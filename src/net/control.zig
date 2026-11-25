//! The Rex control connection: a WebSocket at /api/control carrying JSON
//! requests, responses and events (subprotocol rex.control.v1).
//!
//! This type does the framing and the hello/welcome exchange. It doesn't
//! route responses: `read` returns each incoming message, and callers match
//! responses to their requests by id. The app does that on a reader thread;
//! the headless tools use `call`, which blocks and queues events.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const ws = @import("ws.zig");
const endpoint = @import("endpoint.zig");

const log = std.log.scoped(.control);

/// The API revision this client is written against. See docs/api/llms.txt.
pub const api_revision = 19;

pub const subprotocol = "rex.control.v1";

pub const ClientInfo = struct {
    kind: []const u8 = "app",
    platform: []const u8 = "linux",
    name: []const u8 = "rex-gtk",
    version: []const u8 = "0.2.1",
    label: ?[]const u8 = null,
};

pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
    status: u16 = 0,
};

/// One message from the server. Owns an arena that holds everything it
/// points to; call `deinit` when done.
pub const Incoming = struct {
    arena: *std.heap.ArenaAllocator,
    kind: Kind,

    pub const Kind = union(enum) {
        response: Response,
        event: Event,
        /// A message type this client doesn't know. Skipped.
        unknown,
    };

    pub const Response = struct {
        id: u64,
        seq: u64,
        payload: json.Value,
        err: ?ApiError,
    };

    pub const Event = struct {
        seq: u64,
        /// The event's name, such as session_event.
        name: []const u8,
        payload: json.Value,
    };

    pub fn deinit(self: Incoming) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn allocator(self: Incoming) Allocator {
        return self.arena.allocator();
    }
};

pub const CallError = error{
    /// The server answered with an error. It was logged.
    ApiError,
    UnexpectedMessage,
};

