//! Corruption-coverage statistics: turn the per-trial outcomes that
//! ./corruption-coverage collects (corruption-reader cases validated by
//! `jp2z validate --strict`) into detection rates with confidence intervals
//! and a drift test against a committed baseline. The arithmetic lives here,
//! under unit tests; the Bash driver only orchestrates processes.
//!
//! Statistics: Wilson score interval for a binomial proportion (better
//! coverage than the Wald interval near 0 and 1, where detection rates
//! live); the standard normal CDF through a Chebyshev-fitted complementary
//! error function; a one-sided two-proportion z-test with pooled variance
//! for "did the detection rate drop against the baseline?".

const std = @import("std");

/// 97.5th percentile of the standard normal: the z for a 95% interval.
pub const z95: f64 = 1.959963984540054;

pub const Interval = struct { lo: f64, hi: f64 };

/// Wilson score interval for k successes in n trials at confidence z.
/// n == 0 yields the uninformative [0, 1].
pub fn wilson(k: u64, n: u64, z: f64) Interval {
    if (n == 0) return .{ .lo = 0, .hi = 1 };
    const kf: f64 = @floatFromInt(k);
    const nf: f64 = @floatFromInt(n);
    const z2 = z * z;
    const center = (kf + z2 / 2.0) / (nf + z2);
    const half = (z / (nf + z2)) * @sqrt(kf * (nf - kf) / nf + z2 / 4.0);
    return .{ .lo = @max(0.0, center - half), .hi = @min(1.0, center + half) };
}

/// Standard normal cumulative distribution function.
pub fn normalCdf(x: f64) f64 {
    return 0.5 * erfc(-x / std.math.sqrt2);
}

/// Complementary error function, Chebyshev fit (Numerical Recipes erfcc):
/// fractional error below 1.2e-7 over the whole real line, which puts the
/// absolute error of a tail probability far below the 1e-6 these reports use.
fn erfc(x: f64) f64 {
    const ax = @abs(x);
    const t = 1.0 / (1.0 + 0.5 * ax);
    const poly = -1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277))))))));
    const ans = t * @exp(-ax * ax + poly);
    return if (x >= 0) ans else 2.0 - ans;
}

/// One-sided two-proportion z-test. Returns the probability, under the
/// null hypothesis of equal rates, of observing a candidate rate k2/n2 at
/// least as far BELOW the baseline rate k1/n1 as the one observed (small
/// values mean the candidate detects less). Returns 1 when either sample is
/// empty.
pub fn dropP(k1: u64, n1: u64, k2: u64, n2: u64) f64 {
    if (n1 == 0 or n2 == 0) return 1;
    const p1 = @as(f64, @floatFromInt(k1)) / @as(f64, @floatFromInt(n1));
    const p2 = @as(f64, @floatFromInt(k2)) / @as(f64, @floatFromInt(n2));
    const pooled = @as(f64, @floatFromInt(k1 + k2)) / @as(f64, @floatFromInt(n1 + n2));
    const variance = pooled * (1.0 - pooled) * (1.0 / @as(f64, @floatFromInt(n1)) + 1.0 / @as(f64, @floatFromInt(n2)));
    // Both samples all-detected or none-detected: the rates are equal and
    // there is no spread to measure against.
    if (variance <= 0) return 0.5;
    return normalCdf((p2 - p1) / @sqrt(variance));
}

/// Rounds per cell so the Wilson 95% half-width is at most `half_width`
/// at the worst case p = 0.5 (the Wald approximation n = z^2 / (4 h^2),
/// rounded up).
pub fn roundsForHalfWidth(half_width: f64) u64 {
    return @intFromFloat(@ceil(z95 * z95 / (4.0 * half_width * half_width)));
}

// ── Aggregation ───────────────────────────────────────────────────

/// One validated case as ./corruption-coverage records it. `status` is the
/// corruption-reader report status (`applied` or `noop`); `class` is how the
/// strict validation exit was read: `rejected` (FAIL), `flagged` (WARN),
/// `accepted` (exit 0), `crash` (signal or internal error), `timeout`.
pub const Trial = struct {
    fixture: []const u8,
    profile: []const u8,
    round: u32,
    status: []const u8,
    rc: i32,
    class: []const u8,
};

