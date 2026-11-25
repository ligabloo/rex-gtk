//! A small QR Code encoder for the Pair Device dialog.
//!
//! Byte mode, error correction level M, versions 1 to 10 (up to 213
//! bytes), which is plenty for a server address. It follows the standard
//! (ISO/IEC 18004) the way Project Nayuki's reference generator lays it
//! out: function patterns, Reed-Solomon codewords interleaved by block,
//! the zigzag placement, and the mask with the lowest penalty.

const std = @import("std");

pub const max_version = 10;
pub const max_size = 17 + 4 * max_version;

pub const Error = error{TooLong};

pub const QrCode = struct {
    version: u8,
    size: u8,
    mask: u3,
    modules: [max_size * max_size]bool = @splat(false),
    function: [max_size * max_size]bool = @splat(false),

    /// Whether the module at column `x`, row `y` is dark.
    pub fn get(self: *const QrCode, x: usize, y: usize) bool {
        return self.modules[y * max_size + x];
    }

    fn set(self: *QrCode, x: usize, y: usize, dark: bool) void {
        self.modules[y * max_size + x] = dark;
    }

    fn setFunction(self: *QrCode, x: usize, y: usize, dark: bool) void {
        self.modules[y * max_size + x] = dark;
        self.function[y * max_size + x] = true;
    }

    fn isFunction(self: *const QrCode, x: usize, y: usize) bool {
        return self.function[y * max_size + x];
    }
};

// Error correction level M, versions 1 to 10.
const ecc_per_block = [_]u8{ 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 };
const num_blocks = [_]u8{ 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 };
/// The format bits that name level M.
const ecl_format_bits = 0;

/// Encode `text` in the smallest version it fits, with the best mask.
pub fn encode(text: []const u8) Error!QrCode {
    return encodeWithMask(text, null);
}

/// Encode `text`, with `mask` if given, else the best one.
pub fn encodeWithMask(text: []const u8, mask: ?u3) Error!QrCode {
    const version: u8 = for (1..max_version + 1) |v| {
        const ver: u8 = @intCast(v);
        if (dataBitsNeeded(ver, text.len) <= numDataCodewords(ver) * 8) break ver;
    } else return error.TooLong;

    var data: [400]u8 = undefined;
    const n_data = numDataCodewords(version);
    encodeData(version, text, data[0..n_data]);

    var all: [400]u8 = undefined;
    const codewords = addEccAndInterleave(version, data[0..n_data], &all);

    var qr: QrCode = .{ .version = version, .size = 17 + 4 * version, .mask = 0 };
    drawFunctionPatterns(&qr);
    drawCodewords(&qr, codewords);

    const chosen: u3 = mask orelse best: {
        var best: u3 = 0;
        var best_penalty: u32 = std.math.maxInt(u32);
        for (0..8) |i| {
            const m: u3 = @intCast(i);
            applyMask(&qr, m);
            drawFormatBits(&qr, m);
            const p = penalty(&qr);
            if (p < best_penalty) {
                best = m;
                best_penalty = p;
            }
            applyMask(&qr, m); // undo
        }
        break :best best;
    };
    applyMask(&qr, chosen);
    drawFormatBits(&qr, chosen);
    qr.mask = chosen;
    return qr;
}

fn charCountBits(version: u8) u5 {
    return if (version < 10) 8 else 16;
}

fn dataBitsNeeded(version: u8, len: usize) usize {
    if (len >= @as(usize, 1) << charCountBits(version)) return std.math.maxInt(usize);
    return 4 + @as(usize, charCountBits(version)) + 8 * len;
}

fn numRawDataModules(version: u8) usize {
    const v: usize = version;
    var result = (16 * v + 128) * v + 64;
    if (v >= 2) {
        const num_align = v / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (v >= 7) result -= 36;
    }
    return result;
}

fn numDataCodewords(version: u8) usize {
    const i = version - 1;
    return numRawDataModules(version) / 8 - @as(usize, ecc_per_block[i]) * num_blocks[i];
}

