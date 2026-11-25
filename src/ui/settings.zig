//! rex-gtk's own settings, kept in $XDG_CONFIG_HOME/rex-gtk/settings.json.
//!
//! A flat JSON object of named values such as "ssh.agent". Keys this
//! version doesn't know are kept, so an older build doesn't drop what a
//! newer one saved. Changes are written shortly after they're made, and
//! listeners hear about each one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const glib = @import("glib");
const file = @import("settings_file.zig");
const parse = file.parse;
const stringify = file.stringify;

const log = std.log.scoped(.settings);

/// Wait this long after a change before writing, so a burst of changes,
/// such as dragging a slider, is written once.
const save_delay_ms = 300;

pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, key: []const u8) void,
};

pub const Settings = struct {
    gpa: Allocator,
    io: std.Io,
    /// The file to save to; null keeps changes in memory only.
    path: ?[]u8,
    arena: std.heap.ArenaAllocator,
    values: json.ObjectMap,
    listeners: std.ArrayList(Listener) = .empty,
    save_id: c_uint = 0,

    /// Start from the settings file, or from nothing if it's missing or
    /// unreadable. `config_home` is XDG_CONFIG_HOME, or HOME/.config.
    pub fn load(gpa: Allocator, io: std.Io, config_home: ?[]const u8) !Settings {
        var self: Settings = .{
            .gpa = gpa,
            .io = io,
            .path = null,
            .arena = .init(gpa),
            .values = undefined,
        };
        errdefer self.arena.deinit();
        self.values = .empty;

        const dir = config_home orelse return self;
        self.path = try std.fs.path.join(gpa, &.{ dir, "rex-gtk", "settings.json" });
        const text = std.Io.Dir.cwd().readFileAlloc(io, self.path.?, gpa, .limited(1 << 20)) catch |err| {
            if (err != error.FileNotFound) log.warn("reading {s} failed: {t}", .{ self.path.?, err });
            return self;
        };
        defer gpa.free(text);
        self.values = parse(self.arena.allocator(), text) catch |err| values: {
            log.warn("{s} isn't a JSON object ({t}); starting over", .{ self.path.?, err });
            break :values .empty;
        };
        return self;
    }

    pub fn deinit(self: *Settings) void {
        if (self.save_id != 0) {
            _ = glib.Source.remove(self.save_id);
            self.save_id = 0;
            self.save();
        }
        self.listeners.deinit(self.gpa);
        if (self.path) |p| self.gpa.free(p);
        self.arena.deinit();
    }

    pub fn subscribe(self: *Settings, listener: Listener) void {
        self.listeners.append(self.gpa, listener) catch {};
    }

    pub fn unsubscribe(self: *Settings, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < self.listeners.items.len) {
            if (self.listeners.items[i].ctx == ctx) {
                _ = self.listeners.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn getString(self: *const Settings, key: []const u8, default: []const u8) []const u8 {
        return switch (self.values.get(key) orelse return default) {
            .string => |s| s,
            else => default,
        };
    }

    pub fn getBool(self: *const Settings, key: []const u8, default: bool) bool {
        return switch (self.values.get(key) orelse return default) {
            .bool => |b| b,
            else => default,
        };
    }

    pub fn setString(self: *Settings, key: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, self.getString(key, ""), value) and self.values.contains(key)) return;
        const a = self.arena.allocator();
        const v = a.dupe(u8, value) catch return;
        self.put(key, .{ .string = v });
    }

    pub fn setBool(self: *Settings, key: []const u8, value: bool) void {
        if (self.values.get(key)) |old| if (old == .bool and old.bool == value) return;
        self.put(key, .{ .bool = value });
    }

    fn put(self: *Settings, key: []const u8, value: json.Value) void {
        const a = self.arena.allocator();
        const k = if (self.values.getKey(key)) |existing| existing else a.dupe(u8, key) catch return;
        self.values.put(a, k, value) catch return;
        self.scheduleSave();
        // Copy: a listener may subscribe or unsubscribe.
        const copy = self.gpa.dupe(Listener, self.listeners.items) catch return;
        defer self.gpa.free(copy);
        for (copy) |l| l.func(l.ctx, key);
    }

    fn scheduleSave(self: *Settings) void {
        if (self.path == null or self.save_id != 0) return;
        self.save_id = glib.timeoutAdd(save_delay_ms, &onSaveTimer, self);
    }

    fn onSaveTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Settings = @ptrCast(@alignCast(data.?));
        self.save_id = 0;
        self.save();
        return 0;
    }

    /// Write the file: to a temporary name first, then over the old one,
    /// so a crash never leaves half a file.
    fn save(self: *Settings) void {
        const path = self.path orelse return;
        const text = stringify(self.gpa, self.values) catch return;
        defer self.gpa.free(text);
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch |err| {
            log.warn("creating {s} failed: {t}", .{ dir, err });
            return;
        };
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.new", .{path}) catch return;
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = text }) catch |err| {
            log.warn("writing {s} failed: {t}", .{ tmp, err });
            return;
        };
        cwd.rename(tmp, cwd, path, self.io) catch |err| log.warn("saving {s} failed: {t}", .{ path, err });
    }
};
