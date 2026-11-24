//! Stands in for Ghostty's src/global.zig. The font stack only needs the
//! process's I/O instance and environment. rex-gtk calls `init` once at
//! startup, before loading any font.

const std = @import("std");
const builtin = @import("builtin");

var state: ?struct {
    io: std.Io,
    environ: std.process.Environ,
} = null;

pub fn init(io_: std.Io, environ_: std.process.Environ) void {
    state = .{ .io = io_, .environ = environ_ };
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return (state orelse @panic("ghostty-font: global.init was not called")).io;
}

pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return (state orelse @panic("ghostty-font: global.init was not called")).environ;
}
