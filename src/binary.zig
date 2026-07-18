//! Binary serialization helpers for big-endian data (TrueType/OpenType).
//!
//! Provides convenience functions for appending big-endian integers to
//! buffers, plus bounds-checked big-endian readers (returning 0 on
//! overflow) shared by the color-font table parsers. Note that ttf.zig /
//! opentype.zig keep their own unchecked readers by design: those run in
//! hot per-glyph paths on already-validated tables.

const std = @import("std");

// ============================================================================
// Bounds-checked big-endian readers
// ============================================================================

pub fn readU8(data: []const u8, off: usize) u8 {
    if (off >= data.len) return 0;
    return data[off];
}

pub fn readU16(data: []const u8, off: usize) u16 {
    if (off + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

pub fn readI16(data: []const u8, off: usize) i16 {
    if (off + 2 > data.len) return 0;
    return std.mem.readInt(i16, data[off..][0..2], .big);
}

pub fn readU24(data: []const u8, off: usize) u32 {
    if (off + 3 > data.len) return 0;
    return (@as(u32, data[off]) << 16) | (@as(u32, data[off + 1]) << 8) | data[off + 2];
}

pub fn readU32(data: []const u8, off: usize) u32 {
    if (off + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

/// Read an F2Dot14 fixed-point value as an f64.
pub fn readF2Dot14(data: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(readI16(data, off))) / 16384.0;
}

/// Read a Fixed (16.16) value as an f64.
pub fn readFixed(data: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(@as(i32, @bitCast(readU32(data, off))))) / 65536.0;
}

/// Append a big-endian u16 to an array list.
pub fn appendBE16(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u16) !void {
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, value)));
}

/// Append a big-endian u32 to an array list.
pub fn appendBE32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, value)));
}

/// Append a big-endian i16 to an array list.
pub fn appendBEi16(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i16) !void {
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, value)));
}

/// Append a big-endian i32 to an array list.
pub fn appendBEi32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: i32) !void {
    try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, value)));
}

test "appendBE16" {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(std.testing.allocator);

    try appendBE16(&list, std.testing.allocator, 0x1234);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34 }, list.items);
}

test "appendBE32" {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(std.testing.allocator);

    try appendBE32(&list, std.testing.allocator, 0x12345678);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }, list.items);
}

test "appendBEi16" {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(std.testing.allocator);

    try appendBEi16(&list, std.testing.allocator, -1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF }, list.items);
}
