//! Preferences › General: how this client presents itself, and what it
//! does at startup. Everything here is rex-gtk's own setting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;
const Settings = @import("../settings.zig").Settings;

const startup_choices = [_][]const u8{ "server", "last" };

pub const GeneralPage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,

    pub fn create(prefs: *Prefs) !*GeneralPage {
        const self = try prefs.gpa.create(GeneralPage);
        const app = prefs.app;
        const s = &app.settings;
        const body = adw.PreferencesPage.new();
        self.* = .{
            .prefs = prefs,
            .gpa = prefs.gpa,
            .page = win.navPage("General", body.as(gtk.Widget)),
        };
        var buf: [256]u8 = undefined;

        // This client.
        const client = win.group("This Client", "Other Rex clients and the rex command see this window under its name, as in rex -C NAME do ACTION.");
        const name = adw.EntryRow.new();
        name.as(adw.PreferencesRow).setTitle("Name");
        name.as(gtk.Editable).setText(win.z(&buf, "{s}", .{app.clientLabel() orelse ""}));
        name.setShowApplyButton(1);
        if (app.options.label != null) {
            name.as(gtk.Widget).setSensitive(0);
            name.as(gtk.Widget).setTooltipText("Set by --label for this run");
        }
        _ = adw.EntryRow.signals.apply.connect(name, *GeneralPage, &onNameApply, self, .{});
        client.add(name.as(gtk.Widget));

        const remote = adw.SwitchRow.new();
        remote.as(adw.PreferencesRow).setTitle("Allow remote control");
        remote.as(adw.ActionRow).setSubtitle("Let other clients and the rex command run actions here, such as splitting a pane.");
        remote.setActive(@intFromBool(s.getBool("client.remote_control", true)));
        _ = gobject.Object.signals.notify.connect(remote, *GeneralPage, &onRemoteToggled, self, .{ .detail = "active" });
        client.add(remote.as(gtk.Widget));
        body.add(client);

        // Startup.
        const startup = win.group("Startup", null);
        const open = adw.ComboRow.new();
        open.as(adw.PreferencesRow).setTitle("Show at startup");
        const labels = [_:null]?[*:0]const u8{ "The server's choice", "The last session shown", null };
        const model = gtk.StringList.new(@ptrCast(&labels));
        open.setModel(model.as(gio.ListModel));
        model.as(gobject.Object).unref();
        const current = s.getString("startup.session", "server");
        open.setSelected(if (std.mem.eql(u8, current, "last")) 1 else 0);
        _ = gobject.Object.signals.notify.connect(open, *GeneralPage, &onStartupChanged, self, .{ .detail = "selected" });
        startup.add(open.as(gtk.Widget));

        const start_server = adw.SwitchRow.new();
        start_server.as(adw.PreferencesRow).setTitle("Start the server");
        start_server.as(adw.ActionRow).setSubtitle("Start this computer's Rex server when it isn't running, as the rex command does.");
        start_server.setActive(@intFromBool(s.getBool("startup.start_server", true)));
        _ = gobject.Object.signals.notify.connect(start_server, *GeneralPage, &onStartServerToggled, self, .{ .detail = "active" });
        startup.add(start_server.as(gtk.Widget));
        body.add(startup);

        return self;
    }

    pub fn destroy(self: *GeneralPage) void {
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    pub fn scheduleRefresh(_: *GeneralPage) void {}

    fn settings(self: *GeneralPage) *Settings {
        return &self.prefs.app.settings;
    }

    fn onNameApply(row: *adw.EntryRow, self: *GeneralPage) callconv(.c) void {
        const text = std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " ");
        if (text.len > 64) return self.prefs.toast("A name can be at most 64 bytes", .{});
        // An empty name means the computer's name again.
        self.settings().setString("client.label", text);
        self.prefs.toast("Renamed", .{});
    }

    fn onRemoteToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *GeneralPage) callconv(.c) void {
        self.settings().setBool("client.remote_control", row.getActive() != 0);
    }

    fn onStartupChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *GeneralPage) callconv(.c) void {
        const i = row.getSelected();
        if (i >= startup_choices.len) return;
        self.settings().setString("startup.session", startup_choices[i]);
    }

    fn onStartServerToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *GeneralPage) callconv(.c) void {
        self.settings().setBool("startup.start_server", row.getActive() != 0);
    }
};
