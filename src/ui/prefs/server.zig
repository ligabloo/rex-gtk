//! Preferences › Server: this computer's Rex server. Its status, the
//! addresses it listens on, its built-in Tailscale node, and its
//! configuration file. Everything here talks to the local server; the
//! Tailscale and stop methods only work over its local socket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const win = @import("window.zig");
const Prefs = win.Prefs;
const api = @import("../api.zig");
const Incoming = @import("../client.zig").Incoming;
const machine_mod = @import("../machine.zig");
const Machine = machine_mod.Machine;
const App = @import("../app.zig").App;
const pair = @import("pair.zig");

const log = std.log.scoped(.prefs);

pub const ServerPage = struct {
    prefs: *Prefs,
    /// Outlives the page, unlike `prefs`, for responses that arrive late.
    app: *App,
    gpa: Allocator,
    page: *adw.NavigationPage,
    body: *adw.PreferencesPage,
    groups: std.ArrayList(*adw.PreferencesGroup) = .empty,
    /// Data the current rows' signals point at; reset on each rebuild.
    arena: std.heap.ArenaAllocator,
    deferred: win.Deferred = .{},
    /// Ignore row signals while setting rows up.
    building: bool = false,

    status: ?Incoming = null,
    version: ?Incoming = null,
    /// The rex command's own version, to spot a server left running from
    /// an older install.
    cli_version: ?[]u8 = null,
    /// Requests in flight; the page is freed after the last one.
    outstanding: u32 = 0,
    dead: bool = false,

    /// Tailscale settings that take effect the next time it starts.
    hostname_entry: ?*adw.EntryRow = null,
    control_entry: ?*adw.EntryRow = null,
    only_mine: ?*adw.SwitchRow = null,

    pub fn create(prefs: *Prefs) !*ServerPage {
        const self = try prefs.gpa.create(ServerPage);
        const body = adw.PreferencesPage.new();
        self.* = .{
            .prefs = prefs,
            .app = prefs.app,
            .gpa = prefs.gpa,
            .page = win.navPage("Server", body.as(gtk.Widget)),
            .body = body,
            .arena = .init(prefs.gpa),
        };
        self.fetchCliVersion();
        self.fetch();
        return self;
    }

    pub fn destroy(self: *ServerPage) void {
        self.deferred.cancel();
        self.dead = true;
        self.page.as(gobject.Object).unref();
        if (self.outstanding == 0) self.free();
    }

    fn free(self: *ServerPage) void {
        if (self.status) |m| m.deinit();
        if (self.version) |m| m.deinit();
        if (self.cli_version) |v| self.gpa.free(v);
        self.groups.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// A request came back: false if the page is gone.
    fn finish(self: *ServerPage) bool {
        self.outstanding -= 1;
        if (!self.dead) return true;
        if (self.outstanding == 0) self.free();
        return false;
    }

    pub fn scheduleRefresh(self: *ServerPage) void {
        self.deferred.schedule(ServerPage, self, fetch);
    }

    fn local(self: *ServerPage) *Machine {
        return self.prefs.app.localMachine();
    }

    fn fetch(self: *ServerPage) void {
        const m = self.local();
        if (m.state != .connected) return self.rebuild();
        self.outstanding += 2;
        m.call("server.status", null, self, &onStatus);
        m.call("server.version", null, self, &onVersion);
    }

    fn onStatus(ctx: ?*anyopaque, msg: ?Incoming) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (msg) |x| x.deinit();
        if (self.status) |old| old.deinit();
        self.status = msg;
        self.rebuild();
    }

    fn onVersion(ctx: ?*anyopaque, msg: ?Incoming) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (msg) |x| x.deinit();
        if (self.version) |old| old.deinit();
        self.version = msg;
        self.rebuild();
    }

    fn fetchCliVersion(self: *ServerPage) void {
        const argv = [_:null]?[*:0]const u8{ "rex", "version", "--json", null };
        var err: ?*glib.Error = null;
        const proc = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_pipe = true, .stderr_silence = true }, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        self.outstanding += 1;
        proc.communicateUtf8Async(null, null, &onCliVersion, self);
    }

    fn onCliVersion(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *ServerPage = @ptrCast(@alignCast(data.?));
        const proc: *gio.Subprocess = @ptrCast(source.?);
        defer proc.as(gobject.Object).unref();
        var out: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        const ok = proc.communicateUtf8Finish(res, &out, null, &err) != 0;
        if (err) |e| e.free();
        if (!self.finish()) {
            if (ok) glib.free(out);
            return;
        }
        if (!ok) return;
        defer glib.free(out);
        const parsed = std.json.parseFromSlice(struct { rex_version: []const u8 = "" }, self.gpa, std.mem.span(out), .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        self.cli_version = self.gpa.dupe(u8, parsed.value.rex_version) catch null;
        self.rebuild();
    }

    // ------------------------------------------------------------------
    // Rows

    fn rebuild(self: *ServerPage) void {
        if (self.dead) return;
        self.building = true;
        defer self.building = false;
        for (self.groups.items) |g| self.body.remove(g);
        self.groups.clearRetainingCapacity();
        self.hostname_entry = null;
        self.control_entry = null;
        self.only_mine = null;
        _ = self.arena.reset(.retain_capacity);

        const m = self.local();
        const status: ?api.ServerStatus = if (m.state == .connected) if (self.status) |msg| api.parse(api.ServerStatus, msg) else null else null;
        const version: ?[]const u8 = if (m.state == .connected) if (self.version) |msg|
            (if (api.parse(struct { rex_version: []const u8 = "" }, msg)) |v| v.rex_version else null)
        else
            null else null;

        self.addStatusGroup(m, status, version);
        if (status) |st| {
            self.addConnections(st);
            self.addTailscale(st.tailscale orelse .{});
        }
        self.addConfiguration(m);
    }

    fn add(self: *ServerPage, g: *adw.PreferencesGroup) void {
        self.body.add(g);
        self.groups.append(self.gpa, g) catch {};
    }

    fn dupeZ(self: *ServerPage, text: []const u8) [:0]const u8 {
        return self.arena.allocator().dupeSentinel(u8, text, 0) catch "";
    }

    fn addStatusGroup(self: *ServerPage, m: *Machine, status: ?api.ServerStatus, version: ?[]const u8) void {
        const g = win.group(null, null);
        var buf: [256]u8 = undefined;
        const row = switch (m.state) {
            .connected => row: {
                const st = status orelse api.ServerStatus{};
                const sessions = st.session_count;
                const subtitle = win.z(&buf, "Running{s}{s} · {d} session{s}", .{
                    if (version != null) " · " else "",
                    version orelse "",
                    sessions,
                    if (sessions == 1) "" else "s",
                });
                const r = win.actionRow("Rex Server", subtitle);
                const stop = win.button("Stop Server…", "destructive-action");
                _ = gtk.Button.signals.clicked.connect(stop, *ServerPage, &onStopClicked, self, .{});
                r.addSuffix(stop.as(gtk.Widget));
                break :row r;
            },
            .connecting => row: {
                const r = win.actionRow("Rex Server", "Connecting…");
                r.addSuffix(adw.Spinner.new().as(gtk.Widget));
                break :row r;
            },
            .idle, .offline => row: {
                const r = win.actionRow("Rex Server", if (m.state == .idle) "Stopped" else self.dupeZ(m.detail orelse "Not running"));
                const start = win.button("Start Server", "suggested-action");
                _ = gtk.Button.signals.clicked.connect(start, *ServerPage, &onStartClicked, self, .{});
                r.addSuffix(start.as(gtk.Widget));
                break :row r;
            },
        };
        g.add(row.as(gtk.Widget));

        // A server left running by an older install keeps its old version
        // until it restarts.
        if (version) |v| if (self.cli_version) |cli| if (!std.mem.eql(u8, v, cli)) {
            const warn = win.actionRow("The server is out of date", win.z(&buf, "It runs Rex {s}, but rex is {s}. Restart it to update.", .{ v, cli }));
            warn.addPrefix(gtk.Image.newFromIconName("dialog-warning-symbolic").as(gtk.Widget));
            const restart = win.button("Restart Server…", null);
            _ = gtk.Button.signals.clicked.connect(restart, *ServerPage, &onRestartClicked, self, .{});
            warn.addSuffix(restart.as(gtk.Widget));
            g.add(warn.as(gtk.Widget));
        };
        self.add(g);
    }

    fn addConnections(self: *ServerPage, st: api.ServerStatus) void {
        const g = win.group("Connections", "Where this server accepts connections from rex, apps and your other devices.");
        for (st.listeners orelse &.{}) |l| {
            const transport = if (std.mem.eql(u8, l.transport, "unix")) "Local socket" else l.transport;
            const r = win.actionRow(self.dupeZ(l.endpoint), self.dupeZ(transport));
            r.as(adw.PreferencesRow).setTitleSelectable(1);
            self.addCopy(r, l.endpoint);
            g.add(r.as(gtk.Widget));
        }
        if (st.tailscale) |ts| if (ts.https) |h| if (h.url) |url| {
            const r = win.actionRow(self.dupeZ(url), "Tailnet address");
            r.as(adw.PreferencesRow).setTitleSelectable(1);
            self.addCopy(r, url);
            if (std.mem.eql(u8, h.state, "available")) {
                const b = win.button("Pair Device…", null);
                const p = self.arena.allocator().create(PairReq) catch return;
                p.* = .{ .page = self, .url = self.dupeZ(url), .dns_name = self.dupeZ(ts.dns_name orelse "") };
                _ = gtk.Button.signals.clicked.connect(b, *PairReq, &onPairClicked, p, .{});
                r.addSuffix(b.as(gtk.Widget));
            }
            g.add(r.as(gtk.Widget));
        };
        self.add(g);
    }

    const CopyReq = struct { page: *ServerPage, text: []const u8 };

    fn addCopy(self: *ServerPage, row: *adw.ActionRow, text: []const u8) void {
        const b = win.iconButton("edit-copy-symbolic", "Copy");
        const req = self.arena.allocator().create(CopyReq) catch return;
        req.* = .{ .page = self, .text = self.arena.allocator().dupe(u8, text) catch return };
        _ = gtk.Button.signals.clicked.connect(b, *CopyReq, &struct {
            fn f(_: *gtk.Button, r: *CopyReq) callconv(.c) void {
                r.page.prefs.copy(r.text);
            }
        }.f, req, .{});
        row.addSuffix(b.as(gtk.Widget));
    }

    const PairReq = struct { page: *ServerPage, url: [:0]const u8, dns_name: [:0]const u8 };

    fn onPairClicked(_: *gtk.Button, r: *PairReq) callconv(.c) void {
        pair.show(r.page.prefs, r.url, r.dns_name);
    }

    fn addTailscale(self: *ServerPage, ts: api.Tailscale) void {
        const g = win.group("Tailscale", "Serve this server on your tailnet, so your other devices can reach it without opening a port.");
        const eq = std.mem.eql;
        const state = ts.state;
        const enabled = !eq(u8, state, "disabled");
        var buf: [512]u8 = undefined;

        const serve = adw.SwitchRow.new();
        serve.as(adw.PreferencesRow).setTitle("Serve over Tailscale");
        serve.setActive(@intFromBool(enabled));
        _ = gobject.Object.signals.notify.connect(serve, *ServerPage, &onServeToggled, self, .{ .detail = "active" });
        g.add(serve.as(gtk.Widget));

        if (eq(u8, state, "starting")) {
            const r = win.actionRow("Starting…", null);
            r.addSuffix(adw.Spinner.new().as(gtk.Widget));
            g.add(r.as(gtk.Widget));
        } else if (eq(u8, state, "needs_login")) {
            const r = win.actionRow("Sign in to Tailscale", "Open the sign-in page to add this server to your tailnet.");
            const b = win.button("Sign In…", "suggested-action");
            _ = gtk.Button.signals.clicked.connect(b, *ServerPage, &onSignInClicked, self, .{});
            r.addSuffix(b.as(gtk.Widget));
            g.add(r.as(gtk.Widget));
        } else if (eq(u8, state, "needs_machine_approval")) {
            g.add(win.actionRow("Waiting for approval", "An admin of your tailnet has to approve this device.").as(gtk.Widget));
        } else if (eq(u8, state, "running")) {
            const who = if (ts.account) |a| a.login_name else "";
            const subtitle = if (ts.tailnet_name) |t| win.z(&buf, "{s} · {s}", .{ who, t }) else win.z(&buf, "{s}", .{who});
            const r = win.actionRow("Signed in", subtitle);
            const b = win.button("Sign Out…", null);
            _ = gtk.Button.signals.clicked.connect(b, *ServerPage, &onSignOutClicked, self, .{});
            r.addSuffix(b.as(gtk.Widget));
            g.add(r.as(gtk.Widget));
        }
        if (ts.@"error") |e| {
            const r = win.actionRow("Tailscale reported a problem", self.dupeZ(e));
            r.addPrefix(gtk.Image.newFromIconName("dialog-warning-symbolic").as(gtk.Widget));
            g.add(r.as(gtk.Widget));
        }

        const only_mine = adw.SwitchRow.new();
        only_mine.as(adw.PreferencesRow).setTitle("Only allow my account");
        only_mine.as(adw.ActionRow).setSubtitle("Other members of the tailnet can't connect, even if its access rules let them reach this device.");
        only_mine.setActive(@intFromBool(!ts.allow_tailnet_members));
        _ = gobject.Object.signals.notify.connect(only_mine, *ServerPage, &onOnlyMineToggled, self, .{ .detail = "active" });
        g.add(only_mine.as(gtk.Widget));
        self.only_mine = only_mine;

        // The device's name is the first label of its DNS name.
        const dns = ts.dns_name orelse "";
        const host = if (std.mem.indexOfScalar(u8, dns, '.')) |i| dns[0..i] else dns;
        const name = adw.EntryRow.new();
        name.as(adw.PreferencesRow).setTitle("Device name");
        name.as(gtk.Editable).setText(self.dupeZ(host));
        name.setShowApplyButton(1);
        _ = adw.EntryRow.signals.apply.connect(name, *ServerPage, &onRenameApply, self, .{});
        g.add(name.as(gtk.Widget));
        self.hostname_entry = name;

        const control = adw.EntryRow.new();
        control.as(adw.PreferencesRow).setTitle("Control server (leave empty for Tailscale's)");
        control.as(gtk.Editable).setText(self.dupeZ(ts.control_url orelse ""));
        control.setShowApplyButton(1);
        control.as(gtk.Widget).setSensitive(@intFromBool(!enabled));
        control.as(gtk.Widget).setTooltipText(if (enabled) "Turn Tailscale off to change the control server" else "Such as a Headscale server");
        g.add(control.as(gtk.Widget));
        self.control_entry = control;

        self.add(g);
    }

    fn addConfiguration(self: *ServerPage, m: *Machine) void {
        const keys = &self.prefs.app.keys;
        const g = win.group("Configuration", null);
        const path = keys.config_path;
        const subtitle: [:0]const u8 = if (path.len == 0)
            "Unknown until the server is running"
        else if (keys.config_exists)
            self.dupeZ(path)
        else
            self.dupeZ(std.fmt.allocPrint(self.arena.allocator(), "{s} (not created yet)", .{path}) catch path);
        const r = win.actionRow("Configuration file", subtitle);
        const open = win.button("Open", null);
        open.as(gtk.Widget).setSensitive(@intFromBool(path.len > 0 and keys.config_exists));
        _ = gtk.Button.signals.clicked.connect(open, *ServerPage, &onOpenConfig, self, .{});
        r.addSuffix(open.as(gtk.Widget));
        const reload = win.button("Reload", null);
        reload.as(gtk.Widget).setSensitive(@intFromBool(m.state == .connected));
        _ = gtk.Button.signals.clicked.connect(reload, *ServerPage, &onReload, self, .{});
        r.addSuffix(reload.as(gtk.Widget));
        g.add(r.as(gtk.Widget));
        self.add(g);
    }

    // ------------------------------------------------------------------
    // Server

    fn onStopClicked(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        win.confirm(self.prefs, "Stop the Rex Server?", "Every session on this computer ends, along with the programs running in it.", "Stop Server", self, &struct {
            fn go(ctx: *anyopaque) void {
                const s: *ServerPage = @ptrCast(@alignCast(ctx));
                s.stopServer(false);
            }
        }.go);
    }

    fn onRestartClicked(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        win.confirm(self.prefs, "Restart the Rex Server?", "Every session on this computer ends, along with the programs running in it.", "Restart Server", self, &struct {
            fn go(ctx: *anyopaque) void {
                const s: *ServerPage = @ptrCast(@alignCast(ctx));
                s.stopServer(true);
            }
        }.go);
    }

    fn stopServer(self: *ServerPage, restart: bool) void {
        self.outstanding += 1;
        self.local().call("server.stop", .{}, self, if (restart) &onStoppedRestart else &onStopped);
    }

    fn onStopped(ctx: ?*anyopaque, msg: ?Incoming) void {
        stopped(ctx, msg, false);
    }

    fn onStoppedRestart(ctx: ?*anyopaque, msg: ?Incoming) void {
        stopped(ctx, msg, true);
    }

    fn stopped(ctx: ?*anyopaque, maybe_msg: ?Incoming, restart: bool) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const alive = self.finish();
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err) |e| {
            if (alive) self.prefs.toast("Couldn't stop the server: {s}", .{e.message});
            return;
        }
        // Don't let the reconnect start it again.
        app.localMachine().disconnect();
        if (restart) _ = glib.timeoutAdd(800, &startLater, app);
    }

    fn startLater(data: ?*anyopaque) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(data.?));
        machine_mod.startLocalServer();
        app.localMachine().connect(false);
        return 0;
    }

    fn onStartClicked(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        machine_mod.startLocalServer();
        // Give it a moment before the first try.
        _ = glib.timeoutAdd(300, &connectLater, self.prefs.app);
    }

    fn connectLater(data: ?*anyopaque) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(data.?));
        app.localMachine().connect(false);
        return 0;
    }

    // ------------------------------------------------------------------
    // Tailscale

    /// Responses that only matter if they failed; the status event
    /// updates the page.
    fn onTailscaleDone(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (maybe_msg) |m| m.deinit();
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err) |e| self.prefs.toast("Tailscale: {s}", .{e.message});
        self.scheduleRefresh();
    }

    fn tailscaleCall(self: *ServerPage, method: []const u8, payload: anytype) void {
        self.outstanding += 1;
        self.local().call(method, payload, self, &onTailscaleDone);
    }

    fn entryText(e: ?*adw.EntryRow) []const u8 {
        const row = e orelse return "";
        return std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " ");
    }

    fn enable(self: *ServerPage) void {
        const allow = if (self.only_mine) |s| s.getActive() == 0 else false;
        const hostname = entryText(self.hostname_entry);
        const control = entryText(self.control_entry);
        self.tailscaleCall("server.tailscale.enable", .{
            .allow_tailnet_members = allow,
            .hostname = if (hostname.len > 0) hostname else null,
            .control_url = if (control.len > 0) control else null,
        });
    }

    fn onServeToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *ServerPage) callconv(.c) void {
        if (self.building) return;
        if (row.getActive() != 0) self.enable() else self.tailscaleCall("server.tailscale.disable", .{});
    }

    fn onOnlyMineToggled(_: *adw.SwitchRow, _: *gobject.ParamSpec, self: *ServerPage) callconv(.c) void {
        if (self.building) return;
        // Enabling again with the new rule updates a running node. A node
        // that's off just keeps the choice for when it starts.
        const st = self.currentTailscale() orelse return;
        if (!std.mem.eql(u8, st.state, "disabled")) self.enable();
    }

    fn currentTailscale(self: *ServerPage) ?api.Tailscale {
        const msg = self.status orelse return null;
        const st = api.parse(api.ServerStatus, msg) orelse return null;
        return st.tailscale orelse .{};
    }

    fn onRenameApply(row: *adw.EntryRow, self: *ServerPage) callconv(.c) void {
        const name = entryText(row);
        if (name.len == 0) return;
        const st = self.currentTailscale() orelse return;
        if (std.mem.eql(u8, st.state, "disabled")) {
            self.prefs.toast("The name is used when Tailscale starts", .{});
            return;
        }
        self.tailscaleCall("server.tailscale.rename", .{ .hostname = name });
    }

    fn onSignInClicked(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        if (self.currentTailscale()) |st| if (st.auth_url) |url| return win.openUri(self.prefs, url);
        self.outstanding += 1;
        self.local().call("server.tailscale.login", .{}, self, &onLogin);
    }

    fn onLogin(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (maybe_msg) |m| m.deinit();
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err) |e| return self.prefs.toast("Tailscale: {s}", .{e.message});
        const res = api.parse(struct { tailscale: api.Tailscale }, msg) orelse return;
        if (res.tailscale.auth_url) |url| win.openUri(self.prefs, url) else self.prefs.toast("Tailscale didn't give a sign-in link", .{});
    }

    fn onSignOutClicked(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        win.confirm(self.prefs, "Sign Out of Tailscale?", "This server leaves your tailnet, and your other devices can't reach it until you sign in again.", "Sign Out", self, &struct {
            fn go(ctx: *anyopaque) void {
                const s: *ServerPage = @ptrCast(@alignCast(ctx));
                s.tailscaleCall("server.tailscale.logout", .{});
            }
        }.go);
    }

    // ------------------------------------------------------------------
    // Configuration

    fn onOpenConfig(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        const path = self.prefs.app.keys.config_path;
        if (path.len == 0) return;
        const zpath = self.gpa.dupeSentinel(u8, path, 0) catch return;
        defer self.gpa.free(zpath);
        const file = gio.File.newForPath(zpath);
        defer file.as(gobject.Object).unref();
        const launcher = gtk.FileLauncher.new(file);
        defer launcher.as(gobject.Object).unref();
        const window = if (self.prefs.app.window) |w| w.as(gtk.Window) else null;
        launcher.launch(window, null, null, null);
    }

    fn onReload(_: *gtk.Button, self: *ServerPage) callconv(.c) void {
        self.outstanding += 1;
        self.local().call("server.config_reload", .{}, self, &onReloaded);
    }

    fn onReloaded(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *ServerPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (maybe_msg) |m| m.deinit();
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err) |e| return self.prefs.toast("Couldn't reload: {s}", .{e.message});
        const res = api.parse(struct {
            diagnostics: ?[]const struct { severity: []const u8 = "", message: []const u8 = "", source: ?[]const u8 = null } = null,
        }, msg) orelse return;
        const problems = res.diagnostics orelse &.{};
        for (problems) |d| log.warn("configuration {s}: {s} ({s})", .{ d.severity, d.message, d.source orelse "" });
        if (problems.len == 0) {
            self.prefs.toast("Configuration reloaded", .{});
        } else {
            self.prefs.toast("Reloaded with {d} problem{s}: {s}", .{ problems.len, if (problems.len == 1) "" else "s", problems[0].message });
        }
    }
};
