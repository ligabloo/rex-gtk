//! Mouse, wheel and clipboard handling for a terminal pane.
//!
//! While the program in the terminal has mouse reporting on (and Shift
//! isn't held), mouse and wheel events go to the server, which encodes them
//! for the program. Otherwise selection and scrolling happen locally on the
//! mirror terminal: the server never sends its own selection back (see
//! docs/protocol-notes.md), so a local selection is the only one we can draw.

const std = @import("std");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const core = @import("core");
const tv = @import("terminal_view.zig");
const input = @import("input.zig");

const ghostty_vt = core.ghostty_vt;
const Pane = tv.Pane;
const Terminal = ghostty_vt.Terminal;

const log = std.log.scoped(.mouse);

/// Characters that end a word for double-click selection (Ghostty's default).
const word_boundaries: []const u21 = &.{ ' ', '\t', '\'', '"', '│', '`', '|', ':', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };
/// For finding a URL under a Ctrl+click: only whitespace and brackets end it.
const url_boundaries: []const u21 = &.{ ' ', '\t', '\'', '"', '`', '(', ')', '[', ']', '{', '}', '<', '>' };

const double_click_ns = 400 * std.time.ns_per_ms;
const autoscroll_ms = 15;

/// Per-pane pointer state.
pub const State = struct {
    gesture: ghostty_vt.SelectionGesture = .init,
    /// Buttons held, as reported to the server.
    left: bool = false,
    middle: bool = false,
    right: bool = false,
    /// Selecting locally with the left button.
    selecting: bool = false,
    /// The last pointer position, in widget coordinates.
    x: f64 = 0,
    y: f64 = 0,
    /// The last cell reported for motion, to send one event per cell.
    last_cell: ?[2]u16 = null,
    /// Smooth-scroll pixels not yet turned into lines.
    scroll_rest: f64 = 0,
    autoscroll_id: c_uint = 0,

    pub fn deinit(self: *State, terminal: ?*Terminal) void {
        if (self.autoscroll_id != 0) _ = glib.Source.remove(self.autoscroll_id);
        self.autoscroll_id = 0;
        if (terminal) |t| self.gesture.deinit(t);
    }
};

pub fn setup(pane: *Pane) void {
    const click = gtk.GestureClick.new();
    click.as(gtk.GestureSingle).setButton(0);
    _ = gtk.GestureClick.signals.pressed.connect(click, *Pane, &onPressed, pane, .{});
    _ = gtk.GestureClick.signals.released.connect(click, *Pane, &onReleased, pane, .{});
    pane.addController(click.as(gtk.EventController));

    const motion = gtk.EventControllerMotion.new();
    _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Pane, &onMotion, pane, .{});
    pane.addController(motion.as(gtk.EventController));

    const scroll = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true });
    _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Pane, &onScroll, pane, .{});
    pane.addController(scroll.as(gtk.EventController));
}

// ----------------------------------------------------------------------
// Geometry

const Cell = struct { x: u16, y: u16 };

/// The cell under a point in widget coordinates, clamped to the grid.
fn cellAt(pane: *Pane, t: *const Terminal, x: f64, y: f64) Cell {
    const scale = pane.widget.scale();
    const cell = pane.services.fonts.cellSize();
    const pad: f64 = @floatFromInt(pane.renderer.padding);
    const cw: f64 = @floatFromInt(@max(1, cell.width));
    const ch: f64 = @floatFromInt(@max(1, cell.height));
    const col = @floor((x * scale - pad) / cw);
    const row = @floor((y * scale - pad) / ch);
    const max_x: f64 = @floatFromInt(@max(1, t.cols) - 1);
    const max_y: f64 = @floatFromInt(@max(1, t.rows) - 1);
    return .{
        .x = @intFromFloat(std.math.clamp(col, 0, max_x)),
        .y = @intFromFloat(std.math.clamp(row, 0, max_y)),
    };
}

fn geometry(pane: *Pane, t: *const Terminal) ghostty_vt.SelectionGesture.Drag.Geometry {
    const cell = pane.services.fonts.cellSize();
    return .{
        .columns = t.cols,
        .cell_width = cell.width,
        .padding_left = pane.renderer.padding,
        .screen_height = pane.device_h,
    };
}

