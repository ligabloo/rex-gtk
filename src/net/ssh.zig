//! Reaching a Rex server over ssh.
//!
//! We don't run ssh ourselves. `rex __internal ssh-tunnel ssh://HOST` does,
//! the same helper Rex.app uses: it starts the remote server if needed,
//! forwards its socket to a local Unix socket, and talks JSON lines on its
//! standard input and output. It stops when its input closes. See
//! docs/protocol-notes.md.
//!
//! This file is the parts that need no process: the helper's messages, the
//! answer we send back, and which ssh agent socket to hand it. The owner of
//! a machine spawns the helper and feeds its lines through `parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// How long to wait for the helper's first line. A locked ssh agent makes
/// ssh wait without printing anything.
pub const connect_timeout_ms = 20_000;

pub const PromptKind = enum {
    /// A yes or no question, such as trusting a host's key.
    confirm,
    /// Anything else. Ask for hidden text: it's a password or a passphrase.
    secret,
};

pub const ErrorKind = enum {
    /// ssh could not reach the host.
    connect,
    /// The host's key is unknown or changed, and nobody could be asked.
    host_key,
    /// The host has no `rex` on a non-interactive shell's PATH.
    rex_not_found,
    other,
};

pub const Message = union(enum) {
    /// One of ssh's questions. Reply with `writeAnswer`.
    prompt: struct { id: []const u8, kind: PromptKind, text: []const u8 },
    /// A prompt ended. `answered` is false if the helper gave up on it.
    done: struct { id: []const u8, answered: bool },
    /// The tunnel is up. `socket` is a local Unix socket path.
    ready: struct { socket: []const u8, remote_socket: []const u8 },
    /// The helper is stopping. `kind` is null when we closed its input.
    exit: struct { reason: []const u8, kind: ?ErrorKind },
    unknown,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    message: Message,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Parse one line the helper printed. A line that isn't a message we know
/// comes back as `unknown`, so a newer helper doesn't break us.
pub fn parse(gpa: Allocator, line: []const u8) Allocator.Error!Parsed {
    var parsed: Parsed = .{ .arena = .init(gpa), .message = .unknown };
    errdefer parsed.arena.deinit();
    const alloc = parsed.arena.allocator();

    const root = json.parseFromSliceLeaky(json.Value, alloc, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parsed,
    };
    if (root != .object) return parsed;
    const obj = root.object;
    const type_name = str(obj, "type") orelse return parsed;

    if (std.mem.eql(u8, type_name, "prompt")) {
        const id = str(obj, "id") orelse return parsed;
        const kind_name = str(obj, "kind") orelse "";
        parsed.message = .{ .prompt = .{
            .id = id,
            .kind = if (std.mem.eql(u8, kind_name, "confirm")) .confirm else .secret,
            .text = str(obj, "text") orelse "",
        } };
    } else if (std.mem.eql(u8, type_name, "done")) {
        const id = str(obj, "id") orelse return parsed;
        const reason = str(obj, "reason") orelse "";
        parsed.message = .{ .done = .{ .id = id, .answered = std.mem.eql(u8, reason, "answered") } };
    } else if (std.mem.eql(u8, type_name, "ready")) {
        const socket = str(obj, "socket") orelse return parsed;
        // Only a Unix socket is known. Anything else we couldn't dial.
        if (str(obj, "network")) |network| {
            if (!std.mem.eql(u8, network, "unix")) return parsed;
        }
        parsed.message = .{ .ready = .{
            .socket = socket,
            .remote_socket = str(obj, "remote_socket") orelse "",
        } };
    } else if (std.mem.eql(u8, type_name, "exit")) {
        const kind: ?ErrorKind = if (str(obj, "error_kind")) |name|
            std.meta.stringToEnum(ErrorKind, name) orelse .other
        else
            null;
        parsed.message = .{ .exit = .{ .reason = str(obj, "reason") orelse "", .kind = kind } };
    }
    return parsed;
}

fn str(obj: json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Write the reply to a prompt, as one line.
pub fn writeAnswer(w: *std.Io.Writer, id: []const u8, answer: []const u8) std.Io.Writer.Error!void {
    var s: json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("answer");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("answer");
    try s.write(answer);
    try s.endObject();
    try w.writeByte('\n');
}

/// Which ssh agent the helper, and so ssh, should use.
pub const Agent = union(enum) {
    /// Whatever SSH_AUTH_SOCK already says.
    default,
    gnome_keyring,
    onepassword,
    /// The path of an agent's socket.
    custom: []const u8,
    /// No agent. ssh asks for each key's passphrase.
    none,
};

pub const Env = struct {
    ssh_auth_sock: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    home: ?[]const u8,
};

/// The socket path to put in SSH_AUTH_SOCK, or null to unset it. The path
/// may not exist: check before offering an agent. Caller owns the result.
pub fn agentSocket(gpa: Allocator, agent: Agent, env: Env) Allocator.Error!?[]u8 {
    switch (agent) {
        .none => return null,
        .default => return if (env.ssh_auth_sock) |s| try gpa.dupe(u8, s) else null,
        .custom => |path| return if (path.len == 0) null else try gpa.dupe(u8, path),
        .onepassword => {
            const home = env.home orelse return null;
            return try std.fs.path.join(gpa, &.{ home, ".1password", "agent.sock" });
        },
        .gnome_keyring => {
            const runtime = env.xdg_runtime_dir orelse return null;
            return try std.fs.path.join(gpa, &.{ runtime, "gcr", "ssh" });
        },
    }
}

/// Where GNOME Keyring's agent lived before gcr took it over. Try it when
/// the path from `agentSocket` doesn't exist. Caller owns the result.
pub fn legacyKeyringSocket(gpa: Allocator, env: Env) Allocator.Error!?[]u8 {
    const runtime = env.xdg_runtime_dir orelse return null;
    return try std.fs.path.join(gpa, &.{ runtime, "keyring", "ssh" });
}

const testing = std.testing;

test "prompt, done and answer" {
    var p = try parse(testing.allocator,
        \\{"type":"prompt","id":"1","kind":"confirm","text":"Are you sure (yes/no)? ","pid":76064}
    );
    defer p.deinit();
    try testing.expectEqualStrings("1", p.message.prompt.id);
    try testing.expectEqual(PromptKind.confirm, p.message.prompt.kind);
    try testing.expectEqualStrings("Are you sure (yes/no)? ", p.message.prompt.text);

    var q = try parse(testing.allocator,
        \\{"type":"prompt","id":"2","kind":"passphrase","text":"Enter passphrase: "}
    );
    defer q.deinit();
    try testing.expectEqual(PromptKind.secret, q.message.prompt.kind);

    var d = try parse(testing.allocator,
        \\{"type":"done","id":"1","reason":"canceled"}
    );
    defer d.deinit();
    try testing.expect(!d.message.done.answered);

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAnswer(&w, "1", "say \"yes\"");
    try testing.expectEqualStrings(
        "{\"type\":\"answer\",\"id\":\"1\",\"answer\":\"say \\\"yes\\\"\"}\n",
        w.buffered(),
    );
}

test "ready" {
    var p = try parse(testing.allocator,
        \\{"type":"ready","version":1,"network":"unix","socket":"/run/user/1000/rex/ssh/3baa.sock","mode":"forward","host":"ssh://localhost","remote_socket":"/run/user/1000/rex/server.sock"}
    );
    defer p.deinit();
    try testing.expectEqualStrings("/run/user/1000/rex/ssh/3baa.sock", p.message.ready.socket);
    try testing.expectEqualStrings("/run/user/1000/rex/server.sock", p.message.ready.remote_socket);

    var tcp = try parse(testing.allocator,
        \\{"type":"ready","network":"tcp","socket":"127.0.0.1:9"}
    );
    defer tcp.deinit();
    try testing.expect(tcp.message == .unknown);
}

test "exit" {
    var a = try parse(testing.allocator,
        \\{"type":"exit","reason":"rex was not found on box","error_kind":"rex_not_found"}
    );
    defer a.deinit();
    try testing.expectEqual(ErrorKind.rex_not_found, a.message.exit.kind.?);

    var b = try parse(testing.allocator,
        \\{"type":"exit","reason":"standard input was closed"}
    );
    defer b.deinit();
    try testing.expect(b.message.exit.kind == null);

    var c = try parse(testing.allocator,
        \\{"type":"exit","reason":"x","error_kind":"something_new"}
    );
    defer c.deinit();
    try testing.expectEqual(ErrorKind.other, c.message.exit.kind.?);
}

test "lines we don't know" {
    for ([_][]const u8{ "", "not json", "[1]", "{\"type\":\"hello\"}", "{\"type\":\"ready\"}" }) |line| {
        var p = try parse(testing.allocator, line);
        defer p.deinit();
        try testing.expect(p.message == .unknown);
    }
}

test "agent sockets" {
    const gpa = testing.allocator;
    const env: Env = .{ .ssh_auth_sock = "/tmp/agent", .xdg_runtime_dir = "/run/user/1000", .home = "/home/me" };

    try testing.expect(try agentSocket(gpa, .none, env) == null);
    try testing.expect(try agentSocket(gpa, .{ .custom = "" }, env) == null);
    try testing.expect(try agentSocket(gpa, .default, .{ .ssh_auth_sock = null, .xdg_runtime_dir = null, .home = null }) == null);

    const cases = [_]struct { Agent, []const u8 }{
        .{ .default, "/tmp/agent" },
        .{ .{ .custom = "/x/y.sock" }, "/x/y.sock" },
        .{ .onepassword, "/home/me/.1password/agent.sock" },
        .{ .gnome_keyring, "/run/user/1000/gcr/ssh" },
    };
    for (cases) |case| {
        const path = (try agentSocket(gpa, case[0], env)).?;
        defer gpa.free(path);
        try testing.expectEqualStrings(case[1], path);
    }
}
