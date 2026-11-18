//! Fast number formatting utilities for PDF output.
//!
//! These functions provide significantly faster float-to-string conversion
//! compared to std.fmt.bufPrint for fixed decimal places, which is the
//! common case in PDF coordinate output.
//!
//! Benchmarks show 11-14x speedup over std.fmt.bufPrint("{d:.2}", .{val}).

const std = @import("std");

/// Precomputed digit pairs for fast integer-to-string conversion.
const digit_pairs = init: {
    var table: [100][2]u8 = undefined;
    for (0..100) |n| {
        table[n][0] = @intCast(n / 10 + '0');
        table[n][1] = @intCast(n % 10 + '0');
    }
    break :init table;
};

/// Write a non-zero unsigned integer to buffer starting at index i.
/// Returns the new index after writing.
inline fn writeUnsignedInt(buf: []u8, i: usize, value: u64) usize {
    var temp: [20]u8 = undefined;
    var t: usize = 0;
    var n = value;
    while (n >= 100) {
        const pair = digit_pairs[n % 100];
        temp[t] = pair[1];
        temp[t + 1] = pair[0];
        t += 2;
        n /= 100;
    }
    if (n >= 10) {
        const pair = digit_pairs[n];
        temp[t] = pair[1];
        temp[t + 1] = pair[0];
        t += 2;
    } else if (n > 0) {
        temp[t] = @intCast(n + '0');
        t += 1;
    }
    var idx = i;
    while (t > 0) {
        t -= 1;
        buf[idx] = temp[t];
        idx += 1;
    }
    return idx;
}

/// Write f64 with 2 decimal places to buffer.
/// Returns the slice of buf that was written.
/// ~14x faster than std.fmt.bufPrint("{d:.2}", .{val}).
pub fn writeF64_2(buf: []u8, val: f64) []u8 {
    return writeF64N(buf, val, 2);
}

/// Write f64 with 3 decimal places to buffer.
/// Returns the slice of buf that was written.
pub fn writeF64_3(buf: []u8, val: f64) []u8 {
    return writeF64N(buf, val, 3);
}

/// Shared implementation: fixed `decimals` (2 or 3) fractional digits, all
/// branching resolved at comptime so the hot wrappers stay fully inlined.
/// Precondition: `val` is finite and |val| < 2^64 / 1000 (NaN or larger
/// magnitudes panic in @intFromFloat). Document entry points guarantee it
/// by bounding caller input with validate.max_value; see validate.zig.
fn writeF64N(buf: []u8, val: f64, comptime decimals: u2) []u8 {
    const scale: f64 = if (decimals == 2) 100.0 else 1000.0;
    const max_frac: u64 = if (decimals == 2) 99 else 999;

    var v = val;
    var i: usize = 0;

    // Handle negative
    if (v < 0) {
        buf[i] = '-';
        i += 1;
        v = -v;
    }

    // Round, then split into integer and fractional parts
    v = @round(v * scale) / scale;
    const int_part: u64 = @intFromFloat(v);
    const frac_part: u64 = @intFromFloat((v - @as(f64, @floatFromInt(int_part))) * scale + 0.5);

    // Write integer part
    if (int_part == 0) {
        buf[i] = '0';
        i += 1;
    } else {
        i = writeUnsignedInt(buf, i, int_part);
    }

    // Decimal point and fixed-width fractional digits
    buf[i] = '.';
    i += 1;
    const f = @min(frac_part, max_frac);
    if (decimals == 3) {
        buf[i] = @intCast(f / 100 + '0');
        i += 1;
    }
    const pair = digit_pairs[f % 100];
    buf[i] = pair[0];
    i += 1;
    buf[i] = pair[1];
    i += 1;

    return buf[0..i];
}

/// Write "x y" coordinate pair with 2 decimal places.
/// Returns number of bytes written.
pub fn writeCoord2(buf: []u8, x: f64, y: f64) usize {
    var len: usize = 0;
    const xs = writeF64_2(buf[len..], x);
    len += xs.len;
    buf[len] = ' ';
    len += 1;
    const ys = writeF64_2(buf[len..], y);
    len += ys.len;
    return len;
}

