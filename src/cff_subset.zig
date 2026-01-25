const std = @import("std");

// Import common utilities from ttf_subset
const ttf_subset = @import("ttf_subset.zig");
pub const readU16 = ttf_subset.readU16;
pub const readI16 = ttf_subset.readI16;
pub const readU32 = ttf_subset.readU32;

// =============================================================================
// CFF INDEX Structures
// =============================================================================

/// CFF INDEX structure for parsing font data
pub const CFFIndex = struct {
    count: u16,
    off_size: u8,
    offsets_start: usize,
    data_start: usize,
    data: []const u8,

    pub fn getEntry(self: *const CFFIndex, index: u16) ?[]const u8 {
        if (index >= self.count) return null;
        const start = readCFFOffset(self.data, self.offsets_start, index, self.off_size);
        const end = readCFFOffset(self.data, self.offsets_start, index + 1, self.off_size);
        if (start == 0 or end <= start) return null;
        const abs_start = self.data_start + start - 1;
        const abs_end = self.data_start + end - 1;
        if (abs_end > self.data.len) return null;
        return self.data[abs_start..abs_end];
    }
};

pub fn parseCFFIndex(data: []const u8, offset: usize) ?CFFIndex {
    if (offset + 2 > data.len) return null;
    const count = readU16(data, offset);
    if (count == 0) return CFFIndex{ .count = 0, .off_size = 0, .offsets_start = 0, .data_start = 0, .data = data };

    const off_size = data[offset + 2];
    const offsets_start = offset + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;
    return CFFIndex{ .count = count, .off_size = off_size, .offsets_start = offsets_start, .data_start = data_start, .data = data };
}

/// Calculate the byte size of a CFF dict operand starting at the given position.
/// Handles integer operands (1-5 bytes) and real number operands (variable length).
/// Returns the total number of bytes to advance.
fn cffOperandSize(data: []const u8, pos: usize) usize {
    const b0 = data[pos];
    if (b0 == 28) {
        return 3; // 2-byte integer
    } else if (b0 == 29) {
        return 5; // 4-byte integer
    } else if (b0 == 30) {
        // Real number - scan for end nibble (0xf)
        var i: usize = pos + 1;
        while (i < data.len and (data[i] & 0xf) != 0xf and (data[i] >> 4) != 0xf) : (i += 1) {}
        return i + 1 - pos;
    } else if (b0 >= 247 and b0 <= 254) {
        return 2; // 2-byte integer
    } else {
        return 1; // 1-byte integer (32-246) or unknown
    }
}

pub fn skipCFFIndex(data: []const u8, offset: usize) usize {
    if (offset + 2 > data.len) return offset;
    const count = readU16(data, offset);
    if (count == 0) return offset + 2;

    const off_size = data[offset + 2];
    const offsets_end = offset + 3 + (@as(usize, count) + 1) * off_size;
    if (offsets_end > data.len) return offset;

    const last_offset = readCFFOffset(data, offset + 3, count, off_size);
    return offsets_end + last_offset - 1;
}

pub fn readCFFOffset(data: []const u8, base: usize, index: u16, off_size: u8) usize {
    const pos = base + @as(usize, index) * off_size;
    if (pos + off_size > data.len) return 0;

    return switch (off_size) {
        1 => data[pos],
        2 => readU16(data, pos),
        3 => (@as(usize, data[pos]) << 16) | (@as(usize, data[pos + 1]) << 8) | data[pos + 2],
        4 => readU32(data, pos),
        else => 0,
    };
}

// =============================================================================
// SID Remapping for String INDEX Subsetting
// =============================================================================

/// Standard CFF string count (SIDs 0-390 are predefined)
pub const STANDARD_STRING_COUNT: u16 = 391;

