//! Subsetting a CID-keyed CFF (Top DICT with ROS: CJK fonts such as Apple
//! SD Gothic Neo). Unlike a name-keyed CFF, its charset maps glyphs to CIDs,
//! and each glyph's Private DICT and local subroutines come from a Font DICT
//! that FDSelect picks out of FDArray.
//!
//! The subset numbers its glyphs 0..n-1 (the codes the PDF content uses
//! with Identity-H) and makes the charset the identity, so CID n is glyph
//! n. FDSelect is rebuilt over the new glyphs, every Font DICT keeps its own
//! Private DICT, and each glyph is desubroutinized with its own Font DICT's
//! local subroutines.
//!
//! Layout: header, Name INDEX, Top DICT INDEX, String INDEX, an empty
//! Global Subr INDEX, charset, FDSelect, CharStrings INDEX, FDArray INDEX,
//! Private DICTs. Offsets in the Font DICTs are 5-byte integers so their
//! sizes don't depend on the values.

const std = @import("std");
const cff = @import("cff_subset.zig");
const binary = @import("binary.zig");

const Allocator = std.mem.Allocator;
const CFFIndex = cff.CFFIndex;

/// One DICT entry: its operator (two-byte ones as 0x0C00 | second byte)
/// and its integer operands (reals read as 0).
const Entry = struct {
    op: u16,
    operands: [48]i32 = undefined,
    count: usize = 0,
    /// Byte range of the operands and the whole entry
    operand_start: usize,
    end: usize,
};

/// The entry starting at `pos.*`; advances `pos`. Null at the end or on a
/// malformed DICT.
fn nextEntry(dict: []const u8, pos: *usize) ?Entry {
    var e: Entry = .{ .op = 0, .operand_start = pos.*, .end = 0 };
    var i = pos.*;
    while (i < dict.len) {
        const b0 = dict[i];
        switch (b0) {
            0...11, 13...21 => {
                e.op = b0;
                e.end = i + 1;
                pos.* = e.end;
                return e;
            },
            12 => {
                if (i + 1 >= dict.len) return null;
                e.op = 0x0C00 | @as(u16, dict[i + 1]);
                e.end = i + 2;
                pos.* = e.end;
                return e;
            },
            28 => {
                if (i + 3 > dict.len) return null;
                push(&e, @as(i16, @bitCast(cff.readU16(dict, i + 1))));
                i += 3;
            },
            29 => {
                if (i + 5 > dict.len) return null;
                push(&e, @bitCast(cff.readU32(dict, i + 1)));
                i += 5;
            },
            30 => {
                // Real: nibbles until one is 0xF
                i += 1;
                while (i < dict.len and (dict[i] & 0xF) != 0xF and (dict[i] >> 4) != 0xF) i += 1;
                i += 1;
                push(&e, 0);
            },
            32...246 => {
                push(&e, @as(i32, b0) - 139);
                i += 1;
            },
            247...250 => {
                if (i + 2 > dict.len) return null;
                push(&e, (@as(i32, b0) - 247) * 256 + dict[i + 1] + 108);
                i += 2;
            },
            251...254 => {
                if (i + 2 > dict.len) return null;
                push(&e, -(@as(i32, b0) - 251) * 256 - @as(i32, dict[i + 1]) - 108);
                i += 2;
            },
            else => return null, // reserved
        }
    }
    return null;
}

fn push(e: *Entry, v: i32) void {
    if (e.count < e.operands.len) e.operands[e.count] = v;
    e.count += 1;
}

fn findEntry(dict: []const u8, op: u16) ?Entry {
    var pos: usize = 0;
    while (nextEntry(dict, &pos)) |e| {
        if (e.op == op) return e;
    }
    return null;
}

const op_ros: u16 = 0x0C1E;
const op_fd_array: u16 = 0x0C24;
const op_fd_select: u16 = 0x0C25;
const op_font_name: u16 = 0x0C26;

