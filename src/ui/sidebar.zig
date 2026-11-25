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
    /// Machines and sessions the user collapsed. Sessions are keyed by
    /// session id, owned.
    collapsed_machines: std.AutoHashMapUnmanaged(*Machine, void) = .empty,
    collapsed_sessions: std.StringHashMapUnmanaged(void) = .empty,
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
        const palette = gtk.Button.newFromIconName("modifier-key-symbolic");
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
        filter_toggle.as(gtk.Button).setIconName("filter-symbolic");
        filter_toggle.as(gtk.Widget).setTooltipText("Filter Tabs");
        filter_toggle.as(gtk.Widget).addCssClass("flat");
        const filter = gtk.SearchEntry.new();
        if (gobject.ext.cast(gtk.Entry, filter.as(gobject.Object))) |entry|
            entry.setIconFromIconName(.primary, null);
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
        var it = self.collapsed_sessions.iterator();
        while (it.next()) |kv| self.gpa.free(kv.key_ptr.*);
        self.collapsed_sessions.deinit(self.gpa);
        self.collapsed_machines.deinit(self.gpa);
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

        const show_activity = self.app.settings.getBool("sidebar.activity", true);
        for (self.app.machines.items) |m| {
            self.append(self.machineRow(m), .{
                .kind = .machine,
                .machine = m,
                .haystack = std.ascii.allocLowerString(a, m.title()) catch "",
            });
            if (m.state != .connected) continue;
            const machine_collapsed = self.collapsed_machines.contains(m);
            for (m.sessions.items) |s| {
                const sid = a.dupe(u8, s.session_id) catch continue;
                const name = if (s.label.len > 0) s.label else shortId(s.session_id);
                self.append(sessionRow(name, machine_collapsed or self.collapsed_sessions.contains(sid)), .{
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
                    const activity: ov.Summary = if (show_activity) m.overview.windowSummary(w) else .{};
                    // While a program says what it's doing, show that.
                    const detail = switch (activity.state) {
                        .working, .blocked, .@"error" => activity.text orelse pwd,
                        else => pwd,
                    };
                    const hay = std.fmt.allocPrint(a, "{s} {s} {s}", .{ title, detail, name }) catch continue;
                    _ = std.ascii.lowerString(hay, hay);
                    self.append(tabRow(title, detail, activity), .{
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
        const collapsed = self.collapsed_machines.contains(m);
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("machine-row");
        if (collapsed) row.as(gtk.Widget).addCssClass("collapsed");
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
                b.as(gtk.Widget).addCssClass("new-session");
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
        const expander = gtk.Image.newFromIconName(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
        expander.as(gtk.Widget).addCssClass("expander");
        box.append(expander.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn sessionRow(name: []const u8, collapsed: bool) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("session-row");
        if (collapsed) row.as(gtk.Widget).addCssClass("collapsed");
        const box = gtk.Box.new(.horizontal, 8);
        var buf: [256]u8 = undefined;
        const label = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "Session");
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("heading");
        label.as(gtk.Widget).addCssClass("dim-label");
        box.append(label.as(gtk.Widget));
        const expander = gtk.Image.newFromIconName(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
        expander.as(gtk.Widget).addCssClass("expander");
        box.append(expander.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));
        row.as(gtk.Widget).setTooltipText("Show or hide this session's tabs");
        return row;
    }

    fn tabRow(title: []const u8, detail: []const u8, activity: ov.Summary) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("tab-row");
        const box = gtk.Box.new(.horizontal, 10);

        const tile = gtk.Image.newFromIconName("utilities-terminal-symbolic");
        tile.as(gtk.Widget).addCssClass("tab-tile");
        tile.as(gtk.Widget).setValign(.center);
        // Agents and other programs that report their status get a tile of
        // their own.
        if (activity.app) |app| {
            tile.as(gtk.Widget).addCssClass("agent");
            var tip: [128]u8 = undefined;
            tile.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&tip, "{s}", .{app}, 0) catch "");
        }
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
        if (activityMark(activity.state)) |mark| box.append(mark);
        row.setChild(box.as(gtk.Widget));
        return row;
    }

    /// What a tab's programs are doing, at the end of its row.
    fn activityMark(state: ov.Activity) ?*gtk.Widget {
        const dot = struct {
            fn make(class: [:0]const u8, tip: [:0]const u8) *gtk.Widget {
                const l = gtk.Label.new("●");
                l.as(gtk.Widget).addCssClass(class);
                l.as(gtk.Widget).addCssClass("activity-dot");
                l.as(gtk.Widget).setTooltipText(tip);
                l.as(gtk.Widget).setValign(.center);
                return l.as(gtk.Widget);
            }
        }.make;
        switch (state) {
            .idle => return null,
            .working => {
                const s = adw.Spinner.new();
                s.as(gtk.Widget).setTooltipText("Working");
                s.as(gtk.Widget).setValign(.center);
                return s.as(gtk.Widget);
            },
            .blocked => return dot("accent", "Waiting for you"),
            .@"error" => return dot("error", "Failed"),
            .done => {
                const i = gtk.Image.newFromIconName("object-select-symbolic");
                i.as(gtk.Widget).addCssClass("success");
                i.as(gtk.Widget).setTooltipText("Done");
                return i.as(gtk.Widget);
            },
        }
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
            .machine => {
                self.toggleMachine(e.machine);
                self.list.invalidateFilter();
            },
            .session => {
                self.toggleSession(e.session_id);
                self.list.invalidateFilter();
            },
            .tab => self.app.showTab(e.machine, e.session_id, e.window_id),
        }
    }

    fn toggleMachine(self: *Sidebar, m: *Machine) void {
        if (self.collapsed_machines.contains(m)) {
            _ = self.collapsed_machines.remove(m);
        } else {
            self.collapsed_machines.put(self.gpa, m, {}) catch return;
        }
        self.syncExpander(m, null);
    }

    fn toggleSession(self: *Sidebar, session_id: []const u8) void {
        if (self.collapsed_sessions.fetchRemove(session_id)) |kv| {
            self.gpa.free(kv.key);
        } else {
            const key = self.gpa.dupe(u8, session_id) catch return;
            self.collapsed_sessions.put(self.gpa, key, {}) catch self.gpa.free(key);
        }
        self.syncExpander(null, session_id);
    }

    /// Point the expander of the machine or session row for `id` at its
    /// collapse state; the other argument is null.
    fn syncExpander(self: *Sidebar, m: ?*Machine, session_id: ?[]const u8) void {
        for (self.entries.items, 0..) |e, i| {
            const match = switch (e.kind) {
                .machine => m != null and e.machine == m.?,
                .session => session_id != null and std.mem.eql(u8, e.session_id, session_id.?),
                .tab => false,
            };
            if (!match) continue;
            const row = self.list.getRowAtIndex(@intCast(i)) orelse continue;
            const collapsed = switch (e.kind) {
                .machine => self.collapsed_machines.contains(e.machine),
                .session => self.collapsed_sessions.contains(e.session_id),
                .tab => false,
            };
            if (collapsed) row.as(gtk.Widget).addCssClass("collapsed") else row.as(gtk.Widget).removeCssClass("collapsed");
            const child = row.getChild() orelse continue;
            const expander = child.getLastChild() orelse continue;
            if (gobject.ext.cast(gtk.Image, expander)) |img|
                img.setFromIconName(if (collapsed) "pan-end-symbolic" else "pan-down-symbolic");
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
    /// With no query, collapsed machines and sessions hide their children.
    fn filterRow(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Sidebar = @ptrCast(@alignCast(data.?));
        var buf: [256]u8 = undefined;
        const q = self.query(&buf);
        const i: usize = @intCast(row.getIndex());
        if (i >= self.entries.items.len) return 1;
        const e = self.entries.items[i];
        if (q.len == 0) {
            return switch (e.kind) {
                .machine => 1,
                .session => @intFromBool(!self.collapsed_machines.contains(e.machine)),
                .tab => @intFromBool(!self.collapsed_machines.contains(e.machine) and
                    !self.collapsed_sessions.contains(e.session_id)),
            };
        }
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
