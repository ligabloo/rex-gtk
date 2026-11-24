//! Stands in for Ghostty's src/input/key.zig (used by input/keycodes.zig),
//! re-exporting the `ghostty-vt` module's key enum.

pub const Key = @import("ghostty-vt").input.Key;
