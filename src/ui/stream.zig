//! One terminal's data stream, read on its own thread. The thread opens the
//! data connection, decodes the snapshot (which can be large), then forwards
//! every later chunk. Results arrive on the main thread through `Sink`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const data = core.data;
const ghostty_vt = core.ghostty_vt;
const glib = @import("glib");
const mainloop = @import("mainloop.zig");

const log = std.log.scoped(.stream);

/// Main-thread callbacks. None of them run after `Stream.destroy`.
pub const Sink = struct {
    ctx: *anyopaque,
    /// The snapshot is decoded. The sink takes ownership of `decoded` and
    /// must `deinit` it after building its terminal from it.
    ready: *const fn (ctx: *anyopaque, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64) void,
    /// Stream bytes after the snapshot.
    bytes: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// The stream ended.
    ended: *const fn (ctx: *anyopaque, end: End) void,
};

pub const End = struct {
    /// The WebSocket close status, if the server sent one.
    close_code: ?u16 = null,
    /// Connecting or the handshake failed (such as a REJECT).
    open_failed: bool = false,
    /// The snapshot couldn't be decoded: likely a Ghostty version mismatch.
    snapshot_failed: bool = false,
};

/// The most stream bytes waiting for the main thread before the reader
/// stops reading. Keeps `cat hugefile` from piling up memory.
const max_queued_bytes = 8 * 1024 * 1024;

/// Output arriving within this long of the last drain is a flood, and is
/// delivered at idle priority so GTK still gets to redraw. Sparser output,
/// such as the echo of a key, is delivered ahead of the redraw.
const busy_window_us = 4 * std.time.us_per_ms;

