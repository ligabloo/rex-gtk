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

const Px = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Space between tiled blocks, in logical pixels.
const gap = 1;

pub const LayoutWidget = extern struct {
    parent_instance: Parent,
    state: ?*State,

    const State = struct {
        placements: std.ArrayList(Placement) = .empty,
        dark: bool = true,
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
        self.as(gtk.Widget).setOverflow(.hidden);
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

    /// Remove every child.
    pub fn clear(self: *LayoutWidget) void {
        self.setPlacements(&.{}, true);
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
            if (p.dim) snap.appendColor(&shade, &r);
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
