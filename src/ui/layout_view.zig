//! A container that places a Rex window's blocks where the session view
//! says: each block's rect is a fraction of the window's size. One of these
//! is a tab's content. Floating layers come after the tiled layer and are
//! drawn on top; a zoomed block covers everything.
//!
//! The container doesn't own the block widgets: `SessionView` holds a
//! reference to each, and moves them between containers as blocks move
//! between windows.

const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gsk = @import("gsk");
const gtk = @import("gtk");

const alloc = std.heap.c_allocator;

pub const Kind = enum { tiled, floating, zoomed };

pub const Placement = struct {
    widget: *gtk.Widget,
    /// [x, y, w, h] as fractions of the window.
    rect: [4]f64,
    kind: Kind,
    /// Draw this block dimmed: it isn't the focused one.
    dim: bool = false,

    /// Where it ended up, in widget coordinates. Set by size_allocate.
    px: Px = .{},
};

/// The border between the two sides of a split, which the user can drag.
pub const Divider = struct {
    /// The split's [x, y, w, h], as fractions of the window.
    rect: [4]f64,
    /// True for a split with one side above the other.
    vertical: bool,
    ratio: f64,
    /// A block on each side, to name the split in `session.resize_pane`.
    before: []const u8,
    after: []const u8,
};

pub const ResizeFn = *const fn (ctx: *anyopaque, d: Divider, ratio: f64) void;

/// How close to a divider, in logical pixels, a press grabs it.
const grab_distance = 4;
/// At most one resize request per this many milliseconds while dragging.
const resize_interval_ms = 30;

const Px = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Space between tiled blocks, in logical pixels.
const gap = 1;

