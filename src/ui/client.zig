//! The app's control connection: requests from the main thread, a reader
//! thread for responses and events, and routing of each response to the
//! callback of the request it answers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const control = core.control;
const mainloop = @import("mainloop.zig");

const log = std.log.scoped(.client);

pub const Incoming = control.Incoming;

/// Called on the main thread with a response. The callee owns `msg` and
/// must `deinit` it. `msg` is null if the connection closed first.
pub const ResponseFn = *const fn (ctx: ?*anyopaque, msg: ?Incoming) void;

pub const Handler = struct {
    ctx: ?*anyopaque,
    /// An event arrived. The handler owns `msg`.
    event: *const fn (ctx: ?*anyopaque, msg: Incoming) void,
    /// The connection is gone.
    disconnected: *const fn (ctx: ?*anyopaque) void,
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    ctl: *control.Control,
    handler: Handler,
    thread: ?std.Thread = null,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
    closed: bool = false,

    const Pending = struct {
        ctx: ?*anyopaque,
        callback: ResponseFn,
    };

    /// Take over a control connection that has said hello, and start
    /// reading from it. On error the caller keeps `ctl`.
    pub fn start(gpa: Allocator, io: std.Io, ctl: *control.Control, handler: Handler) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .ctl = ctl,
            .handler = handler,
        };
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    /// Close the connection and free the client. Main thread only.
    pub fn destroy(self: *Client) void {
        self.closed = true;
        self.ctl.close();
        self.ctl.conn.shutdown();
        if (self.thread) |t| t.join();
        var it = self.pending.valueIterator();
        while (it.next()) |p| p.callback(p.ctx, null);
        self.pending.clearAndFree(self.gpa);
        // Deliveries the reader already queued still point at us. They run
        // in order, so free after them; each sees `closed` and does nothing.
        mainloop.post(Client, self, free);
    }

    fn free(self: *Client) void {
        self.ctl.destroy();
        self.gpa.destroy(self);
    }

    pub fn clientId(self: *const Client) []const u8 {
        return self.ctl.clientId();
    }

    /// Send a request; `callback` gets the response on the main thread.
    pub fn call(
        self: *Client,
        method: []const u8,
        payload: anytype,
        ctx: ?*anyopaque,
        callback: ResponseFn,
    ) void {
        const id = self.ctl.request(method, payload) catch |err| {
            log.warn("sending {s} failed: {}", .{ method, err });
            callback(ctx, null);
            return;
        };
        self.pending.put(self.gpa, id, .{ .ctx = ctx, .callback = callback }) catch {
            log.warn("out of memory tracking {s}", .{method});
        };
    }

    /// Send a request whose result doesn't matter. Errors are logged.
    pub fn send(self: *Client, method: []const u8, payload: anytype) void {
        self.call(method, payload, @ptrCast(@constCast(method.ptr)), &logError);
    }

    fn logError(ctx: ?*anyopaque, msg: ?Incoming) void {
        const method: [*:0]const u8 = @ptrCast(ctx.?);
        const m = msg orelse return;
        defer m.deinit();
        if (m.kind.response.err) |e| log.warn("{s} failed: {s} ({s})", .{ method, e.message, e.code });
    }

    // ------------------------------------------------------------------
    // Reader thread

    const Delivery = struct {
        client: *Client,
        msg: ?Incoming,
    };

    fn readLoop(self: *Client) void {
        while (true) {
            const msg = self.ctl.read() catch |err| {
                if (!self.closed) log.warn("control connection ended: {}", .{err});
                break;
            };
            const d = self.gpa.create(Delivery) catch {
                msg.deinit();
                continue;
            };
            d.* = .{ .client = self, .msg = msg };
            mainloop.post(Delivery, d, deliver);
        }
        const d = self.gpa.create(Delivery) catch return;
        d.* = .{ .client = self, .msg = null };
        mainloop.post(Delivery, d, deliver);
    }

    /// Main thread.
    fn deliver(d: *Delivery) void {
        const self = d.client;
        const maybe_msg = d.msg;
        self.gpa.destroy(d);

        const msg = maybe_msg orelse {
            if (!self.closed) self.handler.disconnected(self.handler.ctx);
            return;
        };
        if (self.closed) {
            msg.deinit();
            return;
        }
        switch (msg.kind) {
            .response => |r| {
                const p = self.pending.fetchRemove(r.id) orelse {
                    msg.deinit();
                    return;
                };
                p.value.callback(p.value.ctx, msg);
            },
            .event => self.handler.event(self.handler.ctx, msg),
            .unknown => msg.deinit(),
        }
    }
};
