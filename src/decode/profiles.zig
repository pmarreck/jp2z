//! Profile checks: what a codestream's Rsiz CLAIMS versus what it does.
//!
//! Rsiz (SIZ, T.800 Table A.10 plus amendments) names a profile; each
//! profile is a table of restrictions on SIZ, COD/COC, QCD, RGN, markers
//! and tile-part layout (Table A.45 for Profiles 0/1; the digital cinema,
//! broadcast and IMF amendments for the rest; transcribed in
//! docs/T800_PROFILES.md). A claimed profile that is violated is a proven
//! nonconformance of the codestream to its own declaration: finding 259
//! profile_violation, FAIL. Rules that need information outside the
//! codestream (broadcast/IMF rate and level limits, cinema bitrate per
//! frame) are not checked and the profile is reported as partially
//! verified (c145). Rsiz is a family code for broadcast (main level in
//! the low nibble) and IMF (sub level and main level), never an enum.
const std = @import("std");
const Allocator = std.mem.Allocator;
const codestream = @import("codestream.zig");
const CodingParams = codestream.CodingParams;
const ValidationReport = codestream.ValidationReport;

pub const Kind = enum {
    none, profile0, profile1,
    cinema2k, cinema4k, scinema2k, scinema4k, lts,
    bc_single, bc_multi, bc_multi_r,
    imf_2k, imf_4k, imf_8k, imf_2k_r, imf_4k_r, imf_8k_r,
    part2, htj2k, undefined,
};

/// Table A.10 with the amendment families (docs/T800_PROFILES.md).
pub fn classify(rsiz: u16) Kind {
    if (rsiz & 0x8000 != 0) return .part2;
    if (rsiz & 0x4000 != 0) return .htj2k;
    switch (rsiz) {
        0 => return .none,
        1 => return .profile0,
        2 => return .profile1,
        3 => return .cinema2k,
        4 => return .cinema4k,
        5 => return .scinema2k,
        6 => return .scinema4k,
        7 => return .lts,
        0x0306, 0x0307 => return .bc_multi_r,
        else => {},
    }
    const hi = rsiz & 0xFF00;
    const ml = rsiz & 0x000F;
    const sl = (rsiz & 0x00F0) >> 4;
    if ((hi == 0x0100 or hi == 0x0200) and sl == 0 and ml >= 1 and ml <= 7) return if (hi == 0x0100) .bc_single else .bc_multi;
    if (hi >= 0x0400 and hi <= 0x0900 and ml >= 1 and ml <= 11 and sl <= 9) {
        return switch (hi) {
            0x0400 => .imf_2k,
            0x0500 => .imf_4k,
            0x0600 => .imf_8k,
            0x0700 => .imf_2k_r,
            0x0800 => .imf_4k_r,
            else => .imf_8k_r,
        };
    }
    return .undefined;
}

pub fn name(k: Kind) []const u8 {
    return switch (k) {
        .none => "no profile",
        .profile0 => "Profile 0",
        .profile1 => "Profile 1",
        .cinema2k => "2K Digital Cinema",
        .cinema4k => "4K Digital Cinema",
        .scinema2k => "Scalable 2K Digital Cinema",
        .scinema4k => "Scalable 4K Digital Cinema",
        .lts => "Long-term Storage",
        .bc_single => "Broadcast Contribution Single Tile",
        .bc_multi => "Broadcast Contribution Multi-tile",
        .bc_multi_r => "Broadcast Contribution Multi-tile Reversible",
        .imf_2k => "2K IMF Single Tile Lossy",
        .imf_4k => "4K IMF Single Tile Lossy",
        .imf_8k => "8K IMF Single Tile Lossy",
        .imf_2k_r => "2K IMF Reversible",
        .imf_4k_r => "4K IMF Reversible",
        .imf_8k_r => "8K IMF Reversible",
        .part2 => "Part 2",
        .htj2k => "HTJ2K",
        .undefined => "undefined",
    };
}

/// Facts the main-header walk knows that CodingParams does not carry.
pub const MainFacts = struct {
    has_ppm: bool = false,
    has_tlm: bool = false,
    has_rgn: bool = false,
};

