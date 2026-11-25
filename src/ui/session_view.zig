//! One attached Rex session: its windows as tabs, their layouts, and a
//! pane for every block. `apply` reconciles the UI with a `session.view`:
//! blocks keep their pane (and data stream) for as long as they stay in a
//! window, however the layout around them changes.
//!
//! The server is the source of truth. Local actions (clicking a pane,
//! picking a tab) only send requests; the UI changes when the view that
//! results comes back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const tv = @import("terminal_view.zig");
const api = @import("api.zig");
const Incoming = @import("client.zig").Incoming;
const LayoutWidget = @import("layout_view.zig").LayoutWidget;
const Placement = @import("layout_view.zig").Placement;
const Divider = @import("layout_view.zig").Divider;
const mouse = @import("mouse.zig");
const gio = @import("gio");

const Pane = tv.Pane;
const log = std.log.scoped(.session_view);

const terminal_creator = "com.superlogical.terminal";

pub const Listener = struct {
    ctx: *anyopaque,
    /// The label, active tab, or the focused pane's title changed.
    changed: *const fn (ctx: *anyopaque) void,
};

/// A block in one of the session's windows.
const Block = struct {
    block_id: []u8,
    /// Set for terminal blocks.
    pane: ?*Pane = null,
    /// Shown for blocks we can't display. We hold a reference.
    placeholder: ?*gtk.Widget = null,

    fn widget(self: *Block) *gtk.Widget {
        if (self.pane) |p| return p.widgetPtr();
        return self.placeholder.?;
    }
};

/// A session window, shown as a tab.
pub const Tab = struct {
    window_id: []u8,
    layout: *LayoutWidget,
    page: *adw.TabPage,
    focused_block_id: ?[]u8 = null,
    /// The window's label.
    label: ?[]u8 = null,
    /// The blocks the tab shows, front to back. Rebuilt by every `apply`.
    visible: std.ArrayList(*Block) = .empty,
};

