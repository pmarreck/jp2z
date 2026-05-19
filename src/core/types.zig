//! Public pixel-data types for jp2z. Mirrors jpegz's `core/types.zig`
//! exactly so the jpegz integration shim (planned at jp2z M6) can
//! re-export jp2z's `Image` / `PixelLayout` / `ColorSpace` directly
//! without translation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ColorSpace = enum(u8) {
    unknown,
    grayscale,
    rgb,
    ycbcr,
    cmyk,
    ycck,
    srgb,            // JP2 enumerated colorspace 16
    greyscale_jp2,   // JP2 enumerated colorspace 17
};

pub const PixelLayout = enum(u8) {
    grayscale,
    rgb,
    cmyk,
};

pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: ColorSpace,
    layout: PixelLayout,

    pub fn rowStride(self: Image) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return @as(usize, self.width) * @as(usize, self.channels) * bytes_per_sample;
    }

    pub fn pixelsU16(self: Image) []align(1) u16 {
        std.debug.assert(self.bits_per_sample > 8);
        return std.mem.bytesAsSlice(u16, self.pixels);
    }

    pub fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const ImageMetadata = struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: ColorSpace,
    layout: PixelLayout,

    pub fn rowStride(self: ImageMetadata) usize {
        const bytes_per_sample: usize = if (self.bits_per_sample > 8) 2 else 1;
        return @as(usize, self.width) * @as(usize, self.channels) * bytes_per_sample;
    }
};
