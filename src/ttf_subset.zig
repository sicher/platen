const std = @import("std");
const ttf = @import("ttf.zig");
const binary = @import("binary.zig");

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

/// Calculate TrueType table checksum (sum of 32-bit big-endian values)
pub fn calcTableChecksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    }
    // Handle remaining bytes (pad with zeros)
    if (i < data.len) {
        var last: [4]u8 = .{ 0, 0, 0, 0 };
        const remaining = data.len - i;
        @memcpy(last[0..remaining], data[i..][0..remaining]);
        sum +%= std.mem.readInt(u32, &last, .big);
    }
    return sum;
}

pub fn writeTableEntry(output: []u8, dir_offset: *usize, tag: *const [4]u8, checksum: u32, offset: u32, length: u32) void {
    @memcpy(output[dir_offset.*..][0..4], tag);
    std.mem.writeInt(u32, output[dir_offset.* + 4 ..][0..4], checksum, .big);
    std.mem.writeInt(u32, output[dir_offset.* + 8 ..][0..4], offset, .big);
    std.mem.writeInt(u32, output[dir_offset.* + 12 ..][0..4], length, .big);
    dir_offset.* += 16;
}

/// glyph_id is usize so callers can ask for `gid + 1` (the end of glyph
/// 0xFFFF) without wrapping u16.
pub fn getLocaOffset(loca: []const u8, glyph_id: usize, format: i16) usize {
    if (format == 0) {
        const off = glyph_id * 2;
        if (off + 2 > loca.len) return 0;
        return @as(usize, readU16(loca, off)) * 2;
    } else {
        const off = glyph_id * 4;
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
    var new_hmtx = std.ArrayListUnmanaged(u8).empty;
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

        try binary.appendBE16(&new_hmtx, allocator, advance);
        try binary.appendBEi16(&new_hmtx, allocator, lsb);
    }

    return new_hmtx.toOwnedSlice(allocator);
}

/// Build minimal cmap for CID mode (just .notdef mapping)
pub fn buildMinimalCmap(allocator: std.mem.Allocator) ![]u8 {
    var new_cmap = std.ArrayListUnmanaged(u8).empty;
    errdefer new_cmap.deinit(allocator);

    // cmap header
    try binary.appendBE16(&new_cmap, allocator, 0); // version
    try binary.appendBE16(&new_cmap, allocator, 1); // numTables

    // Encoding record for Windows Unicode BMP
    try binary.appendBE16(&new_cmap, allocator, 3); // platformID
    try binary.appendBE16(&new_cmap, allocator, 1); // encodingID
    try binary.appendBE32(&new_cmap, allocator, 12); // offset

    // Minimal Format 4 subtable (just final segment 0xFFFF)
    const seg_count: u16 = 1;
    const seg_count_x2: u16 = seg_count * 2;

    try binary.appendBE16(&new_cmap, allocator, 4); // format
    try binary.appendBE16(&new_cmap, allocator, 32); // length
    try binary.appendBE16(&new_cmap, allocator, 0); // language
    try binary.appendBE16(&new_cmap, allocator, seg_count_x2);
    try binary.appendBE16(&new_cmap, allocator, 2); // searchRange
    try binary.appendBE16(&new_cmap, allocator, 0); // entrySelector
    try binary.appendBE16(&new_cmap, allocator, 0); // rangeShift
    try binary.appendBE16(&new_cmap, allocator, 0xFFFF); // endCode
    try binary.appendBE16(&new_cmap, allocator, 0); // reservedPad
    try binary.appendBE16(&new_cmap, allocator, 0xFFFF); // startCode
    try binary.appendBEi16(&new_cmap, allocator, 1); // idDelta
    try binary.appendBE16(&new_cmap, allocator, 0); // idRangeOffset

    return new_cmap.toOwnedSlice(allocator);
}

