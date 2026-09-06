//! Deterministic strict-validator classifier over a set of conforming
//! JPEG 2000 files and three mutation scales. Structural mutations are
//! known-invalid by construction. Entropy-body mutations are sensitivity
//! probes because an arbitrary changed entropy stream can remain conforming.

const std = @import("std");
const jp2z = @import("jp2z");

const Fixture = struct {
    name: []const u8,
    family: Family,
    data: []const u8,
};

const Family = enum(usize) { codestream, jp2 };

const fixtures = [_]Fixture{
    .{ .name = "a1_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/a1_mono.j2c") },
    .{ .name = "a5_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/a5_mono.j2c") },
    .{ .name = "b1_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/b1_mono.j2c") },
    .{ .name = "c1_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/c1_mono.j2c") },
    .{ .name = "c2_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/c2_mono.j2c") },
    .{ .name = "d1_colr.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/d1_colr.j2c") },
    .{ .name = "e1_colr.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/e1_colr.j2c") },
    .{ .name = "f1_mono.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/f1_mono.j2c") },
    .{ .name = "p0_04.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_04.j2k") },
    .{ .name = "p0_09.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_09.j2k") },
    .{ .name = "p0_10.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_10.j2k") },
    .{ .name = "p1_04.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p1_04.j2k") },
    // Packed packet headers (T.800 A.7.4/A.7.5): g3 = PPM in 214 segments
    // (Nppm chunks span segments), g4 = PPT in 214 segments over 2 tile-parts,
    // p1_06 = PPT per tile-part across 16 tiles; g3/g4/p1_06 all carry SOP+EPH
    // (EPH inside the packed store). Must-accept guards for the packed walk.
    .{ .name = "g3_colr.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/g3_colr.j2c") },
    .{ .name = "g4_colr.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/g4_colr.j2c") },
    .{ .name = "p1_06.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p1_06.j2k") },
    .{ .name = "file1.jp2", .family = .jp2, .data = @embedFile("unit/fixtures/conformance/file1.jp2") },
    .{ .name = "file9.jp2", .family = .jp2, .data = @embedFile("unit/fixtures/conformance/file9.jp2") },
    // Real-encoder multi-tile lossy JP2 (12 tiles, 8 layers, RPCL, custom
    // precincts, SOP+EPH, SEGSYM). Guards the empty-packet extractor class:
    // stale last_contribution_length sliced phantom bytes into cblk plans
    // and fired entropy_under_read on a valid file (2026-08-13).
    .{ .name = "balloon_eciRGB_icc.jp2", .family = .jp2, .data = @embedFile("unit/fixtures/conformance/balloon_eciRGB_icc.jp2") },
};

const Stats = struct {
    controls: usize = 0,
    false_positive_rejects: usize = 0,
    known_corrupt_by_class: [3]usize = @splat(0),
    known_corrupt_misses_by_class: [3]usize = @splat(0),
    entropy_probes_by_class: [3]usize = @splat(0),
    entropy_detected_by_class: [3]usize = @splat(0),
    controls_by_family: [2]usize = @splat(0),
    false_positive_rejects_by_family: [2]usize = @splat(0),
    unsupported_controls_by_family: [2]usize = @splat(0),
    known_corrupt_misses_by_family_and_class: [6]usize = @splat(0),
    entropy_detected_by_family_and_class: [6]usize = @splat(0),
};

fn familyClassIndex(family: Family, class: usize) usize {
    return @intFromEnum(family) * 3 + class;
}

const Outcome = struct { rejected: bool, unsupported: bool };

fn strictOutcome(allocator: std.mem.Allocator, data: []const u8) !Outcome {
    var report = try jp2z.deepValidate(allocator, data, true);
    defer report.deinit(allocator);
    var unsupported = false;
    for (report.findings.items) |finding| {
        if (finding.code == .jp2_unsupported_marker_ignored) unsupported = true;
    }
    return .{ .rejected = report.overall == .fail, .unsupported = unsupported };
}

fn codestreamStart(data: []const u8) ?usize {
    return std.mem.indexOf(u8, data, &.{ 0xff, 0x4f, 0xff, 0x51 });
}

fn entropyRange(data: []const u8, start: usize) ?struct { start: usize, end: usize } {
    const sod_rel = std.mem.indexOf(u8, data[start..], &.{ 0xff, 0x93 }) orelse return null;
    const body_start = start + sod_rel + 2;
    const eoc_rel = std.mem.indexOf(u8, data[body_start..], &.{ 0xff, 0xd9 }) orelse return null;
    const body_end = body_start + eoc_rel;
    if (body_end <= body_start) return null;
    return .{ .start = body_start, .end = body_end };
}

