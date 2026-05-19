//! FindingsSink — side-channel collector for spec-deviation findings.
//! Mirrors `jpegz/src/decode/findings.zig` shape so consumers can
//! pass the same vocabulary to both libraries (and so jpegz's future
//! re-export shim can route findings through without translation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../jp2z.zig");
const errors = @import("../core/errors.zig");

pub const Finding = types.Finding;
pub const Severity = errors.Severity;
pub const FindingCode = errors.FindingCode;

pub const FindingsSink = struct {
    allocator: Allocator,
    list: std.ArrayList(Finding),

    pub fn init(allocator: Allocator) FindingsSink {
        return .{
            .allocator = allocator,
            .list = .empty,
        };
    }

    pub fn deinit(self: *FindingsSink) void {
        for (self.list.items) |f| {
            if (f.detail) |d| self.allocator.free(d);
        }
        self.list.deinit(self.allocator);
    }

    pub fn emit(
        self: *FindingsSink,
        severity: Severity,
        code: FindingCode,
        offset: ?u64,
        detail: ?[]const u8,
    ) Allocator.Error!void {
        const stored: ?[]const u8 = if (detail) |d|
            try self.allocator.dupe(u8, d)
        else
            null;
        errdefer if (stored) |s| self.allocator.free(s);

        try self.list.append(self.allocator, .{
            .severity = severity,
            .code = code,
            .offset = offset,
            .detail = stored,
        });
    }

    pub fn items(self: *const FindingsSink) []const Finding {
        return self.list.items;
    }
};

test "FindingsSink: init, emit, deinit" {
    var sink = FindingsSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.emit(.warn, .jp2_invalid_codestream, 42, "test");
    try std.testing.expectEqual(@as(usize, 1), sink.items().len);
}
