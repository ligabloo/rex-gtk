//! Draws one terminal with OpenGL, using Ghostty's font stack, cell buffers
//! and shaders. A trimmed port of Ghostty's src/renderer/generic.zig at the
//! pinned commit; functions keep Ghostty's names so the two can be compared
//! when the pin moves.
//!
//! Left out for v1: kitty images, background images, custom shaders, the
//! debug overlay, search highlights, OSC 8 link underlines, preedit, padding
//! color extension and minimum contrast.
//!
//! Every terminal draws into its own offscreen Target. The app turns that
//! target into a GdkTexture; rexshot reads it back into a PNG.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gh = @import("ghostty-render");
const vt = @import("ghostty-vt");
const font = gh.font;
const gl = gh.gl;
const egl = gl.egl;
const rp = gh.renderer;
const ogl = rp.opengl;
const shaders = ogl.shaders;
const cellpkg = rp.cell;
const Fonts = @import("fonts.zig").Fonts;

const log = std.log.scoped(.renderer);

/// Ghostty's renderer requires OpenGL 4.3 core.
pub const min_gl_major = 4;
pub const min_gl_minor = 3;

/// The process's GPU context: one surfaceless EGL context and the compiled
/// shaders, shared by every terminal. GTK main thread only.
pub const Gpu = struct {
    gpa: Allocator,
    device: *ogl.Device,
    context: *egl.Context,
    shaders: shaders.Shaders,

    pub fn create(gpa: Allocator) !*Gpu {
        const self = try gpa.create(Gpu);
        errdefer gpa.destroy(self);

        const device = try ogl.Device.init(gpa, .{});
        errdefer device.deinit(gpa);

        // Ask for desktop OpenGL explicitly, or EGL may give us GLES.
        try egl.bindApi(egl.c.EGL_OPENGL_API);
        const context = try egl.Context.create(device.display, device.config, null, &.{
            egl.c.EGL_CONTEXT_MAJOR_VERSION,       min_gl_major,
            egl.c.EGL_CONTEXT_MINOR_VERSION,       min_gl_minor,
            egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        });
        errdefer context.destroy(device.display) catch {};
        try device.display.makeCurrent(null, null, context);

        const version = try gl.glad.load(&egl.getProcAddress);

        const major = gl.glad.versionMajor(@intCast(version));
        const minor = gl.glad.versionMinor(@intCast(version));
        log.info("OpenGL {}.{} ({s})", .{
            major, minor, device.display.queryString(.vendor) orelse "unknown vendor",
        });
        if (major < min_gl_major or (major == min_gl_major and minor < min_gl_minor)) {
            return error.OpenGLOutdated;
        }
        // Ghostty's shaders expect sRGB framebuffers for blending.
        try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);

        self.* = .{
            .gpa = gpa,
            .device = device,
            .context = context,
            .shaders = try .init(gpa, &.{}),
        };
        return self;
    }

    pub fn destroy(self: *Gpu) void {
        self.makeCurrent() catch {};
        self.shaders.deinit(self.gpa);
        // No glad.unload(): it dlcloses a loader handle that loading through
        // EGL never opened. The pointers live as long as the process.
        self.device.display.releaseCurrent();
        self.context.destroy(self.device.display) catch {};
        self.device.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn makeCurrent(self: *Gpu) !void {
        try self.device.display.makeCurrent(null, null, self.context);
    }

    /// Unbind our context from this thread, so a toolkit sharing the thread
    /// (GTK) finds no context current rather than ours.
    pub fn release(self: *Gpu) void {
        self.device.display.releaseCurrent();
    }
};

/// How many targets a renderer rotates through. A finished frame may still
/// be on screen (as a DMA-BUF) while the next ones draw, as in Ghostty's
/// swap chain.
pub const swap_chain_count = 3;

pub const Options = struct {
    /// Padding around the grid, in device pixels.
    padding: u32 = 4,
};

