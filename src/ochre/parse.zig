//! Colors as CSS writes them: hex, names, `rgb()`, `hsl()`, `oklab()` and
//! `oklch()`, in CSS Color 4's modern and legacy syntax. Numbers come back as
//! written, so `rgb(300 0 0)` is out of gamut, not clamped. See DESIGN.md.

const std = @import("std");
const convert = @import("convert.zig");
const names = @import("names.zig").names;
const oklab = @import("oklab.zig");
const rgb = @import("rgb.zig");

const Oklab = oklab.Oklab;
const Oklch = oklab.Oklch;
const Rgba8 = rgb.Rgba8;
const Srgb = rgb.Srgb;

/// A parsed color, in the space it was written in. `hsl()` is another way of
/// writing sRGB, so it comes back as `srgb`.
pub fn Parsed(comptime T: type) type {
    return union(enum) {
        srgb: Srgb(T),
        oklab: Oklab(T),
        oklch: Oklch(T),
    };
}

pub const Error = error{InvalidColor};

pub const Options = struct {
    /// The type to give the color as: `Srgb(f32)`, `Oklch(f64)` and so on,
    /// `Rgba8`, or `Parsed(T)` to keep the space it was written in.
    as: type,
};

/// Whitespace around the color is ignored, and works at compile time too.
/// `none` gives 0, as CSS renders it: NaN only ever means an error here.
/// `.as = Rgba8` fails with `OutOfGamut` too, for a color 8 bits cannot hold.
pub fn parse(text: []const u8, comptime options: Options) Result(options.as) {
    const As = options.as;
    if (As == Rgba8) return Rgba8.from(try parseWritten(f64, text));
    const written = try parseWritten(convert.floatOf(As), text);
    return if (As == Parsed(convert.floatOf(As))) written else As.from(written);
}

fn Result(comptime As: type) type {
    return if (As == Rgba8) (Error || error{OutOfGamut})!Rgba8 else Error!As;
}

fn parseWritten(comptime T: type, text: []const u8) Error!Parsed(T) {
    const color = std.mem.trim(u8, text, whitespace);
    if (color.len == 0) return error.InvalidColor;
    if (color[0] == '#') return .{ .srgb = Srgb(T).from(try parseHex(color[1..])) };

    const open = std.mem.indexOfScalar(u8, color, '(') orelse {
        const named = names.get(color) orelse return error.InvalidColor;
        return .{ .srgb = Srgb(T).from(named) };
    };
    if (color[color.len - 1] != ')') return error.InvalidColor;

    const function = color[0..open];
    const arguments = try parseArguments(T, color[open + 1 .. color.len - 1]);
    if (isAny(function, "rgb", "rgba")) return .{ .srgb = try toRgb(T, arguments) };
    if (isAny(function, "hsl", "hsla")) return .{ .srgb = try toHsl(T, arguments) };
    if (std.ascii.eqlIgnoreCase(function, "oklab")) return .{ .oklab = try toOklab(T, arguments) };
    if (std.ascii.eqlIgnoreCase(function, "oklch")) return .{ .oklch = try toOklch(T, arguments) };
    return error.InvalidColor;
}

fn isAny(name: []const u8, first: []const u8, second: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, first) or std.ascii.eqlIgnoreCase(name, second);
}

const whitespace = " \t\n\r\x0c";

/// 3, 4, 6 or 8 digits. The 4 and 8 digit forms end in alpha.
fn parseHex(digits: []const u8) Error!Rgba8 {
    const width: usize = switch (digits.len) {
        3, 4 => 1,
        6, 8 => 2,
        else => return error.InvalidColor,
    };
    var channels = [_]u8{ 0, 0, 0, 255 };
    for (channels[0 .. digits.len / width], 0..) |*channel, i| {
        const first = try hexDigit(digits[i * width]);
        const second = try hexDigit(digits[i * width + width - 1]);
        channel.* = first * 16 + second;
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2], .alpha = channels[3] };
}

fn hexDigit(char: u8) Error!u8 {
    return std.fmt.charToDigit(char, 16) catch error.InvalidColor;
}

fn Component(comptime T: type) type {
    return union(enum) {
        number: T,
        percentage: T,
        degrees: T,
        none,
    };
}

fn Arguments(comptime T: type) type {
    return struct {
        values: [3]Component(T),
        alpha: T,
        /// Written with commas.
        legacy: bool,
    };
}

