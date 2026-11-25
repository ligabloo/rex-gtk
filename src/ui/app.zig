//! The application: one window with every machine's sessions in a
//! sidebar and the selected session's windows as tabs.

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
const core = @import("core");
const Incoming = @import("client.zig").Incoming;
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const Settings = @import("settings.zig").Settings;
const Prefs = @import("prefs/window.zig").Prefs;
const tv = @import("terminal_view.zig");
const api = @import("api.zig");
const SessionView = @import("session_view.zig").SessionView;
const actions = @import("actions.zig");
const Keys = @import("keys.zig").Keys;
const prompts = @import("prompts.zig");

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

/// What main found in the environment.
pub const Startup = struct {
    /// This computer's server: REX_SERVER, or the default socket.
    local_address: []const u8,
    /// XDG_CONFIG_HOME, or HOME/.config; null if neither is set.
    config_home: ?[]const u8 = null,
    /// This computer's name, the client's label unless one is set.
    hostname: ?[]const u8 = null,
    ssh_env: core.ssh.Env = .{ .ssh_auth_sock = null, .xdg_runtime_dir = null, .home = null },
};

/// A row of the sidebar: a machine's heading, or one of its sessions.
const Row = struct {
    machine: *Machine,
    session: ?usize = null,
};

/// The session to show once its machine connects.
const Want = struct {
    machine_id: []u8,
    session_id: []u8,
};

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    startup: Startup,
    adw_app: *adw.Application,
    settings: Settings,

    window: ?*adw.ApplicationWindow = null,
    window_title: ?*adw.WindowTitle = null,
    content: ?*adw.ToolbarView = null,
    tab_bar: ?*adw.TabBar = null,
    session_list: ?*gtk.ListBox = null,
    split_view: ?*adw.OverlaySplitView = null,

    /// The terminal font size in points; starts at `options.font_size`.
    font_size: f32 = 11,
    /// Key bindings, sequences and modes.
    keys: Keys = undefined,
    /// Prompts from configuration file actions (rex.ui) being shown.
    prompts: prompts.Prompts = undefined,

    services: ?tv.Services = null,
    /// This computer's server first, then the user's hosts.
    machines: std.ArrayList(*Machine) = .empty,
    hosts_pending: bool = false,
    /// The sidebar's rows, in order.
    rows: std.ArrayList(Row) = .empty,
    list_syncing: bool = false,
    /// The session we show.
    view: ?*SessionView = null,
    /// The session to show again after a reconnect, or the one
    /// `--session HOST:SESSION` asked for.
    want: ?Want = null,
    /// --session applies to the first connection only.
    session_option_used: bool = false,
    /// The Preferences window, while it's open.
    prefs: ?*Prefs = null,

    pub fn create(gpa: Allocator, io: std.Io, startup: Startup, options: Options) !*App {
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .startup = startup,
            .adw_app = adw.Application.new(app_id, .{ .non_unique = true }),
            .settings = try .load(gpa, io, startup.config_home),
            .font_size = options.font_size,
        };
        self.keys = .init(gpa, self);
        self.prompts = .init(gpa, self);
        _ = gio.Application.signals.activate.connect(self.adw_app, *App, &onActivate, self, .{});
        _ = gio.Application.signals.shutdown.connect(self.adw_app, *App, &onShutdown, self, .{});
        return self;
    }

    extern fn g_unix_signal_add(signum: c_int, handler: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;

    /// SIGTERM or SIGINT: quit cleanly, so the server drops our client at
    /// once instead of keeping it for a reconnect.
    fn onQuitSignal(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.adw_app.as(gio.Application).quit();
        return 0;
    }

    /// Debug builds: SIGUSR1 drops the control connection and SIGUSR2 every
    /// data stream, without a close frame, to test reconnecting.
    fn onDropSignal(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.machines.items.len > 0) if (self.rex().client) |c| c.ctl.conn.shutdown();
        return 1;
    }

    fn onDropStreamsSignal(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.view) |v| v.dropStreams();
        return 1;
    }

    pub fn run(self: *App) u8 {
        if (@import("builtin").mode == .debug) {
            _ = g_unix_signal_add(@intCast(@intFromEnum(std.posix.SIG.USR1)), &onDropSignal, self);
            _ = g_unix_signal_add(@intCast(@intFromEnum(std.posix.SIG.USR2)), &onDropStreamsSignal, self);
        }
        _ = g_unix_signal_add(@intCast(@intFromEnum(std.posix.SIG.TERM)), &onQuitSignal, self);
        _ = g_unix_signal_add(@intCast(@intFromEnum(std.posix.SIG.INT)), &onQuitSignal, self);
        const status = gio.Application.run(self.adw_app.as(gio.Application), 0, null);
        // Run what shutdown queued, such as freeing streams after their
        // threads end.
        const ctx = glib.MainContext.default();
        while (ctx.iteration(0) != 0) {}
        return @intCast(status);
    }

    pub fn destroy(self: *App) void {
        self.keys.deinit();
        self.prompts.deinit();
        self.settings.deinit();
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
        header.packEnd(self.primaryMenu().as(gtk.Widget));
        const new_tab = gtk.Button.newFromIconName("tab-new-symbolic");
        new_tab.as(gtk.Widget).setTooltipText("New Tab");
        new_tab.as(gtk.Actionable).setActionName("app.rex");
        new_tab.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString("client.tab.new"));
        header.packEnd(new_tab.as(gtk.Widget));

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
        self.split_view = split;
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

    /// The menu behind the header bar's menu button. Each item performs a
    /// Rex action through the "app.rex" action.
    fn primaryMenu(self: *App) *gtk.MenuButton {
        const rex_action = gio.SimpleAction.new("rex", glib.VariantType.new("s"));
        _ = gio.SimpleAction.signals.activate.connect(rex_action, *App, &onRexAction, self, .{});
        self.adw_app.as(gio.ActionMap).addAction(rex_action.as(gio.Action));

        const sections = [_][]const [2][:0]const u8{
            &.{ .{ "New Tab", "client.tab.new" }, .{ "New Session", "session.new" } },
            &.{ .{ "Split Right", "pane.split.right" }, .{ "Split Down", "pane.split.down" }, .{ "Zoom Pane", "pane.zoom" }, .{ "Float Pane", "pane.float" }, .{ "Close Pane", "pane.close" } },
            &.{ .{ "Rename Tab…", "client.tab.rename" }, .{ "Rename Pane…", "pane.rename" }, .{ "Rename Session…", "session.rename" }, .{ "Close Session…", "session.close" } },
            &.{ .{ "Toggle Sidebar", "client.sidebar.toggle" }, .{ "Full Screen", "client.window.fullscreen.toggle" }, .{ "Preferences", "client.preferences" } },
        };
        const menu = gio.Menu.new();
        inline for (sections) |items| {
            const section = gio.Menu.new();
            for (items) |item| {
                const mi = gio.MenuItem.new(item[0], null);
                mi.setActionAndTargetValue("app.rex", glib.Variant.newString(item[1]));
                section.appendItem(mi);
                mi.as(gobject.Object).unref();
            }
            menu.appendSection(null, section.as(gio.MenuModel));
            section.as(gobject.Object).unref();
        }
        const button = gtk.MenuButton.new();
        button.setIconName("open-menu-symbolic");
        button.setMenuModel(menu.as(gio.MenuModel));
        button.as(gtk.Widget).setTooltipText("Main Menu");
        menu.as(gobject.Object).unref();
        return button;
    }

    fn onRexAction(_: *gio.SimpleAction, param: ?*glib.Variant, self: *App) callconv(.c) void {
        const p = param orelse return;
        actions.run(self, std.mem.span(p.getString(null)), .null);
    }

    pub fn toggleSidebar(self: *App) void {
        const split = self.split_view orelse return;
        split.setShowSidebar(@intFromBool(split.getShowSidebar() == 0));
    }

    /// Change the terminal font size for every pane.
    pub fn setFontSize(self: *App, points: f32) void {
        const services = if (self.services) |*s| s else return;
        if (points == self.font_size) return;
        const fonts = render.fonts.Fonts.create(self.gpa, .{
            .family = self.options.font_family,
            .size_points = points,
            .dpi = @intFromFloat(96 * self.windowScale()),
        }) catch |err| {
            log.err("loading the font at {d}pt failed: {}", .{ points, err });
            return;
        };
        const old = services.fonts;
        services.fonts = fonts;
        self.font_size = points;
        if (self.view) |v| v.fontsChanged();
        old.destroy();
    }

    /// Every key press in a terminal comes here first. Returns true if it
    /// was bound to an action, which then runs instead of typing.
    fn onShortcut(ctx: *anyopaque, pane: *tv.Pane, keyval: u32, keycode: u32, state: gdk.ModifierType, event: *gdk.KeyEvent, repeat: bool) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.keys.handle(pane, keyval, keycode, state, event, repeat);
    }

    /// A key sequence or mode started or ended: show it in the title.
    pub fn keyStateChanged(self: *App) void {
        self.updateTitle();
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
        if (self.prefs) |p| p.destroy();
        self.prefs = null;
        self.settings.unsubscribe(self);
        if (self.view) |v| v.destroy();
        self.view = null;
        for (self.machines.items) |m| m.destroy();
        self.machines.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.clearWant();
        if (self.services) |*s| {
            s.fonts.destroy();
            s.gpu.destroy();
        }
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
        if (self.window_title == null) return;
        const view = self.view orelse return self.setTitle("Rex", "");
        var buf: [256]u8 = undefined;
        const subtitle: []const u8 = if (self.keys.pendingPrefix().len > 0) sub: {
            var w: std.Io.Writer = .fixed(&buf);
            for (self.keys.pendingPrefix()) |k| w.print("{s} ", .{k}) catch {};
            w.writeAll("…") catch {};
            break :sub w.buffered();
        } else if (self.keys.modeName()) |m|
            std.fmt.bufPrint(&buf, "{s} mode", .{m}) catch m
        else
            view.activeTitle() orelse "";
        self.setTitle(if (view.label.len > 0) view.label else "Rex", subtitle);
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
    // Machines

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

        self.services = .{
            .gpa = self.gpa,
            .io = self.io,
            .gpu = gpu,
            .fonts = fonts,
            .dump_frame = self.options.dump_frame,
            .dark = self.adw_app.getStyleManager().getDark() != 0,
            .app = self.adw_app.as(gio.Application),
            .shortcut = .{ .ctx = self, .func = onShortcut },
        };
        _ = gobject.Object.signals.notify.connect(
            self.adw_app.getStyleManager(),
            *App,
            &onDarkChanged,
            self,
            .{ .detail = "dark" },
        );

        // --session HOST:SESSION shows a session on one of the hosts. A
        // session ID has a colon of its own ("session:…").
        if (self.options.session) |want| if (std.mem.indexOfScalar(u8, want, ':')) |colon| {
            const host = want[0..colon];
            if (!std.ascii.eqlIgnoreCase(host, "session") and colon + 1 < want.len) {
                self.setWant(host, want[colon + 1 ..]);
                self.session_option_used = true;
            }
        };

        // Or show the session shown last time, if asked to.
        if (self.options.session == null and std.mem.eql(u8, self.settings.getString("startup.session", "server"), "last")) {
            const mid = self.settings.getString("startup.last_machine", "");
            const sid = self.settings.getString("startup.last_session", "");
            if (mid.len > 0 and sid.len > 0) self.setWant(mid, sid);
        }
        self.settings.subscribe(.{ .ctx = self, .func = onSettingChanged });

        const local = try Machine.create(self.gpa, self.io, self.machineListener(), .{
            .id = "local",
            .label = "This Computer",
            .addresses = &.{self.startup.local_address},
            .is_local = true,
            .client_label = self.clientLabel(),
        });
        errdefer local.destroy();
        local.autostart = self.settings.getBool("startup.start_server", true);
        try self.machines.append(self.gpa, local);
        local.connect(false);
    }

    fn machineListener(self: *App) machine_mod.Listener {
        return .{
            .ctx = self,
            .connected = onMachineConnected,
            .event = onMachineEvent,
            .disconnected = onMachineDisconnected,
            .changed = onMachineChanged,
            .ssh_agent = sshAgent,
            .window = dialogParent,
        };
    }

    /// This computer's machine. Always present once started.
    pub fn localMachine(self: *App) *Machine {
        return self.machines.items[0];
    }

    /// The machine requests go to: the shown session's, else this
    /// computer's.
    pub fn rex(self: *App) *Machine {
        if (self.view) |v| return v.machine;
        return self.localMachine();
    }

    fn machineById(self: *App, id: []const u8) ?*Machine {
        for (self.machines.items) |m| if (std.mem.eql(u8, m.id, id)) return m;
        return null;
    }

    fn machineByLabel(self: *App, label: []const u8) ?*Machine {
        for (self.machines.items) |m| if (std.ascii.eqlIgnoreCase(m.label, label)) return m;
        return null;
    }

    fn setWant(self: *App, machine_id: []const u8, session_id: []const u8) void {
        self.clearWant();
        const mid = self.gpa.dupe(u8, machine_id) catch return;
        const sid = self.gpa.dupe(u8, session_id) catch {
            self.gpa.free(mid);
            return;
        };
        self.want = .{ .machine_id = mid, .session_id = sid };
    }

    fn clearWant(self: *App) void {
        const w = self.want orelse return;
        self.gpa.free(w.machine_id);
        self.gpa.free(w.session_id);
        self.want = null;
    }

    /// The session `want` names on `m`, if it's for `m`. A want made from
    /// --session names the host by label.
    fn wantFor(self: *App, m: *Machine) ?[]const u8 {
        const w = self.want orelse return null;
        if (std.mem.eql(u8, w.machine_id, m.id) or std.ascii.eqlIgnoreCase(w.machine_id, m.label)) return w.session_id;
        return null;
    }

    fn sshAgent(ctx: *anyopaque, gpa: Allocator) ?[]u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const ssh = core.ssh;
        const name = self.settings.getString("ssh.agent", "default");
        const agent: ssh.Agent = if (std.mem.eql(u8, name, "none"))
            .none
        else if (std.mem.eql(u8, name, "gnome_keyring"))
            .gnome_keyring
        else if (std.mem.eql(u8, name, "onepassword"))
            .onepassword
        else if (std.mem.eql(u8, name, "custom"))
            .{ .custom = self.settings.getString("ssh.agent_path", "") }
        else
            .default;
        const env = self.startup.ssh_env;
        const path = ssh.agentSocket(gpa, agent, env) catch return null;
        if (agent == .gnome_keyring) if (path) |p| {
            std.Io.Dir.cwd().access(self.io, p, .{}) catch {
                gpa.free(p);
                return ssh.legacyKeyringSocket(gpa, env) catch null;
            };
        };
        return path;
    }

    /// The ssh agent socket the settings choose, or null for none.
    /// Caller frees.
    pub fn sshAgentSocket(self: *App, gpa: Allocator) ?[]u8 {
        return sshAgent(self, gpa);
    }

    fn dialogParent(ctx: *anyopaque) ?*gtk.Widget {
        const self: *App = @ptrCast(@alignCast(ctx));
        return if (self.window) |w| w.as(gtk.Widget) else null;
    }

    fn onMachineConnected(ctx: *anyopaque, m: *Machine) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (m.is_local) {
            self.keys.fetch();
            self.refreshHosts();
        }

        // With nothing asked for, this computer's server picks the session
        // and attaches it in the same call. Otherwise attach nothing yet:
        // the session is found by ID or label once the list is in.
        const tickets = &[_]api.TicketRequest{.{}};
        const server_picks = m.is_local and self.view == null and self.want == null and
            (self.options.session == null or self.session_option_used);
        if (server_picks) {
            m.call("session.bootstrap", .{
                .event_scope = "all",
                .data_tickets = tickets,
            }, m, &onBootstrap);
        } else {
            m.call("session.bootstrap", .{
                .event_scope = "all",
                .attach_session_ids = &[_][]const u8{},
            }, m, &onBootstrap);
        }
    }

    /// The session on `m` that `text` names: its ID, its label, or the end
    /// of its ID.
    fn matchSession(m: *Machine, text: []const u8) ?[]const u8 {
        for (m.sessions.items) |s| if (std.mem.eql(u8, s.session_id, text)) return s.session_id;
        for (m.sessions.items) |s| if (std.mem.eql(u8, s.label, text)) return s.session_id;
        for (m.sessions.items) |s| if (std.mem.endsWith(u8, s.session_id, text)) return s.session_id;
        return null;
    }

    /// The listener's ctx is the app; responses carry the machine.
    fn appOf(m: *Machine) *App {
        return @ptrCast(@alignCast(m.listener.ctx));
    }

    fn onBootstrap(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const m: *Machine = @ptrCast(@alignCast(ctx.?));
        const self = appOf(m);
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const boot = api.parse(api.Bootstrap, msg) orelse return self.failed("session.bootstrap");

        if (boot.server_status) |st| if (st.host_id) |h| {
            if (m.host_id) |old| self.gpa.free(old);
            m.host_id = self.gpa.dupe(u8, h) catch null;
        };
        if (boot.attach_all) |all| m.setSessions(all.sessions);

        // The server picked and attached a session.
        if (boot.selected_session) |session| {
            const view = self.showSession(m, session.session.session_id) orelse return;
            view.apply(session.view, boot.data_tickets orelse &.{});
            return;
        }

        // A session we were asked for: after a reconnect, or by --session.
        var wanted: ?[]const u8 = self.wantFor(m);
        if (wanted == null and m.is_local and self.view == null and !self.session_option_used) wanted = self.options.session;
        if (m.is_local) self.session_option_used = true;
        if (wanted) |text| {
            const found = matchSession(m, text);
            if (found == null) log.warn("{s} has no session {s}", .{ m.label, text });
            const id = if (found) |f| self.gpa.dupe(u8, f) catch null else null;
            defer if (id) |x| self.gpa.free(x);
            if (self.wantFor(m) != null) self.clearWant();
            if (id) |x| return self.switchSession(m, x);
        }
        if (self.view == null and (wanted != null or m.is_local)) self.showFirstSession();
    }

    fn failed(self: *App, what: []const u8) void {
        log.err("{s} failed", .{what});
        if (self.view == null) self.showStatus("dialog-error-symbolic", "Rex request failed", what);
    }

    fn onMachineDisconnected(ctx: *anyopaque, m: *Machine) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (m.is_local) {
            self.prompts.deinit();
            self.prompts = .init(self.gpa, self);
        }
        const view = self.view orelse return;
        if (view.machine != m) return;
        // Show it again once the machine is back.
        self.setWant(m.id, view.session_id);
        view.destroy();
        self.view = null;
        self.updateTitle();
        self.showMachineStatus(m);
    }

    fn onMachineChanged(ctx: *anyopaque, m: *Machine) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.rebuildSidebar();
        if (self.prefs) |p| p.machinesChanged();
        if (self.view == null and self.statusMachine() == m) self.showMachineStatus(m);
    }

    /// The machine whose state the content area shows while no session
    /// is shown.
    fn statusMachine(self: *App) ?*Machine {
        if (self.want) |w| {
            if (self.machineById(w.machine_id)) |m| return m;
            if (self.machineByLabel(w.machine_id)) |m| return m;
        }
        if (self.machines.items.len == 0) return null;
        return self.localMachine();
    }

    fn showMachineStatus(self: *App, m: *Machine) void {
        var buf: [256]u8 = undefined;
        switch (m.state) {
            .idle, .connecting => {
                const t = std.fmt.bufPrintSentinel(&buf, "Connecting to {s}…", .{if (m.is_local) "Rex" else m.label}, 0) catch "Connecting…";
                self.showStatus("network-transmit-receive-symbolic", t, null);
            },
            .offline => {
                const t = std.fmt.bufPrintSentinel(&buf, "Can't reach {s}", .{if (m.is_local) "Rex" else m.label}, 0) catch "Can't connect";
                self.showStatus("network-offline-symbolic", t, m.detail);
            },
            .connected => {},
        }
    }

    // ------------------------------------------------------------------
    // Preferences

    pub fn showPreferences(self: *App) void {
        if (self.prefs) |p| return p.present();
        self.prefs = Prefs.create(self) catch |err| {
            log.err("opening Preferences failed: {}", .{err});
            return;
        };
        self.prefs.?.present();
    }

    /// The Preferences window closed and freed itself.
    pub fn prefsClosed(self: *App) void {
        self.prefs = null;
    }

    /// The keymap, and with it the configuration file's path, arrived.
    pub fn keymapLoaded(self: *App) void {
        if (self.prefs) |p| p.serverChanged();
    }

    /// How this client names itself to servers: --label, the setting, or
    /// the computer's name.
    pub fn clientLabel(self: *App) ?[]const u8 {
        if (self.options.label) |l| return l;
        const set = self.settings.getString("client.label", "");
        if (set.len > 0) return set;
        return self.startup.hostname;
    }

    fn onSettingChanged(ctx: *anyopaque, key: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const eq = std.mem.eql;
        if (eq(u8, key, "client.label")) {
            const label = self.clientLabel() orelse return;
            for (self.machines.items) |m| m.setClientLabel(label);
        } else if (eq(u8, key, "startup.start_server")) {
            self.localMachine().autostart = self.settings.getBool(key, true);
        } else if (eq(u8, key, "ssh.agent") or eq(u8, key, "ssh.agent_path")) {
            self.retrySsh();
        }
    }

    /// Try again every ssh machine that can't be reached, as after the
    /// ssh agent changed.
    pub fn retrySsh(self: *App) void {
        for (self.machines.items) |m| if (m.usesSsh() and m.state == .offline) m.connect(false);
    }

    /// Try again every machine that can't be reached.
    pub fn retryOffline(self: *App) void {
        for (self.machines.items) |m| if (m.state == .offline) m.connect(false);
    }

    // ------------------------------------------------------------------
    // Hosts

    fn refreshHosts(self: *App) void {
        if (self.hosts_pending) return;
        self.hosts_pending = true;
        self.localMachine().call("hosts.list", null, self, &onHostsList);
    }

    fn onHostsList(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.hosts_pending = false;
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const list = api.parse(api.Hosts, msg) orelse return;
        const hosts = list.hosts orelse &.{};
        const local = self.localMachine();
        // The same entries untyped, to send back fields we don't know.
        const raw = api.parse(struct { hosts: ?[]const std.json.Value = null }, msg);
        const raw_hosts: []const std.json.Value = if (raw) |r| r.hosts orelse &.{} else &.{};

        // Drop machines whose host is gone.
        var i: usize = 1;
        while (i < self.machines.items.len) {
            const m = self.machines.items[i];
            const keep = for (hosts) |h| {
                if (std.mem.eql(u8, h.id, m.id)) break true;
            } else false;
            if (keep) {
                i += 1;
                continue;
            }
            _ = self.machines.orderedRemove(i);
            self.removeMachine(m);
        }

        for (hosts, 0..) |h, hi| {
            if (h.id.len == 0) continue;
            // This computer may be in its own list, by its tailnet name.
            if (h.host_id) |hid| if (local.host_id) |lid| if (std.mem.eql(u8, hid, lid)) continue;
            const endpoints = h.endpoints orelse &.{};
            const json_text: ?[]u8 = if (hi < raw_hosts.len)
                std.json.Stringify.valueAlloc(self.gpa, raw_hosts[hi], .{}) catch null
            else
                null;
            defer if (json_text) |t| self.gpa.free(t);
            const from_config = h.source != null and h.source.? != .null;
            if (self.machineById(h.id)) |m| {
                if (json_text) |t| m.setHostJson(t, from_config);
                m.update(h.label, h.icon, endpoints);
                continue;
            }
            const m = Machine.create(self.gpa, self.io, self.machineListener(), .{
                .id = h.id,
                .label = h.label,
                .icon = h.icon,
                .addresses = endpoints,
                .client_label = self.clientLabel(),
            }) catch continue;
            if (json_text) |t| m.setHostJson(t, from_config);
            self.machines.append(self.gpa, m) catch {
                m.destroy();
                continue;
            };
            m.connect(false);
        }
        self.rebuildSidebar();
        if (self.prefs) |p| p.machinesChanged();
    }

    fn removeMachine(self: *App, m: *Machine) void {
        if (self.view) |v| if (v.machine == m) {
            v.destroy();
            self.view = null;
            self.updateTitle();
        };
        m.destroy();
        self.rebuildSidebar();
        if (self.view == null) self.showFirstSession();
    }

    /// Show any session at all, this computer's first.
    fn showFirstSession(self: *App) void {
        for (self.machines.items) |m| if (m.state == .connected and m.sessions.items.len > 0) {
            return self.switchSession(m, m.sessions.items[0].session_id);
        };
        if (self.statusMachine()) |m| if (m.state != .connected) return self.showMachineStatus(m);
        self.showStatus("utilities-terminal-symbolic", "No sessions", "Create one with `rex new`.");
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

    // ------------------------------------------------------------------
    // Sessions

    /// Replace the shown session with a new, empty view of `session_id`.
    fn showSession(self: *App, m: *Machine, session_id: []const u8) ?*SessionView {
        if (self.view) |old| {
            old.machine.send("session.detach", .{ .session_id = old.session_id });
            old.destroy();
            self.view = null;
        }
        const view = SessionView.create(self.gpa, &self.services.?, m, session_id, .{
            .ctx = self,
            .changed = onViewChanged,
        }) catch |err| {
            log.err("showing {s} failed: {}", .{ session_id, err });
            return null;
        };
        view.window_active = self.windowActive();
        self.view = view;
        self.settings.setString("startup.last_machine", m.id);
        self.settings.setString("startup.last_session", session_id);
        self.content.?.setContent(view.tab_view.as(gtk.Widget));
        self.tab_bar.?.setView(view.tab_view);
        self.selectCurrentRow();
        return view;
    }

    /// Switch to a session: detach from the one shown, attach to it.
    pub fn switchSession(self: *App, m: *Machine, session_id: []const u8) void {
        if (self.view) |v| if (v.machine == m and std.mem.eql(u8, v.session_id, session_id)) return;
        if (m.state != .connected) return;
        const view = self.showSession(m, session_id) orelse return;
        self.updateTitle();
        m.call("session.attach", .{ .session_id = view.session_id }, m, &onAttached);
    }

    /// Switch to a session by ID on whichever machine has it, preferring
    /// the shown session's machine.
    pub fn switchSessionById(self: *App, session_id: []const u8) void {
        const current = self.rex();
        if (current.hasSession(session_id)) return self.switchSession(current, session_id);
        for (self.machines.items) |m| if (m.hasSession(session_id)) return self.switchSession(m, session_id);
        // Too new to be listed yet.
        self.switchSession(current, session_id);
    }

    fn onAttached(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const m: *Machine = @ptrCast(@alignCast(ctx.?));
        const self = appOf(m);
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const res = api.parse(struct { view: api.View }, msg) orelse return;
        const view = self.view orelse return;
        // The user may have switched again meanwhile.
        const id = res.view.session_id orelse return;
        if (view.machine != m or !std.mem.eql(u8, id, view.session_id)) return;
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

    /// Every session of every connected machine, in sidebar order, for
    /// stepping through them.
    pub fn sessionCount(self: *App) usize {
        var n: usize = 0;
        for (self.machines.items) |m| if (m.state == .connected) {
            n += m.sessions.items.len;
        };
        return n;
    }

    /// Show the session `step` places from the shown one, wrapping.
    pub fn stepSession(self: *App, step: i64) void {
        const n = self.sessionCount();
        if (n == 0) return;
        var current: i64 = 0;
        var i: i64 = 0;
        if (self.view) |v| for (self.machines.items) |m| if (m.state == .connected) {
            for (m.sessions.items) |s| {
                if (m == v.machine and std.mem.eql(u8, s.session_id, v.session_id)) current = i;
                i += 1;
            }
        };
        var target: usize = @intCast(@mod(current + step, @as(i64, @intCast(n))));
        for (self.machines.items) |m| if (m.state == .connected) {
            if (target < m.sessions.items.len) return self.switchSession(m, m.sessions.items[target].session_id);
            target -= m.sessions.items.len;
        };
    }

    // ------------------------------------------------------------------
    // Sidebar

    fn rebuildSidebar(self: *App) void {
        const box = self.session_list orelse return;
        self.list_syncing = true;
        defer self.list_syncing = false;
        box.removeAll();
        self.rows.clearRetainingCapacity();
        for (self.machines.items) |m| {
            self.rows.append(self.gpa, .{ .machine = m }) catch return;
            box.append(self.machineRow(m).as(gtk.Widget));
            if (m.state != .connected) continue;
            for (m.sessions.items, 0..) |s, i| {
                self.rows.append(self.gpa, .{ .machine = m, .session = i }) catch return;
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (s.label.len > 0) s.label else s.session_id}, 0) catch "session";
                const label = gtk.Label.new(text);
                label.setXalign(0);
                label.setEllipsize(.end);
                label.as(gtk.Widget).setMarginStart(12);
                box.append(label.as(gtk.Widget));
            }
        }
        self.selectCurrentRow();
    }

    /// A machine's heading: its name, and a warning to try again when it
    /// can't be reached.
    fn machineRow(self: *App, m: *Machine) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setActivatable(0);
        row.setSelectable(0);
        const hbox = gtk.Box.new(.horizontal, 6);
        const icon = gtk.Image.newFromIconName(if (m.is_local) "computer-symbolic" else "network-server-symbolic");
        hbox.append(icon.as(gtk.Widget));
        var buf: [128]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{m.title()}, 0) catch "Machine";
        const label = gtk.Label.new(name);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("heading");
        hbox.append(label.as(gtk.Widget));
        switch (m.state) {
            .connecting => {
                const spinner = adw.Spinner.new();
                hbox.append(spinner.as(gtk.Widget));
            },
            .offline => {
                const button = gtk.Button.newFromIconName("dialog-warning-symbolic");
                button.as(gtk.Widget).addCssClass("flat");
                var tip: [512]u8 = undefined;
                const text = std.fmt.bufPrintSentinel(&tip, "Can't reach {s}. {s} Click to try again.", .{ m.title(), m.detail orelse "" }, 0) catch "Click to try again.";
                button.as(gtk.Widget).setTooltipText(text);
                _ = gtk.Button.signals.clicked.connect(button, *Machine, &onRetryClicked, m, .{});
                hbox.append(button.as(gtk.Widget));
            },
            .idle, .connected => {},
        }
        row.setChild(hbox.as(gtk.Widget));
        _ = self;
        return row;
    }

    fn onRetryClicked(_: *gtk.Button, m: *Machine) callconv(.c) void {
        m.connect(true);
    }

    fn selectCurrentRow(self: *App) void {
        const box = self.session_list orelse return;
        self.list_syncing = true;
        defer self.list_syncing = false;
        const view = self.view orelse return box.selectRow(null);
        for (self.rows.items, 0..) |r, i| {
            const si = r.session orelse continue;
            if (r.machine != view.machine) continue;
            if (std.mem.eql(u8, r.machine.sessions.items[si].session_id, view.session_id)) {
                box.selectRow(box.getRowAtIndex(@intCast(i)));
                return;
            }
        }
        box.selectRow(null);
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *App) callconv(.c) void {
        if (self.list_syncing) return;
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i >= self.rows.items.len) return;
        const entry = self.rows.items[i];
        const si = entry.session orelse return;
        if (si >= entry.machine.sessions.items.len) return;
        self.switchSession(entry.machine, entry.machine.sessions.items[si].session_id);
    }

    /// The shown session is gone: show another, or say there are none.
    fn sessionGone(self: *App, m: *Machine, session_id: []const u8) void {
        const view = self.view orelse return;
        if (view.machine != m or !std.mem.eql(u8, view.session_id, session_id)) return;
        view.destroy();
        self.view = null;
        self.updateTitle();
        // Prefer the session after the one that ended, then the one before.
        const items = m.sessions.items;
        const gone = for (items, 0..) |s, i| {
            if (std.mem.eql(u8, s.session_id, session_id)) break i;
        } else items.len;
        const next: ?usize = if (gone + 1 < items.len) gone + 1 else if (gone > 0 and items.len > 0) @min(gone, items.len) - 1 else null;
        if (next) |i| if (!std.mem.eql(u8, items[i].session_id, session_id)) return self.switchSession(m, items[i].session_id);
        self.showFirstSessionExcept(m, session_id);
    }

    fn showFirstSessionExcept(self: *App, m: *Machine, session_id: []const u8) void {
        for (self.machines.items) |other| if (other.state == .connected) {
            for (other.sessions.items) |s| {
                if (other == m and std.mem.eql(u8, s.session_id, session_id)) continue;
                return self.switchSession(other, s.session_id);
            }
        };
        self.showStatus("utilities-terminal-symbolic", "No sessions", "Create one with `rex new`.");
    }

    // ------------------------------------------------------------------
    // Events

    fn onMachineEvent(ctx: *anyopaque, m: *Machine, msg: Incoming) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        defer msg.deinit();
        const ev = msg.kind.event;
        const eq = std.mem.eql;

        if (eq(u8, ev.name, "event_dropped")) {
            // Fetch again whatever the event would have changed.
            const p = api.parseValue(struct { event_type: []const u8 = "", session_id: ?[]const u8 = null }, msg, ev.payload) orelse return;
            log.warn("{s} dropped a {s} event", .{ m.label, p.event_type });
            if (p.session_id) |sid| {
                if (self.view) |v| if (v.machine == m and eq(u8, v.session_id, sid)) v.refreshView();
            }
            if (m.is_local and eq(u8, p.event_type, "keymap_changed")) self.keys.fetch();
            if (m.is_local and eq(u8, p.event_type, "hosts_changed")) self.refreshHosts();
            m.refreshSessions();
        } else if (eq(u8, ev.name, "keymap_changed")) {
            if (!m.is_local) return;
            const p = api.parseValue(struct { hash: []const u8 = "" }, msg, ev.payload) orelse return;
            self.keys.changed(p.hash);
        } else if (eq(u8, ev.name, "hosts_changed")) {
            if (m.is_local) self.refreshHosts();
        } else if (eq(u8, ev.name, "tailscale_status_changed")) {
            if (m.is_local) if (self.prefs) |p| p.serverChanged();
        } else if (eq(u8, ev.name, "client_perform_requested")) {
            self.performRequested(m, msg, ev.payload);
        } else if (eq(u8, ev.name, "client_prompt_requested")) {
            // Prompts come from the configuration file's actions, which
            // run on this computer's server.
            if (m.is_local) self.prompts.show(msg, ev.payload);
        } else if (eq(u8, ev.name, "client_prompt_ended")) {
            if (!m.is_local) return;
            const p = api.parseValue(struct { call_id: []const u8 }, msg, ev.payload) orelse return;
            self.prompts.end(p.call_id);
        } else if (eq(u8, ev.name, "session_created") or eq(u8, ev.name, "session_moved")) {
            m.refreshSessions();
        } else if (eq(u8, ev.name, "session_destroyed")) {
            const p = api.parseValue(struct { session_id: []const u8 }, msg, ev.payload) orelse return;
            m.refreshSessions();
            self.sessionGone(m, p.session_id);
        } else if (eq(u8, ev.name, "session_event")) {
            const se = api.parseValue(api.SessionEvent, msg, ev.payload) orelse return;
            if (eq(u8, se.event.type, "session_label_changed")) m.refreshSessions();
            const view = self.view orelse return;
            if (view.machine != m or !eq(u8, se.session_id, view.session_id)) return;
            view.handleEvent(msg, se.event.type, se.event.payload);
        }
    }

    /// Another client asked us to perform one of our actions, such as
    /// `rex -C linux do pane.split.right`.
    fn performRequested(self: *App, m: *Machine, msg: Incoming, payload: std.json.Value) void {
        const req = api.parseValue(struct {
            call_id: []const u8,
            action: []const u8,
            args: std.json.Value = .null,
        }, msg, payload) orelse return;
        const Err = struct { code: []const u8, message: []const u8 };
        if (!self.settings.getBool("client.remote_control", true)) {
            const e: Err = .{ .code = "refused", .message = "remote control is turned off in rex-gtk's preferences" };
            return m.send("client.reply", .{ .call_id = req.call_id, .@"error" = e });
        }
        if (std.mem.startsWith(u8, req.action, "client.mode.")) {
            self.keys.perform(req.action, req.args, "api");
            return m.send("client.reply", .{ .call_id = req.call_id, .result = std.json.Value.null });
        }
        actions.perform(self, req.action, req.args) catch |err| {
            const e: Err = switch (err) {
                error.NotSupported => .{ .code = "not_supported", .message = "rex-gtk has no such action" },
                error.BadArgs => .{ .code = "refused", .message = "missing or wrong arguments" },
                error.NoTarget => .{ .code = "refused", .message = "nothing to act on" },
            };
            return m.send("client.reply", .{ .call_id = req.call_id, .@"error" = e });
        };
        m.send("client.reply", .{ .call_id = req.call_id, .result = std.json.Value.null });
    }
};
