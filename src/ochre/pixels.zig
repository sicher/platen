//! Operations on slices of pixels. Their meaning is ochre's; where they are in
//! an image is the caller's, so nothing here knows a width or a height. A
//! buffer of bytes gets here by `std.mem.bytesAsSlice(Rgba8, bytes)`.

const std = @import("std");
const rgb = @import("rgb.zig");
const floatOf = @import("convert.zig").floatOf;

const Rgba8 = rgb.Rgba8;
const LinearSrgb = rgb.LinearSrgb;

/// The space a renderer blends in, which premultiplying has to match. Stored
/// channels stay gamma-encoded in both.
pub const Blend = enum {
    /// In the encoded values: a framebuffer that is not sRGB.
    gamma,
    /// In linear light: an sRGB texture and framebuffer. Channels are decoded
    /// to multiply and encoded again; alpha is linear already.
    linear,
};

/// An `Rgba8` multiplied by its alpha. The two kinds differ in their bytes, so
/// they are different types.
pub fn PremultipliedRgba8(comptime blend: Blend) type {
    return extern struct {
        r: u8,
        g: u8,
        b: u8,
        alpha: u8,

        const Self = @This();

        /// One pixel of `premultiply`. Only from `Rgba8`: premultiplying is
        /// for bytes, and other colors get there by `Rgba8.from`.
        pub fn from(pixel: Rgba8) Self {
            switch (blend) {
                .gamma => return .{
                    .r = multiplyByte(pixel.r, pixel.alpha),
                    .g = multiplyByte(pixel.g, pixel.alpha),
                    .b = multiplyByte(pixel.b, pixel.alpha),
                    .alpha = pixel.alpha,
                },
                .linear => {
                    const coverage = byteToFloat(pixel.alpha);
                    const multiplied: LinearSrgb(f64) = .{
                        .r = decoded(f64)[pixel.r] * coverage,
                        .g = decoded(f64)[pixel.g] * coverage,
                        .b = decoded(f64)[pixel.b] * coverage,
                    };
                    const encoded = rgb.Srgb(f64).from(multiplied);
                    return .{
                        .r = roundToByte(encoded.r),
                        .g = roundToByte(encoded.g),
                        .b = roundToByte(encoded.b),
                        .alpha = pixel.alpha,
                    };
                },
            }
        }

        /// Fails on a channel above what its alpha allows, which no `Rgba8`
        /// gives: additive pixels are the usual reason, with alpha 0 and a
        /// color. Without any alpha or color the result is transparent black.
        pub fn unpremultiply(self: Self) error{OutOfGamut}!Rgba8 {
            try self.check();
            return self.divide();
        }

        fn check(self: Self) error{OutOfGamut}!void {
            const limit = switch (blend) {
                .gamma => self.alpha,
                .linear => linear_limits[self.alpha],
            };
            if (self.r > limit or self.g > limit or self.b > limit) return error.OutOfGamut;
        }

        fn divide(self: Self) Rgba8 {
            if (self.alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .alpha = 0 };
            return switch (blend) {
                .gamma => .{
                    .r = divideByte(self.r, self.alpha),
                    .g = divideByte(self.g, self.alpha),
                    .b = divideByte(self.b, self.alpha),
                    .alpha = self.alpha,
                },
                .linear => .{
                    .r = divideLinear(self.r, self.alpha),
                    .g = divideLinear(self.g, self.alpha),
                    .b = divideLinear(self.b, self.alpha),
                    .alpha = self.alpha,
                },
            };
        }
    };
}

/// Multiplies each pixel by its alpha, in place. The result is the same memory
/// as its own type, so straight pixels cannot be blended by mistake.
pub fn premultiply(comptime blend: Blend, pixels: []Rgba8) []PremultipliedRgba8(blend) {
    const result: []PremultipliedRgba8(blend) = @ptrCast(pixels);
    for (pixels, result) |pixel, *out| out.* = .from(pixel);
    return result;
}