/// Restrictions that apply per tile-part (checked in walkTileParts).
pub const TilePartRules = struct {
    /// COD, COC, QCD, QCC only in the main header.
    main_header_only: bool = false,
    /// PPT prohibited.
    no_ppt: bool = false,
    /// All TPsot=0 tile-parts first, in tile order (Profile 0).
    tpsot_order: bool = false,
};

pub fn tilePartRules(k: Kind) TilePartRules {
    return switch (k) {
        .profile0 => .{ .main_header_only = true, .no_ppt = true, .tpsot_order = true },
        .cinema2k, .cinema4k, .scinema2k, .scinema4k, .lts => .{ .main_header_only = true, .no_ppt = true },
        .imf_2k, .imf_4k, .imf_8k, .imf_2k_r, .imf_4k_r, .imf_8k_r => .{ .main_header_only = true, .no_ppt = true },
        else => .{},
    };
}

fn fail(report: *ValidationReport, allocator: Allocator, k: Kind, pos: u64, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    var buf: [192]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    var out: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&out, "{s}: {s}", .{ name(k), body }) catch body;
    try codestream.emit(report, allocator, .fail, .profile_violation, pos, detail);
}

inline fn ceilDiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

/// Largest tile extent on the reference grid (the image itself when one
/// tile covers it), used for the lowest-resolution and precinct rules.
fn tileExtent(cp: *const CodingParams, xsiz: u32, ysiz: u32) struct { w: u32, h: u32, single: bool } {
    const nt = cp.numTilesXY(xsiz, ysiz);
    const single = nt.x == 1 and nt.y == 1;
    if (single) return .{ .w = xsiz - cp.image_x0, .h = ysiz - cp.image_y0, .single = true };
    return .{ .w = cp.tile_w, .h = cp.tile_h, .single = false };
}

