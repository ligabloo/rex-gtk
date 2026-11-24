//! Terminal rendering: fonts and the OpenGL renderer, built on Ghostty's
//! font stack and renderer. GTK-free.

pub const fonts = @import("fonts.zig");
pub const renderer = @import("renderer.zig");
pub const png = @import("png.zig");
pub const ghostty = @import("ghostty-render");

test {
    @import("std").testing.refAllDecls(@This());
}
