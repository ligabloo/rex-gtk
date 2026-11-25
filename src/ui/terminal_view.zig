//! One Rex terminal block as a GTK widget.
//!
//! `Pane` owns everything about the block on the client side: the data
//! stream, the mirror terminal, the renderer and the input state.
//! `TerminalWidget` is the GTK widget that shows the pane's latest frame and
//! receives its input. Frames are drawn offscreen with our own EGL context
//! and handed to GTK as DMA-BUF textures (or CPU copies as a fallback), the
//! way Ghostty's GTK app presents its frames (apprt/gtk/class/render_surface.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const render = @import("render");
const Machine = @import("machine.zig").Machine;
const Stream = @import("stream.zig").Stream;
const StreamEnd = @import("stream.zig").End;
const input = @import("input.zig");
const mouse = @import("mouse.zig");

const ghostty_vt = core.ghostty_vt;
const Mirror = core.mirror.Mirror;
const Renderer = render.renderer.Renderer;
const Dmabuf = render.ghostty.renderer.Dmabuf;

const log = std.log.scoped(.terminal_view);

/// Shared by every pane.
pub const Services = struct {
    gpa: Allocator,
    io: std.Io,
    gpu: *render.renderer.Gpu,
    fonts: *render.fonts.Fonts,
    /// Cleared when GTK can't import a DMA-BUF; later frames use CPU copies.
    dmabuf_ok: bool = true,
    /// Debugging: write every frame to this PNG path.
    dump_frame: ?[]const u8 = null,
    /// Whether the desktop uses a dark style. See `pushTheme`.
    dark: bool = true,
    /// For desktop notifications.
    app: ?*@import("gio").Application = null,
    /// Gets every key press first; returns true if it was a shortcut.
    shortcut: ?struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, pane: *Pane, keyval: u32, keycode: u32, state: gdk.ModifierType, event: *gdk.KeyEvent, repeat: bool) bool,
    } = null,
};

const Theme = struct {
    foreground: []const u8,
    background: []const u8,
    cursor: []const u8,
    scheme: []const u8,
};

/// Libadwaita's view colors, so terminals sit naturally in the window.
const dark_theme: Theme = .{ .foreground = "#ffffff", .background = "#1e1e1e", .cursor = "#ffffff", .scheme = "dark" };
const light_theme: Theme = .{ .foreground = "#1e1e1e", .background = "#ffffff", .cursor = "#1e1e1e", .scheme = "light" };

const blink_interval_ms = 600;

