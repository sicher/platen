const std = @import("std");
const ttf = @import("ttf.zig");

// =============================================================================
// Common Utilities
// =============================================================================

pub fn readU16(data: []const u8, offset: usize) u16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

pub fn readI16(data: []const u8, offset: usize) i16 {
    return @bitCast(readU16(data, offset));
}

pub fn readU32(data: []const u8, offset: usize) u32 {
    if (offset + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

pub fn padTo4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

pub fn writeTableEntry(output: []u8, dir_offset: *usize, tag: *const [4]u8, offset: u32, length: u32) void {
    @memcpy(output[dir_offset.*..][0..4], tag);
    std.mem.writeInt(u32, output[dir_offset.* + 4 ..][0..4], 0, .big); // checksum placeholder
    std.mem.writeInt(u32, output[dir_offset.* + 8 ..][0..4], offset, .big);
    std.mem.writeInt(u32, output[dir_offset.* + 12 ..][0..4], length, .big);
    dir_offset.* += 16;
}

pub fn getLocaOffset(loca: []const u8, glyph_id: u16, format: i16) usize {
    if (format == 0) {
        const off = @as(usize, glyph_id) * 2;
        if (off + 2 > loca.len) return 0;
        return @as(usize, readU16(loca, off)) * 2;
    } else {
        const off = @as(usize, glyph_id) * 4;
        if (off + 4 > loca.len) return 0;
        return readU32(loca, off);
    }
}

// =============================================================================
// TTF Table Building Helpers
// =============================================================================

/// Build hmtx table for a list of glyph IDs
pub fn buildHmtxForGlyphs(
    allocator: std.mem.Allocator,
    orig_hmtx: []const u8,
    num_long_hor_metrics: u16,
    glyph_ids: []const u16,
) ![]u8 {
    var new_hmtx = std.ArrayListUnmanaged(u8){};
    errdefer new_hmtx.deinit(allocator);

    for (glyph_ids) |gid| {
        var advance: u16 = 0;
        var lsb: i16 = 0;

        if (gid < num_long_hor_metrics) {
            const off = @as(usize, gid) * 4;
            if (off + 4 <= orig_hmtx.len) {
                advance = readU16(orig_hmtx, off);
                lsb = readI16(orig_hmtx, off + 2);
            }
        } else {
            // Use last advance width
            if (num_long_hor_metrics > 0) {
                const off = (@as(usize, num_long_hor_metrics) - 1) * 4;
                if (off + 2 <= orig_hmtx.len) {
                    advance = readU16(orig_hmtx, off);
                }
            }
            // lsb from separate array
            const lsb_idx = gid - num_long_hor_metrics;
            const lsb_off = @as(usize, num_long_hor_metrics) * 4 + @as(usize, lsb_idx) * 2;
            if (lsb_off + 2 <= orig_hmtx.len) {
                lsb = readI16(orig_hmtx, lsb_off);
            }
        }

        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, advance)));
        try new_hmtx.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, lsb)));
    }

    return new_hmtx.toOwnedSlice(allocator);
}

/// Build minimal cmap for CID mode (just .notdef mapping)
pub fn buildMinimalCmap(allocator: std.mem.Allocator) ![]u8 {
    var new_cmap = std.ArrayListUnmanaged(u8){};
    errdefer new_cmap.deinit(allocator);

    // cmap header
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // version
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // numTables

    // Encoding record for Windows Unicode BMP
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 3))); // platformID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 1))); // encodingID
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, 12))); // offset

    // Minimal Format 4 subtable (just final segment 0xFFFF)
    const seg_count: u16 = 1;
    const seg_count_x2: u16 = seg_count * 2;

    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 4))); // format
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 32))); // length
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // language
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, seg_count_x2)));
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 2))); // searchRange
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // entrySelector
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // rangeShift
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // endCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // reservedPad
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0xFFFF))); // startCode
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, 1))); // idDelta
    try new_cmap.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // idRangeOffset

    return new_cmap.toOwnedSlice(allocator);
}