pub const SessionView = struct {
    gpa: Allocator,
    services: *tv.Services,
    session_id: []u8,
    label: []u8,
    listener: Listener,

    /// The tab strip's model; the app puts it in the window.
    tab_view: *adw.TabView,
    tabs: std.ArrayList(*Tab) = .empty,
    blocks: std.StringArrayHashMapUnmanaged(*Block) = .empty,

    /// The revision of the view we show, and the newest one we've heard of.
    revision: u64 = 0,
    newest_revision: u64 = 0,
    view_pending: bool = false,

    /// Set while we change the tab view ourselves, so its signals don't
    /// turn into requests.
    syncing: bool = false,
    /// Whether the app window is active. We claim the blocks we show only
    /// while it is, so two apps on one session don't fight over sizes.
    window_active: bool = false,

    /// Requests in flight that point at us. See `destroy`.
    outstanding: u32 = 0,
    dead: bool = false,

    handlers: [3]c_ulong = .{ 0, 0, 0 },

    pub fn create(gpa: Allocator, services: *tv.Services, session_id: []const u8, listener: Listener) !*SessionView {
        const self = try gpa.create(SessionView);
        errdefer gpa.destroy(self);
        const tab_view = adw.TabView.new();
        _ = tab_view.as(gobject.Object).refSink();
        self.* = .{
            .gpa = gpa,
            .services = services,
            .session_id = try gpa.dupe(u8, session_id),
            .label = try gpa.dupe(u8, ""),
            .listener = listener,
            .tab_view = tab_view,
        };
        self.handlers[0] = gobject.Object.signals.notify.connect(tab_view, *SessionView, &onSelectedPage, self, .{ .detail = "selected-page" });
        self.handlers[1] = adw.TabView.signals.close_page.connect(tab_view, *SessionView, &onClosePage, self, .{});
        self.handlers[2] = adw.TabView.signals.page_reordered.connect(tab_view, *SessionView, &onPageReordered, self, .{});
        return self;
    }

    /// Tear down the UI and every pane. The struct itself is freed once
    /// no request still points at it.
    pub fn destroy(self: *SessionView) void {
        const gpa = self.gpa;
        for (self.handlers) |h| gobject.signalHandlerDisconnect(self.tab_view.as(gobject.Object), h);

        for (self.tabs.items) |tab| tab.layout.clear();
        for (self.tabs.items) |tab| self.freeTab(tab);
        self.tabs.deinit(gpa);
        for (self.blocks.values()) |b| self.freeBlock(b);
        self.blocks.deinit(gpa);
        self.tab_view.as(gobject.Object).unref();

        gpa.free(self.session_id);
        gpa.free(self.label);
        self.dead = true;
        if (self.outstanding == 0) gpa.destroy(self);
    }

    /// Account for a finished request. Returns false if we were destroyed
    /// meanwhile (and are now freed).
    fn finish(self: *SessionView) bool {
        self.outstanding -= 1;
        if (!self.dead) return true;
        if (self.outstanding == 0) self.gpa.destroy(self);
        return false;
    }

    fn call(self: *SessionView, method: []const u8, payload: anytype, callback: @import("client.zig").ResponseFn) void {
        self.outstanding += 1;
        self.services.client.call(method, payload, self, callback);
    }

    // ------------------------------------------------------------------
    // Reconciling with the server's view

    /// Show `view`. `tickets` are data tickets that came with it (from
    /// `session.bootstrap`); other terminals get one from `data.connect`.
    pub fn apply(self: *SessionView, view: api.View, tickets: []const api.Ticket) void {
        if (view.revision < self.revision) return;
        self.revision = view.revision;
        self.newest_revision = @max(self.newest_revision, view.revision);
        if (view.label) |l| self.setLabel(l);

        const windows = view.windows orelse &.{};
        const me = self.services.client.clientId();

        // Blocks: keep the ones still in a window, add new ones, drop the rest.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        for (windows) |w| for (w.layers orelse &.{}) |layer| for (layer.blocks orelse &.{}) |b| {
            seen.put(self.gpa, b.block_id, {}) catch {};
            const block = self.ensureBlock(b, tickets) orelse continue;
            if (block.pane) |p| p.setOwned(if (b.owner) |o| std.mem.eql(u8, o, me) else false);
        };
        var i: usize = 0;
        while (i < self.blocks.count()) {
            const b = self.blocks.values()[i];
            if (seen.contains(b.block_id)) {
                i += 1;
                continue;
            }
            self.blocks.swapRemoveAt(i);
            self.freeBlock(b);
        }

        // Tabs, in the view's order.
        self.syncing = true;
        defer self.syncing = false;
        for (windows, 0..) |w, index| {
            const tab = self.findTab(w.window_id) orelse self.newTab(w.window_id) orelse continue;
            _ = self.tab_view.reorderPage(tab.page, @intCast(index));
            self.updateTab(tab, w);
        }
        i = 0;
        while (i < self.tabs.items.len) {
            const tab = self.tabs.items[i];
            const keep = for (windows) |w| {
                if (std.mem.eql(u8, w.window_id, tab.window_id)) break true;
            } else false;
            if (keep) {
                i += 1;
                continue;
            }
            _ = self.tabs.orderedRemove(i);
            tab.layout.clear();
            self.tab_view.closePage(tab.page);
            self.freeTab(tab);
        }

        // Keep our list in the server's order too.
        for (windows, 0..) |w, index| {
            if (index >= self.tabs.items.len) break;
            for (self.tabs.items[index..], index..) |t, j| if (std.mem.eql(u8, t.window_id, w.window_id)) {
                std.mem.swap(*Tab, &self.tabs.items[index], &self.tabs.items[j]);
                break;
            };
        }

        if (view.active_window_id) |id| if (self.findTab(id)) |tab| {
            self.tab_view.setSelectedPage(tab.page);
            tab.page.setNeedsAttention(0);
        };
        self.syncing = false;

        self.focusActive();
        self.claimVisible();
        self.listener.changed(self.listener.ctx);
    }

    fn ensureBlock(self: *SessionView, b: api.Block, tickets: []const api.Ticket) ?*Block {
        if (self.blocks.get(b.block_id)) |existing| return existing;
        const gpa = self.gpa;
        const block = gpa.create(Block) catch return null;
        block.* = .{ .block_id = gpa.dupe(u8, b.block_id) catch {
            gpa.destroy(block);
            return null;
        } };
        self.blocks.put(gpa, block.block_id, block) catch {
            gpa.free(block.block_id);
            gpa.destroy(block);
            return null;
        };

        const creator = b.creator_name orelse terminal_creator;
        if (!std.mem.eql(u8, creator, terminal_creator)) {
            block.placeholder = placeholder(b.label orelse creator);
            return block;
        }

        const pane = Pane.create(self.services, self.session_id, b.block_id) catch |err| {
            log.err("creating a pane for {s} failed: {}", .{ b.block_id, err });
            block.placeholder = placeholder("Can't show this terminal");
            return block;
        };
        pane.on_title = .{ .ctx = self, .func = onPaneTitle };
        block.pane = pane;

        for (tickets) |t| if (std.mem.eql(u8, t.block_id, b.block_id)) {
            pane.connect(t.ticket) catch |err| log.err("opening {s} failed: {}", .{ b.block_id, err });
            return block;
        };
        self.requestTicket(block.block_id);
        return block;
    }

    fn placeholder(text: []const u8) *gtk.Widget {
        const page = adw.StatusPage.new();
        page.setIconName("application-x-addon-symbolic");
        var buf: [256]u8 = undefined;
        page.setTitle(std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch "Block");
        page.setDescription("rex-gtk can't show this kind of block yet.");
        const w = page.as(gtk.Widget);
        _ = w.as(gobject.Object).refSink();
        return w;
    }

    fn freeBlock(self: *SessionView, b: *Block) void {
        if (b.pane) |p| p.destroy();
        if (b.placeholder) |w| {
            if (w.getParent() != null) w.unparent();
            w.as(gobject.Object).unref();
        }
        self.gpa.free(b.block_id);
        self.gpa.destroy(b);
    }

    const TicketReq = struct { view: *SessionView, block_id: []u8 };

    fn requestTicket(self: *SessionView, block_id: []const u8) void {
        const req = self.gpa.create(TicketReq) catch return;
        req.* = .{ .view = self, .block_id = self.gpa.dupe(u8, block_id) catch {
            self.gpa.destroy(req);
            return;
        } };
        self.outstanding += 1;
        self.services.client.call("data.connect", .{
            .session_id = self.session_id,
            .block_id = block_id,
            .data_ref_id = "terminal",
            .subprotocol = core.data.terminal_subprotocol,
        }, req, &onTicket);
    }

    fn onTicket(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *TicketReq = @ptrCast(@alignCast(ctx.?));
        const self = req.view;
        const gpa = self.gpa;
        defer {
            gpa.free(req.block_id);
            gpa.destroy(req);
        }
        const msg = maybe_msg orelse {
            _ = self.finish();
            return;
        };
        defer msg.deinit();
        if (!self.finish()) return;
        const res = api.parse(struct { ticket: []const u8 }, msg) orelse return;
        const block = self.blocks.get(req.block_id) orelse return;
        const pane = block.pane orelse return;
        if (pane.stream != null) return;
        pane.connect(res.ticket) catch |err| log.err("opening {s} failed: {}", .{ req.block_id, err });
    }

    /// The tab at a position in the server's window order.
    pub fn tabAt(self: *SessionView, index: usize) ?*Tab {
        return if (index < self.tabs.items.len) self.tabs.items[index] else null;
    }

    fn findTab(self: *SessionView, window_id: []const u8) ?*Tab {
        for (self.tabs.items) |t| if (std.mem.eql(u8, t.window_id, window_id)) return t;
        return null;
    }

    fn tabForPage(self: *SessionView, page: *adw.TabPage) ?*Tab {
        for (self.tabs.items) |t| if (t.page == page) return t;
        return null;
    }

    fn newTab(self: *SessionView, window_id: []const u8) ?*Tab {
        const gpa = self.gpa;
        const tab = gpa.create(Tab) catch return null;
        const layout = LayoutWidget.new();
        tab.* = .{
            .window_id = gpa.dupe(u8, window_id) catch {
                gpa.destroy(tab);
                return null;
            },
            .layout = layout,
            .page = self.tab_view.append(layout.as(gtk.Widget)),
        };
        layout.setResizeHandler(self, onDividerDragged);
        self.tabs.append(gpa, tab) catch {
            self.tab_view.closePage(tab.page);
            self.freeTab(tab);
            return null;
        };
        return tab;
    }

    fn freeTab(self: *SessionView, tab: *Tab) void {
        tab.visible.deinit(self.gpa);
        if (tab.focused_block_id) |f| self.gpa.free(f);
        if (tab.label) |l| self.gpa.free(l);
        self.gpa.free(tab.window_id);
        self.gpa.destroy(tab);
    }

    fn updateTab(self: *SessionView, tab: *Tab, w: api.Window) void {
        const gpa = self.gpa;
        if (tab.focused_block_id) |f| gpa.free(f);
        tab.focused_block_id = if (w.focused_block_id) |f| gpa.dupe(u8, f) catch null else null;

        var placements: std.ArrayList(Placement) = .empty;
        defer placements.deinit(gpa);
        var dividers: std.ArrayList(Divider) = .empty;
        defer dividers.deinit(gpa);
        tab.visible.clearRetainingCapacity();

        if (w.zoomed_block_id) |z| {
            if (self.blocks.get(z)) |b| {
                placements.append(gpa, .{ .widget = b.widget(), .rect = .{ 0, 0, 1, 1 }, .kind = .zoomed }) catch {};
                tab.visible.append(gpa, b) catch {};
            }
        } else for (w.layers orelse &.{}) |layer| {
            if (layer.state) |s| if (std.mem.eql(u8, s, "minimized")) continue;
            const kind: @import("layout_view.zig").Kind =
                if (std.mem.eql(u8, layer.kind, "tiled")) .tiled else .floating;
            if (layer.layout) |root| {
                self.addLeaves(tab, &placements, &root, kind);
                if (kind == .tiled) addDividers(gpa, &dividers, &root);
            }
        }

        if (placements.items.len > 1) for (placements.items, tab.visible.items) |*p, b| {
            p.dim = if (tab.focused_block_id) |f| !std.mem.eql(u8, f, b.block_id) else false;
        };
        tab.layout.setPlacements(placements.items, self.services.dark);
        tab.layout.setDividers(dividers.items);
        if (w.label) |l| if (tab.label == null or !std.mem.eql(u8, tab.label.?, l)) {
            if (tab.label) |old| gpa.free(old);
            tab.label = gpa.dupe(u8, l) catch null;
        };
        self.updateTabTitle(tab);
    }

    fn addLeaves(self: *SessionView, tab: *Tab, out: *std.ArrayList(Placement), node: *const api.LayoutNode, kind: @import("layout_view.zig").Kind) void {
        if (node.split) |s| {
            self.addLeaves(tab, out, s.before, kind);
            self.addLeaves(tab, out, s.after, kind);
            return;
        }
        const id = node.block_id orelse return;
        const b = self.blocks.get(id) orelse return;
        out.append(self.gpa, .{ .widget = b.widget(), .rect = node.rect, .kind = kind }) catch return;
        tab.visible.append(self.gpa, b) catch {
            _ = out.pop();
        };
    }

    /// A tab shows its window's label, unless that's the default
    /// ("Window 1a2b3c4d"); then the focused terminal's title.
    fn addDividers(gpa: Allocator, out: *std.ArrayList(Divider), node: *const api.LayoutNode) void {
        const s = node.split orelse return;
        const before = firstBlock(s.before) orelse return;
        const after = firstBlock(s.after) orelse return;
        out.append(gpa, .{
            .rect = node.rect,
            .vertical = std.mem.eql(u8, s.direction, "vertical"),
            .ratio = s.ratio,
            .before = before,
            .after = after,
        }) catch return;
        addDividers(gpa, out, s.before);
        addDividers(gpa, out, s.after);
    }

    fn firstBlock(node: *const api.LayoutNode) ?[]const u8 {
        if (node.block_id) |id| return id;
        const s = node.split orelse return null;
        return firstBlock(s.before) orelse firstBlock(s.after);
    }

    fn onDividerDragged(ctx: *anyopaque, d: Divider, ratio: f64) void {
        const self: *SessionView = @ptrCast(@alignCast(ctx));
        self.services.client.send("session.resize_pane", .{
            .session_id = self.session_id,
            .direction = if (d.vertical) "vertical" else "horizontal",
            .before_block_id = d.before,
            .after_block_id = d.after,
            .ratio = ratio,
        });
    }

    fn updateTabTitle(self: *SessionView, tab: *Tab) void {
        var buf: [256]u8 = undefined;
        const label = tab.label orelse "";
        const pane_title = self.focusedTitle(tab);
        const title = if (pane_title != null and (label.len == 0 or isDefaultWindowLabel(label)))
            pane_title.?
        else if (label.len > 0) label else "Terminal";
        tab.page.setTitle(std.fmt.bufPrintSentinel(&buf, "{s}", .{title}, 0) catch "Terminal");
        tab.page.setTooltip(std.fmt.bufPrintSentinel(&buf, "{s}", .{pane_title orelse label}, 0) catch "");
    }

    fn isDefaultWindowLabel(label: []const u8) bool {
        const prefix = "Window ";
        if (!std.mem.startsWith(u8, label, prefix)) return false;
        const rest = label[prefix.len..];
        if (rest.len != 8) return false;
        for (rest) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    fn setLabel(self: *SessionView, label: []const u8) void {
        if (std.mem.eql(u8, self.label, label)) return;
        const copy = self.gpa.dupe(u8, label) catch return;
        self.gpa.free(self.label);
        self.label = copy;
    }

    // ------------------------------------------------------------------
    // Focus and ownership

    pub fn selectedTab(self: *SessionView) ?*Tab {
        const page = self.tab_view.getSelectedPage() orelse return null;
        return self.tabForPage(page);
    }

    pub fn focusedPane(self: *SessionView, tab: *Tab) ?*Pane {
        const id = tab.focused_block_id orelse return null;
        const b = self.blocks.get(id) orelse return null;
        return b.pane;
    }

    fn focusedTitle(self: *SessionView, tab: *Tab) ?[]const u8 {
        const pane = self.focusedPane(tab) orelse return null;
        return pane.title;
    }

    /// The title of the focused pane in the selected tab.
    pub fn activeTitle(self: *SessionView) ?[]const u8 {
        const tab = self.selectedTab() orelse return null;
        return self.focusedTitle(tab);
    }

    /// Mark each window's focused pane, and give keyboard focus to the
    /// selected tab's.
    fn focusActive(self: *SessionView) void {
        for (self.blocks.values()) |b| if (b.pane) |p| {
            p.server_focused = false;
        };
        for (self.tabs.items) |tab| if (self.focusedPane(tab)) |p| {
            p.server_focused = true;
        };
        const tab = self.selectedTab() orelse return;
        const pane = self.focusedPane(tab) orelse return;
        const w = pane.widgetPtr();
        if (w.hasFocus() == 0) _ = w.grabFocus();
    }

    pub fn setWindowActive(self: *SessionView, active: bool) void {
        self.window_active = active;
        if (active) self.claimVisible();
    }

    /// Take ownership of the terminals the selected tab shows, so they
    /// take this window's size and theme.
    pub fn claimVisible(self: *SessionView) void {
        if (!self.window_active) return;
        const tab = self.selectedTab() orelse return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.gpa);
        for (tab.visible.items) |b| if (b.pane) |p| if (!p.owned) {
            ids.append(self.gpa, b.block_id) catch return;
        };
        if (ids.items.len == 0) return;
        self.call("session.own_block", .{
            .session_id = self.session_id,
            .block_ids = ids.items,
            .mode = "take",
        }, &onOwned);
    }

    fn onOwned(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *SessionView = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse {
            _ = self.finish();
            return;
        };
        defer msg.deinit();
        if (!self.finish()) return;
        const res = api.parse(struct {
            blocks: []const struct { block_id: []const u8, owner: ?[]const u8 = null },
        }, msg) orelse return;
        const me = self.services.client.clientId();
        for (res.blocks) |b| if (self.blocks.get(b.block_id)) |block| if (block.pane) |p| {
            p.setOwned(if (b.owner) |o| std.mem.eql(u8, o, me) else false);
        };
    }

    /// The font changed: every pane rebuilds its renderer.
    pub fn fontsChanged(self: *SessionView) void {
        for (self.blocks.values()) |b| if (b.pane) |p| p.fontsChanged();
    }

    /// The desktop's light/dark style changed.
    pub fn themeChanged(self: *SessionView) void {
        for (self.blocks.values()) |b| if (b.pane) |p| p.pushTheme();
        for (self.tabs.items) |tab| tab.layout.as(gtk.Widget).queueDraw();
    }

    // ------------------------------------------------------------------
    // Tab view signals

    fn onSelectedPage(_: *adw.TabView, _: *gobject.ParamSpec, self: *SessionView) callconv(.c) void {
        if (self.syncing) return;
        const tab = self.selectedTab() orelse return;
        tab.page.setNeedsAttention(0);
        self.services.client.send("session.focus_window", .{
            .session_id = self.session_id,
            .window_id = tab.window_id,
        });
        if (self.focusedPane(tab)) |p| _ = p.widgetPtr().grabFocus();
        self.claimVisible();
        self.listener.changed(self.listener.ctx);
    }

    /// The user dragged a tab to a new place: move the window to match.
    fn onPageReordered(view: *adw.TabView, page: *adw.TabPage, position: c_int, self: *SessionView) callconv(.c) void {
        if (self.syncing) return;
        const tab = self.tabForPage(page) orelse return;
        const next: ?*Tab = if (position + 1 < view.getNPages()) self.tabForPage(view.getNthPage(position + 1)) else null;
        if (next) |n| {
            self.services.client.send("session.move_window", .{ .session_id = self.session_id, .window_id = tab.window_id, .before_window_id = n.window_id });
        } else {
            self.services.client.send("session.move_window", .{ .session_id = self.session_id, .window_id = tab.window_id });
        }
    }

    fn onClosePage(view: *adw.TabView, page: *adw.TabPage, self: *SessionView) callconv(.c) c_int {
        if (self.syncing) return 0; // we're removing it: let it close
        // The user closed a tab: close the window on the server. The tab
        // goes away when the view without it arrives.
        if (self.tabForPage(page)) |tab| self.services.client.send("session.close_window", .{
            .session_id = self.session_id,
            .window_id = tab.window_id,
        });
        view.closePageFinish(page, 0);
        return 1;
    }

    // ------------------------------------------------------------------
    // Events

    /// A `session_event` for this session.
    pub fn handleEvent(self: *SessionView, msg: Incoming, event_type: []const u8, payload: std.json.Value) void {
        if (std.mem.eql(u8, event_type, "session_view_changed")) {
            const p = api.parseValue(struct { revision: u64 }, msg, payload) orelse return;
            if (p.revision <= self.revision) return;
            self.newest_revision = @max(self.newest_revision, p.revision);
            self.refreshView();
        } else if (std.mem.eql(u8, event_type, "block_owner_changed")) {
            const p = api.parseValue(struct { block_id: []const u8, owner: ?[]const u8 = null }, msg, payload) orelse return;
            const b = self.blocks.get(p.block_id) orelse return;
            const pane = b.pane orelse return;
            const me = self.services.client.clientId();
            pane.setOwned(if (p.owner) |o| std.mem.eql(u8, o, me) else false);
        } else if (std.mem.eql(u8, event_type, "session_label_changed")) {
            const p = api.parseValue(struct { label: []const u8 }, msg, payload) orelse return;
            self.setLabel(p.label);
            self.listener.changed(self.listener.ctx);
        } else if (std.mem.eql(u8, event_type, "block_event")) {
            const p = api.parseValue(struct {
                block_id: []const u8,
                name: []const u8,
                payload: std.json.Value = .null,
            }, msg, payload) orelse return;
            self.blockEvent(msg, p.block_id, p.name, p.payload);
        }
    }

    fn blockEvent(self: *SessionView, msg: Incoming, block_id: []const u8, name: []const u8, payload: std.json.Value) void {
        const b = self.blocks.get(block_id) orelse return;
        if (std.mem.eql(u8, name, "title_changed")) {
            const p = api.parseValue(struct { title: []const u8 = "" }, msg, payload) orelse return;
            if (b.pane) |pane| pane.setTitle(p.title);
        } else if (std.mem.eql(u8, name, "bell")) {
            const tab = self.tabShowing(b) orelse return;
            if (self.selectedTab() != tab) tab.page.setNeedsAttention(1);
            if (b.pane) |pane| pane.widgetPtr().errorBell();
        } else if (std.mem.eql(u8, name, "pwd_changed")) {
            const p = api.parseValue(struct { pwd: []const u8 = "" }, msg, payload) orelse return;
            if (b.pane) |pane| pane.setPwd(p.pwd);
        } else if (std.mem.eql(u8, name, "url_clicked")) {
            const p = api.parseValue(struct { url: []const u8 }, msg, payload) orelse return;
            if (b.pane) |pane| mouse.openUrl(pane, p.url);
        } else if (std.mem.eql(u8, name, "clipboard_written")) {
            const p = api.parseValue(struct { text: ?[]const u8 = null, id: ?u64 = null, bytes: u64 = 0 }, msg, payload) orelse return;
            const pane = b.pane orelse return;
            if (p.text) |text| {
                setClipboard(pane, text);
            } else if (p.bytes > 0) {
                self.readClipboard(block_id, p.id orelse 0);
            }
        } else if (std.mem.eql(u8, name, "desktop_notification")) {
            const p = api.parseValue(struct { title: []const u8 = "", body: []const u8 = "" }, msg, payload) orelse return;
            self.notify(p.title, p.body);
        } else {
            log.debug("block event {s} for {s}", .{ name, block_id });
        }
    }

    fn setClipboard(pane: *Pane, text: []const u8) void {
        const gpa = pane.services.gpa;
        const z = gpa.dupeSentinel(u8, text, 0) catch return;
        defer gpa.free(z);
        pane.widgetPtr().getClipboard().setText(z);
        log.debug("a program copied {d} bytes to the clipboard", .{text.len});
    }

    /// A copy too large for its event: read it with clipboard_read, in parts.
    const ClipboardRead = struct {
        view: *SessionView,
        block_id: []u8,
        id: u64,
        text: std.ArrayList(u8) = .empty,
    };

    fn readClipboard(self: *SessionView, block_id: []const u8, id: u64) void {
        const req = self.gpa.create(ClipboardRead) catch return;
        req.* = .{ .view = self, .block_id = self.gpa.dupe(u8, block_id) catch {
            self.gpa.destroy(req);
            return;
        }, .id = id };
        self.readClipboardPart(req);
    }

    fn readClipboardPart(self: *SessionView, req: *ClipboardRead) void {
        self.outstanding += 1;
        self.services.client.call("com.superlogical.terminal.clipboard_read", .{
            .session_id = self.session_id,
            .block_id = req.block_id,
            .args = .{ .id = req.id, .offset = req.text.items.len, .max_bytes = 983040 },
        }, req, &onClipboardPart);
    }

    fn onClipboardPart(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *ClipboardRead = @ptrCast(@alignCast(ctx.?));
        const self = req.view;
        const gpa = self.gpa;
        var done = true;
        defer if (done) {
            req.text.deinit(gpa);
            gpa.free(req.block_id);
            gpa.destroy(req);
        };
        const msg = maybe_msg orelse {
            _ = self.finish();
            return;
        };
        defer msg.deinit();
        if (!self.finish()) return;
        const res = api.parse(struct { id: u64, data: []const u8, eof: bool }, msg) orelse return;
        req.id = res.id;
        req.text.appendSlice(gpa, res.data) catch return;
        if (!res.eof and res.data.len > 0) {
            done = false;
            return self.readClipboardPart(req);
        }
        const b = self.blocks.get(req.block_id) orelse return;
        if (b.pane) |pane| setClipboard(pane, req.text.items);
    }

    fn notify(self: *SessionView, title: []const u8, body: []const u8) void {
        const app = self.services.app orelse return;
        const gpa = self.gpa;
        const t = gpa.dupeSentinel(u8, if (title.len > 0) title else "Terminal", 0) catch return;
        defer gpa.free(t);
        const b = gpa.dupeSentinel(u8, body, 0) catch return;
        defer gpa.free(b);
        const n = gio.Notification.new(t);
        defer n.as(gobject.Object).unref();
        n.setBody(b);
        app.sendNotification(null, n);
    }

    fn tabShowing(self: *SessionView, b: *Block) ?*Tab {
        for (self.tabs.items) |tab| for (tab.visible.items) |v| if (v == b) return tab;
        return null;
    }

    fn onPaneTitle(ctx: *anyopaque, _: *Pane) void {
        const self: *SessionView = @ptrCast(@alignCast(ctx));
        for (self.tabs.items) |tab| self.updateTabTitle(tab);
        self.listener.changed(self.listener.ctx);
    }

    /// Fetch the view again. Only one request is in flight at a time; a
    /// newer revision seen meanwhile triggers another when it returns.
    pub fn refreshView(self: *SessionView) void {
        if (self.view_pending) return;
        self.view_pending = true;
        self.call("session.view", .{ .session_id = self.session_id }, &onView);
    }

    fn onView(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *SessionView = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse {
            _ = self.finish();
            return;
        };
        defer msg.deinit();
        if (!self.finish()) return;
        self.view_pending = false;
        if (api.parse(api.View, msg)) |view| self.apply(view, &.{});
        if (self.newest_revision > self.revision) self.refreshView();
    }
};
