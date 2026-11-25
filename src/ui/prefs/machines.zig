//! Preferences › Machines: the Rex servers this client connects to. This
//! computer, then the user's hosts (`rex hosts`), which are kept by this
//! computer's server; and the ssh agent used for ssh:// addresses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const win = @import("window.zig");
const Prefs = win.Prefs;
const App = @import("../app.zig").App;
const api = @import("../api.zig");
const Incoming = @import("../client.zig").Incoming;
const machine_mod = @import("../machine.zig");
const Machine = machine_mod.Machine;

const log = std.log.scoped(.prefs);

const agent_names = [_][]const u8{ "default", "gnome_keyring", "onepassword", "custom", "none" };

pub const MachinesPage = struct {
    prefs: *Prefs,
    app: *App,
    gpa: Allocator,
    page: *adw.NavigationPage,
    body: *adw.PreferencesPage,
    list_group: ?*adw.PreferencesGroup = null,
    ssh_group: ?*adw.PreferencesGroup = null,
    arena: std.heap.ArenaAllocator,
    deferred: win.Deferred = .{},
    outstanding: u32 = 0,
    dead: bool = false,

    agent_row: *adw.ComboRow,
    path_row: *adw.EntryRow,
    agent_status: *adw.ActionRow,
    check: ?*AgentCheck = null,

    detail: ?*Detail = null,
    popped_handler: c_ulong = 0,

    pub fn create(prefs: *Prefs) !*MachinesPage {
        const gpa = prefs.gpa;
        const self = try gpa.create(MachinesPage);
        const body = adw.PreferencesPage.new();
        self.* = .{
            .prefs = prefs,
            .app = prefs.app,
            .gpa = gpa,
            .page = win.navPage("Machines", body.as(gtk.Widget)),
            .body = body,
            .arena = .init(gpa),
            .agent_row = adw.ComboRow.new(),
            .path_row = adw.EntryRow.new(),
            .agent_status = win.actionRow("Agent", "Checking…"),
        };
        self.rebuildList();
        self.buildSsh();
        self.popped_handler = adw.NavigationView.signals.popped.connect(prefs.nav, *MachinesPage, &onPopped, self, .{});
        return self;
    }

    pub fn destroy(self: *MachinesPage) void {
        self.deferred.cancel();
        if (self.popped_handler != 0) gobject.signalHandlerDisconnect(self.prefs.nav.as(gobject.Object), self.popped_handler);
        self.dropDetail();
        if (self.check) |c| c.page = null;
        if (self.ssh_group) |g| g.as(gobject.Object).unref();
        self.ssh_group = null;
        self.dead = true;
        self.page.as(gobject.Object).unref();
        if (self.outstanding == 0) self.free();
    }

    fn free(self: *MachinesPage) void {
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn finish(self: *MachinesPage) bool {
        self.outstanding -= 1;
        if (!self.dead) return true;
        if (self.outstanding == 0) self.free();
        return false;
    }

    pub fn scheduleRefresh(self: *MachinesPage) void {
        self.deferred.schedule(MachinesPage, self, refresh);
    }

    fn refresh(self: *MachinesPage) void {
        if (self.dead) return;
        self.rebuildList();
        if (self.detail) |d| d.rebuild();
    }

    // ------------------------------------------------------------------
    // The list

    const RowReq = struct { page: *MachinesPage, id: []const u8 };

    fn rebuildList(self: *MachinesPage) void {
        if (self.list_group) |g| self.body.remove(g);
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const g = win.group("Machines", "This computer, and the hosts you connect to. Hosts are kept by this computer's server and shared with the rex command.");
        for (self.app.machines.items) |m| {
            const subtitle: [:0]const u8 = if (m.is_local)
                "This computer"
            else
                std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ kindName(m.kind()), if (m.addresses.len > 0) m.addresses[0] else "no address" }, 0) catch "";
            const row = win.actionRow(a.dupeSentinel(u8, m.title(), 0) catch "", subtitle);
            row.addSuffix(stateBadge(m));
            if (!m.is_local) {
                row.as(gtk.ListBoxRow).setActivatable(1);
                row.addSuffix(gtk.Image.newFromIconName("go-next-symbolic").as(gtk.Widget));
                const req = a.create(RowReq) catch continue;
                req.* = .{ .page = self, .id = a.dupe(u8, m.id) catch continue };
                _ = adw.ActionRow.signals.activated.connect(row, *RowReq, &onRowActivated, req, .{});
            }
            g.add(row.as(gtk.Widget));
        }
        const add = adw.ButtonRow.new();
        add.as(adw.PreferencesRow).setTitle("Add Machine…");
        add.setStartIconName("add-machine-symbolic");
        _ = adw.ButtonRow.signals.activated.connect(add, *MachinesPage, &onAddClicked, self, .{});
        g.add(add.as(gtk.Widget));

        // Above the ssh group, which is built once.
        if (self.ssh_group) |ssh| self.body.remove(ssh);
        self.body.add(g);
        if (self.ssh_group) |ssh| self.body.add(ssh);
        self.list_group = g;
    }

    fn onRowActivated(_: *adw.ActionRow, req: *RowReq) callconv(.c) void {
        req.page.openDetail(req.id);
    }

    fn onAddClicked(_: *adw.ButtonRow, self: *MachinesPage) callconv(.c) void {
        AddDialog.show(self.app, self.prefs.parentWidget());
    }

    fn machineById(self: *MachinesPage, id: []const u8) ?*Machine {
        for (self.app.machines.items) |m| if (std.mem.eql(u8, m.id, id)) return m;
        return null;
    }

    // ------------------------------------------------------------------
    // ssh

    fn buildSsh(self: *MachinesPage) void {
        const settings = &self.app.settings;
        const g = win.group("SSH", "For ssh:// addresses, Rex runs your system's ssh, so ~/.ssh/config, your keys and jump hosts apply.");

        const row = self.agent_row;
        row.as(adw.PreferencesRow).setTitle("SSH agent");
        const labels = [_:null]?[*:0]const u8{ "System default", "GNOME Keyring", "1Password", "Custom", "None", null };
        const model = gtk.StringList.new(@ptrCast(&labels));
        row.setModel(model.as(gio.ListModel));
        model.as(gobject.Object).unref();
        const current = settings.getString("ssh.agent", "default");
        for (agent_names, 0..) |n, i| if (std.mem.eql(u8, n, current)) row.setSelected(@intCast(i));
        _ = gobject.Object.signals.notify.connect(row, *MachinesPage, &onAgentChanged, self, .{ .detail = "selected" });
        g.add(row.as(gtk.Widget));

        const path = self.path_row;
        path.as(adw.PreferencesRow).setTitle("Agent socket");
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        path.as(gtk.Editable).setText(win.z(&buf, "{s}", .{settings.getString("ssh.agent_path", "")}));
        path.setShowApplyButton(1);
        path.as(gtk.Widget).setVisible(@intFromBool(std.mem.eql(u8, current, "custom")));
        _ = adw.EntryRow.signals.apply.connect(path, *MachinesPage, &onPathApply, self, .{});
        g.add(path.as(gtk.Widget));

        const check = win.button("Check Again", "suggested-action");
        _ = gtk.Button.signals.clicked.connect(check, *MachinesPage, &onCheckAgain, self, .{});
        self.agent_status.addSuffix(check.as(gtk.Widget));
        g.add(self.agent_status.as(gtk.Widget));

        self.body.add(g);
        // Ours too: rebuilding the list takes it off the page for a moment.
        _ = g.as(gobject.Object).ref();
        self.ssh_group = g;
        self.runCheck();
    }

    fn onAgentChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *MachinesPage) callconv(.c) void {
        const i = row.getSelected();
        if (i >= agent_names.len) return;
        const name = agent_names[i];
        self.path_row.as(gtk.Widget).setVisible(@intFromBool(std.mem.eql(u8, name, "custom")));
        self.app.settings.setString("ssh.agent", name);
        self.runCheck();
    }

    fn onPathApply(row: *adw.EntryRow, self: *MachinesPage) callconv(.c) void {
        const text = std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " ");
        self.app.settings.setString("ssh.agent_path", text);
        self.runCheck();
    }

    fn onCheckAgain(_: *gtk.Button, self: *MachinesPage) callconv(.c) void {
        self.runCheck();
        self.app.retryOffline();
    }

    fn setAgentStatus(self: *MachinesPage, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        self.agent_status.setSubtitle(win.z(&buf, fmt, args));
    }

    /// Ask the agent which keys it has, the way ssh will.
    fn runCheck(self: *MachinesPage) void {
        if (self.check) |c| c.page = null;
        self.check = null;
        const socket = self.app.sshAgentSocket(self.gpa) orelse {
            return self.setAgentStatus("No agent. ssh asks for each key's passphrase when you connect.", .{});
        };
        defer self.gpa.free(socket);
        std.Io.Dir.cwd().access(self.app.io, socket, .{}) catch {
            return self.setAgentStatus("No agent is running at {s}.", .{socket});
        };
        self.setAgentStatus("Checking…", .{});
        self.check = AgentCheck.start(self, socket) catch {
            return self.setAgentStatus("Couldn't run ssh-add to check the agent.", .{});
        };
    }

    // ------------------------------------------------------------------
    // Details

    pub fn openDetail(self: *MachinesPage, id: []const u8) void {
        self.dropDetail();
        const d = Detail.create(self, id) catch return;
        self.detail = d;
        self.prefs.push(d.page);
    }

    /// Forget the detail page, as when another page replaces it.
    pub fn dropDetail(self: *MachinesPage) void {
        const d = self.detail orelse return;
        self.detail = null;
        d.destroy();
    }

    fn onPopped(_: *adw.NavigationView, page: *adw.NavigationPage, self: *MachinesPage) callconv(.c) void {
        const d = self.detail orelse return;
        if (d.page == page) self.dropDetail();
    }

    // ------------------------------------------------------------------
    // Saving hosts

    /// Send a host back with a new label and addresses, keeping every
    /// other field as the server gave it.
    fn putHost(self: *MachinesPage, m: *Machine, label: []const u8, endpoints: []const []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var host: std.json.ObjectMap = .empty;
        if (m.host_json) |text| if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})) |v| {
            if (v == .object) host = v.object;
        } else |_| {};
        var list: std.json.Array = .init(a);
        for (endpoints) |e| list.append(.{ .string = e }) catch return;
        host.put(a, "id", .{ .string = m.id }) catch return;
        host.put(a, "label", .{ .string = label }) catch return;
        host.put(a, "endpoints", .{ .array = list }) catch return;
        self.outstanding += 1;
        self.app.localMachine().call("hosts.put", .{ .host = std.json.Value{ .object = host } }, self, &onSaved);
    }

    fn onSaved(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *MachinesPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (maybe_msg) |m| m.deinit();
        const msg = maybe_msg orelse return self.prefs.toast("This computer's server isn't connected", .{});
        defer msg.deinit();
        if (msg.kind.response.err) |e| return self.prefs.toast("Couldn't save: {s}", .{e.message});
        // hosts_changed updates the machines and this page.
    }

    fn removeHost(self: *MachinesPage, id: []const u8) void {
        self.outstanding += 1;
        self.app.localMachine().call("hosts.remove", .{ .id = id }, self, &onRemoved);
    }

    fn onRemoved(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *MachinesPage = @ptrCast(@alignCast(ctx.?));
        if (!self.finish()) return if (maybe_msg) |m| m.deinit();
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err) |e| return self.prefs.toast("Couldn't remove: {s}", .{e.message});
        if (self.detail != null) self.prefs.pop();
    }
};

