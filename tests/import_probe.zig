//! Mechanical gate (MFIC) for the PUBLIC `jp2z` module's import contract:
//! a validate-only consumer — exactly what the jpegz facade's U1 slice is —
//! must compile AND link with ZERO C dependencies: no openjpeg headers, no
//! -lopenjp2, no include/library paths. Zig's lazy analysis keeps the
//! Phase-1 decode path (openjpeg_wrapper's @cImport) out of such builds as
//! long as nothing force-links the C ABI from the module root.
//!
//! If this step REDs, one of two regressions returned: a comptime
//! force-link of ffi/c_api.zig in src/jp2z.zig (belongs in lib_root.zig),
//! or openjpeg re-attached to the public module in build.zig (belongs on
//! the internal flavor / artifacts).
const std = @import("std");
const jp2z = @import("jp2z");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // A bare SOC marker: enough to drive the validate walk end-to-end.
    // The gate is compile+link; the run just proves the entry point is
    // callable. Output stays silent (tests run clean) — exit code only.
    var report = try jp2z.validate(arena.allocator(), &[_]u8{ 0xFF, 0x4F });
    defer report.deinit(arena.allocator());
    if (@intFromEnum(report.overall) > @intFromEnum(jp2z.Severity.fail)) return error.ImplausibleSeverity;
}
