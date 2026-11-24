//! One terminal's data stream, read on its own thread. The thread opens the
//! data connection, decodes the snapshot (which can be large), then forwards
//! every later chunk. Results arrive on the main thread through `Sink`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const data = core.data;
const ghostty_vt = core.ghostty_vt;
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
    /// The stream ended. `close_code` is the WebSocket status, if any.
    ended: *const fn (ctx: *anyopaque, close_code: ?u16) void,
};

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
        self.gpa.free(self.ticket);
        self.gpa.destroy(self);
    }

    // ------------------------------------------------------------------
    // Reader thread

    fn run(self: *Stream) void {
        var close_code: ?u16 = null;
        defer self.postEnded(close_code);

        const dc = data.DataConn.open(self.gpa, self.io, self.socket_path, self.ticket, data.terminal_subprotocol) catch |err| {
            log.warn("opening data connection failed: {}", .{err});
            return;
        };
        self.conn.store(dc, .release);
        // destroy() may have run before the store; check again.
        if (self.stopping.load(.acquire)) return;

        const decoded = self.gpa.create(ghostty_vt.snapshot.Decoded) catch return;
        decoded.* = dc.decodeSnapshot() catch |err| {
            self.gpa.destroy(decoded);
            if (!self.stopping.load(.acquire)) log.warn("snapshot decode failed: {}", .{err});
            close_code = dc.closeCode();
            return;
        };
        self.postReady(decoded, dc.welcome.nonce);

        while (true) {
            const bytes = (dc.next() catch |err| {
                if (!self.stopping.load(.acquire)) log.warn("data stream read failed: {}", .{err});
                break;
            }) orelse break;
            self.postBytes(bytes) catch break;
        }
        close_code = dc.closeCode();
    }

    const Ready = struct { stream: *Stream, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64 };
    const Bytes = struct { stream: *Stream, bytes: []u8 };
    const Ended = struct { stream: *Stream, code: ?u16 };

    fn postReady(self: *Stream, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64) void {
        const m = self.gpa.create(Ready) catch return;
        m.* = .{ .stream = self, .decoded = decoded, .nonce = nonce };
        mainloop.post(Ready, m, deliverReady);
    }

    fn postBytes(self: *Stream, bytes: []const u8) !void {
        const m = try self.gpa.create(Bytes);
        errdefer self.gpa.destroy(m);
        m.* = .{ .stream = self, .bytes = try self.gpa.dupe(u8, bytes) };
        mainloop.post(Bytes, m, deliverBytes);
    }

    fn postEnded(self: *Stream, code: ?u16) void {
        const m = self.gpa.create(Ended) catch return;
        m.* = .{ .stream = self, .code = code };
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

    fn deliverBytes(m: *Bytes) void {
        const self = m.stream;
        defer {
            self.gpa.free(m.bytes);
            self.gpa.destroy(m);
        }
        if (!self.closed) self.sink.bytes(self.sink.ctx, m.bytes);
    }

    fn deliverEnded(m: *Ended) void {
        const self = m.stream;
        defer self.gpa.destroy(m);
        if (!self.closed) self.sink.ended(self.sink.ctx, m.code);
    }
};