/// Build a minimal name table from the original, keeping only essential entries.
/// This dramatically reduces font size (from ~17KB to ~300 bytes for Gentium fonts).
/// Required name IDs for PDF: 1 (family), 2 (subfamily), 4 (full name), 6 (PostScript name)
pub fn buildMinimalNameTable(allocator: std.mem.Allocator, orig_name: ?[]const u8) ![]u8 {
    var new_name = std.ArrayListUnmanaged(u8).empty;
    errdefer new_name.deinit(allocator);

    // If no original name table, create an empty one
    const name_data = orig_name orelse {
        // Empty name table: format 0, 0 records, storage offset 6
        try binary.appendBE16(&new_name, allocator, 0);
        try binary.appendBE16(&new_name, allocator, 0);
        try binary.appendBE16(&new_name, allocator, 6);
        return new_name.toOwnedSlice(allocator);
    };

    if (name_data.len < 6) {
        // Invalid name table, return empty
        try binary.appendBE16(&new_name, allocator, 0);
        try binary.appendBE16(&new_name, allocator, 0);
        try binary.appendBE16(&new_name, allocator, 6);
        return new_name.toOwnedSlice(allocator);
    }

    // Parse original name table
    const num_records = readU16(name_data, 2);
    const storage_offset = readU16(name_data, 4);

    // Name IDs we want to keep (for Windows Unicode BMP: platform 3, encoding 1)
    const keep_ids = [_]u16{ 1, 2, 4, 6 }; // family, subfamily, full name, PostScript name

    // Collect matching records
    const NameEntry = struct {
        name_id: u16,
        string_data: []const u8,
    };

    var entries = std.ArrayListUnmanaged(NameEntry).empty;
    defer entries.deinit(allocator);

    var next_start: usize = 0; // start offset of the next kept string
    var i: usize = 0;
    while (i < num_records) : (i += 1) {
        const record_offset = 6 + i * 12;
        if (record_offset + 12 > name_data.len) break;

        const platform_id = readU16(name_data, record_offset);
        const encoding_id = readU16(name_data, record_offset + 2);
        const name_id = readU16(name_data, record_offset + 6);
        const str_length = readU16(name_data, record_offset + 8);
        const str_offset = readU16(name_data, record_offset + 10);

        // Only keep Windows Unicode BMP entries (platform 3, encoding 1)
        if (platform_id != 3 or encoding_id != 1) continue;

        // Check if this is a name ID we want
        var keep = false;
        for (keep_ids) |kid| {
            if (name_id == kid) {
                keep = true;
                break;
            }
        }
        if (!keep) continue;

        // Check if we already have this name ID (avoid duplicates)
        var duplicate = false;
        for (entries.items) |e| {
            if (e.name_id == name_id) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        // Extract string data. The rebuilt record stores the string's start
        // as a u16 offset, so an entry that would start past 0xFFFF cannot
        // be represented and is dropped (hostile tables only: real names
        // are a few dozen bytes).
        if (next_start > 0xFFFF) continue;
        const abs_str_offset = @as(usize, storage_offset) + @as(usize, str_offset);
        if (abs_str_offset + str_length <= name_data.len) {
            next_start += str_length;
            try entries.append(allocator, .{
                .name_id = name_id,
                .string_data = name_data[abs_str_offset..][0..str_length],
            });
        }
    }

    // Build minimal name table
    const record_count: u16 = @intCast(entries.items.len);
    const header_size: u16 = 6 + record_count * 12;

    // Header
    try binary.appendBE16(&new_name, allocator, 0); // format
    try binary.appendBE16(&new_name, allocator, record_count);
    try binary.appendBE16(&new_name, allocator, header_size); // storage offset

    // Calculate string offsets and write records
    var str_offset: usize = 0; // <= 0xFFFF for every kept entry (see above)
    for (entries.items) |entry| {
        // Platform 3 (Windows), Encoding 1 (Unicode BMP), Language 0x0409 (English)
        try binary.appendBE16(&new_name, allocator, 3); // platformID
        try binary.appendBE16(&new_name, allocator, 1); // encodingID
        try binary.appendBE16(&new_name, allocator, 0x0409); // languageID
        try binary.appendBE16(&new_name, allocator, entry.name_id);
        try binary.appendBE16(&new_name, allocator, @intCast(entry.string_data.len));
        try binary.appendBE16(&new_name, allocator, @intCast(str_offset));
        str_offset += entry.string_data.len;
    }

    // Write string data
    for (entries.items) |entry| {
        try new_name.appendSlice(allocator, entry.string_data);
    }

    return new_name.toOwnedSlice(allocator);
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
    os2: ?[]const u8, // OS/2 table - required by some PDF validators
    num_glyphs: u16,
};

/// Assemble a complete TTF file from tables
pub fn assembleTTF(allocator: std.mem.Allocator, tables: TTFTables) ![]u8 {
    // Base tables: cmap, glyf, head, hhea, hmtx, loca, maxp, name, post (9)
    // Optional: OS/2 (+1 if present)
    const has_os2 = tables.os2 != null;
    const table_count: u16 = if (has_os2) 10 else 9;
    const header_size: usize = 12 + @as(usize, table_count) * 16;

    // Update hhea with new numOfLongHorMetrics
    if (tables.hhea.len >= 36) {
        std.mem.writeInt(u16, tables.hhea[34..36], tables.num_glyphs, .big);
    }

    // Copy maxp and update numGlyphs (at offset 4)
    // TrueType maxp is 32 bytes (version 1.0), CFF maxp is 6 bytes (version 0.5)
    // We preserve the original table structure and only update numGlyphs
    var new_maxp_buf: [32]u8 = undefined;
    const maxp_len = @min(tables.maxp.len, 32);
    @memcpy(new_maxp_buf[0..maxp_len], tables.maxp[0..maxp_len]);
    std.mem.writeInt(u16, new_maxp_buf[4..6], tables.num_glyphs, .big);

    // Calculate padded sizes and offsets
    const head_padded = padTo4(tables.head.len);
    const hhea_padded = padTo4(tables.hhea.len);
    const maxp_padded = padTo4(maxp_len);
    const hmtx_padded = padTo4(tables.hmtx.len);
    const cmap_padded = padTo4(tables.cmap.len);
    const loca_padded = padTo4(tables.loca.len);
    const glyf_padded = padTo4(tables.glyf.len);
    const name_len = if (tables.name) |n| n.len else 0;
    const name_padded = padTo4(name_len);
    const os2_len = if (tables.os2) |o| o.len else 0;
    const os2_padded = padTo4(os2_len);
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
    const os2_offset = offset;
    offset += @intCast(os2_padded);
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

    // Write table data first (needed for checksum calculation)
    @memcpy(result[head_offset..][0..tables.head.len], tables.head);
    @memcpy(result[hhea_offset..][0..tables.hhea.len], tables.hhea);
    @memcpy(result[maxp_offset..][0..maxp_len], new_maxp_buf[0..maxp_len]);
    @memcpy(result[hmtx_offset..][0..tables.hmtx.len], tables.hmtx);
    @memcpy(result[cmap_offset..][0..tables.cmap.len], tables.cmap);
    @memcpy(result[loca_offset..][0..tables.loca.len], tables.loca);
    @memcpy(result[glyf_offset..][0..tables.glyf.len], tables.glyf);

    if (tables.name) |name_data| {
        @memcpy(result[name_offset..][0..name_data.len], name_data);
    }

    if (tables.os2) |os2_data| {
        @memcpy(result[os2_offset..][0..os2_data.len], os2_data);
    }

    if (tables.post) |post_data| {
        const copy_len = @min(post_data.len, 32);
        @memcpy(result[post_offset..][0..copy_len], post_data[0..copy_len]);
        // Force post table to version 3.0 (no glyph names)
        // Version 2.0 requires glyph name data beyond the 32-byte header
        // Version 3.0 is exactly 32 bytes with no additional data required
        std.mem.writeInt(u32, result[post_offset..][0..4], 0x00030000, .big);
    } else {
        // Minimal post table - version 3.0
        std.mem.writeInt(u32, result[post_offset..][0..4], 0x00030000, .big);
    }

    // Calculate checksums after table data is written
    const cmap_checksum = calcTableChecksum(result[cmap_offset..][0..tables.cmap.len]);
    const glyf_checksum = calcTableChecksum(result[glyf_offset..][0..tables.glyf.len]);
    const head_checksum = calcTableChecksum(result[head_offset..][0..tables.head.len]);
    const hhea_checksum = calcTableChecksum(result[hhea_offset..][0..tables.hhea.len]);
    const hmtx_checksum = calcTableChecksum(result[hmtx_offset..][0..tables.hmtx.len]);
    const loca_checksum = calcTableChecksum(result[loca_offset..][0..tables.loca.len]);
    const maxp_checksum = calcTableChecksum(result[maxp_offset..][0..maxp_len]);
    const name_checksum = calcTableChecksum(result[name_offset..][0..name_len]);
    const os2_checksum = calcTableChecksum(result[os2_offset..][0..os2_len]);
    const post_checksum = calcTableChecksum(result[post_offset..][0..post_len]);

    // Write table directory with checksums (alphabetically sorted)
    var dir_offset: usize = 12;
    writeTableEntry(result, &dir_offset, "cmap", cmap_checksum, cmap_offset, @intCast(tables.cmap.len));
    writeTableEntry(result, &dir_offset, "glyf", glyf_checksum, glyf_offset, @intCast(tables.glyf.len));
    writeTableEntry(result, &dir_offset, "head", head_checksum, head_offset, @intCast(tables.head.len));
    writeTableEntry(result, &dir_offset, "hhea", hhea_checksum, hhea_offset, @intCast(tables.hhea.len));
    writeTableEntry(result, &dir_offset, "hmtx", hmtx_checksum, hmtx_offset, @intCast(tables.hmtx.len));
    writeTableEntry(result, &dir_offset, "loca", loca_checksum, loca_offset, @intCast(tables.loca.len));
    writeTableEntry(result, &dir_offset, "maxp", maxp_checksum, maxp_offset, @intCast(maxp_len));
    writeTableEntry(result, &dir_offset, "name", name_checksum, name_offset, @intCast(name_len));
    if (has_os2) {
        writeTableEntry(result, &dir_offset, "OS/2", os2_checksum, os2_offset, @intCast(os2_len));
    }
    writeTableEntry(result, &dir_offset, "post", post_checksum, post_offset, @intCast(post_len));

    return result;
}

// =============================================================================
// Composite Glyph Handling
// =============================================================================

/// Get all component glyph IDs referenced by a composite glyph
pub fn getCompositeComponents(glyf: []const u8, loca: []const u8, loca_format: i16, glyph_id: u16) [16]u16 {
    var components: [16]u16 = @splat(0);
    var comp_idx: usize = 0;

    const glyph_offset = getLocaOffset(loca, glyph_id, loca_format);
    const next_offset = getLocaOffset(loca, @as(usize, glyph_id) + 1, loca_format);

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
        var glyphs_to_check = std.ArrayListUnmanaged(u16).empty;
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

test "buildMinimalNameTable null input" {
    const allocator = std.testing.allocator;
    const name = try buildMinimalNameTable(allocator, null);
    defer allocator.free(name);

    // Should produce empty name table: format(2) + count(2) + offset(2) = 6 bytes
    try std.testing.expectEqual(@as(usize, 6), name.len);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, name[0..2], .big)); // format
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, name[2..4], .big)); // count
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, name[4..6], .big)); // storage offset
}

