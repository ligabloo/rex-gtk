//! rexshot: render a recorded terminal stream with the GPU renderer and
//! save it as a PNG. Needs a GPU driver with EGL, but no display.
//!
//!   rexshot RECORDING OUT.png [--font FAMILY] [--size POINTS]
//!
//! Make a recording with `rexcat BLOCK --record RECORDING`.

const std = @import("std");
const Io = std.Io;
const render = @import("render");
const core = @import("core");
const gh = render.ghostty;

const usage = "usage: rexshot RECORDING OUT.png [--font FAMILY] [--size POINTS]\n";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    gh.global.init(io, init.minimal.environ);

    var positional: [2][]const u8 = undefined;
    var n_positional: usize = 0;
    var family: ?[:0]const u8 = null;
    var size: f32 = 11;
    {
        var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--font")) {
                family = args.next() orelse return fail(io, usage);
            } else if (std.mem.eql(u8, arg, "--size")) {
                size = try std.fmt.parseFloat(f32, args.next() orelse return fail(io, usage));
            } else if (n_positional < 2) {
                positional[n_positional] = arg;
                n_positional += 1;
            } else return fail(io, usage);
        }
    }
    if (n_positional != 2) return fail(io, usage);

    const bytes = try Io.Dir.cwd().readFileAlloc(io, positional[0], gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(bytes);
    const mirror = try core.recording.replay(gpa, io, bytes);
    defer mirror.destroy();

    const gpu = try render.renderer.Gpu.create(gpa);
    defer gpu.destroy();
    const fonts = try render.fonts.Fonts.create(gpa, .{ .family = family, .size_points = size });
    defer fonts.destroy();
    var r = try render.renderer.Renderer.init(gpa, gpu, fonts, .{});
    defer r.deinit();

    try r.update(&mirror.terminal, true);
    const px = r.sizeForGrid(mirror.terminal.cols, mirror.terminal.rows);
    const target = try r.draw(px.width, px.height);

    // GL reads rows bottom-up; PNG wants them top-down.
    const pixels = try target.readPixelsAlloc(gpa);
    defer gpa.free(pixels);
    const stride = @as(usize, px.width) * 4;
    var y: usize = 0;
    while (y < px.height / 2) : (y += 1) {
        const a = pixels[y * stride ..][0..stride];
        const b = pixels[(px.height - 1 - y) * stride ..][0..stride];
        for (a, b) |*pa, *pb| std.mem.swap(u8, pa, pb);
    }

    const out = try Io.Dir.cwd().createFile(io, positional[1], .{});
    defer out.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = out.writer(io, &buf);
    try render.png.write(&w.interface, px.width, px.height, pixels);
    try w.interface.flush();

    std.log.info("{}x{} cells -> {}x{} px: {s}", .{
        mirror.terminal.cols, mirror.terminal.rows, px.width, px.height, positional[1],
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
