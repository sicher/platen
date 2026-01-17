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
    const count = readU16(data, topdict_index_start);
    if (count == 0) return null;

    const off_size = data[topdict_index_start + 2];
    const offsets_start = topdict_index_start + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;

    const first_off = readCFFOffset(data, offsets_start, 0, off_size);
    const second_off = readCFFOffset(data, offsets_start, 1, off_size);
    const dict_data = data[data_start + first_off - 1 .. data_start + second_off - 1];

    return parseCFFDictForOperator(dict_data, 17); // 17 = CharStrings
}

pub fn parseCFFTopDictForPrivate(data: []const u8, topdict_index_start: usize) PrivateInfo {
    const count = readU16(data, topdict_index_start);
    if (count == 0) return .{ .size = 0, .offset = 0 };

    const off_size = data[topdict_index_start + 2];
    const offsets_start = topdict_index_start + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;

    const first_off = readCFFOffset(data, offsets_start, 0, off_size);
    const second_off = readCFFOffset(data, offsets_start, 1, off_size);
    const dict_data = data[data_start + first_off - 1 .. data_start + second_off - 1];

    // Parse for operator 18 (Private) which has two operands: size, offset
    var operands: [2]i32 = .{ 0, 0 };
    var op_count: usize = 0;
    var i: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];
        if (b0 == 18) {
            return .{ .size = @intCast(operands[0]), .offset = @intCast(operands[1]) };
        } else if (b0 == 12) {
            i += 2;
            op_count = 0;
        } else if (b0 <= 21) {
            i += 1;
            op_count = 0;
        } else if (b0 == 28) {
            if (op_count < 2) operands[op_count] = @as(i32, @as(i16, @bitCast(readU16(dict_data, i + 1))));
            op_count += 1;
            i += 3;
        } else if (b0 == 29) {
            if (op_count < 2) operands[op_count] = @as(i32, @bitCast(readU32(dict_data, i + 1)));
            op_count += 1;
            i += 5;
        } else if (b0 == 30) {
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
            op_count += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            if (op_count < 2) operands[op_count] = @as(i32, b0) - 139;
            op_count += 1;
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (op_count < 2) operands[op_count] = (@as(i32, b0) - 247) * 256 + dict_data[i + 1] + 108;
            op_count += 1;
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (op_count < 2) operands[op_count] = -(@as(i32, b0) - 251) * 256 - dict_data[i + 1] - 108;
            op_count += 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    return .{ .size = 0, .offset = 0 };
}

pub fn parseCFFDictForOperator(dict_data: []const u8, target_op: u8) ?usize {
    var operand: i32 = 0;
    var i: usize = 0;

    while (i < dict_data.len) {
        const b0 = dict_data[i];
        if (b0 == target_op) {
            return @intCast(operand);
        } else if (b0 == 12) {
            i += 2;
        } else if (b0 <= 21) {
            i += 1;
        } else if (b0 == 28) {
            operand = @as(i32, @as(i16, @bitCast(readU16(dict_data, i + 1))));
            i += 3;
        } else if (b0 == 29) {
            operand = @as(i32, @bitCast(readU32(dict_data, i + 1)));
            i += 5;
        } else if (b0 == 30) {
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            operand = @as(i32, b0) - 139;
            i += 1;
        } else if (b0 >= 247 and b0 <= 250) {
            operand = (@as(i32, b0) - 247) * 256 + dict_data[i + 1] + 108;
            i += 2;
        } else if (b0 >= 251 and b0 <= 254) {
            operand = -(@as(i32, b0) - 251) * 256 - dict_data[i + 1] - 108;
            i += 2;
        } else {
            i += 1;
        }
    }
    return null;
}

// =============================================================================
// CFF Charset Handling
// =============================================================================

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
        // Format 1: ranges with 1-byte nLeft
        var pos = charset_offset + 1;
        var current_gid: u16 = 1;
        while (pos + 2 < cff_data.len) {
            const first_sid = readU16(cff_data, pos);
            const nleft = cff_data[pos + 2];
            const range_end = current_gid + nleft;
            if (glyph_idx <= range_end) {
                return first_sid + (glyph_idx - current_gid);
            }
            current_gid = range_end + 1;
            pos += 3;
        }
        return null;
    } else if (format == 2) {
        // Format 2: ranges with 2-byte nLeft
        var pos = charset_offset + 1;
        var current_gid: u16 = 1;
        while (pos + 3 < cff_data.len) {
            const first_sid = readU16(cff_data, pos);
            const nleft = readU16(cff_data, pos + 2);
            const range_end = current_gid + nleft;
            if (glyph_idx <= range_end) {
                return first_sid + (glyph_idx - current_gid);
            }
            current_gid = range_end + 1;
            pos += 4;
        }
        return null;
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
    const count = readU16(cff_data, topdict_index_start);
    if (count == 0) return;

    const off_size = cff_data[topdict_index_start + 2];
    const offsets_start = topdict_index_start + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;

    const first_off = readCFFOffset(cff_data, offsets_start, 0, off_size);
    const second_off = readCFFOffset(cff_data, offsets_start, 1, off_size);
    const dict_data = cff_data[data_start + first_off - 1 .. data_start + second_off - 1];

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
        } else if (b0 == 28) {
            i += 3;
        } else if (b0 == 29) {
            i += 5;
        } else if (b0 == 30) {
            i += 1;
            while (i < dict_data.len and (dict_data[i] & 0xf) != 0xf and (dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            i += 1;
        } else if (b0 >= 247 and b0 <= 254) {
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
        } else if (b0 == 28) {
            i += 3;
        } else if (b0 == 29) {
            i += 5;
        } else if (b0 == 30) {
            i += 1;
            while (i < private_dict_data.len and (private_dict_data[i] & 0xf) != 0xf and (private_dict_data[i] >> 4) != 0xf) : (i += 1) {}
            i += 1;
        } else if (b0 >= 32 and b0 <= 246) {
            i += 1;
        } else if (b0 >= 247 and b0 <= 254) {
            i += 2;
        } else {
            i += 1;
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
