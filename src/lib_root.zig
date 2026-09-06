//! Root of the STATIC LIBRARY artifact (libjp2z.a) — and ONLY that
//! artifact. Re-exports the public API and force-links the C ABI so its
//! `export fn`s land in the archive. This lives OUTSIDE src/jp2z.zig on
//! purpose: force-linking the C ABI from the importable module root made
//! every plain Zig consumer (e.g. the jpegz facade's validate-only U1
//! path) carry the archive's exports. Since Phase 3 the C ABI's decode is
//! the pure-Zig cleanroom route, so the archive references no openjpeg
//! symbol: the CLI and the C smoke test link it without -lopenjp2, and
//! tests/import_probe.zig keeps the public module free of C attachments.
//!
//! Fleet note (Peter, 2026-07-31): jp2z's C-FFI dogfooding obligation is
//! carried by jpegz (the whole-family facade + its C CLI); jp2z's own C
//! CLI remains as the e2e test vehicle, and in-fleet Zig consumers import
//! the module directly — never through this C ABI.
pub const jp2z = @import("jp2z.zig");

comptime {
    _ = @import("ffi/c_api.zig");
}