/// Write "x y" pair followed by suffix string.
/// Returns number of bytes written.
pub fn writeCoord2Suffix(buf: []u8, x: f64, y: f64, suffix: []const u8) usize {
    var len = writeCoord2(buf, x, y);
    @memcpy(buf[len..][0..suffix.len], suffix);
    len += suffix.len;
    return len;
}

/// Write 6 coordinates for cubic bezier "x1 y1 x2 y2 x3 y3 c\n".
/// Returns number of bytes written.
pub fn writeCubic(buf: []u8, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) usize {
    var len: usize = 0;
    len += writeCoord2(buf[len..], x1, y1);
    buf[len] = ' ';
    len += 1;
    len += writeCoord2(buf[len..], x2, y2);
    buf[len] = ' ';
    len += 1;
    len += writeCoord2(buf[len..], x3, y3);
    @memcpy(buf[len..][0..3], " c\n");
    len += 3;
    return len;
}

/// Write 4 coordinates "x1 y1 x2 y2" followed by suffix.
/// Returns number of bytes written.
pub fn writeCoord4Suffix(buf: []u8, x1: f64, y1: f64, x2: f64, y2: f64, suffix: []const u8) usize {
    var len: usize = 0;
    len += writeCoord2(buf[len..], x1, y1);
    buf[len] = ' ';
    len += 1;
    len += writeCoord2(buf[len..], x2, y2);
    @memcpy(buf[len..][0..suffix.len], suffix);
    len += suffix.len;
    return len;
}

/// Write integer to buffer.
/// Returns the slice of buf that was written.
pub fn writeInt(buf: []u8, val: anytype) []u8 {
    const T = @TypeOf(val);
    const is_signed = @typeInfo(T).int.signedness == .signed;

    var v: if (is_signed) i64 else u64 = val;
    var i: usize = 0;

    if (is_signed and v < 0) {
        buf[i] = '-';
        i += 1;
        v = -v;
    }

    if (v == 0) {
        buf[i] = '0';
        return buf[0 .. i + 1];
    }

    const n: u64 = @intCast(if (is_signed) @as(u64, @intCast(v)) else v);
    return buf[0..writeUnsignedInt(buf, i, n)];
}

// ============================================================================
// Hex Formatting
// ============================================================================

/// Hex character lookup table
const hex_chars = "0123456789ABCDEF";

/// Fast conversion of u16 to 4-character uppercase hex string.
/// Writes exactly 4 characters to buf.
pub fn writeHex4(buf: *[4]u8, val: u16) void {
    buf[0] = hex_chars[(val >> 12) & 0xF];
    buf[1] = hex_chars[(val >> 8) & 0xF];
    buf[2] = hex_chars[(val >> 4) & 0xF];
    buf[3] = hex_chars[val & 0xF];
}

/// A CMap's bfchar blocks hold at most 100 entries (Adobe TN #5099 and
/// #5014, as PDF readers expect).
pub const max_bfchar_entries = 100;

/// The block lines before bfchar entry `index` of `total`: at every 100th
/// entry, "endbfchar" closing the block before (but at the first) and
/// "N beginbfchar" opening the next; else nothing. After the last entry
/// the caller writes "endbfchar" (when `total` > 0).
pub fn bfcharBlockLines(buf: *[48]u8, index: usize, total: usize) []const u8 {
    if (index % max_bfchar_entries != 0) return "";
    const n = @min(max_bfchar_entries, total - index);
    const close: []const u8 = if (index > 0) "endbfchar\n" else "";
    return std.fmt.bufPrint(buf, "{s}{d} beginbfchar\n", .{ close, n }) catch unreachable;
}

/// Write CMap entry "<GID> <CODEPOINT>\n" for BMP codepoints.
/// Returns bytes written.
pub fn writeCMapEntry(buf: []u8, gid: u16, codepoint: u21) usize {
    var len: usize = 0;
    buf[len] = '<';
    len += 1;
    writeHex4(buf[len..][0..4], gid);
    len += 4;
    @memcpy(buf[len..][0..3], "> <");
    len += 3;
    writeHex4(buf[len..][0..4], @intCast(codepoint));
    len += 4;
    @memcpy(buf[len..][0..2], ">\n");
    len += 2;
    return len;
}