/// Main-header rules for the claimed profile. `pos` anchors the findings
/// (the SOT that ends the main header). Returns true when every checkable
/// rule was verified, false when the profile has rules outside the
/// codestream's evidence (the caller reports it as partially verified).
pub fn checkMainHeader(report: *ValidationReport, allocator: Allocator, cp: *const CodingParams, image_w: u32, image_h: u32, facts: MainFacts, pos: u64) Allocator.Error!bool {
    const k = classify(cp.rsiz);
    const xsiz = cp.image_x0 + image_w;
    const ysiz = cp.image_y0 + image_h;
    const ncomp: usize = @min(@as(usize, cp.num_components), 16);
    const ext = tileExtent(cp, xsiz, ysiz);
    switch (k) {
        .none, .part2, .htj2k, .undefined => return true,
        .profile0, .profile1 => {
            // Table A.45.
            if (xsiz >= 0x80000000 or ysiz >= 0x80000000) try fail(report, allocator, k, pos, "Xsiz and Ysiz must be below 2^31 (Table A.45)", .{});
            if (k == .profile0) {
                if (cp.image_x0 != 0 or cp.image_y0 != 0 or cp.tile_x0 != 0 or cp.tile_y0 != 0) try fail(report, allocator, k, pos, "image and tile origin must be 0 (Table A.45)", .{});
                if (!ext.single and !(cp.tile_w == 128 and cp.tile_h == 128)) try fail(report, allocator, k, pos, "tiles must be 128x128 or one tile covering the image (Table A.45)", .{});
            } else {
                if (cp.image_x0 >= 0x80000000 or cp.image_y0 >= 0x80000000 or cp.tile_x0 >= 0x80000000 or cp.tile_y0 >= 0x80000000) try fail(report, allocator, k, pos, "origins must be below 2^31 (Table A.45)", .{});
                // Table A.45 Profile 1 tile rule, read as: square tiles of at most
                // 1024 samples in the finest-sampled component, or one tile
                // covering the image. ISO p1_04 (128x128 tiles) and p1_06 (3x3)
                // are Profile 1, so the "at least 1024" transcription cannot be
                // the rule; the sampling-normalised bound is an upper bound.
                if (!ext.single) {
                    var min_dx: u32 = std.math.maxInt(u32);
                    var c0: usize = 0;
                    while (c0 < ncomp) : (c0 += 1) min_dx = @min(min_dx, cp.comp_dx[c0]);
                    if (cp.tile_w != cp.tile_h) try fail(report, allocator, k, pos, "tiles must be square unless one tile covers the image (Table A.45)", .{});
                    if (cp.tile_w / min_dx > 1024) try fail(report, allocator, k, pos, "tile exceeds 1024 samples in the finest component (Table A.45)", .{});
                }
            }
            var c: usize = 0;
            while (c < ncomp) : (c += 1) {
                const cc = cp.codingFor(@intCast(c));
                const dx = cp.comp_dx[c];
                const dy = cp.comp_dy[c];
                if (cp.roishiftFor(@intCast(c)) > 37) try fail(report, allocator, k, pos, "component {d}: RGN shift {d} exceeds 37 (Table A.45)", .{ c, cp.roishiftFor(@intCast(c)) });
                if (k == .profile0) {
                    if (!(dx == 1 or dx == 2 or dx == 4) or !(dy == 1 or dy == 2 or dy == 4)) try fail(report, allocator, k, pos, "component {d}: sub-sampling {d}x{d} is not 1, 2 or 4 (Table A.45)", .{ c, dx, dy });
                    if (cc.cblk_width_exp != cc.cblk_height_exp or (cc.cblk_width_exp != 3 and cc.cblk_width_exp != 4)) try fail(report, allocator, k, pos, "component {d}: code-block must be 32x32 or 64x64 (Table A.45)", .{c});
                    if (cc.cblksty & 0x0B != 0) try fail(report, allocator, k, pos, "component {d}: code-block style uses BYPASS, RESET or VSC (Table A.45)", .{c});
                } else {
                    if (cc.cblk_width_exp > 4 or cc.cblk_height_exp > 4) try fail(report, allocator, k, pos, "component {d}: code-block dimension exceeds 64 (Table A.45)", .{c});
                }
                // Lowest resolution at most 128x128 (per tile).
                const tcw = ceilDiv(ext.w, dx);
                const tch = ceilDiv(ext.h, dy);
                const shift: u6 = @intCast(cc.num_decomp_levels);
                const llw = (@as(u64, tcw) + (@as(u64, 1) << shift) - 1) >> shift;
                const llh = (@as(u64, tch) + (@as(u64, 1) << shift) - 1) >> shift;
                if (llw > 128 or llh > 128) try fail(report, allocator, k, pos, "component {d}: lowest resolution {d}x{d} exceeds 128x128 (Table A.45)", .{ c, llw, llh });
                if (k == .profile0) {
                    // One precinct per resolution of at most 128x128 (origin 0:
                    // precincts = ceil(res / 2^PP)).
                    var r: u8 = 0;
                    while (r <= cc.num_decomp_levels) : (r += 1) {
                        const lv: u6 = @intCast(cc.num_decomp_levels - r);
                        const rw = (@as(u64, tcw) + (@as(u64, 1) << lv) - 1) >> lv;
                        const rh = (@as(u64, tch) + (@as(u64, 1) << lv) - 1) >> lv;
                        if (rw <= 128 and rh <= 128) {
                            const ppx: u6 = @intCast(cc.precinct_sizes[r].x_exp);
                            const ppy: u6 = @intCast(cc.precinct_sizes[r].y_exp);
                            if (rw > (@as(u64, 1) << ppx) or rh > (@as(u64, 1) << ppy)) try fail(report, allocator, k, pos, "component {d} resolution {d}: more than one precinct in a resolution of at most 128x128 (Table A.45)", .{ c, r });
                        }
                    }
                }
            }
            if (k == .profile0) {
                if (facts.has_ppm) try fail(report, allocator, k, pos, "PPM is prohibited (Table A.45)", .{});
                if (cp.num_pocs > 0 and (cp.pocs[0].rs != 0 or cp.pocs[0].cs != 0)) try fail(report, allocator, k, pos, "first POC entry must have RSpoc 0 and CSpoc 0 (Table A.45)", .{});
            }
            return true;
        },
        .cinema2k, .cinema4k, .scinema2k, .scinema4k, .lts => {
            const max_w: u32 = switch (k) { .cinema2k, .scinema2k => 2048, .cinema4k, .scinema4k => 4096, else => 16384 };
            const max_h: u32 = switch (k) { .cinema2k, .scinema2k => 1080, .cinema4k, .scinema4k => 2160, else => 8640 };
            if (image_w > max_w or image_h > max_h) try fail(report, allocator, k, pos, "image {d}x{d} exceeds {d}x{d}", .{ image_w, image_h, max_w, max_h });
            if (k == .lts) {
                if (cp.num_components > 8) try fail(report, allocator, k, pos, "{d} components exceed 8", .{cp.num_components});
            } else {
                if (cp.num_components != 3) try fail(report, allocator, k, pos, "{d} components; the profile requires exactly 3", .{cp.num_components});
                var c: usize = 0;
                while (c < ncomp) : (c += 1) {
                    if (cp.comp_dx[c] != 1 or cp.comp_dy[c] != 1) try fail(report, allocator, k, pos, "component {d}: sub-sampling must be 1x1", .{c});
                    if (cp.comp_prec[c] != 12 or (cp.comp_signed >> @intCast(c)) & 1 != 0) try fail(report, allocator, k, pos, "component {d}: must be 12-bit unsigned", .{c});
                }
            }
            if (cp.image_x0 != 0 or cp.image_y0 != 0 or cp.tile_x0 != 0 or cp.tile_y0 != 0) try fail(report, allocator, k, pos, "image and tile origin must be 0", .{});
            if (k == .lts) {
                if (!ext.single and (cp.tile_w < 1024 or cp.tile_h < 512)) try fail(report, allocator, k, pos, "tiles must be at least 1024x512 or one tile covering the image", .{});
            } else if (!ext.single) try fail(report, allocator, k, pos, "one tile must cover the image", .{});
            if (facts.has_rgn) try fail(report, allocator, k, pos, "RGN is prohibited", .{});
            if (facts.has_ppm) try fail(report, allocator, k, pos, "PPM is prohibited", .{});
            if (cp.progression_order != .cprl) try fail(report, allocator, k, pos, "progression order must be CPRL", .{});
            const layers_ok = switch (k) { .cinema2k, .cinema4k => cp.num_layers == 1, .scinema2k, .scinema4k => cp.num_layers == 2, else => cp.num_layers <= 5 };
            if (!layers_ok) try fail(report, allocator, k, pos, "{d} quality layer(s); the profile allows {s}", .{ cp.num_layers, switch (k) { .cinema2k, .cinema4k => "exactly 1", .scinema2k, .scinema4k => "exactly 2", else => "at most 5" } });
            const max_levels: u8 = switch (k) { .cinema2k, .scinema2k => 5, .cinema4k, .scinema4k => 6, else => 32 };
            var c: usize = 0;
            while (c < ncomp) : (c += 1) {
                const cc = cp.codingFor(@intCast(c));
                if (k != .lts and (cc.cblk_width_exp != 3 or cc.cblk_height_exp != 3)) try fail(report, allocator, k, pos, "component {d}: code-block must be 32x32", .{c});
                if (cc.num_decomp_levels > max_levels) try fail(report, allocator, k, pos, "component {d}: {d} decomposition levels exceed {d}", .{ c, cc.num_decomp_levels, max_levels });
            }
            if (k == .scinema2k or k == .scinema4k) {
                if (cp.scod & 0x06 != 0) try fail(report, allocator, k, pos, "SOP and EPH are prohibited", .{});
                if (cp.scod & 0x01 == 0) try fail(report, allocator, k, pos, "precincts must be explicitly defined", .{});
            }
            if (k == .lts and cp.scod & 0x04 == 0) try fail(report, allocator, k, pos, "EPH is required", .{});
            return false; // per-frame bitrate limits are not checkable here
        },
        .bc_single, .bc_multi, .bc_multi_r => {
            if (cp.progression_order != .cprl) try fail(report, allocator, k, pos, "progression order must be CPRL", .{});
            if (!facts.has_tlm) try fail(report, allocator, k, pos, "TLM is required", .{});
            if (k == .bc_single and !ext.single) try fail(report, allocator, k, pos, "one tile must cover the image", .{});
            return false; // main-level sampling and bitrate limits need the frame rate
        },
        .imf_2k, .imf_4k, .imf_8k, .imf_2k_r, .imf_4k_r, .imf_8k_r => {
            const max_w: u32 = switch (k) { .imf_2k, .imf_2k_r => 2048, .imf_4k, .imf_4k_r => 4096, else => 8192 };
            const max_h: u32 = switch (k) { .imf_2k, .imf_2k_r => 1556, .imf_4k, .imf_4k_r => 3112, else => 6224 };
            const max_levels: u8 = switch (k) { .imf_2k, .imf_2k_r => 5, .imf_4k, .imf_4k_r => 6, else => 7 };
            if (image_w > max_w or image_h > max_h) try fail(report, allocator, k, pos, "image {d}x{d} exceeds {d}x{d} (Table A.51)", .{ image_w, image_h, max_w, max_h });
            const lossy = k == .imf_2k or k == .imf_4k or k == .imf_8k;
            if (lossy and !ext.single) try fail(report, allocator, k, pos, "one tile must cover the image (Table A.51)", .{});
            if (cp.image_x0 != 0 or cp.image_y0 != 0 or cp.tile_x0 != 0 or cp.tile_y0 != 0) try fail(report, allocator, k, pos, "image and tile origin must be 0", .{});
            if (cp.num_components > 3) try fail(report, allocator, k, pos, "{d} components exceed 3", .{cp.num_components});
            if (facts.has_rgn) try fail(report, allocator, k, pos, "RGN is prohibited", .{});
            if (facts.has_ppm) try fail(report, allocator, k, pos, "PPM is prohibited", .{});
            var levels0: ?u8 = null;
            var c: usize = 0;
            while (c < ncomp) : (c += 1) {
                const cc = cp.codingFor(@intCast(c));
                if (cp.comp_prec[c] < 8 or cp.comp_prec[c] > 16 or (cp.comp_signed >> @intCast(c)) & 1 != 0) try fail(report, allocator, k, pos, "component {d}: must be unsigned 8 to 16 bits", .{c});
                if (cp.comp_dy[c] != 1) try fail(report, allocator, k, pos, "component {d}: YRsiz must be 1", .{c});
                const want_dx: u32 = if (c == 0) 1 else cp.comp_dx[1];
                if (cp.comp_dx[c] != want_dx or (cp.comp_dx[c] != 1 and cp.comp_dx[c] != 2)) try fail(report, allocator, k, pos, "component {d}: XRsiz must be 1 for all components, or 1 then 2 for the rest", .{c});
                if (levels0 == null) levels0 = cc.num_decomp_levels else if (cc.num_decomp_levels != levels0.?) try fail(report, allocator, k, pos, "component {d}: decomposition levels differ from component 0", .{c});
                if (cc.num_decomp_levels > max_levels) try fail(report, allocator, k, pos, "component {d}: {d} decomposition levels exceed {d} (Table A.51)", .{ c, cc.num_decomp_levels, max_levels });
            }
            return false; // main/sub level throughput and size limits need the frame rate
        },
    }
}

