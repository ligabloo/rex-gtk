//! A small RFC 6455 WebSocket client over a Unix domain socket, TCP or TLS.
//!
//! Only what Rex needs: one connection per socket, no extensions (we never
//! offer permessage-deflate), text and binary messages, ping/pong and close.
//!
//! Threading: one thread reads (`readMessage` or `payloadReader`), any thread
//! may write. Writes are serialized by a mutex.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const endpoint = @import("endpoint.zig");

const log = std.log.scoped(.ws);
const tls = std.crypto.tls;

/// The system's root certificates, read the first time a TLS connection
/// needs them and shared by every connection after that.
var ca_bundle: std.crypto.Certificate.Bundle = .empty;
var ca_bundle_lock: Io.RwLock = .init;
var ca_bundle_loaded: bool = false;

fn loadCaBundle(io: Io) !void {
    try ca_bundle_lock.lock(io);
    defer ca_bundle_lock.unlock(io);
    if (ca_bundle_loaded) return;
    ca_bundle.rescan(std.heap.page_allocator, io, Io.Clock.real.now(io)) catch |err| {
        log.warn("reading the system's root certificates failed: {t}", .{err});
        return error.TlsFailed;
    };
    ca_bundle_loaded = true;
}

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    fn isControl(op: Opcode) bool {
        return @intFromEnum(op) & 0x8 != 0;
    }
};

pub const Error = error{
    /// The server closed the connection with a close frame. See `close_code`.
    Closed,
    /// The server broke the WebSocket protocol.
    ProtocolError,
    /// A message was larger than the caller's limit.
    MessageTooLarge,
    /// The HTTP upgrade failed. See the log for the status line.
    HandshakeFailed,
    /// The server answered 403: its access rules don't let us in.
    Forbidden,
} || Io.Reader.Error || Io.Writer.Error || Allocator.Error;

/// The longest control frame payload the protocol allows.
const max_control_payload = 125;