pub const Pane = struct {
    services: *Services,
    /// The server the block lives on.
    machine: *Machine,
    session_id: []u8,
    block_id: []u8,
    widget: *TerminalWidget,
    im: *gtk.IMMulticontext,

    stream: ?*Stream = null,
    mirror: ?*Mirror = null,
    renderer: Renderer,

    /// The widget's size in device pixels, and the grid we last asked for.
    device_w: u32 = 0,
    device_h: u32 = 0,
    requested_cols: u16 = 0,
    requested_rows: u16 = 0,

    /// We own the block, so its size and theme follow this widget.
    owned: bool = false,
    /// The server says this is the focused block of its window.
    server_focused: bool = false,
    /// The title the program set, if any.
    title: ?[]u8 = null,
    /// The working directory the shell reported, if any.
    pwd: ?[]u8 = null,
    /// Keys of a sequence to send with the next key (see `setKeyPrefix`).
    key_prefix: std.ArrayList([]u8) = .empty,
    /// Called when the title changes.
    on_title: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, pane: *Pane) void } = null,

    dirty: bool = false,
    tick_id: c_uint = 0,
    blink_id: c_uint = 0,
    blink_visible: bool = true,
    focused: bool = false,

    // Keyboard state.
    in_key_event: bool = false,
    im_commit: std.ArrayList(u8) = .empty,
    composing: bool = false,
    pressed: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Our event controllers on the widget, removed in `destroy`: GTK may
    /// keep the widget alive (and send it events) after the pane is gone.
    controllers: std.ArrayList(*gtk.EventController) = .empty,
    /// Mouse, selection and scrolling state; see mouse.zig.
    pointer: mouse.State = .{},

    /// Why the terminal can't be shown, drawn over it.
    failure: ?[:0]const u8 = null,
    /// Reconnecting a lost stream: attempts so far and the pending timer.
    stream_retries: u8 = 0,
    retry_id: c_uint = 0,
    /// Asked to get a new ticket and call `connect` again.
    on_stream_lost: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, pane: *Pane) void } = null,

    /// Called when the program in the block has exited.
    on_exit: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, pane: *Pane) void } = null,

    /// Create the pane and its widget. Nothing shows until `connect`.
    pub fn create(services: *Services, machine: *Machine, session_id: []const u8, block_id: []const u8) !*Pane {
        const gpa = services.gpa;
        const self = try gpa.create(Pane);
        errdefer gpa.destroy(self);

        self.* = .{
            .services = services,
            .machine = machine,
            .session_id = try gpa.dupe(u8, session_id),
            .block_id = try gpa.dupe(u8, block_id),
            .widget = TerminalWidget.new(),
            .im = gtk.IMMulticontext.new(),
            .renderer = try .init(gpa, services.gpu, services.fonts, .{}),
        };
        self.widget.pane = self;
        // The pane holds its own reference: the widget moves between
        // containers as the block moves between windows.
        _ = self.widget.as(gobject.Object).refSink();
        self.setupInput();
        return self;
    }

    /// Open the block's data stream with a ticket from `data.connect` or
    /// `session.bootstrap`.
    pub fn connect(self: *Pane, ticket: []const u8) !void {
        if (self.stream) |s| s.destroy();
        self.stream = null;
        const address = self.machine.dataEndpoint() orelse return error.NotConnected;
        self.stream = try Stream.create(self.services.gpa, self.services.io, address, ticket, .{
            .ctx = self,
            .ready = onStreamReady,
            .bytes = onStreamBytes,
            .ended = onStreamEnded,
        });
    }

    pub fn widgetPtr(self: *Pane) *gtk.Widget {
        return self.widget.as(gtk.Widget);
    }

    pub fn destroy(self: *Pane) void {
        const gpa = self.services.gpa;
        if (self.tick_id != 0) self.widget.as(gtk.Widget).removeTickCallback(self.tick_id);
        if (self.blink_id != 0) _ = glib.Source.remove(self.blink_id);
        if (self.retry_id != 0) _ = glib.Source.remove(self.retry_id);
        if (self.stream) |s| s.destroy();
        self.pointer.deinit(if (self.mirror) |m| &m.terminal else null);
        if (self.mirror) |m| m.destroy();

        gdk.GLContext.clearCurrent();
        self.renderer.deinit();
        self.services.gpu.release();

        self.widget.pane = null;
        self.widget.setTexture(null);
        const w = self.widget.as(gtk.Widget);
        for (self.controllers.items) |c| w.removeController(c);
        self.controllers.deinit(gpa);
        _ = gobject.signalHandlersDisconnectMatched(self.im.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        self.im.as(gtk.IMContext).setClientWidget(null);
        self.im.as(gobject.Object).unref();
        if (w.getParent() != null) w.unparent();
        self.widget.as(gobject.Object).unref();
        self.im_commit.deinit(gpa);
        self.pressed.deinit(gpa);
        if (self.title) |t| gpa.free(t);
        if (self.pwd) |d| gpa.free(d);
        self.clearKeyPrefix();
        self.key_prefix.deinit(gpa);
        gpa.free(self.session_id);
        gpa.free(self.block_id);
        gpa.destroy(self);
    }

    /// The font changed (`services.fonts` is new): rebuild the renderer.
    pub fn fontsChanged(self: *Pane) void {
        const gpu = self.services.gpu;
        gdk.GLContext.clearCurrent();
        gpu.makeCurrent() catch return;
        defer gpu.release();
        const renderer = Renderer.init(self.services.gpa, gpu, self.services.fonts, .{}) catch |err| {
            log.err("rebuilding the renderer failed: {}", .{err});
            return;
        };
        self.renderer.deinit();
        self.renderer = renderer;
        self.renderer.focused = self.focused;
        self.requested_cols = 0;
        self.requested_rows = 0;
        self.requestGridSize();
        self.markDirty();
    }

    /// Whether we own the block. Taking it over sizes the terminal to this
    /// widget and gives it our theme.
    pub fn setOwned(self: *Pane, owned: bool) void {
        if (owned == self.owned) return;
        self.owned = owned;
        if (!owned) return;
        self.requested_cols = 0;
        self.requested_rows = 0;
        self.requestGridSize();
        self.pushTheme();
    }

    pub fn setTitle(self: *Pane, title: []const u8) void {
        const gpa = self.services.gpa;
        if (self.title) |t| {
            if (std.mem.eql(u8, t, title)) return;
            gpa.free(t);
        }
        self.title = gpa.dupe(u8, title) catch null;
        if (self.on_title) |cb| cb.func(cb.ctx, self);
    }

    /// From `pwd_changed`: a file:// URL (OSC 7) or a plain path.
    pub fn setPwd(self: *Pane, reported: []const u8) void {
        const gpa = self.services.gpa;
        var path = reported;
        if (std.mem.startsWith(u8, path, "file://")) {
            const rest = path["file://".len..];
            path = if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest[i..] else return;
        }
        const copy = gpa.dupe(u8, path) catch return;
        // Undo percent-encoding in place.
        var n: usize = 0;
        var i: usize = 0;
        while (i < copy.len) : (n += 1) {
            if (copy[i] == '%' and i + 2 < copy.len) {
                if (std.fmt.parseInt(u8, copy[i + 1 .. i + 3], 16)) |b| {
                    copy[n] = b;
                    i += 3;
                    continue;
                } else |_| {}
            }
            copy[n] = copy[i];
            i += 1;
        }
        if (self.pwd) |old| gpa.free(old);
        self.pwd = gpa.realloc(copy, n) catch copy[0..n];
    }

    /// Send these keys as the `prefix` of the next key: it ends a sequence
    /// bound to a Lua function.
    pub fn setKeyPrefix(self: *Pane, keys: []const []const u8) void {
        self.clearKeyPrefix();
        for (keys) |k| {
            const copy = self.services.gpa.dupe(u8, k) catch return;
            self.key_prefix.append(self.services.gpa, copy) catch self.services.gpa.free(copy);
        }
    }

    fn clearKeyPrefix(self: *Pane) void {
        for (self.key_prefix.items) |k| self.services.gpa.free(k);
        self.key_prefix.clearRetainingCapacity();
    }

    pub fn exitCode(self: *const Pane) ?i64 {
        return if (self.mirror) |m| m.exit_code else null;
    }

    // ------------------------------------------------------------------
    // Stream

    fn onStreamReady(ctx: *anyopaque, decoded: *ghostty_vt.snapshot.Decoded, nonce: u64) void {
        const self: *Pane = @ptrCast(@alignCast(ctx));
        const gpa = self.services.gpa;
        defer {
            decoded.deinit(gpa);
            gpa.destroy(decoded);
        }
        const mirror = Mirror.create(gpa, decoded, nonce) catch |err| {
            log.err("building terminal from snapshot failed: {}", .{err});
            return;
        };
        // A reconnected stream starts over with a new snapshot.
        if (self.mirror) |old| {
            self.pointer.deinit(&old.terminal);
            self.pointer = .{};
            old.destroy();
        }
        self.mirror = mirror;
        self.stream_retries = 0;
        self.failure = null;
        self.renderer.invalidate();
        self.markDirty();
        self.widget.as(gtk.Widget).queueDraw();
    }

    fn onStreamBytes(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Pane = @ptrCast(@alignCast(ctx));
        const mirror = self.mirror orelse return;
        const had_exited = mirror.exit_code != null;
        mirror.feed(bytes) catch |err| log.warn("applying stream bytes failed: {}", .{err});
        self.markDirty();
        if (!had_exited and mirror.exit_code != null) {
            self.widget.as(gtk.Widget).queueDraw();
            if (self.on_exit) |cb| cb.func(cb.ctx, self);
        }
    }

    fn onStreamEnded(ctx: *anyopaque, end: StreamEnd) void {
        const self: *Pane = @ptrCast(@alignCast(ctx));
        log.info("stream for {s} ended (status {?})", .{ self.block_id, end.close_code });
        if (self.stream) |s| s.destroy();
        self.stream = null;

        if (end.snapshot_failed) {
            return self.fail("Can't read this terminal: the Rex server uses a different Ghostty version. Update rex-gtk's Ghostty pin (see README).");
        }
        const code = end.close_code orelse 0;
        // The block closed, or the stream ended normally: nothing to resume.
        if (code == 4000 or code == 1000) return;
        // 1008 without a handshake problem: the block can't stream at all.
        if (code == 1008 and !end.open_failed) return self.fail("This block has no terminal stream.");

        // Dropped, canceled, or "reconnect required": start over with a
        // new ticket, backing off.
        if (self.stream_retries >= 8) return self.fail("Lost this terminal's stream.");
        const delay: c_uint = @min(5000, @as(c_uint, 200) << @intCast(self.stream_retries));
        self.stream_retries += 1;
        if (self.retry_id != 0) _ = glib.Source.remove(self.retry_id);
        self.retry_id = glib.timeoutAdd(delay, &onRetry, self);
    }

    fn onRetry(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Pane = @ptrCast(@alignCast(data.?));
        self.retry_id = 0;
        if (self.on_stream_lost) |cb| cb.func(cb.ctx, self);
        return 0;
    }

    fn fail(self: *Pane, message: [:0]const u8) void {
        self.failure = message;
        self.widget.as(gtk.Widget).queueDraw();
    }

    // ------------------------------------------------------------------
    // Size

    fn onResize(self: *Pane, device_w: u32, device_h: u32) void {
        if (device_w == 0 or device_h == 0) return;
        if (device_w == self.device_w and device_h == self.device_h) return;
        self.device_w = device_w;
        self.device_h = device_h;
        self.requestGridSize();
        self.markDirty();
    }

    fn requestGridSize(self: *Pane) void {
        if (self.device_w == 0 or !self.owned) return;
        const grid = self.renderer.gridForSize(self.device_w, self.device_h);
        if (grid.cols == self.requested_cols and grid.rows == self.requested_rows) return;
        self.requested_cols = grid.cols;
        self.requested_rows = grid.rows;
        const cell = self.services.fonts.cellSize();
        self.machine.send("com.superlogical.terminal.resize", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .args = .{
                .columns = grid.cols,
                .rows = grid.rows,
                .cell_width_px = cell.width,
                .cell_height_px = cell.height,
            },
        });
    }

    // ------------------------------------------------------------------
    // Drawing

    pub fn markDirty(self: *Pane) void {
        self.dirty = true;
        if (self.tick_id != 0) return;
        self.tick_id = self.widget.as(gtk.Widget).addTickCallback(&onTick, self, null);
    }

    fn onTick(_: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Pane = @ptrCast(@alignCast(data.?));
        self.tick_id = 0;
        // Hidden panes draw when they're shown again (see `TerminalWidget.map`).
        if (self.widget.as(gtk.Widget).getMapped() == 0) return 0;
        if (self.dirty) {
            self.dirty = false;
            self.renderFrame();
        }
        return 0; // G_SOURCE_REMOVE: the next change adds it again.
    }

    fn renderFrame(self: *Pane) void {
        const mirror = self.mirror orelse return;
        if (self.device_w == 0 or self.device_h == 0) return;
        const gpu = self.services.gpu;

        // GTK tracks which GL context it thinks is current. Clear its
        // record before binding ours, so its next draw binds its own again.
        gdk.GLContext.clearCurrent();
        gpu.makeCurrent() catch |err| {
            log.err("making the GL context current failed: {}", .{err});
            return;
        };
        defer gpu.release();

        self.renderer.update(&mirror.terminal, self.blink_visible) catch |err| {
            log.warn("updating cells failed: {}", .{err});
            return;
        };
        const target = self.renderer.draw(self.device_w, self.device_h) catch |err| {
            log.warn("drawing failed: {}", .{err});
            return;
        };

        if (self.services.dump_frame) |path| self.dumpFrame(target, path);

        const texture = (if (self.services.dmabuf_ok) self.dmabufTexture(target) else null) orelse
            memoryTexture(target) orelse return;
        self.widget.setTexture(texture);
        self.widget.as(gtk.Widget).queueDraw();
    }

    /// Debugging aid (--dump-frame): write the frame just drawn as a PNG.
    fn dumpFrame(self: *Pane, target: *render.ghostty.renderer.opengl.Target, path: []const u8) void {
        const gpa = self.services.gpa;
        const io = self.services.io;
        const pixels = target.readPixelsAlloc(gpa) catch return;
        defer gpa.free(pixels);
        const stride = target.width * 4;
        var y: usize = 0;
        while (y < target.height / 2) : (y += 1) {
            const a = pixels[y * stride ..][0..stride];
            const b = pixels[(target.height - 1 - y) * stride ..][0..stride];
            for (a, b) |*pa, *pb| std.mem.swap(u8, pa, pb);
        }
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(io, &buf);
        render.png.write(&w.interface, @intCast(target.width), @intCast(target.height), pixels) catch return;
        w.interface.flush() catch {};
    }

    fn dmabufTexture(self: *Pane, target: *render.ghostty.renderer.opengl.Target) ?*gdk.Texture {
        const gpu = self.services.gpu;
        const frame = target.exportDmabuf(gpu.device.display, gpu.context) catch |err| {
            log.warn("DMA-BUF export failed ({}); using CPU copies", .{err});
            self.services.dmabuf_ok = false;
            return null;
        };

        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.as(gobject.Object).unref();
        builder.setDisplay(self.widget.as(gtk.Widget).getDisplay());
        builder.setWidth(frame.width);
        builder.setHeight(frame.height);
        builder.setFourcc(frame.fourcc);
        builder.setModifier(frame.modifier);
        builder.setPremultiplied(@intFromBool(frame.premultiplied));
        builder.setNPlanes(frame.planes.count);
        for (0..frame.planes.count) |i| {
            builder.setFd(@intCast(i), frame.planes.fds[i]);
            builder.setOffset(@intCast(i), @intCast(frame.planes.offsets[i]));
            builder.setStride(@intCast(i), @intCast(frame.planes.strides[i]));
        }

        // GDK owns the file descriptors from here; it calls planesDestroy
        // when the texture is released.
        const planes = std.heap.c_allocator.create(Dmabuf.Planes) catch {
            frame.deinit();
            return null;
        };
        planes.* = frame.planes;
        var err_: ?*glib.Error = null;
        return builder.build(&planesDestroy, planes, &err_) orelse {
            if (err_) |e| log.warn("GTK can't import the DMA-BUF ({s}); using CPU copies", .{e.f_message orelse "?"});
            planes.deinit();
            std.heap.c_allocator.destroy(planes);
            self.services.dmabuf_ok = false;
            return null;
        };
    }

    fn planesDestroy(data: ?*anyopaque) callconv(.c) void {
        const planes: *Dmabuf.Planes = @ptrCast(@alignCast(data orelse return));
        planes.deinit();
        std.heap.c_allocator.destroy(planes);
    }

    fn memoryTexture(target: *render.ghostty.renderer.opengl.Target) ?*gdk.Texture {
        const alloc = std.heap.c_allocator;
        const pixels = target.readPixelsAlloc(alloc) catch |err| {
            log.warn("reading back the frame failed: {}", .{err});
            return null;
        };
        const bytes = glib.Bytes.newWithFreeFunc(pixels.ptr, pixels.len, &freePixels, pixels.ptr);
        defer bytes.unref();
        const texture = gdk.MemoryTexture.new(
            @intCast(target.width),
            @intCast(target.height),
            .r8g8b8a8_premultiplied,
            bytes,
            target.width * 4,
        );
        return texture.as(gdk.Texture);
    }

    fn freePixels(data: ?*anyopaque) callconv(.c) void {
        // c_allocator is malloc; free takes the pointer alone.
        std.c.free(data);
    }

    // ------------------------------------------------------------------
    // Input

    fn setupInput(self: *Pane) void {
        const widget = self.widget.as(gtk.Widget);
        widget.setFocusable(1);
        widget.setFocusOnClick(1);

        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Pane, &onKeyPressed, self, .{});
        _ = gtk.EventControllerKey.signals.key_released.connect(keys, *Pane, &onKeyReleased, self, .{});
        self.addController(keys.as(gtk.EventController));

        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *Pane, &onFocusEnter, self, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(focus, *Pane, &onFocusLeave, self, .{});
        self.addController(focus.as(gtk.EventController));

        mouse.setup(self);

        const im = self.im.as(gtk.IMContext);
        im.setClientWidget(widget);
        _ = gtk.IMContext.signals.commit.connect(im, *Pane, &onImCommit, self, .{});
        _ = gtk.IMContext.signals.preedit_start.connect(im, *Pane, &onPreeditStart, self, .{});
        _ = gtk.IMContext.signals.preedit_end.connect(im, *Pane, &onPreeditEnd, self, .{});
    }

    pub fn addController(self: *Pane, c: *gtk.EventController) void {
        self.widget.as(gtk.Widget).addController(c);
        self.controllers.append(self.services.gpa, c) catch {};
    }

    /// A click on this pane: make it the focused block on the server.
    pub fn focusOnServer(self: *Pane) void {
        if (!self.server_focused) self.machine.send("session.focus_block", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
        });
    }

    /// The selection or viewport changed locally: redraw.
    pub fn selectionChanged(self: *Pane) void {
        self.renderer.invalidate();
        self.markDirty();
    }

    /// Send text as a paste. The server adds bracketed-paste markers if
    /// the program asked for them.
    pub fn paste(self: *Pane, text: []const u8) void {
        if (text.len == 0) return;
        mouse.scrollToBottom(self);
        self.machine.send("block.event", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .event = .{ .type = "paste", .payload = .{ .text = text } },
        });
    }



    fn onKeyPressed(ctrl: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, self: *Pane) callconv(.c) c_int {
        return @intFromBool(self.keyEvent(ctrl, true, keyval, keycode, state));
    }

    fn onKeyReleased(ctrl: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, self: *Pane) callconv(.c) void {
        _ = self.keyEvent(ctrl, false, keyval, keycode, state);
    }

    fn keyEvent(self: *Pane, ctrl: *gtk.EventControllerKey, press: bool, keyval: u32, keycode: u32, state: gdk.ModifierType) bool {
        const gpa = self.services.gpa;
        const event = ctrl.as(gtk.EventController).getCurrentEvent() orelse return false;
        const key_event = gobject.ext.cast(gdk.KeyEvent, event) orelse return false;
        if (press) if (self.services.shortcut) |sc| {
            if (sc.func(sc.ctx, self, keyval, keycode, state, key_event, self.pressed.contains(keycode))) return true;
        };

        // Give the input method the first look. It may commit text (sent
        // with this key), start a composition, or eat the key.
        self.in_key_event = true;
        self.im_commit.clearRetainingCapacity();
        const im_handled = self.im.as(gtk.IMContext).filterKeypress(event) != 0;
        self.in_key_event = false;
        if (press and (self.composing or (im_handled and self.im_commit.items.len == 0))) return true;

        const action: []const u8 = if (!press) action: {
            // Releases of keys we never sent (shortcuts) stay here.
            if (!self.pressed.remove(keycode)) return false;
            break :action "release";
        } else if (self.pressed.contains(keycode)) "repeat" else action: {
            self.pressed.put(gpa, keycode, {}) catch {};
            break :action "press";
        };

        const consumed = key_event.getConsumedModifiers();
        var mods_buf: [64]u8 = undefined;
        var consumed_buf: [64]u8 = undefined;
        const mods = input.formatMods(&mods_buf, state);
        const consumed_mods = input.formatMods(&consumed_buf, consumed);

        // Text: what the input method committed, else what the key types.
        // Ctrl/Alt/Super combinations type no text; the server encodes them
        // from the key and modifiers.
        var text_buf: [4]u8 = undefined;
        const unconsumed_command =
            (state.control_mask and !consumed.control_mask) or
            (state.alt_mask and !consumed.alt_mask) or
            (state.super_mask and !consumed.super_mask);
        const text: []const u8 = if (!press)
            ""
        else if (self.im_commit.items.len > 0)
            self.im_commit.items
        else if (unconsumed_command)
            ""
        else
            input.keyvalText(&text_buf, keyval);

        const display = self.widget.as(gtk.Widget).getDisplay();
        self.machine.send("client.key", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .key = input.KeyEvent{
                .key = input.keyName(keycode),
                .mods = mods,
                .consumed_mods = consumed_mods,
                .text = text,
                .unshifted_codepoint = input.unshiftedCodepoint(display, keycode, key_event.getLayout()),
                .composing = false,
                .action = action,
            },
            .prefix = if (press and self.key_prefix.items.len > 0) self.key_prefix.items else null,
        });
        if (press) self.clearKeyPrefix();

        // Typing shows the cursor right away, and returns to the bottom.
        self.restartBlink();
        if (press) mouse.scrollToBottom(self);
        return true;
    }

    fn onImCommit(_: *gtk.IMContext, text: [*:0]u8, self: *Pane) callconv(.c) void {
        const s = std.mem.span(text);
        if (self.in_key_event) {
            self.im_commit.appendSlice(self.services.gpa, s) catch {};
            return;
        }
        // A composition finished outside a key press: type the text.
        self.machine.send("com.superlogical.terminal.write", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .args = .{ .data = s },
        });
    }

    fn onPreeditStart(_: *gtk.IMContext, self: *Pane) callconv(.c) void {
        self.composing = true;
    }

    fn onPreeditEnd(_: *gtk.IMContext, self: *Pane) callconv(.c) void {
        self.composing = false;
    }

    fn onFocusEnter(_: *gtk.EventControllerFocus, self: *Pane) callconv(.c) void {
        self.focused = true;
        self.im.as(gtk.IMContext).focusIn();
        self.renderer.focused = true;
        self.renderer.invalidate();
        self.restartBlink();
        self.sendFocus("in");
        self.markDirty();
    }

    /// Set the terminal's default colors to match the desktop's light or
    /// dark style. Applies while we own the block.
    pub fn pushTheme(self: *Pane) void {
        if (!self.owned) return;
        const theme = if (self.services.dark) dark_theme else light_theme;
        self.machine.send("com.superlogical.terminal.set_theme", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .args = theme,
        });
    }

    fn onFocusLeave(_: *gtk.EventControllerFocus, self: *Pane) callconv(.c) void {
        self.focused = false;
        self.im.as(gtk.IMContext).focusOut();
        self.pressed.clearRetainingCapacity();
        self.renderer.focused = false;
        self.renderer.invalidate();
        if (self.blink_id != 0) _ = glib.Source.remove(self.blink_id);
        self.blink_id = 0;
        self.blink_visible = true;
        self.sendFocus("out");
        self.markDirty();
    }

    fn sendFocus(self: *Pane, action: []const u8) void {
        self.machine.send("block.event", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .event = .{ .type = "focus", .payload = .{ .action = action } },
        });
    }

    fn restartBlink(self: *Pane) void {
        if (!self.focused) return;
        if (self.blink_id != 0) _ = glib.Source.remove(self.blink_id);
        const was_visible = self.blink_visible;
        self.blink_visible = true;
        self.blink_id = glib.timeoutAdd(blink_interval_ms, &onBlink, self);
        if (!was_visible) {
            self.renderer.invalidate();
            self.markDirty();
        }
    }

    fn onBlink(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Pane = @ptrCast(@alignCast(data.?));
        self.blink_visible = !self.blink_visible;
        const blinking = if (self.mirror) |m| m.terminal.modes.get(.cursor_blinking) else false;
        if (blinking) {
            self.renderer.invalidate();
            self.markDirty();
        }
        return 1; // keep going
    }
};