fn parseArguments(comptime T: type, text: []const u8) Error!Arguments(T) {
    var scanner: Scanner = .{ .text = text };
    const first = try scanner.component(T);
    const legacy = scanner.eat(',');
    const second = try scanner.component(T);
    if (legacy and !scanner.eat(',')) return error.InvalidColor;
    const third = try scanner.component(T);

    var alpha: Component(T) = .{ .number = 1 };
    if (scanner.eat(if (legacy) ',' else '/')) alpha = try scanner.component(T);
    scanner.skipWhitespace();
    if (scanner.position != text.len) return error.InvalidColor;

    const values = [_]Component(T){ first, second, third };
    if (legacy) {
        for (values ++ [_]Component(T){alpha}) |value| {
            if (value == .none) return error.InvalidColor;
        }
    }
    return .{ .values = values, .alpha = try toAlpha(T, alpha), .legacy = legacy };
}

/// Alpha outside 0 to 1 means nothing, as in `mix`. CSS stops it there too.
fn toAlpha(comptime T: type, value: Component(T)) Error!T {
    return oklab.limitAlpha(T, switch (value) {
        .number => |number| number,
        .percentage => |percentage| percentage / 100,
        .none => 0,
        .degrees => return error.InvalidColor,
    });
}

fn toRgb(comptime T: type, arguments: Arguments(T)) Error!Srgb(T) {
    const values = arguments.values;
    if (arguments.legacy) {
        const kind = std.meta.activeTag(values[0]);
        if (values[1] != kind or values[2] != kind) return error.InvalidColor;
    }
    return .{
        .r = try toChannel(T, values[0]),
        .g = try toChannel(T, values[1]),
        .b = try toChannel(T, values[2]),
        .alpha = arguments.alpha,
    };
}

fn toChannel(comptime T: type, value: Component(T)) Error!T {
    return switch (value) {
        .number => |number| number / 255,
        .percentage => |percentage| percentage / 100,
        .none => 0,
        .degrees => error.InvalidColor,
    };
}

fn toHsl(comptime T: type, arguments: Arguments(T)) Error!Srgb(T) {
    const values = arguments.values;
    if (arguments.legacy and (values[1] != .percentage or values[2] != .percentage)) {
        return error.InvalidColor;
    }
    return hslToSrgb(
        T,
        try toHue(T, values[0]),
        try toPercent(T, values[1]),
        try toPercent(T, values[2]),
        arguments.alpha,
    );
}

/// 100 and 100% mean the same in `hsl()`'s modern syntax.
fn toPercent(comptime T: type, value: Component(T)) Error!T {
    return switch (value) {
        .number, .percentage => |percent| percent / 100,
        .none => 0,
        .degrees => error.InvalidColor,
    };
}

fn toHue(comptime T: type, value: Component(T)) Error!T {
    return switch (value) {
        .number, .degrees => |degrees| degrees,
        .none => 0,
        .percentage => error.InvalidColor,
    };
}

/// `hslToRgb` of CSS Color 4. The parser lets no NaN through, so `@min` and
/// `@max` have none to lose.
fn hslToSrgb(comptime T: type, hue: T, saturation: T, lightness: T, alpha: T) Srgb(T) {
    const amplitude = saturation * @min(lightness, 1 - lightness);
    return .{
        .r = hslChannel(T, 0, hue, amplitude, lightness),
        .g = hslChannel(T, 8, hue, amplitude, lightness),
        .b = hslChannel(T, 4, hue, amplitude, lightness),
        .alpha = alpha,
    };
}

fn hslChannel(comptime T: type, n: T, hue: T, amplitude: T, lightness: T) T {
    const k = @mod(n + hue / 30, 12);
    return lightness - amplitude * @max(-1, @min(k - 3, 9 - k, 1));
}

fn toOklab(comptime T: type, arguments: Arguments(T)) Error!Oklab(T) {
    if (arguments.legacy) return error.InvalidColor;
    const values = arguments.values;
    return .{
        .l = try toLightness(T, values[0]),
        .a = try toScaled(T, values[1]),
        .b = try toScaled(T, values[2]),
        .alpha = arguments.alpha,
    };
}

