//! Stands in for Ghostty's src/config.zig. Only the value types that the
//! font stack uses are here, copied from Ghostty's src/config/Config.zig.
//! Ghostty's full configuration is not used: rex-gtk builds its font grid
//! from its own settings (src/render/fonts.zig).

/// See `font-synthetic-style` in Ghostty's documentation.
pub const FontSyntheticStyle = packed struct {
    bold: bool = true,
    italic: bool = true,
    @"bold-italic": bool = true,
};

/// See `font-shaping-break` in Ghostty's documentation.
pub const FontShapingBreak = packed struct {
    cursor: bool = true,
};

/// See `freetype-load-flags` in Ghostty's documentation.
pub const FreetypeLoadFlags = packed struct {
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
    light: bool = true,
};