fn kindName(kind: core.endpoint.Kind) []const u8 {
    return switch (kind) {
        .local => "Local socket",
        .ssh => "SSH",
        .tailscale => "Tailscale",
        .direct => "Address",
    };
}

fn stateBadge(m: *Machine) *gtk.Widget {
    return switch (m.state) {
        .connected => win.badge("Connected", "success"),
        .connecting => win.badge("Connecting…", "dim-label"),
        .offline => win.badge("Can't reach", "warning"),
        .idle => win.badge("Disconnected", "dim-label"),
    };
}

fn entryText(row: *adw.EntryRow) []const u8 {
    return std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " \t");
}

// ----------------------------------------------------------------------
// One host's details

const Detail = struct {
    owner: *MachinesPage,
    gpa: Allocator,
    id: []u8,
    page: *adw.NavigationPage,
    body: *adw.PreferencesPage,
    groups: std.ArrayList(*adw.PreferencesGroup) = .empty,
    arena: std.heap.ArenaAllocator,

    fn create(owner: *MachinesPage, id: []const u8) !*Detail {
        const gpa = owner.gpa;
        const m = owner.machineById(id) orelse return error.NoMachine;
        const d = try gpa.create(Detail);
        const body = adw.PreferencesPage.new();
        var buf: [128]u8 = undefined;
        d.* = .{
            .owner = owner,
            .gpa = gpa,
            .id = try gpa.dupe(u8, id),
            .page = win.navPage(win.z(&buf, "{s}", .{m.title()}), body.as(gtk.Widget)),
            .body = body,
            .arena = .init(gpa),
        };
        d.rebuild();
        return d;
    }

    fn destroy(d: *Detail) void {
        d.groups.deinit(d.gpa);
        d.arena.deinit();
        d.page.as(gobject.Object).unref();
        d.gpa.free(d.id);
        d.gpa.destroy(d);
    }

    fn machine(d: *Detail) ?*Machine {
        return d.owner.machineById(d.id);
    }

    const AddrReq = struct { d: *Detail, index: usize };

    fn rebuild(d: *Detail) void {
        for (d.groups.items) |g| d.body.remove(g);
        d.groups.clearRetainingCapacity();
        _ = d.arena.reset(.retain_capacity);
        const a = d.arena.allocator();
        const m = d.machine() orelse {
            // Removed elsewhere.
            d.owner.prefs.pop();
            return;
        };
        d.page.setTitle(a.dupeSentinel(u8, m.title(), 0) catch "");
        const editable = !m.from_config;

        // Status.
        const status = win.group(null, if (m.from_config) "Declared in your configuration file. Change it there." else null);
        const state_text: [:0]const u8 = switch (m.state) {
            .connected => std.fmt.allocPrintSentinel(a, "Connected at {s}", .{m.endpoint_text orelse "?"}, 0) catch "Connected",
            .connecting => "Connecting…",
            .offline => a.dupeSentinel(u8, m.detail orelse "Can't reach it", 0) catch "",
            .idle => "Disconnected",
        };
        const st = win.actionRow("Status", state_text);
        st.setSubtitleSelectable(1);
        if (m.state == .offline or m.state == .idle) {
            const b = win.button("Connect", "suggested-action");
            _ = gtk.Button.signals.clicked.connect(b, *Detail, &onConnect, d, .{});
            st.addSuffix(b.as(gtk.Widget));
        }
        status.add(st.as(gtk.Widget));
        d.add(status);

        // Name.
        const name_group = win.group(null, null);
        const name = adw.EntryRow.new();
        name.as(adw.PreferencesRow).setTitle("Name");
        name.as(gtk.Editable).setText(a.dupeSentinel(u8, m.label, 0) catch "");
        name.setShowApplyButton(1);
        name.as(gtk.Widget).setSensitive(@intFromBool(editable));
        _ = adw.EntryRow.signals.apply.connect(name, *Detail, &onNameApply, d, .{});
        name_group.add(name.as(gtk.Widget));
        d.add(name_group);

        // Addresses, in the order they're tried.
        const addrs = win.group("Addresses", "Tried in this order. For example ssh://me@studio, studio.tail1234.ts.net, or 192.168.1.20:7297.");
        for (m.addresses, 0..) |addr, i| {
            const row = adw.EntryRow.new();
            row.as(adw.PreferencesRow).setTitle(std.fmt.allocPrintSentinel(a, "{s}", .{kindName(kindOf(addr))}, 0) catch "");
            row.as(gtk.Editable).setText(a.dupeSentinel(u8, addr, 0) catch "");
            row.setShowApplyButton(1);
            row.as(gtk.Widget).setSensitive(@intFromBool(editable));
            const req = a.create(AddrReq) catch continue;
            req.* = .{ .d = d, .index = i };
            _ = adw.EntryRow.signals.apply.connect(row, *AddrReq, &onAddressApply, req, .{});
            if (m.addresses.len > 1) {
                const remove = win.iconButton("user-trash-symbolic", "Remove This Address");
                _ = gtk.Button.signals.clicked.connect(remove, *AddrReq, &onAddressRemove, req, .{});
                row.addSuffix(remove.as(gtk.Widget));
            }
            addrs.add(row.as(gtk.Widget));
        }
        const new = adw.EntryRow.new();
        new.as(adw.PreferencesRow).setTitle("Add an address");
        new.setShowApplyButton(1);
        new.as(gtk.Widget).setSensitive(@intFromBool(editable));
        const req = a.create(AddrReq) catch return;
        req.* = .{ .d = d, .index = m.addresses.len };
        _ = adw.EntryRow.signals.apply.connect(new, *AddrReq, &onAddressApply, req, .{});
        addrs.add(new.as(gtk.Widget));
        d.add(addrs);

        if (editable) {
            const danger = win.group(null, null);
            const remove = adw.ButtonRow.new();
            remove.as(adw.PreferencesRow).setTitle("Remove Machine…");
            remove.as(gtk.Widget).addCssClass("destructive-action");
            _ = adw.ButtonRow.signals.activated.connect(remove, *Detail, &onRemove, d, .{});
            danger.add(remove.as(gtk.Widget));
            d.add(danger);
        }
    }

    fn add(d: *Detail, g: *adw.PreferencesGroup) void {
        d.body.add(g);
        d.groups.append(d.gpa, g) catch {};
    }

    fn onConnect(_: *gtk.Button, d: *Detail) callconv(.c) void {
        if (d.machine()) |m| m.connect(true);
    }

    fn onNameApply(row: *adw.EntryRow, d: *Detail) callconv(.c) void {
        const m = d.machine() orelse return;
        const label = entryText(row);
        if (label.len == 0) return d.owner.prefs.toast("A machine needs a name", .{});
        d.owner.putHost(m, label, m.addresses);
    }

    fn onAddressApply(row: *adw.EntryRow, req: *AddrReq) callconv(.c) void {
        const d = req.d;
        const m = d.machine() orelse return;
        const text = entryText(row);
        if (text.len == 0) return;
        _ = core.endpoint.parse(text) catch return d.owner.prefs.toast("Rex doesn't understand that address", .{});
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(d.gpa);
        for (m.addresses) |x| list.append(d.gpa, x) catch return;
        if (req.index < list.items.len) list.items[req.index] = text else list.append(d.gpa, text) catch return;
        d.owner.putHost(m, m.label, list.items);
    }

    fn onAddressRemove(_: *gtk.Button, req: *AddrReq) callconv(.c) void {
        const d = req.d;
        const m = d.machine() orelse return;
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(d.gpa);
        for (m.addresses, 0..) |x, i| if (i != req.index) list.append(d.gpa, x) catch return;
        d.owner.putHost(m, m.label, list.items);
    }

    fn onRemove(_: *adw.ButtonRow, d: *Detail) callconv(.c) void {
        const m = d.machine() orelse return;
        var buf: [256]u8 = undefined;
        win.confirm(d.owner.prefs, win.z(&buf, "Remove {s}?", .{m.title()}), "Its sessions keep running there, but this client and the rex command stop listing it.", "Remove", d, &struct {
            fn go(ctx: *anyopaque) void {
                const dd: *Detail = @ptrCast(@alignCast(ctx));
                dd.owner.removeHost(dd.id);
            }
        }.go);
    }
};

