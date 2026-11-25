//! The content's header bar, in the two layouts:
//!
//! - Tabs in the sidebar (the default): the sidebar toggle, the tab's name
//!   over "session · machine". The bar can hide, and slides in
//!   over the terminal when the pointer reaches the top edge, like Black
//!   Box.
//! - Tabs in the header bar: a session switcher (session over machine)
//!   that opens a popover of every machine's sessions, and the tabs.
//!   There is no sidebar.
//!
//! Settings: "tabs.layout" is "sidebar" or "header"; "header.behavior" is
//! "hidden", "hover" or "always".

const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const Machine = @import("machine.zig").Machine;

/// How close to the top edge the pointer must come to show a hidden bar.
const hot_zone = 8;

pub const Layout = enum { sidebar, header };
pub const Behavior = enum { hidden, hover, always };

pub const Header = struct {
    app: *App,
    bar: *adw.HeaderBar,
    title: *adw.WindowTitle,
    toggle: *gtk.ToggleButton,
    switcher: *gtk.MenuButton,
    switcher_title: *gtk.Label,
    switcher_subtitle: *gtk.Label,
    switcher_list: *gtk.ListBox,
    popover: *gtk.Popover,
    tab_bar: *adw.TabBar,
    content: *adw.ToolbarView,
    split: *adw.OverlaySplitView,
    /// The palette button, at the end.
    end_box: *gtk.Box,
    layout: Layout = .sidebar,
    behavior: Behavior = .hover,
    hovering: bool = false,
    /// Sessions in the switcher's list, by row.
    choices: std.ArrayList(struct { machine: *Machine, session_id: []u8 }) = .empty,

    pub fn init(self: *Header, app: *App, sidebar: *gtk.Widget) void {
        const title = adw.WindowTitle.new("Rex", "");
        const bar = adw.HeaderBar.new();
        bar.setTitleWidget(title.as(gtk.Widget));

        const toggle = gtk.ToggleButton.new();
        toggle.as(gtk.Button).setIconName("sidebar-show-symbolic");
        toggle.as(gtk.Widget).setTooltipText("Sessions");
        toggle.as(gtk.Widget).addCssClass("flat");
        toggle.as(gtk.Widget).addCssClass("sidebar-toggle");
        bar.packStart(toggle.as(gtk.Widget));

        // The session switcher: session name over machine name.
        const switcher_title = gtk.Label.new("Rex");
        switcher_title.as(gtk.Widget).addCssClass("heading");
        switcher_title.setXalign(0);
        switcher_title.setEllipsize(.end);
        switcher_title.setMaxWidthChars(18);
        const switcher_subtitle = gtk.Label.new("");
        switcher_subtitle.as(gtk.Widget).addCssClass("caption");
        switcher_subtitle.as(gtk.Widget).addCssClass("dim-label");
        switcher_subtitle.setXalign(0);
        switcher_subtitle.setEllipsize(.end);
        switcher_subtitle.setMaxWidthChars(18);
        const labels = gtk.Box.new(.vertical, 0);
        labels.as(gtk.Widget).setValign(.center);
        labels.append(switcher_title.as(gtk.Widget));
        labels.append(switcher_subtitle.as(gtk.Widget));
        const switcher_box = gtk.Box.new(.horizontal, 8);
        switcher_box.append(gtk.Image.newFromIconName("computer-symbolic").as(gtk.Widget));
        switcher_box.append(labels.as(gtk.Widget));
        switcher_box.append(gtk.Image.newFromIconName("pan-down-symbolic").as(gtk.Widget));
        const switcher_list = gtk.ListBox.new();
        switcher_list.as(gtk.Widget).addCssClass("navigation-sidebar");
        switcher_list.setSelectionMode(.none);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(switcher_list.as(gtk.Widget));
        scroller.setPolicy(.never, .automatic);
        scroller.setPropagateNaturalHeight(1);
        scroller.setMaxContentHeight(480);
        scroller.as(gtk.Widget).setSizeRequest(280, -1);
        const popover = gtk.Popover.new();
        popover.setChild(scroller.as(gtk.Widget));
        const switcher = gtk.MenuButton.new();
        switcher.setChild(switcher_box.as(gtk.Widget));
        switcher.setPopover(popover);
        switcher.as(gtk.Widget).setTooltipText("Sessions");
        switcher.as(gtk.Widget).addCssClass("flat");
        bar.packStart(switcher.as(gtk.Widget));

        // The palette while the sidebar (which has its own) is hidden.
        const end_box = gtk.Box.new(.horizontal, 6);
        const palette = gtk.Button.newFromIconName("modifier-key-symbolic");
        palette.as(gtk.Widget).setTooltipText("Command Palette");
        palette.as(gtk.Actionable).setActionName("app.rex");
        palette.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString("client.palette.toggle"));
        end_box.append(palette.as(gtk.Widget));
        bar.packEnd(end_box.as(gtk.Widget));

        const tab_bar = adw.TabBar.new();
        tab_bar.setAutohide(0);
        tab_bar.setExpandTabs(0);
        tab_bar.as(gtk.Widget).addCssClass("inline");
        tab_bar.as(gtk.Widget).setHexpand(1);

        const content = adw.ToolbarView.new();
        content.setTopBarStyle(.raised);
        content.addTopBar(bar.as(gtk.Widget));

        const split = adw.OverlaySplitView.new();
        split.setSidebar(sidebar);
        split.setContent(content.as(gtk.Widget));
        _ = split.as(gobject.Object).bindProperty("show-sidebar", toggle.as(gobject.Object), "active", .{
            .bidirectional = true,
            .sync_create = true,
        });

        self.* = .{
            .app = app,
            .bar = bar,
            .title = title,
            .toggle = toggle,
            .switcher = switcher,
            .switcher_title = switcher_title,
            .switcher_subtitle = switcher_subtitle,
            .switcher_list = switcher_list,
            .popover = popover,
            .tab_bar = tab_bar,
            .content = content,
            .split = split,
            .end_box = end_box,
        };

        _ = gobject.Object.signals.notify.connect(split, *Header, &onSidebarShown, self, .{ .detail = "show-sidebar" });
        _ = gtk.Widget.signals.show.connect(popover.as(gtk.Widget), *Header, &onSwitcherOpened, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(switcher_list, *Header, &onSwitcherRow, self, .{});

        // Watch the pointer over the whole content, before the terminals
        // see it, to show a hidden bar at the top edge.
        const motion = gtk.EventControllerMotion.new();
        motion.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Header, &onMotion, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Header, &onLeave, self, .{});
        content.as(gtk.Widget).addController(motion.as(gtk.EventController));

        split.setShowSidebar(@intFromBool(app.settings.getBool("window.sidebar", true)));
        self.applySettings();
    }

    pub fn deinit(self: *Header) void {
        self.clearChoices();
        self.choices.deinit(self.app.gpa);
    }

    /// Read the layout and behavior settings and apply them.
    pub fn applySettings(self: *Header) void {
        const s = &self.app.settings;
        self.layout = std.meta.stringToEnum(Layout, s.getString("tabs.layout", "sidebar")) orelse .sidebar;
        self.behavior = std.meta.stringToEnum(Behavior, s.getString("header.behavior", "hover")) orelse .hover;

        const header_tabs = self.layout == .header;
        self.toggle.as(gtk.Widget).setVisible(@intFromBool(!header_tabs));
        self.switcher.as(gtk.Widget).setVisible(@intFromBool(header_tabs));
        self.bar.setTitleWidget(if (header_tabs) self.tab_bar.as(gtk.Widget) else self.title.as(gtk.Widget));
        if (header_tabs) {
            self.split.setShowSidebar(0);
            self.split.setCollapsed(1);
        } else {
            self.split.setCollapsed(0);
            self.split.setShowSidebar(@intFromBool(s.getBool("window.sidebar", true)));
        }
        self.updateReveal();
    }

    /// Whether the bar hides while not hovered.
    fn autoHides(self: *const Header) bool {
        return self.layout == .sidebar and self.behavior != .always;
    }

    fn updateReveal(self: *Header) void {
        const hides = self.autoHides();
        self.end_box.as(gtk.Widget).setVisible(@intFromBool(self.layout == .header or self.split.getShowSidebar() == 0));
        // Over the terminal, not above it, so showing it doesn't resize.
        self.content.setExtendContentToTopEdge(@intFromBool(hides));
        const show = !hides or (self.behavior == .hover and self.hovering);
        self.content.setRevealTopBars(@intFromBool(show));
    }

    fn onSidebarShown(split: *adw.OverlaySplitView, _: *gobject.ParamSpec, self: *Header) callconv(.c) void {
        if (self.layout == .sidebar) self.app.settings.setBool("window.sidebar", split.getShowSidebar() != 0);
        self.hovering = false;
        self.updateReveal();
    }

    fn onMotion(_: *gtk.EventControllerMotion, _: f64, y: f64, self: *Header) callconv(.c) void {
        if (!self.autoHides() or self.behavior != .hover) return;
        const bar_height: f64 = @floatFromInt(self.bar.as(gtk.Widget).getHeight());
        const near = if (self.hovering) y <= bar_height + hot_zone else y <= hot_zone;
        if (near == self.hovering) return;
        self.hovering = near;
        self.updateReveal();
    }

    fn onLeave(_: *gtk.EventControllerMotion, self: *Header) callconv(.c) void {
        if (!self.hovering) return;
        self.hovering = false;
        self.updateReveal();
    }

    /// Show the bar for a moment, as when a shortcut needs it.
    pub fn reveal(self: *Header) void {
        self.hovering = true;
        self.updateReveal();
    }

    // ------------------------------------------------------------------
    // Titles

    pub fn setTitle(self: *Header, title: [:0]const u8, subtitle: [:0]const u8) void {
        self.title.setTitle(title);
        self.title.setSubtitle(subtitle);
    }

    pub fn setSession(self: *Header, session: [:0]const u8, machine: [:0]const u8) void {
        self.switcher_title.setText(session);
        self.switcher_subtitle.setText(machine);
    }

    // ------------------------------------------------------------------
    // The session switcher

    fn clearChoices(self: *Header) void {
        for (self.choices.items) |c| self.app.gpa.free(c.session_id);
        self.choices.clearRetainingCapacity();
    }

    /// Fill the popover each time it opens: every reachable machine's
    /// sessions, with the shown one checked.
    fn onSwitcherOpened(_: *gtk.Widget, self: *Header) callconv(.c) void {
        const app = self.app;
        const list = self.switcher_list;
        list.removeAll();
        self.clearChoices();
        var buf: [256]u8 = undefined;
        for (app.machines.items) |m| {
            const head = gtk.Box.new(.horizontal, 8);
            head.append(gtk.Image.newFromIconName(if (m.is_local) "computer-symbolic" else "network-server-symbolic").as(gtk.Widget));
            const name = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{m.title()}, 0) catch "");
            name.as(gtk.Widget).addCssClass("heading");
            name.setXalign(0);
            name.as(gtk.Widget).setHexpand(1);
            head.append(name.as(gtk.Widget));
            if (m.state == .connected) {
                const b = gtk.Button.newFromIconName("window-new-symbolic");
                b.as(gtk.Widget).addCssClass("flat");
                b.as(gtk.Widget).setTooltipText("New Session");
                _ = gtk.Button.signals.clicked.connect(b, *Machine, &onNewSession, m, .{});
                head.append(b.as(gtk.Widget));
            } else if (m.state == .offline) {
                const w = gtk.Image.newFromIconName("dialog-warning-symbolic");
                w.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&buf, "Can't reach {s}. {s}", .{ m.title(), m.detail orelse "" }, 0) catch "");
                head.append(w.as(gtk.Widget));
            }
            const head_row = gtk.ListBoxRow.new();
            head_row.setActivatable(0);
            head_row.setChild(head.as(gtk.Widget));
            list.append(head_row.as(gtk.Widget));
            self.choices.append(app.gpa, .{ .machine = m, .session_id = app.gpa.dupe(u8, "") catch continue }) catch {};

            if (m.state != .connected) continue;
            for (m.sessions.items) |s| {
                const row = gtk.Box.new(.horizontal, 8);
                row.as(gtk.Widget).setMarginStart(28);
                const label = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{if (s.label.len > 0) s.label else s.session_id}, 0) catch "");
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).setHexpand(1);
                row.append(label.as(gtk.Widget));
                const current = if (app.view) |v| v.machine == m and std.mem.eql(u8, v.session_id, s.session_id) else false;
                const check = gtk.Image.newFromIconName("object-select-symbolic");
                check.as(gtk.Widget).setOpacity(if (current) 1 else 0);
                row.append(check.as(gtk.Widget));
                list.append(row.as(gtk.Widget));
                self.choices.append(app.gpa, .{ .machine = m, .session_id = app.gpa.dupe(u8, s.session_id) catch continue }) catch {};
            }
        }
        const add = gtk.Label.new("Add Machine…");
        add.setXalign(0);
        list.append(add.as(gtk.Widget));
    }

    fn onSwitcherRow(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Header) callconv(.c) void {
        const i: usize = @intCast(row.getIndex());
        self.popover.popdown();
        if (i >= self.choices.items.len) {
            // The last row: Add Machine.
            return @import("prefs/machines.zig").showAddMachine(self.app, self.bar.as(gtk.Widget));
        }
        const c = self.choices.items[i];
        if (c.session_id.len == 0) return;
        self.app.switchSession(c.machine, c.session_id);
    }

    fn onNewSession(_: *gtk.Button, m: *Machine) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(m.listener.ctx));
        app.header.popover.popdown();
        @import("actions.zig").newSessionOn(app, m);
    }
};
