//! Encoder package root (scope added 2026-10-23; plan in
//! docs/plan_context/encoder_and_cli.md). Pure in-memory transforms and
//! coders; the C ABI in ffi/c_api.zig is the public entry point.
pub const transform = @import("encode/transform.zig");
pub const mq_encoder = @import("encode/mq_encoder.zig");
pub const tier1 = @import("encode/tier1.zig");
pub const tier2 = @import("encode/tier2.zig");
pub const codestream = @import("encode/codestream.zig");
pub const Params = codestream.Params;
pub const EncodeError = codestream.EncodeError;
pub const encodeJ2k = codestream.encodeJ2k;
pub const encodeJp2 = codestream.encodeJp2;

test {
    _ = transform;
    _ = mq_encoder;
    _ = tier1;
    _ = tier2;
    _ = codestream;
}
