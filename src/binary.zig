//! Binary serialization helpers for big-endian data (TrueType/OpenType).
//!
//! Provides convenience functions for appending big-endian integers to buffers,
//! reducing verbosity of std.mem.toBytes(std.mem.nativeToBig(...)) pattern.

const std = @import("std");

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