/// Collect all SIDs used in Top DICT
/// Top DICT operators that take SID operands:
/// - 0: version, 1: Notice, 2: FullName, 3: FamilyName, 4: Weight
/// - 12 0: Copyright, 12 21: PostScript, 12 22: BaseFontName
/// - 12 30: ROS (first two operands are SIDs)
pub fn collectTopDictSIDs(
    allocator: std.mem.Allocator,
    cff_data: []const u8,
    topdict_index_start: usize,
) !std.ArrayListUnmanaged(u16) {
    var sids = std.ArrayListUnmanaged(u16){};
    errdefer sids.deinit(allocator);

    const index = parseCFFIndex(cff_data, topdict_index_start) orelse return sids;
    const dict_data = index.getEntry(0) orelse return sids;

    // Parse dict, tracking operands
    var operands: [48]i32 = undefined;
    var op_count: usize = 0;
    var i: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];

        if (b0 == 12) {
            // Two-byte operator
            if (i + 1 < dict_data.len) {
                const b1 = dict_data[i + 1];
                if (b1 == 0 or b1 == 21 or b1 == 22) {
                    // Copyright, PostScript, BaseFontName - single SID operand
                    if (op_count >= 1 and operands[op_count - 1] >= 0) {
                        try sids.append(allocator, @intCast(operands[op_count - 1]));
                    }
                } else if (b1 == 30) {
                    // ROS - first two operands are SIDs (Registry, Ordering)
                    if (op_count >= 2) {
                        if (operands[op_count - 3] >= 0) try sids.append(allocator, @intCast(operands[op_count - 3]));
                        if (operands[op_count - 2] >= 0) try sids.append(allocator, @intCast(operands[op_count - 2]));
                    }
                }
            }
            i += 2;
            op_count = 0;
        } else if (b0 <= 4) {
            // version, Notice, FullName, FamilyName, Weight - single SID operand
            if (op_count >= 1 and operands[op_count - 1] >= 0) {
                try sids.append(allocator, @intCast(operands[op_count - 1]));
            }
            i += 1;
            op_count = 0;
        } else if (b0 <= 21) {
            // Other single-byte operator
            i += 1;
            op_count = 0;
        } else if (b0 == 28) {
            if (op_count < 48) {
                operands[op_count] = @as(i32, @as(i16, @bitCast(readU16(dict_data, i + 1))));
                op_count += 1;
            }
            i += 3;
        } else if (b0 == 29) {
            if (op_count < 48) {
                operands[op_count] = @as(i32, @bitCast(readU32(dict_data, i + 1)));
                op_count += 1;
            }
            i += 5;
        } else if (b0 == 30) {
            // Real number - skip
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
            op_count += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            if (op_count < 48) {
                operands[op_count] = @as(i32, b0) - 139;
                op_count += 1;
            }
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (op_count < 48 and i + 1 < dict_data.len) {
                operands[op_count] = (@as(i32, b0) - 247) * 256 + dict_data[i + 1] + 108;
                op_count += 1;
            }
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (op_count < 48 and i + 1 < dict_data.len) {
                operands[op_count] = -(@as(i32, b0) - 251) * 256 - dict_data[i + 1] - 108;
                op_count += 1;
            }
            i += 2;
        } else {
            i += 1;
        }
    }

    return sids;
}

/// Build a subset String INDEX containing only the strings referenced by used_sids.
/// Returns the new String INDEX data and a remap from old SID to new SID.
pub fn buildSubsetStringIndex(
    allocator: std.mem.Allocator,
    cff_data: []const u8,
    string_index_start: usize,
    used_sids: []const u16,
) !struct { data: []const u8, remap: std.AutoHashMapUnmanaged(u16, u16) } {
    const orig_index = parseCFFIndex(cff_data, string_index_start) orelse
        return .{ .data = &[_]u8{ 0, 0 }, .remap = .{} };

    // Collect unique custom SIDs (>= 391) and sort them
    var custom_sids = std.ArrayListUnmanaged(u16){};
    defer custom_sids.deinit(allocator);

    for (used_sids) |sid| {
        if (sid >= STANDARD_STRING_COUNT) {
            // Check if already in list
            var found = false;
            for (custom_sids.items) |existing| {
                if (existing == sid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try custom_sids.append(allocator, sid);
            }
        }
    }

    // Sort for consistent ordering
    std.mem.sort(u16, custom_sids.items, {}, std.sort.asc(u16));

    // Build remap: old SID -> new SID
    var remap = std.AutoHashMapUnmanaged(u16, u16){};
    errdefer remap.deinit(allocator);

    for (custom_sids.items, 0..) |old_sid, idx| {
        const new_sid: u16 = STANDARD_STRING_COUNT + @as(u16, @intCast(idx));
        try remap.put(allocator, old_sid, new_sid);
    }

    // Build new String INDEX with only needed strings
    var string_data = std.ArrayListUnmanaged(u8){};
    defer string_data.deinit(allocator);

    for (custom_sids.items) |old_sid| {
        const string_idx = old_sid - STANDARD_STRING_COUNT;
        if (orig_index.getEntry(string_idx)) |str| {
            try string_data.appendSlice(allocator, str);
        }
    }

    // Build INDEX structure
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    const new_count: u16 = @intCast(custom_sids.items.len);
    if (new_count == 0) {
        try output.appendSlice(allocator, &[_]u8{ 0, 0 });
        return .{ .data = try output.toOwnedSlice(allocator), .remap = remap };
    }

    // Determine offset size needed
    var offsets = std.ArrayListUnmanaged(u32){};
    defer offsets.deinit(allocator);

    var current_offset: u32 = 1;
    try offsets.append(allocator, current_offset);

    for (custom_sids.items) |old_sid| {
        const string_idx = old_sid - STANDARD_STRING_COUNT;
        if (orig_index.getEntry(string_idx)) |str| {
            current_offset += @intCast(str.len);
        }
        try offsets.append(allocator, current_offset);
    }

    const off_size: u8 = if (current_offset < 256) 1 else if (current_offset < 65536) 2 else if (current_offset < 16777216) 3 else 4;

    // Write count
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, new_count)));
    // Write offSize
    try output.append(allocator, off_size);
    // Write offsets
    for (offsets.items) |off| {
        switch (off_size) {
            1 => try output.append(allocator, @intCast(off)),
            2 => try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(off)))),
            3 => {
                try output.append(allocator, @intCast((off >> 16) & 0xff));
                try output.append(allocator, @intCast((off >> 8) & 0xff));
                try output.append(allocator, @intCast(off & 0xff));
            },
            4 => try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, off))),
            else => {},
        }
    }
    // Write string data
    try output.appendSlice(allocator, string_data.items);

    return .{ .data = try output.toOwnedSlice(allocator), .remap = remap };
}

