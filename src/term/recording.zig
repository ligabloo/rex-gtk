//! Recorded terminal data streams, for replaying without a server.
//!
//! A recording is one header line, `REXREC1 <nonce>\n`, followed by every
//! byte of a terminal data stream after the WELCOME: the snapshot, then the
//! live output. `rexcat --record` writes them; `rexshot` replays them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Mirror = @import("mirror.zig").Mirror;

pub const magic = "REXREC1";

pub const Header = struct {
    nonce: u64,
    /// The stream bytes after the header line.
    stream: []const u8,
};

pub fn parse(bytes: []const u8) !Header {
    const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.NotARecording;
    var it = std.mem.tokenizeScalar(u8, bytes[0..nl], ' ');
    if (!std.mem.eql(u8, it.next() orelse "", magic)) return error.NotARecording;
    const nonce = std.fmt.parseInt(u64, it.next() orelse return error.NotARecording, 10) catch
        return error.NotARecording;
    return .{ .nonce = nonce, .stream = bytes[nl + 1 ..] };
}

/// Rebuild the terminal a recording ends with.
pub fn replay(gpa: Allocator, io: std.Io, bytes: []const u8) !*Mirror {
    const header = try parse(bytes);
    var reader: std.Io.Reader = .fixed(header.stream);
    var decoded = try ghostty_vt.snapshot.decode(gpa, io, &reader, .{
        .max_continuation_bytes = 1024 * 1024,
        .kitty_image_storage_limit = 0,
    });
    defer decoded.deinit(gpa);
    const mirror = try Mirror.create(gpa, &decoded, header.nonce);
    errdefer mirror.destroy();
    try mirror.feed(reader.buffered());
    return mirror;
}

test "parse header" {
    const h = try parse("REXREC1 42\nabc");
    try std.testing.expectEqual(42, h.nonce);
    try std.testing.expectEqualStrings("abc", h.stream);
    try std.testing.expectError(error.NotARecording, parse("nope\n"));
}
