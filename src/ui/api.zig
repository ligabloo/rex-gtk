//! Typed views of the Rex API results and events the app reads. Fields the
//! app doesn't use are left out; unknown fields are ignored when parsing.
//! See docs/api/llms.txt for the full shapes.

const std = @import("std");
const core = @import("core");
const Incoming = core.control.Incoming;

const log = std.log.scoped(.api);

pub const SessionList = struct {
    sessions: []const struct {
        session_id: []const u8,
        label: []const u8 = "",
    },
};

pub const TicketRequest = struct {
    creator_name: []const u8 = "com.superlogical.terminal",
    data_ref_id: []const u8 = "terminal",
    subprotocol: []const u8 = core.data.terminal_subprotocol,
};

pub const Ticket = struct {
    session_id: []const u8,
    block_id: []const u8,
    ticket: []const u8,
};

pub const LayoutNode = struct {
    rect: [4]f64,
    block_id: ?[]const u8 = null,
    split: ?struct {
        split_id: ?[]const u8 = null,
        direction: []const u8 = "horizontal",
        ratio: f64 = 0.5,
        before: *const LayoutNode,
        after: *const LayoutNode,
    } = null,
};

pub const Block = struct {
    block_id: []const u8,
    label: ?[]const u8 = null,
    creator_name: ?[]const u8 = null,
    owner: ?[]const u8 = null,
};

pub const Layer = struct {
    layer_id: ?[]const u8 = null,
    kind: []const u8 = "tiled",
    bounds: [4]f64 = .{ 0, 0, 1, 1 },
    state: ?[]const u8 = null,
    layout: ?LayoutNode = null,
    blocks: ?[]const Block = null,
};

pub const Window = struct {
    window_id: []const u8,
    label: ?[]const u8 = null,
    focused_block_id: ?[]const u8 = null,
    zoomed_block_id: ?[]const u8 = null,
    layers: ?[]const Layer = null,
};

pub const View = struct {
    revision: u64,
    session_id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    active_window_id: ?[]const u8 = null,
    windows: ?[]const Window = null,

    pub fn activeWindow(self: View) ?Window {
        const id = self.active_window_id orelse return null;
        for (self.windows orelse &.{}) |w| if (std.mem.eql(u8, w.window_id, id)) return w;
        return null;
    }
};

pub const Attached = struct {
    session: struct { session_id: []const u8, label: []const u8 = "" },
    view: View,
};

pub const Bootstrap = struct {
    client_id: []const u8,
    selected_session: ?Attached = null,
    attached_sessions: ?[]const Attached = null,
    data_tickets: ?[]const Ticket = null,
};

pub const SessionEvent = struct {
    session_id: []const u8,
    event: struct {
        type: []const u8,
        payload: std.json.Value = .null,
    },
};

/// Parse a response's payload. Logs and returns null on an API error or a
/// shape mismatch. The result lives in the message's arena.
pub fn parse(comptime T: type, msg: Incoming) ?T {
    const r = msg.kind.response;
    if (r.err) |e| {
        log.warn("request failed: {s} ({s})", .{ e.message, e.code });
        return null;
    }
    return parseValue(T, msg, r.payload);
}

pub fn parseValue(comptime T: type, msg: Incoming, value: std.json.Value) ?T {
    return std.json.parseFromValueLeaky(T, msg.allocator(), value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("unexpected {s} shape: {}", .{ @typeName(T), err });
        return null;
    };
}
