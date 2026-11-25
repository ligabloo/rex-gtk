//! Turning key presses into actions, with the keymap the server resolves
//! for this client (`client.keymap`): our built-in bindings, under the
//! user's Rex configuration file, under its Lua scripts.
//!
//! Handles key sequences (such as ctrl+b then %), modes, keys bound to Lua
//! functions (`client.key.forward`), and actions that run on the server
//! (configuration file actions and block actions, via `client.action`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const App = @import("app.zig").App;
const actions = @import("actions.zig");
const keymap = @import("keymap.zig");
const input = @import("input.zig");
const tv = @import("terminal_view.zig");
const api = @import("api.zig");
const Incoming = @import("client.zig").Incoming;

const log = std.log.scoped(.keys);

const Mode = struct {
    name: []const u8,
    exclusive: bool = false,
    blocked: ?[]const ?[]const ?[]const u8 = null,
};

/// The resolved keymap, as `client.keymap` returned it.
const Resolved = struct {
    bindings: []const keymap.Binding,
    modes: []const Mode,
    /// Names of the server's actions (configuration file and blocks).
    server_actions: std.StringHashMapUnmanaged(void),
    hash: []const u8,
};

pub const Keys = struct {
    gpa: Allocator,
    app: *App,
    /// Owns everything in `resolved`.
    arena: ?std.heap.ArenaAllocator = null,
    resolved: ?Resolved = null,

    /// The keys of a sequence typed so far.
    prefix: std.ArrayList(keymap.Press) = .empty,
    prefix_names: std.ArrayList([]const u8) = .empty,
    /// The active mode, and whether it ends after one action.
    mode: ?[]const u8 = null,
    mode_once: bool = false,
    /// Storage for `mode` and `prefix_names`.
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, app: *App) Keys {
        return .{ .gpa = gpa, .app = app, .scratch = .init(gpa) };
    }

    pub fn deinit(self: *Keys) void {
        if (self.arena) |*a| a.deinit();
        self.prefix.deinit(self.gpa);
        self.prefix_names.deinit(self.gpa);
        self.scratch.deinit();
    }

    fn bindings(self: *const Keys) []const keymap.Binding {
        return if (self.resolved) |r| r.bindings else &keymap.defaults;
    }

    // ------------------------------------------------------------------
    // Fetching the keymap

    /// Ask the server for our keymap, declaring our actions and built-in
    /// bindings. Called at startup and after `keymap_changed`.
    pub fn fetch(self: *Keys) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const Decl = struct {
            name: []const u8,
            kind: []const u8 = "client",
            title: []const u8,
            category: []const u8,
            args: ?std.json.Value = null,
            repeats: bool = false,
        };
        const decls = a.alloc(Decl, actions.all.len) catch return;
        for (actions.all, decls) |act, *d| d.* = .{
            .name = act.name,
            .title = act.title,
            .category = act.category,
            .args = if (act.args) |s| std.json.parseFromSliceLeaky(std.json.Value, a, s, .{}) catch null else null,
            .repeats = act.repeats,
        };
        const B = struct { keys: []const []const u8, action: []const u8, args: ?std.json.Value = null };
        const defaults = a.alloc(B, keymap.defaults.len) catch return;
        for (keymap.defaults, defaults) |b, *d| d.* = .{
            .keys = b.keys,
            .action = b.action,
            .args = if (b.args) |s| std.json.parseFromSliceLeaky(std.json.Value, a, s, .{}) catch null else null,
        };
        // The keymap is this computer's, whichever machine is shown.
        self.app.localMachine().call("client.keymap", .{
            .actions = decls,
            .server_actions = "all",
            .defaults = &[_]struct { name: []const u8, bindings: []const B }{.{ .name = "default", .bindings = defaults }},
        }, self, &onKeymap);
    }

    fn onKeymap(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *Keys = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        const a = arena.allocator();
        const Result = struct {
            bindings: ?[]const struct {
                keys: ?[]const ?[]const u8 = null,
                action: []const u8,
                args: ?std.json.Value = null,
                mode: ?[]const u8 = null,
            } = null,
            diagnostics: ?[]const struct { severity: []const u8, message: []const u8, source: ?[]const u8 = null } = null,
            actions: ?[]const struct { name: []const u8 } = null,
            modes: ?[]const Mode = null,
            config: struct { hash: []const u8 = "" } = .{},
        };
        if (msg.kind.response.err) |e| {
            log.warn("client.keymap failed: {s}; using built-in bindings", .{e.message});
            arena.deinit();
            return;
        }
        const res = std.json.parseFromValueLeaky(Result, a, msg.kind.response.payload, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("unexpected client.keymap result: {}", .{err});
            arena.deinit();
            return;
        };
        for (res.diagnostics orelse &.{}) |d| log.warn("keymap {s}: {s} ({s})", .{ d.severity, d.message, d.source orelse "" });

        // Copy what we keep out of the message into our arena.
        var list: std.ArrayList(keymap.Binding) = .empty;
        for (res.bindings orelse &.{}) |b| {
            const keys_in = b.keys orelse continue;
            const keys = a.alloc([]const u8, keys_in.len) catch continue;
            var ok = true;
            for (keys_in, keys) |k, *out| out.* = if (k) |s| (a.dupe(u8, s) catch "") else blk: {
                ok = false;
                break :blk "";
            };
            if (!ok) continue;
            const args: ?[]const u8 = if (b.args) |v| (if (v == .null) null else std.json.Stringify.valueAlloc(a, v, .{}) catch null) else null;
            list.append(a, .{
                .keys = keys,
                .action = a.dupe(u8, b.action) catch continue,
                .args = args,
                .mode = if (b.mode) |m| a.dupe(u8, m) catch null else null,
            }) catch continue;
        }
        var server_actions: std.StringHashMapUnmanaged(void) = .empty;
        for (res.actions orelse &.{}) |act| server_actions.put(a, a.dupe(u8, act.name) catch continue, {}) catch {};
        const modes_in: []const Mode = res.modes orelse &.{};
        const modes: []Mode = a.alloc(Mode, modes_in.len) catch {
            arena.deinit();
            return;
        };
        for (modes_in, modes) |m, *out| out.* = .{
            .name = a.dupe(u8, m.name) catch "",
            .exclusive = m.exclusive,
            .blocked = dupeBlocked(a, m.blocked),
        };

        if (self.arena) |*old| old.deinit();
        self.arena = arena;
        self.resolved = .{
            .bindings = list.items,
            .modes = modes,
            .server_actions = server_actions,
            .hash = a.dupe(u8, res.config.hash) catch "",
        };
        self.resetPrefix();
        log.info("keymap: {d} bindings, {d} server actions, {d} modes", .{ list.items.len, server_actions.count(), modes.len });
    }

    fn dupeBlocked(a: Allocator, blocked: ?[]const ?[]const ?[]const u8) ?[]const ?[]const ?[]const u8 {
        const b = blocked orelse return null;
        const out = a.alloc(?[]const ?[]const u8, b.len) catch return null;
        for (b, out) |seq, *o| {
            const s = seq orelse {
                o.* = null;
                continue;
            };
            const keys = a.alloc(?[]const u8, s.len) catch return null;
            for (s, keys) |k, *ko| ko.* = if (k) |x| a.dupe(u8, x) catch null else null;
            o.* = keys;
        }
        return out;
    }

    /// `keymap_changed`: fetch again unless the configuration is unchanged.
    pub fn changed(self: *Keys, hash: []const u8) void {
        if (self.resolved) |r| if (std.mem.eql(u8, r.hash, hash)) return;
        self.fetch();
    }

    // ------------------------------------------------------------------
    // Key presses

    fn resetPrefix(self: *Keys) void {
        self.prefix.clearRetainingCapacity();
        self.prefix_names.clearRetainingCapacity();
        if (self.mode == null) _ = self.scratch.reset(.retain_capacity);
        self.app.keyStateChanged();
    }

    pub fn modeName(self: *const Keys) ?[]const u8 {
        return self.mode;
    }

    pub fn pendingPrefix(self: *const Keys) []const []const u8 {
        return self.prefix_names.items;
    }

    fn findMode(self: *const Keys, name: []const u8) ?Mode {
        const r = self.resolved orelse return null;
        for (r.modes) |m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    fn available(self: *const Keys, name: []const u8) bool {
        if (actions.find(name) != null) return true;
        if (std.mem.eql(u8, name, "client.key.forward")) return true;
        if (std.mem.startsWith(u8, name, "client.mode.")) return true;
        if (self.resolved) |r| if (r.server_actions.contains(name)) return true;
        return false;
    }

    /// Every key press in a terminal comes here first. Returns true if the
    /// key was used for a binding; false sends it to the terminal.
    pub fn handle(self: *Keys, pane: *tv.Pane, keyval: u32, keycode: u32, state: gdk.ModifierType, event: *gdk.KeyEvent, repeat: bool) bool {
        const display = pane.widgetPtr().getDisplay();
        const press: keymap.Press = .{
            .physical = input.keyName(keycode),
            .mods = .{ .shift = state.shift_mask, .ctrl = state.control_mask, .alt = state.alt_mask, .super = state.super_mask },
            .unshifted = @intCast(input.unshiftedCodepoint(display, keycode, event.getLayout())),
            .shifted = @intCast(gdk.keyvalToUnicode(keyval)),
        };
        if (isModifier(press.physical)) return false;

        const depth = self.prefix.items.len;
        const mode = self.mode;
        // Bindings in the active mode come first, then the rest unless the
        // mode is exclusive.
        const passes: []const ?[]const u8 = if (mode) |m| &.{ m, null } else &.{null};
        for (passes) |pass_mode| {
            if (pass_mode == null) if (mode) |m| if (self.findMode(m)) |info| {
                if (info.exclusive or self.isBlocked(info, press)) {
                    if (depth > 0) self.resetPrefix();
                    return true;
                }
            };
            for (self.bindings()) |b| {
                if (!sameMode(b.mode, pass_mode)) continue;
                if (b.keys.len <= depth) continue;
                if (!self.prefixMatches(b)) continue;
                const key = keymap.Key.parse(b.keys[depth]) orelse continue;
                if (!key.matches(press)) continue;
                if (!self.available(b.action)) continue;

                if (b.keys.len > depth + 1) {
                    // The start of a sequence: wait for the next key.
                    self.prefix.append(self.gpa, press) catch return true;
                    self.prefix_names.append(self.gpa, self.scratch.allocator().dupe(u8, b.keys[depth]) catch "") catch {};
                    self.app.keyStateChanged();
                    return true;
                }
                return self.run(pane, b, repeat);
            }
        }
        // A sequence that went nowhere: drop it, and the key with it.
        if (depth > 0) {
            self.resetPrefix();
            return true;
        }
        return false;
    }

    fn sameMode(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn prefixMatches(self: *const Keys, b: keymap.Binding) bool {
        for (self.prefix.items, 0..) |p, i| {
            const k = keymap.Key.parse(b.keys[i]) orelse return false;
            if (!k.matches(p)) return false;
        }
        return true;
    }

    fn isBlocked(self: *const Keys, mode: Mode, press: keymap.Press) bool {
        _ = self;
        for (mode.blocked orelse &.{}) |seq| {
            const s = seq orelse continue;
            if (s.len != 1) continue;
            const k = keymap.Key.parse(s[0] orelse continue) orelse continue;
            if (k.matches(press)) return true;
        }
        return false;
    }

    fn isModifier(physical: []const u8) bool {
        for ([_][]const u8{ "shift_left", "shift_right", "control_left", "control_right", "alt_left", "alt_right", "meta_left", "meta_right", "caps_lock" }) |m| {
            if (std.mem.eql(u8, physical, m)) return true;
        }
        return false;
    }

    fn run(self: *Keys, pane: *tv.Pane, b: keymap.Binding, repeat: bool) bool {
        // The keys typed before this one, for client.key.forward.
        const had_prefix = self.prefix_names.items.len > 0;
        defer if (had_prefix) self.resetPrefix();

        if (std.mem.eql(u8, b.action, "client.key.forward")) {
            // A key bound to a Lua function: send it to the server, which
            // runs the function.
            if (had_prefix) pane.setKeyPrefix(self.prefix_names.items);
            return false;
        }
        if (repeat) {
            const act = actions.find(b.action);
            if (act == null or !act.?.repeats) return true;
        }

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const args: std.json.Value = if (b.args) |a|
            std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), a, .{}) catch .null
        else
            .null;
        self.perform(b.action, args, "key");
        return true;
    }

    /// Perform any action a binding or a server reply can name.
    pub fn perform(self: *Keys, name: []const u8, args: std.json.Value, origin: []const u8) void {
        const app = self.app;
        if (std.mem.eql(u8, name, "client.mode.enter")) {
            const m = if (args == .object) args.object.get("name") else null;
            if (m == null or m.? != .string) return;
            self.mode = self.scratch.allocator().dupe(u8, m.?.string) catch return;
            const once = if (args == .object) args.object.get("once") else null;
            self.mode_once = once != null and once.? == .bool and once.?.bool;
            app.keyStateChanged();
            return;
        }
        if (std.mem.eql(u8, name, "client.mode.exit") or std.mem.eql(u8, name, "client.mode.exit_all")) {
            self.mode = null;
            app.keyStateChanged();
            return;
        }
        defer if (self.mode_once) {
            self.mode = null;
            self.mode_once = false;
            app.keyStateChanged();
        };

        if (actions.find(name) != null) return actions.run(app, name, args);

        // A configuration file or block action: the server runs it.
        const view = app.view;
        app.rex().call("client.action", .{
            .action = name,
            .args = @as(?std.json.Value, if (args == .null) null else args),
            .origin = origin,
            .session_id = if (view) |v| v.session_id else null,
        }, self, &onActionDone);
    }

    fn onActionDone(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const self: *Keys = @ptrCast(@alignCast(ctx.?));
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const res = api.parse(struct {
            client_actions: ?[]const struct { action: []const u8, args: std.json.Value = .null } = null,
        }, msg) orelse return;
        // Actions the Lua code queued for us with rex.client.queue.
        for (res.client_actions orelse &.{}) |ca| self.perform(ca.action, ca.args, "key");
    }
};