pub const Control = struct {
    gpa: Allocator,
    io: Io,
    conn: *ws.Conn,
    next_id: std.atomic.Value(u64) = .init(1),

    /// From the welcome.
    max_message_bytes: usize = 64 * 1024,
    negotiated_revision: u32 = 0,
    client_id: [64]u8 = undefined,
    client_id_len: usize = 0,
    reconnect_token: [256]u8 = undefined,
    reconnect_token_len: usize = 0,
    resumed: bool = false,

    /// Events read by `call` while it waited for its response.
    pending_events: std.ArrayList(Incoming) = .empty,

    pub const ConnectOptions = struct {
        info: ClientInfo = .{},
        /// From an earlier welcome, to continue that client.
        reconnect_token: ?[]const u8 = null,
    };

    pub fn connect(gpa: Allocator, io: Io, ep: endpoint.Endpoint, options: ConnectOptions) !*Control {
        const conn = try ws.Conn.connect(gpa, io, ep, .{
            .path = "/api/control",
            .subprotocol = subprotocol,
        });
        errdefer conn.destroy(gpa);

        const self = try gpa.create(Control);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .conn = conn };

        try self.sendHello(options);
        try self.readWelcome();
        return self;
    }

    pub fn destroy(self: *Control) void {
        for (self.pending_events.items) |msg| msg.deinit();
        self.pending_events.deinit(self.gpa);
        self.conn.destroy(self.gpa);
        self.gpa.destroy(self);
    }

    /// Close cleanly. Ends the client on the server at once.
    pub fn close(self: *Control) void {
        self.conn.sendClose(1000, "");
    }

    pub fn clientId(self: *const Control) []const u8 {
        return self.client_id[0..self.client_id_len];
    }

    pub fn reconnectToken(self: *const Control) []const u8 {
        return self.reconnect_token[0..self.reconnect_token_len];
    }

    fn sendHello(self: *Control, options: ConnectOptions) !void {
        const Hello = struct {
            type: []const u8 = "hello",
            api_revision: u32 = api_revision,
            api_min_revision: u32 = api_revision,
            client: ClientInfo,
            reconnect_token: ?[]const u8,
        };
        const text = try json.Stringify.valueAlloc(self.gpa, Hello{
            .client = options.info,
            .reconnect_token = options.reconnect_token,
        }, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(text);
        // The server requires the hello to be under 512 bytes.
        if (text.len >= 512) return error.HelloTooLarge;
        try self.conn.writeMessage(.text, text);
    }

    fn readWelcome(self: *Control) !void {
        const msg = try self.conn.readMessage(self.gpa, self.max_message_bytes);
        defer self.gpa.free(msg.data);

        const Welcome = struct {
            type: []const u8,
            protocol: []const u8,
            limits: struct { max_message_bytes: usize },
            client: ?struct {
                id: []const u8,
                reconnect_token: []const u8,
                resumed: bool = false,
            } = null,
            api_revision: u32 = 0,
        };
        const parsed = try json.parseFromSlice(Welcome, self.gpa, msg.data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const welcome = parsed.value;
        if (!std.mem.eql(u8, welcome.type, "welcome") or !std.mem.eql(u8, welcome.protocol, subprotocol)) {
            log.err("unexpected first message: {s}", .{msg.data});
            return error.UnexpectedMessage;
        }
        self.max_message_bytes = welcome.limits.max_message_bytes;
        self.negotiated_revision = welcome.api_revision;
        if (welcome.client) |client| {
            self.client_id_len = copyInto(&self.client_id, client.id);
            self.reconnect_token_len = copyInto(&self.reconnect_token, client.reconnect_token);
            self.resumed = client.resumed;
        }
        log.debug("welcome: client {s}, revision {}, resumed {}", .{
            self.clientId(), self.negotiated_revision, self.resumed,
        });
    }

    /// Send a request and return its id. `payload` is any value std.json
    /// can serialize; null optional fields are left out.
    pub fn request(self: *Control, method: []const u8, payload: anytype) !u64 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{}", .{id}) catch unreachable;

        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var s: json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        try s.beginObject();
        try s.objectField("type");
        try s.write("request");
        try s.objectField("id");
        try s.write(id_str);
        try s.objectField("method");
        try s.write(method);
        if (@TypeOf(payload) != @TypeOf(null)) {
            try s.objectField("payload");
            try s.write(payload);
        }
        try s.endObject();

        const text = out.written();
        if (text.len > self.max_message_bytes) return error.MessageTooLarge;
        try self.conn.writeMessage(.text, text);
        return id;
    }

    /// Block until the next message arrives.
    pub fn read(self: *Control) !Incoming {
        const msg = try self.conn.readMessage(self.gpa, self.max_message_bytes);
        defer self.gpa.free(msg.data);
        if (msg.opcode != .text) return error.UnexpectedMessage;
        return parseIncoming(self.gpa, msg.data);
    }

    /// Send a request and block until its response, queuing any events that
    /// arrive meanwhile in `pending_events`. For single-threaded tools only:
    /// the app must not mix `call` with a reader thread.
    pub fn call(self: *Control, method: []const u8, payload: anytype) !Incoming {
        const id = try self.request(method, payload);
        while (true) {
            const msg = try self.read();
            switch (msg.kind) {
                .response => |r| if (r.id == id) {
                    if (r.err) |e| {
                        log.err("{s} failed: {s} ({s})", .{ method, e.message, e.code });
                        msg.deinit();
                        return error.ApiError;
                    }
                    return msg;
                },
                .event => {
                    try self.pending_events.append(self.gpa, msg);
                    continue;
                },
                .unknown => {},
            }
            msg.deinit();
        }
    }

    /// `call`, then parse the response payload as `T`. The result lives in
    /// the returned message's arena.
    pub fn callTyped(self: *Control, comptime T: type, method: []const u8, payload: anytype) !struct { Incoming, T } {
        const msg = try self.call(method, payload);
        errdefer msg.deinit();
        const value = try json.parseFromValueLeaky(T, msg.allocator(), msg.kind.response.payload, .{
            .ignore_unknown_fields = true,
        });
        return .{ msg, value };
    }
};