fn pinAt(t: *Terminal, cell: Cell) ?ghostty_vt.Pin {
    return t.screens.active.pages.pin(.{ .viewport = .{ .x = cell.x, .y = cell.y } });
}

/// Whether mouse events go to the program instead of selecting text.
fn reporting(t: *const Terminal, state: gdk.ModifierType) bool {
    return t.flags.mouse_event != .none and !state.shift_mask;
}

// ----------------------------------------------------------------------
// Buttons

fn buttonName(button: c_uint) []const u8 {
    return switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        8 => "four",
        9 => "five",
        else => "unknown",
    };
}

fn setHeld(st: *State, button: c_uint, held: bool) void {
    switch (button) {
        1 => st.left = held,
        2 => st.middle = held,
        3 => st.right = held,
        else => {},
    }
}

fn sendMouse(pane: *Pane, action: []const u8, button: c_uint, cell: Cell, state: gdk.ModifierType) void {
    var mods_buf: [64]u8 = undefined;
    const st = &pane.pointer;
    pane.machine.send("block.event", .{
        .session_id = pane.session_id,
        .block_id = pane.block_id,
        .event = .{ .type = "mouse", .payload = .{
            .action = action,
            .button = buttonName(button),
            .x = cell.x,
            .y = cell.y,
            .mods = input.formatMods(&mods_buf, state),
            .buttons = .{ .left = st.left, .middle = st.middle, .right = st.right },
        } },
    });
}

fn onPressed(click: *gtk.GestureClick, _: c_int, x: f64, y: f64, pane: *Pane) callconv(.c) void {
    const widget = pane.widget.as(gtk.Widget);
    _ = widget.grabFocus();
    pane.focusOnServer();

    const mirror = pane.mirror orelse return;
    const t = &mirror.terminal;
    const button = click.as(gtk.GestureSingle).getCurrentButton();
    const state = click.as(gtk.EventController).getCurrentEventState();
    const st = &pane.pointer;
    st.x = x;
    st.y = y;
    const cell = cellAt(pane, t, x, y);

    if (reporting(t, state)) {
        setHeld(st, button, true);
        st.last_cell = .{ cell.x, cell.y };
        sendMouse(pane, "press", button, cell, state);
        return;
    }

    switch (button) {
        1 => {
            if (state.control_mask) {
                if (openUrlAt(pane, t, cell)) return;
            }
            const pin = pinAt(t, cell) orelse return;
            const sel = st.gesture.press(t, .{
                .time = std.Io.Timestamp.now(pane.services.io, .awake),
                .pin = pin,
                .xpos = x * pane.widget.scale(),
                .ypos = y * pane.widget.scale(),
                .max_distance = @floatFromInt(pane.services.fonts.cellSize().width),
                .repeat_interval = double_click_ns,
                .word_boundary_codepoints = word_boundaries,
            }) catch return;
            t.screens.active.select(sel) catch {};
            st.selecting = true;
            pane.selectionChanged();
        },
        2 => pasteFrom(pane, widget.getPrimaryClipboard()),
        3 => if (pane.services.context_menu) |cm| cm.func(cm.ctx, pane, x, y),
        else => {},
    }
}

fn onReleased(click: *gtk.GestureClick, _: c_int, x: f64, y: f64, pane: *Pane) callconv(.c) void {
    const mirror = pane.mirror orelse return;
    const t = &mirror.terminal;
    const button = click.as(gtk.GestureSingle).getCurrentButton();
    const state = click.as(gtk.EventController).getCurrentEventState();
    const st = &pane.pointer;
    const cell = cellAt(pane, t, x, y);

    if (button == 1 and st.selecting) {
        st.selecting = false;
        stopAutoscroll(st);
        st.gesture.release(t, .{ .pin = pinAt(t, cell) });
        // Selecting copies to the primary selection, as on X11, and to the
        // clipboard too if asked.
        copyTo(pane, pane.widget.as(gtk.Widget).getPrimaryClipboard());
        if (pane.services.settings) |s| if (s.getBool("terminal.copy_on_select", false))
            copyTo(pane, pane.widget.as(gtk.Widget).getClipboard());
        return;
    }
    const was_held = switch (button) {
        1 => st.left,
        2 => st.middle,
        3 => st.right,
        else => true,
    };
    if (!was_held) return;
    setHeld(st, button, false);
    sendMouse(pane, "release", button, cell, state);
}

