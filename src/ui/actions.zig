//! The actions this client performs, named as Rex.app names them so key
//! bindings in the user's Rex configuration and `rex -C … do` work the same
//! with either app. Each action turns into requests to the server; the UI
//! changes when the resulting view arrives.

const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("app.zig").App;
const sv = @import("session_view.zig");
const tv = @import("terminal_view.zig");
const mouse = @import("mouse.zig");
const Incoming = @import("client.zig").Incoming;
const api = @import("api.zig");
const Machine = @import("machine.zig").Machine;

const log = std.log.scoped(.actions);

pub const Action = struct {
    name: []const u8,
    title: []const u8,
    category: []const u8,
    /// A JSON Schema of the arguments, if the action takes any.
    args: ?[]const u8 = null,
    /// True if holding the key should repeat the action.
    repeats: bool = false,
};

const direction_schema =
    \\{"type":"object","properties":{"direction":{"enum":["left","right","up","down"],"type":"string"}},"required":["direction"]}
;

/// Every action this client performs, for menus, `client.keymap` and
/// `client.perform`.
pub const all = [_]Action{
    .{ .name = "client.tab.new", .title = "New Tab", .category = "Tabs" },
    .{ .name = "client.tab.close", .title = "Close Tab", .category = "Tabs" },
    .{ .name = "client.tab.rename", .title = "Rename Tab", .category = "Tabs" },
    .{ .name = "client.tab.next", .title = "Show Next Tab", .category = "Tabs", .repeats = true },
    .{ .name = "client.tab.previous", .title = "Show Previous Tab", .category = "Tabs", .repeats = true },
    .{ .name = "client.tab.goto", .title = "Go to Tab", .category = "Tabs", .args =
    \\{"type":"object","properties":{"index":{"type":"integer","description":"The tab to show. Tabs count from 1, and -1 means the last tab."}},"required":["index"]}
    },
    .{ .name = "client.tab.move", .title = "Move Tab", .category = "Tabs", .args =
    \\{"type":"object","properties":{"direction":{"enum":["backward","forward"],"type":"string"}},"required":["direction"]}
    },
    .{ .name = "client.tab.move.backward", .title = "Move Tab Backward", .category = "Tabs" },
    .{ .name = "client.tab.move.forward", .title = "Move Tab Forward", .category = "Tabs" },
    .{ .name = "pane.split", .title = "Split Pane", .category = "Panes", .args =
    \\{"type":"object","properties":{"direction":{"enum":["right","down","left","up","auto"],"type":"string"}},"required":["direction"]}
    },
    .{ .name = "pane.split.left", .title = "Split Pane Left", .category = "Panes" },
    .{ .name = "pane.split.right", .title = "Split Pane Right", .category = "Panes" },
    .{ .name = "pane.split.up", .title = "Split Pane Up", .category = "Panes" },
    .{ .name = "pane.split.down", .title = "Split Pane Down", .category = "Panes" },
    .{ .name = "pane.split.auto", .title = "Split Pane Best Fit", .category = "Panes" },
    .{ .name = "pane.focus", .title = "Focus Pane", .category = "Panes", .args = direction_schema, .repeats = true },
    .{ .name = "pane.focus.left", .title = "Focus Pane Left", .category = "Panes", .repeats = true },
    .{ .name = "pane.focus.right", .title = "Focus Pane Right", .category = "Panes", .repeats = true },
    .{ .name = "pane.focus.up", .title = "Focus Pane Up", .category = "Panes", .repeats = true },
    .{ .name = "pane.focus.down", .title = "Focus Pane Down", .category = "Panes", .repeats = true },
    .{ .name = "pane.focus_next", .title = "Focus Next Pane", .category = "Panes", .repeats = true },
    .{ .name = "pane.focus_previous", .title = "Focus Previous Pane", .category = "Panes", .repeats = true },
    .{ .name = "pane.zoom", .title = "Zoom Pane", .category = "Panes" },
    .{ .name = "pane.close", .title = "Close Pane", .category = "Panes" },
    .{ .name = "pane.float", .title = "Float Pane", .category = "Panes" },
    .{ .name = "pane.rename", .title = "Rename Pane", .category = "Panes" },
    .{ .name = "pane.copy", .title = "Copy from Pane", .category = "Edit" },
    .{ .name = "pane.paste", .title = "Paste into Pane", .category = "Edit" },
    .{ .name = "pane.select_all", .title = "Select All in Pane", .category = "Edit" },
    .{ .name = "client.scroll.page_up", .title = "Scroll Page Up", .category = "View", .repeats = true },
    .{ .name = "client.scroll.page_down", .title = "Scroll Page Down", .category = "View", .repeats = true },
    .{ .name = "session.new", .title = "New Session", .category = "Sessions" },
    .{ .name = "session.next", .title = "Next Session", .category = "Sessions" },
    .{ .name = "session.previous", .title = "Previous Session", .category = "Sessions" },
    .{ .name = "session.select", .title = "Go to Session", .category = "Sessions", .args =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"The identifier that the session's server assigned."}},"required":["session_id"]}
    },
    .{ .name = "session.rename", .title = "Rename Session", .category = "Sessions" },
    .{ .name = "session.close", .title = "Close Session", .category = "Sessions" },
    .{ .name = "client.sidebar.toggle", .title = "Toggle Sidebar", .category = "View" },
    .{ .name = "client.font.increase", .title = "Increase Font Size", .category = "View", .repeats = true },
    .{ .name = "client.font.decrease", .title = "Decrease Font Size", .category = "View", .repeats = true },
    .{ .name = "client.font.reset", .title = "Reset Font Size", .category = "View" },
    .{ .name = "client.window.fullscreen.toggle", .title = "Toggle Full Screen", .category = "Window" },
    .{ .name = "client.close", .title = "Close", .category = "Window" },
    .{ .name = "client.palette.toggle", .title = "Command Palette", .category = "Window" },
    .{ .name = "client.shortcuts", .title = "Keyboard Shortcuts", .category = "Window" },
    .{ .name = "client.about", .title = "About rex-gtk", .category = "Window" },
    .{ .name = "client.sidebar.filter", .title = "Filter Tabs", .category = "View" },
    .{ .name = "pane.reset", .title = "Reset Terminal", .category = "Panes" },
    .{ .name = "pane.menu", .title = "Show Pane Menu", .category = "Panes" },
    .{ .name = "client.preferences", .title = "Preferences", .category = "Window", .args =
    \\{"type":"object","properties":{"page":{"enum":["server","general","machines","appearance","themes","terminal","shortcuts","notifications"],"type":"string","description":"The page to show."},"machine":{"type":"string","description":"On the Machines page, the machine whose details to show, by name."}}}
    },
};

