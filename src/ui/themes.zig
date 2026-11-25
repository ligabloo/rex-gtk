//! Terminal color themes: one is used in light mode and one in dark mode.
//! Pushed to the blocks this client owns with
//! com.superlogical.terminal.set_theme.

const std = @import("std");

pub const Theme = struct {
    id: []const u8,
    name: [:0]const u8,
    dark: bool,
    foreground: []const u8,
    background: []const u8,
    cursor: []const u8,
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta,
    /// cyan, white, then their bright forms.
    palette: [16][]const u8,
};

/// GNOME's terminal palette, as in Console and Ptyxis.
const gnome_palette = [16][]const u8{
    "#241f31", "#c01c28", "#2ec27e", "#f5c211", "#1e78e4", "#9841bb", "#0ab9dc", "#c0bfbc",
    "#5e5c64", "#ed333b", "#57e389", "#f8e45c", "#51a1ff", "#c061cb", "#4fd2fd", "#f6f5f4",
};

// Adwaita view colors. Light text uses the opaque result of compositing
// libadwaita's rgb(0 0 6 / 80%) foreground over the white view.
pub const all = [_]Theme{
    .{ .id = "adwaita", .name = "Adwaita", .dark = false, .foreground = "#333338", .background = "#ffffff", .cursor = "#333338", .palette = gnome_palette },
    .{ .id = "solarized-light", .name = "Solarized Light", .dark = false, .foreground = "#657b83", .background = "#fdf6e3", .cursor = "#657b83", .palette = .{
        "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
        "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
    } },
    .{ .id = "gruvbox-light", .name = "Gruvbox Light", .dark = false, .foreground = "#3c3836", .background = "#fbf1c7", .cursor = "#3c3836", .palette = .{
        "#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64",
        "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836",
    } },
    .{ .id = "catppuccin-latte", .name = "Catppuccin Latte", .dark = false, .foreground = "#4c4f69", .background = "#eff1f5", .cursor = "#dc8a78", .palette = .{
        "#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be",
        "#6c6f85", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#bcc0cc",
    } },
    .{ .id = "adwaita-dark", .name = "Adwaita Dark", .dark = true, .foreground = "#ffffff", .background = "#1d1d20", .cursor = "#ffffff", .palette = gnome_palette },
    .{ .id = "tokyo-night", .name = "Tokyo Night", .dark = true, .foreground = "#c0caf5", .background = "#1a1b26", .cursor = "#c0caf5", .palette = .{
        "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
        "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
    } },
    .{ .id = "gruvbox-dark", .name = "Gruvbox Dark", .dark = true, .foreground = "#ebdbb2", .background = "#282828", .cursor = "#ebdbb2", .palette = .{
        "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
        "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
    } },
    .{ .id = "nord", .name = "Nord", .dark = true, .foreground = "#d8dee9", .background = "#2e3440", .cursor = "#d8dee9", .palette = .{
        "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
        "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
    } },
};

pub const default_light = "adwaita";
pub const default_dark = "adwaita-dark";

pub fn find(id: []const u8) ?*const Theme {
    for (&all) |*t| if (std.mem.eql(u8, t.id, id)) return t;
    return null;
}

/// The theme for a mode, by id, falling back to the default for it.
pub fn forMode(id: []const u8, dark: bool) *const Theme {
    if (find(id)) |t| if (t.dark == dark) return t;
    return find(if (dark) default_dark else default_light).?;
}

/// The palette as set_theme takes it: "0=#241f31" and so on.
pub fn paletteArgs(t: *const Theme, buf: *[16][12]u8, out: *[16][]const u8) void {
    for (t.palette, 0..) |color, i| {
        out[i] = std.fmt.bufPrint(&buf[i], "{d}={s}", .{ i, color }) catch "";
    }
}

pub const Rgb = [3]u8;

