//! rexcat: attach to one Rex terminal headlessly and print its contents.
//!
//!   rexcat BLOCK_ID [--follow MS] [--record FILE] [--vt]
//!
//! Connects like the app does (control connection, session.bootstrap with a
//! data ticket, data connection, snapshot decode) and prints the terminal as
//! plain text, so the result can be compared with `rex capture -b BLOCK`.
//! --follow keeps applying live output for MS milliseconds before printing.
//! --record saves the raw data stream (snapshot and all) for offline replay.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const control = core.control;
const ghostty_vt = core.ghostty_vt;

const usage = "usage: rexcat BLOCK_ID [--follow MS] [--record FILE] [--vt]\n";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var block_id: ?[]const u8 = null;
    var follow_ms: i64 = 0;
    var record_path: ?[]const u8 = null;
    var emit_vt = false;
    {
        var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--follow")) {
                follow_ms = try std.fmt.parseInt(i64, args.next() orelse return fail(io, usage), 10);
            } else if (std.mem.eql(u8, arg, "--record")) {
                record_path = args.next() orelse return fail(io, usage);
            } else if (std.mem.eql(u8, arg, "--vt")) {
                emit_vt = true;
            } else if (block_id == null) {
                block_id = arg;
            } else return fail(io, usage);
        }
    }
    const block = block_id orelse return fail(io, usage);

    // REX_SERVER takes any address `rex -S` does, except ssh://.
    const socket_path = try control.defaultSocketPath(gpa, init.environ_map);
    defer gpa.free(socket_path);
    var candidates: core.endpoint.Candidates = .{};
    candidates.buf[0] = .{ .unix = socket_path };
    candidates.len = 1;
    if (init.environ_map.get("REX_SERVER")) |server| {
        candidates = core.endpoint.parse(server) catch return fail(io, "REX_SERVER is not an address\n");
    }
    var ep: core.endpoint.Endpoint = undefined;
    const ctl = try control.connectAny(gpa, io, candidates.slice(), .{
        .info = .{ .kind = "cli", .name = "rexcat" },
    }, &ep);
    defer ctl.destroy();
    defer ctl.close();

    // Attach every session, asking for terminal data tickets, and pick the
    // ticket for our block.
    const list_msg, const list = try ctl.callTyped(struct {
        sessions: []const struct { session_id: []const u8 },
    }, "session.list", null);
    defer list_msg.deinit();
    var session_ids: std.ArrayList([]const u8) = .empty;
    defer session_ids.deinit(gpa);
    for (list.sessions) |s| try session_ids.append(gpa, s.session_id);

    const Ticket = struct {
        session_id: []const u8,
        block_id: []const u8,
        ticket: []const u8,
    };
    const boot_msg, const boot = try ctl.callTyped(struct {
        data_tickets: ?[]const Ticket = null,
    }, "session.bootstrap", .{
        .event_scope = "session",
        .attach_session_ids = session_ids.items,
        .data_tickets = &[_]struct {
            creator_name: []const u8,
            data_ref_id: []const u8,
            subprotocol: []const u8,
        }{.{
            .creator_name = "com.superlogical.terminal",
            .data_ref_id = "terminal",
            .subprotocol = core.data.terminal_subprotocol,
        }},
    });
    defer boot_msg.deinit();

    const ticket = for (boot.data_tickets orelse &.{}) |t| {
        if (std.mem.eql(u8, t.block_id, block) or std.mem.endsWith(u8, t.block_id, block)) break t;
    } else {
        return fail(io, "no terminal block with that ID in any session\n");
    };

    const dc = try core.data.DataConn.open(gpa, io, ep, ticket.ticket, core.data.terminal_subprotocol);
    defer dc.destroy();
    defer dc.close();

    const record_file: ?Io.File = if (record_path) |path| try Io.Dir.cwd().createFile(io, path, .{}) else null;
    defer if (record_file) |f| f.close(io);
    var record_buf: [16 * 1024]u8 = undefined;
    var record_writer: ?Io.File.Writer = if (record_file) |f| f.writer(io, &record_buf) else null;
    defer if (record_writer) |*w| w.interface.flush() catch {};
    if (record_writer) |*w| {
        // The nonce tells a replay which APC messages are Rex's own.
        try w.interface.print("{s} {}\n", .{ core.recording.magic, dc.welcome.nonce });
        dc.payload.tee = &w.interface;
    }

    var decoded = try dc.decodeSnapshot();
    defer decoded.deinit(gpa);
    const mirror = try core.mirror.Mirror.create(gpa, &decoded, dc.welcome.nonce);
    defer mirror.destroy();

    // The first resize message follows the snapshot right away. Read until
    // it has been applied so the size is the live one.
    while (mirror.resize_count == 0) {
        const bytes = try dc.next() orelse break;
        try mirror.feed(bytes);
    }

    if (follow_ms > 0) {
        const Follower = struct {
            fn run(d: *core.data.DataConn, m: *core.mirror.Mirror) void {
                while (true) {
                    const bytes = (d.next() catch return) orelse return;
                    m.feed(bytes) catch return;
                }
            }
        };
        const thread = try std.Thread.spawn(.{}, Follower.run, .{ dc, mirror });
        try io.sleep(.fromMilliseconds(follow_ms), .awake);
        dc.shutdown();
        thread.join();
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const formatter: ghostty_vt.formatter.TerminalFormatter = .init(
        &mirror.terminal,
        if (emit_vt) .vt else .plain,
    );
    try stdout.interface.print("{f}\n", .{formatter});
    try stdout.interface.flush();

    std.log.info("{}x{} cells, owner {s}, nonce {}", .{
        mirror.terminal.cols, mirror.terminal.rows, mirror.owner() orelse "none", dc.welcome.nonce,
    });
    return 0;
}

fn fail(io: Io, msg: []const u8) u8 {
    var buf: [256]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    stderr.interface.writeAll(msg) catch {};
    stderr.interface.flush() catch {};
    return 2;
}
