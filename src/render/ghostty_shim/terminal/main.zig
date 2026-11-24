//! Stands in for Ghostty's src/terminal/main.zig by re-exporting the
//! `ghostty-vt` module. Using the module, not a second copy of the source,
//! keeps these the same types as the terminals rex-gtk mirrors.

const vt = @import("ghostty-vt");

pub const Cell = vt.Cell;
pub const Style = vt.Style;
pub const RenderState = vt.RenderState;
pub const Terminal = vt.Terminal;
pub const Screen = vt.Screen;
pub const Selection = vt.Selection;
pub const Pin = vt.Pin;
pub const point = vt.point;
pub const page = vt.page;
pub const kitty = vt.kitty;
pub const color = vt.color;
pub const size = vt.size;
pub const modes = vt.modes;
pub const CursorStyle = vt.CursorStyle;
