//! Server addresses: the forms `rex -S` accepts, and what to try for each.
//!
//! A Unix socket and an `ssh://` address each lead to one place. A host
//! name leads to up to three, tried in order, because a Rex server may
//! answer over HTTPS on 443 (Tailscale), or on its own port with or
//! without TLS. See docs/protocol-notes.md.

const std = @import("std");

/// The port a Rex server listens on when its address names none.
pub const default_port: u16 = 7297;

pub const Tcp = struct {
    /// A host name or an IP address, without brackets.
    host: []const u8,
    port: u16,
    tls: bool,
};

/// One place to connect to. Slices point into the text that was parsed.
pub const Endpoint = union(enum) {
    /// The path of a Unix socket.
    unix: []const u8,
    tcp: Tcp,
    /// The whole `ssh://` address, as the ssh tunnel helper takes it.
    ssh: []const u8,

    pub fn format(self: Endpoint, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .unix => |path| try w.print("unix://{s}", .{path}),
            .ssh => |url| try w.writeAll(url),
            .tcp => |t| {
                const scheme = if (t.tls) "https" else "http";
                const v6 = std.mem.indexOfScalar(u8, t.host, ':') != null;
                if (v6) {
                    try w.print("{s}://[{s}]:{d}", .{ scheme, t.host, t.port });
                } else {
                    try w.print("{s}://{s}:{d}", .{ scheme, t.host, t.port });
                }
            },
        }
    }
};

/// How an address is reached, for showing next to a machine.
pub const Kind = enum { local, ssh, tailscale, direct };

pub const ParseError = error{ EmptyAddress, BadPort, BadAddress };

/// The endpoints an address leads to, in the order to try them.
pub const Candidates = struct {
    buf: [3]Endpoint = undefined,
    len: usize = 0,

    pub fn slice(self: *const Candidates) []const Endpoint {
        return self.buf[0..self.len];
    }

    fn add(self: *Candidates, e: Endpoint) void {
        self.buf[self.len] = e;
        self.len += 1;
    }

    pub fn kind(self: *const Candidates) Kind {
        return switch (self.buf[0]) {
            .unix => .local,
            .ssh => .ssh,
            .tcp => |t| if (std.ascii.endsWithIgnoreCase(t.host, ".ts.net")) .tailscale else .direct,
        };
    }
};

pub fn parse(text_untrimmed: []const u8) ParseError!Candidates {
    const text = std.mem.trim(u8, text_untrimmed, " \t\r\n");
    if (text.len == 0) return error.EmptyAddress;
    var out: Candidates = .{};

    if (cutPrefix(text, "unix://")) |path| {
        if (path.len == 0) return error.BadAddress;
        out.add(.{ .unix = path });
        return out;
    }
    if (cutPrefix(text, "ssh://")) |rest| {
        if (rest.len == 0) return error.BadAddress;
        out.add(.{ .ssh = text });
        return out;
    }

    const Scheme = struct { prefix: []const u8, tls: bool, port: u16 };
    const schemes = [_]Scheme{
        .{ .prefix = "https://", .tls = true, .port = 443 },
        .{ .prefix = "wss://", .tls = true, .port = 443 },
        .{ .prefix = "http://", .tls = false, .port = 80 },
        .{ .prefix = "ws://", .tls = false, .port = 80 },
    };
    for (schemes) |s| {
        const rest = cutPrefix(text, s.prefix) orelse continue;
        const hp = try splitHostPort(authority(rest));
        out.add(.{ .tcp = .{ .host = hp.host, .port = hp.port orelse s.port, .tls = s.tls } });
        return out;
    }
    if (std.mem.indexOf(u8, text, "://") != null) return error.BadAddress;

    const hp = try splitHostPort(authority(text));
    if (hp.port) |port| {
        out.add(.{ .tcp = .{ .host = hp.host, .port = port, .tls = true } });
        out.add(.{ .tcp = .{ .host = hp.host, .port = port, .tls = false } });
    } else {
        out.add(.{ .tcp = .{ .host = hp.host, .port = 443, .tls = true } });
        out.add(.{ .tcp = .{ .host = hp.host, .port = default_port, .tls = true } });
        out.add(.{ .tcp = .{ .host = hp.host, .port = default_port, .tls = false } });
    }
    return out;
}

fn cutPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (text.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix)) return null;
    return text[prefix.len..];
}

