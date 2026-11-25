//! The command palette: every action and every tab of every machine, in a
//! dialog you type to filter. Enter runs the highlighted row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const Machine = @import("machine.zig").Machine;
const actions = @import("actions.zig");
const keymap = @import("keymap.zig");
const ov = @import("overview.zig");

const Item = struct {
    kind: enum { action, tab },
    /// The action's name, or the tab's window.
    name: []const u8,
    machine: ?*Machine = null,
    session_id: []const u8 = "",
    /// Lowercase title and subtitle, for matching.
    haystack: []const u8,
};

const Palette = struct {
    app: *App,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    items: std.ArrayList(Item) = .empty,
};

var open: ?*Palette = null;

pub fn toggle(app: *App) void {
    if (open) |p| {
        _ = p.dialog.close();
        return;
    }
    show(app) catch {};
}

fn show(app: *App) !void {
    const gpa = app.gpa;
    const p = try gpa.create(Palette);
    errdefer gpa.destroy(p);

    const dialog = adw.Dialog.new();
    dialog.setTitle("Command Palette");
    dialog.setContentWidth(560);
    dialog.setContentHeight(440);

    const entry = gtk.SearchEntry.new();
    entry.setPlaceholderText("Run an action or go to a tab");
    entry.as(gtk.Widget).setHexpand(1);
    const header = adw.HeaderBar.new();
    header.setTitleWidget(entry.as(gtk.Widget));
    header.setShowEndTitleButtons(0);
    header.setShowStartTitleButtons(0);

    const list = gtk.ListBox.new();
    list.as(gtk.Widget).addCssClass("navigation-sidebar");
    const scroller = gtk.ScrolledWindow.new();
    scroller.setChild(list.as(gtk.Widget));
    scroller.setPolicy(.never, .automatic);
    scroller.as(gtk.Widget).setVexpand(1);

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.setContent(scroller.as(gtk.Widget));
    dialog.setChild(toolbar.as(gtk.Widget));

    p.* = .{ .app = app, .gpa = gpa, .arena = .init(gpa), .dialog = dialog, .entry = entry, .list = list };
    fill(p);
    list.setFilterFunc(&filterRow, p, null);
    _ = gtk.SearchEntry.signals.search_changed.connect(entry, *Palette, &onChanged, p, .{});
    _ = gtk.SearchEntry.signals.activate.connect(entry, *Palette, &onActivate, p, .{});
    _ = gtk.SearchEntry.signals.stop_search.connect(entry, *Palette, &onStop, p, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Palette, &onRow, p, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Palette, &onClosed, p, .{});

    // Up and Down move through the list while typing.
    const keys = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Palette, &onKey, p, .{});
    entry.as(gtk.Widget).addController(keys.as(gtk.EventController));

    open = p;
    dialog.present(if (app.window) |w| w.as(gtk.Widget) else null);
    _ = entry.as(gtk.Widget).grabFocus();
    selectFirst(p);
}

fn fill(p: *Palette) void {
    const a = p.arena.allocator();
    // Tabs first, so typing a program's name jumps to it.
    for (p.app.machines.items) |m| {
        if (m.state != .connected) continue;
        for (m.sessions.items) |s| {
            const info = m.overview.session(s.session_id) orelse continue;
            const session_name = if (s.label.len > 0) s.label else s.session_id;
            for (info.windows.items) |w| {
                const block = if (w.focused_block_id) |b| m.overview.block(b) else null;
                const title = ov.tabTitle(w.label, if (block) |b| b.title else null);
                const subtitle = std.fmt.allocPrint(a, "{s} · {s}", .{ session_name, m.title() }) catch continue;
                const hay = std.fmt.allocPrint(a, "{s} {s}", .{ title, subtitle }) catch continue;
                _ = std.ascii.lowerString(hay, hay);
                add(p, .{
                    .kind = .tab,
                    .name = a.dupe(u8, w.window_id) catch continue,
                    .machine = m,
                    .session_id = a.dupe(u8, s.session_id) catch continue,
                    .haystack = hay,
                }, "utilities-terminal-symbolic", title, subtitle, null);
            }
        }
    }
    for (actions.all) |act| {
        // Actions that need arguments have no row of their own.
        if (act.args != null and !std.mem.eql(u8, act.name, "client.preferences")) continue;
        if (std.mem.eql(u8, act.name, "client.palette.toggle")) continue;
        const hay = std.fmt.allocPrint(a, "{s} {s} {s}", .{ act.title, act.category, act.name }) catch continue;
        _ = std.ascii.lowerString(hay, hay);
        var buf: [64]u8 = undefined;
        const accel = if (p.app.keys.keyFor(act.name)) |spec| keymap.gtkAccel(&buf, spec) else null;
        add(p, .{ .kind = .action, .name = act.name, .haystack = hay }, null, act.title, act.category, accel);
    }
}

