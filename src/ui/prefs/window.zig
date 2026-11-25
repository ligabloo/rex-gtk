//! The Preferences window: a sidebar of pages, as in GNOME Settings, and
//! the selected page as Adwaita boxed lists.
//!
//! Pages build their rows from the app's current state and are rebuilt
//! when it changes (`machinesChanged`, `serverChanged`). Rebuilds always
//! run from an idle callback, never inside a row's own signal, so a row
//! can safely cause one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const App = @import("../app.zig").App;
const Settings = @import("../settings.zig").Settings;
const ServerPage = @import("server.zig").ServerPage;
const GeneralPage = @import("general.zig").GeneralPage;
const MachinesPage = @import("machines.zig").MachinesPage;
const AppearancePage = @import("appearance.zig").AppearancePage;
const ThemesPage = @import("themes.zig").ThemesPage;
const TerminalPage = @import("terminal.zig").TerminalPage;
const ShortcutsPage = @import("shortcuts.zig").ShortcutsPage;
const NotificationsPage = @import("notifications.zig").NotificationsPage;

const log = std.log.scoped(.prefs);

pub const PageId = enum { server, general, machines, appearance, themes, terminal, shortcuts, notifications };

const PageInfo = struct {
    id: PageId,
    title: [:0]const u8,
    icon: [:0]const u8,
    /// Words the search matches besides the title.
    keywords: []const u8,
};

const pages = [_]PageInfo{
    .{ .id = .server, .title = "Server", .icon = "network-server-symbolic", .keywords = "status stop restart connections address tailscale tailnet pair device qr sign in account control configuration init.lua reload" },
    .{ .id = .general, .title = "General", .icon = "preferences-system-symbolic", .keywords = "client name label remote control startup session open start server" },
    .{ .id = .machines, .title = "Machines", .icon = "computer-symbolic", .keywords = "hosts remote ssh agent keys add machine address check" },
    .{ .id = .appearance, .title = "Appearance", .icon = "applications-graphics-symbolic", .keywords = "style light dark tabs layout sidebar header bar hide hover dim panes activity" },
    .{ .id = .themes, .title = "Themes", .icon = "color-select-symbolic", .keywords = "colors palette light dark solarized gruvbox catppuccin tokyo nord" },
    .{ .id = .terminal, .title = "Terminal", .icon = "utilities-terminal-symbolic", .keywords = "font size selection copy scroll wheel" },
    .{ .id = .shortcuts, .title = "Shortcuts", .icon = "preferences-desktop-keyboard-shortcuts-symbolic", .keywords = "keys bindings keyboard keymap" },
    .{ .id = .notifications, .title = "Notifications", .icon = "preferences-system-notifications-symbolic", .keywords = "bell sound alert notify blocked done failed osc" },
};