test "classify: Table A.10 families" {
    try std.testing.expectEqual(Kind.none, classify(0));
    try std.testing.expectEqual(Kind.profile0, classify(1));
    try std.testing.expectEqual(Kind.profile1, classify(2));
    try std.testing.expectEqual(Kind.lts, classify(7));
    try std.testing.expectEqual(Kind.bc_single, classify(0x0101));
    try std.testing.expectEqual(Kind.bc_multi, classify(0x0207));
    try std.testing.expectEqual(Kind.undefined, classify(0x0108)); // mainlevel 8 is not defined
    try std.testing.expectEqual(Kind.undefined, classify(0x0301)); // reversible only at 6/7
    try std.testing.expectEqual(Kind.bc_multi_r, classify(0x0307));
    try std.testing.expectEqual(Kind.imf_2k, classify(0x0445)); // sublevel 4, mainlevel 5
    try std.testing.expectEqual(Kind.imf_8k_r, classify(0x0901));
    try std.testing.expectEqual(Kind.undefined, classify(0x0400)); // mainlevel 0
    try std.testing.expectEqual(Kind.part2, classify(0x8000));
    try std.testing.expectEqual(Kind.htj2k, classify(0x4000));
    try std.testing.expectEqual(Kind.undefined, classify(0x000A));
}