fn kindOf(address: []const u8) core.endpoint.Kind {
    const c = core.endpoint.parse(address) catch return .direct;
    return c.kind();
}

// ----------------------------------------------------------------------
// Checking the ssh agent

const AgentCheck = struct {
    /// Null once nobody waits for the answer.
    page: ?*MachinesPage,
    gpa: Allocator,
    proc: *gio.Subprocess,
    socket: []u8,
    timeout_id: c_uint = 0,
    timed_out: bool = false,

    fn start(page: *MachinesPage, socket: []const u8) !*AgentCheck {
        const gpa = page.gpa;
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_silence = true });
        defer launcher.as(gobject.Object).unref();
        const zsock = try gpa.dupeSentinel(u8, socket, 0);
        defer gpa.free(zsock);
        launcher.setenv("SSH_AUTH_SOCK", zsock, 1);
        const argv = [_:null]?[*:0]const u8{ "ssh-add", "-l", null };
        var err: ?*glib.Error = null;
        const proc = launcher.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            return error.SpawnFailed;
        };
        const c = try gpa.create(AgentCheck);
        c.* = .{ .page = page, .gpa = gpa, .proc = proc, .socket = try gpa.dupe(u8, socket) };
        // An agent that asks before it signs, or is locked, may not answer.
        c.timeout_id = glib.timeoutAdd(5000, &onTimeout, c);
        proc.communicateUtf8Async(null, null, &onDone, c);
        return c;
    }

    fn onTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const c: *AgentCheck = @ptrCast(@alignCast(data.?));
        c.timeout_id = 0;
        c.timed_out = true;
        c.proc.forceExit();
        return 0;
    }

    fn onDone(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const c: *AgentCheck = @ptrCast(@alignCast(data.?));
        defer c.free();
        var out: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        const ok = c.proc.communicateUtf8Finish(res, &out, null, &err) != 0;
        if (err) |e| e.free();
        defer if (ok) glib.free(out);
        const page = c.page orelse return;
        if (page.check == c) page.check = null;
        if (c.timed_out) return page.setAgentStatus("The agent at {s} didn't answer. It may be locked, or waiting for you to approve.", .{c.socket});
        if (!ok or c.proc.getIfExited() == 0) return page.setAgentStatus("Couldn't check the agent.", .{});
        switch (c.proc.getExitStatus()) {
            0 => {
                var keys: usize = 0;
                var it = std.mem.splitScalar(u8, std.mem.span(out), '\n');
                while (it.next()) |line| keys += @intFromBool(std.mem.trim(u8, line, " ").len > 0);
                page.setAgentStatus("{d} key{s} ready, from {s}", .{ keys, if (keys == 1) "" else "s", c.socket });
            },
            1 => page.setAgentStatus("The agent has no keys. Add one with ssh-add.", .{}),
            else => page.setAgentStatus("Can't talk to the agent at {s}.", .{c.socket}),
        }
    }

    fn free(c: *AgentCheck) void {
        if (c.timeout_id != 0) _ = glib.Source.remove(c.timeout_id);
        c.proc.as(gobject.Object).unref();
        c.gpa.free(c.socket);
        c.gpa.destroy(c);
    }
};

