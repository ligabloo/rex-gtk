//! Splits a terminal data stream into the program's VT bytes and Rex's own
//! messages. Rex places each message as `ESC _ rex1;<nonce>;<json> ESC \`,
//! where <nonce> is the data connection's channel nonce in decimal. A
//! sequence with a different nonce was printed by a program and passes
//! through unchanged as VT bytes.
//!
//! Chunk boundaries are arbitrary: a message may be split anywhere, including
//! inside the introducer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const introducer = "\x1b_rex1;";

/// A message longer than this can't be one of ours; it passes through.
const max_message_len = 1024 * 1024;

pub const Filter = struct {
    /// "<nonce>;" in decimal, matched right after the introducer.
    nonce_prefix_buf: [24]u8 = undefined,
    nonce_prefix_len: usize = 0,

    state: State = .ground,
    /// Bytes held back while deciding whether they start a message: a partial
    /// introducer, or a whole message body.
    held: std.ArrayList(u8) = .empty,

    const State = enum {
        ground,
        /// `held` is a proper prefix of `introducer`.
        introducer,
        /// `held` is the introducer plus body bytes; looking for ESC \.
        body,
        /// As body, and the last held byte was ESC.
        body_esc,
    };

    pub fn init(nonce: u64) Filter {
        var self: Filter = .{};
        const s = std.fmt.bufPrint(&self.nonce_prefix_buf, "{};", .{nonce}) catch unreachable;
        self.nonce_prefix_len = s.len;
        return self;
    }

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        self.held.deinit(gpa);
    }

    fn noncePrefix(self: *const Filter) []const u8 {
        return self.nonce_prefix_buf[0..self.nonce_prefix_len];
    }

    /// Feed one chunk. `handler` must provide `vt(self, []const u8) !void` and
    /// `message(self, []const u8) !void`; the message slice is the JSON text.
    /// Slices are only valid during the call.
    pub fn feed(self: *Filter, gpa: Allocator, input: []const u8, handler: anytype) !void {
        var i: usize = 0;
        while (i < input.len) {
            switch (self.state) {
                .ground => {
                    const esc = std.mem.indexOfScalarPos(u8, input, i, 0x1b) orelse input.len;
                    if (esc > i) try handler.vt(input[i..esc]);
                    i = esc;
                    if (i < input.len) {
                        self.held.clearRetainingCapacity();
                        try self.held.append(gpa, 0x1b);
                        self.state = .introducer;
                        i += 1;
                    }
                },
                .introducer => {
                    const c = input[i];
                    if (c == introducer[self.held.items.len]) {
                        try self.held.append(gpa, c);
                        i += 1;
                        if (self.held.items.len == introducer.len) self.state = .body;
                    } else {
                        // Not ours. Release what we held and reprocess `c`
                        // in ground state (it may itself be ESC).
                        try handler.vt(self.held.items);
                        self.held.clearRetainingCapacity();
                        self.state = .ground;
                    }
                },
                .body, .body_esc => {
                    // Copy up to the next ESC in one go.
                    const start = i;
                    while (i < input.len) : (i += 1) {
                        const c = input[i];
                        if (self.state == .body_esc and c == '\\') {
                            i += 1;
                            try self.held.appendSlice(gpa, input[start..i]);
                            try self.finishMessage(handler);
                            break;
                        }
                        self.state = if (c == 0x1b) .body_esc else .body;
                    } else {
                        try self.held.appendSlice(gpa, input[start..i]);
                        if (self.held.items.len > max_message_len) {
                            try handler.vt(self.held.items);
                            self.held.clearRetainingCapacity();
                            self.state = .ground;
                        }
                    }
                },
            }
        }
    }

    fn finishMessage(self: *Filter, handler: anytype) !void {
        defer {
            self.held.clearRetainingCapacity();
            self.state = .ground;
        }
        const whole = self.held.items;
        // Strip the introducer and the ESC \ terminator.
        const body = whole[introducer.len .. whole.len - 2];
        if (std.mem.startsWith(u8, body, self.noncePrefix())) {
            try handler.message(body[self.nonce_prefix_len..]);
        } else {
            try handler.vt(whole);
        }
    }
};

const TestHandler = struct {
    vt_out: std.ArrayList(u8) = .empty,
    messages: std.ArrayList([]u8) = .empty,
    gpa: Allocator,

    fn vt(self: *TestHandler, bytes: []const u8) !void {
        try self.vt_out.appendSlice(self.gpa, bytes);
    }
    fn message(self: *TestHandler, text: []const u8) !void {
        try self.messages.append(self.gpa, try self.gpa.dupe(u8, text));
    }
    fn deinit(self: *TestHandler) void {
        self.vt_out.deinit(self.gpa);
        for (self.messages.items) |m| self.gpa.free(m);
        self.messages.deinit(self.gpa);
    }
};

fn runChunked(input: []const u8, chunk: usize, nonce: u64) !TestHandler {
    const gpa = std.testing.allocator;
    var h: TestHandler = .{ .gpa = gpa };
    errdefer h.deinit();
    var f: Filter = .init(nonce);
    defer f.deinit(gpa);
    var i: usize = 0;
    while (i < input.len) : (i += chunk) {
        try f.feed(gpa, input[i..@min(input.len, i + chunk)], &h);
    }
    return h;
}

test "messages are extracted at every chunk size" {
    const input = "a\x1b[1mb\x1b_rex1;42;{\"type\":\"resize\"}\x1b\\c\x1b_rex1;7;{\"x\":1}\x1b\\d\x1b";
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var h = try runChunked(input, chunk, 42);
        defer h.deinit();
        try std.testing.expectEqualStrings(
            "a\x1b[1mbc\x1b_rex1;7;{\"x\":1}\x1b\\d",
            h.vt_out.items,
        );
        try std.testing.expectEqual(1, h.messages.items.len);
        try std.testing.expectEqualStrings("{\"type\":\"resize\"}", h.messages.items[0]);
    }
}

test "near miss of the introducer passes through, including a second ESC" {
    var h = try runChunked("x\x1b_rex\x1b_rex1;5;{}\x1b\\y\x1b_other\x1b\\", 1, 5);
    defer h.deinit();
    try std.testing.expectEqualStrings("x\x1b_rexy\x1b_other\x1b\\", h.vt_out.items);
    try std.testing.expectEqual(1, h.messages.items.len);
    try std.testing.expectEqualStrings("{}", h.messages.items[0]);
}

test "ESC inside a message body that isn't ST" {
    var h = try runChunked("\x1b_rex1;1;{\"a\":\"\x1b[\"}\x1b\\z", 3, 1);
    defer h.deinit();
    try std.testing.expectEqualStrings("z", h.vt_out.items);
    try std.testing.expectEqualStrings("{\"a\":\"\x1b[\"}", h.messages.items[0]);
}
