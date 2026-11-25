//! What the sidebar lists for one machine: each session's windows, and
//! the title and working directory of each window's focused block.
//!
//! Sessions come from the machine's session list. Their windows come from
//! `session.view`, fetched again on `session_view_changed`. Titles and
//! directories come from `title_changed` and `pwd_changed` block events
//! (the app subscribes with event_scope "all"), and are asked for once for
//! a block we haven't heard about.

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const Incoming = @import("client.zig").Incoming;
const Machine = @import("machine.zig").Machine;

const log = std.log.scoped(.overview);

pub const Window = struct {
    window_id: []u8,
    label: []u8,
    focused_block_id: ?[]u8,
    /// Every block the window shows, for its activity.
    blocks: [][]u8 = &.{},
};

/// What programs in a terminal say they're doing (OSC 7501), most urgent
/// last: a tab shows the most urgent of its blocks.
pub const Activity = enum(u8) {
    idle,
    done,
    working,
    @"error",
    blocked,

    pub fn parse(text: []const u8) Activity {
        return std.meta.stringToEnum(Activity, text) orelse .idle;
    }
};

/// One status record a program reported.
pub const Record = struct {
    id: []u8,
    state: Activity,
    /// The program, such as claude or cargo.
    app: ?[]u8 = null,
    /// What it says it's doing, as plain text.
    text: ?[]u8 = null,
};

/// The most urgent state among some records, with the record's details.
pub const Summary = struct {
    state: Activity = .idle,
    app: ?[]const u8 = null,
    text: ?[]const u8 = null,

    fn merge(self: *Summary, r: Record) void {
        if (@intFromEnum(r.state) > @intFromEnum(self.state) or (self.app == null and r.app != null and r.state == self.state)) {
            self.state = r.state;
            self.app = r.app orelse self.app;
            self.text = r.text;
        }
    }
};

pub const Session = struct {
    session_id: []u8,
    revision: u64 = 0,
    active_window_id: ?[]u8 = null,
    windows: std.ArrayList(Window) = .empty,
    /// A view request is in flight, and whether another is needed after.
    fetching: bool = false,
    stale: bool = false,
};

pub const BlockInfo = struct {
    title: ?[]u8 = null,
    /// The working directory as a path, decoded from file:// URLs.
    pwd: ?[]u8 = null,
    asked: bool = false,
    asked_status: bool = false,
    records: std.ArrayList(Record) = .empty,

    pub fn summary(self: *const BlockInfo) Summary {
        var out: Summary = .{};
        for (self.records.items) |r| out.merge(r);
        return out;
    }
};