pub fn find(name: []const u8) ?Action {
    for (all) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

pub const Error = error{
    /// Not one of our actions.
    NotSupported,
    /// Missing or wrong arguments.
    BadArgs,
    /// Nothing to act on, such as no session or no focused pane.
    NoTarget,
};

/// Perform an action. `args` is a JSON object, or `.null` for none.
pub fn perform(app: *App, name: []const u8, args: std.json.Value) Error!void {
    log.debug("perform {s}", .{name});
    const eq = std.mem.eql;

    // Actions that don't need a session.
    if (eq(u8, name, "client.sidebar.toggle")) return app.toggleSidebar();
    if (eq(u8, name, "client.window.fullscreen.toggle")) {
        const w = (app.window orelse return error.NoTarget).as(gtk.Window);
        if (w.isFullscreen() != 0) w.unfullscreen() else w.fullscreen();
        return;
    }
    if (eq(u8, name, "client.close")) {
        (app.window orelse return error.NoTarget).as(gtk.Window).close();
        return;
    }
    if (eq(u8, name, "client.palette.toggle")) return @import("palette.zig").toggle(app);
    if (eq(u8, name, "client.shortcuts")) return app.showShortcuts();
    if (eq(u8, name, "client.about")) return app.showAbout();
    if (eq(u8, name, "client.sidebar.filter")) return app.startFilter();
    if (eq(u8, name, "client.preferences")) {
        app.showPreferences();
        const prefs = app.prefs orelse return;
        if (argString(args, "page")) |page| prefs.showPageNamed(page) catch return error.BadArgs;
        if (argString(args, "machine")) |m| prefs.showMachine(m) catch return error.BadArgs;
        return;
    }
    if (eq(u8, name, "client.font.increase")) return app.setFontSize(app.font_size + 1);
    if (eq(u8, name, "client.font.decrease")) return app.setFontSize(@max(4, app.font_size - 1));
    if (eq(u8, name, "client.font.reset")) return app.setFontSize(app.defaultFontSize());
    if (eq(u8, name, "session.new")) return newSession(app);
    if (eq(u8, name, "session.select")) {
        const id = argString(args, "session_id") orelse return error.BadArgs;
        return app.switchSessionById(id);
    }
    if (eq(u8, name, "session.next")) return stepSession(app, 1);
    if (eq(u8, name, "session.previous")) return stepSession(app, -1);

    const view = app.view orelse return error.NoTarget;
    const rex = app.rex();
    const sid = view.session_id;

    if (eq(u8, name, "session.rename")) return promptRename(app, .session, view.label, "Rename Session");
    if (eq(u8, name, "session.close")) return confirmCloseSession(app);

    // Tabs.
    if (eq(u8, name, "client.tab.new")) {
        return newTabOn(app, view.machine, sid);
    }
    if (eq(u8, name, "client.tab.next")) return rex.send("session.focus_next_window", .{ .session_id = sid, .wrap = true });
    if (eq(u8, name, "client.tab.previous")) return rex.send("session.focus_previous_window", .{ .session_id = sid, .wrap = true });
    if (eq(u8, name, "client.tab.goto")) {
        const index = argInt(args, "index") orelse return error.BadArgs;
        const n: i64 = @intCast(view.tabs.items.len);
        if (n == 0) return error.NoTarget;
        const i: i64 = if (index < 0) n + index else index - 1;
        if (i < 0 or i >= n) return error.NoTarget;
        return rex.send("session.focus_window", .{ .session_id = sid, .window_id = view.tabAt(@intCast(i)).?.window_id });
    }
    if (eq(u8, name, "client.tab.move") or eq(u8, name, "client.tab.move.forward") or eq(u8, name, "client.tab.move.backward")) {
        const forward = if (eq(u8, name, "client.tab.move"))
            eq(u8, argString(args, "direction") orelse return error.BadArgs, "forward")
        else
            eq(u8, name, "client.tab.move.forward");
        return moveTab(app, view, forward);
    }

    const tab = view.selectedTab() orelse return error.NoTarget;
    if (eq(u8, name, "client.tab.close")) return view.closeTab(tab);
    if (eq(u8, name, "client.tab.rename")) return promptRename(app, .tab, tab.label orelse "", "Rename Tab");

    // Panes.
    if (eq(u8, name, "pane.focus_next")) return rex.send("session.focus_next_pane", .{ .session_id = sid, .wrap = true });
    if (eq(u8, name, "pane.focus_previous")) return rex.send("session.focus_previous_pane", .{ .session_id = sid, .wrap = true });
    if (std.mem.startsWith(u8, name, "pane.focus")) {
        const dir = suffixOrArg(name, "pane.focus", args, "direction") orelse return error.BadArgs;
        if (!isDirection(dir)) return error.BadArgs;
        return rex.send("session.focus_direction", .{ .session_id = sid, .direction = dir, .wrap = false });
    }

    const block_id = tab.focused_block_id orelse return error.NoTarget;
    if (std.mem.startsWith(u8, name, "pane.split")) {
        var dir = suffixOrArg(name, "pane.split", args, "direction") orelse return error.BadArgs;
        if (eq(u8, dir, "auto")) {
            const pane = view.focusedPane(tab);
            dir = if (pane) |p| (if (p.device_w >= p.device_h * 2) "right" else "down") else "right";
        }
        if (!isDirection(dir)) return error.BadArgs;
        const horizontal = eq(u8, dir, "left") or eq(u8, dir, "right");
        const after = eq(u8, dir, "right") or eq(u8, dir, "down");
        return rex.send("session.new_split", .{
            .session_id = sid,
            .anchor_id = block_id,
            .direction = if (horizontal) "horizontal" else "vertical",
            .side = if (after) "after" else "before",
            .layout = shellLayout(app),
            .focus = true,
        });
    }
    if (eq(u8, name, "pane.zoom")) return rex.send("session.zoom_block", .{ .session_id = sid, .block_id = block_id });
    if (eq(u8, name, "pane.close")) return rex.send("block.close", .{ .session_id = sid, .block_id = block_id });
    if (eq(u8, name, "pane.float")) return rex.send("session.float_block", .{
        .session_id = sid,
        .block_id = block_id,
        .bounds = [4]f64{ 0.15, 0.15, 0.7, 0.7 },
    });
    if (eq(u8, name, "pane.rename")) return promptRename(app, .pane, "", "Rename Pane");

    const pane = view.focusedPane(tab) orelse return error.NoTarget;
    const widget = pane.widgetPtr();
    if (eq(u8, name, "pane.menu")) {
        const w = pane.widgetPtr();
        const cm = pane.services.context_menu orelse return error.NotSupported;
        return cm.func(cm.ctx, pane, @as(f64, @floatFromInt(w.getWidth())) / 2, @as(f64, @floatFromInt(w.getHeight())) / 3);
    }
    if (eq(u8, name, "pane.reset")) {
        return pane.machine.send("com.superlogical.terminal.reset", .{
            .session_id = pane.session_id,
            .block_id = pane.block_id,
            .args = struct {}{},
        });
    }
    if (eq(u8, name, "pane.copy")) return mouse.copyTo(pane, widget.getClipboard());
    if (eq(u8, name, "pane.paste")) return mouse.pasteFrom(pane, widget.getClipboard());
    if (eq(u8, name, "pane.select_all")) {
        const mirror = pane.mirror orelse return error.NoTarget;
        const screen = mirror.terminal.screens.active;
        screen.select(screen.selectAll()) catch {};
        return pane.selectionChanged();
    }
    if (eq(u8, name, "client.scroll.page_up") or eq(u8, name, "client.scroll.page_down")) {
        const mirror = pane.mirror orelse return error.NoTarget;
        const rows: isize = @intCast(mirror.terminal.rows);
        mirror.terminal.scrollViewport(.{ .delta = if (eq(u8, name, "client.scroll.page_up")) -rows else rows });
        return pane.selectionChanged();
    }
    return error.NotSupported;
}

/// Perform an action from a key binding or menu, logging failures.
pub fn run(app: *App, name: []const u8, args: std.json.Value) void {
    perform(app, name, args) catch |err| log.warn("{s}: {s}", .{ name, @errorName(err) });
}

// ----------------------------------------------------------------------
// Helpers

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// `pane.split.left` → "left"; `pane.split` → its `direction` argument.
fn suffixOrArg(name: []const u8, base: []const u8, args: std.json.Value, key: []const u8) ?[]const u8 {
    if (name.len > base.len + 1 and name[base.len] == '.') return name[base.len + 1 ..];
    if (name.len == base.len) return argString(args, key);
    return null;
}

fn isDirection(d: []const u8) bool {
    for ([_][]const u8{ "left", "right", "up", "down" }) |x| if (std.mem.eql(u8, d, x)) return true;
    return false;
}

const ShellOptions = struct { cwd: ?[]const u8 = null };
const ShellLayout = struct {
    block: struct {
        flavor: []const u8 = "com.superlogical.terminal.shell",
        options: ShellOptions = .{},
    } = .{},
};

pub fn newTabOn(app: *App, m: *Machine, session_id: []const u8) void {
    const current = if (app.view) |view|
        view.machine == m and std.mem.eql(u8, view.session_id, session_id)
    else
        false;
    m.send("session.new_window", .{
        .session_id = session_id,
        .layout = if (current) shellLayout(app) else ShellLayout{},
    });
}

/// A new shell, started in the focused pane's directory when we know it.
fn shellLayout(app: *App) ShellLayout {
    var layout: ShellLayout = .{};
    if (app.view) |view| if (view.selectedTab()) |tab| if (view.focusedPane(tab)) |p| {
        layout.block.options.cwd = p.pwd;
    };
    return layout;
}

fn moveTab(app: *App, view: *sv.SessionView, forward: bool) Error!void {
    const tab = view.selectedTab() orelse return error.NoTarget;
    const n = view.tabs.items.len;
    const i = for (view.tabs.items, 0..) |t, i| {
        if (t == tab) break i;
    } else return error.NoTarget;
    // Move before the tab two places on (or to the end), or one place back.
    const rex = app.rex();
    if (forward) {
        if (i + 1 >= n) return;
        if (i + 2 >= n) return rex.send("session.move_window", .{ .session_id = view.session_id, .window_id = tab.window_id });
        return rex.send("session.move_window", .{ .session_id = view.session_id, .window_id = tab.window_id, .before_window_id = view.tabs.items[i + 2].window_id });
    }
    if (i == 0) return;
    return rex.send("session.move_window", .{ .session_id = view.session_id, .window_id = tab.window_id, .before_window_id = view.tabs.items[i - 1].window_id });
}

fn stepSession(app: *App, step: i64) Error!void {
    if (app.sessionCount() == 0) return error.NoTarget;
    app.stepSession(step);
}

fn newSession(app: *App) void {
    newSessionOn(app, app.rex());
}

/// Start a session with one shell on `m`, and show it.
pub fn newSessionOn(app: *App, m: *Machine) void {
    m.call("session.create", .{ .initial_windows = &[_]struct { layout: ShellLayout }{.{ .layout = shellLayout(app) }} }, m, &onSessionCreated);
}

fn onSessionCreated(ctx: ?*anyopaque, maybe_msg: ?Incoming) void {
    const m: *Machine = @ptrCast(@alignCast(ctx.?));
    const app: *App = @ptrCast(@alignCast(m.listener.ctx));
    const msg = maybe_msg orelse return;
    defer msg.deinit();
    const res = api.parse(struct { session: struct { session_id: []const u8 } }, msg) orelse return;
    app.switchSession(m, res.session.session_id);
}

// ----------------------------------------------------------------------
// Dialogs

const RenameTarget = enum { session, tab, pane };

const Rename = struct {
    app: *App,
    target: RenameTarget,
    session_id: []u8,
    /// The window or block to rename.
    id: ?[]u8,
    entry: *gtk.Entry,
};

fn promptRename(app: *App, target: RenameTarget, current: []const u8, heading: [:0]const u8) Error!void {
    const view = app.view orelse return error.NoTarget;
    const gpa = app.gpa;
    const tab = view.selectedTab();
    const id: ?[]const u8 = switch (target) {
        .session => null,
        .tab => (tab orelse return error.NoTarget).window_id,
        .pane => (tab orelse return error.NoTarget).focused_block_id orelse return error.NoTarget,
    };

    const entry = gtk.Entry.new();
    entry.setActivatesDefault(1);
    const cur = gpa.dupeSentinel(u8, current, 0) catch return error.NoTarget;
    defer gpa.free(cur);
    entry.as(gtk.Editable).setText(cur);

    const req = gpa.create(Rename) catch return error.NoTarget;
    req.* = .{
        .app = app,
        .target = target,
        .session_id = gpa.dupe(u8, view.session_id) catch return error.NoTarget,
        .id = if (id) |i| gpa.dupe(u8, i) catch null else null,
        .entry = entry,
    };

    const dialog = adw.AlertDialog.new(heading, null);
    dialog.setExtraChild(entry.as(gtk.Widget));
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("rename", "Rename");
    dialog.setResponseAppearance("rename", .suggested);
    dialog.setDefaultResponse("rename");
    dialog.setCloseResponse("cancel");
    _ = adw.AlertDialog.signals.response.connect(dialog, *Rename, &onRenameResponse, req, .{});
    dialog.as(adw.Dialog).present(if (app.window) |w| w.as(gtk.Widget) else null);
}

fn onRenameResponse(_: *adw.AlertDialog, response: [*:0]u8, req: *Rename) callconv(.c) void {
    const app = req.app;
    const gpa = app.gpa;
    defer {
        gpa.free(req.session_id);
        if (req.id) |i| gpa.free(i);
        gpa.destroy(req);
    }
    if (!std.mem.eql(u8, std.mem.span(response), "rename")) return;
    const label = std.mem.span(req.entry.as(gtk.Editable).getText());
    const rex = app.rex();
    switch (req.target) {
        .session => rex.send("session.set_label", .{ .session_id = req.session_id, .label = label }),
        .tab => rex.send("session.set_window_label", .{ .session_id = req.session_id, .window_id = req.id.?, .label = label }),
        .pane => rex.send("session.set_block_label", .{ .session_id = req.session_id, .block_id = req.id.?, .label = label }),
    }
}

fn confirmCloseSession(app: *App) Error!void {
    const view = app.view orelse return error.NoTarget;
    const gpa = app.gpa;
    const id = gpa.dupe(u8, view.session_id) catch return error.NoTarget;
    const Req = struct { app: *App, session_id: []u8 };
    const req = gpa.create(Req) catch {
        gpa.free(id);
        return error.NoTarget;
    };
    req.* = .{ .app = app, .session_id = id };

    const dialog = adw.AlertDialog.new("Close Session?", "Every program running in this session will end.");
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("close", "Close Session");
    dialog.setResponseAppearance("close", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    _ = adw.AlertDialog.signals.response.connect(dialog, *Req, &struct {
        fn done(_: *adw.AlertDialog, response: [*:0]u8, r: *Req) callconv(.c) void {
            defer {
                r.app.gpa.free(r.session_id);
                r.app.gpa.destroy(r);
            }
            if (!std.mem.eql(u8, std.mem.span(response), "close")) return;
            r.app.rex().send("session.destroy", .{ .session_id = r.session_id });
        }
    }.done, req, .{});
    dialog.as(adw.Dialog).present(if (app.window) |w| w.as(gtk.Widget) else null);
}