pub const Prefs = struct {
    app: *App,
    gpa: Allocator,
    dialog: *adw.Dialog,
    toasts: *adw.ToastOverlay,
    split: *adw.NavigationSplitView,
    /// The content side: the selected page, with subpages pushed on it.
    nav: *adw.NavigationView,
    list: *gtk.ListBox,
    search: *gtk.SearchEntry,
    search_bar: *gtk.SearchBar,
    status_dot: *gtk.Widget,

    server: *ServerPage,
    general: *GeneralPage,
    machines: *MachinesPage,
    appearance: *AppearancePage,
    themes: *ThemesPage,
    terminal: *TerminalPage,
    shortcuts: *ShortcutsPage,
    notifications: *NotificationsPage,
    current: PageId = .server,
    closed_handler: c_ulong = 0,

    pub fn create(app: *App) !*Prefs {
        const gpa = app.gpa;
        const self = try gpa.create(Prefs);
        errdefer gpa.destroy(self);

        const dialog = adw.Dialog.new();
        dialog.setTitle("Preferences");
        dialog.setContentWidth(940);
        dialog.setContentHeight(680);

        // Sidebar: a search toggle beside the title, then the pages.
        const search_toggle = gtk.ToggleButton.new();
        search_toggle.as(gtk.Button).setIconName("system-search-symbolic");
        search_toggle.as(gtk.Widget).setTooltipText("Search");
        const side_header = adw.HeaderBar.new();
        side_header.packStart(search_toggle.as(gtk.Widget));
        side_header.setShowEndTitleButtons(0);

        const search = gtk.SearchEntry.new();
        search.as(gtk.Widget).setHexpand(1);
        const search_bar = gtk.SearchBar.new();
        search_bar.setChild(search.as(gtk.Widget));
        search_bar.connectEntry(search.as(gtk.Editable));
        _ = search_bar.as(gobject.Object).bindProperty("search-mode-enabled", search_toggle.as(gobject.Object), "active", .{ .bidirectional = true, .sync_create = true });

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("navigation-sidebar");
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        const side_box = gtk.Box.new(.vertical, 0);
        side_box.append(search_bar.as(gtk.Widget));
        side_box.append(scroller.as(gtk.Widget));
        const side_toolbar = adw.ToolbarView.new();
        side_toolbar.addTopBar(side_header.as(gtk.Widget));
        side_toolbar.setContent(side_box.as(gtk.Widget));
        const side_page = adw.NavigationPage.new(side_toolbar.as(gtk.Widget), "Preferences");

        const nav = adw.NavigationView.new();
        const content_page = adw.NavigationPage.new(nav.as(gtk.Widget), "Preferences");

        const split = adw.NavigationSplitView.new();
        split.setSidebar(side_page);
        split.setContent(content_page);
        split.setMinSidebarWidth(220);
        split.setMaxSidebarWidth(260);

        const toasts = adw.ToastOverlay.new();
        toasts.setChild(split.as(gtk.Widget));
        dialog.setChild(toasts.as(gtk.Widget));

        self.* = .{
            .app = app,
            .gpa = gpa,
            .dialog = dialog,
            .toasts = toasts,
            .split = split,
            .nav = nav,
            .list = list,
            .search = search,
            .search_bar = search_bar,
            .status_dot = undefined,
            .server = undefined,
            .general = undefined,
            .machines = undefined,
            .appearance = undefined,
            .themes = undefined,
            .terminal = undefined,
            .shortcuts = undefined,
            .notifications = undefined,
        };

        // The page list. The Server row ends with a dot for its state.
        for (pages) |p| {
            const box = gtk.Box.new(.horizontal, 12);
            box.append(gtk.Image.newFromIconName(p.icon).as(gtk.Widget));
            const label = gtk.Label.new(p.title);
            label.setXalign(0);
            label.as(gtk.Widget).setHexpand(1);
            box.append(label.as(gtk.Widget));
            if (p.id == .server) {
                const dot = gtk.Label.new("●");
                dot.as(gtk.Widget).addCssClass("caption");
                box.append(dot.as(gtk.Widget));
                self.status_dot = dot.as(gtk.Widget);
            }
            list.append(box.as(gtk.Widget));
        }
        list.setFilterFunc(&filterRow, self, null);
        _ = gtk.ListBox.signals.row_selected.connect(list, *Prefs, &onRowSelected, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *Prefs, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(search, *Prefs, &onSearchActivate, self, .{});
        // Typing anywhere in the sidebar starts a search.
        search_bar.setKeyCaptureWidget(side_toolbar.as(gtk.Widget));

        self.server = try ServerPage.create(self);
        errdefer self.server.destroy();
        self.general = try GeneralPage.create(self);
        errdefer self.general.destroy();
        self.machines = try MachinesPage.create(self);
        errdefer self.machines.destroy();
        self.appearance = try AppearancePage.create(self);
        self.themes = try ThemesPage.create(self);
        self.terminal = try TerminalPage.create(self);
        self.shortcuts = try ShortcutsPage.create(self);
        self.notifications = try NotificationsPage.create(self);

        self.closed_handler = adw.Dialog.signals.closed.connect(dialog, *Prefs, &onClosed, self, .{});
        list.selectRow(list.getRowAtIndex(0));
        self.updateStatusDot();
        return self;
    }

    pub fn present(self: *Prefs) void {
        self.dialog.present(if (self.app.window) |w| w.as(gtk.Widget) else null);
    }

    /// Close and free, as when the app quits.
    pub fn destroy(self: *Prefs) void {
        if (self.closed_handler != 0) gobject.signalHandlerDisconnect(self.dialog.as(gobject.Object), self.closed_handler);
        self.closed_handler = 0;
        self.dialog.forceClose();
        self.free();
    }

    fn free(self: *Prefs) void {
        self.server.destroy();
        self.general.destroy();
        self.machines.destroy();
        self.appearance.destroy();
        self.themes.destroy();
        self.terminal.destroy();
        self.shortcuts.destroy();
        self.notifications.destroy();
        self.gpa.destroy(self);
    }

    fn onClosed(_: *adw.Dialog, self: *Prefs) callconv(.c) void {
        self.closed_handler = 0;
        self.app.prefsClosed();
        self.free();
    }

    /// Show a page, as from the sidebar.
    pub fn showPage(self: *Prefs, id: PageId) void {
        self.current = id;
        self.machines.dropDetail();
        const page = switch (id) {
            .server => self.server.page,
            .general => self.general.page,
            .machines => self.machines.page,
            .appearance => self.appearance.page,
            .themes => self.themes.page,
            .terminal => self.terminal.page,
            .shortcuts => self.shortcuts.page,
            .notifications => self.notifications.page,
        };
        var list = [_]*adw.NavigationPage{page};
        self.nav.replace(&list, 1);
        self.split.setShowContent(1);
    }

    /// Show a page by its name, as `rex do client.preferences page=…`.
    pub fn showPageNamed(self: *Prefs, name: []const u8) !void {
        const id = std.meta.stringToEnum(PageId, name) orelse return error.NoSuchPage;
        self.list.selectRow(self.list.getRowAtIndex(@intFromEnum(id)));
    }

    /// Show a machine's details by its name.
    pub fn showMachine(self: *Prefs, label: []const u8) !void {
        for (self.app.machines.items) |m| if (!m.is_local and std.ascii.eqlIgnoreCase(m.label, label)) {
            try self.showPageNamed("machines");
            self.machines.openDetail(m.id);
            return;
        };
        return error.NoSuchMachine;
    }

    /// Push a subpage, such as a machine's details.
    pub fn push(self: *Prefs, page: *adw.NavigationPage) void {
        self.nav.push(page);
    }

    pub fn pop(self: *Prefs) void {
        _ = self.nav.pop();
    }

    pub fn toast(self: *Prefs, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
        self.toasts.addToast(adw.Toast.new(text));
    }

    /// Put text on the clipboard and say so.
    pub fn copy(self: *Prefs, text: []const u8) void {
        const zt = self.gpa.dupeSentinel(u8, text, 0) catch return;
        defer self.gpa.free(zt);
        const display = gdk.Display.getDefault() orelse return;
        display.getClipboard().setText(zt);
        self.toast("Copied", .{});
    }

    /// The window to parent dialogs on.
    pub fn parentWidget(self: *Prefs) *gtk.Widget {
        return self.dialog.as(gtk.Widget);
    }

    // ------------------------------------------------------------------
    // State changes

    pub fn machinesChanged(self: *Prefs) void {
        self.machines.scheduleRefresh();
        // This computer's state shows on the Server page too.
        self.server.scheduleRefresh();
        self.updateStatusDot();
    }

    pub fn serverChanged(self: *Prefs) void {
        self.server.scheduleRefresh();
        self.shortcuts.scheduleRefresh();
        self.updateStatusDot();
    }

    fn updateStatusDot(self: *Prefs) void {
        const w = self.status_dot;
        for ([_][:0]const u8{ "success", "warning", "error", "dim-label" }) |c| w.removeCssClass(c);
        const m = self.app.localMachine();
        const class: [:0]const u8, const tip: [:0]const u8 = switch (m.state) {
            .connected => .{ "success", "Running" },
            .connecting => .{ "warning", "Connecting" },
            .offline => .{ "error", "Not running" },
            .idle => .{ "dim-label", "Stopped" },
        };
        w.addCssClass(class);
        w.setTooltipText(tip);
    }

    // ------------------------------------------------------------------
    // Sidebar

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Prefs) callconv(.c) void {
        const r = row orelse return;
        const i: usize = @intCast(r.getIndex());
        if (i < pages.len) self.showPage(pages[i].id);
    }

    fn filterRow(row: *gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Prefs = @ptrCast(@alignCast(data.?));
        const i: usize = @intCast(row.getIndex());
        if (i >= pages.len) return 1;
        const query = std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " ");
        return @intFromBool(matches(pages[i], query));
    }

    fn matches(p: PageInfo, query: []const u8) bool {
        if (query.len == 0) return true;
        return containsIgnoreCase(p.title, query) or containsIgnoreCase(p.keywords, query);
    }

    fn onSearchChanged(_: *gtk.SearchEntry, self: *Prefs) callconv(.c) void {
        self.list.invalidateFilter();
    }

    /// Enter shows the first page that matches.
    fn onSearchActivate(_: *gtk.SearchEntry, self: *Prefs) callconv(.c) void {
        const query = std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " ");
        for (pages, 0..) |p, i| if (matches(p, query)) {
            self.list.selectRow(self.list.getRowAtIndex(@intCast(i)));
            return;
        };
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// Building rows