pub const Overview = struct {
    gpa: Allocator,
    machine: *Machine,
    sessions: std.ArrayList(*Session) = .empty,
    blocks: std.StringHashMapUnmanaged(BlockInfo) = .empty,
    /// Called after anything the sidebar shows changed.
    changed: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, m: *Machine) void } = null,
    /// Called when a block's activity changes, such as a program becoming
    /// blocked on a question.
    activity: ?struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, m: *Machine, session_id: []const u8, window_id: []const u8, before: Activity, now: Summary) void,
    } = null,

    pub fn init(gpa: Allocator, machine: *Machine) Overview {
        return .{ .gpa = gpa, .machine = machine };
    }

    pub fn deinit(self: *Overview) void {
        self.clear();
        self.sessions.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
    }

    /// Forget everything, as when the connection drops.
    pub fn clear(self: *Overview) void {
        for (self.sessions.items) |s| self.freeSession(s);
        self.sessions.clearRetainingCapacity();
        var it = self.blocks.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            freeInfo(self.gpa, e.value_ptr);
        }
        self.blocks.clearRetainingCapacity();
    }

    fn freeSession(self: *Overview, s: *Session) void {
        self.clearWindows(s);
        s.windows.deinit(self.gpa);
        if (s.active_window_id) |a| self.gpa.free(a);
        self.gpa.free(s.session_id);
        self.gpa.destroy(s);
    }

    fn clearWindows(self: *Overview, s: *Session) void {
        for (s.windows.items) |w| {
            self.gpa.free(w.window_id);
            self.gpa.free(w.label);
            if (w.focused_block_id) |b| self.gpa.free(b);
            for (w.blocks) |b| self.gpa.free(b);
            self.gpa.free(w.blocks);
        }
        s.windows.clearRetainingCapacity();
    }

    fn freeInfo(gpa: Allocator, info: *BlockInfo) void {
        if (info.title) |t| gpa.free(t);
        if (info.pwd) |p| gpa.free(p);
        for (info.records.items) |r| freeRecord(gpa, r);
        info.records.deinit(gpa);
    }

    fn freeRecord(gpa: Allocator, r: Record) void {
        gpa.free(r.id);
        if (r.app) |a| gpa.free(a);
        if (r.text) |t| gpa.free(t);
    }

    /// The most urgent activity among a window's blocks.
    pub fn windowSummary(self: *const Overview, w: Window) Summary {
        var out: Summary = .{};
        for (w.blocks) |b| if (self.blocks.getPtr(b)) |info| {
            const s = info.summary();
            if (@intFromEnum(s.state) > @intFromEnum(out.state) or (out.app == null and s.app != null)) {
                if (@intFromEnum(s.state) >= @intFromEnum(out.state)) out = s else out.app = s.app;
            }
        };
        return out;
    }

    fn notify(self: *Overview) void {
        if (self.changed) |c| c.func(c.ctx, self.machine);
    }

    pub fn session(self: *const Overview, session_id: []const u8) ?*Session {
        for (self.sessions.items) |s| if (std.mem.eql(u8, s.session_id, session_id)) return s;
        return null;
    }

    pub fn block(self: *const Overview, block_id: []const u8) ?*const BlockInfo {
        return self.blocks.getPtr(block_id);
    }

    /// Follow the machine's session list: drop sessions that ended and
    /// fetch the windows of new ones.
    pub fn sync(self: *Overview, ids: []const []const u8) void {
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            const keep = for (ids) |id| {
                if (std.mem.eql(u8, id, s.session_id)) break true;
            } else false;
            if (keep) {
                i += 1;
            } else {
                _ = self.sessions.orderedRemove(i);
                self.freeSession(s);
            }
        }
        for (ids) |id| {
            if (self.session(id) != null) continue;
            const s = self.gpa.create(Session) catch continue;
            s.* = .{ .session_id = self.gpa.dupe(u8, id) catch {
                self.gpa.destroy(s);
                continue;
            } };
            self.sessions.append(self.gpa, s) catch {
                self.freeSession(s);
                continue;
            };
            self.fetchView(s);
        }
        // Keep the server's order.
        std.mem.sort(*Session, self.sessions.items, ids, struct {
            fn lessThan(order: []const []const u8, a: *Session, b: *Session) bool {
                return indexOf(order, a.session_id) < indexOf(order, b.session_id);
            }
            fn indexOf(order: []const []const u8, id: []const u8) usize {
                for (order, 0..) |x, n| if (std.mem.eql(u8, x, id)) return n;
                return order.len;
            }
        }.lessThan);
        self.notify();
    }

    // ------------------------------------------------------------------
    // Views

    const ViewReq = struct { ov: *Overview, session_id: []u8 };

    fn fetchView(self: *Overview, s: *Session) void {
        if (s.fetching) {
            s.stale = true;
            return;
        }
        const req = self.gpa.create(ViewReq) catch return;
        req.* = .{ .ov = self, .session_id = self.gpa.dupe(u8, s.session_id) catch {
            self.gpa.destroy(req);
            return;
        } };
        s.fetching = true;
        s.stale = false;
        self.machine.call("session.view", .{ .session_id = s.session_id }, req, &onView);
    }

    fn onView(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *ViewReq = @ptrCast(@alignCast(ctx.?));
        const self = req.ov;
        defer {
            self.gpa.free(req.session_id);
            self.gpa.destroy(req);
        }
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        const s = self.session(req.session_id) orelse return;
        s.fetching = false;
        if (s.stale) self.fetchView(s);
        const view = api.parse(api.View, msg) orelse return;
        if (view.revision < s.revision) return;
        s.revision = view.revision;

        self.clearWindows(s);
        if (s.active_window_id) |a| self.gpa.free(a);
        s.active_window_id = if (view.active_window_id) |a| self.gpa.dupe(u8, a) catch null else null;
        for (view.windows orelse &.{}) |w| {
            const id = w.window_id;
            var blocks: std.ArrayList([]u8) = .empty;
            for (w.layers orelse &.{}) |layer| for (layer.blocks orelse &.{}) |b| {
                const bid = b.block_id;
                blocks.append(self.gpa, self.gpa.dupe(u8, bid) catch continue) catch {};
            };
            const win: Window = .{
                .window_id = self.gpa.dupe(u8, id) catch continue,
                .label = self.gpa.dupe(u8, w.label orelse "") catch continue,
                .focused_block_id = if (w.focused_block_id) |b| self.gpa.dupe(u8, b) catch null else null,
                .blocks = blocks.toOwnedSlice(self.gpa) catch &.{},
            };
            s.windows.append(self.gpa, win) catch continue;
            if (win.focused_block_id) |b| self.learnBlock(s.session_id, b);
            for (win.blocks) |b| self.learnStatus(s.session_id, b);
        }
        self.notify();
    }

    // ------------------------------------------------------------------
    // Blocks

    /// Ask for a block's title and directory, once.
    fn learnBlock(self: *Overview, session_id: []const u8, block_id: []const u8) void {
        const entry = self.blocks.getOrPut(self.gpa, block_id) catch return;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.gpa.dupe(u8, block_id) catch {
                self.blocks.removeByPtr(entry.key_ptr);
                return;
            };
            entry.value_ptr.* = .{};
        }
        if (entry.value_ptr.asked) return;
        entry.value_ptr.asked = true;
        self.askBlock(session_id, entry.key_ptr.*, "com.superlogical.terminal.title", &onTitle);
        self.askBlock(session_id, entry.key_ptr.*, "com.superlogical.terminal.pwd", &onPwd);
    }

    /// Ask for what a block's programs last reported, once.
    fn learnStatus(self: *Overview, session_id: []const u8, block_id: []const u8) void {
        const info = self.infoFor(block_id) orelse return;
        if (info.asked_status) return;
        info.asked_status = true;
        const key = self.blocks.getKey(block_id).?;
        self.askBlock(session_id, key, "com.superlogical.terminal.program_status", &onStatus);
    }

    fn infoFor(self: *Overview, block_id: []const u8) ?*BlockInfo {
        const entry = self.blocks.getOrPut(self.gpa, block_id) catch return null;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.gpa.dupe(u8, block_id) catch {
                self.blocks.removeByPtr(entry.key_ptr);
                return null;
            };
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    const RecordJson = struct {
        id: ?[]const u8 = null,
        state: []const u8 = "idle",
        app: ?[]const u8 = null,
        effective_app: ?[]const u8 = null,
        title: ?[]const u8 = null,
        msg: ?[]const u8 = null,
    };

    fn onStatus(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *BlockReq = @ptrCast(@alignCast(ctx.?));
        defer finishReq(req);
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err != null) return;
        const res = api.parse(struct { records: ?[]const RecordJson = null }, msg) orelse return;
        for (res.records orelse &.{}) |r| req.ov.putRecord(req.block_id, r.id orelse "", r);
    }

    /// Store a record, and tell the listener if the block's state changed.
    fn putRecord(self: *Overview, block_id: []const u8, id: []const u8, r: RecordJson) void {
        const info = self.infoFor(block_id) orelse return;
        const before = info.summary().state;
        const gpa = self.gpa;
        const text = r.msg orelse r.title;
        const record: Record = .{
            .id = gpa.dupe(u8, id) catch return,
            .state = Activity.parse(r.state),
            .app = if (r.effective_app orelse r.app) |a| gpa.dupe(u8, a) catch null else null,
            .text = if (text) |t| gpa.dupe(u8, t) catch null else null,
        };
        const existing = for (info.records.items) |*old| {
            if (std.mem.eql(u8, old.id, id)) break old;
        } else null;
        if (existing) |old| {
            freeRecord(gpa, old.*);
            old.* = record;
        } else {
            info.records.append(gpa, record) catch freeRecord(gpa, record);
        }
        self.activityChanged(block_id, before, info);
    }

    fn removeRecords(self: *Overview, block_id: []const u8, ids: []const []const u8) void {
        const info = self.blocks.getPtr(block_id) orelse return;
        const before = info.summary().state;
        var i: usize = 0;
        while (i < info.records.items.len) {
            const r = info.records.items[i];
            const gone = for (ids) |id| {
                if (std.mem.eql(u8, id, r.id)) break true;
            } else false;
            if (gone) {
                freeRecord(self.gpa, r);
                _ = info.records.orderedRemove(i);
            } else i += 1;
        }
        self.activityChanged(block_id, before, info);
    }

    fn activityChanged(self: *Overview, block_id: []const u8, before: Activity, info: *BlockInfo) void {
        const now = info.summary();
        self.notify();
        if (now.state == before) return;
        const cb = self.activity orelse return;
        // Find the tab the block is in.
        for (self.sessions.items) |s| for (s.windows.items) |w| for (w.blocks) |b| {
            if (std.mem.eql(u8, b, block_id)) return cb.func(cb.ctx, self.machine, s.session_id, w.window_id, before, now);
        };
    }

    const BlockReq = struct { ov: *Overview, block_id: []u8 };

    fn askBlock(self: *Overview, session_id: []const u8, block_id: []const u8, method: []const u8, cb: @import("client.zig").ResponseFn) void {
        const req = self.gpa.create(BlockReq) catch return;
        req.* = .{ .ov = self, .block_id = self.gpa.dupe(u8, block_id) catch {
            self.gpa.destroy(req);
            return;
        } };
        self.machine.call(method, .{ .session_id = session_id, .block_id = block_id, .args = struct {}{} }, req, cb);
    }

    fn finishReq(req: *BlockReq) void {
        req.ov.gpa.free(req.block_id);
        req.ov.gpa.destroy(req);
    }

    fn onTitle(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *BlockReq = @ptrCast(@alignCast(ctx.?));
        defer finishReq(req);
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err != null) return; // not a terminal
        const res = api.parse(struct { title: []const u8 = "" }, msg) orelse return;
        req.ov.setTitle(req.block_id, res.title);
    }

    fn onPwd(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
        const req: *BlockReq = @ptrCast(@alignCast(ctx.?));
        defer finishReq(req);
        const msg = maybe_msg orelse return;
        defer msg.deinit();
        if (msg.kind.response.err != null) return;
        const res = api.parse(struct { pwd: ?[]const u8 = null }, msg) orelse return;
        if (res.pwd) |p| req.ov.setPwd(req.block_id, p);
    }

    pub fn setTitle(self: *Overview, block_id: []const u8, title: []const u8) void {
        const info = self.blocks.getPtr(block_id) orelse return;
        if (info.title) |t| {
            if (std.mem.eql(u8, t, title)) return;
            self.gpa.free(t);
        }
        info.title = self.gpa.dupe(u8, title) catch null;
        self.notify();
    }

    pub fn setPwd(self: *Overview, block_id: []const u8, reported: []const u8) void {
        const info = self.blocks.getPtr(block_id) orelse return;
        const path = decodePwd(self.gpa, reported) catch return;
        if (info.pwd) |p| {
            if (std.mem.eql(u8, p, path)) {
                self.gpa.free(path);
                return;
            }
            self.gpa.free(p);
        }
        info.pwd = path;
        self.notify();
    }

    // ------------------------------------------------------------------
    // Events

    /// A `session_event` from the machine.
    pub fn sessionEvent(self: *Overview, msg: Incoming, session_id: []const u8, event_type: []const u8, payload: std.json.Value) void {
        const eq = std.mem.eql;
        if (eq(u8, event_type, "session_view_changed")) {
            const s = self.session(session_id) orelse return;
            const p = api.parseValue(struct { revision: u64 = 0 }, msg, payload) orelse return;
            if (p.revision > s.revision) self.fetchView(s);
        } else if (eq(u8, event_type, "block_event")) {
            const p = api.parseValue(struct { block_id: []const u8, name: []const u8, payload: std.json.Value = .null }, msg, payload) orelse return;
            if (eq(u8, p.name, "title_changed")) {
                const t = api.parseValue(struct { title: []const u8 = "" }, msg, p.payload) orelse return;
                self.setTitle(p.block_id, t.title);
            } else if (eq(u8, p.name, "pwd_changed")) {
                const d = api.parseValue(struct { pwd: []const u8 = "" }, msg, p.payload) orelse return;
                self.setPwd(p.block_id, d.pwd);
            } else if (eq(u8, p.name, "program_status_changed")) {
                const d = api.parseValue(struct { id: []const u8 = "", record: RecordJson = .{} }, msg, p.payload) orelse return;
                self.putRecord(p.block_id, d.id, d.record);
            } else if (eq(u8, p.name, "program_status_removed")) {
                const d = api.parseValue(struct { ids: []const []const u8 = &.{} }, msg, p.payload) orelse return;
                self.removeRecords(p.block_id, d.ids);
            }
        }
    }
};

