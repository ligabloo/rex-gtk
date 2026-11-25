//! The application: one window with the server's sessions in a sidebar
//! and the selected session's windows as tabs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const glib = @import("glib");
const gsk = @import("gsk");
const render = @import("render");
const Client = @import("client.zig").Client;
const Incoming = @import("client.zig").Incoming;
const tv = @import("terminal_view.zig");
const api = @import("api.zig");
const SessionView = @import("session_view.zig").SessionView;

const log = std.log.scoped(.app);

pub const app_id = "dev.ligabloo.RexGtk";

pub const Options = struct {
    /// A session ID or label to show; otherwise the server picks one.
    session: ?[]const u8 = null,
    font_family: ?[:0]const u8 = null,
    font_size: f32 = 11,
    label: ?[]const u8 = null,
    /// Debugging: write every frame to this PNG path.
    dump_frame: ?[]const u8 = null,
    /// Debugging: save the whole window to this PNG path every second.
    screenshot: ?[:0]const u8 = null,
};

const SessionItem = struct {
    session_id: []u8,
    label: []u8,
};

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    socket_path: []const u8,
    adw_app: *adw.Application,

    window: ?*adw.ApplicationWindow = null,
    window_title: ?*adw.WindowTitle = null,
    content: ?*adw.ToolbarView = null,
    tab_bar: ?*adw.TabBar = null,
    session_list: ?*gtk.ListBox = null,

    services: ?tv.Services = null,
    /// The sessions in the sidebar, in the server's order.
    sessions: std.ArrayList(SessionItem) = .empty,
    list_syncing: bool = false,
    list_pending: bool = false,
    /// The session we show.
    view: ?*SessionView = null,

    pub fn create(gpa: Allocator, io: std.Io, socket_path: []const u8, options: Options) !*App {
        const self = try gpa.create(App);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .socket_path = socket_path,
            .adw_app = adw.Application.new(app_id, .{ .non_unique = true }),
        };
        _ = gio.Application.signals.activate.connect(self.adw_app, *App, &onActivate, self, .{});
        _ = gio.Application.signals.shutdown.connect(self.adw_app, *App, &onShutdown, self, .{});
        return self;
    }

    pub fn run(self: *App) u8 {
        const status = gio.Application.run(self.adw_app.as(gio.Application), 0, null);
        return @intCast(status);
    }

    pub fn destroy(self: *App) void {
        self.adw_app.unref();
        self.gpa.destroy(self);
    }

    // ------------------------------------------------------------------
    // Window

    fn onActivate(_: *adw.Application, self: *App) callconv(.c) void {
        if (self.window) |w| return w.as(gtk.Window).present();

        const window = adw.ApplicationWindow.new(self.adw_app.as(gtk.Application));
        window.as(gtk.Window).setDefaultSize(1100, 720);
        self.window = window;
        _ = gobject.Object.signals.notify.connect(window, *App, &onActiveChanged, self, .{ .detail = "is-active" });

        // Sidebar: the sessions.
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("navigation-sidebar");
        _ = gtk.ListBox.signals.row_selected.connect(list, *App, &onRowSelected, self, .{});
        self.session_list = list;
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.setPolicy(.never, .automatic);
        const side_header = adw.HeaderBar.new();
        side_header.setTitleWidget(adw.WindowTitle.new("Sessions", "").as(gtk.Widget));
        const sidebar = adw.ToolbarView.new();
        sidebar.addTopBar(side_header.as(gtk.Widget));
        sidebar.setContent(scroller.as(gtk.Widget));

        // Content: the session's windows as tabs.
        const title = adw.WindowTitle.new("Rex", "");
        self.window_title = title;
        const header = adw.HeaderBar.new();
        header.setTitleWidget(title.as(gtk.Widget));
        const toggle = gtk.ToggleButton.new();
        toggle.as(gtk.Button).setIconName("sidebar-show-symbolic");
        toggle.as(gtk.Widget).setTooltipText("Sessions");
        header.packStart(toggle.as(gtk.Widget));

        const tab_bar = adw.TabBar.new();
        tab_bar.setAutohide(1);
        self.tab_bar = tab_bar;

        const content = adw.ToolbarView.new();
        content.addTopBar(header.as(gtk.Widget));
        content.addTopBar(tab_bar.as(gtk.Widget));
        self.content = content;

        const split = adw.OverlaySplitView.new();
        split.setSidebar(sidebar.as(gtk.Widget));
        split.setContent(content.as(gtk.Widget));
        split.setShowSidebar(0);
        _ = split.as(gobject.Object).bindProperty("show-sidebar", toggle.as(gobject.Object), "active", .{
            .bidirectional = true,
            .sync_create = true,
        });

        window.setContent(split.as(gtk.Widget));
        self.showStatus("utilities-terminal-symbolic", "Connecting…", null);
        window.as(gtk.Window).present();
        if (self.options.screenshot != null) _ = glib.timeoutAdd(1000, &onScreenshot, self);

        self.start() catch |err| {
            log.err("startup failed: {}", .{err});
            self.showStatus("dialog-error-symbolic", "Can't connect to Rex", @errorName(err));
        };
    }

    /// Debugging aid (--screenshot): render the window to a PNG.
    fn onScreenshot(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        const window = self.window orelse return 0;
        const widget = window.as(gtk.Widget);
        const renderer = window.as(gtk.Native).getRenderer() orelse return 1;
        const paintable = gtk.WidgetPaintable.new(widget);
        defer paintable.as(gobject.Object).unref();
        const snap = gtk.Snapshot.new();
        paintable.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), @floatFromInt(widget.getWidth()), @floatFromInt(widget.getHeight()));
        const node = snap.freeToNode() orelse return 1;
        defer node.unref();
        const texture = renderer.renderTexture(node, null);
        defer texture.as(gobject.Object).unref();
        _ = texture.saveToPng(self.options.screenshot.?);
        return 1;
    }

    fn onShutdown(_: *adw.Application, self: *App) callconv(.c) void {
        if (self.view) |v| v.destroy();
        self.view = null;
        if (self.services) |*s| {
            s.client.destroy();
            s.fonts.destroy();
            s.gpu.destroy();
        }
        self.clearSessions();
        self.sessions.deinit(self.gpa);
    }

    fn showStatus(self: *App, icon: [:0]const u8, title: [:0]const u8, description: ?[]const u8) void {
        const page = adw.StatusPage.new();
        page.setIconName(icon);
        page.setTitle(title);
        if (description) |d| {
            const z = self.gpa.dupeSentinel(u8, d, 0) catch null;
            defer if (z) |s| self.gpa.free(s);
            page.setDescription(if (z) |s| s.ptr else null);
        }
        self.content.?.setContent(page.as(gtk.Widget));
        self.tab_bar.?.setView(null);
    }

    fn updateTitle(self: *App) void {
        const view = self.view orelse return self.setTitle("Rex", "");
        self.setTitle(if (view.label.len > 0) view.label else "Rex", view.activeTitle() orelse "");
    }

    fn setTitle(self: *App, title: []const u8, subtitle: []const u8) void {
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        const t = std.fmt.bufPrintSentinel(&a, "{s}", .{title}, 0) catch "Rex";
        const s = std.fmt.bufPrintSentinel(&b, "{s}", .{subtitle}, 0) catch "";
        self.window_title.?.setTitle(t);
        self.window_title.?.setSubtitle(s);
    }

    fn onActiveChanged(window: *adw.ApplicationWindow, _: *gobject.ParamSpec, self: *App) callconv(.c) void {
        const view = self.view orelse return;
        view.setWindowActive(window.as(gtk.Window).isActive() != 0);
    }

    fn windowActive(self: *App) bool {
        const w = self.window orelse return false;
        return w.as(gtk.Window).isActive() != 0;
    }

    // ------------------------------------------------------------------
    // Connection

    fn start(self: *App) !void {
        const gpu = try render.renderer.Gpu.create(self.gpa);
        errdefer gpu.destroy();
        gpu.release();
        const fonts = try render.fonts.Fonts.create(self.gpa, .{
            .family = self.options.font_family,
            .size_points = self.options.font_size,
            .dpi = @intFromFloat(96 * self.windowScale()),
        });
        errdefer fonts.destroy();

        const client = try Client.connect(self.gpa, self.io, self.socket_path, .{
            .kind = "app",
            .platform = "linux",
            .name = "rex-gtk",
            .version = "0.0.1",
            .label = self.options.label,
        }, .{
            .ctx = self,
            .event = onEvent,
            .disconnected = onDisconnected,
        });
        self.services = .{
            .gpa = self.gpa,
            .io = self.io,
            .socket_path = self.socket_path,
            .client = client,
            .gpu = gpu,
            .fonts = fonts,
            .dump_frame = self.options.dump_frame,
            .dark = self.adw_app.getStyleManager().getDark() != 0,
            .app = self.adw_app.as(gio.Application),
        };
        _ = gobject.Object.signals.notify.connect(
            self.adw_app.getStyleManager(),
            *App,
            &onDarkChanged,
            self,
            .{ .detail = "dark" },
        );

        // List the sessions, pick the one to show, then attach to it.
        client.call("session.list", null, self, &onFirstSessionList);
    }

    fn onDarkChanged(sm: *adw.StyleManager, _: *gobject.ParamSpec, self: *App) callconv(.c) void {
        const services = if (self.services) |*s| s else return;
        services.dark = sm.getDark() != 0;
        if (self.view) |v| v.themeChanged();
    }

    fn windowScale(self: *App) f64 {
        const window = self.window orelse return 1;
        const s = window.as(gtk.Widget).getScaleFactor();
        return @floatFromInt(@max(1, s));
    }

    fn rex(self: *App) *Client {
        return self.services.?.client;
    }

    fn onFirstSessionList(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const list = api.parse(api.SessionList, msg) orelse return self.failed("session.list");
        self.setSessions(list);

        var attach: ?[]const u8 = null;
        if (self.options.session) |want| {
            for (list.sessions) |s| {
                if (std.mem.eql(u8, s.session_id, want) or std.mem.eql(u8, s.label, want) or
                    std.mem.endsWith(u8, s.session_id, want)) attach = s.session_id;
            }
            if (attach == null) log.warn("no session matches {s}; letting the server pick", .{want});
        }

        const tickets = &[_]api.TicketRequest{.{}};
        if (attach) |id| {
            self.rex().call("session.bootstrap", .{
                .event_scope = "session",
                .attach_session_ids = &[_][]const u8{id},
                .data_tickets = tickets,
            }, self, &onBootstrap);
        } else {
            self.rex().call("session.bootstrap", .{
                .event_scope = "session",
                .data_tickets = tickets,
            }, self, &onBootstrap);
        }
    }

    fn onBootstrap(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const boot = api.parse(api.Bootstrap, msg) orelse return self.failed("session.bootstrap");

        const attached: ?api.Attached = if (boot.selected_session) |s| s else if (boot.attached_sessions) |list|
            (if (list.len > 0) list[0] else null)
        else
            null;
        const session = attached orelse {
            self.showStatus("utilities-terminal-symbolic", "No sessions", "Create one with `rex new`.");
            return;
        };
        const view = self.showSession(session.session.session_id) orelse return;
        view.apply(session.view, boot.data_tickets orelse &.{});
    }

    fn failed(self: *App, what: []const u8) void {
        log.err("{s} failed", .{what});
        self.showStatus("dialog-error-symbolic", "Rex request failed", what);
    }

    // ------------------------------------------------------------------
    // Sessions

    /// Replace the shown session with a new, empty view of `session_id`.
    fn showSession(self: *App, session_id: []const u8) ?*SessionView {
        if (self.view) |old| {
            self.rex().send("session.detach", .{ .session_id = old.session_id });
            old.destroy();
            self.view = null;
        }
        const view = SessionView.create(self.gpa, &self.services.?, session_id, .{
            .ctx = self,
            .changed = onViewChanged,
        }) catch |err| {
            log.err("showing {s} failed: {}", .{ session_id, err });
            return null;
        };
        view.window_active = self.windowActive();
        self.view = view;
        self.content.?.setContent(view.tab_view.as(gtk.Widget));
        self.tab_bar.?.setView(view.tab_view);
        self.selectCurrentRow();
        return view;
    }

    /// Switch to another session: detach from the one shown, attach to it.
    fn switchSession(self: *App, session_id: []const u8) void {
        if (self.view) |v| if (std.mem.eql(u8, v.session_id, session_id)) return;
        const view = self.showSession(session_id) orelse return;
        self.updateTitle();
        self.rex().call("session.attach", .{ .session_id = view.session_id }, self, &onAttached);
    }

    fn onAttached(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const res = api.parse(struct { view: api.View }, msg) orelse return;
        const view = self.view orelse return;
        // The user may have switched again meanwhile.
        const id = res.view.session_id orelse return;
        if (!std.mem.eql(u8, id, view.session_id)) return;
        view.apply(res.view, &.{});
    }

    fn onViewChanged(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const view = self.view orelse return;
        if (view.tabs.items.len == 0) {
            self.content.?.setContent(emptySession().as(gtk.Widget));
        } else if (self.content.?.getContent() != view.tab_view.as(gtk.Widget)) {
            self.content.?.setContent(view.tab_view.as(gtk.Widget));
            self.tab_bar.?.setView(view.tab_view);
        }
        self.updateTitle();
    }

    fn emptySession() *adw.StatusPage {
        const page = adw.StatusPage.new();
        page.setIconName("utilities-terminal-symbolic");
        page.setTitle("Empty session");
        page.setDescription("This session has no windows.");
        return page;
    }

    fn clearSessions(self: *App) void {
        for (self.sessions.items) |s| {
            self.gpa.free(s.session_id);
            self.gpa.free(s.label);
        }
        self.sessions.clearRetainingCapacity();
    }

    fn setSessions(self: *App, list: api.SessionList) void {
        self.clearSessions();
        const box = self.session_list.?;
        self.list_syncing = true;
        defer self.list_syncing = false;
        box.removeAll();
        for (list.sessions) |s| {
            const item: SessionItem = .{
                .session_id = self.gpa.dupe(u8, s.session_id) catch continue,
                .label = self.gpa.dupe(u8, s.label) catch continue,
            };
            self.sessions.append(self.gpa, item) catch continue;
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (s.label.len > 0) s.label else s.session_id}, 0) catch "session";
            const label = gtk.Label.new(text);
            label.setXalign(0);
            label.setEllipsize(.end);
            box.append(label.as(gtk.Widget));
        }
        self.selectCurrentRow();
    }

    fn selectCurrentRow(self: *App) void {
        const box = self.session_list orelse return;
        const view = self.view orelse return;
        self.list_syncing = true;
        defer self.list_syncing = false;
        for (self.sessions.items, 0..) |s, i| if (std.mem.eql(u8, s.session_id, view.session_id)) {
            box.selectRow(box.getRowAtIndex(@intCast(i)));
            return;
        };
        box.selectRow(null);
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *App) callconv(.c) void {
        if (self.list_syncing) return;
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i >= self.sessions.items.len) return;
        self.switchSession(self.sessions.items[i].session_id);
    }

    fn refreshSessions(self: *App) void {
        if (self.list_pending) return;
        self.list_pending = true;
        self.rex().call("session.list", null, self, &onSessionList);
    }

    fn onSessionList(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.list_pending = false;
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const list = api.parse(api.SessionList, msg) orelse return;
        self.setSessions(list);
    }

    /// The shown session is gone: show another, or say there are none.
    fn sessionGone(self: *App, session_id: []const u8) void {
        const view = self.view orelse return;
        if (!std.mem.eql(u8, view.session_id, session_id)) return;
        view.destroy();
        self.view = null;
        self.updateTitle();
        // Prefer the session after the one that ended, then the one before.
        const items = self.sessions.items;
        const gone = for (items, 0..) |s, i| {
            if (std.mem.eql(u8, s.session_id, session_id)) break i;
        } else items.len;
        const next: ?usize = if (gone + 1 < items.len) gone + 1 else if (gone > 0 and items.len > 0) @min(gone, items.len) - 1 else null;
        if (next) |i| if (!std.mem.eql(u8, items[i].session_id, session_id)) return self.switchSession(items[i].session_id);
        self.showStatus("utilities-terminal-symbolic", "No sessions", "Create one with `rex new`.");
    }

    // ------------------------------------------------------------------
    // Events

    fn onEvent(ctx: ?*anyopaque, msg: Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        defer msg.deinit();
        const ev = msg.kind.event;

        if (std.mem.eql(u8, ev.name, "session_created") or std.mem.eql(u8, ev.name, "session_moved")) {
            self.refreshSessions();
        } else if (std.mem.eql(u8, ev.name, "session_destroyed")) {
            const p = api.parseValue(struct { session_id: []const u8 }, msg, ev.payload) orelse return;
            self.refreshSessions();
            self.sessionGone(p.session_id);
        } else if (std.mem.eql(u8, ev.name, "session_event")) {
            const se = api.parseValue(api.SessionEvent, msg, ev.payload) orelse return;
            if (std.mem.eql(u8, se.event.type, "session_label_changed")) self.refreshSessions();
            const view = self.view orelse return;
            if (!std.mem.eql(u8, se.session_id, view.session_id)) return;
            view.handleEvent(msg, se.event.type, se.event.payload);
        }
    }

    fn onDisconnected(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        log.warn("lost the connection to the Rex server", .{});
        if (self.view) |v| v.destroy();
        self.view = null;
        self.showStatus("network-offline-symbolic", "Disconnected from Rex", "Restart rex-gtk to reconnect.");
    }
};