/// Text for GTK, which wants it zero-terminated. Valid until the next call
/// on the same buffer.
pub fn z(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch "…";
}

pub fn actionRow(title: [:0]const u8, subtitle: ?[:0]const u8) *adw.ActionRow {
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title);
    if (subtitle) |s| row.setSubtitle(s);
    // Titles and subtitles here are plain text, such as paths and addresses.
    row.as(adw.PreferencesRow).setUseMarkup(0);
    return row;
}

pub fn group(title: ?[:0]const u8, description: ?[:0]const u8) *adw.PreferencesGroup {
    const g = adw.PreferencesGroup.new();
    if (title) |t| g.setTitle(t);
    if (description) |d| g.setDescription(d);
    return g;
}

pub fn button(label: [:0]const u8, style: ?[:0]const u8) *gtk.Button {
    const b = gtk.Button.newWithLabel(label);
    b.as(gtk.Widget).setValign(.center);
    if (style) |s| b.as(gtk.Widget).addCssClass(s);
    return b;
}

pub fn iconButton(icon: [:0]const u8, tooltip: [:0]const u8) *gtk.Button {
    const b = gtk.Button.newFromIconName(icon);
    b.as(gtk.Widget).setValign(.center);
    b.as(gtk.Widget).addCssClass("flat");
    b.as(gtk.Widget).setTooltipText(tooltip);
    return b;
}