/// Remap an SID using the provided mapping. Standard SIDs (< 391) pass through unchanged.
pub fn remapSID(sid: u16, remap: *const std.AutoHashMapUnmanaged(u16, u16)) u16 {
    if (sid < STANDARD_STRING_COUNT) return sid;
    return remap.get(sid) orelse sid;
}

// =============================================================================
// CFF DICT Parsing
// =============================================================================

pub const PrivateInfo = struct { size: usize, offset: usize };

pub const TopDictOffsets = struct {
    charset: u32,
    charstrings: u32,
    private_size: usize,
    private_offset: u32,
};

pub fn parseCFFTopDictForCharStrings(data: []const u8, topdict_index_start: usize) ?usize {
    const index = parseCFFIndex(data, topdict_index_start) orelse return null;
    const dict_data = index.getEntry(0) orelse return null;
    return parseCFFDictForOperator(dict_data, 17); // 17 = CharStrings
}

/// Result of parsing a CFF dict for a specific operator.
const CFFDictParseResult = struct {
    operands: [2]i32 = .{ 0, 0 },
    count: usize = 0,
    found: bool = false,
};

/// Parse a CFF DICT for a target operator, collecting up to max_operands operands.
/// This is the unified parser for CFF dictionary data, handling all operand encodings.
fn parseCFFDictOperator(dict_data: []const u8, target_op: u8, comptime max_operands: usize) CFFDictParseResult {
    var result = CFFDictParseResult{};
    var i: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];
        if (b0 == target_op) {
            result.found = true;
            return result;
        } else if (b0 == 12) {
            // Two-byte operator (escaped)
            i += 2;
            result.count = 0;
        } else if (b0 <= 21) {
            // One-byte operator
            i += 1;
            result.count = 0;
        } else if (b0 == 28) {
            // 2-byte signed integer
            if (result.count < max_operands) {
                result.operands[result.count] = @as(i32, @as(i16, @bitCast(readU16(dict_data, i + 1))));
            }
            result.count += 1;
            i += 3;
        } else if (b0 == 29) {
            // 4-byte signed integer
            if (result.count < max_operands) {
                result.operands[result.count] = @as(i32, @bitCast(readU32(dict_data, i + 1)));
            }
            result.count += 1;
            i += 5;
        } else if (b0 == 30) {
            // Floating point (variable length, skip)
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
            result.count += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            // Small integer: value = b0 - 139
            if (result.count < max_operands) {
                result.operands[result.count] = @as(i32, b0) - 139;
            }
            result.count += 1;
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            // Positive 2-byte integer
            if (result.count < max_operands) {
                result.operands[result.count] = (@as(i32, b0) - 247) * 256 + dict_data[i + 1] + 108;
            }
            result.count += 1;
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            // Negative 2-byte integer
            if (result.count < max_operands) {
                result.operands[result.count] = -(@as(i32, b0) - 251) * 256 - dict_data[i + 1] - 108;
            }
            result.count += 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    return result;
}

pub fn parseCFFTopDictForPrivate(data: []const u8, topdict_index_start: usize) PrivateInfo {
    const index = parseCFFIndex(data, topdict_index_start) orelse return .{ .size = 0, .offset = 0 };
    const dict_data = index.getEntry(0) orelse return .{ .size = 0, .offset = 0 };

    // Parse for operator 18 (Private) which has two operands: size, offset
    const result = parseCFFDictOperator(dict_data, 18, 2);
    if (result.found) {
        return .{ .size = @intCast(result.operands[0]), .offset = @intCast(result.operands[1]) };
    }
    return .{ .size = 0, .offset = 0 };
}

pub fn parseCFFDictForOperator(dict_data: []const u8, target_op: u8) ?usize {
    const result = parseCFFDictOperator(dict_data, target_op, 1);
    if (result.found) {
        return @intCast(result.operands[0]);
    }
    return null;
}

// =============================================================================
// CFF Charset Handling
// =============================================================================