/// TTF table data for assembly
pub const TTFTables = struct {
    head: []const u8,
    hhea: []u8, // mutable to update numOfLongHorMetrics
    maxp: []const u8,
    hmtx: []const u8,
    cmap: []const u8,
    loca: []const u8,
    glyf: []const u8,
    name: ?[]const u8,
    post: ?[]const u8,
    num_glyphs: u16,
};

/// Assemble a complete TTF file from tables
pub fn assembleTTF(allocator: std.mem.Allocator, tables: TTFTables) ![]u8 {
    const table_count: u16 = 9;
    const header_size: usize = 12 + @as(usize, table_count) * 16;

    // Update hhea with new numOfLongHorMetrics
    if (tables.hhea.len >= 36) {
        std.mem.writeInt(u16, tables.hhea[34..36], tables.num_glyphs, .big);
    }

    // Build maxp
    var new_maxp: [6]u8 = undefined;
    std.mem.writeInt(u32, new_maxp[0..4], 0x00005000, .big);
    std.mem.writeInt(u16, new_maxp[4..6], tables.num_glyphs, .big);

    // Calculate padded sizes and offsets
    const head_padded = padTo4(tables.head.len);
    const hhea_padded = padTo4(tables.hhea.len);
    const maxp_padded = padTo4(new_maxp.len);
    const hmtx_padded = padTo4(tables.hmtx.len);
    const cmap_padded = padTo4(tables.cmap.len);
    const loca_padded = padTo4(tables.loca.len);
    const glyf_padded = padTo4(tables.glyf.len);
    const name_len = if (tables.name) |n| n.len else 0;
    const name_padded = padTo4(name_len);
    const post_len = if (tables.post) |p| @min(p.len, 32) else 32;
    const post_padded = padTo4(post_len);

    var offset: u32 = @intCast(header_size);
    const head_offset = offset;
    offset += @intCast(head_padded);
    const hhea_offset = offset;
    offset += @intCast(hhea_padded);
    const maxp_offset = offset;
    offset += @intCast(maxp_padded);
    const hmtx_offset = offset;
    offset += @intCast(hmtx_padded);
    const cmap_offset = offset;
    offset += @intCast(cmap_padded);
    const loca_offset = offset;
    offset += @intCast(loca_padded);
    const glyf_offset = offset;
    offset += @intCast(glyf_padded);
    const name_offset = offset;
    offset += @intCast(name_padded);
    const post_offset = offset;
    offset += @intCast(post_padded);

    const total_size = offset;

    // Allocate and build the file
    const result = try allocator.alloc(u8, total_size);
    errdefer allocator.free(result);
    @memset(result, 0);

    // Write header
    std.mem.writeInt(u32, result[0..4], 0x00010000, .big); // sfntVersion
    std.mem.writeInt(u16, result[4..6], table_count, .big);
    std.mem.writeInt(u16, result[6..8], 128, .big); // searchRange
    std.mem.writeInt(u16, result[8..10], 3, .big); // entrySelector
    std.mem.writeInt(u16, result[10..12], 16, .big); // rangeShift

    // Write table directory
    var dir_offset: usize = 12;
    writeTableEntry(result, &dir_offset, "cmap", cmap_offset, @intCast(tables.cmap.len));
    writeTableEntry(result, &dir_offset, "glyf", glyf_offset, @intCast(tables.glyf.len));
    writeTableEntry(result, &dir_offset, "head", head_offset, @intCast(tables.head.len));
    writeTableEntry(result, &dir_offset, "hhea", hhea_offset, @intCast(tables.hhea.len));
    writeTableEntry(result, &dir_offset, "hmtx", hmtx_offset, @intCast(tables.hmtx.len));
    writeTableEntry(result, &dir_offset, "loca", loca_offset, @intCast(tables.loca.len));
    writeTableEntry(result, &dir_offset, "maxp", maxp_offset, @intCast(new_maxp.len));
    writeTableEntry(result, &dir_offset, "name", name_offset, @intCast(name_len));
    writeTableEntry(result, &dir_offset, "post", post_offset, @intCast(post_len));

    // Write table data
    @memcpy(result[head_offset..][0..tables.head.len], tables.head);
    @memcpy(result[hhea_offset..][0..tables.hhea.len], tables.hhea);
    @memcpy(result[maxp_offset..][0..new_maxp.len], &new_maxp);
    @memcpy(result[hmtx_offset..][0..tables.hmtx.len], tables.hmtx);
    @memcpy(result[cmap_offset..][0..tables.cmap.len], tables.cmap);
    @memcpy(result[loca_offset..][0..tables.loca.len], tables.loca);
    @memcpy(result[glyf_offset..][0..tables.glyf.len], tables.glyf);

    if (tables.name) |name_data| {
        @memcpy(result[name_offset..][0..name_data.len], name_data);
    }

    if (tables.post) |post_data| {
        const copy_len = @min(post_data.len, 32);
        @memcpy(result[post_offset..][0..copy_len], post_data[0..copy_len]);
    } else {
        // Minimal post table
        std.mem.writeInt(u32, result[post_offset..][0..4], 0x00020000, .big);
    }

    return result;
}

