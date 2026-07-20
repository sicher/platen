//! zlib compression for PDF streams
//!
//! Uses std.compress.flate for deflate/inflate compression.
//! PDF uses FlateDecode filter which is zlib-format (deflate + 2-byte header + adler32 checksum).

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    CompressionFailed,
    DecompressionFailed,
    OutOfMemory,
};

/// Compress data using zlib (deflate with zlib header/checksum) at the
/// default compression level. Returns compressed data owned by the allocator.
pub fn compress(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    return compressLevel(allocator, input, 6);
}

/// Compress data with specified compression level (0-9)
/// Level 0 = no compression, 1 = fastest, 9 = best compression
pub fn compressLevel(allocator: std.mem.Allocator, input: []const u8, level: i32) Error![]u8 {
    if (input.len == 0) {
        return allocator.dupe(u8, &[_]u8{}) catch return Error.OutOfMemory;
    }

    const opts: flate.Compress.Options = switch (level) {
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        9 => .level_9,
        else => .level_1,
    };

    var out = std.Io.Writer.Allocating.initCapacity(allocator, @max(64, input.len / 2)) catch
        return Error.OutOfMemory;
    defer out.deinit();

    var window: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&out.writer, &window, .zlib, opts) catch
        return Error.CompressionFailed;
    comp.writer.writeAll(input) catch return Error.CompressionFailed;
    comp.finish() catch return Error.CompressionFailed;

    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Decompress zlib-compressed data
/// Caller must know the uncompressed size
pub fn decompress(allocator: std.mem.Allocator, input: []const u8, uncompressed_size: usize) Error![]u8 {
    if (input.len == 0 or uncompressed_size == 0) {
        return allocator.dupe(u8, &[_]u8{}) catch return Error.OutOfMemory;
    }

    const output = allocator.alloc(u8, uncompressed_size) catch return Error.OutOfMemory;
    errdefer allocator.free(output);

    var in: std.Io.Reader = .fixed(input);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &window);
    d.reader.readSliceAll(output) catch return Error.DecompressionFailed;

    return output;
}

// Unit tests
test "compress and decompress roundtrip" {
    const allocator = std.testing.allocator;
    // Use repetitive text that compresses well
    const input = "Hello, world! This is a test of zlib compression. " ** 10;

    const compressed = try compress(allocator, input);
    defer allocator.free(compressed);

    // Compression should make it smaller for repetitive input
    try std.testing.expect(compressed.len < input.len);

    const decompressed = try decompress(allocator, compressed, input.len);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(input, decompressed);
}

test "compress empty input" {
    const allocator = std.testing.allocator;
    const compressed = try compress(allocator, "");
    defer allocator.free(compressed);
    try std.testing.expectEqual(@as(usize, 0), compressed.len);
}

test "compress with level" {
    const allocator = std.testing.allocator;
    const input = "Repeated text. " ** 50;

    // Level 1 (fast) vs Level 9 (best)
    const fast = try compressLevel(allocator, input, 1);
    defer allocator.free(fast);

    const best = try compressLevel(allocator, input, 9);
    defer allocator.free(best);

    // Both should be smaller than input
    try std.testing.expect(fast.len < input.len);
    try std.testing.expect(best.len < input.len);

    // Level 9 should be at least as good as level 1
    try std.testing.expect(best.len <= fast.len);
}