/// The GTK widget: draws the pane's latest frame and receives its input.
pub const TerminalWidget = extern struct {
    parent_instance: Parent,
    pane: ?*Pane,
    texture: ?*gdk.Texture,

    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(TerminalWidget, .{
        .name = "RexTerminal",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *TerminalWidget {
        return gobject.ext.newInstance(TerminalWidget, .{});
    }

    pub fn as(self: *TerminalWidget, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn setTexture(self: *TerminalWidget, texture: ?*gdk.Texture) void {
        if (self.texture) |old| old.as(gobject.Object).unref();
        self.texture = texture;
    }

    /// The widget's scale: device pixels per CSS pixel.
    pub fn scale(self: *TerminalWidget) f64 {
        const widget = self.as(gtk.Widget);
        if (widget.getNative()) |native| if (native.getSurface()) |surface| {
            const s = surface.getScale();
            if (s > 0) return s;
        };
        return @floatFromInt(@max(1, widget.getScaleFactor()));
    }

    fn sizeAllocate(self: *TerminalWidget, width: c_int, height: c_int, baseline: c_int) callconv(.c) void {
        gtk.Widget.virtual_methods.size_allocate.call(Class.parent, self.as(gtk.Widget), width, height, baseline);
        const pane = self.pane orelse return;
        const s = self.scale();
        pane.onResize(
            @intFromFloat(@round(@as(f64, @floatFromInt(width)) * s)),
            @intFromFloat(@round(@as(f64, @floatFromInt(height)) * s)),
        );
    }

    fn snapshot(self: *TerminalWidget, snap: *gtk.Snapshot) callconv(.c) void {
        self.snapshotTexture(snap);
        self.snapshotOverlay(snap);
    }

    fn snapshotTexture(self: *TerminalWidget, snap: *gtk.Snapshot) void {
        const texture = self.texture orelse return;
        const s: f32 = @floatCast(self.scale());
        const w: f32 = @as(f32, @floatFromInt(texture.getWidth())) / s;
        const h: f32 = @as(f32, @floatFromInt(texture.getHeight())) / s;

        // OpenGL's origin is bottom-left; GTK's is top-left.
        snap.save();
        defer snap.restore();
        snap.translate(&.{ .f_x = 0, .f_y = h });
        snap.scale(1, -1);
        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{ .f_width = w, .f_height = h },
        });
    }

    /// The pane's own drawing on top of the terminal: a note once the
    /// program has exited.
    fn snapshotOverlay(self: *TerminalWidget, snap: *gtk.Snapshot) void {
        const pane = self.pane orelse return;
        const widget = self.as(gtk.Widget);
        if (pane.failure) |message| return self.drawNote(snap, message, pane.mirror == null);
        const code = pane.exitCode() orelse return;
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "Process exited with status {d}", .{code}, 0) catch return;
        _ = widget;
        self.drawNote(snap, text, false);
    }

    /// Shade the terminal and write a line of text over it, centred, or
    /// near the bottom if the terminal is still worth seeing.
    fn drawNote(self: *TerminalWidget, snap: *gtk.Snapshot, text: [:0]const u8, center: bool) void {
        const pane = self.pane orelse return;
        const widget = self.as(gtk.Widget);
        const W: f32 = @floatFromInt(widget.getWidth());
        const H: f32 = @floatFromInt(widget.getHeight());
        var rect: @import("graphene").Rect = undefined;
        _ = rect.init(0, 0, W, H);
        const dark = pane.services.dark;
        const shade: gdk.RGBA = if (dark)
            .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = 0.45 }
        else
            .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 0.55 };
        snap.appendColor(&shade, &rect);

        const layout = widget.createPangoLayout(text);
        layout.setWidth(@intFromFloat(@max(1, W - 32) * 1024));
        layout.setWrap(.word_char);
        layout.setAlignment(.center);
        defer layout.as(gobject.Object).unref();
        var lw: c_int = 0;
        var lh: c_int = 0;
        layout.getPixelSize(&lw, &lh);
        var fg: gdk.RGBA = undefined;
        widget.getColor(&fg);
        snap.save();
        defer snap.restore();
        const y: f32 = if (center) (H - @as(f32, @floatFromInt(lh))) / 2 else H - @as(f32, @floatFromInt(lh)) - 16;
        snap.translate(&.{ .f_x = 16, .f_y = y });
        snap.appendLayout(layout, &fg);
    }

    fn map(self: *TerminalWidget) callconv(.c) void {
        gtk.Widget.virtual_methods.map.call(Class.parent, self.as(gtk.Widget));
        if (self.pane) |pane| pane.markDirty();
    }

    fn dispose(self: *TerminalWidget) callconv(.c) void {
        self.setTexture(null);
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = TerminalWidget;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gtk.Widget.virtual_methods.map.implement(class, &map);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
