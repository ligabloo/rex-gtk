//! Questions from configuration file actions (`rex.ui`), shown as dialogs:
//! `input` asks for a line of text, `pick` for one or more items. The
//! answer goes back with `client.reply`; the server may end a prompt first
//! (another app answered, or it timed out), and then we close it unanswered.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const api = @import("api.zig");
const Incoming = @import("client.zig").Incoming;

const log = std.log.scoped(.prompts);

const Item = struct {
    id: []const u8,
    title: []const u8,
    subtitle: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    selected: bool = false,
};

const Request = struct {
    call_id: []const u8,
    action: ?[]const u8 = null,
    prompt: struct {
        kind: []const u8,
        title: []const u8,
        placeholder: ?[]const u8 = null,
        value: ?[]const u8 = null,
        confirm: ?[]const u8 = null,
        multiple: bool = false,
        allow_other: bool = false,
        items: ?[]const Item = null,
    },
    timeout_ms: u64 = 60_000,
};

/// One prompt on screen.
const Open = struct {
    prompts: *Prompts,
    call_id: []u8,
    dialog: *adw.AlertDialog,
    entry: ?*gtk.Entry = null,
    /// For pick: the item IDs, and a check button or row per item.
    ids: std.ArrayList([]u8) = .empty,
    checks: std.ArrayList(*gtk.CheckButton) = .empty,
    list: ?*gtk.ListBox = null,
    multiple: bool = false,
    timeout_id: c_uint = 0,
    /// Set once answered or ended, so `response` doesn't reply again.
    done: bool = false,
};