/// Search charset range format for a glyph's SID.
/// nleft_size is 1 for format 1, 2 for format 2.
fn searchCharsetRange(cff_data: []const u8, charset_offset: usize, glyph_idx: u16, nleft_size: u8) ?u16 {
    const entry_size: usize = 2 + nleft_size;
    var pos = charset_offset + 1;
    var current_gid: u16 = 1;
    while (pos + entry_size - 1 < cff_data.len) {
        const first_sid = readU16(cff_data, pos);
        const nleft: u16 = if (nleft_size == 1) cff_data[pos + 2] else readU16(cff_data, pos + 2);
        const range_end = current_gid + nleft;
        if (glyph_idx <= range_end) {
            return first_sid + (glyph_idx - current_gid);
        }
        current_gid = range_end + 1;
        pos += entry_size;
    }
    return null;
}

/// Get the SID (String ID) for a glyph index from a CFF charset
pub fn getCharsetSID(cff_data: []const u8, charset_offset: usize, glyph_idx: u16) ?u16 {
    if (glyph_idx == 0) return 0; // .notdef always has SID 0

    const format = cff_data[charset_offset];

    if (format == 0) {
        // Format 0: array of 2-byte SIDs
        const sid_offset = charset_offset + 1 + (@as(usize, glyph_idx) - 1) * 2;
        if (sid_offset + 1 >= cff_data.len) return null;
        return readU16(cff_data, sid_offset);
    } else if (format == 1) {
        return searchCharsetRange(cff_data, charset_offset, glyph_idx, 1);
    } else if (format == 2) {
        return searchCharsetRange(cff_data, charset_offset, glyph_idx, 2);
    }
    return null;
}

// =============================================================================
// CFF DICT Building
// =============================================================================

pub fn buildUpdatedTopDict(
    allocator: std.mem.Allocator,
    cff_data: []const u8,
    topdict_index_start: usize,
    output: *std.ArrayListUnmanaged(u8),
    offsets: TopDictOffsets,
) !void {
    const index = parseCFFIndex(cff_data, topdict_index_start) orelse return;
    const dict_data = index.getEntry(0) orelse return;

    // Parse and rebuild, replacing operators 15, 17, 18 and removing 16
    var i: usize = 0;
    var operand_start: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];

        if (b0 == 15) {
            // charset - replace with new offset
            try encodeCFFInt(allocator, output, @intCast(offsets.charset));
            try output.append(allocator, 15);
            i += 1;
            operand_start = i;
        } else if (b0 == 16) {
            // Encoding - skip/remove
            i += 1;
            operand_start = i;
        } else if (b0 == 17) {
            // CharStrings - replace with new offset
            try encodeCFFInt(allocator, output, @intCast(offsets.charstrings));
            try output.append(allocator, 17);
            i += 1;
            operand_start = i;
        } else if (b0 == 18) {
            // Private - replace with new size and offset
            try encodeCFFInt(allocator, output, @intCast(offsets.private_size));
            try encodeCFFInt(allocator, output, @intCast(offsets.private_offset));
            try output.append(allocator, 18);
            i += 1;
            operand_start = i;
        } else if (b0 == 12) {
            try output.appendSlice(allocator, dict_data[operand_start .. i + 2]);
            i += 2;
            operand_start = i;
        } else if (b0 <= 21) {
            try output.appendSlice(allocator, dict_data[operand_start .. i + 1]);
            i += 1;
            operand_start = i;
        } else {
            // Operand - skip using helper
            i += cffOperandSize(dict_data, i);
        }
    }
}

