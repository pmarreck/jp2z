//! Mechanical gate (MFIC) for the PUBLIC `jp2z` module's import contract:
//! a strict-validation consumer — exactly what the jpegz facade needs —
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
    // Exercise the actual strict, entropy-decoding entry point against a
    // conforming codestream. This prevents a shallow structural-only probe
    // from going green while deep validation accidentally regains a C oracle.
    const valid = @embedFile("unit/fixtures/conformance/a1_mono.j2c");
    var report = try jp2z.deepValidate(arena.allocator(), valid, true);
    defer report.deinit(arena.allocator());
    if (report.overall == .fail) return error.ValidFixtureRejected;
}