test "buildMinimalNameTable extracts essential entries" {
    const allocator = std.testing.allocator;

    // Build a sample name table with 2 records (name IDs 1 and 6)
    // Format: header(6) + records(12 each) + strings
    var name_data = [_]u8{
        0x00, 0x00, // format = 0
        0x00, 0x02, // numRecords = 2
        0x00, 0x1E, // storageOffset = 30 (6 + 2*12 = 30)
        // Record 1: Platform 3 (Windows), Encoding 1 (Unicode), Language 0x0409, Name ID 1
        0x00, 0x03, // platformID
        0x00, 0x01, // encodingID
        0x04, 0x09, // languageID
        0x00, 0x01, // nameID = 1 (family)
        0x00, 0x08, // length = 8 bytes (4 UTF-16 chars)
        0x00, 0x00, // offset = 0
        // Record 2: Platform 3 (Windows), Encoding 1 (Unicode), Language 0x0409, Name ID 6
        0x00, 0x03, // platformID
        0x00, 0x01, // encodingID
        0x04, 0x09, // languageID
        0x00, 0x06, // nameID = 6 (PostScript)
        0x00, 0x08, // length = 8 bytes
        0x00, 0x08, // offset = 8
        // String data: "Test" (UTF-16BE)
        0x00, 'T', 0x00, 'e', 0x00, 's', 0x00, 't',
        // String data: "Font" (UTF-16BE)
        0x00, 'F', 0x00, 'o', 0x00, 'n', 0x00, 't',
    };

    const min_name = try buildMinimalNameTable(allocator, &name_data);
    defer allocator.free(min_name);

    // Should have 2 records (IDs 1 and 6 are kept)
    const record_count = std.mem.readInt(u16, min_name[2..4], .big);
    try std.testing.expectEqual(@as(u16, 2), record_count);

    // Size should be much smaller than a typical 17KB name table
    try std.testing.expect(min_name.len < 100);
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

// Overflow regression tests (2026-10-05 audit): each panicked before the fix.

test "composite lookup for gid 0xFFFF does not overflow" {
    const loca: [8]u8 = @splat(0);
    const comps = getCompositeComponents(&.{}, &loca, 1, 0xFFFF);
    for (comps) |c| try std.testing.expectEqual(@as(u16, 0), c);
}

test "minimal name table drops names whose offsets would exceed u16" {
    // Two kept records (IDs 1 and 6), each 0x8000 bytes long, sharing one
    // storage area: the rebuilt string offset (u16) would pass 0xFFFF.
    const allocator = std.testing.allocator;
    const header = 6 + 2 * 12;
    const name_data = try allocator.alloc(u8, header + 0x8000);
    defer allocator.free(name_data);
    @memset(name_data, 0);
    std.mem.writeInt(u16, name_data[2..4], 2, .big); // numRecords
    std.mem.writeInt(u16, name_data[4..6], header, .big); // storageOffset
    for ([_]u16{ 1, 6 }, 0..) |id, k| {
        const r = name_data[6 + k * 12 ..][0..12];
        std.mem.writeInt(u16, r[0..2], 3, .big); // platform
        std.mem.writeInt(u16, r[2..4], 1, .big); // encoding
        std.mem.writeInt(u16, r[6..8], id, .big); // nameID
        std.mem.writeInt(u16, r[8..10], 0x8000, .big); // length
    }

    const min_name = try buildMinimalNameTable(allocator, name_data);
    defer allocator.free(min_name);
    // Both fit (offsets 0 and 0x8000); a third would not.
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, min_name[2..4], .big));
}

test "minimal name table caps total string storage at u16 offsets" {
    const allocator = std.testing.allocator;
    const header = 6 + 3 * 12;
    const name_data = try allocator.alloc(u8, header + 0xFFFF);
    defer allocator.free(name_data);
    @memset(name_data, 0);
    std.mem.writeInt(u16, name_data[2..4], 3, .big);
    std.mem.writeInt(u16, name_data[4..6], header, .big);
    for ([_]u16{ 1, 4, 6 }, 0..) |id, k| {
        const r = name_data[6 + k * 12 ..][0..12];
        std.mem.writeInt(u16, r[0..2], 3, .big);
        std.mem.writeInt(u16, r[2..4], 1, .big);
        std.mem.writeInt(u16, r[6..8], id, .big);
        std.mem.writeInt(u16, r[8..10], 0xFFFF, .big);
    }
    const min_name = try buildMinimalNameTable(allocator, name_data);
    defer allocator.free(min_name);
    // Record starts are 0, 0xFFFF, 0x1FFFE: only the first two are
    // representable (the offset field holds where a string starts).
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, min_name[2..4], .big));
}