/// Build updated Top DICT with SID remapping for String INDEX subsetting.
/// This version remaps SIDs in operators 0-4 and 12 0/21/22/30.
/// It preserves real numbers and other operands verbatim.
pub fn buildUpdatedTopDictWithSIDRemap(
    allocator: std.mem.Allocator,
    cff_data: []const u8,
    topdict_index_start: usize,
    output: *std.ArrayListUnmanaged(u8),
    offsets: TopDictOffsets,
    sid_remap: *const std.AutoHashMapUnmanaged(u16, u16),
) !void {
    const index = parseCFFIndex(cff_data, topdict_index_start) orelse return;
    const dict_data = index.getEntry(0) orelse return;

    // Track operand values (for SID remapping) and byte ranges (for verbatim copy)
    var operand_values: [48]i32 = undefined;
    var operand_starts: [48]usize = undefined;
    var operand_ends: [48]usize = undefined;
    var operand_is_int: [48]bool = undefined;
    var op_count: usize = 0;
    var i: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];

        if (b0 == 15) {
            // charset - replace with new offset
            try encodeCFFInt(allocator, output, @intCast(offsets.charset));
            try output.append(allocator, 15);
            i += 1;
            op_count = 0;
        } else if (b0 == 16) {
            // Encoding - skip/remove
            i += 1;
            op_count = 0;
        } else if (b0 == 17) {
            // CharStrings - replace with new offset
            try encodeCFFInt(allocator, output, @intCast(offsets.charstrings));
            try output.append(allocator, 17);
            i += 1;
            op_count = 0;
        } else if (b0 == 18) {
            // Private - replace with new size and offset
            try encodeCFFInt(allocator, output, @intCast(offsets.private_size));
            try encodeCFFInt(allocator, output, @intCast(offsets.private_offset));
            try output.append(allocator, 18);
            i += 1;
            op_count = 0;
        } else if (b0 <= 4) {
            // version, Notice, FullName, FamilyName, Weight - remap SID
            if (op_count >= 1 and operand_is_int[op_count - 1] and operand_values[op_count - 1] >= 0) {
                const old_sid: u16 = @intCast(operand_values[op_count - 1]);
                const new_sid = remapSID(old_sid, sid_remap);
                try encodeCFFInt(allocator, output, @intCast(new_sid));
            }
            try output.append(allocator, b0);
            i += 1;
            op_count = 0;
        } else if (b0 == 12) {
            if (i + 1 < dict_data.len) {
                const b1 = dict_data[i + 1];
                if (b1 == 0 or b1 == 21 or b1 == 22) {
                    // Copyright, PostScript, BaseFontName - remap SID
                    if (op_count >= 1 and operand_is_int[op_count - 1] and operand_values[op_count - 1] >= 0) {
                        const old_sid: u16 = @intCast(operand_values[op_count - 1]);
                        const new_sid = remapSID(old_sid, sid_remap);
                        try encodeCFFInt(allocator, output, @intCast(new_sid));
                    }
                    try output.appendSlice(allocator, &[_]u8{ 12, b1 });
                } else if (b1 == 30) {
                    // ROS - remap first two SIDs (Registry, Ordering), keep Supplement
                    if (op_count >= 3 and operand_is_int[op_count - 3] and operand_is_int[op_count - 2]) {
                        const reg_sid: u16 = if (operand_values[op_count - 3] >= 0) @intCast(operand_values[op_count - 3]) else 0;
                        const ord_sid: u16 = if (operand_values[op_count - 2] >= 0) @intCast(operand_values[op_count - 2]) else 0;
                        try encodeCFFInt(allocator, output, @intCast(remapSID(reg_sid, sid_remap)));
                        try encodeCFFInt(allocator, output, @intCast(remapSID(ord_sid, sid_remap)));
                        // Copy supplement verbatim
                        try output.appendSlice(allocator, dict_data[operand_starts[op_count - 1]..operand_ends[op_count - 1]]);
                    }
                    try output.appendSlice(allocator, &[_]u8{ 12, 30 });
                } else {
                    // Other two-byte operators - copy operands verbatim to preserve reals
                    if (op_count > 0) {
                        try output.appendSlice(allocator, dict_data[operand_starts[0]..operand_ends[op_count - 1]]);
                    }
                    try output.appendSlice(allocator, &[_]u8{ 12, b1 });
                }
            }
            i += 2;
            op_count = 0;
        } else if (b0 <= 21) {
            // Other single-byte operators - copy operands verbatim to preserve reals
            if (op_count > 0) {
                try output.appendSlice(allocator, dict_data[operand_starts[0]..operand_ends[op_count - 1]]);
            }
            try output.append(allocator, b0);
            i += 1;
            op_count = 0;
        } else if (b0 == 28) {
            if (op_count < 48) {
                operand_starts[op_count] = i;
                operand_values[op_count] = @as(i32, @as(i16, @bitCast(readU16(dict_data, i + 1))));
                operand_is_int[op_count] = true;
                operand_ends[op_count] = i + 3;
                op_count += 1;
            }
            i += 3;
        } else if (b0 == 29) {
            if (op_count < 48) {
                operand_starts[op_count] = i;
                operand_values[op_count] = @as(i32, @bitCast(readU32(dict_data, i + 1)));
                operand_is_int[op_count] = true;
                operand_ends[op_count] = i + 5;
                op_count += 1;
            }
            i += 5;
        } else if (b0 == 30) {
            // Real number - track byte range for verbatim copy
            const start = i;
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
            if (op_count < 48) {
                operand_starts[op_count] = start;
                operand_values[op_count] = 0; // Not used for reals
                operand_is_int[op_count] = false;
                operand_ends[op_count] = i;
                op_count += 1;
            }
        } else if (b0 >= 32 and b0 <= 246) {
            if (op_count < 48) {
                operand_starts[op_count] = i;
                operand_values[op_count] = @as(i32, b0) - 139;
                operand_is_int[op_count] = true;
                operand_ends[op_count] = i + 1;
                op_count += 1;
            }
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (op_count < 48 and i + 1 < dict_data.len) {
                operand_starts[op_count] = i;
                operand_values[op_count] = (@as(i32, b0) - 247) * 256 + dict_data[i + 1] + 108;
                operand_is_int[op_count] = true;
                operand_ends[op_count] = i + 2;
                op_count += 1;
            }
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (op_count < 48 and i + 1 < dict_data.len) {
                operand_starts[op_count] = i;
                operand_values[op_count] = -(@as(i32, b0) - 251) * 256 - dict_data[i + 1] - 108;
                operand_is_int[op_count] = true;
                operand_ends[op_count] = i + 2;
                op_count += 1;
            }
            i += 2;
        } else {
            i += 1;
        }
    }
}

