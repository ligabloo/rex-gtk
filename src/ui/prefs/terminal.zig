//! Preferences › Terminal: the font, selection and scrolling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const pango = @import("pango");
const win = @import("window.zig");
const Prefs = win.Prefs;
const Settings = @import("../settings.zig").Settings;

pub const TerminalPage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,
    font_label: *gtk.Label,
    font_row: *adw.ActionRow,

    pub fn create(prefs: *Prefs) !*TerminalPage {
        const self = try prefs.gpa.create(TerminalPage);
        const app = prefs.app;
        const s = &app.settings;
        const body = adw.PreferencesPage.new();

        const font_group = win.group("Font", if (app.options.font_family != null or app.options.font_size != null) "--font or --font-size set the font for this run." else null);
        const label = gtk.Label.new("");
        const button = gtk.Button.new();
        button.setChild(label.as(gtk.Widget));
        button.as(gtk.Widget).setValign(.center);
        const font_row = win.actionRow("Font", null);
        const reset = win.iconButton("edit-undo-symbolic", "Use the Built-in Font");
        font_row.addSuffix(button.as(gtk.Widget));
        font_row.addSuffix(reset.as(gtk.Widget));
        font_group.add(font_row.as(gtk.Widget));

        const size = adw.SpinRow.newWithRange(6, 48, 1);
        size.as(adw.PreferencesRow).setTitle("Size");
        size.setValue(s.getNumber("terminal.font_size", 11));
        font_group.add(size.as(gtk.Widget));
        body.add(font_group);

        const selection = win.group("Selection", null);
        const copy = win.switchRow("Copy on select", "Selected text goes to the clipboard too, not only the primary selection that middle-click pastes.", s.getBool("terminal.copy_on_select", false));
        win.bindSwitch(copy, s, "terminal.copy_on_select");
        selection.add(copy.as(gtk.Widget));
        body.add(selection);

        const scrolling = win.group("Scrolling", null);
        const lines = adw.SpinRow.newWithRange(1, 20, 1);
        lines.as(adw.PreferencesRow).setTitle("Lines per wheel step");
        lines.setValue(s.getNumber("terminal.scroll_lines", 3));
        scrolling.add(lines.as(gtk.Widget));
        body.add(scrolling);

        self.* = .{
            .prefs = prefs,
            .gpa = prefs.gpa,
            .page = win.navPage("Terminal", body.as(gtk.Widget)),
            .font_label = label,
            .font_row = font_row,
        };
        self.showFont();
        s.subscribe(.{ .ctx = self, .func = onSetting });
        _ = gtk.Button.signals.clicked.connect(button, *TerminalPage, &onChooseFont, self, .{});
        _ = gtk.Button.signals.clicked.connect(reset, *TerminalPage, &onReset, self, .{});
        _ = gobject.Object.signals.notify.connect(size, *Settings, &onSizeChanged, s, .{ .detail = "value" });
        _ = gobject.Object.signals.notify.connect(lines, *Settings, &onLinesChanged, s, .{ .detail = "value" });
        return self;
    }

    pub fn destroy(self: *TerminalPage) void {
        self.prefs.app.settings.unsubscribe(self);
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    fn isMonospace(item: *gobject.Object, _: ?*anyopaque) callconv(.c) c_int {
        if (gobject.typeCheckInstanceIsA(@ptrCast(item), pango.FontFamily.getGObjectType()) == 0) return 1;
        const family: *pango.FontFamily = @ptrCast(item);
        return family.isMonospace();
    }

    fn showFont(self: *TerminalPage) void {
        var buf: [256]u8 = undefined;
        const family = self.prefs.app.settings.getString("terminal.font", "");
        self.font_label.setText(win.z(&buf, "{s}", .{if (family.len > 0) family else "JetBrains Mono"}));
        self.font_row.setSubtitle(if (family.len == 0) "The built-in font" else "");
    }

    fn onSetting(ctx: *anyopaque, key: []const u8) void {
        const self: *TerminalPage = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, key, "terminal.font")) self.showFont();
    }

    /// Pick a fixed-width family. The answer goes to the settings, which
    /// outlive this page.
    fn onChooseFont(_: *gtk.Button, self: *TerminalPage) callconv(.c) void {
        const dialog = gtk.FontDialog.new();
        dialog.setTitle("Terminal Font");
        const filter = gtk.CustomFilter.new(&isMonospace, null, null);
        dialog.setFilter(filter.as(gtk.Filter));
        filter.as(gobject.Object).unref();
        const app = self.prefs.app;
        dialog.chooseFamily(if (app.window) |w| w.as(gtk.Window) else null, null, null, &onFamilyChosen, app);
    }

    fn onFamilyChosen(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const app: *@import("../app.zig").App = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FontDialog = @ptrCast(source.?);
        defer dialog.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        const family = dialog.chooseFamilyFinish(res, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        app.settings.setString("terminal.font", std.mem.span(family.getName()));
    }

    fn onReset(_: *gtk.Button, self: *TerminalPage) callconv(.c) void {
        self.prefs.app.settings.setString("terminal.font", "");
    }

    fn onSizeChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, s: *Settings) callconv(.c) void {
        s.setNumber("terminal.font_size", row.getValue());
    }

    fn onLinesChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, s: *Settings) callconv(.c) void {
        s.setNumber("terminal.scroll_lines", row.getValue());
    }
};
