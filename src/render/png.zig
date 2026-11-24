//! A minimal PNG writer for RGBA8 images. It stores pixel data
//! uncompressed (deflate "stored" blocks), which keeps it tiny and
//! dependency-free; the files are larger but these are test screenshots.

const std = @import("std");

/// Write `pixels` (RGBA8, `width * 4` bytes per row, top row first) as PNG.
pub fn write(w: *std.Io.Writer, width: u32, height: u32, pixels: []const u8) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    try w.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try chunk(w, "IHDR", &ihdr);

    // The raw image: each row is a filter byte (0, none) plus the pixels.
    const row_len: usize = @as(usize, width) * 4 + 1;
    const raw_len = row_len * height;
    const max_block = 65535;
    const blocks = @max(1, std.math.divCeil(usize, raw_len, max_block) catch unreachable);
    const idat_len = 2 + raw_len + blocks * 5 + 4;
    if (idat_len > std.math.maxInt(u31)) return error.ImageTooLarge;

    var crc: std.hash.Crc32 = .init();
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(idat_len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll("IDAT");
    crc.update("IDAT");

    const zlib_header = [_]u8{ 0x78, 0x01 };
    try w.writeAll(&zlib_header);
    crc.update(&zlib_header);

    var adler: std.hash.Adler32 = .{};
    var written: usize = 0;
    var block_left: usize = 0;
    var row: u32 = 0;
    var col: usize = 0; // position within the current row, filter byte included
    while (written < raw_len) {
        if (block_left == 0) {
            block_left = @min(max_block, raw_len - written);
            const last: u8 = if (written + block_left == raw_len) 1 else 0;
            var hdr: [5]u8 = undefined;
            hdr[0] = last;
            std.mem.writeInt(u16, hdr[1..3], @intCast(block_left), .little);
            std.mem.writeInt(u16, hdr[3..5], ~@as(u16, @intCast(block_left)), .little);
            try w.writeAll(&hdr);
            crc.update(&hdr);
        }
        // Emit as much of the current row as fits in the block.
        if (col == 0) {
            const zero = [_]u8{0};
            try w.writeAll(&zero);
            crc.update(&zero);
            adler.update(&zero);
            col = 1;
            written += 1;
            block_left -= 1;
            continue;
        }
        const row_start = @as(usize, row) * width * 4 + (col - 1);
        const n = @min(block_left, row_len - col);
        const bytes = pixels[row_start..][0..n];
        try w.writeAll(bytes);
        crc.update(bytes);
        adler.update(bytes);
        col += n;
        written += n;
        block_left -= n;
        if (col == row_len) {
            col = 0;
            row += 1;
        }
    }

    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler.adler, .big);
    try w.writeAll(&adler_buf);
    crc.update(&adler_buf);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try w.writeAll(&crc_buf);

    try chunk(w, "IEND", "");
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try w.writeAll(&crc_buf);
}

test "a 2x2 PNG has the right structure" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const px: [16]u8 = @splat(255);
    try write(&out.writer, 2, 2, &px);
    const b = out.written();
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", b[0..8]);
    try std.testing.expectEqualStrings("IHDR", b[12..16]);
    try std.testing.expectEqualStrings("IEND", b[b.len - 8 .. b.len - 4]);
}