/// Is this Top DICT a CID-keyed font's (it has ROS)?
pub fn isCidKeyed(top_dict: []const u8) bool {
    return findEntry(top_dict, op_ros) != null;
}

/// Append `v` as a 5-byte DICT integer (fixed size).
fn appendInt5(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, v: i32) !void {
    try out.append(allocator, 29);
    try binary.appendBE32(out, allocator, @bitCast(v));
}

fn appendOp(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, op: u16) !void {
    if (op >= 0x0C00) {
        try out.appendSlice(allocator, &.{ 12, @truncate(op) });
    } else try out.append(allocator, @intCast(op));
}

/// The Font DICT index FDSelect gives glyph `gid` (formats 0 and 3; 0 if
/// broken).
fn fdOf(data: []const u8, fd_select: usize, gid: u16, num_glyphs: u16) u8 {
    if (fd_select >= data.len) return 0;
    switch (data[fd_select]) {
        0 => {
            const at = fd_select + 1 + gid;
            return if (gid < num_glyphs and at < data.len) data[at] else 0;
        },
        3 => {
            const n = cff.readU16(data, fd_select + 1);
            var r: usize = 0;
            while (r < n) : (r += 1) {
                const rec = fd_select + 3 + r * 3;
                if (rec + 5 > data.len) return 0;
                const first = cff.readU16(data, rec);
                const next = cff.readU16(data, rec + 3);
                if (gid >= first and gid < next) return data[rec + 2];
            }
            return 0;
        },
        else => return 0,
    }
}

/// A CFF INDEX of `items`.
fn appendIndex(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, items: []const []const u8) !void {
    try binary.appendBE16(out, allocator, @intCast(items.len));
    if (items.len == 0) return;
    var total: usize = 0;
    for (items) |it| total += it.len;
    const off_size: u8 = if (total + 1 <= 0xFF) 1 else if (total + 1 <= 0xFFFF) 2 else if (total + 1 <= 0xFF_FFFF) 3 else 4;
    try out.append(allocator, off_size);
    var off: u32 = 1;
    for (0..items.len + 1) |k| {
        switch (off_size) {
            1 => try out.append(allocator, @intCast(off)),
            2 => try binary.appendBE16(out, allocator, @intCast(off)),
            3 => {
                const b = std.mem.toBytes(std.mem.nativeToBig(u32, off));
                try out.appendSlice(allocator, b[1..4]);
            },
            else => try binary.appendBE32(out, allocator, off),
        }
        if (k < items.len) off += @intCast(items[k].len);
    }
    for (items) |it| try out.appendSlice(allocator, it);
}

fn indexBytes(data: []const u8, start: usize) []const u8 {
    const end = cff.skipCFFIndex(data, start);
    return data[@min(start, data.len)..@min(end, data.len)];
}

const FontDict = struct {
    dict: []const u8,
    private: []const u8 = &.{},
    local_subrs: ?CFFIndex = null,
};

