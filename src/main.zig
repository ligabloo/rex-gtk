//! rex-gtk: a GTK client for Rex.
//!
//!   rex-gtk [--session [HOST:]ID|LABEL] [--font FAMILY] [--font-size POINTS] [--label LABEL]

const std = @import("std");
const core = @import("core");
const render = @import("render");
const app_mod = @import("ui/app.zig");
const App = app_mod.App;

const usage =
    \\usage: rex-gtk [--session [HOST:]ID|LABEL] [--font FAMILY] [--font-size POINTS] [--label LABEL]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    // Ghostty's font code reads the process's I/O and environment.
    render.ghostty.global.init(io, init.minimal.environ);

    var options: app_mod.Options = .{};
    {
        var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--session")) {
                options.session = args.next() orelse return fail(usage);
            } else if (std.mem.eql(u8, arg, "--font")) {
                options.font_family = args.next() orelse return fail(usage);
            } else if (std.mem.eql(u8, arg, "--font-size")) {
                options.font_size = std.fmt.parseFloat(f32, args.next() orelse return fail(usage)) catch return fail(usage);
            } else if (std.mem.eql(u8, arg, "--dump-frame")) {
                options.dump_frame = args.next() orelse return fail(usage);
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                options.screenshot = args.next() orelse return fail(usage);
            } else if (std.mem.eql(u8, arg, "--label")) {
                options.label = args.next() orelse return fail(usage);
            } else return fail(usage);
        }
    }

    // Name this client after the machine unless told otherwise, so
    // `rex -C <hostname> do …` reaches it.
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname: ?[]const u8 = std.posix.gethostname(&host_buf) catch null;

    // This computer's server: REX_SERVER if set, as the rex CLI does.
    const env = init.environ_map;
    const socket_path = try core.control.defaultSocketPath(gpa, env);
    defer gpa.free(socket_path);
    const local_address = if (env.get("REX_SERVER")) |s|
        try gpa.dupe(u8, s)
    else
        try std.fmt.allocPrint(gpa, "unix://{s}", .{socket_path});
    defer gpa.free(local_address);

    const config_home: ?[]u8 = if (env.get("XDG_CONFIG_HOME")) |c|
        try gpa.dupe(u8, c)
    else if (env.get("HOME")) |h|
        try std.fs.path.join(gpa, &.{ h, ".config" })
    else
        null;
    defer if (config_home) |c| gpa.free(c);

    const app = try App.create(gpa, io, .{
        .local_address = local_address,
        .config_home = config_home,
        .hostname = hostname,
        .ssh_env = .{
            .ssh_auth_sock = env.get("SSH_AUTH_SOCK"),
            .xdg_runtime_dir = env.get("XDG_RUNTIME_DIR"),
            .home = env.get("HOME"),
        },
    }, options);
    defer app.destroy();
    return app.run();
}

fn fail(msg: []const u8) u8 {
    std.debug.print("{s}", .{msg});
    return 2;
}
