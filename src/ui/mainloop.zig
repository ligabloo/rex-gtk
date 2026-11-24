//! Hand work from background threads to the GTK main thread.
//!
//! All app state lives on the main thread. Reader threads never touch it;
//! they call `post`, and the callback runs on the main thread. Callbacks
//! posted at the same priority run in the order they were posted.

const glib = @import("glib");

/// Run `handler(data)` on the main thread. Safe to call from any thread.
pub fn post(comptime T: type, data: *T, comptime handler: fn (*T) void) void {
    const Trampoline = struct {
        fn run(ptr: ?*anyopaque) callconv(.c) void {
            handler(@ptrCast(@alignCast(ptr.?)));
        }
    };
    _ = glib.idleAddOnce(&Trampoline.run, data);
}
