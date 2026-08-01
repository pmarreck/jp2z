//! Root of the STATIC LIBRARY artifact (libjp2z.a) — and ONLY that
//! artifact. Re-exports the public API and force-links the C ABI so its
//! `export fn`s land in the archive. This lives OUTSIDE src/jp2z.zig on
//! purpose: the C ABI's decode path reaches openjpeg_wrapper's @cImport,
//! and force-linking it from the importable module root made every plain
//! Zig consumer (e.g. the jpegz facade's validate-only U1 path) inherit a
//! hard openjpeg dependency. tests/import_probe.zig is the mechanical
//! gate that keeps the force-link from migrating back.
//!
//! Fleet note (Peter, 2026-07-31): jp2z's C-FFI dogfooding obligation is
//! carried by jpegz (the whole-family facade + its C CLI); jp2z's own C
//! CLI remains as the e2e test vehicle, and in-fleet Zig consumers import
//! the module directly — never through this C ABI.
pub const jp2z = @import("jp2z.zig");

comptime {
    _ = @import("ffi/c_api.zig");
}
