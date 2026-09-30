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
    // QCD precedes COD in the main header (legal, T.800 A.4.1): guards the
    // per-subband M_b derivation against marker order (false c255 before).
    .{ .name = "p0_01.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_01.j2k") },
    // Tile-part COD overrides (A.6.1): tiles 1 and 3 switch progression to
    // RPCL/CPRL. Was max_abs 254 with the main COD driving every tile.
    .{ .name = "d2_colr.j2c", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/d2_colr.j2c") },
    // COC / RGN per-component overrides (A.6.2 / A.6.3). Every one of these
    // was a strict FALSE POSITIVE while the markers were c145-ignored.
    .{ .name = "p0_02.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_02.j2k") },
    .{ .name = "p0_03.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_03.j2k") },
    .{ .name = "p0_06.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_06.j2k") },
    .{ .name = "p0_13.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p0_13.j2k") },
    .{ .name = "p1_01.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p1_01.j2k") },
    .{ .name = "p1_07.j2k", .family = .codestream, .data = @embedFile("unit/fixtures/conformance/p1_07.j2k") },
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
    entropy_probes_by_class: [entropy_classes]usize = @splat(0),
    entropy_detected_by_class: [entropy_classes]usize = @splat(0),
    controls_by_family: [2]usize = @splat(0),
    false_positive_rejects_by_family: [2]usize = @splat(0),
    unsupported_controls_by_family: [2]usize = @splat(0),
    known_corrupt_misses_by_family_and_class: [6]usize = @splat(0),
    entropy_detected_by_family_and_class: [2 * entropy_classes]usize = @splat(0),
};

/// Entropy-probe classes, in order: sniper (one bit), bolter (one byte XOR
/// FF), legacy-shotgun/zero-fill (1024 bytes set to 0x00; the pre-2026-09-29
/// dense operator, kept under its exact historical semantics), shotgun
/// (8..16 distinct bits in a 32-byte window), nuke (1024-byte pseudorandom
/// overwrite; the fleet default is 4096 and this matrix records 1024 because
/// its smallest entropy bodies are under 4096 bytes).
const entropy_classes = 5;
const nuke_size: usize = 1024;

fn familyClassIndex(family: Family, class: usize) usize {
    return @intFromEnum(family) * 3 + class;
}

