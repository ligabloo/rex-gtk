//! Stands in for Ghostty's src/build_config.zig.

/// Linux: fontconfig for discovery, FreeType for rasterizing, HarfBuzz for
/// shaping.
pub const font_backend: @import("font/backend.zig").Backend = .fontconfig_freetype;

/// Ghostty uses this to register a few types with GObject. rex-gtk doesn't
/// need them, so it reports no app runtime. The tags match Ghostty's so its
/// switches stay exhaustive.
pub const app_runtime: enum { none, gtk } = .none;