/// Build Private DICT without the Subrs operator (19)
pub fn buildPrivateDictWithoutSubrs(
    allocator: std.mem.Allocator,
    private_dict_data: []const u8,
    output: *std.ArrayListUnmanaged(u8),
) !void {
    var i: usize = 0;
    var operand_start: usize = 0;

    while (i < private_dict_data.len) {
        const b0 = private_dict_data[i];

        if (b0 == 19) {
            // Subrs - skip this operator and its operand
            i += 1;
            operand_start = i;
        } else if (b0 == 12) {
            try output.appendSlice(allocator, private_dict_data[operand_start .. i + 2]);
            i += 2;
            operand_start = i;
        } else if (b0 <= 21) {
            try output.appendSlice(allocator, private_dict_data[operand_start .. i + 1]);
            i += 1;
            operand_start = i;
        } else {
            // Operand - skip using helper
            i += cffOperandSize(private_dict_data, i);
        }
    }
}

pub fn encodeCFFInt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: i32) !void {
    if (value >= -107 and value <= 107) {
        try output.append(allocator, @intCast(value + 139));
    } else if (value >= 108 and value <= 1131) {
        const v: u32 = @intCast(value - 108);
        try output.append(allocator, @intCast(247 + (v >> 8)));
        try output.append(allocator, @intCast(v & 0xff));
    } else if (value >= -1131 and value <= -108) {
        const v: u32 = @intCast(-value - 108);
        try output.append(allocator, @intCast(251 + (v >> 8)));
        try output.append(allocator, @intCast(v & 0xff));
    } else if (value >= -32768 and value <= 32767) {
        try output.append(allocator, 28);
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(value))));
    } else {
        try output.append(allocator, 29);
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, value)));
    }
}

// =============================================================================
// Desubroutinization
// =============================================================================

