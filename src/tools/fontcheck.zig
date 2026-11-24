//! fontcheck: load the terminal font the way rex-gtk does and rasterize a
//! few glyphs, without any GPU. A smoke test for the ghostty-font module.
//!
//!   fontcheck [FAMILY] [SIZE]

const std = @import("std");
const render = @import("render");
const gf = render.ghostty;
const font = gf.font;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    gf.global.init(init.io, init.minimal.environ);

    var family: ?[:0]const u8 = null;
    var size: f32 = 11;
    {
        var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = args.skip();
        if (args.next()) |a| family = a;
        if (args.next()) |a| size = try std.fmt.parseFloat(f32, a);
    }

    const fonts = try render.fonts.Fonts.create(gpa, .{ .family = family, .size_points = size });
    defer fonts.destroy();

    const cell = fonts.cellSize();
    std.log.info("cell {}x{} px", .{ cell.width, cell.height });

    // ASCII, a box-drawing sprite, a powerline sprite, CJK, a Nerd Font icon
    // and a color emoji: each takes a different path through the grid.
    const samples = [_]struct { []const u8, u21 }{
        .{ "A", 'A' },
        .{ "box ┼", 0x253C },
        .{ "powerline ", 0xE0B0 },
        .{ "cjk 日", 0x65E5 },
        .{ "nerd ", 0xF07B },
        .{ "emoji 🦖", 0x1F996 },
    };
    for (samples) |s| {
        const name, const cp = s;
        const index = try fonts.grid.getIndex(gpa, cp, .regular, null) orelse {
            std.log.warn("{s}: no font has U+{X:0>4}", .{ name, cp });
            continue;
        };
        // Sprites are looked up by codepoint; real faces by glyph ID, which
        // the shaper provides when rendering (here we ask the face).
        const glyph_id: u32 = if (index.special() != null) cp else glyph: {
            const face = try fonts.grid.resolver.collection.getFace(index);
            break :glyph face.glyphIndex(cp) orelse 0;
        };
        const r = try fonts.grid.renderGlyph(gpa, index, glyph_id, .{
            .grid_metrics = fonts.grid.metrics,
        });
        std.log.info("{s}: {}x{} at atlas ({},{}), {t}", .{
            name, r.glyph.width, r.glyph.height, r.glyph.atlas_x, r.glyph.atlas_y, r.presentation,
        });
    }
    std.log.info("atlases: grayscale {}px, color {}px", .{
        fonts.grid.atlas_grayscale.size, fonts.grid.atlas_color.size,
    });
    return 0;
}
