//! One Rex server the app talks to: this computer's own, or one of the
//! user's hosts (`rex hosts`).
//!
//! A machine owns its control connection and keeps it up. It tries each of
//! the host's addresses in turn: a Unix socket or a TCP address is dialled
//! on a worker thread, so a slow network never blocks the window; an ssh
//! address first starts `rex __internal ssh-tunnel` (see net/ssh.zig) and
//! dials the local socket it forwards. A machine that can't be reached is
//! tried again later, and when the connection drops it reconnects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const endpoint = core.endpoint;
const ssh = core.ssh;
const control = core.control;
const Client = @import("client.zig").Client;
const Incoming = @import("client.zig").Incoming;
const ResponseFn = @import("client.zig").ResponseFn;
const mainloop = @import("mainloop.zig");

const log = std.log.scoped(.machine);

pub const State = enum { idle, connecting, connected, offline };

pub const SessionItem = struct {
    session_id: []u8,
    label: []u8,
};

/// What the app hears from a machine. Every call is on the main thread.
pub const Listener = struct {
    ctx: *anyopaque,
    /// The connection is up; send the first request.
    connected: *const fn (ctx: *anyopaque, m: *Machine) void,
    /// An event arrived. The callee owns `msg`.
    event: *const fn (ctx: *anyopaque, m: *Machine, msg: Incoming) void,
    /// The connection dropped. The machine reconnects on its own.
    disconnected: *const fn (ctx: *anyopaque, m: *Machine) void,
    /// The state, the detail or the sessions changed.
    changed: *const fn (ctx: *anyopaque, m: *Machine) void,
    /// The ssh agent socket to give ssh, or null for none. Caller frees.
    ssh_agent: *const fn (ctx: *anyopaque, gpa: Allocator) ?[]u8,
    /// Where to show ssh's questions.
    window: *const fn (ctx: *anyopaque) ?*gtk.Widget,
};

pub const Options = struct {
    /// "local" for this computer's server, else the host's ID.
    id: []const u8,
    label: []const u8,
    icon: ?[]const u8 = null,
    /// Addresses in the forms `rex -S` takes, in the order to try them.
    addresses: []const []const u8,
    is_local: bool = false,
    /// How this client names itself to the server.
    client_label: ?[]const u8 = null,
};