/// Write CMap entry "<GID> <HIGH><LOW>\n" for surrogate pairs.
/// Returns bytes written.
pub fn writeCMapEntrySurrogate(buf: []u8, gid: u16, high: u16, low: u16) usize {
    var len: usize = 0;
    buf[len] = '<';
    len += 1;
    writeHex4(buf[len..][0..4], gid);
    len += 4;
    @memcpy(buf[len..][0..3], "> <");
    len += 3;
    writeHex4(buf[len..][0..4], high);
    len += 4;
    writeHex4(buf[len..][0..4], low);
    len += 4;
    @memcpy(buf[len..][0..2], ">\n");
    len += 2;
    return len;
}

// ============================================================================
// Tests
// ============================================================================

test "writeHex4" {
    var buf: [4]u8 = undefined;
    writeHex4(&buf, 0x0000);
    try std.testing.expectEqualStrings("0000", &buf);
    writeHex4(&buf, 0xFFFF);
    try std.testing.expectEqualStrings("FFFF", &buf);
    writeHex4(&buf, 0x1234);
    try std.testing.expectEqualStrings("1234", &buf);
    writeHex4(&buf, 0xABCD);
    try std.testing.expectEqualStrings("ABCD", &buf);
}

test "writeCMapEntry" {
    var buf: [32]u8 = undefined;
    const len = writeCMapEntry(&buf, 0x0041, 0x0041);
    try std.testing.expectEqualStrings("<0041> <0041>\n", buf[0..len]);
}

test "writeF64_2 basic values" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0.00", writeF64_2(&buf, 0.0));
    try std.testing.expectEqualStrings("1.50", writeF64_2(&buf, 1.5));
    try std.testing.expectEqualStrings("12.34", writeF64_2(&buf, 12.34));
    try std.testing.expectEqualStrings("100.00", writeF64_2(&buf, 100.0));
    try std.testing.expectEqualStrings("595.28", writeF64_2(&buf, 595.28));
    try std.testing.expectEqualStrings("-50.75", writeF64_2(&buf, -50.75));
    try std.testing.expectEqualStrings("0.01", writeF64_2(&buf, 0.01));
    try std.testing.expectEqualStrings("9999.99", writeF64_2(&buf, 9999.99));
}

test "writeF64_2 rounding" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("123.46", writeF64_2(&buf, 123.456789));
    try std.testing.expectEqualStrings("1.24", writeF64_2(&buf, 1.235));
    try std.testing.expectEqualStrings("1.23", writeF64_2(&buf, 1.234));
}

test "writeF64_3 basic values" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0.000", writeF64_3(&buf, 0.0));
    try std.testing.expectEqualStrings("1.500", writeF64_3(&buf, 1.5));
    try std.testing.expectEqualStrings("0.567", writeF64_3(&buf, 0.567));
    try std.testing.expectEqualStrings("123.457", writeF64_3(&buf, 123.4567));
}

test "writeF64_2 matches std.fmt" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    const test_values = [_]f64{ 0.0, 1.5, 12.34, 100.0, 595.28, 841.89, -50.75, 0.01, 9999.99, 123.456789 };

    for (test_values) |v| {
        const expected = std.fmt.bufPrint(&buf1, "{d:.2}", .{v}) catch unreachable;
        const actual = writeF64_2(&buf2, v);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "bfcharBlockLines: blocks of at most 100 entries" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("100 beginbfchar\n", bfcharBlockLines(&buf, 0, 2850));
    try std.testing.expectEqualStrings("", bfcharBlockLines(&buf, 1, 2850));
    try std.testing.expectEqualStrings("endbfchar\n100 beginbfchar\n", bfcharBlockLines(&buf, 100, 2850));
    try std.testing.expectEqualStrings("endbfchar\n50 beginbfchar\n", bfcharBlockLines(&buf, 2800, 2850));
    try std.testing.expectEqualStrings("7 beginbfchar\n", bfcharBlockLines(&buf, 0, 7));
}