fn toOklch(comptime T: type, arguments: Arguments(T)) Error!Oklch(T) {
    if (arguments.legacy) return error.InvalidColor;
    const values = arguments.values;
    return .{
        .l = try toLightness(T, values[0]),
        .c = try toScaled(T, values[1]),
        .h = try toHue(T, values[2]),
        .alpha = arguments.alpha,
    };
}

fn toLightness(comptime T: type, value: Component(T)) Error!T {
    return switch (value) {
        .number => |number| number,
        .percentage => |percentage| percentage / 100,
        .none => 0,
        .degrees => error.InvalidColor,
    };
}

/// For Oklab's a and b and Oklch's chroma, 100% is 0.4.
fn toScaled(comptime T: type, value: Component(T)) Error!T {
    return switch (value) {
        .number => |number| number,
        .percentage => |percentage| percentage * 0.4 / 100,
        .none => 0,
        .degrees => error.InvalidColor,
    };
}

/// Reads the tokens of CSS Syntax that colors use. Not `std.fmt.parseFloat` alone:
/// it also takes `nan`, `inf`, `0x10` and `1_000`. Comments belong to a
/// stylesheet, and are not read here.
const Scanner = struct {
    text: []const u8,
    position: usize = 0,

    fn peek(self: Scanner, offset: usize) u8 {
        const index = self.position + offset;
        return if (index < self.text.len) self.text[index] else 0;
    }

    fn skipWhitespace(self: *Scanner) void {
        while (self.position < self.text.len and
            std.mem.indexOfScalar(u8, whitespace, self.text[self.position]) != null)
        {
            self.position += 1;
        }
    }

    fn eat(self: *Scanner, char: u8) bool {
        self.skipWhitespace();
        if (self.peek(0) != char) return false;
        self.position += 1;
        return true;
    }

    fn skipDigits(self: *Scanner) void {
        while (std.ascii.isDigit(self.peek(0))) self.position += 1;
    }

    /// What is scanned can still be `-` or `1e`, which `parseFloat` rejects: no
    /// unit starts with an e, so `1e` is never a dimension worth reading.
    fn number(self: *Scanner, comptime T: type) Error!T {
        const start = self.position;
        if (self.peek(0) == '+' or self.peek(0) == '-') self.position += 1;
        self.skipDigits();
        if (self.peek(0) == '.' and std.ascii.isDigit(self.peek(1))) {
            self.position += 1;
            self.skipDigits();
        }
        if (self.peek(0) == 'e' or self.peek(0) == 'E') {
            self.position += 1;
            if (self.peek(0) == '+' or self.peek(0) == '-') self.position += 1;
            self.skipDigits();
        }
        return std.fmt.parseFloat(T, self.text[start..self.position]) catch error.InvalidColor;
    }

    /// An identifier, which is empty if there is none. It runs on through digits
    /// and dashes, so `10deg5` has the unit `deg5` and is not `10deg` and `5`. One
    /// starting otherwise fails as the next component anyway.
    fn name(self: *Scanner) []const u8 {
        if (!std.ascii.isAlphabetic(self.peek(0))) return "";
        const start = self.position;
        while (std.ascii.isAlphanumeric(self.peek(0)) or self.peek(0) == '-') {
            self.position += 1;
        }
        return self.text[start..self.position];
    }

    fn component(self: *Scanner, comptime T: type) Error!Component(T) {
        self.skipWhitespace();
        if (std.ascii.isAlphabetic(self.peek(0))) {
            if (!std.ascii.eqlIgnoreCase(self.name(), "none")) return error.InvalidColor;
            return .none;
        }
        const value = try self.number(T);
        if (self.peek(0) == '%') {
            self.position += 1;
            return .{ .percentage = try finite(T, value) };
        }
        const unit = self.name();
        if (unit.len == 0) return .{ .number = try finite(T, value) };
        return .{ .degrees = try finite(T, value * try degreesPer(T, unit)) };
    }
};

fn degreesPer(comptime T: type, unit: []const u8) Error!T {
    if (std.ascii.eqlIgnoreCase(unit, "deg")) return 1;
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return 0.9;
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return 180.0 / std.math.pi;
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return 360;
    return error.InvalidColor;
}

/// `1e999` overflows to infinity, which no color can use.
fn finite(comptime T: type, value: T) Error!T {
    return if (std.math.isFinite(value)) value else error.InvalidColor;
}