fn onMotion(ctrl: *gtk.EventControllerMotion, x: f64, y: f64, pane: *Pane) callconv(.c) void {
    const mirror = pane.mirror orelse return;
    const t = &mirror.terminal;
    const st = &pane.pointer;
    st.x = x;
    st.y = y;
    const state = ctrl.as(gtk.EventController).getCurrentEventState();
    const cell = cellAt(pane, t, x, y);

    if (st.selecting) {
        drag(pane, t, cell);
        return;
    }
    if (!reporting(t, state)) return;
    // Only button (1002) and any (1003) tracking report motion.
    if (t.flags.mouse_event != .button and t.flags.mouse_event != .any) return;
    const held = st.left or st.middle or st.right;
    if (t.flags.mouse_event == .button and !held) return;
    if (st.last_cell) |lc| if (lc[0] == cell.x and lc[1] == cell.y) return;
    st.last_cell = .{ cell.x, cell.y };
    sendMouse(pane, "motion", 0, cell, state);
}

fn drag(pane: *Pane, t: *Terminal, cell: Cell) void {
    const st = &pane.pointer;
    const scale = pane.widget.scale();
    const pin = pinAt(t, cell) orelse return;
    const sel = st.gesture.drag(t, .{
        .pin = pin,
        .xpos = st.x * scale,
        .ypos = st.y * scale,
        .rectangle = false,
        .word_boundary_codepoints = word_boundaries,
        .geometry = geometry(pane, t),
    });
    if (sel) |s| t.screens.active.select(s) catch {};
    pane.selectionChanged();

    if (st.gesture.left_drag_autoscroll != .none) {
        if (st.autoscroll_id == 0) st.autoscroll_id = glib.timeoutAdd(autoscroll_ms, &onAutoscroll, pane);
    } else stopAutoscroll(st);
}

fn stopAutoscroll(st: *State) void {
    if (st.autoscroll_id != 0) _ = glib.Source.remove(st.autoscroll_id);
    st.autoscroll_id = 0;
}

fn onAutoscroll(data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    const st = &pane.pointer;
    const mirror = pane.mirror orelse {
        st.autoscroll_id = 0;
        return 0;
    };
    const t = &mirror.terminal;
    const scale = pane.widget.scale();
    const cell = cellAt(pane, t, st.x, st.y);
    const sel = st.gesture.autoscrollTick(t, .{
        .viewport = .{ .x = cell.x, .y = cell.y },
        .xpos = st.x * scale,
        .ypos = st.y * scale,
        .rectangle = false,
        .word_boundary_codepoints = word_boundaries,
        .geometry = geometry(pane, t),
    });
    if (sel) |s| t.screens.active.select(s) catch {};
    pane.selectionChanged();
    if (st.gesture.left_drag_autoscroll == .none) {
        st.autoscroll_id = 0;
        return 0;
    }
    return 1;
}

// ----------------------------------------------------------------------
// Wheel