/// The subset of CID-keyed `data` (a CFF table) holding `glyphs` (original
/// glyph IDs; the subset's glyph n is glyphs[n], glyphs[0] = .notdef).
pub fn subset(allocator: Allocator, data: []const u8, glyphs: []const u16) ![]u8 {
    if (data.len < 4) return error.InvalidCFF;
    const hdr_size: usize = data[2];
    const name_end = cff.skipCFFIndex(data, hdr_size);
    const top_index = cff.parseCFFIndex(data, name_end) orelse return error.InvalidCFF;
    const top = top_index.getEntry(0) orelse return error.InvalidCFF;
    const string_start = cff.skipCFFIndex(data, name_end);
    const gsubr_start = cff.skipCFFIndex(data, string_start);
    const global_subrs = cff.parseCFFIndex(data, gsubr_start);

    const cs_entry = findEntry(top, 17) orelse return error.InvalidCFF;
    if (cs_entry.count < 1 or cs_entry.operands[0] < 0) return error.InvalidCFF;
    const charstrings = cff.parseCFFIndex(data, @intCast(cs_entry.operands[0])) orelse return error.InvalidCFF;
    const fd_array_entry = findEntry(top, op_fd_array) orelse return error.InvalidCFF;
    const fd_select_entry = findEntry(top, op_fd_select) orelse return error.InvalidCFF;
    if (fd_array_entry.count < 1 or fd_array_entry.operands[0] < 0) return error.InvalidCFF;
    if (fd_select_entry.count < 1 or fd_select_entry.operands[0] < 0) return error.InvalidCFF;
    const fd_index = cff.parseCFFIndex(data, @intCast(fd_array_entry.operands[0])) orelse return error.InvalidCFF;
    const fd_select: usize = @intCast(fd_select_entry.operands[0]);
    if (fd_index.count == 0) return error.InvalidCFF;

    // The Font DICTs, their Private DICTs and local subroutines
    const fds = try allocator.alloc(FontDict, fd_index.count);
    defer allocator.free(fds);
    for (fds, 0..) |*fd, k| {
        fd.* = .{ .dict = fd_index.getEntry(@intCast(k)) orelse &.{} };
        const p = findEntry(fd.dict, 18) orelse continue;
        if (p.count < 2 or p.operands[0] < 0 or p.operands[1] < 0) continue;
        const size: usize = @intCast(p.operands[0]);
        const off: usize = @intCast(p.operands[1]);
        if (off > data.len or size > data.len - off) continue;
        fd.private = data[off..][0..size];
        if (findEntry(fd.private, 19)) |subrs| {
            if (subrs.count >= 1 and subrs.operands[0] >= 0) fd.local_subrs = cff.parseCFFIndex(data, off + @as(usize, @intCast(subrs.operands[0])));
        }
    }

    // CharStrings, each desubroutinized with its Font DICT's subroutines;
    // the new FDSelect
    const n: u16 = @intCast(glyphs.len);
    const glyph_fds = try allocator.alloc(u8, glyphs.len);
    defer allocator.free(glyph_fds);
    var cs_items: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (cs_items.items) |it| allocator.free(it);
        cs_items.deinit(allocator);
    }
    for (glyphs, glyph_fds) |gid, *fdi| {
        var k = fdOf(data, fd_select, gid, charstrings.count);
        if (k >= fds.len) k = 0;
        fdi.* = k;
        const src = charstrings.getEntry(gid) orelse &.{};
        const cs = if (src.len > 0)
            try cff.desubroutinizeCharString(allocator, src, global_subrs, fds[k].local_subrs, 0)
        else
            try allocator.dupe(u8, &.{14}); // endchar
        errdefer allocator.free(cs);
        try cs_items.append(allocator, cs);
    }

    // Strings: the Top DICT's and the Font DICTs' FontNames
    var used_sids = try cff.collectTopDictSIDs(allocator, data, name_end);
    defer used_sids.deinit(allocator);
    for (fds) |fd| {
        if (findEntry(fd.dict, op_font_name)) |e| {
            if (e.count >= 1) if (std.math.cast(u16, e.operands[0])) |sid| try used_sids.append(allocator, sid);
        }
    }
    const strings = try cff.buildSubsetStringIndex(allocator, data, string_start, used_sids.items);
    defer allocator.free(strings.data);
    var sid_remap = strings.remap;
    defer sid_remap.deinit(allocator);

    // charset: identity, CID n = glyph n (format 2, one range)
    var charset: std.ArrayListUnmanaged(u8) = .empty;
    defer charset.deinit(allocator);
    if (n >= 2) {
        try charset.append(allocator, 2);
        try binary.appendBE16(&charset, allocator, 1);
        try binary.appendBE16(&charset, allocator, n - 2);
    } else try charset.append(allocator, 0);

    // FDSelect format 3: runs of glyphs with one Font DICT
    var fdsel: std.ArrayListUnmanaged(u8) = .empty;
    defer fdsel.deinit(allocator);
    {
        var ranges: u16 = 0;
        for (glyph_fds, 0..) |k, g| {
            if (g == 0 or k != glyph_fds[g - 1]) ranges += 1;
        }
        try fdsel.append(allocator, 3);
        try binary.appendBE16(&fdsel, allocator, ranges);
        for (glyph_fds, 0..) |k, g| {
            if (g == 0 or k != glyph_fds[g - 1]) {
                try binary.appendBE16(&fdsel, allocator, @intCast(g));
                try fdsel.append(allocator, k);
            }
        }
        try binary.appendBE16(&fdsel, allocator, n);
    }

    var charstrings_index: std.ArrayListUnmanaged(u8) = .empty;
    defer charstrings_index.deinit(allocator);
    try appendIndex(&charstrings_index, allocator, cs_items.items);

    // Private DICTs without Subrs (glyphs are desubroutinized)
    var privates: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;
    defer {
        for (privates.items) |*p| p.deinit(allocator);
        privates.deinit(allocator);
    }
    for (fds) |fd| {
        var p: std.ArrayListUnmanaged(u8) = .empty;
        errdefer p.deinit(allocator);
        if (fd.private.len > 0) try cff.buildPrivateDictWithoutSubrs(allocator, fd.private, &p);
        try privates.append(allocator, p);
    }

    // Font DICTs: everything but Private (re-pointed) and FontName
    // (remapped); a placeholder Private, filled once offsets are known
    var font_dicts: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;
    defer {
        for (font_dicts.items) |*d| d.deinit(allocator);
        font_dicts.deinit(allocator);
    }
    for (fds) |fd| {
        var d: std.ArrayListUnmanaged(u8) = .empty;
        errdefer d.deinit(allocator);
        var pos: usize = 0;
        while (nextEntry(fd.dict, &pos)) |e| {
            switch (e.op) {
                18 => {},
                op_font_name => if (e.count >= 1) {
                    if (std.math.cast(u16, e.operands[0])) |sid| {
                        try cff.encodeCFFInt(allocator, &d, cff.remapSID(sid, &sid_remap));
                        try appendOp(&d, allocator, e.op);
                    }
                },
                else => try d.appendSlice(allocator, fd.dict[e.operand_start..e.end]),
            }
        }
        try appendInt5(&d, allocator, 0);
        try appendInt5(&d, allocator, 0);
        try d.append(allocator, 18);
        try font_dicts.append(allocator, d);
    }

    const name_index = data[hdr_size..name_end];
    const empty_gsubrs = [_]u8{ 0, 0 };

    // The Top DICT's size depends on the offsets it holds: rebuild until it
    // settles (offsets only grow with it, so this ends quickly)
    var top_dict: std.ArrayListUnmanaged(u8) = .empty;
    defer top_dict.deinit(allocator);
    var top_index_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer top_index_bytes.deinit(allocator);
    var fd_array_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer fd_array_bytes.deinit(allocator);
    var top_len: usize = 0;
    var private_start: usize = 0;
    for (0..8) |_| {
        const charset_off = hdr_size + name_index.len + top_len + strings.data.len + empty_gsubrs.len;
        const fdselect_off = charset_off + charset.items.len;
        const charstrings_off = fdselect_off + fdsel.items.len;
        const fdarray_off = charstrings_off + charstrings_index.items.len;

        // FDArray with its Private pointers (fixed-size, so its length is
        // known before the offsets are)
        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        defer items.deinit(allocator);
        for (font_dicts.items) |d| try items.append(allocator, d.items);
        fd_array_bytes.clearRetainingCapacity();
        try appendIndex(&fd_array_bytes, allocator, items.items);
        private_start = fdarray_off + fd_array_bytes.items.len;
        var p_off = private_start;
        for (font_dicts.items, privates.items) |*d, p| {
            const tail = d.items[d.items.len - 11 ..];
            tail[0] = 29;
            std.mem.writeInt(i32, tail[1..5], @intCast(p.items.len), .big);
            tail[5] = 29;
            std.mem.writeInt(i32, tail[6..10], @intCast(p_off), .big);
            p_off += p.items.len;
        }
        fd_array_bytes.clearRetainingCapacity();
        items.clearRetainingCapacity();
        for (font_dicts.items) |d| try items.append(allocator, d.items);
        try appendIndex(&fd_array_bytes, allocator, items.items);

        top_dict.clearRetainingCapacity();
        try buildTopDict(allocator, top, &top_dict, &sid_remap, .{
            .charset = charset_off,
            .charstrings = charstrings_off,
            .fd_array = fdarray_off,
            .fd_select = fdselect_off,
        });
        top_index_bytes.clearRetainingCapacity();
        try appendIndex(&top_index_bytes, allocator, &.{top_dict.items});
        if (top_index_bytes.items.len == top_len) break;
        top_len = top_index_bytes.items.len;
    } else return error.InvalidCFF;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, data[0..hdr_size]);
    try out.appendSlice(allocator, name_index);
    try out.appendSlice(allocator, top_index_bytes.items);
    try out.appendSlice(allocator, strings.data);
    try out.appendSlice(allocator, &empty_gsubrs);
    try out.appendSlice(allocator, charset.items);
    try out.appendSlice(allocator, fdsel.items);
    try out.appendSlice(allocator, charstrings_index.items);
    try out.appendSlice(allocator, fd_array_bytes.items);
    std.debug.assert(out.items.len == private_start);
    for (privates.items) |p| try out.appendSlice(allocator, p.items);
    return out.toOwnedSlice(allocator);
}

