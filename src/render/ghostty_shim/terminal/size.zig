//! Stands in for Ghostty's src/terminal/size.zig (used by renderer/size.zig),
//! re-exporting the `ghostty-vt` module's definitions.

const vt = @import("ghostty-vt");

pub const CellCountInt = vt.size.CellCountInt;
