//! A local copy of one Rex terminal, built from its data stream.
//!
//! The terminal is a mirror: it uses Ghostty's read-only VT stream, so it
//! never answers queries (the server's terminal already did). Its size only
//! changes when the stream says so, with a `resize` message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const Filter = @import("stream_filter.zig").Filter;

const log = std.log.scoped(.mirror);

pub const Theme = struct {
    foreground: ?ghostty_vt.color.RGB = null,
    background: ?ghostty_vt.color.RGB = null,
    cursor: ?ghostty_vt.color.RGB = null,
    /// Changes to the 256-color palette.
    palette: [256]?ghostty_vt.color.RGB = @splat(null),
    /// "light", "dark", or null to decide from the background.
    dark: ?bool = null,
};

pub const Mirror = struct {
    gpa: Allocator,
    terminal: Terminal,
    stream: ghostty_vt.TerminalStream,
    filter: Filter,

    theme: Theme = .{},
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    /// The client whose size the terminal has, from the latest resize.
    owner_buf: [64]u8 = undefined,
    owner_len: usize = 0,
    exit_code: ?i64 = null,
    /// How many resize messages have arrived. The first follows the snapshot.
    resize_count: u32 = 0,

    /// Build a mirror from a decoded snapshot. Takes ownership of the
    /// terminal and replays its continuation. Heap-allocated because the
    /// VT stream points at the terminal.
    pub fn create(
        gpa: Allocator,
        decoded: *ghostty_vt.snapshot.Decoded,
        nonce: u64,
    ) !*Mirror {
        const self = try gpa.create(Mirror);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .terminal = decoded.toOwned(),
            .stream = undefined,
            .filter = .init(nonce),
        };
        self.stream = self.terminal.vtStream();

        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| self.stream.nextSlice(bytes),
        }
        return self;
    }

    pub fn destroy(self: *Mirror) void {
        const gpa = self.gpa;
        self.stream.deinit();
        self.terminal.deinit(gpa);
        self.filter.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn owner(self: *const Mirror) ?[]const u8 {
        return if (self.owner_len == 0) null else self.owner_buf[0..self.owner_len];
    }

    /// Feed bytes from the data stream that came after the snapshot.
    pub fn feed(self: *Mirror, bytes: []const u8) !void {
        try self.filter.feed(self.gpa, bytes, self);
    }

    // Filter handler.

    pub fn vt(self: *Mirror, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
    }

    pub fn message(self: *Mirror, text: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const Message = struct {
            type: []const u8,
            cols: ?u16 = null,
            rows: ?u16 = null,
            cell_width_px: u32 = 0,
            cell_height_px: u32 = 0,
            owner: ?[]const u8 = null,
            foreground: ?[]const u8 = null,
            background: ?[]const u8 = null,
            cursor: ?[]const u8 = null,
            palette: ?[]const []const u8 = null,
            scheme: ?[]const u8 = null,
            exit_code: ?i64 = null,
        };
        const msg = std.json.parseFromSliceLeaky(Message, arena.allocator(), text, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("bad rex message ({}): {s}", .{ err, text });
            return;
        };

        if (std.mem.eql(u8, msg.type, "resize")) {
            const cols = msg.cols orelse return;
            const rows = msg.rows orelse return;
            self.cell_width_px = msg.cell_width_px;
            self.cell_height_px = msg.cell_height_px;
            self.owner_len = copyInto(&self.owner_buf, msg.owner orelse "");
            self.resize_count += 1;
            if (cols != self.terminal.cols or rows != self.terminal.rows) {
                try self.terminal.resize(self.gpa, .{
                    .cols = cols,
                    .rows = rows,
                    .cell_size_px = if (msg.cell_width_px > 0 and msg.cell_height_px > 0) .{
                        .width = msg.cell_width_px,
                        .height = msg.cell_height_px,
                    } else null,
                });
            }
        } else if (std.mem.eql(u8, msg.type, "theme")) {
            var theme: Theme = .{
                .foreground = parseHex(msg.foreground),
                .background = parseHex(msg.background),
                .cursor = parseHex(msg.cursor),
            };
            if (msg.palette) |entries| for (entries) |entry| {
                const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                const index = std.fmt.parseInt(u8, entry[0..eq], 10) catch continue;
                theme.palette[index] = parseHex(entry[eq + 1 ..]);
            };
            if (msg.scheme) |s| theme.dark = if (std.mem.eql(u8, s, "light")) false else if (std.mem.eql(u8, s, "dark")) true else null;
            try self.applyTheme(theme);
        } else if (std.mem.eql(u8, msg.type, "child_exited")) {
            self.exit_code = msg.exit_code orelse -1;
        }
        // Unknown types are skipped, as the protocol asks.
    }

    /// Each theme replaces the one before it.
    fn applyTheme(self: *Mirror, theme: Theme) !void {
        self.theme = theme;
        const colors = &self.terminal.colors;
        colors.foreground.default = theme.foreground;
        colors.background.default = theme.background;
        colors.cursor.default = theme.cursor;

        // Ghostty keeps colors a program changed when the default changes.
        var palette = ghostty_vt.color.default;
        for (&palette, theme.palette) |*c, maybe| {
            if (maybe) |v| c.* = v;
        }
        try colors.palette.changeDefault(self.gpa, palette);
    }
};

fn parseHex(maybe: ?[]const u8) ?ghostty_vt.color.RGB {
    var s = maybe orelse return null;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    const v = std.fmt.parseInt(u24, s, 16) catch return null;
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

fn copyInto(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

test "parseHex" {
    const c = parseHex("#d6deeb").?;
    try std.testing.expectEqual(@as(u8, 0xd6), c.r);
    try std.testing.expectEqual(@as(u8, 0xeb), c.b);
    try std.testing.expect(parseHex("xyz") == null);
    try std.testing.expect(parseHex(null) == null);
}