/// A directory from OSC 7 (`file://host/path`, percent-encoded) or a plain
/// path. Caller owns the result.
pub fn decodePwd(gpa: Allocator, reported: []const u8) ![]u8 {
    var path = reported;
    if (std.mem.startsWith(u8, path, "file://")) {
        const rest = path["file://".len..];
        path = if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[i..] else "/";
    }
    const out = try gpa.alloc(u8, path.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (n += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16)) |c| {
                out[n] = c;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = path[i];
        i += 1;
    }
    return gpa.realloc(out, n);
}

/// The name a tab shows: its window's label unless that's the default
/// "Window xxxxxxxx", else the focused program's title, else "Terminal".
pub fn tabTitle(label: []const u8, pane_title: ?[]const u8) []const u8 {
    const default_label = isDefaultWindowLabel(label);
    if (pane_title) |t| if (t.len > 0 and (label.len == 0 or default_label)) return t;
    if (label.len > 0 and !default_label) return label;
    return "Terminal";
}

pub fn isDefaultWindowLabel(label: []const u8) bool {
    const prefix = "Window ";
    if (!std.mem.startsWith(u8, label, prefix)) return false;
    const rest = label[prefix.len..];
    if (rest.len != 8) return false;
    for (rest) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// `path` with `home` shortened to ~.
pub fn tildePath(buf: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    const rest = path[h.len..];
    if (rest.len > 0 and rest[0] != '/') return path;
    return std.fmt.bufPrint(buf, "~{s}", .{rest}) catch path;
}