pub const Prompts = struct {
    gpa: Allocator,
    app: *App,
    open: std.ArrayList(*Open) = .empty,

    pub fn init(gpa: Allocator, app: *App) Prompts {
        return .{ .gpa = gpa, .app = app };
    }

    pub fn deinit(self: *Prompts) void {
        for (self.open.items) |o| {
            o.done = true;
            o.dialog.as(adw.Dialog).forceClose();
        }
        self.open.deinit(self.gpa);
    }

    fn reply(self: *Prompts, call_id: []const u8, result: anytype) void {
        self.app.localMachine().send("client.reply", .{ .call_id = call_id, .result = result });
    }

    pub fn show(self: *Prompts, msg: Incoming, payload: std.json.Value) void {
        const req = api.parseValue(Request, msg, payload) orelse return;
        const p = req.prompt;
        const is_input = std.mem.eql(u8, p.kind, "input");
        const is_pick = std.mem.eql(u8, p.kind, "pick");
        if (!is_input and !is_pick) {
            self.app.localMachine().send("client.reply", .{
                .call_id = req.call_id,
                .@"error" = .{ .code = "not_supported", .message = "rex-gtk can't show this kind of prompt" },
            });
            return;
        }
        const gpa = self.gpa;
        const o = gpa.create(Open) catch return;
        var title_buf: [256]u8 = undefined;
        var body_buf: [256]u8 = undefined;
        const dialog = adw.AlertDialog.new(
            std.fmt.bufPrintSentinel(&title_buf, "{s}", .{p.title}, 0) catch "Question",
            if (req.action) |a| (std.fmt.bufPrintSentinel(&body_buf, "For {s}", .{a}, 0) catch null) else null,
        );
        o.* = .{
            .prompts = self,
            .call_id = gpa.dupe(u8, req.call_id) catch {
                gpa.destroy(o);
                return;
            },
            .dialog = dialog,
            .multiple = p.multiple,
        };

        const box = gtk.Box.new(.vertical, 12);
        if (is_pick) {
            const list = gtk.ListBox.new();
            list.as(gtk.Widget).addCssClass("boxed-list");
            list.setSelectionMode(if (p.multiple) .none else .single);
            for (p.items orelse &.{}) |item| {
                const row = adw.ActionRow.new();
                var b1: [256]u8 = undefined;
                row.as(adw.PreferencesRow).setTitle(std.fmt.bufPrintSentinel(&b1, "{s}", .{item.title}, 0) catch "");
                if (item.subtitle) |sub| {
                    var b2: [256]u8 = undefined;
                    row.setSubtitle(std.fmt.bufPrintSentinel(&b2, "{s}", .{sub}, 0) catch "");
                }
                if (p.multiple) {
                    const check = gtk.CheckButton.new();
                    check.setActive(@intFromBool(item.selected));
                    row.addPrefix(check.as(gtk.Widget));
                    row.setActivatableWidget(check.as(gtk.Widget));
                    o.checks.append(gpa, check) catch {};
                } else if (item.detail) |d| {
                    var b3: [128]u8 = undefined;
                    row.addSuffix(gtk.Label.new(std.fmt.bufPrintSentinel(&b3, "{s}", .{d}, 0) catch "").as(gtk.Widget));
                }
                list.append(row.as(gtk.Widget));
                o.ids.append(gpa, gpa.dupe(u8, item.id) catch continue) catch {};
            }
            if (!p.multiple) list.selectRow(list.getRowAtIndex(0));
            o.list = list;
            const scroller = gtk.ScrolledWindow.new();
            scroller.setChild(list.as(gtk.Widget));
            scroller.setPropagateNaturalHeight(1);
            scroller.setMaxContentHeight(360);
            scroller.setPolicy(.never, .automatic);
            box.append(scroller.as(gtk.Widget));
        }
        if (is_input or p.allow_other) {
            const entry = gtk.Entry.new();
            entry.setActivatesDefault(1);
            if (p.placeholder) |ph| {
                var b: [256]u8 = undefined;
                entry.setPlaceholderText(std.fmt.bufPrintSentinel(&b, "{s}", .{ph}, 0) catch "");
            }
            if (p.value) |v| {
                const z = gpa.dupeSentinel(u8, v, 0) catch null;
                defer if (z) |x| gpa.free(x);
                if (z) |x| entry.as(gtk.Editable).setText(x);
            }
            o.entry = entry;
            box.append(entry.as(gtk.Widget));
        }
        dialog.setExtraChild(box.as(gtk.Widget));
        var confirm_buf: [128]u8 = undefined;
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("ok", std.fmt.bufPrintSentinel(&confirm_buf, "{s}", .{p.confirm orelse "OK"}, 0) catch "OK");
        dialog.setResponseAppearance("ok", .suggested);
        dialog.setDefaultResponse("ok");
        dialog.setCloseResponse("cancel");
        _ = adw.AlertDialog.signals.response.connect(dialog, *Open, &onResponse, o, .{});
        _ = adw.Dialog.signals.closed.connect(dialog.as(adw.Dialog), *Open, &onClosed, o, .{});
        o.timeout_id = glib.timeoutAdd(@intCast(@min(req.timeout_ms, std.math.maxInt(c_uint))), &onTimeout, o);
        self.open.append(gpa, o) catch {};
        dialog.as(adw.Dialog).present(if (self.app.window) |w| w.as(gtk.Widget) else null);
    }

    /// The server ended a prompt: close it without answering.
    pub fn end(self: *Prompts, call_id: []const u8) void {
        for (self.open.items) |o| if (std.mem.eql(u8, o.call_id, call_id)) {
            o.done = true;
            o.dialog.as(adw.Dialog).forceClose();
            return;
        };
    }

    fn onResponse(_: *adw.AlertDialog, response: [*:0]u8, o: *Open) callconv(.c) void {
        if (o.done) return;
        o.done = true;
        const self = o.prompts;
        if (!std.mem.eql(u8, std.mem.span(response), "ok")) {
            return self.reply(o.call_id, .{ .cancelled = true });
        }
        // Typed text wins over a picked item when both are offered.
        if (o.entry) |e| {
            const text = std.mem.span(e.as(gtk.Editable).getText());
            if (o.list == null or text.len > 0) return self.reply(o.call_id, .{ .text = text });
        }
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.gpa);
        if (o.multiple) {
            for (o.checks.items, o.ids.items) |c, id| if (c.getActive() != 0) ids.append(self.gpa, id) catch {};
        } else if (o.list) |list| if (list.getSelectedRow()) |row| {
            const i: usize = @intCast(row.getIndex());
            if (i < o.ids.items.len) ids.append(self.gpa, o.ids.items[i]) catch {};
        };
        self.reply(o.call_id, .{ .ids = ids.items });
    }

    fn onTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const o: *Open = @ptrCast(@alignCast(data.?));
        o.timeout_id = 0;
        o.done = true;
        o.dialog.as(adw.Dialog).forceClose();
        return 0;
    }

    fn onClosed(_: *adw.Dialog, o: *Open) callconv(.c) void {
        const self = o.prompts;
        const gpa = self.gpa;
        if (o.timeout_id != 0) _ = glib.Source.remove(o.timeout_id);
        for (self.open.items, 0..) |x, i| if (x == o) {
            _ = self.open.swapRemove(i);
            break;
        };
        for (o.ids.items) |id| gpa.free(id);
        o.ids.deinit(gpa);
        o.checks.deinit(gpa);
        gpa.free(o.call_id);
        gpa.destroy(o);
    }
};
