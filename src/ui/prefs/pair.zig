//! The Pair Device dialog: a QR code of the server's tailnet address, for
//! Rex on another device to scan. It holds only the address, the same as
//! `rex server tailscale pair` shows; access is up to Tailscale.

const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const qr = @import("../qr.zig");
const win = @import("window.zig");
const Prefs = win.Prefs;

const log = std.log.scoped(.prefs);

/// Pixels per module, and modules of light border on each side.
const scale = 6;
const quiet = 4;

pub fn show(prefs: *Prefs, url: [:0]const u8, dns_name: [:0]const u8) void {
    const code = qr.encode(url) catch {
        prefs.toast("The address is too long for a QR code", .{});
        return;
    };
    const texture = render(prefs.gpa, &code) orelse return;
    defer texture.as(gobject.Object).unref();

    const dialog = adw.Dialog.new();
    dialog.setTitle("Pair Device");
    dialog.setContentWidth(420);

    const box = gtk.Box.new(.vertical, 18);
    box.as(gtk.Widget).setMarginTop(6);
    box.as(gtk.Widget).setMarginBottom(24);
    box.as(gtk.Widget).setMarginStart(24);
    box.as(gtk.Widget).setMarginEnd(24);

    const intro = gtk.Label.new("In Rex on your other device, choose Pair via QR Code and scan this code.");
    intro.setWrap(1);
    intro.setJustify(.center);
    box.append(intro.as(gtk.Widget));

    const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
    picture.setCanShrink(0);
    picture.as(gtk.Widget).setHalign(.center);
    picture.as(gtk.Widget).addCssClass("card");
    picture.as(gtk.Widget).setOverflow(.hidden);
    picture.as(gtk.Widget).setTooltipText(url);
    box.append(picture.as(gtk.Widget));

    // The device's name over its address.
    const dns = std.mem.trimEnd(u8, dns_name, ".");
    const host = if (std.mem.indexOfScalar(u8, dns, '.')) |i| dns[0..i] else dns;
    var buf: [256]u8 = undefined;
    const name_row = gtk.Box.new(.horizontal, 8);
    name_row.as(gtk.Widget).setHalign(.center);
    name_row.append(gtk.Image.newFromIconName("computer-symbolic").as(gtk.Widget));
    const name = gtk.Label.new(win.z(&buf, "{s}", .{if (host.len > 0) host else "This computer"}));
    name.as(gtk.Widget).addCssClass("heading");
    name_row.append(name.as(gtk.Widget));
    const names = gtk.Box.new(.vertical, 2);
    names.append(name_row.as(gtk.Widget));
    if (dns.len > 0) {
        var abuf: [256]u8 = undefined;
        const addr = gtk.Label.new(win.z(&abuf, "{s}", .{dns}));
        addr.as(gtk.Widget).addCssClass("dim-label");
        addr.as(gtk.Widget).addCssClass("caption");
        names.append(addr.as(gtk.Widget));
    }
    box.append(names.as(gtk.Widget));

    const note = gtk.Label.new("Your device must be able to reach this computer, such as on the same Tailscale network. The code holds only this address, not a password.");
    note.setWrap(1);
    note.setJustify(.center);
    note.as(gtk.Widget).addCssClass("dim-label");
    note.as(gtk.Widget).addCssClass("caption");
    box.append(note.as(gtk.Widget));

    const done = gtk.Button.newWithLabel("Done");
    done.as(gtk.Widget).addCssClass("pill");
    done.as(gtk.Widget).addCssClass("suggested-action");
    done.as(gtk.Widget).setHalign(.center);
    _ = gtk.Button.signals.clicked.connect(done, *adw.Dialog, &struct {
        fn f(_: *gtk.Button, d: *adw.Dialog) callconv(.c) void {
            _ = d.close();
        }
    }.f, dialog, .{});
    box.append(done.as(gtk.Widget));

    const header = adw.HeaderBar.new();
    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.setContent(box.as(gtk.Widget));
    dialog.setChild(toolbar.as(gtk.Widget));
    dialog.setDefaultWidget(done.as(gtk.Widget));
    dialog.present(prefs.parentWidget());
}

/// Draw the code black on white, with its quiet zone, at `scale` pixels
/// per module so it stays sharp.
fn render(gpa: std.mem.Allocator, code: *const qr.QrCode) ?*gdk.Texture {
    const modules: usize = @as(usize, code.size) + 2 * quiet;
    const side = modules * scale;
    const stride = side * 3;
    const pixels = gpa.alloc(u8, stride * side) catch return null;
    defer gpa.free(pixels);
    @memset(pixels, 0xFF);
    for (0..code.size) |y| for (0..code.size) |x| {
        if (!code.get(x, y)) continue;
        for (0..scale) |dy| {
            const row = ((y + quiet) * scale + dy) * stride;
            const start = row + (x + quiet) * scale * 3;
            @memset(pixels[start..][0 .. scale * 3], 0);
        }
    };
    const bytes = glib.Bytes.new(pixels.ptr, pixels.len);
    defer bytes.unref();
    const texture = gdk.MemoryTexture.new(@intCast(side), @intCast(side), .r8g8b8, bytes, stride);
    return texture.as(gdk.Texture);
}
