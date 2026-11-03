//! The sRGB color spaces: 8-bit, gamma-encoded and linear.

const std = @import("std");
const convert = @import("convert.zig");
const gamut = @import("gamut.zig");

/// 8-bit gamma-encoded sRGB, as in an image or a hex color.
pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    alpha: u8 = 255,

    /// Any ochre color in 8 bits. Fails on a channel that does not round to
    /// 0-255, or on NaN: going to 8 bits never clips.
    pub fn from(color: anytype) error{OutOfGamut}!Rgba8 {
        return convert.toRgba8(color);
    }
};

pub fn rgba8ToSrgb(comptime T: type, color: Rgba8) Srgb(T) {
    return .{
        .r = byteToFloat(T, color.r),
        .g = byteToFloat(T, color.g),
        .b = byteToFloat(T, color.b),
        .alpha = byteToFloat(T, color.alpha),
    };
}

pub fn srgbToRgba8(comptime T: type, color: Srgb(T)) error{OutOfGamut}!Rgba8 {
    return .{
        .r = try floatToByte(T, color.r),
        .g = try floatToByte(T, color.g),
        .b = try floatToByte(T, color.b),
        .alpha = try floatToByte(T, color.alpha),
    };
}

fn byteToFloat(comptime T: type, byte: u8) T {
    return @as(T, @floatFromInt(byte)) / 255;
}

/// What `Srgb.fit` and a ramp do with a color outside sRGB's gamut.
pub const Gamut = enum {
    /// Nothing: out-of-gamut channels stay.
    keep,
    /// Each channel stopped at 0 and 1. Hue can shift visibly: this is the
    /// cheap way in, and `.map` the good one.
    clip,
    /// Less chroma, at close to the same lightness and hue, by the binary
    /// search of CSS Color 4. Lightness at or past white or black gives white
    /// or black.
    map,
};

/// Gamma-encoded sRGB. In gamut is 0 to 1; values outside that are valid.
pub fn Srgb(comptime T: type) type {
    return extern struct {
        r: T,
        g: T,
        b: T,
        alpha: T = 1,

        const Self = @This();

        /// Any ochre color in this space and precision.
        pub fn from(color: anytype) Self {
            return convert.to(Self, color);
        }

        /// Whether each channel is 0 to 1, within rounding noise from a
        /// conversion (`gamut_tolerance`). False on NaN.
        pub fn inGamut(self: Self) bool {
            return channelInRange(T, self.r, gamut_tolerance) and
                channelInRange(T, self.g, gamut_tolerance) and
                channelInRange(T, self.b, gamut_tolerance);
        }

        /// The color in gamut, by `.clip` or `.map` (`.keep` leaves it as it
        /// is). A color in gamut comes back unchanged, alpha always does, and
        /// NaN stays NaN.
        pub fn fit(self: Self, how: Gamut) Self {
            return switch (how) {
                .keep => self,
                .clip => clip(T, self),
                .map => gamut.map(T, self),
            };
        }
    };
}

fn channelInRange(comptime T: type, value: T, tolerance: T) bool {
    return value >= -tolerance and value <= 1 + tolerance;
}

pub fn clip(comptime T: type, color: Srgb(T)) Srgb(T) {
    return .{
        .r = clipChannel(T, color.r),
        .g = clipChannel(T, color.g),
        .b = clipChannel(T, color.b),
        .alpha = color.alpha,
    };
}

/// Not `@min` and `@max`: they would turn NaN into a plausible channel.
fn clipChannel(comptime T: type, value: T) T {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

/// `inGamut`'s allowance, the same as coloraide's. Conversions through Oklab are
/// measured to stay within 2.1e-5 in `f32`.
const gamut_tolerance = 0.000075;

/// Linear-light sRGB. Values above 1 (a hit flash) or below 0 (out of gamut)
/// pass through every conversion.
pub fn LinearSrgb(comptime T: type) type {
    return extern struct {
        r: T,
        g: T,
        b: T,
        alpha: T = 1,

        const Self = @This();

        /// Any ochre color in this space and precision.
        pub fn from(color: anytype) Self {
            return convert.to(Self, color);
        }
    };
}

pub fn srgbToLinear(comptime T: type, color: Srgb(T)) LinearSrgb(T) {
    return .{
        .r = decode(T, color.r),
        .g = decode(T, color.g),
        .b = decode(T, color.b),
        .alpha = color.alpha,
    };
}

pub fn linearToSrgb(comptime T: type, color: LinearSrgb(T)) Srgb(T) {
    return .{
        .r = encode(T, color.r),
        .g = encode(T, color.g),
        .b = encode(T, color.b),
        .alpha = color.alpha,
    };
}

fn floatToByte(comptime T: type, value: T) error{OutOfGamut}!u8 {
    const scaled = value * 255;
    // Written so that NaN fails too.
    if (!(scaled > -0.5 and scaled < 255.5)) return error.OutOfGamut;
    return @intFromFloat(@round(scaled));
}

/// The sRGB transfer function, extended to negative values by reflection, as in
/// CSS Color 4.
fn decode(comptime T: type, value: T) T {
    const magnitude = @abs(value);
    if (magnitude <= 0.04045) return value / 12.92;
    return std.math.copysign(std.math.pow(T, (magnitude + 0.055) / 1.055, 2.4), value);
}

fn encode(comptime T: type, value: T) T {
    const magnitude = @abs(value);
    if (magnitude <= 0.0031308) return 12.92 * value;
    return std.math.copysign(1.055 * std.math.pow(T, magnitude, 1.0 / 2.4) - 0.055, value);
}
