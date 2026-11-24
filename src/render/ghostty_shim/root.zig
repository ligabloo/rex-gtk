//! Root of the `ghostty-render` module.
//!
//! The build assembles this module from the pinned Ghostty source tree
//! (src/font, src/renderer/opengl, src/datastruct, src/unicode, ...) plus the
//! files in this directory, which replace the parts of Ghostty the font stack
//! and the OpenGL renderer would otherwise pull in (its config, global state,
//! app runtime and renderer loop). See build.zig, `addGhosttyRender`.

pub const font = @import("font/main.zig");
pub const renderer = @import("renderer.zig");
pub const global = @import("global.zig");
pub const config = @import("config.zig");
pub const math = @import("math.zig");
pub const nerd_font_attributes = @import("font/nerd_font_attributes.zig");
/// Ghostty's Zig bindings for OpenGL (glad) and EGL.
pub const gl = @import("opengl");

test {
    @import("std").testing.refAllDecls(@This());
}