/// Detection counts for one (fixture, profile) cell. `n` counts applied
/// cases only; no-ops are listed beside it and never enter a rate. The same
/// struct is the summary record, so a committed summary file is a baseline.
pub const Cell = struct {
    fixture: []const u8,
    profile: []const u8,
    n: u64 = 0,
    detected: u64 = 0,
    rejected: u64 = 0,
    accepted: u64 = 0,
    crashes: u64 = 0,
    timeouts: u64 = 0,
    noops: u64 = 0,
};

/// Fold trial JSON Lines into cells, one per (fixture, profile) in first-seen
/// order, followed by one pooled cell per profile with fixture `(all)`.
/// Lines that do not parse as a Trial (the provenance header, blanks) are
/// skipped.
pub fn aggregate(allocator: std.mem.Allocator, lines: []const u8) ![]Cell {
    // Parsed strings borrow from `lines` (no escapes occur in fixture or
    // profile names), so the returned cells outlive the parse arena.
    var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();
    var cells = std.ArrayList(Cell).empty;
    errdefer cells.deinit(allocator);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const t = std.json.parseFromSliceLeaky(Trial, pa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed }) catch continue;
        const cell = try findOrAdd(&cells, allocator, t.fixture, t.profile);
        fold(cell, t);
    }
    // Pooled rows: one per profile, in first-seen order.
    const per_fixture = cells.items.len;
    var i: usize = 0;
    while (i < per_fixture) : (i += 1) {
        const profile = cells.items[i].profile;
        var seen = false;
        var j: usize = per_fixture;
        while (j < cells.items.len) : (j += 1) {
            if (std.mem.eql(u8, cells.items[j].profile, profile)) seen = true;
        }
        if (seen) continue;
        var pooled: Cell = .{ .fixture = "(all)", .profile = profile };
        var k: usize = 0;
        while (k < per_fixture) : (k += 1) {
            const c = cells.items[k];
            if (!std.mem.eql(u8, c.profile, profile)) continue;
            pooled.n += c.n;
            pooled.detected += c.detected;
            pooled.rejected += c.rejected;
            pooled.accepted += c.accepted;
            pooled.crashes += c.crashes;
            pooled.timeouts += c.timeouts;
            pooled.noops += c.noops;
        }
        try cells.append(allocator, pooled);
    }
    return cells.toOwnedSlice(allocator);
}

fn findOrAdd(cells: *std.ArrayList(Cell), allocator: std.mem.Allocator, fixture: []const u8, profile: []const u8) !*Cell {
    for (cells.items) |*c| {
        if (std.mem.eql(u8, c.fixture, fixture) and std.mem.eql(u8, c.profile, profile)) return c;
    }
    try cells.append(allocator, .{ .fixture = fixture, .profile = profile });
    return &cells.items[cells.items.len - 1];
}

fn fold(cell: *Cell, t: Trial) void {
    if (std.mem.eql(u8, t.status, "noop")) {
        cell.noops += 1;
        return;
    }
    cell.n += 1;
    if (std.mem.eql(u8, t.class, "rejected")) {
        cell.rejected += 1;
        cell.detected += 1;
    } else if (std.mem.eql(u8, t.class, "flagged")) {
        cell.detected += 1;
    } else if (std.mem.eql(u8, t.class, "accepted")) {
        cell.accepted += 1;
    } else if (std.mem.eql(u8, t.class, "crash")) {
        cell.crashes += 1;
    } else if (std.mem.eql(u8, t.class, "timeout")) {
        cell.timeouts += 1;
    }
}

/// Drift verdict for a cell against its baseline at the 5% one-sided level.
pub const Drift = enum { none, drop, rise, no_baseline };

pub fn drift(base: ?Cell, cur: Cell) Drift {
    const b = base orelse return .no_baseline;
    const p = dropP(b.detected, b.n, cur.detected, cur.n);
    if (p < 0.05) return .drop;
    if (p > 0.95) return .rise;
    return .none;
}

/// Parse a committed summary file (JSON Lines of Cell records; the first
/// line is a provenance header and is skipped) into cells. Strings borrow
/// from `lines`.
pub fn parseSummary(allocator: std.mem.Allocator, lines: []const u8) ![]Cell {
    var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();
    var cells = std.ArrayList(Cell).empty;
    errdefer cells.deinit(allocator);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const c = std.json.parseFromSliceLeaky(Cell, pa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed }) catch continue;
        try cells.append(allocator, c);
    }
    return cells.toOwnedSlice(allocator);
}