pub const Machine = struct {
    gpa: Allocator,
    io: std.Io,
    listener: Listener,

    id: []u8,
    label: []u8,
    icon: ?[]u8,
    addresses: [][]u8,
    is_local: bool,
    client_label: ?[]u8,

    state: State = .idle,
    /// Why the machine can't be reached, for its warning's tooltip.
    detail: ?[]u8 = null,
    client: ?*Client = null,
    /// The client whose connection dropped; freed once we reconnect.
    dead_client: ?*Client = null,
    /// Continues our client on the server after a reconnect.
    reconnect_token: ?[]u8 = null,
    /// Where `client` connected, for data connections.
    endpoint_text: ?[]u8 = null,
    /// The server's own ID for its machine and account.
    host_id: ?[]u8 = null,

    /// The sessions on the server, in its order.
    sessions: std.ArrayList(SessionItem) = .empty,
    list_pending: bool = false,

    /// Counts connection attempts, so a late result of an abandoned one is
    /// dropped.
    generation: u32 = 0,
    /// The address being tried, and the last thing that went wrong.
    step: usize = 0,
    last_error: ?[]u8 = null,
    /// May ssh ask the user questions on this attempt?
    interactive: bool = false,
    job: ?*Job = null,
    tunnel: ?*Tunnel = null,
    timeout_id: c_uint = 0,
    retry_id: c_uint = 0,
    /// Failed attempts in a row, for backing off.
    failures: u32 = 0,

    pub fn create(gpa: Allocator, io: std.Io, listener: Listener, options: Options) !*Machine {
        const self = try gpa.create(Machine);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .id = try gpa.dupe(u8, options.id),
            .label = try gpa.dupe(u8, options.label),
            .icon = if (options.icon) |i| try gpa.dupe(u8, i) else null,
            .addresses = try dupeList(gpa, options.addresses),
            .is_local = options.is_local,
            .client_label = if (options.client_label) |l| try gpa.dupe(u8, l) else null,
        };
        return self;
    }

    pub fn destroy(self: *Machine) void {
        self.stop();
        if (self.client) |c| c.destroy();
        if (self.dead_client) |c| c.destroy();
        const gpa = self.gpa;
        gpa.free(self.id);
        gpa.free(self.label);
        if (self.icon) |i| gpa.free(i);
        freeList(gpa, self.addresses);
        if (self.client_label) |l| gpa.free(l);
        freeOpt(gpa, &self.detail);
        freeOpt(gpa, &self.reconnect_token);
        freeOpt(gpa, &self.endpoint_text);
        freeOpt(gpa, &self.host_id);
        freeOpt(gpa, &self.last_error);
        self.clearSessions();
        self.sessions.deinit(gpa);
        gpa.destroy(self);
    }

    /// Change the label, icon or addresses, as `hosts_changed` may. New
    /// addresses take effect at once.
    pub fn update(self: *Machine, label: []const u8, icon: ?[]const u8, addresses: []const []const u8) void {
        const gpa = self.gpa;
        if (!std.mem.eql(u8, self.label, label)) {
            const l = gpa.dupe(u8, label) catch return;
            gpa.free(self.label);
            self.label = l;
        }
        const new_icon: ?[]u8 = if (icon) |i| gpa.dupe(u8, i) catch null else null;
        if (self.icon) |i| gpa.free(i);
        self.icon = new_icon;

        const same = self.addresses.len == addresses.len and for (self.addresses, addresses) |a, b| {
            if (!std.mem.eql(u8, a, b)) break false;
        } else true;
        if (!same) {
            const list = dupeList(gpa, addresses) catch return;
            freeList(gpa, self.addresses);
            self.addresses = list;
            self.disconnect();
            self.connect(false);
        }
        self.listener.changed(self.listener.ctx, self);
    }

    // ------------------------------------------------------------------
    // Requests

    pub fn send(self: *Machine, method: []const u8, payload: anytype) void {
        if (self.client) |c| c.send(method, payload);
    }

    pub fn call(self: *Machine, method: []const u8, payload: anytype, ctx: ?*anyopaque, callback: ResponseFn) void {
        if (self.client) |c| return c.call(method, payload, ctx, callback);
        callback(ctx, null);
    }

    pub fn clientId(self: *const Machine) []const u8 {
        return if (self.client) |c| c.clientId() else "";
    }

    /// Where to open data connections, or null while disconnected.
    pub fn dataEndpoint(self: *const Machine) ?[]const u8 {
        return self.endpoint_text;
    }

    /// The name to show for the machine.
    pub fn title(self: *const Machine) []const u8 {
        return self.label;
    }

    // ------------------------------------------------------------------
    // Sessions

    pub fn clearSessions(self: *Machine) void {
        for (self.sessions.items) |s| {
            self.gpa.free(s.session_id);
            self.gpa.free(s.label);
        }
        self.sessions.clearRetainingCapacity();
    }

    /// `list` is a slice of anything with `session_id` and `label`.
    pub fn setSessions(self: *Machine, list: anytype) void {
        self.clearSessions();
        for (list) |s| {
            const id = self.gpa.dupe(u8, s.session_id) catch continue;
            const label = self.gpa.dupe(u8, s.label) catch {
                self.gpa.free(id);
                continue;
            };
            self.sessions.append(self.gpa, .{ .session_id = id, .label = label }) catch {
                self.gpa.free(id);
                self.gpa.free(label);
            };
        }
        self.listener.changed(self.listener.ctx, self);
    }

    pub fn hasSession(self: *const Machine, session_id: []const u8) bool {
        for (self.sessions.items) |s| if (std.mem.eql(u8, s.session_id, session_id)) return true;
        return false;
    }

    /// Fetch the session list again, as after `session_created`.
    pub fn refreshSessions(self: *Machine) void {
        if (self.list_pending or self.client == null) return;
        self.list_pending = true;
        self.call("session.list", null, self, &onSessionList);
    }

    fn onSessionList(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *Machine = @ptrCast(@alignCast(ctx.?));
        self.list_pending = false;
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const api = @import("api.zig");
        const list = api.parse(api.SessionList, msg) orelse return;
        self.setSessions(list.sessions);
    }

    // ------------------------------------------------------------------
    // Connecting

    /// Start connecting, unless connected already. `interactive` lets ssh
    /// ask the user questions, such as whether to trust a host's key; only
    /// pass it when the user asked to connect.
    pub fn connect(self: *Machine, interactive: bool) void {
        if (self.client != null) return;
        self.stop();
        self.interactive = interactive;
        self.step = 0;
        freeOpt(self.gpa, &self.last_error);
        self.setState(.connecting, null);
        self.tryAddress();
    }

    /// Close the connection without reconnecting.
    pub fn disconnect(self: *Machine) void {
        self.stop();
        if (self.client) |c| {
            self.client = null;
            c.destroy();
            self.listener.disconnected(self.listener.ctx, self);
        }
        freeOpt(self.gpa, &self.endpoint_text);
        self.setState(.idle, null);
    }

    /// Abandon whatever attempt is under way.
    fn stop(self: *Machine) void {
        self.generation +%= 1;
        if (self.job) |j| j.machine = null;
        self.job = null;
        if (self.tunnel) |t| t.close();
        self.tunnel = null;
        self.clearTimeout();
        if (self.retry_id != 0) _ = glib.Source.remove(self.retry_id);
        self.retry_id = 0;
    }

    fn setState(self: *Machine, state: State, detail: ?[]const u8) void {
        self.state = state;
        freeOpt(self.gpa, &self.detail);
        if (detail) |d| self.detail = self.gpa.dupe(u8, d) catch null;
        self.listener.changed(self.listener.ctx, self);
    }

    fn tryAddress(self: *Machine) void {
        while (self.step < self.addresses.len) : (self.step += 1) {
            const address = self.addresses[self.step];
            const candidates = endpoint.parse(address) catch {
                self.noteError("{s} isn't an address Rex understands.", .{address});
                continue;
            };
            // A socket path only works where it exists.
            if (candidates.buf[0] == .unix and !self.is_local) {
                std.Io.Dir.cwd().access(self.io, candidates.buf[0].unix, .{}) catch continue;
            }
            if (candidates.buf[0] == .ssh) return self.startTunnel(address);
            return self.startJob(address);
        }
        const why = if (self.last_error) |e| e else "It has no address to connect to.";
        const copy = self.gpa.dupe(u8, why) catch null;
        defer if (copy) |c| self.gpa.free(c);
        self.fail(copy orelse "Can't connect.");
    }

    fn nextAddress(self: *Machine) void {
        self.clearTimeout();
        self.step += 1;
        self.tryAddress();
    }

    fn noteError(self: *Machine, comptime fmt: []const u8, args: anytype) void {
        freeOpt(self.gpa, &self.last_error);
        self.last_error = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    fn fail(self: *Machine, why: []const u8) void {
        log.info("can't reach {s}: {s}", .{ self.label, why });
        self.clearTimeout();
        self.failures += 1;
        self.setState(.offline, why);
        // This computer's server may simply not be running yet.
        if (self.is_local and self.failures <= 2) startLocalServer();
        const delay: c_uint = if (self.is_local)
            @min(5000, @as(c_uint, 250) << @intCast(@min(self.failures, 5)))
        else
            @min(300_000, @as(c_uint, 30_000) << @intCast(@min(self.failures - 1, 4)));
        self.retry_id = glib.timeoutAdd(delay, &onRetry, self);
    }

    fn onRetry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Machine = @ptrCast(@alignCast(data.?));
        self.retry_id = 0;
        self.connect(false);
        return 0;
    }

    fn startTimeout(self: *Machine) void {
        self.clearTimeout();
        self.timeout_id = glib.timeoutAdd(ssh.connect_timeout_ms, &onTimeout, self);
    }

    fn clearTimeout(self: *Machine) void {
        if (self.timeout_id != 0) _ = glib.Source.remove(self.timeout_id);
        self.timeout_id = 0;
    }

    fn onTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Machine = @ptrCast(@alignCast(data.?));
        self.timeout_id = 0;
        const address = self.addresses[self.step];
        if (self.tunnel) |t| {
            t.close();
            self.tunnel = null;
            self.noteError("ssh to {s} is taking too long. If your SSH agent asks before it signs, check that it's unlocked.", .{address});
        } else {
            if (self.job) |j| j.machine = null;
            self.job = null;
            self.noteError("{s} didn't answer.", .{address});
        }
        self.nextAddress();
        return 0;
    }

    fn startJob(self: *Machine, address: []const u8) void {
        const job = Job.create(self, address) catch |err| {
            self.noteError("{s}: {t}", .{ address, err });
            return self.nextAddress();
        };
        self.job = job;
        self.startTimeout();
        const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            self.job = null;
            job.destroy();
            self.noteError("{s}: {t}", .{ address, err });
            return self.nextAddress();
        };
        thread.detach();
    }

    fn jobDone(self: *Machine, job: *Job) void {
        self.job = null;
        self.clearTimeout();
        const address = self.addresses[self.step];
        const ctl = job.ctl orelse {
            const err = job.err orelse error.Unexpected;
            self.noteDialError(err, address);
            if (self.tunnel != null) {
                // The tunnel's socket didn't answer: nothing else to try
                // through it.
                if (self.tunnel) |t| t.close();
                self.tunnel = null;
            }
            return self.nextAddress();
        };
        job.ctl = null;
        const client = Client.start(self.gpa, self.io, ctl, .{
            .ctx = self,
            .event = onClientEvent,
            .disconnected = onClientGone,
        }) catch |err| {
            ctl.destroy();
            self.noteError("{s}: {t}", .{ address, err });
            return self.nextAddress();
        };
        log.info("connected to {s} at {s} (resumed: {})", .{ self.label, job.chosen orelse "?", ctl.resumed });
        if (self.dead_client) |old| old.destroy();
        self.dead_client = null;
        self.client = client;
        freeOpt(self.gpa, &self.endpoint_text);
        self.endpoint_text = job.chosen;
        job.chosen = null;
        freeOpt(self.gpa, &self.reconnect_token);
        self.failures = 0;
        self.setState(.connected, null);
        self.listener.connected(self.listener.ctx, self);
    }

    fn noteDialError(self: *Machine, err: anyerror, address: []const u8) void {
        const name = @errorName(err);
        const eq = std.mem.eql;
        if (eq(u8, name, "ConnectionRefused") or eq(u8, name, "FileNotFound")) {
            if (self.is_local) return self.noteError("The Rex server isn't running.", .{});
            return self.noteError("Nothing is listening at {s}.", .{address});
        }
        if (eq(u8, name, "UnknownHostName") or eq(u8, name, "NameServerFailure") or
            eq(u8, name, "HostLacksNetworkAddresses") or eq(u8, name, "TemporaryNameServerFailure"))
        {
            if (std.mem.indexOf(u8, address, ".ts.net") != null)
                return self.noteError("Can't find {s}. Is Tailscale running on this computer?", .{address});
            return self.noteError("Can't find {s}.", .{address});
        }
        if (eq(u8, name, "Forbidden")) return self.noteError("{s} doesn't let this computer in.", .{address});
        if (eq(u8, name, "HandshakeFailed")) return self.noteError("{s} isn't a Rex server.", .{address});
        if (eq(u8, name, "TlsFailed")) return self.noteError("Couldn't make a secure connection to {s}.", .{address});
        if (eq(u8, name, "NetworkUnreachable") or eq(u8, name, "HostUnreachable"))
            return self.noteError("{s} can't be reached from this network.", .{address});
        self.noteError("{s}: {s}", .{ address, name });
    }

    fn onClientEvent(ctx: ?*anyopaque, msg: Incoming) void {
        const self: *Machine = @ptrCast(@alignCast(ctx.?));
        self.listener.event(self.listener.ctx, self, msg);
    }

    fn onClientGone(ctx: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(ctx.?));
        const client = self.client orelse return;
        log.warn("lost the connection to {s}; reconnecting", .{self.label});
        freeOpt(self.gpa, &self.reconnect_token);
        self.reconnect_token = self.gpa.dupe(u8, client.ctl.reconnectToken()) catch null;
        self.client = null;
        if (self.dead_client) |old| old.destroy();
        self.dead_client = client;
        freeOpt(self.gpa, &self.endpoint_text);
        self.listener.disconnected(self.listener.ctx, self);
        self.stop();
        self.failures = 0;
        self.setState(.connecting, null);
        self.retry_id = glib.timeoutAdd(250, &onRetry, self);
    }

    // ------------------------------------------------------------------
    // ssh

    fn startTunnel(self: *Machine, address: []const u8) void {
        const agent = self.listener.ssh_agent(self.listener.ctx, self.gpa);
        defer if (agent) |a| self.gpa.free(a);
        const tunnel = Tunnel.start(self, address, agent, self.interactive) catch |err| {
            self.noteError("Couldn't start ssh for {s}: {t}. Is rex on your PATH?", .{ address, err });
            return self.nextAddress();
        };
        self.tunnel = tunnel;
        self.startTimeout();
    }

    fn tunnelMessage(self: *Machine, t: *Tunnel, message: ssh.Message) void {
        const address = self.addresses[self.step];
        switch (message) {
            .ready => |r| {
                if (self.job != null) return;
                var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
                const local = std.fmt.bufPrint(&buf, "unix://{s}", .{r.socket}) catch return;
                self.startJob(local);
            },
            .prompt => |p| {
                // The user is answering: don't time out under them.
                self.clearTimeout();
                if (!self.interactive) return t.answer(p.id, "");
                t.ask(p.id, p.kind, p.text, address);
            },
            .done => |d| {
                t.promptDone(d.id);
                if (self.job == null and self.tunnel == t) self.startTimeout();
            },
            .exit => |e| {
                t.close();
                if (self.tunnel == t) self.tunnel = null;
                if (self.job) |j| j.machine = null;
                self.job = null;
                const kind = e.kind orelse .other;
                switch (kind) {
                    .host_key => self.noteError("{s}'s host key isn't trusted yet. Click to connect and check it.", .{address}),
                    .rex_not_found => self.noteError("Rex isn't installed on {s}, or isn't on the PATH of a non-interactive shell there.", .{address}),
                    .connect, .other => self.noteError("{s}", .{if (e.reason.len > 0) e.reason else "ssh stopped."}),
                }
                if (self.client == null) return self.nextAddress();
            },
            .unknown => {},
        }
    }

    /// The helper went away without saying why.
    fn tunnelEnded(self: *Machine, t: *Tunnel) void {
        if (self.tunnel != t) return;
        self.tunnel = null;
        if (self.client != null) return; // its connection drops on its own
        if (self.job) |j| j.machine = null;
        self.job = null;
        self.noteError("ssh to {s} stopped.", .{self.addresses[self.step]});
        self.nextAddress();
    }
};