/// Mode, count, bytes, terminator, then alternating pad bytes.
fn encodeData(version: u8, text: []const u8, out: []u8) void {
    @memset(out, 0);
    var bit: usize = 0;
    const put = struct {
        fn f(buf: []u8, pos: *usize, value: u32, len: u5) void {
            var i: u5 = len;
            while (i > 0) {
                i -= 1;
                if ((value >> i) & 1 != 0) buf[pos.* >> 3] |= @as(u8, 0x80) >> @intCast(pos.* & 7);
                pos.* += 1;
            }
        }
    }.f;
    put(out, &bit, 0b0100, 4);
    put(out, &bit, @intCast(text.len), charCountBits(version));
    for (text) |c| put(out, &bit, c, 8);
    const capacity = out.len * 8;
    bit += @min(4, capacity - bit); // terminator: zeros are already there
    bit = (bit + 7) / 8 * 8;
    var pad: u8 = 0xEC;
    var i = bit / 8;
    while (i < out.len) : (i += 1) {
        out[i] = pad;
        pad ^= 0xEC ^ 0x11;
    }
}

fn gfMultiply(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((@as(u16, y) >> i) & 1) * x;
    }
    return @intCast(z & 0xFF);
}

fn rsDivisor(degree: usize, out: []u8) void {
    @memset(out[0..degree], 0);
    out[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            out[j] = gfMultiply(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = gfMultiply(root, 0x02);
    }
}

fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    const n = divisor.len;
    @memset(out[0..n], 0);
    for (data) |b| {
        const factor = b ^ out[0];
        std.mem.copyForwards(u8, out[0 .. n - 1], out[1..n]);
        out[n - 1] = 0;
        for (0..n) |i| out[i] ^= gfMultiply(divisor[i], factor);
    }
}

fn addEccAndInterleave(version: u8, data: []const u8, out: []u8) []const u8 {
    const blocks: usize = num_blocks[version - 1];
    const ecc_len: usize = ecc_per_block[version - 1];
    const raw = numRawDataModules(version) / 8;
    const short_blocks = blocks - raw % blocks;
    const short_len = raw / blocks;

    var divisor: [32]u8 = undefined;
    rsDivisor(ecc_len, divisor[0..ecc_len]);

    // Each block: its data, a placeholder byte if short, then its ecc.
    var block_buf: [8][160]u8 = undefined;
    var k: usize = 0;
    for (0..blocks) |i| {
        const dat_len = short_len - ecc_len + @intFromBool(i >= short_blocks);
        const b = &block_buf[i];
        @memcpy(b[0..dat_len], data[k..][0..dat_len]);
        k += dat_len;
        var ecc: [32]u8 = undefined;
        rsRemainder(b[0..dat_len], divisor[0..ecc_len], ecc[0..ecc_len]);
        var pos = dat_len;
        if (i < short_blocks) {
            b[pos] = 0;
            pos += 1;
        }
        @memcpy(b[pos..][0..ecc_len], ecc[0..ecc_len]);
    }

    var n: usize = 0;
    for (0..short_len + 1) |i| {
        for (0..blocks) |j| {
            if (i != short_len - ecc_len or j >= short_blocks) {
                out[n] = block_buf[j][i];
                n += 1;
            }
        }
    }
    std.debug.assert(n == raw);
    return out[0..n];
}

fn alignmentPositions(version: u8, out: *[7]usize) []usize {
    if (version == 1) return out[0..0];
    const v: usize = version;
    const size = 17 + 4 * v;
    const num_align = v / 7 + 2;
    const step = (v * 4 + 4 + (num_align * 2 - 2) - 1) / (num_align * 2 - 2) * 2;
    out[0] = 6;
    var i = num_align - 1;
    var pos = size - 7;
    while (i >= 1) : (i -= 1) {
        out[i] = pos;
        pos -= step;
    }
    return out[0..num_align];
}

fn drawFunctionPatterns(qr: *QrCode) void {
    const size: usize = qr.size;
    for (0..size) |i| {
        qr.setFunction(6, i, i % 2 == 0);
        qr.setFunction(i, 6, i % 2 == 0);
    }
    drawFinder(qr, 3, 3);
    drawFinder(qr, size - 4, 3);
    drawFinder(qr, 3, size - 4);

    var buf: [7]usize = undefined;
    const pos = alignmentPositions(qr.version, &buf);
    for (pos, 0..) |x, i| for (pos, 0..) |y, j| {
        const corner = (i == 0 and j == 0) or (i == 0 and j == pos.len - 1) or (i == pos.len - 1 and j == 0);
        if (!corner) drawAlignment(qr, x, y);
    };
    drawFormatBits(qr, 0); // reserved; redrawn with the real mask
    drawVersion(qr);
}