fn add(p: *Palette, item: Item, icon: ?[:0]const u8, title: []const u8, subtitle: []const u8, accel: ?[]const u8) void {
    p.items.append(p.gpa, item) catch return;
    const box = gtk.Box.new(.horizontal, 10);
    box.as(gtk.Widget).setMarginTop(2);
    box.as(gtk.Widget).setMarginBottom(2);
    if (icon) |i| {
        const tile = gtk.Image.newFromIconName(i);
        tile.as(gtk.Widget).addCssClass("tab-tile");
        box.append(tile.as(gtk.Widget));
    }
    const text = gtk.Box.new(.vertical, 0);
    text.as(gtk.Widget).setHexpand(1);
    var buf: [512]u8 = undefined;
    const t = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{title}, 0) catch "");
    t.setXalign(0);
    t.setEllipsize(.end);
    text.append(t.as(gtk.Widget));
    const s = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{subtitle}, 0) catch "");
    s.setXalign(0);
    s.setEllipsize(.end);
    s.as(gtk.Widget).addCssClass("caption");
    s.as(gtk.Widget).addCssClass("dim-label");
    text.append(s.as(gtk.Widget));
    box.append(text.as(gtk.Widget));
    if (accel) |acc| {
        const label = gtk.ShortcutLabel.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{acc}, 0) catch "");
        label.as(gtk.Widget).setValign(.center);
        box.append(label.as(gtk.Widget));
    }
    p.list.append(box.as(gtk.Widget));
}

fn query(p: *Palette, buf: []u8) []const u8 {
    const text = std.mem.trim(u8, std.mem.span(p.entry.as(gtk.Editable).getText()), " ");
    const n = @min(text.len, buf.len);
    return std.ascii.lowerString(buf[0..n], text[0..n]);
}

/// Every word typed must appear somewhere in the row.
fn matches(haystack: []const u8, q: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, q, ' ');
    while (words.next()) |w| if (std.mem.indexOf(u8, haystack, w) == null) return false;
    return true;
}

fn filterRow(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
    const p: *Palette = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(row.getIndex());
    if (i >= p.items.items.len) return 1;
    var buf: [256]u8 = undefined;
    return @intFromBool(matches(p.items.items[i].haystack, query(p, &buf)));
}

fn visibleRows(p: *Palette, buf: []*gtk.ListBoxRow) []*gtk.ListBoxRow {
    var n: usize = 0;
    var var_buf: [256]u8 = undefined;
    const q = query(p, &var_buf);
    for (p.items.items, 0..) |item, i| {
        if (n == buf.len) break;
        if (!matches(item.haystack, q)) continue;
        buf[n] = p.list.getRowAtIndex(@intCast(i)) orelse continue;
        n += 1;
    }
    return buf[0..n];
}

fn selectFirst(p: *Palette) void {
    var buf: [1]*gtk.ListBoxRow = undefined;
    const rows = visibleRows(p, &buf);
    p.list.selectRow(if (rows.len > 0) rows[0] else null);
}

fn onChanged(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
    p.list.invalidateFilter();
    selectFirst(p);
}

fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, p: *Palette) callconv(.c) c_int {
    const down = keyval == gdk.KEY_Down;
    const up = keyval == gdk.KEY_Up;
    if (!down and !up) return 0;
    var buf: [512]*gtk.ListBoxRow = undefined;
    const rows = visibleRows(p, &buf);
    if (rows.len == 0) return 1;
    const current = p.list.getSelectedRow();
    var at: usize = 0;
    for (rows, 0..) |r, i| if (current != null and r == current.?) {
        at = i;
    };
    const next = if (down) @min(at + 1, rows.len - 1) else at -| 1;
    p.list.selectRow(rows[next]);
    return 1;
}

fn onActivate(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
    const row = p.list.getSelectedRow() orelse return;
    run(p, @intCast(row.getIndex()));
}

fn onRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Palette) callconv(.c) void {
    run(p, @intCast(row.getIndex()));
}

fn onStop(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
    _ = p.dialog.close();
}

/// Close first, so focus is back on the terminal when the action runs.
fn run(p: *Palette, index: usize) void {
    if (index >= p.items.items.len) return;
    const Pending = struct { app: *App, item: Item, name: []u8, session_id: []u8 };
    const item = p.items.items[index];
    const pending = p.gpa.create(Pending) catch return;
    pending.* = .{
        .app = p.app,
        .item = item,
        .name = p.gpa.dupe(u8, item.name) catch return,
        .session_id = p.gpa.dupe(u8, item.session_id) catch return,
    };
    _ = p.dialog.close();
    _ = glib.idleAdd(&struct {
        fn f(data: ?*anyopaque) callconv(.c) c_int {
            const r: *Pending = @ptrCast(@alignCast(data.?));
            const gpa = r.app.gpa;
            defer {
                gpa.free(r.name);
                gpa.free(r.session_id);
                gpa.destroy(r);
            }
            switch (r.item.kind) {
                .action => actions.run(r.app, r.name, .null),
                .tab => {
                    // The machine may have gone meanwhile.
                    for (r.app.machines.items) |m| if (m == r.item.machine.?) {
                        r.app.showTab(m, r.session_id, r.name);
                    };
                },
            }
            return 0;
        }
    }.f, pending);
}

fn onClosed(_: *adw.Dialog, p: *Palette) callconv(.c) void {
    if (open == p) open = null;
    p.items.deinit(p.gpa);
    p.arena.deinit();
    p.gpa.destroy(p);
}