const TopOffsets = struct { charset: usize, charstrings: usize, fd_array: usize, fd_select: usize };

/// The Top DICT with new offsets, SIDs remapped, no Encoding or Private.
fn buildTopDict(allocator: Allocator, top: []const u8, out: *std.ArrayListUnmanaged(u8), sid_remap: *const std.AutoHashMapUnmanaged(u16, u16), offsets: TopOffsets) !void {
    var pos: usize = 0;
    while (nextEntry(top, &pos)) |e| {
        switch (e.op) {
            15 => {
                try appendInt5(out, allocator, @intCast(offsets.charset));
                try appendOp(out, allocator, e.op);
            },
            17 => {
                try appendInt5(out, allocator, @intCast(offsets.charstrings));
                try appendOp(out, allocator, e.op);
            },
            op_fd_array => {
                try appendInt5(out, allocator, @intCast(offsets.fd_array));
                try appendOp(out, allocator, e.op);
            },
            op_fd_select => {
                try appendInt5(out, allocator, @intCast(offsets.fd_select));
                try appendOp(out, allocator, e.op);
            },
            16, 18 => {}, // Encoding (none in CID fonts), Private (per Font DICT)
            // SIDs: version, Notice, FullName, FamilyName, Weight,
            // Copyright, PostScript, BaseFontName
            0...4, 0x0C00, 0x0C15, 0x0C16 => if (e.count >= 1) {
                if (std.math.cast(u16, e.operands[0])) |sid| {
                    try cff.encodeCFFInt(allocator, out, cff.remapSID(sid, sid_remap));
                    try appendOp(out, allocator, e.op);
                }
            },
            op_ros => if (e.count >= 3) {
                const reg = std.math.cast(u16, e.operands[0]) orelse 0;
                const ord = std.math.cast(u16, e.operands[1]) orelse 0;
                try cff.encodeCFFInt(allocator, out, cff.remapSID(reg, sid_remap));
                try cff.encodeCFFInt(allocator, out, cff.remapSID(ord, sid_remap));
                try cff.encodeCFFInt(allocator, out, e.operands[2]);
                try appendOp(out, allocator, e.op);
            },
            else => try out.appendSlice(allocator, top[e.operand_start..e.end]),
        }
    }
}