fn findCell(cells: []const Cell, fixture: []const u8, profile: []const u8) ?Cell {
    for (cells) |c| if (std.mem.eql(u8, c.fixture, fixture) and std.mem.eql(u8, c.profile, profile)) return c;
    return null;
}

fn readAll(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var r = file.reader(io, &.{});
    return try r.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
}

fn pct(k: u64, n: u64) f64 {
    if (n == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
}

/// Input via env (0.16 has no argsAlloc): COVERAGE_TRIALS=<abs path to the
/// per-trial JSON Lines>, COVERAGE_SUMMARY=<abs path to write the summary
/// JSON Lines>, optional COVERAGE_BASELINE=<abs path to a previous summary>.
/// Stdout: the Markdown table and the statistical note. Exit 1 when any
/// cell crashed or timed out, or any cell's detection rate dropped against
/// the baseline at the 5% one-sided level; 2 on usage errors.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const usage = "usage: COVERAGE_TRIALS=<abs> COVERAGE_SUMMARY=<abs> [COVERAGE_BASELINE=<abs>] jp2z-coverage-stats\n";
    const trials_z = std.c.getenv("COVERAGE_TRIALS") orelse {
        std.debug.print(usage, .{});
        std.process.exit(2);
    };
    const summary_z = std.c.getenv("COVERAGE_SUMMARY") orelse {
        std.debug.print(usage, .{});
        std.process.exit(2);
    };
    const trials = try readAll(a, io, std.mem.span(trials_z));
    const cells = try aggregate(a, trials);
    var baseline: []Cell = &.{};
    if (std.c.getenv("COVERAGE_BASELINE")) |b_z| {
        const b_path = std.mem.span(b_z);
        if (readAll(a, io, b_path)) |b_lines| {
            baseline = try parseSummary(a, b_lines);
        } else |_| {
            std.debug.print("coverage-stats: baseline {s} not readable; drift column left empty\n", .{b_path});
        }
    }

    var stdout_buf: [16384]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    var sum_file = try std.Io.Dir.cwd().createFile(io, std.mem.span(summary_z), .{});
    defer sum_file.close(io);
    var sum_buf: [16384]u8 = undefined;
    var sum_w = sum_file.writer(io, &sum_buf);
    const sum = &sum_w.interface;

    try out.print("| Fixture | Profile | Trials | Detected (WARN or FAIL) | Wilson 95% | FAIL only | Crash / timeout | No-op | Baseline | Drift (one-sided p) |\n|---|---|---:|---:|---|---:|---:|---:|---:|---|\n", .{});
    var any_drop = false;
    var any_crash = false;
    for (cells) |c| {
        const ci = wilson(c.detected, c.n, z95);
        const base = findCell(baseline, c.fixture, c.profile);
        const d = drift(base, c);
        if (d == .drop) any_drop = true;
        if (c.crashes + c.timeouts > 0) any_crash = true;
        try out.print("| {s} | {s} | {d} | {d} ({d:.1}%) | {d:.1}% to {d:.1}% | {d} ({d:.1}%) | {d} / {d} | {d} | ", .{ c.fixture, c.profile, c.n, c.detected, pct(c.detected, c.n), 100.0 * ci.lo, 100.0 * ci.hi, c.rejected, pct(c.rejected, c.n), c.crashes, c.timeouts, c.noops });
        if (base) |b| {
            const p = dropP(b.detected, b.n, c.detected, c.n);
            try out.print("{d}/{d} ({d:.1}%) | {s} (p = {d:.4}) |\n", .{ b.detected, b.n, pct(b.detected, b.n), @tagName(d), p });
        } else {
            try out.print("none | no baseline |\n", .{});
        }
        try sum.print("{{\"fixture\":\"{s}\",\"profile\":\"{s}\",\"n\":{d},\"detected\":{d},\"rejected\":{d},\"accepted\":{d},\"crashes\":{d},\"timeouts\":{d},\"noops\":{d},\"rate\":{d:.4},\"wilson_lo\":{d:.4},\"wilson_hi\":{d:.4},\"drift\":\"{s}\"}}\n", .{ c.fixture, c.profile, c.n, c.detected, c.rejected, c.accepted, c.crashes, c.timeouts, c.noops, pct(c.detected, c.n) / 100.0, ci.lo, ci.hi, @tagName(d) });
    }
    try out.print("\nStatistics: \"Detected\" counts strict exits of WARN or FAIL over applied cases (no-ops never enter a rate). Intervals are Wilson score intervals at 95%. \"Drift\" is a one-sided two-proportion z-test (pooled variance) against the committed baseline: drop means p < 0.05 that the rate is unchanged given the fall observed, rise means p > 0.95. At the worst case p = 0.5 the 95% half-width is at most 5 points with {d} rounds, 10 points with {d}, 2 points with {d}.\n", .{ roundsForHalfWidth(0.05), roundsForHalfWidth(0.10), roundsForHalfWidth(0.02) });
    if (any_crash) try out.print("\nVERDICT: crash or timeout observed (counted separately from detection; replay the listed rounds).\n", .{});
    if (any_drop) try out.print("\nVERDICT: detection rate dropped against the baseline in at least one cell.\n", .{});
    if (!any_crash and !any_drop) {
        if (baseline.len == 0) {
            try out.print("\nVERDICT: no crashes; no baseline to compare against (this run becomes the baseline).\n", .{});
        } else {
            try out.print("\nVERDICT: no crashes, no significant drop against the baseline.\n", .{});
        }
    }
    try out.flush();
    try sum.flush();
    if (any_crash or any_drop) std.process.exit(1);
}

