const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const gtk = @import("gtk");

const app_id = "dev.ligabloo.RexGtk";

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    const app = adw.Application.new(app_id, .{});
    defer app.unref();

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &onActivate, null, .{});

    const status = gio.Application.run(app.as(gio.Application), 0, null);
    return @intCast(status);
}

fn onActivate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    const window = adw.ApplicationWindow.new(app.as(gtk.Application));
    window.as(gtk.Window).setTitle("Rex");
    window.as(gtk.Window).setDefaultSize(1000, 700);

    const status = adw.StatusPage.new();
    status.setIconName("utilities-terminal-symbolic");
    status.setTitle("Rex");
    status.setDescription("Not connected yet");

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    toolbar.setContent(status.as(gtk.Widget));

    window.setContent(toolbar.as(gtk.Widget));
    window.as(gtk.Window).present();
}