pub const Renderer = struct {
    gpa: Allocator,
    gpu: *Gpu,
    fonts: *Fonts,
    grid_metrics: font.Metrics,
    padding: u32,

    /// The terminal as last read, and what the shaders need to draw it.
    state: vt.RenderState = .empty,
    cells: cellpkg.Contents = .{},
    uniforms: shaders.Uniforms,
    shaper: font.Shaper,
    shaper_cache: font.ShaperCache,

    /// Set when the cells changed since the last draw.
    cells_rebuilt: bool = true,
    focused: bool = true,

    // GPU resources, created on first draw.
    targets: [swap_chain_count]?ogl.Target = @splat(null),
    target_index: usize = 0,
    uniforms_buf: ?ogl.buffer.Buffer(shaders.Uniforms) = null,
    bg_buf: ?ogl.buffer.Buffer(shaders.CellBg) = null,
    fg_buf: ?ogl.buffer.Buffer(shaders.CellText) = null,
    grayscale: ?ogl.Texture = null,
    color: ?ogl.Texture = null,
    grayscale_modified: usize = 0,
    color_modified: usize = 0,

    pub fn init(gpa: Allocator, gpu: *Gpu, fonts: *Fonts, options: Options) !Renderer {
        var shaper = try font.Shaper.init(gpa, .{});
        errdefer shaper.deinit();
        const metrics = fonts.grid.metrics;
        return .{
            .gpa = gpa,
            .gpu = gpu,
            .fonts = fonts,
            .grid_metrics = metrics,
            .padding = options.padding,
            .shaper = shaper,
            .shaper_cache = .init(),
            .uniforms = .{
                .projection_matrix = undefined,
                .screen_size = undefined,
                .cell_size = .{
                    @floatFromInt(metrics.cell_width),
                    @floatFromInt(metrics.cell_height),
                },
                .grid_size = .{ 0, 0 },
                .grid_padding = undefined,
                .padding_extend = .{},
                .min_contrast = 1,
                .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                .cursor_color = .{ 0, 0, 0, 0 },
                .bg_color = .{ 0, 0, 0, 255 },
                // Ghostty's default on Linux ("linear-corrected"): the
                // shaders work in linear light and the sRGB target encodes
                // the result once. Without it, colors were encoded twice
                // and came out washed out.
                .bools = .{
                    .cursor_wide = false,
                    .use_display_p3 = false,
                    .use_linear_blending = true,
                    .use_linear_correction = true,
                },
            },
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.gpu.makeCurrent() catch {};
        for (&self.targets) |*maybe| if (maybe.*) |*t| t.deinit();
        if (self.uniforms_buf) |b| b.deinit();
        if (self.bg_buf) |b| b.deinit();
        if (self.fg_buf) |b| b.deinit();
        if (self.grayscale) |t| t.deinit();
        if (self.color) |t| t.deinit();
        self.cells.deinit(self.gpa);
        self.state.deinit(self.gpa);
        self.shaper_cache.deinit(self.gpa);
        self.shaper.deinit();
    }

    /// The size in device pixels that fits the terminal's grid exactly,
    /// padding included.
    pub fn sizeForGrid(self: *const Renderer, cols: u32, rows: u32) struct { width: u32, height: u32 } {
        return .{
            .width = cols * self.grid_metrics.cell_width + 2 * self.padding,
            .height = rows * self.grid_metrics.cell_height + 2 * self.padding,
        };
    }

    /// The grid that fits in a surface of the given device-pixel size.
    pub fn gridForSize(self: *const Renderer, width: u32, height: u32) struct { cols: u16, rows: u16 } {
        const inner_w = width -| 2 * self.padding;
        const inner_h = height -| 2 * self.padding;
        return .{
            .cols = @intCast(@max(1, @min(std.math.maxInt(u16), inner_w / self.grid_metrics.cell_width))),
            .rows = @intCast(@max(1, @min(std.math.maxInt(u16), inner_h / self.grid_metrics.cell_height))),
        };
    }

    /// Read the terminal and rebuild what changed. Cheap when nothing did.
    pub fn update(self: *Renderer, t: *vt.Terminal, cursor_blink_visible: bool) !void {
        try self.state.update(self.gpa, t);
        defer self.state.dirty = .false;
        if (self.state.dirty == .false) return;

        try self.rebuildCells(rp.cursorStyle(&self.state, .{
            .focused = self.focused,
            .blink_visible = cursor_blink_visible,
        }));

        const bg = self.state.colors.background;
        self.uniforms.bg_color = .{ bg.r, bg.g, bg.b, 255 };
    }

    /// Mark the whole terminal for redraw, such as after focus changes.
    pub fn invalidate(self: *Renderer) void {
        self.state.dirty = .full;
    }

    fn rebuildCells(self: *Renderer, cursor_style_: ?rp.CursorStyle) Allocator.Error!void {
        const state = &self.state;

        const grid_size_diff =
            self.cells.size.rows != state.rows or
            self.cells.size.columns != state.cols;
        if (grid_size_diff) {
            var new_size = self.cells.size;
            new_size.rows = state.rows;
            new_size.columns = state.cols;
            try self.cells.resize(self.gpa, new_size);
            self.uniforms.grid_size = .{ new_size.columns, new_size.rows };
        }

        const rebuild = state.dirty == .full or grid_size_diff;
        if (rebuild) self.cells.reset();

        const row_data = state.row_data.slice();
        const row_raws = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_dirty = row_data.items(.dirty);
        const row_selection = row_data.items(.selection);
        const row_len: usize = @min(state.rows, self.cells.size.rows);

        for (
            0..,
            row_raws[0..row_len],
            row_cells[0..row_len],
            row_dirty[0..row_len],
            row_selection[0..row_len],
        ) |y_usize, row, *cells, *dirty, selection| {
            const y: vt.size.CellCountInt = @intCast(y_usize);
            if (!rebuild) {
                if (!dirty.*) continue;
                self.cells.clear(y);
            }
            dirty.* = false;
            self.rebuildRow(y, row, cells, selection) catch |err| {
                log.warn("error building row y={} err={}", .{ y, err });
                self.cells.clear(y);
            };
        }

        // Cursor.
        cursor: {
            self.cells.setCursor(null, null);
            self.uniforms.cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) };
            const cursor_vp = state.cursor.viewport orelse break :cursor;
            const style = cursor_style_ orelse break :cursor;
            const cursor_color = state.colors.cursor orelse state.colors.foreground;
            self.addCursor(&state.cursor, style, cursor_color);

            if (style == .block) {
                const wide = state.cursor.cell.wide;
                self.uniforms.cursor_pos = .{
                    switch (wide) {
                        .narrow, .spacer_head, .wide => cursor_vp.x,
                        .spacer_tail => cursor_vp.x -| 1,
                    },
                    @intCast(cursor_vp.y),
                };
                self.uniforms.bools.cursor_wide = switch (wide) {
                    .narrow, .spacer_head => false,
                    .wide, .spacer_tail => true,
                };
                // Text under a block cursor takes the background color.
                const bg = state.colors.background;
                self.uniforms.cursor_color = .{ bg.r, bg.g, bg.b, 255 };
            }
        }

        self.cells_rebuilt = true;
    }

    fn rebuildRow(
        self: *Renderer,
        y: vt.size.CellCountInt,
        row: vt.page.Row,
        cells: *std.MultiArrayList(vt.RenderState.Cell),
        selection: ?[2]vt.size.CellCountInt,
    ) !void {
        _ = row;
        const state = &self.state;
        const cells_slice = cells.slice();
        const cells_len = @min(cells_slice.len, self.cells.size.columns);
        const cells_raw = cells_slice.items(.raw);
        const cells_style = cells_slice.items(.style);

        var run_iter = self.shaper.runIterator(.{
            .grid = &self.fonts.grid,
            .cells = cells_slice,
            .selection = selection,
            .cursor_x = cursor_x: {
                const vp = state.cursor.viewport orelse break :cursor_x null;
                if (vp.y != y) break :cursor_x null;
                break :cursor_x vp.x;
            },
        });
        var shaper_run: ?font.shape.TextRun = try run_iter.next(self.gpa);
        var shaper_cells: ?[]const font.shape.Cell = null;
        var shaper_cells_i: usize = 0;

        for (0.., cells_raw[0..cells_len], cells_style[0..cells_len]) |x, *cell, *managed_style| {
            const wide = cell.wide;
            const style: vt.Style = if (cell.hasStyling()) managed_style.* else .{};

            const selected = selected: {
                const x_compare = if (wide == .spacer_tail) x -| 1 else x;
                const sel = selection orelse break :selected false;
                break :selected x_compare >= sel[0] and x_compare <= sel[1];
            };

            const bg_style = style.bg(cell, &state.colors.palette);
            const fg_style = style.fg(.{
                .default = state.colors.foreground,
                .palette = &state.colors.palette,
            });

            // Selection inverts the default colors, as Ghostty does with no
            // selection colors configured.
            const bg = if (selected)
                state.colors.foreground
            else if (style.flags.inverse != cellpkg.isCovering(cell.codepoint()))
                fg_style
            else
                bg_style;

            const fg = fg: {
                const final_bg = bg_style orelse state.colors.background;
                if (selected) break :fg state.colors.background;
                break :fg if (style.flags.inverse) final_bg else fg_style;
            };

            const alpha: u8 = if (style.flags.faint) 175 else 255;

            {
                const rgb = bg orelse state.colors.background;
                const bg_alpha: u8 = if (selected or style.flags.inverse or bg_style != null) 255 else 0;
                self.cells.bgCell(y, x).* = .{ rgb.r, rgb.g, rgb.b, bg_alpha };
            }

            if (style.flags.invisible) continue;

            if (style.flags.underline != .none) self.addUnderline(
                @intCast(x),
                y,
                style.flags.underline,
                style.underlineColor(&state.colors.palette) orelse fg,
                alpha,
            ) catch |err| log.warn("underline x={} y={}: {}", .{ x, y, err });

            if (style.flags.overline) self.addSprite(.overline, .overline, @intCast(x), y, fg, alpha) catch |err|
                log.warn("overline x={} y={}: {}", .{ x, y, err });

            if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                shaper_run = try run_iter.next(self.gpa);
                shaper_cells = null;
                shaper_cells_i = 0;
            }

            if (shaper_run) |run| glyphs: {
                shaper_cells = shaper_cells orelse self.shaper_cache.get(run) orelse cache: {
                    const new_cells = try self.shaper.shape(run);
                    self.shaper_cache.put(self.gpa, run, new_cells) catch |err|
                        log.warn("error caching shaping results: {}", .{err});
                    break :cache new_cells;
                };
                const shaped = shaper_cells orelse break :glyphs;
                if (shaped.len == 0) break :glyphs;
                std.debug.assert(run.offset + shaped[shaper_cells_i].x >= x);
                while (shaper_cells_i < shaped.len and run.offset + shaped[shaper_cells_i].x == x) : (shaper_cells_i += 1) {
                    self.addGlyph(@intCast(x), y, state.cols, cells_raw, shaped[shaper_cells_i], run, fg, alpha) catch |err|
                        log.warn("glyph x={} y={}: {}", .{ x, y, err });
                }
            }

            if (style.flags.strikethrough) self.addSprite(.strikethrough, .strikethrough, @intCast(x), y, fg, alpha) catch |err|
                log.warn("strikethrough x={} y={}: {}", .{ x, y, err });
        }
    }

    fn addUnderline(
        self: *Renderer,
        x: vt.size.CellCountInt,
        y: vt.size.CellCountInt,
        style: vt.Attribute.Underline,
        color: vt.color.RGB,
        alpha: u8,
    ) !void {
        const sprite: font.Sprite = switch (style) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };
        try self.addSprite(.underline, sprite, x, y, color, alpha);
    }

    /// Ghostty's addOverline and addStrikethrough, which differ only in the
    /// sprite and the layer.
    fn addSprite(
        self: *Renderer,
        comptime key: cellpkg.Key,
        sprite: font.Sprite,
        x: vt.size.CellCountInt,
        y: vt.size.CellCountInt,
        color: vt.color.RGB,
        alpha: u8,
    ) !void {
        const render = try self.fonts.grid.renderGlyph(self.gpa, font.sprite_index, @backingInt(sprite), .{
            .cell_width = 1,
            .grid_metrics = self.grid_metrics,
        });
        try self.cells.add(self.gpa, key, .{
            .atlas = .grayscale,
            .grid_pos = .{ @intCast(x), @intCast(y) },
            .color = .{ color.r, color.g, color.b, alpha },
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .bearings = .{ @intCast(render.glyph.offset_x), @intCast(render.glyph.offset_y) },
        });
    }

    fn addGlyph(
        self: *Renderer,
        x: vt.size.CellCountInt,
        y: vt.size.CellCountInt,
        cols: usize,
        cell_raws: []const vt.page.Cell,
        shaper_cell: font.shape.Cell,
        shaper_run: font.shape.TextRun,
        color: vt.color.RGB,
        alpha: u8,
    ) !void {
        const cell = cell_raws[x];
        const cp = cell.codepoint();
        const render = try self.fonts.grid.renderGlyph(self.gpa, shaper_run.font_index, shaper_cell.glyph_index, .{
            .grid_metrics = self.grid_metrics,
            .cell_width = cell.gridWidth(),
            .constraint = gh.nerd_font_attributes.getConstraint(cp) orelse
                if (cellpkg.isSymbol(cp)) .{ .size = .fit } else .none,
            .constraint_width = cellpkg.constraintWidth(cell_raws, x, cols),
        });
        if (render.glyph.width == 0 or render.glyph.height == 0) return;

        try self.cells.add(self.gpa, .text, .{
            .atlas = switch (render.presentation) {
                .emoji => .color,
                .text => .grayscale,
            },
            .bools = .{ .no_min_contrast = cellpkg.noMinContrast(cp) },
            .grid_pos = .{ @intCast(x), @intCast(y) },
            .color = .{ color.r, color.g, color.b, alpha },
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .bearings = .{
                @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                @intCast(render.glyph.offset_y + shaper_cell.y_offset),
            },
        });
    }

    fn addCursor(
        self: *Renderer,
        cursor_state: *const vt.RenderState.Cursor,
        cursor_style: rp.CursorStyle,
        cursor_color: vt.color.RGB,
    ) void {
        const cursor_vp = cursor_state.viewport orelse return;
        const wide, const x = cell: {
            if (!cursor_vp.wide_tail) break :cell .{ cursor_state.cell.wide == .wide, cursor_vp.x };
            break :cell .{ true, cursor_vp.x - 1 };
        };

        const render = switch (cursor_style) {
            .block, .block_hollow, .bar, .underline => render: {
                const sprite: font.Sprite = switch (cursor_style) {
                    .block => .cursor_rect,
                    .block_hollow => .cursor_hollow_rect,
                    .bar => .cursor_bar,
                    .underline => .cursor_underline,
                    .lock => unreachable,
                };
                break :render self.fonts.grid.renderGlyph(self.gpa, font.sprite_index, @backingInt(sprite), .{
                    .cell_width = if (wide) 2 else 1,
                    .grid_metrics = self.grid_metrics,
                }) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                };
            },
            .lock => (self.fonts.grid.renderCodepoint(self.gpa, 0xF023, .regular, .text, .{
                .cell_width = if (wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            }) catch |err| {
                log.warn("error rendering lock cursor err={}", .{err});
                return;
            }) orelse return,
        };

        self.cells.setCursor(.{
            .atlas = .grayscale,
            .bools = .{ .is_cursor_glyph = true },
            .grid_pos = .{ x, cursor_vp.y },
            .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, 255 },
            .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
            .glyph_size = .{ render.glyph.width, render.glyph.height },
            .bearings = .{ @intCast(render.glyph.offset_x), @intCast(render.glyph.offset_y) },
        }, cursor_style);
    }

    /// Draw into the offscreen target, sized `width` x `height` device
    /// pixels, and return it. The GPU context must be current.
    pub fn draw(self: *Renderer, width: u32, height: u32) !*ogl.Target {
        std.debug.assert(width > 0 and height > 0);

        // (Re)create the target at the right size.
        // Take the next target in the rotation, (re)creating it at this size.
        self.target_index = (self.target_index + 1) % swap_chain_count;
        const slot = &self.targets[self.target_index];
        if (slot.*) |*t| if (t.width != width or t.height != height) {
            t.deinit();
            slot.* = null;
        };
        if (slot.* == null) slot.* = try ogl.Target.init(.{ .width = width, .height = height });
        const target = &slot.*.?;

        // Ghostty sets this from its surface code; RenderPass doesn't.
        try gl.viewport(0, 0, @intCast(width), @intCast(height));
        self.updateScreenSizeUniforms(width, height);

        const opts: ogl.buffer.Options = .{ .target = .array, .usage = .dynamic_draw };
        if (self.uniforms_buf == null) self.uniforms_buf = try .init(opts, 1);
        if (self.bg_buf == null) self.bg_buf = try .init(opts, 1);
        if (self.fg_buf == null) self.fg_buf = try .init(opts, 1);
        try self.uniforms_buf.?.sync(&.{self.uniforms});
        try self.bg_buf.?.sync(self.cells.bg_cells);
        const fg_count = try self.fg_buf.?.syncFromArrayLists(self.cells.fg_rows);
        log.debug("draw {}x{}: {} glyph instances, {} bg cells", .{ width, height, fg_count, self.cells.bg_cells.len });
        self.cells_rebuilt = false;

        try self.syncAtlas(&self.fonts.grid.atlas_grayscale, &self.grayscale, &self.grayscale_modified);
        try self.syncAtlas(&self.fonts.grid.atlas_color, &self.color, &self.color_modified);

        const pipelines = &self.gpu.shaders.pipelines;
        {
            var pass = ogl.RenderPass.begin(.{ .attachments = &.{.{
                .target = .{ .target = target.* },
                .clear_color = .{ 0, 0, 0, 0 },
            }} });
            defer pass.complete();

            pass.step(.{
                .pipeline = pipelines.bg_color,
                .uniforms = self.uniforms_buf.?.buffer,
                .buffers = &.{ null, self.bg_buf.?.buffer },
                .draw = .{ .type = .triangle, .vertex_count = 3 },
            });
            pass.step(.{
                .pipeline = pipelines.cell_bg,
                .uniforms = self.uniforms_buf.?.buffer,
                .buffers = &.{ null, self.bg_buf.?.buffer },
                .draw = .{ .type = .triangle, .vertex_count = 3 },
            });
            pass.step(.{
                .pipeline = pipelines.cell_text,
                .uniforms = self.uniforms_buf.?.buffer,
                .buffers = &.{ self.fg_buf.?.buffer, self.bg_buf.?.buffer },
                .textures = &.{ self.grayscale, self.color },
                .draw = .{
                    .type = .triangle_strip,
                    .vertex_count = 4,
                    .instance_count = fg_count,
                },
            });
        }
        try gl.errors.getError();
        // Submit the work without waiting for it. The DMA-BUF's implicit
        // fence makes GTK wait for the GPU, not this thread. (glFinish here
        // stalled the main thread, and with it input, every frame.)
        gl.flush();
        return target;
    }

    fn updateScreenSizeUniforms(self: *Renderer, width: u32, height: u32) void {
        const cols = self.cells.size.columns;
        const rows = self.cells.size.rows;
        const grid_w = cols * self.grid_metrics.cell_width;
        const grid_h = rows * self.grid_metrics.cell_height;
        const pad: f32 = @floatFromInt(self.padding);
        // Space left over around the grid beyond the padding, given to the
        // right and bottom as Ghostty does.
        const extra_w: f32 = @floatFromInt((width -| 2 * self.padding) -| grid_w);
        const extra_h: f32 = @floatFromInt((height -| 2 * self.padding) -| grid_h);

        self.uniforms.projection_matrix = @bitCast(gh.math.ortho2d(
            -pad,
            @as(f32, @floatFromInt(width)) - pad,
            @as(f32, @floatFromInt(height)) - pad,
            -pad,
        ));
        self.uniforms.grid_padding = .{ pad, pad + extra_w, pad + extra_h, pad };
        self.uniforms.screen_size = .{ @floatFromInt(width), @floatFromInt(height) };
    }

    fn syncAtlas(self: *Renderer, atlas: *const font.Atlas, texture: *?ogl.Texture, last: *usize) !void {
        _ = self;
        const modified = atlas.modified.load(.monotonic);
        if (texture.* != null and modified <= last.*) return;
        last.* = modified;
        if (texture.*) |t| if (atlas.size > t.width) {
            t.deinit();
            texture.* = null;
        };
        if (texture.* == null) {
            const format: gl.Texture.Format, const internal: gl.Texture.InternalFormat = switch (atlas.format) {
                .grayscale => .{ .red, .red },
                .bgra => .{ .bgra, .srgba },
                else => return error.UnsupportedAtlasFormat,
            };
            texture.* = try ogl.Texture.init(.{
                .format = format,
                .internal_format = internal,
                .target = .rectangle,
                .min_filter = .nearest,
                .mag_filter = .nearest,
                .wrap_s = .clamp_to_edge,
                .wrap_t = .clamp_to_edge,
            }, atlas.size, atlas.size, null);
        }
        try texture.*.?.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
    }
};
