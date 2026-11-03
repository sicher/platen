//! The Oklab color spaces: rectangular and polar.

const std = @import("std");
const convert = @import("convert.zig");
const matrix = @import("matrix.zig");
const LinearSrgb = @import("rgb.zig").LinearSrgb;

/// Björn Ottosson's Oklab. `l` is 0 to 1; `a` and `b` are the same scale as `l`.
pub fn Oklab(comptime T: type) type {
    return extern struct {
        l: T,
        a: T,
        b: T,
        alpha: T = 1,

        const Self = @This();

        /// Any ochre color in this space and precision.
        pub fn from(color: anytype) Self {
            return convert.to(Self, color);
        }

        /// deltaEOK: the distance between two colors, ignoring alpha. About
        /// 0.02 is just noticeable.
        pub fn deltaE(self: Self, other: Self) T {
            const l = self.l - other.l;
            const a = self.a - other.a;
            const b = self.b - other.b;
            return @sqrt(l * l + a * a + b * b);
        }

        /// The color `t` of the way from `self` to `other`, with alpha
        /// premultiplied as in CSS Color 4. `t` is not limited to 0 to 1, for
        /// easing that overshoots: color follows it, but the result's alpha
        /// stops at 0 and 1, where a value outside means nothing. Opaque colors
        /// come back exactly at 0 and 1.
        pub fn mix(self: Self, other: Self, t: T) Self {
            const alpha = lerp(T, self.alpha, other.alpha, t);
            return .{
                .l = mixPremultiplied(T, self.l, self.alpha, other.l, other.alpha, t, alpha),
                .a = mixPremultiplied(T, self.a, self.alpha, other.a, other.alpha, t, alpha),
                .b = mixPremultiplied(T, self.b, self.alpha, other.b, other.alpha, t, alpha),
                .alpha = limitAlpha(T, alpha),
            };
        }
    };
}

/// Which way around the hue circle `Oklch.mix` goes, as in CSS Color 4.
pub const HuePath = enum { shorter, longer, increasing, decreasing };

/// Oklab in polar form: lightness, chroma and hue. `h` is in degrees, as in CSS
/// `oklch()`, and `from` gives 0 to 360. `mix` with an overshooting `t` can
/// make `c` negative, which `Oklab.from` handles.
pub fn Oklch(comptime T: type) type {
    return extern struct {
        l: T,
        c: T,
        h: T,
        alpha: T = 1,

        const Self = @This();

        /// Any ochre color in this space and precision.
        pub fn from(color: anytype) Self {
            return convert.to(Self, color);
        }

        /// Whether the hue means nothing: chroma this low is rounding noise.
        /// CSS Color 4 makes such a hue NaN, but here NaN only ever means an
        /// error, so `from` gives it as 0. Check here before using a hue.
        pub fn isAchromatic(self: Self) bool {
            return @abs(self.c) <= achromatic_chroma;
        }

        /// As `Oklab.mix`, going around the hue circle by `path`. An achromatic
        /// color takes the other color's hue, so white to red stays red.
        pub fn mix(self: Self, other: Self, t: T, path: HuePath) Self {
            const alpha = lerp(T, self.alpha, other.alpha, t);
            const start = if (self.isAchromatic()) other.h else self.h;
            const end = if (other.isAchromatic()) start else other.h;
            const hues = unwrapHues(T, @mod(start, 360), @mod(end, 360), path);
            return .{
                .l = mixPremultiplied(T, self.l, self.alpha, other.l, other.alpha, t, alpha),
                .c = mixPremultiplied(T, self.c, self.alpha, other.c, other.alpha, t, alpha),
                .h = @mod(lerp(T, hues[0], hues[1], t), 360),
                .alpha = limitAlpha(T, alpha),
            };
        }
    };
}

pub fn linearToOklab(comptime T: type, color: LinearSrgb(T)) Oklab(T) {
    const lms = matrix.apply(T, matrix.srgb_to_lms, color.r, color.g, color.b);
    // Sign-keeping, unlike pow: out-of-gamut colors have negative cone
    // responses.
    const lab = matrix.apply(
        T,
        matrix.lms_to_oklab,
        std.math.cbrt(lms[0]),
        std.math.cbrt(lms[1]),
        std.math.cbrt(lms[2]),
    );
    return .{ .l = lab[0], .a = lab[1], .b = lab[2], .alpha = color.alpha };
}

pub fn oklabToLinear(comptime T: type, color: Oklab(T)) LinearSrgb(T) {
    const lms = matrix.apply(T, matrix.oklab_to_lms, color.l, color.a, color.b);
    const rgb = matrix.apply(
        T,
        matrix.lms_to_srgb,
        lms[0] * lms[0] * lms[0],
        lms[1] * lms[1] * lms[1],
        lms[2] * lms[2] * lms[2],
    );
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .alpha = color.alpha };
}

pub fn oklabToOklch(comptime T: type, color: Oklab(T)) Oklch(T) {
    const chroma = std.math.hypot(color.a, color.b);
    // Chroma exactly at the limit of CSS Color 4's OKLab_to_OKLCH.
    if (chroma <= achromatic_chroma) {
        return .{ .l = color.l, .c = chroma, .h = 0, .alpha = color.alpha };
    }
    const hue = @mod(std.math.atan2(color.b, color.a) * degrees_per_radian, 360);
    return .{ .l = color.l, .c = chroma, .h = hue, .alpha = color.alpha };
}

pub fn oklchToOklab(comptime T: type, color: Oklch(T)) Oklab(T) {
    const radians = color.h / degrees_per_radian;
    return .{
        .l = color.l,
        .a = color.c * @cos(radians),
        .b = color.c * @sin(radians),
        .alpha = color.alpha,
    };
}

/// The adjustments of CSS Color 4 section "Hue Interpolation".
fn unwrapHues(comptime T: type, from: T, to: T, path: HuePath) [2]T {
    const difference = to - from;
    return switch (path) {
        .shorter => if (difference > 180)
            .{ from + 360, to }
        else if (difference < -180)
            .{ from, to + 360 }
        else
            .{ from, to },
        .longer => if (difference > 0 and difference < 180)
            .{ from + 360, to }
        else if (difference > -180 and difference <= 0)
            .{ from, to + 360 }
        else
            .{ from, to },
        .increasing => if (difference < 0) .{ from, to + 360 } else .{ from, to },
        .decreasing => if (difference > 0) .{ from + 360, to } else .{ from, to },
    };
}

/// Exact at 0 and 1.
pub fn lerp(comptime T: type, from: T, to: T, t: T) T {
    return from * (1 - t) + to * t;
}

fn mixPremultiplied(comptime T: type, from: T, from_alpha: T, to: T, to_alpha: T, t: T, alpha: T) T {
    const premultiplied = lerp(T, from * from_alpha, to * to_alpha, t);
    return if (alpha == 0) premultiplied else premultiplied / alpha;
}

/// Not `@min` and `@max`: they would turn NaN into a plausible alpha.
pub fn limitAlpha(comptime T: type, alpha: T) T {
    if (alpha < 0) return 0;
    if (alpha > 1) return 1;
    return alpha;
}

const achromatic_chroma = 0.000004;
const degrees_per_radian = 180.0 / std.math.pi;
