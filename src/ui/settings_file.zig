//! The settings file's format, kept free of GTK so it can be tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// Parse a settings file. Anything but a JSON object is an error.
pub fn parse(arena: Allocator, text: []const u8) !json.ObjectMap {
    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    if (root != .object) return error.NotAnObject;
    return root.object;
}

/// The file's text for `values`, indented, with a final newline.
pub fn stringify(gpa: Allocator, values: json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try json.Stringify.value(json.Value{ .object = values }, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "round trip keeps keys we don't know" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var values = try parse(a,
        \\{"ssh.agent": "custom", "future.thing": [1, 2], "flag": true}
    );
    try values.put(a, "ssh.agent_path", .{ .string = "/x.sock" });
    const text = try stringify(std.testing.allocator, values);
    defer std.testing.allocator.free(text);

    const again = try parse(a, text);
    try std.testing.expectEqualStrings("custom", again.get("ssh.agent").?.string);
    try std.testing.expectEqualStrings("/x.sock", again.get("ssh.agent_path").?.string);
    try std.testing.expectEqual(2, again.get("future.thing").?.array.items.len);
    try std.testing.expect(again.get("flag").?.bool);
    try std.testing.expect(std.mem.endsWith(u8, text, "}\n"));
}

test "a file that isn't an object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotAnObject, parse(arena.allocator(), "[1]"));
    try std.testing.expect(std.meta.isError(parse(arena.allocator(), "{")));
}
