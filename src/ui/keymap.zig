//! Key bindings, spelled the way Rex spells them (`ctrl+shift+t`,
//! `ctrl+pageup`, `cmd+[KeyK]`), and matching them against key presses.
//!
//! The built-in bindings are `defaults`. The server combines them with the
//! user's configuration file (see `client.keymap`), so the same spelling is
//! used for both.

const std = @import("std");

pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    fn eql(a: Mods, b: Mods) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }
};

/// A key press, as the matcher needs it.
pub const Press = struct {
    /// The physical key, in snake_case W3C naming (`key_t`, `arrow_left`).
    physical: []const u8,
    mods: Mods,
    /// What the key types without modifiers in the current layout, or 0.
    unshifted: u21,
    /// What the key types with the modifiers held, or 0.
    shifted: u21,
};

/// One key of a binding, parsed.
pub const Key = struct {
    mods: Mods,
    key: union(enum) {
        /// A character, following the keyboard layout.
        char: u21,
        /// A physical key, by its snake_case name.
        physical: []const u8,
    },

    pub fn parse(spec: []const u8) ?Key {
        if (spec.len == 0) return null;
        // The key is what follows the last `+`, except that `ctrl++` binds `+`.
        const split: usize = if (std.mem.endsWith(u8, spec, "++"))
            spec.len - 1
        else if (std.mem.lastIndexOfScalar(u8, spec, '+')) |i| i + 1 else 0;
        const key_part = spec[split..];
        var mods: Mods = .{};
        if (split > 0) {
            var it = std.mem.splitScalar(u8, spec[0 .. split - 1], '+');
            while (it.next()) |m| {
                if (std.mem.eql(u8, m, "shift")) mods.shift = true else if (std.mem.eql(u8, m, "ctrl") or std.mem.eql(u8, m, "control")) mods.ctrl = true else if (std.mem.eql(u8, m, "alt") or std.mem.eql(u8, m, "opt") or std.mem.eql(u8, m, "option")) mods.alt = true else if (std.mem.eql(u8, m, "cmd") or std.mem.eql(u8, m, "super")) mods.super = true else return null;
            }
        }
        if (key_part.len == 0) return null;

        // [KeyK]: a physical key by its W3C code.
        if (key_part[0] == '[' and key_part[key_part.len - 1] == ']') {
            return .{ .mods = mods, .key = .{ .physical = key_part[1 .. key_part.len - 1] } };
        }
        // One character.
        const view = std.unicode.Utf8View.init(key_part) catch return null;
        var cps = view.iterator();
        const first = cps.nextCodepoint() orelse return null;
        if (cps.nextCodepoint() == null) return .{ .mods = mods, .key = .{ .char = std.ascii.toLower(@intCast(@min(first, 127))) } };
        // A named key.
        return .{ .mods = mods, .key = .{ .physical = namedKey(key_part) orelse key_part } };
    }

    pub fn matches(self: Key, press: Press) bool {
        switch (self.key) {
            .physical => |name| {
                if (!self.mods.eql(press.mods)) return false;
                if (std.mem.eql(u8, name, press.physical)) return true;
                return w3cMatches(name, press.physical);
            },
            .char => |c| {
                if (press.unshifted != 0 and lower(press.unshifted) == c and self.mods.eql(press.mods)) return true;
                // `ctrl++` is ctrl+shift+= on a US layout: the shift that
                // types the character doesn't count.
                if (press.shifted != 0 and press.shifted != press.unshifted and !isLetter(press.shifted) and press.shifted == c) {
                    var a = self.mods;
                    var b = press.mods;
                    a.shift = false;
                    b.shift = false;
                    return a.eql(b);
                }
                return false;
            },
        }
    }
};

fn lower(c: u21) u21 {
    return if (c < 128) std.ascii.toLower(@intCast(c)) else c;
}

/// Rex's names for keys that don't type a character, mapped to physical keys.
fn namedKey(name: []const u8) ?[]const u8 {
    const table = .{
        .{ "left", "arrow_left" },   .{ "right", "arrow_right" }, .{ "up", "arrow_up" },
        .{ "down", "arrow_down" },   .{ "pageup", "page_up" },    .{ "pagedown", "page_down" },
        .{ "page_up", "page_up" },   .{ "page_down", "page_down" }, .{ "esc", "escape" },
        .{ "return", "enter" },      .{ "del", "delete" },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

/// Whether a W3C code such as KeyK or ArrowLeft names the same key as a
/// snake_case name such as key_k or arrow_left.
fn w3cMatches(code: []const u8, snake: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var alpha_run: usize = 0;
    for (code, 0..) |c, i| {
        if (n + 2 > buf.len) return false;
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                buf[n] = '_';
                n += 1;
            }
            buf[n] = std.ascii.toLower(c);
            alpha_run = 1;
        } else if (std.ascii.isDigit(c)) {
            // Digit1 → digit_1 and Numpad1 → numpad_1, but F1 → f1.
            if (alpha_run > 1) {
                buf[n] = '_';
                n += 1;
            }
            buf[n] = c;
            alpha_run = 0;
        } else {
            buf[n] = c;
            alpha_run += 1;
        }
        n += 1;
    }
    return std.mem.eql(u8, buf[0..n], snake);
}

pub const Binding = struct {
    /// One element per key of a sequence.
    keys: []const []const u8,
    action: []const u8,
    /// The action's arguments as JSON, or null.
    args: ?[]const u8 = null,
    /// The mode the binding belongs to, if any (see `client.keymap`).
    mode: ?[]const u8 = null,
};