// ----------------------------------------------------------------------
// Dialling on a worker thread

const Job = struct {
    /// Main thread only. Null once the machine stopped waiting.
    machine: ?*Machine,
    gpa: Allocator,
    io: std.Io,
    address: []u8,
    label: ?[]u8,
    reconnect_token: ?[]u8,
    /// The result, set by the worker.
    ctl: ?*control.Control = null,
    chosen: ?[]u8 = null,
    err: ?anyerror = null,

    fn create(m: *Machine, address: []const u8) !*Job {
        const gpa = m.gpa;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{
            .machine = m,
            .gpa = gpa,
            .io = m.io,
            .address = try gpa.dupe(u8, address),
            .label = if (m.client_label) |l| gpa.dupe(u8, l) catch null else null,
            .reconnect_token = if (m.reconnect_token) |t| gpa.dupe(u8, t) catch null else null,
        };
        return job;
    }

    fn destroy(job: *Job) void {
        const gpa = job.gpa;
        if (job.ctl) |c| c.destroy();
        gpa.free(job.address);
        if (job.label) |l| gpa.free(l);
        if (job.reconnect_token) |t| gpa.free(t);
        if (job.chosen) |c| gpa.free(c);
        gpa.destroy(job);
    }

    /// Worker thread: touches nothing but the job.
    fn run(job: *Job) void {
        defer mainloop.postWithPriority(Job, job, finish, .default);
        const candidates = endpoint.parse(job.address) catch |err| {
            job.err = err;
            return;
        };
        var chosen: endpoint.Endpoint = undefined;
        const ctl = control.connectAny(job.gpa, job.io, candidates.slice(), .{
            .info = .{ .label = job.label },
            .reconnect_token = job.reconnect_token,
        }, &chosen) catch |err| {
            job.err = err;
            return;
        };
        job.chosen = std.fmt.allocPrint(job.gpa, "{f}", .{chosen}) catch {
            ctl.close();
            ctl.destroy();
            job.err = error.OutOfMemory;
            return;
        };
        job.ctl = ctl;
    }

    /// Main thread.
    fn finish(job: *Job) void {
        defer job.destroy();
        const m = job.machine orelse {
            if (job.ctl) |c| c.close();
            return;
        };
        if (m.job != job) return;
        m.jobDone(job);
    }
};