pub const Stream = struct {
    gpa: Allocator,
    io: std.Io,
    socket_path: []const u8,
    ticket: []u8,
    sink: Sink,
    thread: ?std.Thread = null,
    /// Set by the reader thread once connected; read by `destroy`.
    conn: std.atomic.Value(?*data.DataConn) = .init(null),
    /// Main thread: set by `destroy`; messages check it before delivering.
    closed: bool = false,
    /// Reader thread: asked to stop.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Bytes posted to the main thread and not yet delivered.
    queued: std.atomic.Value(usize) = .init(0),

    /// Stream bytes read and not yet delivered, and whether a `drain` is
    /// posted for them. Guarded by `pending_mutex`.
    pending: std.ArrayList(u8) = .empty,
    drain_posted: bool = false,
    pending_mutex: std.Io.Mutex = .init,
    /// Main thread: the bytes being delivered, swapped with `pending`.
    draining: std.ArrayList(u8) = .empty,
    /// Set while the main thread delivers bytes, and when it last finished
    /// (GLib monotonic time). The reader picks a priority from them.
    feeding: std.atomic.Value(bool) = .init(false),
    last_drain_us: std.atomic.Value(i64) = .init(0),

    pub fn create(gpa: Allocator, io: std.Io, socket_path: []const u8, ticket: []const u8, sink: Sink) !*Stream {
        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .socket_path = socket_path,
            .ticket = try gpa.dupe(u8, ticket),
            .sink = sink,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// End the stream for good and free it. Main thread only.
    pub fn destroy(self: *Stream) void {
        self.closed = true;
        self.stopping.store(true, .release);
        if (self.conn.load(.acquire)) |dc| {
            dc.close();
            dc.shutdown();
        }
        if (self.thread) |t| t.join();
        // Messages already queued run before this, see `closed`, and drop.
        mainloop.post(Stream, self, free);
    }

    fn free(self: *Stream) void {
        if (self.conn.load(.acquire)) |dc| dc.destroy();
        self.pending.deinit(self.gpa);
        self.draining.deinit(self.gpa);
        self.gpa.free(self.ticket);
        self.gpa.destroy(self);
    }

    // ------------------------------------------------------------------
    // Reader thread

    fn run(self: *Stream) void {
        var end: End = .{};
        defer self.postEnded(end);

        const dc = data.DataConn.open(self.gpa, self.io, self.socket_path, self.ticket, data.terminal_subprotocol) catch |err| {
            log.warn("opening data connection failed: {}", .{err});
            end.open_failed = true;
            return;
        };
        self.conn.store(dc, .release);
        // destroy() may have run before the store; check again.
        if (self.stopping.load(.acquire)) return;

        const decoded = self.gpa.create(ghostty_vt.snapshot.Decoded) catch return;
        decoded.* = dc.decodeSnapshot() catch |err| {
            self.gpa.destroy(decoded);
            end.close_code = dc.closeCode();
            if (!self.stopping.load(.acquire)) {
                log.warn("snapshot decode failed: {} (close status {?})", .{ err, end.close_code });
                // A closed connection isn't the snapshot's fault.
                end.snapshot_failed = end.close_code == null and err != error.EndOfStream and err != error.ReadFailed;
            }
            return;
        };
        self.postReady(decoded, dc.welcome.nonce);

        while (true) {
            const bytes = (dc.next() catch |err| {
                if (!self.stopping.load(.acquire)) log.warn("data stream read failed: {}", .{err});
                break;
            }) orelse break;
            self.postBytes(bytes) catch break;
            // Let the main thread catch up before reading more.
            while (self.queued.load(.acquire) > max_queued_bytes and !self.stopping.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch break;
            }
        }
        end.close_code = dc.closeCode();
    }

    const Ready = struct { stream: *Stream, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64 };
    const Ended = struct { stream: *Stream, end: End };

    fn postReady(self: *Stream, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64) void {
        const m = self.gpa.create(Ready) catch return;
        m.* = .{ .stream = self, .decoded = decoded, .nonce = nonce };
        // Same priority as the first `drain`, so it can't overtake this.
        mainloop.postWithPriority(Ready, m, deliverReady, .default);
    }

    /// Queue bytes for the main thread. One `drain` delivers everything
    /// queued since the last, so a burst costs one callback.
    fn postBytes(self: *Stream, bytes: []const u8) !void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        try self.pending.appendSlice(self.gpa, bytes);
        _ = self.queued.fetchAdd(bytes.len, .release);
        if (self.drain_posted) return;
        self.drain_posted = true;
        const busy = self.feeding.load(.acquire) or
            glib.getMonotonicTime() - self.last_drain_us.load(.acquire) < busy_window_us;
        mainloop.postWithPriority(Stream, self, drain, if (busy) .idle else .default);
    }

    fn postEnded(self: *Stream, end: End) void {
        const m = self.gpa.create(Ended) catch return;
        m.* = .{ .stream = self, .end = end };
        mainloop.post(Ended, m, deliverEnded);
    }

    // Main thread

    fn deliverReady(m: *Ready) void {
        const self = m.stream;
        defer self.gpa.destroy(m);
        if (self.closed) {
            m.decoded.deinit(self.gpa);
            self.gpa.destroy(m.decoded);
            return;
        }
        self.sink.ready(self.sink.ctx, m.decoded, m.nonce);
    }

    fn drain(self: *Stream) void {
        self.feeding.store(true, .release);
        {
            self.pending_mutex.lockUncancelable(self.io);
            defer self.pending_mutex.unlock(self.io);
            std.mem.swap(std.ArrayList(u8), &self.pending, &self.draining);
            self.drain_posted = false;
        }
        defer {
            _ = self.queued.fetchSub(self.draining.items.len, .release);
            self.draining.clearRetainingCapacity();
            self.last_drain_us.store(glib.getMonotonicTime(), .release);
            self.feeding.store(false, .release);
        }
        if (!self.closed and self.draining.items.len > 0) self.sink.bytes(self.sink.ctx, self.draining.items);
    }

    fn deliverEnded(m: *Ended) void {
        const self = m.stream;
        defer self.gpa.destroy(m);
        if (!self.closed) self.sink.ended(self.sink.ctx, m.end);
    }
};