/// Undoes `premultiply` in place, as far as 8 bits can: colors at low alpha were
/// rounded to a few levels. Fails as `PremultipliedRgba8.unpremultiply` does,
/// and then leaves `pixels` as they were.
pub fn unpremultiply(comptime blend: Blend, pixels: []PremultipliedRgba8(blend)) error{OutOfGamut}![]Rgba8 {
    for (pixels) |pixel| try pixel.check();
    const result: []Rgba8 = @ptrCast(pixels);
    for (pixels, result) |pixel, *out| out.* = pixel.divide();
    return result;
}

/// `from` over a slice: `in` and `out` hold ochre colors of any type, the
/// same number of them, and their types choose the conversion. `Rgba8` to
/// `LinearSrgb` goes by table. Into `Rgba8` fails as `Rgba8.from` does, with
/// `out` part written.
pub fn convert(in: anytype, out: anytype) Converted(std.meta.Elem(@TypeOf(out))) {
    const In = std.meta.Elem(@TypeOf(in));
    const Out = std.meta.Elem(@TypeOf(out));
    // For the error that names a type that is not a color.
    if (Out != Rgba8) _ = floatOf(Out);
    std.debug.assert(in.len == out.len);
    if (In == Rgba8 and (Out == LinearSrgb(f32) or Out == LinearSrgb(f64))) {
        const T = @FieldType(Out, "alpha");
        const table = decoded(T);
        for (in, out) |pixel, *color| color.* = .{
            .r = table[pixel.r],
            .g = table[pixel.g],
            .b = table[pixel.b],
            .alpha = @as(T, @floatFromInt(pixel.alpha)) / 255,
        };
        return;
    }
    for (in, out) |color, *result| {
        result.* = if (Out == Rgba8) try Rgba8.from(color) else Out.from(color);
    }
}

fn Converted(comptime Out: type) type {
    return if (Out == Rgba8) error{OutOfGamut}!void else void;
}

/// `value * factor / 255`, rounded, without dividing (Blinn, "Three Wrongs Make
/// a Right", 1995).
fn multiplyByte(value: u8, factor: u8) u8 {
    const product = @as(u32, value) * factor + 128;
    return @intCast((product + (product >> 8)) >> 8);
}

/// `value * 255 / divisor`, rounded.
fn divideByte(value: u8, divisor: u8) u8 {
    return @intCast((@as(u32, value) * 255 + divisor / 2) / divisor);
}

fn divideLinear(value: u8, alpha: u8) u8 {
    const straight: LinearSrgb(f64) = .{
        .r = decoded(f64)[value] / byteToFloat(alpha),
        .g = 0,
        .b = 0,
    };
    // A premultiplied channel was rounded, perhaps up past its alpha.
    return roundToByte(@min(rgb.Srgb(f64).from(straight).r, 1));
}

fn byteToFloat(byte: u8) f64 {
    return @as(f64, @floatFromInt(byte)) / 255;
}

fn roundToByte(value: f64) u8 {
    return @intFromFloat(@round(value * 255));
}

/// Every byte in linear light.
fn decoded(comptime T: type) *const [256]T {
    return &struct {
        const table = build: {
            @setEvalBranchQuota(100_000);
            var values: [256]T = undefined;
            for (&values, 0..) |*value, byte| {
                const pixel: Rgba8 = .{ .r = byte, .g = 0, .b = 0 };
                value.* = LinearSrgb(T).from(pixel).r;
            }
            break :build values;
        };
    }.table;
}

/// The highest channel `.linear` premultiplying gives at each alpha, from white.
const linear_limits = build: {
    @setEvalBranchQuota(100_000);
    var limits: [256]u8 = undefined;
    for (&limits, 0..) |*limit, alpha| {
        const white: Rgba8 = .{ .r = 255, .g = 255, .b = 255, .alpha = alpha };
        limit.* = PremultipliedRgba8(.linear).from(white).r;
    }
    break :build limits;
};
