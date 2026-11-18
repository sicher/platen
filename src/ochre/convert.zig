//! What `from` does on every color type: any color into any space, by way of
//! the spaces between, `Rgba8` - `Srgb` - `LinearSrgb` - `Oklab` - `Oklch`.
//! The route is chosen at compile time, so a call costs the steps it takes.

const std = @import("std");
const rgb = @import("rgb.zig");
const oklab = @import("oklab.zig");
const Parsed = @import("parse.zig").Parsed;

const Rgba8 = rgb.Rgba8;

const Space = enum { rgba8, srgb, linear, oklab, oklch };

fn Color(comptime T: type, comptime space: Space) type {
    return switch (space) {
        .rgba8 => Rgba8,
        .srgb => rgb.Srgb(T),
        .linear => rgb.LinearSrgb(T),
        .oklab => oklab.Oklab(T),
        .oklch => oklab.Oklch(T),
    };
}

/// `color` as `Target`, a color type of `f32` or `f64` other than `Rgba8`. A
/// change of precision comes last: the conversion is in the source's.
pub fn to(comptime Target: type, color: anytype) Target {
    const Source = @TypeOf(color);
    if (comptime isParsed(Source)) return switch (color) {
        inline else => |written| to(Target, written),
    };
    const T = floatOf(Target);
    if (Source == Rgba8) return walk(T, spaceOf(Target), rgb.rgba8ToSrgb(T, color));
    return cast(Target, walk(floatOf(Source), spaceOf(Target), color));
}

/// `color` as `Rgba8`. Fails as `Srgb` to 8 bits does.
pub fn toRgba8(color: anytype) error{OutOfGamut}!Rgba8 {
    const Source = @TypeOf(color);
    if (Source == Rgba8) return color;
    const T = floatOf(Source);
    return rgb.srgbToRgba8(T, to(rgb.Srgb(T), color));
}

fn walk(comptime T: type, comptime target: Space, color: anytype) Color(T, target) {
    const source = comptime spaceOf(@TypeOf(color));
    if (source == target) return color;
    const next = if (@intFromEnum(source) < @intFromEnum(target)) switch (source) {
        .srgb => rgb.srgbToLinear(T, color),
        .linear => oklab.linearToOklab(T, color),
        .oklab => oklab.oklabToOklch(T, color),
        .rgba8, .oklch => unreachable,
    } else switch (source) {
        .oklch => oklab.oklchToOklab(T, color),
        .oklab => oklab.oklabToLinear(T, color),
        .linear => rgb.linearToSrgb(T, color),
        .rgba8, .srgb => unreachable,
    };
    return walk(T, target, next);
}

fn cast(comptime Target: type, color: anytype) Target {
    var result: Target = undefined;
    inline for (@typeInfo(Target).@"struct".field_names) |name| {
        @field(result, name) = @floatCast(@field(color, name));
    }
    return result;
}

fn spaceOf(comptime C: type) Space {
    if (C == Rgba8) return .rgba8;
    const T = floatOf(C);
    for ([_]Space{ .srgb, .linear, .oklab, .oklch }) |space| {
        if (C == Color(T, space)) return space;
    }
    notAColor(C);
}

/// The `f32` or `f64` a color type holds.
pub fn floatOf(comptime C: type) type {
    const T = switch (@typeInfo(C)) {
        .@"struct" => if (@hasField(C, "alpha")) @FieldType(C, "alpha") else notAColor(C),
        .@"union" => if (@hasField(C, "srgb")) @FieldType(@FieldType(C, "srgb"), "alpha") else notAColor(C),
        else => notAColor(C),
    };
    if (T != f32 and T != f64) notAColor(C);
    return T;
}

fn isParsed(comptime C: type) bool {
    return @typeInfo(C) == .@"union" and C == Parsed(floatOf(C));
}

fn notAColor(comptime C: type) noreturn {
    @compileError("not an ochre color of f32 or f64: " ++ @typeName(C));
}
