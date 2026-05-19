//! Validate test suite. Stub until M1 (codestream walker) lands.
//!
//! NEXT STEPS (for the LLM picking this up):
//!
//! 1. M1 codestream walker emits findings for structural issues
//!    (missing SOC, bad SIZ marker, truncated codestream). Write
//!    these tests RED-FIRST against the planned cleanroom
//!    validator entry point.
//!
//! 2. Mirror jpegz's validator test patterns — they're a clean
//!    template (see jpegz/tests/unit/validate.zig).

const std = @import("std");
const jp2z = @import("jp2z");

test "validate: stub returns PASS for empty input" {
    var report = try jp2z.validate(std.testing.allocator, "");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.pass, report.overall);
}