test "wilson: k = n gives an interval reaching 1 whose lower bound rises with n; k = 0 mirrors it" {
    const full10 = wilson(10, 10, z95);
    const full100 = wilson(100, 100, z95);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), full10.hi, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), full100.hi, 1e-12);
    try std.testing.expect(full100.lo > full10.lo);
    // Known value: 10/10 at 95% → lower bound 0.7225 (Wilson, no continuity correction).
    try std.testing.expectApproxEqAbs(@as(f64, 0.7225), full10.lo, 5e-4);
    const none10 = wilson(0, 10, z95);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), none10.lo, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) - full10.lo, none10.hi, 1e-12);
}

test "wilson: 50/100 at 95% is [0.4038, 0.5962]; n = 0 is [0, 1]" {
    const half = wilson(50, 100, z95);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4038), half.lo, 5e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5962), half.hi, 5e-4);
    const empty = wilson(0, 0, z95);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), empty.lo, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), empty.hi, 1e-12);
}

test "normalCdf: 0 → 0.5, 1.959964 → 0.975, -1.644854 → 0.05, symmetric, within 1e-6" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), normalCdf(0), 1e-7); // erfc fit: 1.2e-7 fractional error
    try std.testing.expectApproxEqAbs(@as(f64, 0.975), normalCdf(z95), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), normalCdf(-1.6448536269514722), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8413447460685429), normalCdf(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), normalCdf(2.5) + normalCdf(-2.5), 1e-9);
}

test "dropP: equal rates → 0.5; 95/100 falling to 80/100 → about 0.00067; a rise gives p above 0.5; empty samples → 1" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), dropP(50, 100, 50, 100), 1e-7);
    // pooled p = 0.875, se = sqrt(0.875 * 0.125 * 0.02) = 0.046771, z = -0.15 / se = -3.2071 → Φ = 0.000670.
    try std.testing.expectApproxEqAbs(@as(f64, 0.000670), dropP(95, 100, 80, 100), 2e-5);
    try std.testing.expect(dropP(80, 100, 95, 100) > 0.99);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dropP(0, 0, 5, 10), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dropP(5, 10, 0, 0), 1e-12);
}

test "roundsForHalfWidth: ±5 points needs 385 rounds, ±10 needs 97, ±2 needs 2401" {
    try std.testing.expectEqual(@as(u64, 385), roundsForHalfWidth(0.05));
    try std.testing.expectEqual(@as(u64, 97), roundsForHalfWidth(0.10));
    try std.testing.expectEqual(@as(u64, 2401), roundsForHalfWidth(0.02));
}