/// Get subroutine bias based on count (CFF spec)
pub fn getSubrBias(count: u16) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Desubroutinize a single CharString, inlining all subr calls
pub fn desubroutinizeCharString(
    allocator: std.mem.Allocator,
    charstring: []const u8,
    global_subrs: ?CFFIndex,
    local_subrs: ?CFFIndex,
    depth: u8,
) ![]const u8 {
    // Prevent infinite recursion
    if (depth > 10) return allocator.dupe(u8, charstring);

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const gsubr_bias: i32 = if (global_subrs) |gs| getSubrBias(gs.count) else 0;
    const lsubr_bias: i32 = if (local_subrs) |ls| getSubrBias(ls.count) else 0;

    // Track operand stack for subr index calculation
    var stack: [48]i32 = undefined;
    var stack_top: usize = 0;

    // Track operand byte positions in result (for removing callsubr operand)
    var operand_positions: [48]usize = undefined;

    // Track hint count for hintmask/cntrmask
    var stem_count: usize = 0;
    var seen_endchar = false;

    var i: usize = 0;
    while (i < charstring.len) {
        const b0 = charstring[i];

        if (b0 == 1 or b0 == 3 or b0 == 18 or b0 == 23) {
            // hstem, vstem, hstemhm, vstemhm
            stem_count += stack_top / 2;
            stack_top = 0;
            try result.append(allocator, b0);
            i += 1;
        } else if (b0 == 19 or b0 == 20) {
            // hintmask/cntrmask
            stem_count += stack_top / 2;
            stack_top = 0;
            try result.append(allocator, b0);
            i += 1;
            const mask_bytes = (stem_count + 7) / 8;
            if (i + mask_bytes <= charstring.len) {
                try result.appendSlice(allocator, charstring[i..][0..mask_bytes]);
                i += mask_bytes;
            }
        } else if (b0 == 10) {
            // callsubr - inline local subroutine
            if (stack_top > 0 and local_subrs != null) {
                const operand_start = operand_positions[stack_top - 1];
                result.shrinkRetainingCapacity(operand_start);

                stack_top -= 1;
                const subr_idx = stack[stack_top] + lsubr_bias;
                if (subr_idx >= 0) {
                    if (local_subrs.?.getEntry(@intCast(subr_idx))) |subr_data| {
                        const expanded = try desubroutinizeCharString(allocator, subr_data, global_subrs, local_subrs, depth + 1);
                        defer allocator.free(expanded);
                        const inline_len = if (expanded.len > 0 and expanded[expanded.len - 1] == 11)
                            expanded.len - 1
                        else
                            expanded.len;
                        try result.appendSlice(allocator, expanded[0..inline_len]);
                    }
                }
            }
            i += 1;
        } else if (b0 == 29) {
            // callgsubr - inline global subroutine
            if (stack_top > 0 and global_subrs != null) {
                const operand_start = operand_positions[stack_top - 1];
                result.shrinkRetainingCapacity(operand_start);

                stack_top -= 1;
                const subr_idx = stack[stack_top] + gsubr_bias;
                if (subr_idx >= 0) {
                    if (global_subrs.?.getEntry(@intCast(subr_idx))) |subr_data| {
                        const expanded = try desubroutinizeCharString(allocator, subr_data, global_subrs, local_subrs, depth + 1);
                        defer allocator.free(expanded);
                        const inline_len = if (expanded.len > 0 and expanded[expanded.len - 1] == 11)
                            expanded.len - 1
                        else
                            expanded.len;
                        try result.appendSlice(allocator, expanded[0..inline_len]);
                    }
                }
            }
            i += 1;
        } else if (b0 == 11) {
            // return - skip
            i += 1;
        } else if (b0 == 14) {
            // endchar
            try result.append(allocator, b0);
            seen_endchar = true;
            i += 1;
        } else if (b0 == 12) {
            // Two-byte operator
            if (i + 1 < charstring.len) {
                try result.appendSlice(allocator, charstring[i..][0..2]);
                stack_top = 0;
            }
            i += 2;
        } else if (b0 == 28) {
            // shortint
            if (i + 2 < charstring.len and stack_top < 48) {
                operand_positions[stack_top] = result.items.len;
                const val = @as(i32, @as(i16, @bitCast(readU16(charstring, i + 1))));
                stack[stack_top] = val;
                stack_top += 1;
                try result.appendSlice(allocator, charstring[i..][0..3]);
            }
            i += 3;
        } else if (b0 >= 32 and b0 <= 246) {
            // Single-byte integer
            if (stack_top < 48) {
                operand_positions[stack_top] = result.items.len;
                stack[stack_top] = @as(i32, b0) - 139;
                stack_top += 1;
            }
            try result.append(allocator, b0);
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            // Two-byte positive integer
            if (i + 1 < charstring.len and stack_top < 48) {
                operand_positions[stack_top] = result.items.len;
                const val = (@as(i32, b0) - 247) * 256 + charstring[i + 1] + 108;
                stack[stack_top] = val;
                stack_top += 1;
                try result.appendSlice(allocator, charstring[i..][0..2]);
            }
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            // Two-byte negative integer
            if (i + 1 < charstring.len and stack_top < 48) {
                operand_positions[stack_top] = result.items.len;
                const val = -(@as(i32, b0) - 251) * 256 - charstring[i + 1] - 108;
                stack[stack_top] = val;
                stack_top += 1;
                try result.appendSlice(allocator, charstring[i..][0..2]);
            }
            i += 2;
        } else if (b0 == 255) {
            // 4-byte fixed point
            if (i + 4 < charstring.len) {
                try result.appendSlice(allocator, charstring[i..][0..5]);
            }
            i += 5;
        } else if (b0 <= 27) {
            // Other single-byte operators
            try result.append(allocator, b0);
            stack_top = 0;
            i += 1;
        } else {
            // Unknown/reserved
            try result.append(allocator, b0);
            i += 1;
        }
    }

    // Ensure we end with endchar (only for main charstring, not subroutines)
    if (!seen_endchar and result.items.len > 0 and depth == 0) {
        try result.append(allocator, 14);
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "getSubrBias" {
    try std.testing.expectEqual(@as(i32, 107), getSubrBias(0));
    try std.testing.expectEqual(@as(i32, 107), getSubrBias(1239));
    try std.testing.expectEqual(@as(i32, 1131), getSubrBias(1240));
    try std.testing.expectEqual(@as(i32, 1131), getSubrBias(33899));
    try std.testing.expectEqual(@as(i32, 32768), getSubrBias(33900));
}

test "parseCFFIndex empty" {
    const data = [_]u8{ 0, 0 }; // count = 0
    const idx = parseCFFIndex(&data, 0);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 0), idx.?.count);
}

test "parseCFFIndex single entry" {
    const data = [_]u8{
        0, 1, // count = 1
        1, // offSize = 1
        1, 5, // offsets: 1, 5 (so entry 0 is 4 bytes)
        'T', 'E', 'S', 'T', // data
    };
    const idx = parseCFFIndex(&data, 0);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 1), idx.?.count);
    const entry = idx.?.getEntry(0);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualSlices(u8, "TEST", entry.?);
}

test "buildPrivateDictWithoutSubrs" {
    const allocator = std.testing.allocator;

    // Private DICT with: defaultWidthX (20) = 500, Subrs (19) = 100
    const private_dict = [_]u8{
        0xF8, 0x6C, // 500 encoded (247 + 1, 500-108=392 -> 247 + (392>>8)=1, 392&0xff=136)
        20, // defaultWidthX operator
        0x8B + 100, // 100 encoded as single byte (139+100=239)
        19, // Subrs operator (should be removed)
    };

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    try buildPrivateDictWithoutSubrs(allocator, &private_dict, &output);

    // Should have defaultWidthX but not Subrs
    try std.testing.expect(output.items.len > 0);
    // Check that operator 19 is not in output
    for (output.items) |b| {
        try std.testing.expect(b != 19);
    }
}

