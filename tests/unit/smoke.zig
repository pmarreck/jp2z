//! Public-API wiring smoke test.

const std = @import("std");
const jp2z = @import("jp2z");

test "jp2z exposes version + lastErrorMessage" {
    try std.testing.expect(jp2z.version.len > 0);
    // No error has been recorded — empty slice.
    try std.testing.expectEqual(@as(usize, 0), jp2z.lastErrorMessage().len);
}

test "jp2z.decode rejects empty input" {
    try std.testing.expectError(
        error.TruncatedStream,
        jp2z.decode(std.testing.allocator, ""),
    );
}

test "jp2z.decode rejects non-JP2 input" {
    try std.testing.expectError(
        error.InvalidJp2Codestream,
        jp2z.decode(std.testing.allocator, "this is not a JP2 file at all"),
    );
}

test "jp2z.validate of empty input fails with missing_soi" {
    var report = try jp2z.validate(std.testing.allocator, "");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    try std.testing.expectEqual(@as(usize, 1), report.findings.items.len);
    try std.testing.expectEqual(jp2z.FindingCode.missing_soi, report.findings.items[0].code);
}

test "FindingsSink: create + emit + count" {
    var sink = jp2z.FindingsSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.emit(.warn, .jp2_invalid_codestream, 0, "test");
    try std.testing.expectEqual(@as(usize, 1), sink.items().len);
}