pub const Conn = struct {
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    /// Where frames are read from and written to: the socket itself, or
    /// the TLS session on top of it.
    r: *Io.Reader,
    w: *Io.Writer,
    tls_state: ?*Tls = null,
    write_mutex: Io.Mutex = .init,

    /// Payload bytes of the current data frame that haven't been read yet.
    frame_remaining: u64 = 0,
    /// Whether the current data frame is the last of its message.
    frame_fin: bool = true,

    /// Set when the server sends a close frame.
    close_code: ?u16 = null,
    close_reason_buf: [max_control_payload]u8 = undefined,
    close_reason_len: usize = 0,
    /// Set once we have sent a close frame; we never send a second.
    close_sent: bool = false,

    read_buf: [64 * 1024]u8 = undefined,
    // At least one TLS record, which is what the TLS client needs.
    write_buf: [32 * 1024]u8 = undefined,

    const Tls = struct {
        client: tls.Client,
        read_buf: [tls.Client.min_buffer_len]u8 = undefined,
        write_buf: [tls.Client.min_buffer_len]u8 = undefined,
    };

    pub const ConnectOptions = struct {
        /// The request path, such as /api/control.
        path: []const u8,
        /// The value of Sec-WebSocket-Protocol to request and require.
        subprotocol: []const u8,
    };

    /// Connect to wherever `ep` says. An ssh endpoint can't be connected
    /// to directly: start its tunnel and connect to the socket it gives.
    pub fn connect(gpa: Allocator, io: Io, ep: endpoint.Endpoint, options: ConnectOptions) !*Conn {
        return switch (ep) {
            .unix => |path| connectUnix(gpa, io, path, options),
            .tcp => |t| connectTcp(gpa, io, t, options),
            .ssh => error.NeedsTunnel,
        };
    }

    /// Connect over TCP, with TLS if the endpoint says so, and perform the
    /// WebSocket upgrade. Free with `destroy`.
    pub fn connectTcp(gpa: Allocator, io: Io, t: endpoint.Tcp, options: ConnectOptions) !*Conn {
        // Zig 0.17's threaded Io can't time a connect out yet, so this
        // waits as long as the kernel does. Callers connect from a worker
        // thread and stop waiting on their own.
        const connect_options: Io.net.IpAddress.ConnectOptions = .{ .mode = .stream };
        const stream = if (Io.net.IpAddress.parse(t.host, t.port)) |address|
            try address.connect(io, connect_options)
        else |_| stream: {
            const name = Io.net.HostName.init(t.host) catch return error.BadHostName;
            break :stream try name.connect(io, t.port, connect_options);
        };
        errdefer stream.close(io);

        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .r = undefined,
            .w = undefined,
        };
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
        self.r = &self.reader.interface;
        self.w = &self.writer.interface;

        errdefer if (self.tls_state) |state| gpa.destroy(state);
        if (t.tls) {
            try loadCaBundle(io);
            const state = try gpa.create(Tls);
            self.tls_state = state;
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            state.* = .{ .client = tls.Client.init(&self.reader.interface, &self.writer.interface, .{
                .host = .{ .explicit = t.host },
                .ca = .{ .bundle = .{
                    .gpa = std.heap.page_allocator,
                    .io = io,
                    .lock = &ca_bundle_lock,
                    .bundle = &ca_bundle,
                } },
                .read_buffer = &state.read_buf,
                .write_buffer = &state.write_buf,
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(io),
                // A WebSocket ends with a close frame, so a cut connection
                // is noticed without TLS's own end marker.
                .allow_truncation_attacks = true,
            }) catch |err| {
                log.info("TLS with {s}:{d} failed: {t}", .{ t.host, t.port, err });
                return error.TlsFailed;
            } };
            self.r = &state.client.reader;
            self.w = &state.client.writer;
        }

        var host_buf: [300]u8 = undefined;
        const default_port: u16 = if (t.tls) 443 else 80;
        const v6 = std.mem.indexOfScalar(u8, t.host, ':') != null;
        const host = if (t.port == default_port and !v6)
            t.host
        else if (v6)
            std.fmt.bufPrint(&host_buf, "[{s}]:{d}", .{ t.host, t.port }) catch return error.BadHostName
        else
            std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ t.host, t.port }) catch return error.BadHostName;
        try self.handshake(options, host);
        return self;
    }

    /// Connect to a Unix socket and perform the WebSocket upgrade. The
    /// returned connection is heap-allocated because its reader and writer
    /// point into it; free with `destroy`.
    pub fn connectUnix(
        gpa: Allocator,
        io: Io,
        socket_path: []const u8,
        options: ConnectOptions,
    ) !*Conn {
        const address: Io.net.UnixAddress = try .init(socket_path);
        const stream = try address.connect(io);
        errdefer stream.close(io);

        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .r = undefined,
            .w = undefined,
        };
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
        self.r = &self.reader.interface;
        self.w = &self.writer.interface;

        try self.handshake(options, "localhost");
        return self;
    }

    /// Close the socket and free the connection. Call `sendClose` first for
    /// a clean close.
    pub fn destroy(self: *Conn, gpa: Allocator) void {
        self.stream.close(self.io);
        if (self.tls_state) |state| gpa.destroy(state);
        gpa.destroy(self);
    }

    /// Shut down the socket so a thread blocked in a read returns.
    pub fn shutdown(self: *Conn) void {
        self.stream.shutdown(self.io, .both) catch {};
    }

    pub fn closeReason(self: *const Conn) []const u8 {
        return self.close_reason_buf[0..self.close_reason_len];
    }

    /// Send what's buffered all the way to the socket. With TLS the frames
    /// first become records in the socket's own buffer.
    fn flush(self: *Conn) Io.Writer.Error!void {
        try self.w.flush();
        if (self.tls_state != null) try self.writer.interface.flush();
    }

    fn handshake(self: *Conn, options: ConnectOptions, host: []const u8) !void {
        var key_bytes: [16]u8 = undefined;
        self.io.random(&key_bytes);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        const w = self.w;
        try w.print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Sec-WebSocket-Protocol: {s}\r\n" ++
                "\r\n",
            .{ options.path, host, key, options.subprotocol },
        );
        try self.flush();

        var expected_accept_buf: [28]u8 = undefined;
        const expected_accept = acceptKey(&expected_accept_buf, key);

        const r = self.r;
        const status_line = trimCr(try r.takeDelimiterInclusive('\n'));
        if (std.mem.startsWith(u8, status_line, "HTTP/1.1 403")) return error.Forbidden;
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
            log.err("upgrade to {s} refused: {s}", .{ options.path, status_line });
            return error.HandshakeFailed;
        }

        var accept_ok = false;
        var protocol_ok = false;
        while (true) {
            const line = trimCr(try r.takeDelimiterInclusive('\n'));
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept_ok = std.mem.eql(u8, value, expected_accept);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
                protocol_ok = std.mem.eql(u8, value, options.subprotocol);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
                // We offered none, so the server must not choose any.
                log.err("server chose extensions we didn't offer: {s}", .{value});
                return error.HandshakeFailed;
            }
        }
        if (!accept_ok or !protocol_ok) {
            log.err("bad upgrade response (accept ok: {}, protocol ok: {})", .{ accept_ok, protocol_ok });
            return error.HandshakeFailed;
        }
    }

    // ------------------------------------------------------------------
    // Writing

    pub fn writeMessage(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.writeFrameLocked(opcode, payload);
    }

    /// Send a close frame with a status code. Safe to call more than once.
    pub fn sendClose(self: *Conn, code: u16, reason: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.close_sent) return;
        self.close_sent = true;
        var buf: [max_control_payload]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        const n = @min(reason.len, buf.len - 2);
        @memcpy(buf[2..][0..n], reason[0..n]);
        self.writeFrameLocked(.close, buf[0 .. 2 + n]) catch {};
    }

    fn writeFrameLocked(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        const header_len = encodeFrameHeader(&header, opcode, payload.len, true);
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        @memcpy(header[header_len..][0..4], &mask);

        const w = self.w;
        try w.writeAll(header[0 .. header_len + 4]);

        // Mask through a small stack buffer so the caller's payload stays
        // untouched.
        var chunk: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const n = @min(chunk.len, payload.len - offset);
            for (chunk[0..n], payload[offset..][0..n], 0..) |*out, in, i| {
                out.* = in ^ mask[(offset + i) % 4];
            }
            try w.writeAll(chunk[0..n]);
            offset += n;
        }
        try self.flush();
    }

    // ------------------------------------------------------------------
    // Reading

    pub const Message = struct {
        opcode: Opcode,
        /// Owned by the caller's allocator.
        data: []u8,
    };

    /// Read one complete text or binary message, answering pings on the way.
    /// Returns error.Closed after the server's close frame.
    pub fn readMessage(self: *Conn, gpa: Allocator, max_len: usize) Error!Message {
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(gpa);

        const first = try self.nextDataFrame(false);
        while (true) {
            if (data.items.len + self.frame_remaining > max_len) return error.MessageTooLarge;
            const n: usize = @intCast(self.frame_remaining);
            try data.ensureUnusedCapacity(gpa, n);
            try self.r.readSliceAll(data.unusedCapacitySlice()[0..n]);
            data.items.len += n;
            self.frame_remaining = 0;
            if (self.frame_fin) break;
            _ = try self.nextDataFrame(true);
        }
        return .{ .opcode = first, .data = try data.toOwnedSlice(gpa) };
    }

    /// Read frame headers until a data frame arrives, handling control frames.
    /// `continuation` says whether we're in the middle of a message.
    fn nextDataFrame(self: *Conn, continuation: bool) Error!Opcode {
        std.debug.assert(self.frame_remaining == 0);
        const r = self.r;
        while (true) {
            const head = try r.takeArray(2);
            const fin = head[0] & 0x80 != 0;
            if (head[0] & 0x70 != 0) return error.ProtocolError; // RSV bits
            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(head[0])));
            if (head[1] & 0x80 != 0) return error.ProtocolError; // server frames are never masked
            const len: u64 = switch (head[1] & 0x7f) {
                126 => try r.takeInt(u16, .big),
                127 => try r.takeInt(u64, .big),
                else => |l| l,
            };

            if (opcode.isControl()) {
                if (!fin or len > max_control_payload) return error.ProtocolError;
                var buf: [max_control_payload]u8 = undefined;
                const payload = buf[0..@intCast(len)];
                try r.readSliceAll(payload);
                switch (opcode) {
                    .ping => self.writeMessage(.pong, payload) catch {},
                    .pong => {},
                    .close => {
                        if (payload.len >= 2) {
                            self.close_code = std.mem.readInt(u16, payload[0..2], .big);
                            self.close_reason_len = payload.len - 2;
                            @memcpy(self.close_reason_buf[0..self.close_reason_len], payload[2..]);
                        } else {
                            self.close_code = 1005; // no status received
                        }
                        self.sendClose(self.close_code.?, "");
                        return error.Closed;
                    },
                    else => return error.ProtocolError,
                }
                continue;
            }

            switch (opcode) {
                .continuation => if (!continuation) return error.ProtocolError,
                .text, .binary => if (continuation) return error.ProtocolError,
                else => return error.ProtocolError,
            }
            self.frame_fin = fin;
            self.frame_remaining = len;
            return opcode;
        }
    }

    /// A reader over the payload of every data frame, joined in order. Rex's
    /// data connections define message boundaries as meaningless, so this is
    /// the natural way to read a stream. Reaching the server's close frame
    /// ends the stream (`EndOfStream`), with `close_code` set.
    pub const PayloadReader = struct {
        conn: *Conn,
        interface: Io.Reader,
        /// Bytes this reader has handed out, for data stream resume counts.
        consumed: u64 = 0,
        /// The error behind the last `ReadFailed`, if any.
        err: ?Error = null,
        /// If set, every stream byte is also written here (for recording).
        tee: ?*Io.Writer = null,

        fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *PayloadReader = @alignCast(@fieldParentPtr("interface", io_r));
            const conn = self.conn;
            while (conn.frame_remaining == 0) {
                _ = conn.nextDataFrame(!conn.frame_fin) catch |err| switch (err) {
                    error.Closed, error.EndOfStream => return error.EndOfStream,
                    else => {
                        self.err = err;
                        return error.ReadFailed;
                    },
                };
            }
            const max: usize = @intCast(@min(conn.frame_remaining, std.math.maxInt(usize)));
            const dest = limit.min(.limited(max)).slice(try w.writableSliceGreedy(1));
            var vec: [1][]u8 = .{dest};
            const n = conn.r.readVec(&vec) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => {
                    self.err = error.ReadFailed;
                    return error.ReadFailed;
                },
            };
            if (self.tee) |t| t.writeAll(dest[0..n]) catch {};
            w.advance(n);
            conn.frame_remaining -= n;
            self.consumed += n;
            return n;
        }
    };

    /// Start reading the connection as one byte stream. `buffer` is the
    /// reader's own buffer; it must outlive the reader.
    pub fn payloadReader(self: *Conn, buffer: []u8) PayloadReader {
        return .{
            .conn = self,
            .interface = .{
                .vtable = &.{ .stream = PayloadReader.stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }
};

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// Compute Sec-WebSocket-Accept for a key.
fn acceptKey(out: *[28]u8, key: []const u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Write a frame header without the masking key. Returns its length. When
/// `masked` is set, the caller appends the 4-byte key right after.
fn encodeFrameHeader(buf: *[14]u8, opcode: Opcode, len: usize, masked: bool) usize {
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    const mask_bit: u8 = if (masked) 0x80 else 0;
    if (len < 126) {
        buf[1] = mask_bit | @as(u8, @intCast(len));
        return 2;
    } else if (len <= std.math.maxInt(u16)) {
        buf[1] = mask_bit | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        return 4;
    } else {
        buf[1] = mask_bit | 127;
        std.mem.writeInt(u64, buf[2..10], len, .big);
        return 10;
    }
}

test "accept key from RFC 6455" {
    var buf: [28]u8 = undefined;
    try std.testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        acceptKey(&buf, "dGhlIHNhbXBsZSBub25jZQ=="),
    );
}

test "frame header lengths" {
    var buf: [14]u8 = undefined;
    try std.testing.expectEqual(2, encodeFrameHeader(&buf, .text, 5, true));
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x85), buf[1]);
    try std.testing.expectEqual(4, encodeFrameHeader(&buf, .binary, 300, false));
    try std.testing.expectEqual(@as(u8, 126), buf[1]);
    try std.testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqual(10, encodeFrameHeader(&buf, .binary, 70000, false));
    try std.testing.expectEqual(@as(u8, 127), buf[1]);
}
