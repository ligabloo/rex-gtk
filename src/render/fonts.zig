//! The terminal font: one family at one size, with Ghostty's fallbacks.
//!
//! This replaces Ghostty's SharedGridSet, which builds grids from Ghostty's
//! full configuration. The collection is built the same way as
//! SharedGridSet.collection in the pinned Ghostty source: the configured
//! family in each style, then the embedded JetBrains Mono, the Nerd Font
//! symbols and the Noto emoji fonts as fallbacks, with fontconfig discovery
//! for anything still missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gf = @import("ghostty-render");
const font = gf.font;

const log = std.log.scoped(.fonts);

pub const Settings = struct {
    /// Font family, such as "JetBrains Mono". Null uses the embedded
    /// JetBrains Mono.
    family: ?[:0]const u8 = null,
    /// Size in points.
    size_points: f32 = 11,
    /// Screen DPI, already multiplied by the display's scale factor.
    dpi: u16 = 96,
};

/// A loaded font grid plus what it needs to stay alive. Shared by every
/// terminal using the same settings; ref-counted by the caller.
pub const Fonts = struct {
    gpa: Allocator,
    library: font.Library,
    discover: font.Discover,
    grid: font.SharedGrid,

    pub fn create(gpa: Allocator, settings: Settings) !*Fonts {
        const self = try gpa.create(Fonts);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.library = try font.Library.init(gpa);
        errdefer self.library.deinit();
        self.discover = .init(self.library);
        errdefer self.discover.deinit();

        const size: font.face.DesiredSize = .{
            .points = settings.size_points,
            .xdpi = settings.dpi,
            .ydpi = settings.dpi,
        };
        var collection = try buildCollection(gpa, self.library, &self.discover, settings.family, size);
        errdefer collection.deinit(gpa);

        self.grid = try .init(gpa, .{
            .collection = collection,
            .discover = &self.discover,
        });
        return self;
    }

    pub fn destroy(self: *Fonts) void {
        const gpa = self.gpa;
        self.grid.deinit(gpa);
        self.discover.deinit();
        self.library.deinit();
        gpa.destroy(self);
    }

    pub fn cellSize(self: *Fonts) gf.renderer.CellSize {
        return self.grid.cellSize();
    }
};

fn buildCollection(
    gpa: Allocator,
    lib: font.Library,
    disco: *font.Discover,
    family: ?[:0]const u8,
    size: font.face.DesiredSize,
) !font.Collection {
    const load_options: font.Collection.LoadOptions = .{
        .library = lib,
        .size = size,
    };
    var c = font.Collection.init();
    errdefer c.deinit(gpa);
    c.load_options = load_options;

    if (family) |name| {
        var name_buf: [256]u8 = undefined;
        inline for (@typeInfo(font.Style).@"enum".field_names) |field| {
            const style = @field(font.Style, field);
            var it = try disco.discover(gpa, .{
                .family = name,
                .size = size.points,
                .bold = style == .bold or style == .bold_italic,
                .italic = style == .italic or style == .bold_italic,
                .monospace = false,
            });
            defer it.deinit();
            if (try it.next()) |face| {
                log.info("font {s}: {s}", .{ field, face.name(&name_buf) catch "?" });
                _ = try c.addDeferred(gpa, face, .{
                    .style = style,
                    .fallback = false,
                    .size_adjustment = .none,
                });
            } else if (style == .regular) {
                log.warn("font family not found: {s}", .{name});
            }
        }
    }

    try c.completeStyles(gpa, .{});

    // Built-in fallbacks, in the same order as Ghostty.
    const face_options = load_options.faceOptions();
    _ = try c.add(gpa, try .init(lib, font.embedded.variable, face_options), .{
        .style = .regular,
        .fallback = true,
        .size_adjustment = font.default_fallback_adjustment,
    });
    try (try c.getFace(try c.add(gpa, try .init(lib, font.embedded.variable, face_options), .{
        .style = .bold,
        .fallback = true,
        .size_adjustment = font.default_fallback_adjustment,
    }))).setVariations(&.{.{ .id = .init("wght"), .value = 700 }}, face_options);
    _ = try c.add(gpa, try .init(lib, font.embedded.variable_italic, face_options), .{
        .style = .italic,
        .fallback = true,
        .size_adjustment = font.default_fallback_adjustment,
    });
    try (try c.getFace(try c.add(gpa, try .init(lib, font.embedded.variable_italic, face_options), .{
        .style = .bold_italic,
        .fallback = true,
        .size_adjustment = font.default_fallback_adjustment,
    }))).setVariations(&.{.{ .id = .init("wght"), .value = 700 }}, face_options);
    _ = try c.add(gpa, try .init(lib, font.embedded.symbols_nerd_font, face_options), .{
        .style = .regular,
        .fallback = true,
        .size_adjustment = .none,
    });
    _ = try c.add(gpa, try .init(lib, font.embedded.emoji, face_options), .{
        .style = .regular,
        .fallback = true,
        .size_adjustment = .none,
    });
    _ = try c.add(gpa, try .init(lib, font.embedded.emoji_text, face_options), .{
        .style = .regular,
        .fallback = true,
        .size_adjustment = .none,
    });
    return c;
}
