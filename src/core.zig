//! GTK-free core: networking, the Rex protocol, the session model and the
//! terminal mirrors. Everything here is unit-testable without a display.

const std = @import("std");

pub const ghostty_vt = @import("ghostty-vt");
pub const ws = @import("net/ws.zig");
pub const control = @import("net/control.zig");
pub const data = @import("net/data.zig");
pub const stream_filter = @import("term/stream_filter.zig");
pub const mirror = @import("term/mirror.zig");
pub const recording = @import("term/recording.zig");

test {
    std.testing.refAllDecls(@This());
}

test "libghostty-vt is linked" {
    var t: ghostty_vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("rex");
    const str = try t.plainString(std.testing.allocator);
    defer std.testing.allocator.free(str);
    try std.testing.expectEqualStrings("rex", str);
}
