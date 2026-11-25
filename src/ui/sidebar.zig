//! The sidebar: every machine, its sessions, and each session's tabs, as
//! in Rex.app. A machine heading (with New Session, or a warning when it
//! can't be reached), a small session heading, then a row per tab with a
//! tile, the tab's name and its working directory.
//!
//! The list is rebuilt from the machines' overviews whenever they change,
//! from an idle callback so a burst of title changes rebuilds once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const Machine = @import("machine.zig").Machine;
const ov = @import("overview.zig");

const log = std.log.scoped(.sidebar);

/// What a row stands for. Strings live in the sidebar's arena until the
/// next rebuild.
const Entry = struct {
    kind: enum { machine, session, tab },
    machine: *Machine,
    session_id: []const u8 = "",
    window_id: []const u8 = "",
    /// Lowercase text the filter matches.
    haystack: []const u8 = "",
};

pub const Sidebar = struct {
    app: *App,
    gpa: Allocator,
    /// The whole sidebar, for the split view.
    widget: *gtk.Widget,
    list: *gtk.ListBox,
    filter_toggle: *gtk.ToggleButton,
    filter: *gtk.SearchEntry,
    entries: std.ArrayList(Entry) = .empty,
    arena: std.heap.ArenaAllocator,
    rebuild_id: c_uint = 0,
    syncing: bool = false,

    pub fn init(self: *Sidebar, app: *App) void {
        const gpa = app.gpa;

        // Header: New Tab, with the title centered.
        const header = adw.HeaderBar.new();
        header.setTitleWidget(adw.WindowTitle.new("Sessions", "").as(gtk.Widget));
        const new_tab = gtk.Button.newFromIconName("tab-new-symbolic");
        new_tab.as(gtk.Widget).setTooltipText("New Tab");
        new_tab.as(gtk.Actionable).setActionName("app.rex");
        new_tab.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString("client.tab.new"));
        header.packEnd(new_tab.as(gtk.Widget));
        const palette = gtk.Button.newFromIconName("system-search-symbolic");
        palette.as(gtk.Widget).setTooltipText("Command Palette");
        palette.as(gtk.Actionable).setActionName("app.rex");
        palette.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString("client.palette.toggle"));
        header.packStart(palette.as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("navigation-sidebar");
        list.as(gtk.Widget).addCssClass("rex-sidebar");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.setPolicy(.never, .automatic);
        scroller.as(gtk.Widget).setVexpand(1);

        // Bottom: a filter that opens inline, and Add Machine.
        const filter_toggle = gtk.ToggleButton.new();
        filter_toggle.as(gtk.Button).setIconName("edit-find-symbolic");
        filter_toggle.as(gtk.Widget).setTooltipText("Filter Tabs");
        filter_toggle.as(gtk.Widget).addCssClass("flat");
        const filter = gtk.SearchEntry.new();
        filter.as(gtk.Widget).setHexpand(1);
        filter.as(gtk.Widget).setVisible(0);
        filter.setPlaceholderText("Filter");
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        const add_machine = gtk.Button.newFromIconName("list-add-symbolic");
        add_machine.as(gtk.Widget).setTooltipText("Add Machine…");
        add_machine.as(gtk.Widget).addCssClass("flat");
        const bottom = gtk.Box.new(.horizontal, 6);
        bottom.as(gtk.Widget).addCssClass("toolbar");
        bottom.append(filter_toggle.as(gtk.Widget));
        bottom.append(filter.as(gtk.Widget));
        bottom.append(spacer.as(gtk.Widget));
        bottom.append(add_machine.as(gtk.Widget));

        const toolbar = adw.ToolbarView.new();
        toolbar.addTopBar(header.as(gtk.Widget));
        toolbar.setContent(scroller.as(gtk.Widget));
        toolbar.addBottomBar(bottom.as(gtk.Widget));

        self.* = .{
            .app = app,
            .gpa = gpa,
            .widget = toolbar.as(gtk.Widget),
            .list = list,
            .filter_toggle = filter_toggle,
            .filter = filter,
            .arena = .init(gpa),
        };
        list.setFilterFunc(&filterRow, self, null);
        _ = gtk.ListBox.signals.row_activated.connect(list, *Sidebar, &onRowActivated, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(filter_toggle, *Sidebar, &onFilterToggled, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(filter, *Sidebar, &onFilterChanged, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(filter, *Sidebar, &onStopFilter, self, .{});
        _ = gobject.Object.signals.notify.connect(filter_toggle, *gtk.Widget, &hideWhenActive, spacer.as(gtk.Widget), .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(add_machine, *Sidebar, &onAddMachine, self, .{});
    }

    pub fn deinit(self: *Sidebar) void {
        if (self.rebuild_id != 0) _ = glib.Source.remove(self.rebuild_id);
        self.rebuild_id = 0;
        self.entries.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Rebuild soon. Cheap to call often.
    pub fn scheduleRebuild(self: *Sidebar) void {
        if (self.rebuild_id != 0) return;
        self.rebuild_id = glib.idleAdd(&onRebuild, self);
    }

    fn onRebuild(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Sidebar = @ptrCast(@alignCast(data.?));
        self.rebuild_id = 0;
        self.rebuild();
        return 0;
    }

    pub fn rebuild(self: *Sidebar) void {
        self.syncing = true;
        defer self.syncing = false;
        self.list.removeAll();
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        for (self.app.machines.items) |m| {
            self.append(self.machineRow(m), .{
                .kind = .machine,
                .machine = m,
                .haystack = std.ascii.allocLowerString(a, m.title()) catch "",
            });
            if (m.state != .connected) continue;
            for (m.sessions.items) |s| {
                const sid = a.dupe(u8, s.session_id) catch continue;
                const name = if (s.label.len > 0) s.label else shortId(s.session_id);
                self.append(sessionRow(name), .{
                    .kind = .session,
                    .machine = m,
                    .session_id = sid,
                    .haystack = std.ascii.allocLowerString(a, name) catch "",
                });
                const info = m.overview.session(s.session_id) orelse continue;
                for (info.windows.items) |w| {
                    const block = if (w.focused_block_id) |b| m.overview.block(b) else null;
                    const title = ov.tabTitle(w.label, if (block) |b| b.title else null);
                    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
                    const home = if (m.is_local) self.app.startup.ssh_env.home else null;
                    const pwd = if (block) |b| if (b.pwd) |p| ov.tildePath(&tbuf, p, home) else "" else "";
                    const hay = std.fmt.allocPrint(a, "{s} {s} {s}", .{ title, pwd, name }) catch continue;
                    _ = std.ascii.lowerString(hay, hay);
                    self.append(tabRow(title, pwd), .{
                        .kind = .tab,
                        .machine = m,
                        .session_id = sid,
                        .window_id = a.dupe(u8, w.window_id) catch continue,
                        .haystack = hay,
                    });
                }
            }
        }
        self.selectCurrent();
    }

    fn append(self: *Sidebar, row: *gtk.ListBoxRow, entry: Entry) void {
        self.entries.append(self.gpa, entry) catch return;
        self.list.append(row.as(gtk.Widget));
    }

    fn shortId(id: []const u8) []const u8 {
        return if (id.len > 8) id[id.len - 8 ..] else id;
    }

    // ------------------------------------------------------------------
    // Rows

    fn machineRow(self: *Sidebar, m: *Machine) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.setActivatable(0);
        row.as(gtk.Widget).addCssClass("machine-row");
        const box = gtk.Box.new(.horizontal, 8);
        box.append(gtk.Image.newFromIconName(if (m.is_local) "computer-symbolic" else "network-server-symbolic").as(gtk.Widget));
        var buf: [128]u8 = undefined;
        const label = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{m.title()}, 0) catch "Machine");
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("heading");
        box.append(label.as(gtk.Widget));
        switch (m.state) {
            .connected => {
                const b = gtk.Button.newFromIconName("window-new-symbolic");
                b.as(gtk.Widget).addCssClass("flat");
                b.as(gtk.Widget).setTooltipText("New Session");
                _ = gtk.Button.signals.clicked.connect(b, *Machine, &onNewSession, m, .{});
                box.append(b.as(gtk.Widget));
            },
            .connecting => box.append(adw.Spinner.new().as(gtk.Widget)),
            .offline, .idle => {
                const b = gtk.Button.newFromIconName("dialog-warning-symbolic");
                b.as(gtk.Widget).addCssClass("flat");
                var tip: [600]u8 = undefined;
                const text = std.fmt.bufPrintSentinel(&tip, "Can't reach {s}. {s} Click to try again.", .{ m.title(), m.detail orelse "" }, 0) catch "Click to try again.";
                b.as(gtk.Widget).setTooltipText(text);
                _ = gtk.Button.signals.clicked.connect(b, *Machine, &onRetry, m, .{});
                box.append(b.as(gtk.Widget));
            },
        }
        row.setChild(box.as(gtk.Widget));
        _ = self;
        return row;
    }

    fn sessionRow(name: []const u8) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("session-row");
        var buf: [256]u8 = undefined;
        const label = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "Session");
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).addCssClass("caption-heading");
        label.as(gtk.Widget).addCssClass("dim-label");
        row.setChild(label.as(gtk.Widget));
        row.as(gtk.Widget).setTooltipText("Show this session");
        return row;
    }

    fn tabRow(title: []const u8, detail: []const u8) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("tab-row");
        const box = gtk.Box.new(.horizontal, 10);

        const tile = gtk.Image.newFromIconName("utilities-terminal-symbolic");
        tile.as(gtk.Widget).addCssClass("tab-tile");
        tile.as(gtk.Widget).setValign(.center);
        box.append(tile.as(gtk.Widget));

        const text = gtk.Box.new(.vertical, 0);
        text.as(gtk.Widget).setValign(.center);
        text.as(gtk.Widget).setHexpand(1);
        var buf: [512]u8 = undefined;
        const name = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{title}, 0) catch "Terminal");
        name.setXalign(0);
        name.setEllipsize(.end);
        text.append(name.as(gtk.Widget));
        if (detail.len > 0) {
            const d = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{detail}, 0) catch "");
            d.setXalign(0);
            d.setEllipsize(.start);
            d.as(gtk.Widget).addCssClass("caption");
            d.as(gtk.Widget).addCssClass("dim-label");
            text.append(d.as(gtk.Widget));
        }
        box.append(text.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn onNewSession(_: *gtk.Button, m: *Machine) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(m.listener.ctx));
        @import("actions.zig").newSessionOn(app, m);
    }

    fn onRetry(_: *gtk.Button, m: *Machine) callconv(.c) void {
        m.connect(true);
    }

    fn onAddMachine(_: *gtk.Button, self: *Sidebar) callconv(.c) void {
        @import("prefs/machines.zig").showAddMachine(self.app, self.widget);
    }

    // ------------------------------------------------------------------
    // Selection

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Sidebar) callconv(.c) void {
        if (self.syncing) return;
        const i: usize = @intCast(row.getIndex());
        if (i >= self.entries.items.len) return;
        const e = self.entries.items[i];
        switch (e.kind) {
            .machine => {},
            .session => self.app.switchSession(e.machine, e.session_id),
            .tab => self.app.showTab(e.machine, e.session_id, e.window_id),
        }
    }

    /// Highlight the shown session's selected tab.
    pub fn selectCurrent(self: *Sidebar) void {
        self.syncing = true;
        defer self.syncing = false;
        const view = self.app.view orelse return self.list.selectRow(null);
        const tab = view.selectedTab();
        for (self.entries.items, 0..) |e, i| {
            if (e.kind != .tab or e.machine != view.machine) continue;
            if (!std.mem.eql(u8, e.session_id, view.session_id)) continue;
            const t = tab orelse break;
            if (std.mem.eql(u8, e.window_id, t.window_id)) {
                self.list.selectRow(self.list.getRowAtIndex(@intCast(i)));
                return;
            }
        }
        self.list.selectRow(null);
    }

    // ------------------------------------------------------------------
    // Filter

    fn onFilterToggled(button: *gtk.ToggleButton, self: *Sidebar) callconv(.c) void {
        const on = button.getActive() != 0;
        self.filter.as(gtk.Widget).setVisible(@intFromBool(on));
        if (on) {
            _ = self.filter.as(gtk.Widget).grabFocus();
        } else {
            self.filter.as(gtk.Editable).setText("");
        }
    }

    fn hideWhenActive(button: *gtk.ToggleButton, _: *gobject.ParamSpec, w: *gtk.Widget) callconv(.c) void {
        w.setVisible(@intFromBool(button.getActive() == 0));
    }

    fn onFilterChanged(_: *gtk.SearchEntry, self: *Sidebar) callconv(.c) void {
        self.list.invalidateFilter();
    }

    fn onStopFilter(_: *gtk.SearchEntry, self: *Sidebar) callconv(.c) void {
        self.filter_toggle.setActive(0);
    }

    /// Show the filter, as from a shortcut.
    pub fn startFilter(self: *Sidebar) void {
        self.filter_toggle.setActive(1);
    }

    fn query(self: *Sidebar, buf: []u8) []const u8 {
        const text = std.mem.trim(u8, std.mem.span(self.filter.as(gtk.Editable).getText()), " ");
        const n = @min(text.len, buf.len);
        return std.ascii.lowerString(buf[0..n], text[0..n]);
    }

    /// A tab shows if it matches; a heading if anything under it does.
    fn filterRow(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Sidebar = @ptrCast(@alignCast(data.?));
        var buf: [256]u8 = undefined;
        const q = self.query(&buf);
        if (q.len == 0) return 1;
        const i: usize = @intCast(row.getIndex());
        if (i >= self.entries.items.len) return 1;
        const e = self.entries.items[i];
        switch (e.kind) {
            .tab => return @intFromBool(std.mem.indexOf(u8, e.haystack, q) != null),
            .session, .machine => {
                for (self.entries.items[i + 1 ..]) |next| {
                    if (next.kind == .machine) break;
                    if (e.kind == .session and next.kind == .session) break;
                    if (next.kind == .tab and std.mem.indexOf(u8, next.haystack, q) != null) return 1;
                }
                return 0;
            },
        }
    }
};