fn runMatrix(allocator: std.mem.Allocator) !Stats {
    var stats = Stats{};
    for (fixtures) |fixture| {
        stats.controls += 1;
        stats.controls_by_family[@intFromEnum(fixture.family)] += 1;
        const control = try strictOutcome(allocator, fixture.data);
        if (control.unsupported) stats.unsupported_controls_by_family[@intFromEnum(fixture.family)] += 1;
        if (control.rejected) {
            stats.false_positive_rejects += 1;
            stats.false_positive_rejects_by_family[@intFromEnum(fixture.family)] += 1;
        }

        const soc = codestreamStart(fixture.data) orelse return error.MissingCodestream;
        for (0..3) |class| {
            const mutant = try allocator.dupe(u8, fixture.data);
            defer allocator.free(mutant);
            switch (class) {
                0 => mutant[soc] ^= 0x01, // sniper: one bit in mandatory SOC
                1 => mutant[soc] = 0x00, // bolter: one byte in mandatory SOC
                2 => @memset(mutant[soc..@min(mutant.len, soc + 1024)], 0x00), // shotgun
                else => unreachable,
            }
            stats.known_corrupt_by_class[class] += 1;
            if (!(try strictOutcome(allocator, mutant)).rejected) {
                stats.known_corrupt_misses_by_class[class] += 1;
                stats.known_corrupt_misses_by_family_and_class[familyClassIndex(fixture.family, class)] += 1;
            }
        }

        const entropy = entropyRange(fixture.data, soc) orelse continue;
        const middle = entropy.start + (entropy.end - entropy.start) / 2;
        for (0..3) |class| {
            const mutant = try allocator.dupe(u8, fixture.data);
            defer allocator.free(mutant);
            switch (class) {
                0 => mutant[middle] ^= 0x01,
                1 => mutant[middle] ^= 0xff,
                2 => {
                    const shotgun_start = entropy.start + (entropy.end - entropy.start) / 4;
                    @memset(mutant[shotgun_start..@min(entropy.end, shotgun_start + 1024)], 0x00);
                },
                else => unreachable,
            }
            stats.entropy_probes_by_class[class] += 1;
            if ((try strictOutcome(allocator, mutant)).rejected) {
                stats.entropy_detected_by_class[class] += 1;
                stats.entropy_detected_by_family_and_class[familyClassIndex(fixture.family, class)] += 1;
            }
        }
    }
    return stats;
}

test "strict validation classifies valid controls and known-invalid mutations over sets" {
    const stats = try runMatrix(std.testing.allocator);
    try std.testing.expectEqual(fixtures.len, stats.controls);
    try std.testing.expectEqual(@as(usize, 0), stats.false_positive_rejects);
    try std.testing.expectEqual([_]usize{ fixtures.len, fixtures.len, fixtures.len }, stats.known_corrupt_by_class);
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, stats.known_corrupt_misses_by_class);
    try std.testing.expectEqual([_]usize{ 15, 3 }, stats.controls_by_family);
    try std.testing.expectEqual([_]usize{ 0, 0 }, stats.false_positive_rejects_by_family);
    try std.testing.expectEqual([_]usize{ 2, 0 }, stats.unsupported_controls_by_family);
    try std.testing.expectEqual([_]usize{ 0, 0, 0, 0, 0, 0 }, stats.known_corrupt_misses_by_family_and_class);
    for (stats.entropy_probes_by_class) |count| try std.testing.expect(count > 0);
    // Regression floor by family × {sniper, bolter, shotgun}. Entropy changes
    // are probes rather than known-invalid files, so improvement may raise the
    // counts without invalidating the gate.
    const sensitivity_floor = [_]usize{ 11, 11, 15, 3, 3, 3 };
    for (stats.entropy_detected_by_family_and_class, sensitivity_floor) |actual, floor| {
        try std.testing.expect(actual >= floor);
    }
}

test "mutation matrix: dump measured stats when MUTATION_MATRIX_DUMP is set (scorecard source)" {
    // Not a gate: prints the measured counts that conformance/
    // MUTATION_SCORECARD.md transcribes, so the scorecard is regenerated
    // from the classifier rather than retyped. Silent unless asked.
    if (std.c.getenv("MUTATION_MATRIX_DUMP") == null) return;
    const s = try runMatrix(std.testing.allocator);
    std.debug.print(
        \\
        \\mutation-matrix: controls_by_family={any} false_positive_rejects_by_family={any} unsupported_by_family={any}
        \\mutation-matrix: known_corrupt_misses_by_family_and_class={any}
        \\mutation-matrix: entropy_detected_by_family_and_class={any} (order: codestream sniper,bolter,shotgun; jp2 sniper,bolter,shotgun)
        \\
    , .{ s.controls_by_family, s.false_positive_rejects_by_family, s.unsupported_controls_by_family, s.known_corrupt_misses_by_family_and_class, s.entropy_detected_by_family_and_class });
}
