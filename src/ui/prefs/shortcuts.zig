//! Preferences › Shortcuts: every key binding in effect, which the server
//! makes from rex-gtk's defaults and your configuration file. They're
//! changed in the configuration file, as with Rex.app and the CLI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;
const actions = @import("../actions.zig");
const keymap = @import("../keymap.zig");

pub const ShortcutsPage = struct {
    prefs: *Prefs,
    gpa: Allocator,
    page: *adw.NavigationPage,
    body: *adw.PreferencesPage,
    groups: std.ArrayList(*adw.PreferencesGroup) = .empty,
    filter: *gtk.SearchEntry,

    pub fn create(prefs: *Prefs) !*ShortcutsPage {
        const self = try prefs.gpa.create(ShortcutsPage);
        const body = adw.PreferencesPage.new();
        const filter = gtk.SearchEntry.new();
        filter.setPlaceholderText("Filter Shortcuts");
        filter.as(gtk.Widget).setMarginBottom(12);

        const top = win.group(null, "Shortcuts come from rex-gtk's defaults and your Rex configuration file, where you can change them. Key sequences and modes work too.");
        const open = win.button("Open Configuration File", null);
        open.as(gtk.Widget).setHalign(.start);
        _ = gtk.Button.signals.clicked.connect(open, *Prefs, &onOpenConfig, prefs, .{});
        top.setHeaderSuffix(open.as(gtk.Widget));
        top.add(filter.as(gtk.Widget));
        body.add(top);

        self.* = .{
            .prefs = prefs,
            .gpa = prefs.gpa,
            .page = win.navPage("Shortcuts", body.as(gtk.Widget)),
            .body = body,
            .filter = filter,
        };
        _ = gtk.SearchEntry.signals.search_changed.connect(filter, *ShortcutsPage, &onFilter, self, .{});
        self.rebuild();
        return self;
    }

    pub fn destroy(self: *ShortcutsPage) void {
        self.groups.deinit(self.gpa);
        self.page.as(gobject.Object).unref();
        self.gpa.destroy(self);
    }

    /// The keymap changed.
    pub fn scheduleRefresh(self: *ShortcutsPage) void {
        self.rebuild();
    }

    fn onFilter(_: *gtk.SearchEntry, self: *ShortcutsPage) callconv(.c) void {
        self.rebuild();
    }

    fn rebuild(self: *ShortcutsPage) void {
        for (self.groups.items) |g| self.body.remove(g);
        self.groups.clearRetainingCapacity();
        var qbuf: [128]u8 = undefined;
        const raw = std.mem.trim(u8, std.mem.span(self.filter.as(gtk.Editable).getText()), " ");
        const q = std.ascii.lowerString(qbuf[0..@min(raw.len, qbuf.len)], raw[0..@min(raw.len, qbuf.len)]);

        // Sorted by name, so "Go to Tab 1" comes before "Go to Tab 2".
        const all = self.prefs.app.keys.allBindings();
        const bindings = self.gpa.dupe(keymap.Binding, all) catch return;
        defer self.gpa.free(bindings);
        std.mem.sort(keymap.Binding, bindings, {}, struct {
            fn lessThan(_: void, x: keymap.Binding, y: keymap.Binding) bool {
                const o = std.mem.order(u8, x.action, y.action);
                if (o != .eq) return o == .lt;
                return std.mem.order(u8, x.args orelse "", y.args orelse "") == .lt;
            }
        }.lessThan);
        const categories = [_][:0]const u8{ "Tabs", "Panes", "Sessions", "Edit", "View", "Window", "Configuration" };
        for (categories) |cat| {
            const g = win.group(cat, null);
            var any = false;
            for (bindings) |b| {
                const act = actions.find(b.action);
                const category = if (act) |a| a.category else "Configuration";
                if (!std.mem.eql(u8, category, cat)) continue;
                var tbuf: [256]u8 = undefined;
                var kbuf: [128]u8 = undefined;
                var titlebuf: [192]u8 = undefined;
                const base = if (act) |a| a.title else b.action;
                const title = if (b.args) |args| std.fmt.bufPrint(&titlebuf, "{s} {s}", .{ base, keymap.argSummary(args) }) catch base else base;
                var w: std.Io.Writer = .fixed(&kbuf);
                for (b.keys, 0..) |k, i| {
                    if (i > 0) w.writeAll(" then ") catch {};
                    w.writeAll(k) catch {};
                }
                const keys = w.buffered();
                const line = std.fmt.bufPrint(&tbuf, "{s} {s} {s} {s}", .{ title, b.action, keys, b.mode orelse "" }) catch continue;
                var lbuf: [256]u8 = undefined;
                if (q.len > 0 and std.mem.indexOf(u8, std.ascii.lowerString(lbuf[0..line.len], line), q) == null) continue;

                var sbuf: [256]u8 = undefined;
                const subtitle: ?[:0]const u8 = if (b.mode) |m|
                    std.fmt.bufPrintSentinel(&sbuf, "In {s} mode", .{m}, 0) catch null
                else if (act == null)
                    std.fmt.bufPrintSentinel(&sbuf, "{s}", .{b.action}, 0) catch null
                else
                    null;
                var nbuf: [256]u8 = undefined;
                const row = win.actionRow(std.fmt.bufPrintSentinel(&nbuf, "{s}", .{title}, 0) catch "", subtitle);
                var abuf: [64]u8 = undefined;
                var zbuf: [64]u8 = undefined;
                if (b.keys.len == 1) if (keymap.gtkAccel(&abuf, b.keys[0])) |accel| {
                    const label = gtk.ShortcutLabel.new(std.fmt.bufPrintSentinel(&zbuf, "{s}", .{accel}, 0) catch "");
                    label.as(gtk.Widget).setValign(.center);
                    row.addSuffix(label.as(gtk.Widget));
                } else {
                    row.addSuffix(keyText(keys));
                } else row.addSuffix(keyText(keys));
                g.add(row.as(gtk.Widget));
                any = true;
            }
            if (any) {
                self.body.add(g);
                self.groups.append(self.gpa, g) catch {};
            } else {
                _ = g.as(gobject.Object).refSink();
                g.as(gobject.Object).unref();
            }
        }
    }

    fn keyText(keys: []const u8) *gtk.Widget {
        var buf: [160]u8 = undefined;
        const l = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{keys}, 0) catch "");
        l.as(gtk.Widget).addCssClass("monospace");
        l.as(gtk.Widget).addCssClass("dim-label");
        l.as(gtk.Widget).setValign(.center);
        return l.as(gtk.Widget);
    }

    fn onOpenConfig(_: *gtk.Button, prefs: *Prefs) callconv(.c) void {
        const path = prefs.app.keys.config_path;
        if (path.len == 0) return prefs.toast("The configuration file's path isn't known yet", .{});
        const z = prefs.gpa.dupeSentinel(u8, path, 0) catch return;
        defer prefs.gpa.free(z);
        const file = gio.File.newForPath(z);
        defer file.as(gobject.Object).unref();
        const launcher = gtk.FileLauncher.new(file);
        defer launcher.as(gobject.Object).unref();
        launcher.launch(if (prefs.app.window) |w| w.as(gtk.Window) else null, null, null, null);
    }
};
