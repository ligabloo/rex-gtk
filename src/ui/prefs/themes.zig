//! Preferences › Themes: the terminal colors used in light mode and in
//! dark mode, picked from previews.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;
const themes = @import("../themes.zig");

const preview_w = 132;
const preview_h = 64;

const Choice = struct { page: *ThemesPage, key: []const u8, id: []const u8 };

pub const ThemesPage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,
    choices: std.ArrayList(*Choice) = .empty,
    pickers: [2]*gtk.Widget = undefined,

    pub fn create(prefs: *Prefs) !*ThemesPage {
        const self = try prefs.gpa.create(ThemesPage);
        self.* = .{ .prefs = prefs, .gpa = prefs.gpa, .page = undefined };
        const s = &prefs.app.settings;
        const body = adw.PreferencesPage.new();

        const config = win.group(null, null);
        const use_config = win.switchRow("Use colors from the configuration file", "Leave the terminal's colors to your Rex configuration instead of these themes.", s.getBool("theme.use_config", false));
        win.bindSwitch(use_config, s, "theme.use_config");
        _ = gobject.Object.signals.notify.connect(use_config, *ThemesPage, &onUseConfig, self, .{ .detail = "active" });
        config.add(use_config.as(gtk.Widget));
        body.add(config);

        for ([_]bool{ false, true }, 0..) |dark, i| {
            const g = win.group(if (dark) "Dark Theme" else "Light Theme", if (dark) "Used while the app is dark." else "Used while the app is light.");
            const key = if (dark) "theme.dark" else "theme.light";
            const current = themes.forMode(s.getString(key, ""), dark).id;
            const flow = gtk.FlowBox.new();
            flow.setSelectionMode(.none);
            flow.setHomogeneous(1);
            flow.setMinChildrenPerLine(2);
            flow.setMaxChildrenPerLine(4);
            flow.setColumnSpacing(12);
            flow.setRowSpacing(12);
            var first: ?*gtk.ToggleButton = null;
            for (&themes.all) |*t| {
                if (t.dark != dark) continue;
                const c = self.card(t, key) orelse continue;
                if (first) |f| c.setGroup(f) else first = c;
                if (std.mem.eql(u8, t.id, current)) c.setActive(1);
                flow.append(c.as(gtk.Widget));
            }
            g.add(flow.as(gtk.Widget));
            body.add(g);
            self.pickers[i] = g.as(gtk.Widget);
        }
        self.page = win.navPage("Themes", body.as(gtk.Widget));
        self.updateSensitive();
        return self;
    }

    pub fn destroy(self: *ThemesPage) void {
        for (self.choices.items) |c| self.gpa.destroy(c);
        self.choices.deinit(self.gpa);
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    fn card(self: *ThemesPage, t: *const themes.Theme, key: []const u8) ?*gtk.ToggleButton {
        const choice = self.gpa.create(Choice) catch return null;
        choice.* = .{ .page = self, .key = key, .id = t.id };
        self.choices.append(self.gpa, choice) catch {
            self.gpa.destroy(choice);
            return null;
        };
        const box = gtk.Box.new(.vertical, 6);
        if (preview(self.gpa, t)) |texture| {
            const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
            picture.setCanShrink(0);
            picture.as(gtk.Widget).addCssClass("theme-preview");
            picture.as(gtk.Widget).setOverflow(.hidden);
            box.append(picture.as(gtk.Widget));
            texture.as(gobject.Object).unref();
        }
        box.append(gtk.Label.new(t.name).as(gtk.Widget));
        const button = gtk.ToggleButton.new();
        button.as(gtk.Button).setChild(box.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("theme-card");
        _ = gtk.ToggleButton.signals.toggled.connect(button, *Choice, &onToggled, choice, .{});
        return button;
    }

    fn onToggled(button: *gtk.ToggleButton, c: *Choice) callconv(.c) void {
        if (button.getActive() == 0) return;
        c.page.prefs.app.settings.setString(c.key, c.id);
    }

    fn onUseConfig(_: *adw.SwitchRow, _: *gobject.ParamSpec, self: *ThemesPage) callconv(.c) void {
        self.updateSensitive();
    }

    fn updateSensitive(self: *ThemesPage) void {
        const use_config = self.prefs.app.settings.getBool("theme.use_config", false);
        for (self.pickers) |p| p.setSensitive(@intFromBool(!use_config));
    }
};

/// A small picture of a theme: its background, a line of "text" in its
/// foreground, and its 16 colors.
fn preview(gpa: Allocator, t: *const themes.Theme) ?*gdk.Texture {
    const stride = preview_w * 3;
    const pixels = gpa.alloc(u8, stride * preview_h) catch return null;
    defer gpa.free(pixels);
    const bg = rgb(t.background);
    var i: usize = 0;
    while (i < pixels.len) : (i += 3) @memcpy(pixels[i..][0..3], &bg);
    fill(pixels, stride, 10, 10, 56, 5, rgb(t.foreground));
    fill(pixels, stride, 10, 20, 34, 5, rgb(t.palette[2]));
    fill(pixels, stride, 48, 20, 22, 5, rgb(t.palette[4]));
    for (0..8) |k| {
        fill(pixels, stride, 10 + k * 14, 34, 12, 8, rgb(t.palette[k]));
        fill(pixels, stride, 10 + k * 14, 46, 12, 8, rgb(t.palette[k + 8]));
    }
    const bytes = glib.Bytes.new(pixels.ptr, pixels.len);
    defer bytes.unref();
    return gdk.MemoryTexture.new(preview_w, preview_h, .r8g8b8, bytes, stride).as(gdk.Texture);
}

fn fill(pixels: []u8, stride: usize, x: usize, y: usize, w: usize, h: usize, color: [3]u8) void {
    for (y..y + h) |row| for (x..x + w) |col| {
        @memcpy(pixels[row * stride + col * 3 ..][0..3], &color);
    };
}

fn rgb(hex: []const u8) [3]u8 {
    const v = std.fmt.parseInt(u24, hex[1..], 16) catch 0;
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}
