//! Gamut mapping: CSS Color 4's "Binary Search Gamut Mapping with Local MINDE".
//! https://drafts.csswg.org/css-color-4/#binsearch

const rgb = @import("rgb.zig");
const Srgb = rgb.Srgb;
const oklab = @import("oklab.zig");
const Oklab = oklab.Oklab;
const Oklch = oklab.Oklch;

/// One just noticeable difference, in deltaEOK.
const jnd = 0.02;
const epsilon = 0.0001;

pub fn map(comptime T: type, color: Srgb(T)) Srgb(T) {
    if (inExactRange(T, color)) return color;

    var current = Oklch(T).from(color);
    if (current.l >= 1) return .{ .r = 1, .g = 1, .b = 1, .alpha = color.alpha };
    if (current.l <= 0) return .{ .r = 0, .g = 0, .b = 0, .alpha = color.alpha };

    var clipped = clip(T, current);
    if (distance(T, clipped, current) < jnd) return clipped;

    var low: T = 0;
    var high = current.c;
    var low_in_gamut = true;
    while (high - low > epsilon) {
        const chroma = (low + high) / 2;
        current.c = chroma;
        if (low_in_gamut and inExactRange(T, Srgb(T).from(current))) {
            low = chroma;
            continue;
        }
        clipped = clip(T, current);
        const difference = distance(T, clipped, current);
        if (difference < jnd) {
            if (jnd - difference < epsilon) return clipped;
            low_in_gamut = false;
            low = chroma;
        } else {
            high = chroma;
        }
    }
    return clipped;
}

/// With no tolerance, unlike `Srgb.inGamut`. False on NaN.
fn inExactRange(comptime T: type, color: Srgb(T)) bool {
    return color.r >= 0 and color.r <= 1 and
        color.g >= 0 and color.g <= 1 and
        color.b >= 0 and color.b <= 1;
}

fn clip(comptime T: type, color: Oklch(T)) Srgb(T) {
    return rgb.clip(T, Srgb(T).from(color));
}

fn distance(comptime T: type, clipped: Srgb(T), color: Oklch(T)) T {
    return Oklab(T).from(clipped).deltaE(Oklab(T).from(color));
}