// ----------------------------------------------------------------------
// The ssh tunnel helper

const Tunnel = struct {
    /// Null once the machine let go; the next read callback frees us.
    machine: ?*Machine,
    gpa: Allocator,
    proc: *gio.Subprocess,
    stdin: ?*gio.OutputStream,
    lines: *gio.DataInputStream,
    cancellable: *gio.Cancellable,
    in_callback: bool = false,

    /// ssh's open question, if any.
    dialog: ?*adw.AlertDialog = null,
    entry: ?*gtk.PasswordEntry = null,
    prompt_id: ?[]u8 = null,
    prompt_kind: ssh.PromptKind = .confirm,

    fn start(m: *Machine, address: []const u8, agent: ?[]const u8, interactive: bool) !*Tunnel {
        const gpa = m.gpa;
        const launcher = gio.SubprocessLauncher.new(.{ .stdin_pipe = true, .stdout_pipe = true, .stderr_silence = true });
        defer launcher.as(gobject.Object).unref();
        if (agent) |a| {
            const z = try gpa.dupeSentinel(u8, a, 0);
            defer gpa.free(z);
            launcher.setenv("SSH_AUTH_SOCK", z, 1);
        } else launcher.unsetenv("SSH_AUTH_SOCK");

        const addr_z = try gpa.dupeSentinel(u8, address, 0);
        defer gpa.free(addr_z);
        var argv_buf: [6:null]?[*:0]const u8 = .{ "rex", "__internal", "ssh-tunnel", null, null, null };
        var n: usize = 3;
        if (!interactive) {
            argv_buf[n] = "--no-prompt";
            n += 1;
        }
        argv_buf[n] = addr_z.ptr;

        var err: ?*glib.Error = null;
        const proc = launcher.spawnv(@ptrCast(&argv_buf), &err) orelse {
            if (err) |e| {
                log.warn("starting rex __internal ssh-tunnel failed: {s}", .{e.f_message orelse "?"});
                e.free();
            }
            return error.SpawnFailed;
        };
        errdefer proc.as(gobject.Object).unref();

        const t = try gpa.create(Tunnel);
        t.* = .{
            .machine = m,
            .gpa = gpa,
            .proc = proc,
            .stdin = proc.getStdinPipe(),
            .lines = gio.DataInputStream.new(proc.getStdoutPipe().?),
            .cancellable = gio.Cancellable.new(),
        };
        t.readNext();
        return t;
    }

    fn readNext(t: *Tunnel) void {
        t.lines.readLineAsync(glib.PRIORITY_DEFAULT, t.cancellable, &onLine, t);
    }

    fn onLine(_: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *Tunnel = @ptrCast(@alignCast(data.?));
        var len: usize = 0;
        var err: ?*glib.Error = null;
        const line = t.lines.readLineFinishUtf8(res, &len, &err);
        if (err) |e| e.free();
        const text = line orelse {
            // End of output: the helper exited, or we cancelled.
            if (t.machine) |m| {
                t.machine = null;
                m.tunnelEnded(t);
            }
            return t.free();
        };
        defer glib.free(text);

        if (t.machine) |m| {
            var parsed = ssh.parse(t.gpa, text[0..len]) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                t.in_callback = true;
                m.tunnelMessage(t, p.message);
                t.in_callback = false;
            }
        }
        if (t.machine == null) return t.free();
        t.readNext();
    }

    /// Let go: closing the helper's input stops it, which closes the
    /// forward and ssh with it.
    fn close(t: *Tunnel) void {
        if (t.machine == null) return;
        t.machine = null;
        t.closeDialog();
        if (t.stdin) |s| _ = s.close(null, null);
        t.stdin = null;
        // A read is pending unless we're inside its callback, which frees
        // us when it returns.
        if (!t.in_callback) t.cancellable.cancel();
    }

    fn free(t: *Tunnel) void {
        t.closeDialog();
        if (t.stdin) |s| _ = s.close(null, null);
        t.lines.as(gobject.Object).unref();
        t.cancellable.as(gobject.Object).unref();
        t.proc.as(gobject.Object).unref();
        t.gpa.destroy(t);
    }

    fn answer(t: *Tunnel, id: []const u8, text: []const u8) void {
        const stdin = t.stdin orelse return;
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        ssh.writeAnswer(&w, id, text) catch return;
        const out = w.buffered();
        _ = stdin.writeAll(out.ptr, out.len, null, null, null);
    }

    /// Show one of ssh's questions.
    fn ask(t: *Tunnel, id: []const u8, kind: ssh.PromptKind, text: []const u8, address: []const u8) void {
        const m = t.machine orelse return;
        t.closeDialog();
        const gpa = t.gpa;
        t.prompt_id = gpa.dupe(u8, id) catch return;
        t.prompt_kind = kind;

        var head_buf: [256]u8 = undefined;
        const heading = std.fmt.bufPrintSentinel(&head_buf, "Connecting to {s}", .{address}, 0) catch "Connecting";
        const body = gpa.dupeSentinel(u8, std.mem.trim(u8, text, " \r\n"), 0) catch return;
        defer gpa.free(body);
        const dialog = adw.AlertDialog.new(heading, body);
        dialog.addResponse("cancel", "Cancel");
        switch (kind) {
            .confirm => {
                dialog.addResponse("yes", "Trust and Connect");
                dialog.setResponseAppearance("yes", .suggested);
                dialog.setDefaultResponse("cancel");
            },
            .secret => {
                const entry = gtk.PasswordEntry.new();
                entry.setShowPeekIcon(1);
                entry.as(gtk.Widget).setHexpand(1);
                _ = gtk.PasswordEntry.signals.activate.connect(entry, *Tunnel, &onEntryActivate, t, .{});
                dialog.setExtraChild(entry.as(gtk.Widget));
                t.entry = entry;
                dialog.addResponse("yes", "Connect");
                dialog.setResponseAppearance("yes", .suggested);
                dialog.setDefaultResponse("yes");
            },
        }
        dialog.setCloseResponse("cancel");
        _ = adw.AlertDialog.signals.response.connect(dialog, *Tunnel, &onResponse, t, .{});
        t.dialog = dialog;
        dialog.as(adw.Dialog).present(m.listener.window(m.listener.ctx));
    }

    fn onEntryActivate(_: *gtk.PasswordEntry, t: *Tunnel) callconv(.c) void {
        t.respond(true);
    }

    fn onResponse(_: *adw.AlertDialog, response: [*:0]u8, t: *Tunnel) callconv(.c) void {
        t.respond(std.mem.eql(u8, std.mem.span(response), "yes"));
    }

    fn respond(t: *Tunnel, yes: bool) void {
        const id = t.prompt_id orelse return;
        defer t.closeDialog();
        switch (t.prompt_kind) {
            .confirm => t.answer(id, if (yes) "yes" else "no"),
            .secret => {
                if (!yes) {
                    // Nothing sensible to send: give up on this address.
                    const m = t.machine orelse return;
                    t.closeDialog();
                    m.tunnelMessage(t, .{ .exit = .{ .reason = "Canceled.", .kind = .other } });
                    return;
                }
                const text = if (t.entry) |e| std.mem.span(e.as(gtk.Editable).getText()) else "";
                t.answer(id, text);
            },
        }
    }

    /// The helper finished with a prompt, maybe without our answer.
    fn promptDone(t: *Tunnel, id: []const u8) void {
        const open = t.prompt_id orelse return;
        if (std.mem.eql(u8, open, id)) t.closeDialog();
    }

    fn closeDialog(t: *Tunnel) void {
        if (t.prompt_id) |p| t.gpa.free(p);
        t.prompt_id = null;
        t.entry = null;
        const d = t.dialog orelse return;
        t.dialog = null;
        _ = gobject.signalHandlersDisconnectMatched(d.as(gobject.Object), .{ .data = true }, 0, 0, null, null, t);
        d.as(adw.Dialog).forceClose();
    }
};

// ----------------------------------------------------------------------

/// Start this computer's Rex server if it isn't running, the way the rex
/// CLI does.
pub fn startLocalServer() void {
    const argv = [_:null]?[*:0]const u8{ "rex", "__internal", "autostart-status", null };
    var err: ?*glib.Error = null;
    const proc = gio.Subprocess.newv(@ptrCast(&argv), .{ .stdout_silence = true, .stderr_silence = true }, &err) orelse {
        if (err) |e| {
            log.warn("starting the Rex server failed: {s}", .{e.f_message orelse "?"});
            e.free();
        }
        return;
    };
    proc.as(gobject.Object).unref();
}

fn dupeList(gpa: Allocator, list: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (list) |s| {
        out[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn freeList(gpa: Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn freeOpt(gpa: Allocator, p: *?[]u8) void {
    if (p.*) |s| gpa.free(s);
    p.* = null;
}