fn onScroll(ctrl: *gtk.EventControllerScroll, dx: f64, dy: f64, pane: *Pane) callconv(.c) c_int {
    const mirror = pane.mirror orelse return 0;
    const t = &mirror.terminal;
    const st = &pane.pointer;
    const state = ctrl.as(gtk.EventController).getCurrentEventState();
    const unit = ctrl.getUnit();

    // In a full-screen program, or one that asked for the mouse, the
    // program scrolls.
    if (reporting(t, state) or t.screens.active_key == .alternate) {
        var mods_buf: [64]u8 = undefined;
        const cell = cellAt(pane, t, st.x, st.y);
        pane.machine.send("block.event", .{
            .session_id = pane.session_id,
            .block_id = pane.block_id,
            .event = .{ .type = "wheel", .payload = .{
                .x = cell.x,
                .y = cell.y,
                .delta_x = dx,
                .delta_y = dy,
                .delta_mode = if (unit == .wheel) "line" else "pixel",
                .mods = input.formatMods(&mods_buf, state),
            } },
        });
        return 1;
    }

    // Otherwise scroll our own view of the scrollback.
    const step: f64 = if (pane.services.settings) |s| s.getNumber("terminal.scroll_lines", 3) else 3;
    const lines: f64 = if (unit == .wheel) dy * step else lines: {
        const cell_h: f64 = @as(f64, @floatFromInt(pane.services.fonts.cellSize().height)) / pane.widget.scale();
        st.scroll_rest += dy;
        const n = @trunc(st.scroll_rest / cell_h);
        st.scroll_rest -= n * cell_h;
        break :lines n;
    };
    if (lines == 0) return 1;
    t.scrollViewport(.{ .delta = @intFromFloat(lines) });
    pane.selectionChanged();
    return 1;
}

/// Return to the bottom of the scrollback, as typing does.
pub fn scrollToBottom(pane: *Pane) void {
    const mirror = pane.mirror orelse return;
    const t = &mirror.terminal;
    if (t.screens.active.pages.viewport == .active) return;
    t.scrollViewport(.bottom);
    pane.selectionChanged();
}

// ----------------------------------------------------------------------
// URLs

/// Open the URL under a Ctrl+click. Returns false if there is none.
fn openUrlAt(pane: *Pane, t: *Terminal, cell: Cell) bool {
    const pin = pinAt(t, cell) orelse return false;
    const sel = t.screens.active.selectWord(pin, url_boundaries) orelse return false;
    const gpa = pane.services.gpa;
    const text = t.screens.active.selectionString(gpa, .{ .sel = sel }) catch return false;
    defer gpa.free(text);
    const url = std.mem.trimEnd(u8, text, ".,;:!?");
    for ([_][]const u8{ "http://", "https://", "file://", "mailto:", "ftp://" }) |scheme| {
        if (std.mem.startsWith(u8, url, scheme)) {
            openUrl(pane, url);
            return true;
        }
    }
    return false;
}

pub fn openUrl(pane: *Pane, url: []const u8) void {
    const gpa = pane.services.gpa;
    const z = gpa.dupeSentinel(u8, url, 0) catch return;
    defer gpa.free(z);
    const launcher = gtk.UriLauncher.new(z);
    defer launcher.as(gobject.Object).unref();
    const root = pane.widget.as(gtk.Widget).getRoot();
    const window: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;
    launcher.launch(window, null, null, null);
}

// ----------------------------------------------------------------------
// Clipboard

/// Put the selection on `clipboard`. Returns false if nothing is selected.
pub fn copyTo(pane: *Pane, clipboard: *gdk.Clipboard) void {
    const mirror = pane.mirror orelse return;
    const screen = mirror.terminal.screens.active;
    const sel = screen.selection orelse return;
    const gpa = pane.services.gpa;
    const text = screen.selectionString(gpa, .{ .sel = sel }) catch return;
    defer gpa.free(text);
    if (text.len == 0) return;
    clipboard.setText(text.ptr);
}

/// Paste `clipboard`'s text into the terminal.
pub fn pasteFrom(pane: *Pane, clipboard: *gdk.Clipboard) void {
    // The pane may be gone when the text arrives; the widget outlives it
    // while we hold a reference, and its `pane` is cleared on destroy.
    const widget = pane.widget;
    _ = widget.as(gobject.Object).ref();
    clipboard.readTextAsync(null, &onPasteText, widget);
}

fn onPasteText(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const widget: *tv.TerminalWidget = @ptrCast(@alignCast(data.?));
    defer widget.as(gobject.Object).unref();
    const clipboard: *gdk.Clipboard = @ptrCast(@alignCast(source.?));
    var err: ?*glib.Error = null;
    const text = clipboard.readTextFinish(result, &err) orelse {
        if (err) |e| e.free();
        return;
    };
    defer glib.free(text);
    const pane = widget.pane orelse return;
    pane.paste(std.mem.span(text));
}