/// A small colored label, such as "Connected".
pub fn badge(text: [:0]const u8, style: [:0]const u8) *gtk.Widget {
    const l = gtk.Label.new(text);
    l.as(gtk.Widget).addCssClass("caption");
    l.as(gtk.Widget).addCssClass(style);
    l.as(gtk.Widget).setValign(.center);
    return l.as(gtk.Widget);
}

/// A preferences page in a navigation page with its own header bar.
pub fn navPage(title: [:0]const u8, content: *gtk.Widget) *adw.NavigationPage {
    const header = adw.HeaderBar.new();
    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(header.as(gtk.Widget));
    toolbar.setContent(content);
    const page = adw.NavigationPage.new(toolbar.as(gtk.Widget), title);
    // The page list replaces pages; keep ours alive while it isn't shown.
    _ = page.as(gobject.Object).ref();
    return page;
}

/// Calls `func(ctx)` once from idle, however many times it's asked for
/// before then.
pub const Deferred = struct {
    id: c_uint = 0,

    pub fn schedule(self: *Deferred, comptime T: type, ctx: *T, comptime func: fn (*T) void) void {
        if (self.id != 0) return;
        const Tramp = struct {
            fn run(data: ?*anyopaque) callconv(.c) c_int {
                const c: *T = @ptrCast(@alignCast(data.?));
                c.deferred.id = 0;
                func(c);
                return 0;
            }
        };
        self.id = glib.idleAdd(&Tramp.run, ctx);
    }

    pub fn cancel(self: *Deferred) void {
        if (self.id != 0) _ = glib.Source.remove(self.id);
        self.id = 0;
    }
};

/// Ask before doing something that can't be undone. `func(ctx)` runs if
/// the user agrees.
pub fn confirm(
    prefs: *Prefs,
    heading: [:0]const u8,
    body: [:0]const u8,
    action: [:0]const u8,
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
) void {
    const Req = struct {
        gpa: Allocator,
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) void,

        fn done(_: *adw.AlertDialog, response: [*:0]u8, r: *@This()) callconv(.c) void {
            defer r.gpa.destroy(r);
            if (std.mem.eql(u8, std.mem.span(response), "go")) r.func(r.ctx);
        }
    };
    const req = prefs.gpa.create(Req) catch return;
    req.* = .{ .gpa = prefs.gpa, .ctx = ctx, .func = func };
    const dialog = adw.AlertDialog.new(heading, body);
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("go", action);
    dialog.setResponseAppearance("go", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    _ = adw.AlertDialog.signals.response.connect(dialog, *Req, &Req.done, req, .{});
    dialog.as(adw.Dialog).present(prefs.parentWidget());
}

/// Open a web page in the user's browser.
pub fn openUri(prefs: *Prefs, uri: []const u8) void {
    const zuri = prefs.gpa.dupeSentinel(u8, uri, 0) catch return;
    defer prefs.gpa.free(zuri);
    const launcher = gtk.UriLauncher.new(zuri);
    defer launcher.as(gobject.Object).unref();
    const window = if (prefs.app.window) |w| w.as(gtk.Window) else null;
    launcher.launch(window, null, null, null);
}

pub fn switchRow(title: [:0]const u8, subtitle: ?[:0]const u8, active: bool) *adw.SwitchRow {
    const row = adw.SwitchRow.new();
    row.as(adw.PreferencesRow).setTitle(title);
    if (subtitle) |t| row.as(adw.ActionRow).setSubtitle(t);
    row.setActive(@intFromBool(active));
    return row;
}

/// Keep a boolean setting in step with a switch.
pub fn bindSwitch(row: *adw.SwitchRow, settings: *Settings, comptime key: []const u8) void {
    _ = gobject.Object.signals.notify.connect(row, *Settings, &struct {
        fn f(r: *adw.SwitchRow, _: *gobject.ParamSpec, s: *Settings) callconv(.c) void {
            s.setBool(key, r.getActive() != 0);
        }
    }.f, settings, .{ .detail = "active" });
}