test "remapSID standard SIDs unchanged" {
    // Standard SIDs (< 391) should pass through unchanged
    var remap = std.AutoHashMapUnmanaged(u16, u16){};
    defer remap.deinit(std.testing.allocator);

    try remap.put(std.testing.allocator, 500, 391); // Custom SID mapping

    // Standard SIDs unchanged
    try std.testing.expectEqual(@as(u16, 0), remapSID(0, &remap));
    try std.testing.expectEqual(@as(u16, 34), remapSID(34, &remap)); // 'space'
    try std.testing.expectEqual(@as(u16, 390), remapSID(390, &remap));

    // Custom SID gets remapped
    try std.testing.expectEqual(@as(u16, 391), remapSID(500, &remap));

    // Unknown custom SID returns unchanged
    try std.testing.expectEqual(@as(u16, 999), remapSID(999, &remap));
}

test "buildSubsetStringIndex basic" {
    const allocator = std.testing.allocator;

    // Build a String INDEX with 3 strings
    const string_index = [_]u8{
        0, 3, // count = 3
        1, // offSize = 1
        1, 4, 8, 14, // offsets: entry 0 at 1-3, entry 1 at 4-7, entry 2 at 8-13
        'F', 'o', 'o', // entry 0: "Foo" (SID 391)
        'B', 'a', 'r', '!', // entry 1: "Bar!" (SID 392)
        'H', 'e', 'l', 'l', 'o', '!', // entry 2: "Hello!" (SID 393)
    };

    // Request only SIDs 391 and 393 (skip 392)
    const used_sids = [_]u16{ 0, 34, 391, 393 }; // Include standard SIDs too

    const result = try buildSubsetStringIndex(allocator, &string_index, 0, &used_sids);
    defer allocator.free(result.data);
    defer {
        var remap = result.remap;
        remap.deinit(allocator);
    }

    // Should have remapped custom SIDs
    try std.testing.expectEqual(@as(u16, 391), result.remap.get(391).?);
    try std.testing.expectEqual(@as(u16, 392), result.remap.get(393).?);

    // Parse the result String INDEX
    const new_idx = parseCFFIndex(result.data, 0);
    try std.testing.expect(new_idx != null);
    try std.testing.expectEqual(@as(u16, 2), new_idx.?.count); // Only 2 custom strings

    // Verify content
    const entry0 = new_idx.?.getEntry(0);
    try std.testing.expect(entry0 != null);
    try std.testing.expectEqualSlices(u8, "Foo", entry0.?);

    const entry1 = new_idx.?.getEntry(1);
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqualSlices(u8, "Hello!", entry1.?);
}

test "buildSubsetStringIndex empty when only standard SIDs" {
    const allocator = std.testing.allocator;

    // String INDEX with 2 strings
    const string_index = [_]u8{
        0, 2, // count = 2
        1, // offSize = 1
        1, 4, 8, // offsets
        'F', 'o', 'o', // entry 0
        'B', 'a', 'r', '!', // entry 1
    };

    // Request only standard SIDs
    const used_sids = [_]u16{ 0, 34, 35, 36 };

    const result = try buildSubsetStringIndex(allocator, &string_index, 0, &used_sids);
    defer allocator.free(result.data);
    defer {
        var remap = result.remap;
        remap.deinit(allocator);
    }

    // Should have empty String INDEX (count = 0)
    try std.testing.expectEqual(@as(u16, 0), readU16(result.data, 0));
    try std.testing.expectEqual(@as(usize, 0), result.remap.count());
}

test "collectTopDictSIDs basic" {
    const allocator = std.testing.allocator;

    // Build a minimal Top DICT INDEX with version SID and FamilyName SID
    // version (op 0) = SID 500, FamilyName (op 3) = SID 501
    // CFF integer encoding for 500: 500-108=392, 392/256=1 r136, so (248, 136) = (0xF8, 0x88)
    // CFF integer encoding for 501: 501-108=393, 393/256=1 r137, so (248, 137) = (0xF8, 0x89)
    const topdict_index = [_]u8{
        0, 1, // count = 1
        1, // offSize = 1
        1, 7, // offsets: 1 to 7 (6 bytes of dict data)
        // Dict data (6 bytes total):
        0xF8, 0x88, // SID 500 encoded
        0, // version operator
        0xF8, 0x89, // SID 501 encoded
        3, // FamilyName operator
    };

    var sids = try collectTopDictSIDs(allocator, &topdict_index, 0);
    defer sids.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), sids.items.len);
    try std.testing.expectEqual(@as(u16, 500), sids.items[0]);
    try std.testing.expectEqual(@as(u16, 501), sids.items[1]);
}