/// Parse one control message. Public for tests.
pub fn parseIncoming(gpa: Allocator, text: []const u8) !Incoming {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const alloc = arena.allocator();

    const root = try json.parseFromSliceLeaky(json.Value, alloc, text, .{});
    if (root != .object) return error.UnexpectedMessage;
    const obj = root.object;
    const type_name = stringField(obj, "type") orelse return error.UnexpectedMessage;

    const kind: Incoming.Kind = if (std.mem.eql(u8, type_name, "response")) kind: {
        const id_str = stringField(obj, "id") orelse return error.UnexpectedMessage;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.UnexpectedMessage;
        const err: ?ApiError = if (obj.get("error")) |e| switch (e) {
            .null => null,
            else => try json.parseFromValueLeaky(ApiError, alloc, e, .{ .ignore_unknown_fields = true }),
        } else null;
        break :kind .{ .response = .{
            .id = id,
            .seq = intField(obj, "seq") orelse 0,
            .payload = obj.get("payload") orelse .null,
            .err = err,
        } };
    } else if (std.mem.eql(u8, type_name, "event")) kind: {
        const inner = obj.get("payload") orelse return error.UnexpectedMessage;
        if (inner != .object) return error.UnexpectedMessage;
        break :kind .{ .event = .{
            .seq = intField(obj, "seq") orelse 0,
            .name = stringField(inner.object, "type") orelse return error.UnexpectedMessage,
            .payload = inner.object.get("payload") orelse .null,
        } };
    } else .unknown;

    return .{ .arena = arena, .kind = kind };
}

pub fn stringField(obj: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn intField(obj: json.ObjectMap, name: []const u8) ?u64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn copyInto(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

/// Connect to the first endpoint of `address` that a Rex server answers
/// on. `chosen` is set to it, for opening data connections later. A server
/// that refuses us ends the search: trying without TLS wouldn't help.
pub fn connectAny(
    gpa: Allocator,
    io: Io,
    candidates: []const endpoint.Endpoint,
    options: Control.ConnectOptions,
    chosen: *endpoint.Endpoint,
) !*Control {
    var last: anyerror = error.NoEndpoints;
    for (candidates) |ep| {
        const ctl = Control.connect(gpa, io, ep, options) catch |err| {
            log.info("{f}: {t}", .{ ep, err });
            if (err == error.Forbidden) return err;
            last = err;
            continue;
        };
        chosen.* = ep;
        return ctl;
    }
    return last;
}

/// The server's socket path: REX_SERVER if it names a Unix socket, else
/// $XDG_RUNTIME_DIR/rex/server.sock. Caller owns the result.
pub fn defaultSocketPath(gpa: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("REX_SERVER")) |server| {
        const prefix = "unix://";
        if (std.mem.startsWith(u8, server, prefix)) return gpa.dupe(u8, server[prefix.len..]);
    }
    const runtime = environ.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    return std.fs.path.join(gpa, &.{ runtime, "rex", "server.sock" });
}

test "parse response and error" {
    const gpa = std.testing.allocator;
    {
        const msg = try parseIncoming(gpa,
            \\{"type":"response","id":"7","seq":3,"payload":{"x":1}}
        );
        defer msg.deinit();
        const r = msg.kind.response;
        try std.testing.expectEqual(7, r.id);
        try std.testing.expectEqual(3, r.seq);
        try std.testing.expect(r.err == null);
        try std.testing.expectEqual(1, r.payload.object.get("x").?.integer);
    }
    {
        const msg = try parseIncoming(gpa,
            \\{"type":"response","id":"2","seq":0,"error":{"code":"not_found","message":"block not found","status":404}}
        );
        defer msg.deinit();
        try std.testing.expectEqualStrings("not_found", msg.kind.response.err.?.code);
    }
}

test "parse event and unknown" {
    const gpa = std.testing.allocator;
    {
        const msg = try parseIncoming(gpa,
            \\{"type":"event","seq":2,"payload":{"type":"session_event","payload":{"session_id":"s","event":{"type":"block_created","payload":{"block_id":"b"}}}}}
        );
        defer msg.deinit();
        try std.testing.expectEqualStrings("session_event", msg.kind.event.name);
        try std.testing.expectEqual(2, msg.kind.event.seq);
    }
    {
        const msg = try parseIncoming(gpa,
            \\{"type":"something_new","x":1}
        );
        defer msg.deinit();
        try std.testing.expect(msg.kind == .unknown);
    }
}