test "aggregate: cells per (fixture, profile) in first-seen order, no-ops outside n, detected = flagged + rejected, crashes and timeouts counted; header line skipped; pooled (all) rows per profile" {
    const a = std.testing.allocator;
    const lines =
        \\{"corruption_coverage":1,"seed":"0x2a","rounds":3}
        \\{"fixture":"a1_mono.j2c","profile":"sniper","round":0,"status":"applied","rc":1,"class":"rejected"}
        \\{"fixture":"a1_mono.j2c","profile":"sniper","round":1,"status":"applied","rc":2,"class":"flagged"}
        \\{"fixture":"a1_mono.j2c","profile":"sniper","round":2,"status":"applied","rc":0,"class":"accepted"}
        \\{"fixture":"a1_mono.j2c","profile":"nuke","round":0,"status":"noop","rc":0,"class":"accepted"}
        \\{"fixture":"a1_mono.j2c","profile":"nuke","round":1,"status":"applied","rc":139,"class":"crash"}
        \\{"fixture":"a1_mono.j2c","profile":"nuke","round":2,"status":"applied","rc":124,"class":"timeout"}
        \\{"fixture":"p0_09.j2k","profile":"sniper","round":0,"status":"applied","rc":1,"class":"rejected"}
        \\
    ;
    const cells = try aggregate(a, lines);
    defer a.free(cells);
    try std.testing.expectEqual(@as(usize, 5), cells.len);
    try std.testing.expectEqualStrings("a1_mono.j2c", cells[0].fixture);
    try std.testing.expectEqualStrings("sniper", cells[0].profile);
    try std.testing.expectEqual(@as(u64, 3), cells[0].n);
    try std.testing.expectEqual(@as(u64, 2), cells[0].detected);
    try std.testing.expectEqual(@as(u64, 1), cells[0].rejected);
    try std.testing.expectEqual(@as(u64, 1), cells[0].accepted);
    try std.testing.expectEqualStrings("nuke", cells[1].profile);
    try std.testing.expectEqual(@as(u64, 2), cells[1].n);
    try std.testing.expectEqual(@as(u64, 1), cells[1].noops);
    try std.testing.expectEqual(@as(u64, 1), cells[1].crashes);
    try std.testing.expectEqual(@as(u64, 1), cells[1].timeouts);
    try std.testing.expectEqual(@as(u64, 0), cells[1].detected);
    try std.testing.expectEqualStrings("p0_09.j2k", cells[2].fixture);
    // Pooled rows follow the per-fixture rows, one per profile in first-seen order.
    try std.testing.expectEqualStrings("(all)", cells[3].fixture);
    try std.testing.expectEqualStrings("sniper", cells[3].profile);
    try std.testing.expectEqual(@as(u64, 4), cells[3].n);
    try std.testing.expectEqual(@as(u64, 3), cells[3].detected);
    try std.testing.expectEqualStrings("(all)", cells[4].fixture);
    try std.testing.expectEqualStrings("nuke", cells[4].profile);
    try std.testing.expectEqual(@as(u64, 1), cells[4].noops);
}

test "drift: no baseline → no_baseline; 95/100 → 80/100 is a drop; 95/100 → 94/100 is none; 80/100 → 95/100 is a rise" {
    const cur_drop: Cell = .{ .fixture = "x", .profile = "sniper", .n = 100, .detected = 80 };
    const base: Cell = .{ .fixture = "x", .profile = "sniper", .n = 100, .detected = 95 };
    try std.testing.expectEqual(Drift.no_baseline, drift(null, cur_drop));
    try std.testing.expectEqual(Drift.drop, drift(base, cur_drop));
    const cur_same: Cell = .{ .fixture = "x", .profile = "sniper", .n = 100, .detected = 94 };
    try std.testing.expectEqual(Drift.none, drift(base, cur_same));
    const base_low: Cell = .{ .fixture = "x", .profile = "sniper", .n = 100, .detected = 80 };
    try std.testing.expectEqual(Drift.rise, drift(base_low, base));
}

test "parseSummary: the provenance header is skipped and Cell records round-trip with extra fields ignored" {
    const a = std.testing.allocator;
    const lines =
        \\{"corruption_coverage":1,"seed":"0x2a"}
        \\{"fixture":"a1_mono.j2c","profile":"sniper","n":200,"detected":190,"rejected":150,"accepted":10,"crashes":0,"timeouts":0,"noops":0,"rate":0.95,"wilson_lo":0.91,"wilson_hi":0.97,"drift":"none"}
        \\{"fixture":"(all)","profile":"sniper","n":200,"detected":190,"rejected":150,"accepted":10,"crashes":0,"timeouts":0,"noops":0}
        \\
    ;
    const cells = try parseSummary(a, lines);
    defer a.free(cells);
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqualStrings("a1_mono.j2c", cells[0].fixture);
    try std.testing.expectEqual(@as(u64, 190), cells[0].detected);
    try std.testing.expectEqualStrings("(all)", cells[1].fixture);
}