// =============================================================================
// Composite Glyph Handling
// =============================================================================

/// Get all component glyph IDs referenced by a composite glyph
pub fn getCompositeComponents(glyf: []const u8, loca: []const u8, loca_format: i16, glyph_id: u16) [16]u16 {
    var components: [16]u16 = [_]u16{0} ** 16;
    var comp_idx: usize = 0;

    const glyph_offset = getLocaOffset(loca, glyph_id, loca_format);
    const next_offset = getLocaOffset(loca, glyph_id + 1, loca_format);

    if (next_offset <= glyph_offset) return components;
    const glyph_len = next_offset - glyph_offset;
    if (glyph_len < 10 or glyph_offset + glyph_len > glyf.len) return components;

    const glyph_data = glyf[glyph_offset..][0..glyph_len];
    const num_contours = readI16(glyph_data, 0);

    if (num_contours >= 0) return components; // Simple glyph

    // Composite glyph - parse components
    var pos: usize = 10;
    while (pos + 4 <= glyph_data.len and comp_idx < 16) {
        const flags = readU16(glyph_data, pos);
        const component_gid = readU16(glyph_data, pos + 2);

        components[comp_idx] = component_gid;
        comp_idx += 1;

        pos += 4;

        // Skip arguments
        if (flags & 0x0001 != 0) {
            pos += 4; // ARG_1_AND_2_ARE_WORDS
        } else {
            pos += 2;
        }

        // Skip transformation
        if (flags & 0x0008 != 0) {
            pos += 2; // WE_HAVE_A_SCALE
        } else if (flags & 0x0040 != 0) {
            pos += 4; // WE_HAVE_AN_X_AND_Y_SCALE
        } else if (flags & 0x0080 != 0) {
            pos += 8; // WE_HAVE_A_TWO_BY_TWO
        }

        if (flags & 0x0020 == 0) break; // No more components
    }

    return components;
}

/// Recursively expand a glyph set to include all composite glyph components.
/// Keeps expanding until no new glyphs are added.
pub fn expandCompositeGlyphs(
    allocator: std.mem.Allocator,
    glyph_set: *std.AutoHashMapUnmanaged(u16, void),
    glyf: []const u8,
    loca: []const u8,
    loca_format: i16,
    max_glyphs: u16,
) !void {
    var changed = true;
    while (changed) {
        changed = false;

        // Collect current glyphs to check (can't modify while iterating)
        var glyphs_to_check = std.ArrayListUnmanaged(u16){};
        defer glyphs_to_check.deinit(allocator);

        var check_iter = glyph_set.keyIterator();
        while (check_iter.next()) |gid| {
            try glyphs_to_check.append(allocator, gid.*);
        }

        for (glyphs_to_check.items) |gid| {
            const components = getCompositeComponents(glyf, loca, loca_format, gid);
            for (components) |comp_gid| {
                if (comp_gid != 0 and comp_gid < max_glyphs and !glyph_set.contains(comp_gid)) {
                    try glyph_set.put(allocator, comp_gid, {});
                    changed = true;
                }
            }
        }
    }
}