fn familyEntropyIndex(family: Family, class: usize) usize {
    return @intFromEnum(family) * entropy_classes + class;
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

/// Deterministic stream for a mutation: ChaCha seeded by BLAKE3 of a label,
/// so a fixture name plus mode always draws the same pellets and the clock
/// never enters a test. Not the shared `random` project (an in-core test
/// stays dependency-free); the label is the replay key.
fn labelledStream(label: []const u8) std.Random.ChaCha {
    var seed: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(label, &seed, .{});
    return std.Random.ChaCha.init(seed);
}

const shotgun_window: usize = 32;
const ShotgunResult = struct { window: usize, count: u8, positions: [16]u16 };

/// Sparse shotgun (fleet mutation vocabulary, 2026-09-29): 8..16 distinct
/// bit positions inside one fully contained 32-byte window, each XOR 1, so
/// the Hamming distance equals the drawn count and nothing outside the
/// window changes. Positions are drawn without replacement by rejecting
/// repeats, and returned with the window for replay.
fn sparseShotgun(mutant: []u8, window: usize, label: []const u8) ShotgunResult {
    std.debug.assert(window + shotgun_window <= mutant.len);
    var stream = labelledStream(label);
    const rng = stream.random();
    const count: u8 = rng.intRangeAtMost(u8, 8, 16);
    var taken: [shotgun_window * 8]bool = @splat(false);
    var out: ShotgunResult = .{ .window = window, .count = count, .positions = @splat(0) };
    var drawn: u8 = 0;
    while (drawn < count) {
        const bit = rng.uintLessThan(u16, shotgun_window * 8);
        if (taken[bit]) continue;
        taken[bit] = true;
        out.positions[drawn] = bit;
        mutant[window + bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        drawn += 1;
    }
    return out;
}

/// Nuke (fleet mutation vocabulary, 2026-09-29): overwrite one fully
/// contained window with deterministic pseudorandom bytes, redrawing until
/// the replacement differs from the original so the trial is never a
/// no-op. The default is 4096 bytes; the caller records the size it used.
fn nukeOverwrite(mutant: []u8, window: usize, size: usize, label: []const u8) void {
    std.debug.assert(window + size <= mutant.len);
    var stream = labelledStream(label);
    const rng = stream.random();
    const target = mutant[window .. window + size];
    var original: [4096]u8 = undefined;
    const keep = original[0..size];
    @memcpy(keep, target);
    while (true) {
        rng.bytes(target);
        if (!std.mem.eql(u8, target, keep)) return;
    }
}

fn runMatrix(allocator: std.mem.Allocator) !Stats {
    var stats = Stats{};
    const dump_per_fixture = std.c.getenv("MUTATION_MATRIX_DUMP") != null;
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
                2 => @memset(mutant[soc..@min(mutant.len, soc + 1024)], 0x00), // legacy-shotgun/zero-fill (1024 bytes)
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
        const quarter = entropy.start + (entropy.end - entropy.start) / 4;
        for (0..entropy_classes) |class| {
            const mutant = try allocator.dupe(u8, fixture.data);
            defer allocator.free(mutant);
            switch (class) {
                0 => mutant[middle] ^= 0x01,
                1 => mutant[middle] ^= 0xff,
                2 => @memset(mutant[quarter..@min(entropy.end, quarter + 1024)], 0x00), // legacy-shotgun/zero-fill (1024 bytes)
                3 => {
                    // Sparse shotgun: the 32-byte window at the quarter point
                    // (every fixture's entropy body is longer than 32 bytes).
                    const label = try std.fmt.allocPrint(allocator, "jp2z-mutation-matrix/shotgun/{s}", .{fixture.name});
                    defer allocator.free(label);
                    _ = sparseShotgun(mutant, quarter, label);
                },
                4 => {
                    // Nuke: a 1024-byte pseudorandom overwrite at the quarter
                    // point, clipped to the body like the legacy fill.
                    const size = @min(nuke_size, entropy.end - quarter);
                    const label = try std.fmt.allocPrint(allocator, "jp2z-mutation-matrix/nuke/{s}", .{fixture.name});
                    defer allocator.free(label);
                    nukeOverwrite(mutant, quarter, size, label);
                },
                else => unreachable,
            }
            stats.entropy_probes_by_class[class] += 1;
            const detected = (try strictOutcome(allocator, mutant)).rejected;
            if (detected) {
                stats.entropy_detected_by_class[class] += 1;
                stats.entropy_detected_by_family_and_class[familyEntropyIndex(fixture.family, class)] += 1;
            }
            if (dump_per_fixture) std.debug.print("mutation-matrix: {s} entropy class {d} detected={}\n", .{ fixture.name, class, detected });
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
    try std.testing.expectEqual([_]usize{ 23, 3 }, stats.controls_by_family);
    try std.testing.expectEqual([_]usize{ 0, 0 }, stats.false_positive_rejects_by_family);
    // No control carries a valid-but-unsupported notice: file9's palette is
    // applied by decode/image.zig since 2026-09-12.
    try std.testing.expectEqual([_]usize{ 0, 0 }, stats.unsupported_controls_by_family);
    try std.testing.expectEqual([_]usize{ 0, 0, 0, 0, 0, 0 }, stats.known_corrupt_misses_by_family_and_class);
    for (stats.entropy_probes_by_class) |count| try std.testing.expect(count > 0);
    // Regression floor by family × {sniper, bolter, legacy zero-fill, shotgun,
    // nuke}. Entropy changes are probes rather than known-invalid files, so
    // improvement may raise the counts without invalidating the gate. The
    // legacy zero-fill column keeps its pre-2026-09-29 floor; the sparse
    // shotgun and nuke floors are the counts measured when they were added
    // and are never compared with the zero-fill column.
    const sensitivity_floor = [_]usize{ 15, 16, 21, 19, 22, 3, 3, 3, 3, 3 };
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
        \\mutation-matrix: entropy_detected_by_family_and_class={any} (order per family: sniper, bolter, legacy-shotgun/zero-fill 1024 B, shotgun 8..16 bits/32 B, nuke 1024 B pseudorandom; codestream then jp2)
        \\
    , .{ s.controls_by_family, s.false_positive_rejects_by_family, s.unsupported_controls_by_family, s.known_corrupt_misses_by_family_and_class, s.entropy_detected_by_family_and_class });
}

// Sparse shotgun operator (fleet mutation vocabulary, Peter 2026-09-29):
// 8..16 distinct bit positions inside one fully contained 32-byte window,
// each XOR 1. The Hamming distance equals the drawn count, nothing outside
// the window changes, and the same label always draws the same pellets.
test "sparse shotgun: 8..16 distinct bits, all inside the 32-byte window, deterministic per label" {
    var buf: [128]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i * 7 & 0xff);
    const pristine = buf;
    const r = sparseShotgun(&buf, 40, "label-a");
    try std.testing.expectEqual(@as(usize, 40), r.window);
    try std.testing.expect(r.count >= 8 and r.count <= 16);
    var hamming: usize = 0;
    for (buf, pristine, 0..) |m, p, i| {
        const d = m ^ p;
        if (i < 40 or i >= 72) try std.testing.expectEqual(@as(u8, 0), d);
        hamming += @popCount(d);
    }
    try std.testing.expectEqual(@as(usize, r.count), hamming);
    // Distinct positions: sorted copy has no adjacent equals.
    var pos = r.positions;
    std.mem.sort(u16, pos[0..r.count], {}, std.sort.asc(u16));
    var k: usize = 1;
    while (k < r.count) : (k += 1) try std.testing.expect(pos[k] != pos[k - 1]);
    // Same label, same pellets; a different label draws differently.
    var again = pristine;
    const r2 = sparseShotgun(&again, 40, "label-a");
    try std.testing.expectEqualSlices(u8, &buf, &again);
    try std.testing.expectEqual(r.count, r2.count);
    var other = pristine;
    _ = sparseShotgun(&other, 40, "label-b");
    try std.testing.expect(!std.mem.eql(u8, &buf, &other));
}
