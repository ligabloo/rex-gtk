//! The application: one window showing one Rex session.
//!
//! M2b scope: connect, attach to a session, and show the focused terminal of
//! its active window, following the server when focus moves. Tabs, splits
//! and a session list come in M3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const render = @import("render");
const Client = @import("client.zig").Client;
const Incoming = @import("client.zig").Incoming;
const tv = @import("terminal_view.zig");
const api = @import("api.zig");

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
};

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    socket_path: []const u8,
    adw_app: *adw.Application,

    window: ?*adw.ApplicationWindow = null,
    window_title: ?*adw.WindowTitle = null,
    toolbar: ?*adw.ToolbarView = null,

    services: ?tv.Services = null,
    session_id: ?[]u8 = null,
    view_revision: u64 = 0,
    view_pending: bool = false,
    pane: ?*tv.Pane = null,

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
        window.as(gtk.Window).setDefaultSize(1000, 700);
        self.window = window;

        const title = adw.WindowTitle.new("Rex", "");
        self.window_title = title;
        const header = adw.HeaderBar.new();
        header.setTitleWidget(title.as(gtk.Widget));

        const toolbar = adw.ToolbarView.new();
        toolbar.addTopBar(header.as(gtk.Widget));
        self.toolbar = toolbar;
        window.setContent(toolbar.as(gtk.Widget));
        self.showStatus("utilities-terminal-symbolic", "Connecting…", null);
        window.as(gtk.Window).present();

        self.start() catch |err| {
            log.err("startup failed: {}", .{err});
            self.showStatus("dialog-error-symbolic", "Can't connect to Rex", @errorName(err));
        };
    }

    fn onShutdown(_: *adw.Application, self: *App) callconv(.c) void {
        if (self.pane) |p| p.destroy();
        self.pane = null;
        if (self.services) |*s| {
            s.client.destroy();
            s.fonts.destroy();
            s.gpu.destroy();
        }
        if (self.session_id) |id| self.gpa.free(id);
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
        self.toolbar.?.setContent(page.as(gtk.Widget));
    }

    fn setTitle(self: *App, title: []const u8, subtitle: []const u8) void {
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        const t = std.fmt.bufPrintSentinel(&a, "{s}", .{title}, 0) catch "Rex";
        const s = std.fmt.bufPrintSentinel(&b, "{s}", .{subtitle}, 0) catch "";
        self.window_title.?.setTitle(t);
        self.window_title.?.setSubtitle(s);
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
        };
        _ = gobject.Object.signals.notify.connect(
            self.adw_app.getStyleManager(),
            *App,
            &onDarkChanged,
            self,
            .{ .detail = "dark" },
        );

        // Find the requested session, then attach to it.
        client.call("session.list", null, self, &onSessionList);
    }

    fn onDarkChanged(sm: *adw.StyleManager, _: *gobject.ParamSpec, self: *App) callconv(.c) void {
        const services = if (self.services) |*s| s else return;
        services.dark = sm.getDark() != 0;
        if (self.pane) |p| if (p.focused) p.pushTheme();
    }

    fn windowScale(self: *App) f64 {
        const window = self.window orelse return 1;
        const s = window.as(gtk.Widget).getScaleFactor();
        return @floatFromInt(@max(1, s));
    }

    fn onSessionList(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const list = api.parse(api.SessionList, msg) orelse return self.failed("session.list");

        var attach: ?[]const u8 = null;
        if (self.options.session) |want| {
            for (list.sessions) |s| {
                if (std.mem.eql(u8, s.session_id, want) or std.mem.eql(u8, s.label, want) or
                    std.mem.endsWith(u8, s.session_id, want)) attach = s.session_id;
            }
            if (attach == null) log.warn("no session matches {s}; letting the server pick", .{want});
        }

        const client = self.services.?.client;
        const tickets = &[_]api.TicketRequest{.{}};
        if (attach) |id| {
            client.call("session.bootstrap", .{
                .event_scope = "session",
                .attach_session_ids = &[_][]const u8{id},
                .data_tickets = tickets,
            }, self, &onBootstrap);
        } else {
            client.call("session.bootstrap", .{
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
        self.session_id = self.gpa.dupe(u8, session.session.session_id) catch return;
        self.applyView(session.view, boot.data_tickets orelse &.{});
    }

    fn failed(self: *App, what: []const u8) void {
        log.err("{s} failed", .{what});
        self.showStatus("dialog-error-symbolic", "Rex request failed", what);
    }

    /// Show the focused block of the view's active window.
    fn applyView(self: *App, view: api.View, tickets: []const api.Ticket) void {
        self.view_revision = view.revision;
        self.setTitle(view.label orelse "Rex", "");

        const window = view.activeWindow() orelse {
            self.showStatus("utilities-terminal-symbolic", "Empty session", null);
            return;
        };
        const block_id = window.zoomed_block_id orelse window.focused_block_id orelse return;
        self.setTitle(view.label orelse "Rex", window.label orelse "");

        if (self.pane) |p| if (std.mem.eql(u8, p.block_id, block_id)) return;

        // A ticket from bootstrap, or ask for one.
        for (tickets) |t| if (std.mem.eql(u8, t.block_id, block_id)) {
            return self.showPane(block_id, t.ticket);
        };
        const Req = struct { app: *App, block_id: []u8 };
        const req = self.gpa.create(Req) catch return;
        req.* = .{ .app = self, .block_id = self.gpa.dupe(u8, block_id) catch return };
        self.services.?.client.call("data.connect", .{
            .session_id = self.session_id.?,
            .block_id = block_id,
            .data_ref_id = "terminal",
            .subprotocol = core.data.terminal_subprotocol,
        }, req, &struct {
            fn done(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
                const r: *Req = @ptrCast(@alignCast(ctx.?));
                const app = r.app;
                defer {
                    app.gpa.free(r.block_id);
                    app.gpa.destroy(r);
                }
                const msg = maybe_msg orelse return;
                defer msg.deinit();
                const res = api.parse(struct { ticket: []const u8 }, msg) orelse return app.failed("data.connect");
                app.showPane(r.block_id, res.ticket);
            }
        }.done);
    }

    fn showPane(self: *App, block_id: []const u8, ticket: []const u8) void {
        if (self.pane) |p| p.destroy();
        self.pane = null;
        const pane = tv.Pane.create(&self.services.?, self.session_id.?, block_id, ticket) catch |err| {
            log.err("creating pane failed: {}", .{err});
            return;
        };
        self.pane = pane;
        const widget = pane.widget.as(gtk.Widget);
        self.toolbar.?.setContent(widget);
        _ = widget.grabFocus();
    }

    // ------------------------------------------------------------------
    // Events

    fn onEvent(ctx: ?*anyopaque, msg: Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        defer msg.deinit();
        const ev = msg.kind.event;
        if (!std.mem.eql(u8, ev.name, "session_event")) return;
        const se = api.parseValue(api.SessionEvent, msg, ev.payload) orelse return;
        const our = self.session_id orelse return;
        if (!std.mem.eql(u8, se.session_id, our)) return;

        if (std.mem.eql(u8, se.event.type, "session_view_changed")) {
            const p = api.parseValue(struct { revision: u64 }, msg, se.event.payload) orelse return;
            if (p.revision > self.view_revision) self.refreshView();
        } else if (std.mem.eql(u8, se.event.type, "session_destroyed")) {
            if (self.pane) |pn| pn.destroy();
            self.pane = null;
            self.showStatus("utilities-terminal-symbolic", "Session ended", null);
        }
    }

    fn refreshView(self: *App) void {
        if (self.view_pending) return;
        self.view_pending = true;
        self.services.?.client.call("session.view", .{ .session_id = self.session_id.? }, self, &onView);
    }

    fn onView(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.view_pending = false;
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const view = api.parse(api.View, msg) orelse return;
        if (view.revision < self.view_revision) return;
        if (view.activeWindow() == null) {
            if (self.pane) |p| p.destroy();
            self.pane = null;
            self.showStatus("utilities-terminal-symbolic", "Empty session", null);
            self.view_revision = view.revision;
            return;
        }
        self.applyView(view, &.{});
    }

    fn onDisconnected(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        log.warn("lost the connection to the Rex server", .{});
        if (self.pane) |p| p.destroy();
        self.pane = null;
        self.showStatus("network-offline-symbolic", "Disconnected from Rex", "Restart rex-gtk to reconnect.");
    }
};
