//! A path between two colors, as evenly spaced samples for a lookup table or as
//! the few stops a renderer needs to draw it with straight lines.

const std = @import("std");
const oklab = @import("oklab.zig");
const rgb = @import("rgb.zig");
const floatOf = @import("convert.zig").floatOf;

const HuePath = oklab.HuePath;
const Oklab = oklab.Oklab;
const Oklch = oklab.Oklch;
const Gamut = rgb.Gamut;
const Rgba8 = rgb.Rgba8;
const Srgb = rgb.Srgb;
const lerp = oklab.lerp;

pub const Options = struct {
    /// The space the ramp goes through: straight in Oklab, or around the hue
    /// in Oklch.
    interpolate: enum { oklab, oklch } = .oklab,
    /// The way around the hue circle, for `.oklch`. Oklab has no hue to take.
    hue: HuePath = .shorter,
    /// `Srgb.fit` for every color of the ramp. An Oklch path can leave the
    /// gamut even between colors in it. This is not left for later because
    /// `stops` has to keep its tolerance for the color that is finally shown.
    gamut: Gamut,
};

/// A ramp from `from` to `to`, colors of any space, in `f32` or `f64`. Its
/// precision is theirs, so the two must agree, and an `Rgba8` takes the other's.
pub fn ramp(from: anytype, to: anytype, options: Options) Ramp(FloatOf(@TypeOf(from), @TypeOf(to))) {
    const T = FloatOf(@TypeOf(from), @TypeOf(to));
    const path: Ramp(T).Path = switch (options.interpolate) {
        .oklab => .{ .oklab = .{ .from = .from(from), .to = .from(to) } },
        .oklch => .{ .oklch = .{ .from = .from(from), .to = .from(to), .hue = options.hue } },
    };
    return .{ .path = path, .gamut = options.gamut };
}

fn FloatOf(comptime From: type, comptime To: type) type {
    if (From == Rgba8 and To == Rgba8) {
        @compileError("a ramp between two Rgba8 has no precision: give one color as Srgb(f32) or Srgb(f64)");
    }
    if (From == Rgba8) return floatOf(To);
    if (To == Rgba8) return floatOf(From);
    const T = floatOf(From);
    if (floatOf(To) != T) {
        @compileError("a ramp's colors are of one precision: " ++ @typeName(From) ++ " and " ++ @typeName(To));
    }
    return T;
}

/// A point on a ramp. `offset` is 0 to 1, in order along the stops.
pub fn Stop(comptime T: type) type {
    return extern struct {
        offset: T,
        color: Srgb(T),
    };
}

/// What `ramp` gives. The ends are kept in the space it goes through.
pub fn Ramp(comptime T: type) type {
    return struct {
        path: Path,
        gamut: Gamut,

        const Self = @This();

        const Path = union(enum) {
            oklab: struct { from: Oklab(T), to: Oklab(T) },
            oklch: struct { from: Oklch(T), to: Oklch(T), hue: HuePath },
        };

        /// The color `t` of the way along. As in `mix`, `t` is not limited to 0
        /// to 1.
        pub fn at(self: Self, t: T) Srgb(T) {
            const color = switch (self.path) {
                .oklab => |path| Srgb(T).from(path.from.mix(path.to, t)),
                .oklch => |path| Srgb(T).from(path.from.mix(path.to, t, path.hue)),
            };
            return color.fit(self.gamut);
        }

        /// Fills `out` with evenly spaced colors, from 0 to 1 inclusive. A
        /// single color is the middle, as in coloraide.
        pub fn sample(self: Self, out: []Srgb(T)) void {
            if (out.len == 1) {
                out[0] = self.at(0.5);
                return;
            }
            const last: T = @floatFromInt(out.len -| 1);
            for (out, 0..) |*color, i| {
                const position: T = @floatFromInt(i);
                color.* = self.at(position / last);
            }
        }

        /// As few stops as `out` needs, by halving, so that interpolating them
        /// straight in sRGB stays within `tolerance` of the path, in deltaEOK.
        /// 0.02 is just noticeable. Returns the part of `out` it used. Segments
        /// are checked at points, so a kink from `.clip` or `.map` can pass
        /// between them: expect up to 1.2 times `tolerance` with those.
        ///
        /// Each color's error counts by its alpha, as a color that cannot be
        /// seen needs no accuracy. Interpolate the stops without premultiplying.
        /// `.map` can jump, as CSS's gamut mapping does: no stops can follow
        /// that, so a jump is left narrower than any pixel, and one too small
        /// to see adds to the error. Otherwise, fails with `TooManyStops`
        /// rather than return a worse ramp.
        pub fn stops(self: Self, tolerance: T, out: []Stop(T)) error{TooManyStops}![]Stop(T) {
            if (out.len < 2) return error.TooManyStops;
            const first: Stop(T) = .{ .offset = 0, .color = self.at(0) };
            const last: Stop(T) = .{ .offset = 1, .color = self.at(1) };
            out[0] = first;
            var count: usize = 1;
            try self.refine(first, last, tolerance, out, &count, 0);
            return out[0..count];
        }

        fn refine(
            self: Self,
            from: Stop(T),
            to: Stop(T),
            tolerance: T,
            out: []Stop(T),
            count: *usize,
            depth: u8,
        ) error{TooManyStops}!void {
            if (depth == max_depth or self.isStraight(from, to, tolerance)) {
                if (count.* == out.len) return error.TooManyStops;
                out[count.*] = to;
                count.* += 1;
                return;
            }
            const offset = (from.offset + to.offset) / 2;
            const middle: Stop(T) = .{ .offset = offset, .color = self.at(offset) };
            try self.refine(from, middle, tolerance, out, count, depth + 1);
            try self.refine(middle, to, tolerance, out, count, depth + 1);
        }

        fn isStraight(self: Self, from: Stop(T), to: Stop(T), tolerance: T) bool {
            for (1..probes + 1) |i| {
                const position: T = @floatFromInt(i);
                const along = position / (probes + 1);
                const exact = self.at(lerp(T, from.offset, to.offset, along));
                const straight: Srgb(T) = .{
                    .r = lerp(T, from.color.r, to.color.r, along),
                    .g = lerp(T, from.color.g, to.color.g, along),
                    .b = lerp(T, from.color.b, to.color.b, along),
                };
                const distance = Oklab(T).from(exact).deltaE(Oklab(T).from(straight));
                if (distance * exact.alpha > tolerance) return false;
            }
            return true;
        }
    };
}

/// Points checked between two stops. One is not enough: where the error is an S
/// around the line, the middle is on it.
const probes = 7;

/// A segment of 1/65536 of the ramp is not divided again. Only a jump gets this
/// far at any useful tolerance, and an f32 offset still resolves it.
const max_depth = 16;
