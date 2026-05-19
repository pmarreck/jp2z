//! Thread-local last-error preservation. Identical shape to
//! `jpegz/src/core/last_error.zig`.

const std = @import("std");

threadlocal var buf: [512]u8 = undefined;
threadlocal var len: usize = 0;
threadlocal var initialized: bool = false;

inline fn ensureInitialized() void {
    if (!initialized) {
        buf[0] = 0;
        initialized = true;
    }
}

pub fn clear() void {
    ensureInitialized();
    len = 0;
    buf[0] = 0;
}

pub fn set(comptime fmt: []const u8, args: anytype) void {
    ensureInitialized();
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    len = slice.len;
    if (len < buf.len) buf[len] = 0 else buf[buf.len - 1] = 0;
}

pub fn current() []const u8 {
    ensureInitialized();
    return buf[0..len];
}

pub fn cPtr() [*:0]const u8 {
    ensureInitialized();
    if (len < buf.len) buf[len] = 0 else buf[buf.len - 1] = 0;
    return @ptrCast(&buf[0]);
}

test "set + current round-trip" {
    clear();
    try std.testing.expectEqual(@as(usize, 0), current().len);
    set("hello {s}", .{"world"});
    try std.testing.expectEqualStrings("hello world", current());
}