pub const LayoutWidget = extern struct {
    parent_instance: Parent,
    state: ?*State,

    const State = struct {
        placements: std.ArrayList(Placement) = .empty,
        dark: bool = true,
        /// Whether unfocused blocks are drawn dimmed at all.
        dim_enabled: bool = true,
        dividers: std.ArrayList(Divider) = .empty,
        on_resize: ?struct { ctx: *anyopaque, func: ResizeFn } = null,
        /// The divider being dragged, and where the drag started.
        dragging: ?usize = null,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        last_sent: i64 = 0,

        fn clearDividers(self: *State) void {
            for (self.dividers.items) |d| {
                alloc.free(d.before);
                alloc.free(d.after);
            }
            self.dividers.clearRetainingCapacity();
            self.dragging = null;
        }
    };

    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(LayoutWidget, .{
        .name = "RexLayout",
        .instanceInit = &instanceInit,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *LayoutWidget {
        return gobject.ext.newInstance(LayoutWidget, .{});
    }

    pub fn as(self: *LayoutWidget, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn instanceInit(self: *LayoutWidget, _: *Class) callconv(.c) void {
        self.state = alloc.create(State) catch null;
        if (self.state) |s| s.* = .{};
        const me = self.as(gtk.Widget);
        me.setOverflow(.hidden);

        // Dragging dividers. Both controllers look at events before the
        // terminals do, and let go of any that aren't near a divider.
        const drag = gtk.GestureDrag.new();
        drag.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *LayoutWidget, &onDragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *LayoutWidget, &onDragUpdate, self, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *LayoutWidget, &onDragEnd, self, .{});
        me.addController(drag.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        motion.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *LayoutWidget, &onMotion, self, .{});
        me.addController(motion.as(gtk.EventController));
    }

    /// Turn dimming of unfocused blocks on or off.
    pub fn setDimEnabled(self: *LayoutWidget, on: bool) void {
        const state = self.state orelse return;
        if (state.dim_enabled == on) return;
        state.dim_enabled = on;
        self.as(gtk.Widget).queueDraw();
    }

    /// Show these blocks, in drawing order (back to front). Widgets that are
    /// children of another container are moved here; children not listed
    /// are removed.
    pub fn setPlacements(self: *LayoutWidget, placements: []const Placement, dark: bool) void {
        const state = self.state orelse return;
        const me = self.as(gtk.Widget);

        // Drop children that are no longer listed.
        var child = me.getFirstChild();
        while (child) |c| {
            child = c.getNextSibling();
            const keep = for (placements) |p| {
                if (p.widget == c) break true;
            } else false;
            if (!keep) c.unparent();
        }

        // Add or move each one to the end, which puts them in order.
        for (placements) |p| {
            const w = p.widget;
            if (w.getParent()) |parent| if (parent != me) w.unparent();
            w.insertBefore(me, null);
            w.setChildVisible(1);
        }

        state.placements.clearRetainingCapacity();
        state.placements.appendSlice(alloc, placements) catch {};
        state.dark = dark;
        me.queueAllocate();
        me.queueDraw();
    }

    /// Remove every child, the dividers and the resize callback.
    pub fn clear(self: *LayoutWidget) void {
        self.setPlacements(&.{}, true);
        if (self.state) |s| {
            s.clearDividers();
            s.on_resize = null;
        }
    }

    pub fn setResizeHandler(self: *LayoutWidget, ctx: *anyopaque, func: ResizeFn) void {
        if (self.state) |s| s.on_resize = .{ .ctx = ctx, .func = func };
    }

    /// Replace the draggable dividers. Copies the block IDs.
    pub fn setDividers(self: *LayoutWidget, dividers: []const Divider) void {
        const state = self.state orelse return;
        const dragging = state.dragging;
        state.clearDividers();
        for (dividers) |d| {
            const before = alloc.dupe(u8, d.before) catch continue;
            const after = alloc.dupe(u8, d.after) catch {
                alloc.free(before);
                continue;
            };
            var copy = d;
            copy.before = before;
            copy.after = after;
            state.dividers.append(alloc, copy) catch {
                alloc.free(before);
                alloc.free(after);
            };
        }
        // A view that arrives mid-drag keeps the same dividers in the same order.
        if (dragging) |i| if (i < state.dividers.items.len) {
            state.dragging = i;
        };
    }

    /// The divider under a point, if any.
    fn dividerAt(self: *LayoutWidget, x: f64, y: f64) ?usize {
        const state = self.state orelse return null;
        const me = self.as(gtk.Widget);
        const W: f64 = @floatFromInt(me.getWidth());
        const H: f64 = @floatFromInt(me.getHeight());
        for (state.dividers.items, 0..) |d, i| {
            const r = d.rect;
            if (d.vertical) {
                const at = (r[1] + r[3] * d.ratio) * H;
                if (@abs(y - at) <= grab_distance and x >= r[0] * W and x <= (r[0] + r[2]) * W) return i;
            } else {
                const at = (r[0] + r[2] * d.ratio) * W;
                if (@abs(x - at) <= grab_distance and y >= r[1] * H and y <= (r[1] + r[3]) * H) return i;
            }
        }
        return null;
    }

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, self: *LayoutWidget) callconv(.c) void {
        const state = self.state orelse return;
        if (state.dragging != null) return;
        const me = self.as(gtk.Widget);
        const cursor: ?[*:0]const u8 = if (self.dividerAt(x, y)) |i|
            (if (state.dividers.items[i].vertical) "row-resize" else "col-resize")
        else
            null;
        me.setCursorFromName(cursor);
    }

    fn onDragBegin(drag: *gtk.GestureDrag, x: f64, y: f64, self: *LayoutWidget) callconv(.c) void {
        const state = self.state orelse return;
        const i = self.dividerAt(x, y) orelse {
            _ = drag.as(gtk.Gesture).setState(.denied);
            return;
        };
        _ = drag.as(gtk.Gesture).setState(.claimed);
        state.dragging = i;
        state.drag_x = x;
        state.drag_y = y;
    }

    fn onDragUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *LayoutWidget) callconv(.c) void {
        self.dragTo(dx, dy, false);
    }

    fn onDragEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, self: *LayoutWidget) callconv(.c) void {
        self.dragTo(dx, dy, true);
        if (self.state) |s| s.dragging = null;
    }

    fn dragTo(self: *LayoutWidget, dx: f64, dy: f64, final: bool) void {
        const state = self.state orelse return;
        const i = state.dragging orelse return;
        if (i >= state.dividers.items.len) return;
        const d = state.dividers.items[i];
        const me = self.as(gtk.Widget);
        const W: f64 = @floatFromInt(me.getWidth());
        const H: f64 = @floatFromInt(me.getHeight());
        const ratio = if (d.vertical)
            ((state.drag_y + dy) / H - d.rect[1]) / d.rect[3]
        else
            ((state.drag_x + dx) / W - d.rect[0]) / d.rect[2];
        const clamped = std.math.clamp(ratio, 0.05, 0.95);
        const now: i64 = @divTrunc(glib.getMonotonicTime(), 1000);
        if (!final and now - state.last_sent < resize_interval_ms) return;
        state.last_sent = now;
        if (state.on_resize) |cb| cb.func(cb.ctx, d, clamped);
    }

    fn sizeAllocate(self: *LayoutWidget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const state = self.state orelse return;
        const W: f64 = @floatFromInt(width);
        const H: f64 = @floatFromInt(height);
        for (state.placements.items) |*p| {
            var x0 = @round(p.rect[0] * W);
            var y0 = @round(p.rect[1] * H);
            var x1 = @round((p.rect[0] + p.rect[2]) * W);
            var y1 = @round((p.rect[1] + p.rect[3]) * H);
            switch (p.kind) {
                .zoomed => {
                    x0 = 0;
                    y0 = 0;
                    x1 = W;
                    y1 = H;
                },
                // Leave a gap on the sides that touch another block.
                .tiled => {
                    if (x0 > 0) x0 += gap;
                    if (y0 > 0) y0 += gap;
                },
                .floating => {},
            }
            const w = @max(0, x1 - x0);
            const h = @max(0, y1 - y0);
            p.px = .{ .x = @floatCast(x0), .y = @floatCast(y0), .w = @floatCast(w), .h = @floatCast(h) };
            var a: gtk.Allocation = .{
                .f_x = @intFromFloat(x0),
                .f_y = @intFromFloat(y0),
                .f_width = @intFromFloat(w),
                .f_height = @intFromFloat(h),
            };
            p.widget.sizeAllocate(&a, -1);
        }
    }

    fn measure(_: *LayoutWidget, _: gtk.Orientation, _: c_int, min: ?*c_int, nat: ?*c_int, min_base: ?*c_int, nat_base: ?*c_int) callconv(.c) void {
        if (min) |m| m.* = 0;
        if (nat) |n| n.* = 0;
        if (min_base) |m| m.* = -1;
        if (nat_base) |n| n.* = -1;
    }

    fn snapshot(self: *LayoutWidget, snap: *gtk.Snapshot) callconv(.c) void {
        const state = self.state orelse return;
        const me = self.as(gtk.Widget);
        const W: f32 = @floatFromInt(me.getWidth());
        const H: f32 = @floatFromInt(me.getHeight());

        // The gaps between blocks show the background.
        var fg: gdk.RGBA = undefined;
        me.getColor(&fg);
        const sep: gdk.RGBA = .{ .f_red = fg.f_red, .f_green = fg.f_green, .f_blue = fg.f_blue, .f_alpha = 0.15 };
        var all: graphene.Rect = undefined;
        _ = all.init(0, 0, W, H);
        snap.appendColor(&sep, &all);

        const shade: gdk.RGBA = if (state.dark)
            .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = 0.3 }
        else
            .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 0.35 };

        for (state.placements.items) |p| {
            if (p.px.w <= 0 or p.px.h <= 0) continue;
            var r: graphene.Rect = undefined;
            _ = r.init(p.px.x, p.px.y, p.px.w, p.px.h);
            me.snapshotChild(p.widget, snap);
            if (p.dim and state.dim_enabled) snap.appendColor(&shade, &r);
            if (p.kind == .floating) {
                var outline: gsk.RoundedRect = undefined;
                var outer: graphene.Rect = undefined;
                _ = outer.init(p.px.x - 1, p.px.y - 1, p.px.w + 2, p.px.h + 2);
                _ = outline.initFromRect(&outer, 0);
                const widths: [4]f32 = .{ 1, 1, 1, 1 };
                const border: gdk.RGBA = .{ .f_red = fg.f_red, .f_green = fg.f_green, .f_blue = fg.f_blue, .f_alpha = 0.4 };
                snap.appendBorder(&outline, &widths, &.{ border, border, border, border });
            }
        }
    }

    fn dispose(self: *LayoutWidget) callconv(.c) void {
        const me = self.as(gtk.Widget);
        while (me.getFirstChild()) |c| c.unparent();
        if (self.state) |s| s.placements.clearRetainingCapacity();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *LayoutWidget) callconv(.c) void {
        if (self.state) |s| {
            s.placements.deinit(alloc);
            s.clearDividers();
            s.dividers.deinit(alloc);
            alloc.destroy(s);
            self.state = null;
        }
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = LayoutWidget;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
