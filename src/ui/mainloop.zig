//! Hand work from background threads to the GTK main thread.
//!
//! All app state lives on the main thread. Reader threads never touch it;
//! they call `post`, and the callback runs on the main thread. Callbacks
//! posted at the same priority run in the order they were posted.

const glib = @import("glib");

pub const Priority = enum(c_int) {
    /// Runs when nothing more urgent is pending, after GTK's redraws.
    idle = glib.PRIORITY_DEFAULT_IDLE,
    /// Runs alongside input events, ahead of GTK's redraws. For latency-
    /// sensitive work that can't flood the loop.
    default = glib.PRIORITY_DEFAULT,
};

/// Run `handler(data)` on the main thread at idle priority. Safe to call
/// from any thread.
pub fn post(comptime T: type, data: *T, comptime handler: fn (*T) void) void {
    postWithPriority(T, data, handler, .idle);
}

/// Run `handler(data)` on the main thread. Safe to call from any thread.
pub fn postWithPriority(comptime T: type, data: *T, comptime handler: fn (*T) void, priority: Priority) void {
    const Trampoline = struct {
        fn run(ptr: ?*anyopaque) callconv(.c) c_int {
            handler(@ptrCast(@alignCast(ptr.?)));
            return 0; // G_SOURCE_REMOVE
        }
    };
    _ = glib.idleAddFull(@intFromEnum(priority), &Trampoline.run, data, null);
}