fn drawFinder(qr: *QrCode, cx: usize, cy: usize) void {
    const size: isize = qr.size;
    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const x = @as(isize, @intCast(cx)) + dx;
            const y = @as(isize, @intCast(cy)) + dy;
            if (x < 0 or y < 0 or x >= size or y >= size) continue;
            const dist = @max(@abs(dx), @abs(dy));
            qr.setFunction(@intCast(x), @intCast(y), dist != 2 and dist != 4);
        }
    }
}

fn drawAlignment(qr: *QrCode, cx: usize, cy: usize) void {
    var dy: isize = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: isize = -2;
        while (dx <= 2) : (dx += 1) {
            const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
            const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
            qr.setFunction(x, y, @max(@abs(dx), @abs(dy)) != 1);
        }
    }
}

fn bitOf(x: u32, i: u5) bool {
    return (x >> i) & 1 != 0;
}

fn formatBits(mask: u3) u32 {
    const data: u32 = (ecl_format_bits << 3) | @as(u32, mask);
    var rem = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data << 10) | rem) ^ 0x5412;
}

fn drawFormatBits(qr: *QrCode, mask: u3) void {
    const bits = formatBits(mask);
    const size: usize = qr.size;
    for (0..6) |i| qr.setFunction(8, i, bitOf(bits, @intCast(i)));
    qr.setFunction(8, 7, bitOf(bits, 6));
    qr.setFunction(8, 8, bitOf(bits, 7));
    qr.setFunction(7, 8, bitOf(bits, 8));
    for (9..15) |i| qr.setFunction(14 - i, 8, bitOf(bits, @intCast(i)));
    for (0..8) |i| qr.setFunction(size - 1 - i, 8, bitOf(bits, @intCast(i)));
    for (8..15) |i| qr.setFunction(8, size - 15 + i, bitOf(bits, @intCast(i)));
    qr.setFunction(8, size - 8, true);
}

fn drawVersion(qr: *QrCode) void {
    if (qr.version < 7) return;
    var rem: u32 = qr.version;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    const bits = (@as(u32, qr.version) << 12) | rem;
    const size: usize = qr.size;
    for (0..18) |i| {
        const bit = bitOf(bits, @intCast(i));
        const a = size - 11 + i % 3;
        const b = i / 3;
        qr.setFunction(a, b, bit);
        qr.setFunction(b, a, bit);
    }
}

fn drawCodewords(qr: *QrCode, data: []const u8) void {
    const size: usize = qr.size;
    var i: usize = 0;
    var right: isize = @as(isize, @intCast(size)) - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        const r: usize = @intCast(right);
        for (0..size) |vert| {
            for (0..2) |j| {
                const x = r - j;
                const upward = ((r + 1) & 2) == 0;
                const y = if (upward) size - 1 - vert else vert;
                if (!qr.isFunction(x, y) and i < data.len * 8) {
                    qr.set(x, y, (data[i >> 3] >> @intCast(7 - (i & 7))) & 1 != 0);
                    i += 1;
                }
            }
        }
    }
}

fn applyMask(qr: *QrCode, mask: u3) void {
    const size: usize = qr.size;
    for (0..size) |y| for (0..size) |x| {
        const invert = switch (mask) {
            0 => (x + y) % 2 == 0,
            1 => y % 2 == 0,
            2 => x % 3 == 0,
            3 => (x + y) % 3 == 0,
            4 => (x / 3 + y / 2) % 2 == 0,
            5 => x * y % 2 + x * y % 3 == 0,
            6 => (x * y % 2 + x * y % 3) % 2 == 0,
            7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
        };
        if (invert and !qr.isFunction(x, y)) qr.set(x, y, !qr.get(x, y));
    };
}

// ----------------------------------------------------------------------
// Choosing a mask

const n1 = 3;
const n2 = 3;
const n3 = 40;
const n4 = 10;

const Runs = struct {
    size: usize,
    history: [7]usize = @splat(0),

    fn add(self: *Runs, len_in: usize) void {
        var len = len_in;
        if (self.history[0] == 0) len += self.size; // light border before the first run
        std.mem.copyBackwards(usize, self.history[1..7], self.history[0..6]);
        self.history[0] = len;
    }

    fn countPatterns(self: *const Runs) u32 {
        const h = self.history;
        const n = h[1];
        const core = n > 0 and h[2] == n and h[3] == n * 3 and h[4] == n and h[5] == n;
        return @as(u32, @intFromBool(core and h[0] >= n * 4 and h[6] >= n)) +
            @intFromBool(core and h[6] >= n * 4 and h[0] >= n);
    }

    fn terminateAndCount(self: *Runs, color: bool, len_in: usize) u32 {
        var len = len_in;
        if (color) {
            self.add(len);
            len = 0;
        }
        len += self.size; // light border after the last run
        self.add(len);
        return self.countPatterns();
    }
};