/// Built-in bindings, following Linux terminal conventions (Ctrl+Shift for
/// app shortcuts, so plain Ctrl keys reach programs).
pub const defaults = [_]Binding{
    .{ .keys = &.{"ctrl+shift+t"}, .action = "client.tab.new" },
    .{ .keys = &.{"ctrl+pagedown"}, .action = "client.tab.next" },
    .{ .keys = &.{"ctrl+pageup"}, .action = "client.tab.previous" },
    .{ .keys = &.{"ctrl+tab"}, .action = "client.tab.next" },
    .{ .keys = &.{"ctrl+shift+tab"}, .action = "client.tab.previous" },
    .{ .keys = &.{"ctrl+shift+pagedown"}, .action = "client.tab.move.forward" },
    .{ .keys = &.{"ctrl+shift+pageup"}, .action = "client.tab.move.backward" },
    .{ .keys = &.{"alt+1"}, .action = "client.tab.goto", .args = "{\"index\":1}" },
    .{ .keys = &.{"alt+2"}, .action = "client.tab.goto", .args = "{\"index\":2}" },
    .{ .keys = &.{"alt+3"}, .action = "client.tab.goto", .args = "{\"index\":3}" },
    .{ .keys = &.{"alt+4"}, .action = "client.tab.goto", .args = "{\"index\":4}" },
    .{ .keys = &.{"alt+5"}, .action = "client.tab.goto", .args = "{\"index\":5}" },
    .{ .keys = &.{"alt+6"}, .action = "client.tab.goto", .args = "{\"index\":6}" },
    .{ .keys = &.{"alt+7"}, .action = "client.tab.goto", .args = "{\"index\":7}" },
    .{ .keys = &.{"alt+8"}, .action = "client.tab.goto", .args = "{\"index\":8}" },
    .{ .keys = &.{"alt+9"}, .action = "client.tab.goto", .args = "{\"index\":-1}" },
    .{ .keys = &.{"ctrl+shift+o"}, .action = "pane.split.right" },
    .{ .keys = &.{"ctrl+shift+e"}, .action = "pane.split.down" },
    .{ .keys = &.{"ctrl+shift+w"}, .action = "pane.close" },
    .{ .keys = &.{"ctrl+shift+enter"}, .action = "pane.zoom" },
    .{ .keys = &.{"ctrl+alt+left"}, .action = "pane.focus.left" },
    .{ .keys = &.{"ctrl+alt+right"}, .action = "pane.focus.right" },
    .{ .keys = &.{"ctrl+alt+up"}, .action = "pane.focus.up" },
    .{ .keys = &.{"ctrl+alt+down"}, .action = "pane.focus.down" },
    .{ .keys = &.{"ctrl+shift+]"}, .action = "pane.focus_next" },
    .{ .keys = &.{"ctrl+shift+["}, .action = "pane.focus_previous" },
    .{ .keys = &.{"ctrl+shift+c"}, .action = "pane.copy" },
    .{ .keys = &.{"ctrl+shift+v"}, .action = "pane.paste" },
    .{ .keys = &.{"ctrl+shift+a"}, .action = "pane.select_all" },
    .{ .keys = &.{"shift+pageup"}, .action = "client.scroll.page_up" },
    .{ .keys = &.{"shift+pagedown"}, .action = "client.scroll.page_down" },
    .{ .keys = &.{"ctrl+shift+n"}, .action = "session.new" },
    .{ .keys = &.{"ctrl+alt+pagedown"}, .action = "session.next" },
    .{ .keys = &.{"ctrl+alt+pageup"}, .action = "session.previous" },
    .{ .keys = &.{"ctrl+shift+s"}, .action = "client.sidebar.toggle" },
    .{ .keys = &.{"ctrl+="}, .action = "client.font.increase" },
    .{ .keys = &.{"ctrl++"}, .action = "client.font.increase" },
    .{ .keys = &.{"ctrl+-"}, .action = "client.font.decrease" },
    .{ .keys = &.{"ctrl+0"}, .action = "client.font.reset" },
    .{ .keys = &.{"f11"}, .action = "client.window.fullscreen.toggle" },
    .{ .keys = &.{"ctrl+,"}, .action = "client.preferences" },
};

test "parse and match" {
    const t = std.testing;
    const k = Key.parse("ctrl+shift+t").?;
    try t.expect(k.matches(.{ .physical = "key_t", .mods = .{ .ctrl = true, .shift = true }, .unshifted = 't', .shifted = 'T' }));
    try t.expect(!k.matches(.{ .physical = "key_t", .mods = .{ .ctrl = true }, .unshifted = 't', .shifted = 't' }));

    const plus = Key.parse("ctrl++").?;
    try t.expect(plus.key.char == '+');
    try t.expect(plus.matches(.{ .physical = "equal", .mods = .{ .ctrl = true, .shift = true }, .unshifted = '=', .shifted = '+' }));

    const pgup = Key.parse("ctrl+pageup").?;
    try t.expect(pgup.matches(.{ .physical = "page_up", .mods = .{ .ctrl = true }, .unshifted = 0, .shifted = 0 }));

    const phys = Key.parse("cmd+[KeyK]").?;
    try t.expect(phys.matches(.{ .physical = "key_k", .mods = .{ .super = true }, .unshifted = 'k', .shifted = 'k' }));
    try t.expect(w3cMatches("Digit1", "digit_1"));
    try t.expect(w3cMatches("F12", "f12"));
    try t.expect(w3cMatches("ArrowLeft", "arrow_left"));
    try t.expect(w3cMatches("Numpad1", "numpad_1"));

    try t.expect(Key.parse("ctrl+bogus+x") == null);
    const f11 = Key.parse("f11").?;
    try t.expect(f11.matches(.{ .physical = "f11", .mods = .{}, .unshifted = 0, .shifted = 0 }));
}

fn isLetter(c: u21) bool {
    return c < 128 and std.ascii.isAlphabetic(@intCast(c));
}
