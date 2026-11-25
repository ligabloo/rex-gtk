//! Preferences › Appearance: where the tabs go, and how the header bar
//! behaves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;
const Settings = @import("../settings.zig").Settings;
const switchRow = win.switchRow;

const behaviors = [_][]const u8{ "hidden", "hover", "always" };
const schemes = [_][]const u8{ "system", "light", "dark" };

pub const AppearancePage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,
    behavior: *adw.ComboRow,

    pub fn create(prefs: *Prefs) !*AppearancePage {
        const self = try prefs.gpa.create(AppearancePage);
        const s = &prefs.app.settings;
        const body = adw.PreferencesPage.new();

        // Light, dark, or as the system says.
        const look = win.group("Appearance", null);
        const style = adw.ComboRow.new();
        style.as(adw.PreferencesRow).setTitle("Style");
        const style_labels = [_:null]?[*:0]const u8{ "Follow System", "Light", "Dark", null };
        const style_model = gtk.StringList.new(@ptrCast(&style_labels));
        style.setModel(style_model.as(gio.ListModel));
        style_model.as(gobject.Object).unref();
        const scheme = s.getString("style.scheme", "system");
        for (schemes, 0..) |name, i| if (std.mem.eql(u8, name, scheme)) style.setSelected(@intCast(i));
        look.add(style.as(gtk.Widget));
        const tint = switchRow("Tint with theme", "Paint the window, header bar and sidebar in the terminal theme's colors.", s.getBool("style.tint", false));
        win.bindSwitch(tint, &prefs.app.settings, "style.tint");
        look.add(tint.as(gtk.Widget));
        body.add(look);

        const tabs = win.group("Tabs", null);
        const layout_row = win.actionRow("Tab layout", null);
        const layout = adw.ToggleGroup.new();
        layout.as(gtk.Widget).setValign(.center);
        for ([_][3][:0]const u8{
            .{ "sidebar", "Sidebar", "sidebar-show-symbolic" },
            .{ "header", "Header Bar", "tab-new-symbolic" },
        }) |t| {
            const toggle = adw.Toggle.new();
            toggle.setName(t[0]);
            toggle.setLabel(t[1]);
            toggle.setIconName(t[2]);
            layout.add(toggle);
        }
        const current = s.getString("tabs.layout", "sidebar");
        var buf: [32]u8 = undefined;
        layout.setActiveName(win.z(&buf, "{s}", .{if (std.mem.eql(u8, current, "header")) "header" else "sidebar"}));
        layout_row.addSuffix(layout.as(gtk.Widget));
        tabs.add(layout_row.as(gtk.Widget));

        const behavior = adw.ComboRow.new();
        behavior.as(adw.PreferencesRow).setTitle("Header bar");
        behavior.as(adw.ActionRow).setSubtitle("Show on hover slides it in when the pointer reaches the top edge.");
        const labels = [_:null]?[*:0]const u8{ "Hidden", "Show on hover", "Always show", null };
        const model = gtk.StringList.new(@ptrCast(&labels));
        behavior.setModel(model.as(gio.ListModel));
        model.as(gobject.Object).unref();
        const b = s.getString("header.behavior", "hover");
        for (behaviors, 0..) |name, i| if (std.mem.eql(u8, name, b)) behavior.setSelected(@intCast(i));
        behavior.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, current, "header")));
        tabs.add(behavior.as(gtk.Widget));
        const activity = switchRow("Program activity", "Show what programs in each tab say they're doing, such as an agent waiting for you.", s.getBool("sidebar.activity", true));
        tabs.add(activity.as(gtk.Widget));
        body.add(tabs);

        const panes = win.group("Panes", null);
        const dim = switchRow("Dim unfocused panes", "In a tab with splits, the panes you aren't typing in are drawn dimmer.", s.getBool("panes.dim", true));
        panes.add(dim.as(gtk.Widget));
        body.add(panes);

        self.* = .{
            .prefs = prefs,
            .gpa = prefs.gpa,
            .page = win.navPage("Appearance", body.as(gtk.Widget)),
            .behavior = behavior,
        };
        _ = gobject.Object.signals.notify.connect(layout, *AppearancePage, &onLayoutChanged, self, .{ .detail = "active-name" });
        _ = gobject.Object.signals.notify.connect(behavior, *AppearancePage, &onBehaviorChanged, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(style, *AppearancePage, &onStyleChanged, self, .{ .detail = "selected" });
        win.bindSwitch(activity, &prefs.app.settings, "sidebar.activity");
        win.bindSwitch(dim, &prefs.app.settings, "panes.dim");
        return self;
    }

    pub fn destroy(self: *AppearancePage) void {
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    fn settings(self: *AppearancePage) *Settings {
        return &self.prefs.app.settings;
    }

    fn onLayoutChanged(group: *adw.ToggleGroup, _: *gobject.ParamSpec, self: *AppearancePage) callconv(.c) void {
        const name = std.mem.span(group.getActiveName() orelse return);
        self.settings().setString("tabs.layout", name);
        self.behavior.as(gtk.Widget).setSensitive(@intFromBool(!std.mem.eql(u8, name, "header")));
    }

    fn onStyleChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *AppearancePage) callconv(.c) void {
        const i = row.getSelected();
        if (i < schemes.len) self.settings().setString("style.scheme", schemes[i]);
    }

    fn onBehaviorChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *AppearancePage) callconv(.c) void {
        const i = row.getSelected();
        if (i < behaviors.len) self.settings().setString("header.behavior", behaviors[i]);
    }
};