fn penalty(qr: *const QrCode) u32 {
    const size: usize = qr.size;
    var result: u32 = 0;
    for (0..2) |pass| {
        for (0..size) |a| {
            var color = false;
            var run: usize = 0;
            var runs: Runs = .{ .size = size };
            for (0..size) |b| {
                const m = if (pass == 0) qr.get(b, a) else qr.get(a, b);
                if (m == color) {
                    run += 1;
                    if (run == 5) result += n1 else if (run > 5) result += 1;
                } else {
                    runs.add(run);
                    if (!color) result += runs.countPatterns() * n3;
                    color = m;
                    run = 1;
                }
            }
            result += runs.terminateAndCount(color, run) * n3;
        }
    }
    for (0..size - 1) |y| for (0..size - 1) |x| {
        const c = qr.get(x, y);
        if (c == qr.get(x + 1, y) and c == qr.get(x, y + 1) and c == qr.get(x + 1, y + 1)) result += n2;
    };
    var dark: usize = 0;
    for (0..size) |y| for (0..size) |x| {
        dark += @intFromBool(qr.get(x, y));
    };
    const total = size * size;
    const diff = if (dark * 20 > total * 10) dark * 20 - total * 10 else total * 10 - dark * 20;
    const k = (diff + total - 1) / total - 1;
    result += @intCast(k * n4);
    return result;
}

// ----------------------------------------------------------------------

const testing = std.testing;

/// The mask a code was drawn with, read from its first format copy.
fn maskOf(rows: []const []const u8) u3 {
    const dark = struct {
        fn f(r: []const []const u8, x: usize, y: usize) u32 {
            return @intFromBool(r[y][x * 2] == '#');
        }
    }.f;
    var bits: u32 = 0;
    for (0..6) |i| bits |= dark(rows, 8, i) << @intCast(i);
    bits |= dark(rows, 8, 7) << 6;
    bits |= dark(rows, 8, 8) << 7;
    bits |= dark(rows, 7, 8) << 8;
    for (9..15) |i| bits |= dark(rows, 14 - i, 8) << @intCast(i);
    return @intCast(((bits ^ 0x5412) >> 10) & 7);
}

/// Compare against `qrencode -t ASCII -l M -m 0 -8 TEXT`: two characters
/// per module, '#' for dark. The files in testdata/ come from that command
/// with trailing spaces removed.
fn expectMatches(text: []const u8, art: []const u8) !void {
    var rows_buf: [max_size][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, art, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        rows_buf[n] = row;
        n += 1;
    }
    const rows = rows_buf[0..n];
    const qr = try encodeWithMask(text, maskOf(rows));
    try testing.expectEqual(n, qr.size);
    for (rows, 0..) |row, y| {
        for (0..qr.size) |x| {
            const want = x * 2 < row.len and row[x * 2] == '#';
            if (want != qr.get(x, y)) {
                std.debug.print("module ({d},{d}) differs\n", .{ x, y });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "matches qrencode, version 1" {
    try expectMatches("rex", @embedFile("testdata/qr_v1.txt"));
}

test "matches qrencode, version 3" {
    try expectMatches("https://rex.tail1234.ts.net", @embedFile("testdata/qr_v3.txt"));
}

test "matches qrencode, version 7 (version bits, several blocks)" {
    try expectMatches("https://studio-workstation.tail1234.ts.net/a/very/long/path?with=query&and=more-padding-here&and-a-bit-more=yes", @embedFile("testdata/qr_v7.txt"));
}

test "matches qrencode, version 10 (16-bit count, mixed block lengths)" {
    const xs: [200]u8 = @splat('x');
    try expectMatches(&xs, @embedFile("testdata/qr_v10.txt"));
}

test "picks a mask and refuses what doesn't fit" {
    const qr = try encode("https://rex.tail1234.ts.net");
    try testing.expectEqual(3, qr.version);
    const too_long: [214]u8 = @splat('x');
    try testing.expectError(error.TooLong, encode(&too_long));
}
