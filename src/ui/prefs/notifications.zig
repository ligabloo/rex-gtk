//! Preferences › Notifications: what rex-gtk tells you about tabs you
//! aren't looking at, and what the terminal bell does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;

pub const NotificationsPage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,

    pub fn create(prefs: *Prefs) !*NotificationsPage {
        const self = try prefs.gpa.create(NotificationsPage);
        const s = &prefs.app.settings;
        const body = adw.PreferencesPage.new();

        const activity = win.group("Program Activity", "When a program in a tab you aren't looking at reports that it…");
        const rows = [_]struct { key: []const u8, title: [:0]const u8, subtitle: [:0]const u8 }{
            .{ .key = "notify.blocked", .title = "Needs you", .subtitle = "Such as an agent asking for permission or a question." },
            .{ .key = "notify.done", .title = "Finished", .subtitle = "Such as a build or an agent's task." },
            .{ .key = "notify.error", .title = "Failed", .subtitle = "Such as a deploy that stopped with an error." },
        };
        inline for (rows) |r| {
            const row = win.switchRow(r.title, r.subtitle, s.getBool(r.key, true));
            win.bindSwitch(row, s, r.key);
            activity.add(row.as(gtk.Widget));
        }
        body.add(activity);

        const bell = win.group("Terminal Bell", null);
        const mark = win.switchRow("Mark the tab", "A tab in the background that rings shows that it needs attention.", s.getBool("bell.mark_tab", true));
        win.bindSwitch(mark, s, "bell.mark_tab");
        bell.add(mark.as(gtk.Widget));
        const sound = win.switchRow("Play a sound", null, s.getBool("bell.sound", false));
        win.bindSwitch(sound, s, "bell.sound");
        bell.add(sound.as(gtk.Widget));
        body.add(bell);

        const desktop = win.group("Desktop Notifications", "rex-gtk's notifications can be turned off altogether in GNOME Settings › Apps.");
        const terminal = win.switchRow("Programs' own notifications", "Show the notifications programs send with OSC 9 and OSC 777.", s.getBool("notify.terminal", true));
        win.bindSwitch(terminal, s, "notify.terminal");
        desktop.add(terminal.as(gtk.Widget));
        body.add(desktop);

        self.* = .{
            .prefs = prefs,
            .gpa = prefs.gpa,
            .page = win.navPage("Notifications", body.as(gtk.Widget)),
        };
        return self;
    }

    pub fn destroy(self: *NotificationsPage) void {
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }
};