/// The host and port part: drops a path and any `user@`.
fn authority(text: []const u8) []const u8 {
    var a = text;
    if (std.mem.indexOfAny(u8, a, "/?#")) |i| a = a[0..i];
    if (std.mem.lastIndexOfScalar(u8, a, '@')) |i| a = a[i + 1 ..];
    return a;
}

const HostPort = struct { host: []const u8, port: ?u16 };

fn splitHostPort(a: []const u8) ParseError!HostPort {
    if (a.len == 0) return error.BadAddress;
    if (a[0] == '[') {
        const end = std.mem.indexOfScalar(u8, a, ']') orelse return error.BadAddress;
        const host = a[1..end];
        if (host.len == 0) return error.BadAddress;
        const rest = a[end + 1 ..];
        if (rest.len == 0) return .{ .host = host, .port = null };
        if (rest[0] != ':') return error.BadAddress;
        return .{ .host = host, .port = try parsePort(rest[1..]) };
    }
    const colon = std.mem.indexOfScalar(u8, a, ':') orelse return .{ .host = a, .port = null };
    // More than one colon without brackets is a bare IPv6 address.
    if (std.mem.indexOfScalarPos(u8, a, colon + 1, ':') != null) return .{ .host = a, .port = null };
    if (colon == 0) return error.BadAddress;
    return .{ .host = a[0..colon], .port = try parsePort(a[colon + 1 ..]) };
}

fn parsePort(text: []const u8) ParseError!u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.BadPort;
    if (port == 0) return error.BadPort;
    return port;
}

const testing = std.testing;

fn expectTcp(e: Endpoint, host: []const u8, port: u16, tls: bool) !void {
    try testing.expectEqualStrings(host, e.tcp.host);
    try testing.expectEqual(port, e.tcp.port);
    try testing.expectEqual(tls, e.tcp.tls);
}

test "unix and ssh lead to one endpoint" {
    const u = try parse("unix:///run/user/1000/rex/server.sock");
    try testing.expectEqual(1, u.len);
    try testing.expectEqualStrings("/run/user/1000/rex/server.sock", u.buf[0].unix);
    try testing.expectEqual(Kind.local, u.kind());

    const s = try parse(" ssh://me@studio:2222 ");
    try testing.expectEqual(1, s.len);
    try testing.expectEqualStrings("ssh://me@studio:2222", s.buf[0].ssh);
    try testing.expectEqual(Kind.ssh, s.kind());
}

test "a bare host is probed three ways" {
    const c = try parse("studio.tail1234.ts.net");
    try testing.expectEqual(3, c.len);
    try expectTcp(c.buf[0], "studio.tail1234.ts.net", 443, true);
    try expectTcp(c.buf[1], "studio.tail1234.ts.net", 7297, true);
    try expectTcp(c.buf[2], "studio.tail1234.ts.net", 7297, false);
    try testing.expectEqual(Kind.tailscale, c.kind());
}

test "a host with a port tries TLS then plain" {
    const c = try parse("192.168.1.20:7297");
    try testing.expectEqual(2, c.len);
    try expectTcp(c.buf[0], "192.168.1.20", 7297, true);
    try expectTcp(c.buf[1], "192.168.1.20", 7297, false);
    try testing.expectEqual(Kind.direct, c.kind());
}

test "a scheme fixes the endpoint" {
    const a = try parse("https://rex.tail1234.ts.net");
    try testing.expectEqual(1, a.len);
    try expectTcp(a.buf[0], "rex.tail1234.ts.net", 443, true);

    const b = try parse("http://user@box:8080/api/control");
    try testing.expectEqual(1, b.len);
    try expectTcp(b.buf[0], "box", 8080, false);
}

test "IPv6" {
    const a = try parse("[fd7a::1]:7297");
    try expectTcp(a.buf[0], "fd7a::1", 7297, true);
    const b = try parse("fd7a::1");
    try testing.expectEqual(3, b.len);
    try expectTcp(b.buf[0], "fd7a::1", 443, true);

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{a.buf[1]});
    try testing.expectEqualStrings("http://[fd7a::1]:7297", text);
}

test "bad addresses" {
    try testing.expectError(error.EmptyAddress, parse("  "));
    try testing.expectError(error.BadPort, parse("box:0"));
    try testing.expectError(error.BadPort, parse("box:http"));
    try testing.expectError(error.BadAddress, parse("gopher://box"));
    try testing.expectError(error.BadAddress, parse("unix://"));
}
