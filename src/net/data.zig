//! A Rex data connection: a WebSocket at /api/data that streams one block's
//! output. For a terminal (subprotocol rex.data.terminal.v1) the stream is a
//! Ghostty snapshot followed by the program's output with Rex's own messages
//! mixed in. See "Data Connections" in docs/api/llms.txt.
//!
//! All reads block; the app runs one reader thread per data connection.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const ws = @import("ws.zig");
const endpoint = @import("endpoint.zig");

const log = std.log.scoped(.data);

pub const terminal_subprotocol = "rex.data.terminal.v1";

pub const Reject = enum(u8) {
    unknown_ticket = 0x01,
    already_connected = 0x02,
    stream_unavailable = 0x03,
    limit = 0x04,
    malformed = 0x05,
    server_failed = 0x06,
    wrong_subprotocol = 0x07,
    _,
};

pub const Welcome = struct {
    reconnect_token: [16]u8,
    /// How long the server keeps the stream for a resume.
    grace_ms: u32,
    /// Marks Rex's own messages in the terminal stream. Never zero.
    nonce: u64,
};

pub const Error = error{
    /// The server sent a REJECT. See `DataConn.reject`.
    Rejected,
    BadTicket,
    BadHandshake,
};

/// Largest continuation (unfinished VT sequence) we accept in a snapshot.
const max_continuation_bytes = 1024 * 1024;

pub const DataConn = struct {
    gpa: Allocator,
    io: Io,
    conn: *ws.Conn,
    welcome: Welcome = undefined,
    reject: ?Reject = null,
    payload: ws.Conn.PayloadReader = undefined,
    buf: [64 * 1024]u8 = undefined,

    /// Open a data connection and complete the handshake. `ticket` is the
    /// base64url ticket from data.connect or session.bootstrap.
    pub fn open(
        gpa: Allocator,
        io: Io,
        ep: endpoint.Endpoint,
        ticket: []const u8,
        subprotocol: []const u8,
    ) !*DataConn {
        var ticket_bytes: [16]u8 = undefined;
        const decoder = std.base64.url_safe_no_pad.Decoder;
        if ((decoder.calcSizeForSlice(ticket) catch return error.BadTicket) != 16) return error.BadTicket;
        decoder.decode(&ticket_bytes, ticket) catch return error.BadTicket;

        const conn = try ws.Conn.connect(gpa, io, ep, .{
            .path = "/api/data",
            .subprotocol = subprotocol,
        });
        errdefer conn.destroy(gpa);

        const self = try gpa.create(DataConn);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .conn = conn };

        var hello: [17]u8 = undefined;
        hello[0] = 0x01;
        @memcpy(hello[1..], &ticket_bytes);
        try conn.writeMessage(.binary, &hello);

        // The answer is one binary message: WELCOME or REJECT.
        const answer = try conn.readMessage(gpa, 64);
        defer gpa.free(answer.data);
        if (answer.opcode != .binary or answer.data.len < 2) return error.BadHandshake;
        switch (answer.data[0]) {
            0x81 => {
                if (answer.data.len != 32) return error.BadHandshake;
                self.welcome = parseWelcome(answer.data[0..32]);
            },
            0x82 => {
                self.reject = @enumFromInt(answer.data[1]);
                log.warn("data connection rejected: {t}", .{self.reject.?});
                return error.Rejected;
            },
            else => return error.BadHandshake,
        }

        self.payload = conn.payloadReader(&self.buf);
        return self;
    }

    pub fn destroy(self: *DataConn) void {
        self.conn.destroy(self.gpa);
        self.gpa.destroy(self);
    }

    /// End the stream for good (status 1000). Any other way of closing
    /// leaves the stream waiting on the server for a resume.
    pub fn close(self: *DataConn) void {
        self.conn.sendClose(1000, "");
    }

    /// Unblock a thread that is reading this connection.
    pub fn shutdown(self: *DataConn) void {
        self.conn.shutdown();
    }

    pub fn reader(self: *DataConn) *Io.Reader {
        return &self.payload.interface;
    }

    /// Decode the snapshot that starts every terminal stream, through FINISH.
    /// Bytes after it stay buffered for `next`.
    pub fn decodeSnapshot(self: *DataConn) !ghostty_vt.snapshot.Decoded {
        return ghostty_vt.snapshot.decode(self.gpa, self.io, self.reader(), .{
            .max_continuation_bytes = max_continuation_bytes,
            // No kitty graphics in v1.
            .kitty_image_storage_limit = 0,
        });
    }

    /// Block until stream bytes are available and return them. The slice
    /// is valid until the next call. Returns null when the stream ends;
    /// `closeCode` then says why.
    pub fn next(self: *DataConn) !?[]const u8 {
        const r = self.reader();
        const bytes = r.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return self.payload.err orelse error.ReadFailed,
        };
        r.toss(bytes.len);
        return bytes;
    }

    pub fn closeCode(self: *const DataConn) ?u16 {
        return self.conn.close_code;
    }

    pub fn closeReason(self: *const DataConn) []const u8 {
        return self.conn.closeReason();
    }
};

fn parseWelcome(msg: *const [32]u8) Welcome {
    return .{
        .reconnect_token = msg[1..17].*,
        // Bytes 17..20 are zero.
        .grace_ms = std.mem.readInt(u32, msg[20..24], .little),
        .nonce = std.mem.readInt(u64, msg[24..32], .little),
    };
}

test "parse WELCOME" {
    var msg: [32]u8 = @splat(0);
    msg[0] = 0x81;
    for (msg[1..17], 0..) |*b, i| b.* = @intCast(i);
    std.mem.writeInt(u32, msg[20..24], 60_000, .little);
    std.mem.writeInt(u64, msg[24..32], 0x0102030405060708, .little);
    const w = parseWelcome(&msg);
    try std.testing.expectEqual(@as(u8, 15), w.reconnect_token[15]);
    try std.testing.expectEqual(60_000, w.grace_ms);
    try std.testing.expectEqual(0x0102030405060708, w.nonce);
}
