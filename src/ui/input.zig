//! Translate GDK input events into Rex's `client.key` key events.
//!
//! Rex names the physical key after its W3C code, which on Linux comes from
//! the xkb keycode (GDK's hardware keycode) via Ghostty's keycode table. The
//! server encodes keys for the program, so the client only describes them.

const std = @import("std");
const gdk = @import("gdk");
const render = @import("render");

const keycodes = render.ghostty.keycodes;

/// The JSON shape `client.key` takes under `key`.
pub const KeyEvent = struct {
    key: []const u8,
    mods: []const u8,
    consumed_mods: []const u8,
    text: []const u8,
    unshifted_codepoint: u32,
    composing: bool,
    action: []const u8,
};

/// The Rex name of the key with this xkb keycode, or "unidentified".
pub fn keyName(keycode: u32) []const u8 {
    for (keycodes.entries) |entry| {
        if (entry.native == keycode) return @tagName(entry.key);
    }
    return "unidentified";
}

/// Write modifiers in Rex's order: shift, ctrl, alt, super, caps_lock.
pub fn formatMods(buf: []u8, state: gdk.ModifierType) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    const names = [_]struct { bool, []const u8 }{
        .{ state.shift_mask, "shift" },
        .{ state.control_mask, "ctrl" },
        .{ state.alt_mask, "alt" },
        .{ state.super_mask, "super" },
        .{ state.lock_mask, "caps_lock" },
    };
    for (names) |entry| {
        const on, const name = entry;
        if (!on) continue;
        if (!first) w.writeByte('+') catch break;
        w.writeAll(name) catch break;
        first = false;
    }
    return w.buffered();
}

/// The code point the key types with no modifiers in the event's layout,
/// such as 'n' for ctrl+N or '1' for shift+1. 0 if none.
pub fn unshiftedCodepoint(display: *gdk.Display, keycode: u32, layout: u32) u32 {
    var keyval: c_uint = 0;
    if (display.translateKey(keycode, .{}, @intCast(layout), &keyval, null, null, null) == 0) return 0;
    return gdk.keyvalToUnicode(keyval);
}

/// The text a key types, as UTF-8, when the input method didn't commit any.
/// Control characters and keys that type nothing give "".
pub fn keyvalText(buf: *[4]u8, keyval: u32) []const u8 {
    const cp = gdk.keyvalToUnicode(keyval);
    if (cp < 0x20 or cp == 0x7f) return "";
    const n = std.unicode.utf8Encode(@intCast(cp), buf) catch return "";
    return buf[0..n];
}

test "keyName maps xkb keycodes" {
    // xkb keycode 38 is the A key, 36 is Enter.
    try std.testing.expectEqualStrings("key_a", keyName(38));
    try std.testing.expectEqualStrings("enter", keyName(36));
    try std.testing.expectEqualStrings("unidentified", keyName(0));
}