pub fn parseRgb(hex: []const u8) Rgb {
    const digits = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    const v = std.fmt.parseInt(u24, digits, 16) catch 0;
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

/// `a` moved `t` of the way towards `b`.
pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    var out: Rgb = undefined;
    for (&out, a, b) |*o, x, y| {
        const v = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(x))) * t;
        o.* = @intFromFloat(@round(std.math.clamp(v, 0, 255)));
    }
    return out;
}

fn hexOf(c: Rgb, buf: *[7]u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c[0], c[1], c[2] }) catch "#000000";
}

/// CSS that paints libadwaita's surfaces in a theme's colors: the window
/// and header bar take the terminal's background, and the sidebar, cards,
/// dialogs and popovers a shade towards its text color.
pub fn tintCss(t: *const Theme, out: []u8) []const u8 {
    // Let libadwaita supply the native surface colors for its own themes.
    if (std.mem.eql(u8, t.id, default_light) or std.mem.eql(u8, t.id, default_dark)) return "";

    const bg = parseRgb(t.background);
    const fg = parseRgb(t.foreground);
    var b: [6][7]u8 = undefined;
    const bg_s = hexOf(bg, &b[0]);
    const fg_s = hexOf(fg, &b[1]);
    const sidebar = hexOf(mix(bg, fg, 0.04), &b[2]);
    const dialog = hexOf(mix(bg, fg, 0.03), &b[3]);
    const card = hexOf(mix(bg, fg, 0.07), &b[4]);
    const popover = hexOf(mix(bg, fg, 0.06), &b[5]);
    return std.fmt.bufPrint(out,
        \\:root {{
        \\  --window-bg-color: {0s}; --window-fg-color: {1s};
        \\  --view-bg-color: {0s}; --view-fg-color: {1s};
        \\  --headerbar-bg-color: {0s}; --headerbar-fg-color: {1s}; --headerbar-backdrop-color: {0s};
        \\  --sidebar-bg-color: {2s}; --sidebar-fg-color: {1s}; --sidebar-backdrop-color: {2s};
        \\  --secondary-sidebar-bg-color: {2s}; --secondary-sidebar-fg-color: {1s};
        \\  --dialog-bg-color: {3s}; --dialog-fg-color: {1s};
        \\  --card-bg-color: {4s}; --card-fg-color: {1s};
        \\  --popover-bg-color: {5s}; --popover-fg-color: {1s};
        \\}}
        \\
    , .{ bg_s, fg_s, sidebar, dialog, card, popover }) catch "";
}

test "tint css" {
    try std.testing.expectEqual(Rgb{ 0x28, 0x28, 0x28 }, parseRgb("#282828"));
    try std.testing.expectEqual(Rgb{ 128, 128, 128 }, mix(.{ 0, 0, 0 }, .{ 255, 255, 255 }, 0.5));
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("", tintCss(forMode("", false), &buf));
    try std.testing.expectEqualStrings("", tintCss(forMode("", true), &buf));
    const css = tintCss(find("nord").?, &buf);
    try std.testing.expect(std.mem.indexOf(u8, css, "--window-bg-color: #2e3440;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--headerbar-fg-color: #d8dee9;") != null);
}

test "every theme is complete and well formed" {
    for (all) |t| {
        for (t.palette) |c| {
            try std.testing.expectEqual(7, c.len);
            try std.testing.expectEqual('#', c[0]);
            _ = try std.fmt.parseInt(u24, c[1..], 16);
        }
        _ = try std.fmt.parseInt(u24, t.background[1..], 16);
        _ = try std.fmt.parseInt(u24, t.foreground[1..], 16);
    }
    try std.testing.expect(forMode("nord", false).dark == false);
    try std.testing.expectEqualStrings("nord", forMode("nord", true).id);
    var buf: [16][12]u8 = undefined;
    var out: [16][]const u8 = undefined;
    paletteArgs(find("nord").?, &buf, &out);
    try std.testing.expectEqualStrings("15=#eceff4", out[15]);
}
