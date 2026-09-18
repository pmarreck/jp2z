//! Probe-survivor labeller: give every ACCEPTED corruption-probe trial an
//! independent, specification-grounded label so an undetected mutation is
//! counted honestly as a false negative or as an inert byte.
//!
//! The oracle is openjpeg (an implementation jp2z's author did not write),
//! reached through `jp2z.internal.openjpegDecode`. A sniper or bolter trial
//! is replayed exactly (the events file records mode, offset and bit; the
//! mutation is a bit flip or a byte XOR 0xFF) and the mutant is decoded by
//! the oracle and by jp2z. Labels:
//!   inert           the oracle decodes the mutant to the pristine pixels:
//!                   the byte carried no image information (comment text,
//!                   an unused header field, a redundant encoding)
//!   changed         the oracle decodes to different pixels: the corruption
//!                   reached the image and jp2z did not report it — a true
//!                   false negative
//!   wrapper_refuses the packed Image contract (one precision for every
//!                   channel) refuses the mutant in both the wrapper and
//!                   jp2z.decode; opj_decompress decodes it (verified on
//!                   p0_13 with one component at 7 bits, 2026-09-18), so
//!                   this is a limit of the Image type, not a detection
//! Shotgun and truncation trials carry random windows the events do not
//! record, so only sniper and bolter are replayable; those two modes are
//! also the ones with survivors.
//!
//! Input via env (0.16 has no argsAlloc): PROBE_FIXTURE=<abs path>,
//! PROBE_EVENTS=<abs path to events.ndjson>. Output: one JSON line per
//! labelled trial on stdout, then a summary line.

const std = @import("std");
const jp2z = @import("jp2z");

const Event = struct {
    mode: []const u8,
    round: u32,
    offset: u64,
    bit: ?u8 = null,
    size: u64 = 1,
    outcome: []const u8,
};

fn readAll(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var r = file.reader(io, &.{});
    return try r.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const fx_z = std.c.getenv("PROBE_FIXTURE") orelse {
        std.debug.print("usage: PROBE_FIXTURE=<abs> PROBE_EVENTS=<abs> jp2z-probe-label\n", .{});
        std.process.exit(2);
    };
    const ev_z = std.c.getenv("PROBE_EVENTS") orelse {
        std.debug.print("usage: PROBE_FIXTURE=<abs> PROBE_EVENTS=<abs> jp2z-probe-label\n", .{});
        std.process.exit(2);
    };
    const fixture = std.mem.span(fx_z);
    const name = std.fs.path.basename(fixture);
    const data = try readAll(a, io, fixture);
    const events = try readAll(a, io, std.mem.span(ev_z));

    // Pristine reference from the oracle. A trial-level allocator keeps
    // the mutant decodes from accumulating in the arena.
    var pristine = try jp2z.internal.openjpegDecode(a, data);
    defer pristine.deinit(a);
    // jp2z's own pristine decode is the baseline for the agreement column:
    // on 9/7 fixtures jp2z legitimately differs from openjpeg by ±1, so
    // comparing a mutant's jp2z decode against the oracle's pixels would
    // read "changed" for every inert byte.
    var jz_pristine = try jp2z.decode(a, data);
    defer jz_pristine.deinit(a);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    var n_accepted: u32 = 0;
    var n_inert: u32 = 0;
    var n_changed: u32 = 0;
    var n_wrapper_refuses: u32 = 0;
    var n_unreplayable: u32 = 0;
    var it = std.mem.splitScalar(u8, events, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(Event, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        const e = parsed.value;
        if (!std.mem.eql(u8, e.outcome, "accepted")) continue;
        n_accepted += 1;
        const sniper = std.mem.eql(u8, e.mode, "sniper");
        const bolter = std.mem.eql(u8, e.mode, "bolter");
        if (!(sniper or bolter) or e.offset >= data.len) {
            n_unreplayable += 1;
            continue;
        }
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const ta = scratch.allocator();
        const mutant = try ta.dupe(u8, data);
        const off: usize = @intCast(e.offset);
        if (sniper) {
            const bit: u3 = @intCast(e.bit orelse 0);
            mutant[off] ^= @as(u8, 1) << bit;
        } else {
            mutant[off] ^= 0xFF;
        }
        var label: []const u8 = undefined;
        var diff_samples: usize = 0;
        var max_abs: u32 = 0;
        if (jp2z.internal.openjpegDecode(ta, mutant)) |m| {
            if (m.pixels.len != pristine.pixels.len or m.width != pristine.width or m.height != pristine.height) {
                label = "changed";
                diff_samples = pristine.pixels.len;
            } else {
                for (m.pixels, pristine.pixels) |x, y| if (x != y) {
                    diff_samples += 1;
                    const d: u32 = if (x > y) x - y else y - x;
                    if (d > max_abs) max_abs = d;
                };
                label = if (diff_samples == 0) "inert" else "changed";
            }
        } else |_| {
            label = "wrapper_refuses";
        }
        // Does jp2z's own decode agree with the oracle on the mutant?
        const jz: []const u8 = if (jp2z.decode(ta, mutant)) |j| blk: {
            if (label[0] == 'w') break :blk "decoded";
            var same = j.pixels.len == jz_pristine.pixels.len;
            if (same) {
                for (j.pixels, jz_pristine.pixels) |x, y| if (x != y) {
                    same = false;
                    break;
                };
            }
            break :blk if (same) "pristine" else "changed";
        } else |err| @errorName(err);
        if (std.mem.eql(u8, label, "inert")) n_inert += 1 else if (std.mem.eql(u8, label, "changed")) n_changed += 1 else n_wrapper_refuses += 1;
        try out.print("{{\"fixture\":\"{s}\",\"mode\":\"{s}\",\"round\":{d},\"offset\":{d},\"bit\":{?d},\"label\":\"{s}\",\"diff_samples\":{d},\"max_abs\":{d},\"jp2z_decode\":\"{s}\"}}\n", .{ name, e.mode, e.round, e.offset, e.bit, label, diff_samples, max_abs, jz });
    }
    try out.print("{{\"fixture\":\"{s}\",\"summary\":true,\"accepted\":{d},\"inert\":{d},\"changed\":{d},\"wrapper_refuses\":{d},\"unreplayable\":{d}}}\n", .{ name, n_accepted, n_inert, n_changed, n_wrapper_refuses, n_unreplayable });
    try out.flush();
}