// ----------------------------------------------------------------------
// Adding a machine

/// Add Machine, from the sidebar or the Machines page.
pub fn showAddMachine(app: *App, parent: *gtk.Widget) void {
    AddDialog.show(app, parent);
}

const AddDialog = struct {
    app: *App,
    gpa: Allocator,
    dialog: *adw.Dialog,
    name: *adw.EntryRow,
    kind: *adw.ToggleGroup,
    address: *adw.EntryRow,
    test_row: *adw.ActionRow,
    spinner: *adw.Spinner,
    add_button: *gtk.Button,
    /// A throwaway connection to try the address.
    probe: ?*Machine = null,
    drop_id: c_uint = 0,
    adding: bool = false,
    closed: bool = false,

    fn show(app: *App, parent: *gtk.Widget) void {
        const gpa = app.gpa;
        const self = gpa.create(AddDialog) catch return;
        const dialog = adw.Dialog.new();
        dialog.setTitle("Add Machine");
        dialog.setContentWidth(480);

        const cancel = gtk.Button.newWithLabel("Cancel");
        const add = gtk.Button.newWithLabel("Add");
        add.as(gtk.Widget).addCssClass("suggested-action");
        const header = adw.HeaderBar.new();
        header.setShowStartTitleButtons(0);
        header.setShowEndTitleButtons(0);
        header.packStart(cancel.as(gtk.Widget));
        header.packEnd(add.as(gtk.Widget));

        const body = adw.PreferencesPage.new();
        const g1 = win.group(null, null);
        const name = adw.EntryRow.new();
        name.as(adw.PreferencesRow).setTitle("Name, such as studio");
        g1.add(name.as(gtk.Widget));
        body.add(g1);

        const kind = adw.ToggleGroup.new();
        kind.as(gtk.Widget).setValign(.center);
        for ([_][2][:0]const u8{ .{ "ssh", "SSH" }, .{ "address", "Address" } }) |t| {
            const toggle = adw.Toggle.new();
            toggle.setName(t[0]);
            toggle.setLabel(t[1]);
            kind.add(toggle);
        }
        kind.setActiveName("ssh");
        const g2 = win.group("Connection", "SSH runs your system's ssh and needs Rex installed on the machine. An address reaches a Rex server that listens on the network, such as one on your tailnet.");
        g2.setHeaderSuffix(kind.as(gtk.Widget));
        const address = adw.EntryRow.new();
        g2.add(address.as(gtk.Widget));
        const test_row = win.actionRow("Test the connection", "Connect once to check the address. ssh may ask you to trust the machine's key.");
        const spinner = adw.Spinner.new();
        spinner.as(gtk.Widget).setVisible(0);
        test_row.addSuffix(spinner.as(gtk.Widget));
        const test_button = win.button("Test", null);
        test_row.addSuffix(test_button.as(gtk.Widget));
        g2.add(test_row.as(gtk.Widget));
        body.add(g2);

        const toolbar = adw.ToolbarView.new();
        toolbar.addTopBar(header.as(gtk.Widget));
        toolbar.setContent(body.as(gtk.Widget));
        dialog.setChild(toolbar.as(gtk.Widget));

        self.* = .{
            .app = app,
            .gpa = gpa,
            .dialog = dialog,
            .name = name,
            .kind = kind,
            .address = address,
            .test_row = test_row,
            .spinner = spinner,
            .add_button = add,
        };
        self.updateAddressTitle();
        _ = gobject.Object.signals.notify.connect(kind, *AddDialog, &onKindChanged, self, .{ .detail = "active-name" });
        _ = gtk.Button.signals.clicked.connect(cancel, *AddDialog, &onCancel, self, .{});
        _ = gtk.Button.signals.clicked.connect(add, *AddDialog, &onAdd, self, .{});
        _ = gtk.Button.signals.clicked.connect(test_button, *AddDialog, &onTest, self, .{});
        _ = adw.Dialog.signals.closed.connect(dialog, *AddDialog, &onClosed, self, .{});
        dialog.present(parent);
        _ = name.as(gtk.Widget).grabFocus();
    }

    fn isSsh(self: *AddDialog) bool {
        const n = self.kind.getActiveName() orelse return true;
        return std.mem.eql(u8, std.mem.span(n), "ssh");
    }

    fn updateAddressTitle(self: *AddDialog) void {
        self.address.as(adw.PreferencesRow).setTitle(if (self.isSsh())
            "Host, such as me@studio or a name from ~/.ssh/config"
        else
            "Address, such as studio.tail1234.ts.net or 192.168.1.20:7297");
    }

    fn onKindChanged(_: *adw.ToggleGroup, _: *gobject.ParamSpec, self: *AddDialog) callconv(.c) void {
        self.updateAddressTitle();
    }

    /// The address as Rex spells it, in `buf`.
    fn endpointText(self: *AddDialog, buf: []u8) ?[]const u8 {
        const text = entryText(self.address);
        if (text.len == 0) return null;
        const full = if (self.isSsh() and !std.mem.startsWith(u8, text, "ssh://"))
            std.fmt.bufPrint(buf, "ssh://{s}", .{text}) catch return null
        else
            std.fmt.bufPrint(buf, "{s}", .{text}) catch return null;
        _ = core.endpoint.parse(full) catch return null;
        return full;
    }

    /// The name to use: the one typed, or the address's host.
    fn label(self: *AddDialog, endpoint: []const u8) []const u8 {
        const typed = entryText(self.name);
        if (typed.len > 0) return typed;
        var host = endpoint;
        if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
        if (std.mem.lastIndexOfScalar(u8, host, '@')) |i| host = host[i + 1 ..];
        if (std.mem.indexOfAny(u8, host, ".:/")) |i| host = host[0..i];
        return host;
    }

    fn setTest(self: *AddDialog, busy: bool, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        self.test_row.setSubtitle(win.z(&buf, fmt, args));
        self.spinner.as(gtk.Widget).setVisible(@intFromBool(busy));
    }

    fn onTest(_: *gtk.Button, self: *AddDialog) callconv(.c) void {
        var buf: [512]u8 = undefined;
        const ep = self.endpointText(&buf) orelse return self.setTest(false, "Type an address Rex understands first.", .{});
        self.dropProbe();
        const m = Machine.create(self.gpa, self.app.io, .{
            .ctx = self,
            .connected = probeConnected,
            .event = probeEvent,
            .disconnected = probeNothing,
            .changed = probeChanged,
            .ssh_agent = probeAgent,
            .window = probeWindow,
        }, .{
            .id = "probe",
            .label = self.label(ep),
            .addresses = &.{ep},
            .client_label = self.app.clientLabel(),
        }) catch return;
        self.probe = m;
        m.connect(true);
    }

    fn dropProbe(self: *AddDialog) void {
        const m = self.probe orelse return;
        self.probe = null;
        m.destroy();
    }

    fn probeConnected(ctx: *anyopaque, m: *Machine) void {
        const self: *AddDialog = @ptrCast(@alignCast(ctx));
        self.setTest(false, "Connected to a Rex server at {s}.", .{m.endpoint_text orelse "?"});
        self.dropProbeLater();
    }

    /// Done with the probe, but not from inside its own callback.
    fn dropProbeLater(self: *AddDialog) void {
        if (self.drop_id != 0) return;
        self.drop_id = glib.idleAdd(&struct {
            fn f(data: ?*anyopaque) callconv(.c) c_int {
                const s: *AddDialog = @ptrCast(@alignCast(data.?));
                s.drop_id = 0;
                s.dropProbe();
                return 0;
            }
        }.f, self);
    }

    fn probeChanged(ctx: *anyopaque, m: *Machine) void {
        const self: *AddDialog = @ptrCast(@alignCast(ctx));
        switch (m.state) {
            .connecting => self.setTest(true, "Connecting…", .{}),
            .offline => {
                self.setTest(false, "{s}", .{m.detail orelse "Can't connect."});
                // Don't keep retrying in the background.
                self.dropProbeLater();
            },
            .connected, .idle => {},
        }
    }

    fn probeEvent(_: *anyopaque, _: *Machine, msg: Incoming) void {
        msg.deinit();
    }

    fn probeNothing(_: *anyopaque, _: *Machine) void {}

    fn probeAgent(ctx: *anyopaque, gpa: Allocator) ?[]u8 {
        const self: *AddDialog = @ptrCast(@alignCast(ctx));
        return self.app.sshAgentSocket(gpa);
    }

    fn probeWindow(ctx: *anyopaque) ?*gtk.Widget {
        const self: *AddDialog = @ptrCast(@alignCast(ctx));
        return self.dialog.as(gtk.Widget);
    }

    fn onAdd(_: *gtk.Button, self: *AddDialog) callconv(.c) void {
        if (self.adding) return;
        var buf: [512]u8 = undefined;
        const ep = self.endpointText(&buf) orelse return self.setTest(false, "Type an address Rex understands first.", .{});
        const name = self.label(ep);
        if (name.len == 0) return self.setTest(false, "Give the machine a name.", .{});
        self.adding = true;
        self.add_button.as(gtk.Widget).setSensitive(0);
        self.app.localMachine().call("hosts.put", .{ .host = .{ .label = name, .endpoints = &[_][]const u8{ep} } }, self, &onAdded);
    }

    fn onAdded(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *AddDialog = @ptrCast(@alignCast(ctx.?));
        self.adding = false;
        if (self.closed) {
            if (maybe_msg) |m| m.deinit();
            return self.gpa.destroy(self);
        }
        self.add_button.as(gtk.Widget).setSensitive(1);
        const msg = maybe_msg orelse return self.setTest(false, "This computer's server isn't connected.", .{});
        defer msg.deinit();
        if (msg.kind.response.err) |e| return self.setTest(false, "Couldn't add it: {s}", .{e.message});
        _ = self.dialog.close();
    }

    fn onCancel(_: *gtk.Button, self: *AddDialog) callconv(.c) void {
        _ = self.dialog.close();
    }

    fn onClosed(_: *adw.Dialog, self: *AddDialog) callconv(.c) void {
        self.closed = true;
        if (self.drop_id != 0) _ = glib.Source.remove(self.drop_id);
        self.drop_id = 0;
        self.dropProbe();
        // A hosts.put may still be answered: keep the struct until then.
        if (self.adding) return;
        self.gpa.destroy(self);
    }
};