/// Rewrite composite glyph component IDs using the remap table
pub fn rewriteCompositeGlyphIDs(glyph_data: []u8, remap: *const std.AutoArrayHashMapUnmanaged(u16, u16)) !void {
    if (glyph_data.len < 10) return;

    // Skip header (numberOfContours, xMin, yMin, xMax, yMax)
    var pos: usize = 10;

    while (pos + 4 <= glyph_data.len) {
        const flags = std.mem.readInt(u16, glyph_data[pos..][0..2], .big);
        const old_gid = std.mem.readInt(u16, glyph_data[pos + 2 ..][0..2], .big);

        // Remap the glyph ID
        const new_gid = remap.get(old_gid) orelse old_gid;
        std.mem.writeInt(u16, glyph_data[pos + 2 ..][0..2], new_gid, .big);

        pos += 4;

        // Skip arguments based on flags
        if (flags & 0x0001 != 0) {
            pos += 4; // ARG_1_AND_2_ARE_WORDS
        } else {
            pos += 2;
        }

        // Skip transformation based on flags
        if (flags & 0x0008 != 0) {
            pos += 2; // WE_HAVE_A_SCALE
        } else if (flags & 0x0040 != 0) {
            pos += 4; // WE_HAVE_AN_X_AND_Y_SCALE
        } else if (flags & 0x0080 != 0) {
            pos += 8; // WE_HAVE_A_TWO_BY_TWO
        }

        // Check if more components
        if (flags & 0x0020 == 0) break;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "readU16 basic" {
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try std.testing.expectEqual(@as(u16, 0x1234), readU16(&data, 0));
    try std.testing.expectEqual(@as(u16, 0x3456), readU16(&data, 1));
}

test "readU16 out of bounds" {
    const data = [_]u8{ 0x12 };
    try std.testing.expectEqual(@as(u16, 0), readU16(&data, 0));
}

test "padTo4" {
    try std.testing.expectEqual(@as(usize, 0), padTo4(0));
    try std.testing.expectEqual(@as(usize, 4), padTo4(1));
    try std.testing.expectEqual(@as(usize, 4), padTo4(4));
    try std.testing.expectEqual(@as(usize, 8), padTo4(5));
}

test "buildHmtxForGlyphs basic" {
    const allocator = std.testing.allocator;

    // Create a simple hmtx with 2 long metrics
    const orig_hmtx = [_]u8{
        0x02, 0x00, 0x00, 0x10, // glyph 0: advance=512, lsb=16
        0x03, 0x00, 0x00, 0x20, // glyph 1: advance=768, lsb=32
    };

    const glyph_ids = [_]u16{ 0, 1 };
    const result = try buildHmtxForGlyphs(allocator, &orig_hmtx, 2, &glyph_ids);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 8), result.len);
}

test "buildMinimalCmap" {
    const allocator = std.testing.allocator;
    const cmap = try buildMinimalCmap(allocator);
    defer allocator.free(cmap);

    // Should have header + encoding record + format 4
    try std.testing.expect(cmap.len > 0);
    // Version should be 0
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, cmap[0..2], .big));
}

test "rewriteCompositeGlyphIDs remaps component references" {
    var glyph_data = [_]u8{
        0xFF, 0xFF, // numberOfContours = -1 (composite)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x64, // bounds
        0x00, 0x00, // flags
        0x00, 0x64, // glyphIndex = 100
        0x00, 0x00, // args
    };

    var remap = std.AutoArrayHashMapUnmanaged(u16, u16){};
    defer remap.deinit(std.testing.allocator);
    try remap.put(std.testing.allocator, 100, 5);

    try rewriteCompositeGlyphIDs(&glyph_data, &remap);

    const new_gid = std.mem.readInt(u16, glyph_data[12..14], .big);
    try std.testing.expectEqual(@as(u16, 5), new_gid);
}
