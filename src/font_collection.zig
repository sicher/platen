//! TrueType/OpenType collections (.ttc/.otc).
//!
//! A collection is a `ttcf` header followed by one offset table per face;
//! the faces' table offsets are absolute in the file and faces share
//! tables. `extractFace` rebuilds one face as a standalone sfnt (what
//! `Document.loadFontFromMemory` and the subsetters expect). A plain
//! .ttf/.otf is treated as a collection of one face, so every function
//! here accepts both.
//!
//! All parsing is bounds-checked: hostile data yields an error or null,
//! never a panic.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidSignature,
    InvalidCollection,
    FaceIndexOutOfRange,
    OutOfBounds,
};

/// True for a `ttcf` collection header.
pub fn isCollection(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "ttcf");
}

/// Number of faces: the collection's face count, or 1 for a single sfnt.
pub fn faceCount(data: []const u8) Error!u32 {
    if (!isCollection(data)) {
        if (!isSfnt(data, 0)) return Error.InvalidSignature;
        return 1;
    }
    if (data.len < 12) return Error.InvalidCollection;
    const n = be32(data, 8) orelse return Error.InvalidCollection;
    // Each face needs a 4-byte offset in the header.
    if (n == 0 or n > (data.len - 12) / 4) return Error.InvalidCollection;
    return n;
}

/// Byte offset of face `index`'s offset table (0 for a single sfnt).
pub fn faceOffset(data: []const u8, index: u32) Error!usize {
    const n = try faceCount(data);
    if (index >= n) return Error.FaceIndexOutOfRange;
    if (!isCollection(data)) return 0;
    const off = be32(data, 12 + 4 * @as(usize, index)) orelse return Error.InvalidCollection;
    if (!isSfnt(data, off)) return Error.InvalidSignature;
    return off;
}

/// A face's table, read in place (offsets in a collection are file-absolute).
/// Null if the face has no such table or its record is out of bounds.
pub fn faceTable(data: []const u8, face_offset: usize, tag: *const [4]u8) ?[]const u8 {
    const num = be16(data, face_offset + 4) orelse return null;
    for (0..num) |t| {
        const rec = face_offset + 12 + 16 * t;
        if (rec + 16 > data.len) return null;
        if (!std.mem.eql(u8, data[rec..][0..4], tag)) continue;
        return slice(data, be32(data, rec + 8).?, be32(data, rec + 12).?);
    }
    return null;
}

/// Rebuilds face `index` as a standalone sfnt in a new buffer owned by the
/// caller. Tables are copied in directory order, each 4-byte aligned with
/// zero padding; the directory header and the per-table checksums are kept
/// (table bytes are unchanged). A single sfnt (index 0) is copied as is.
pub fn extractFace(allocator: Allocator, data: []const u8, index: u32) (Error || Allocator.Error)![]u8 {
    const off = try faceOffset(data, index);
    if (!isCollection(data)) return allocator.dupe(u8, data);

    const num: usize = be16(data, off + 4) orelse return Error.OutOfBounds;
    const dir_len = 12 + 16 * num;
    if (off + dir_len > data.len) return Error.OutOfBounds;

    var size: usize = dir_len;
    for (0..num) |t| {
        const rec = off + 12 + 16 * t;
        const toff = be32(data, rec + 8).?;
        const len = be32(data, rec + 12).?;
        _ = slice(data, toff, len) orelse return Error.OutOfBounds;
        size += pad4(len);
    }

    const out = try allocator.alloc(u8, size);
    @memset(out, 0);
    @memcpy(out[0..dir_len], data[off..][0..dir_len]);
    var pos: usize = dir_len;
    for (0..num) |t| {
        const rec = 12 + 16 * t;
        const toff = be32(out, rec + 8).?;
        const len = be32(out, rec + 12).?;
        std.mem.writeInt(u32, out[rec + 8 ..][0..4], @intCast(pos), .big);
        @memcpy(out[pos..][0..len], data[toff..][0..len]);
        pos += pad4(len);
    }
    return out;
}

/// Names and style of one face, decoded to UTF-8.
pub const FaceInfo = struct {
    index: u32,
    /// Typographic family (name ID 16), else family (ID 1).
    family: []const u8,
    /// Typographic subfamily (ID 17), else subfamily (ID 2).
    subfamily: []const u8,
    /// PostScript name (ID 6); empty if absent.
    postscript_name: []const u8,
    /// OS/2 usWeightClass; 0 without an OS/2 table.
    weight: u16,
    /// OS/2 usWidthClass (5 = normal); 0 without an OS/2 table.
    width: u16,
    /// OS/2 fsSelection BOLD, else head.macStyle bold.
    bold: bool,
    /// OS/2 fsSelection ITALIC, else head.macStyle italic.
    italic: bool,

    pub fn deinit(self: FaceInfo, allocator: Allocator) void {
        allocator.free(self.family);
        allocator.free(self.subfamily);
        allocator.free(self.postscript_name);
    }
};

/// Names and style of face `index` (no extraction). Fails with
/// error.MissingName if the face has no usable family or subfamily name.
pub fn describeFace(allocator: Allocator, data: []const u8, index: u32) !FaceInfo {
    const off = try faceOffset(data, index);
    const name = faceTable(data, off, "name") orelse return error.MissingName;
    const recs = pickNames(name);
    const fam = recs[16] orelse recs[1] orelse return error.MissingName;
    const sub = recs[17] orelse recs[2] orelse return error.MissingName;

    const family = try decodeName(allocator, fam);
    errdefer allocator.free(family);
    const subfamily = try decodeName(allocator, sub);
    errdefer allocator.free(subfamily);
    const ps = if (recs[6]) |r| try decodeName(allocator, r) else try allocator.dupe(u8, "");

    var info: FaceInfo = .{
        .index = index,
        .family = family,
        .subfamily = subfamily,
        .postscript_name = ps,
        .weight = 0,
        .width = 0,
        .bold = false,
        .italic = false,
    };
    if (faceTable(data, off, "OS/2")) |os2| {
        info.weight = be16(os2, 4) orelse 0;
        info.width = be16(os2, 6) orelse 0;
        const sel = be16(os2, 62) orelse 0;
        info.bold = sel & (1 << 5) != 0;
        info.italic = sel & 1 != 0;
    } else if (faceTable(data, off, "head")) |head| {
        const mac = be16(head, 44) orelse 0;
        info.bold = mac & 1 != 0;
        info.italic = mac & 2 != 0;
    }
    return info;
}

/// Describes every face of a collection (or the one face of a sfnt). Faces
/// without usable names are skipped. Free with `freeFaces`.
pub fn listFaces(allocator: Allocator, data: []const u8) ![]FaceInfo {
    const n = try faceCount(data);
    var out: std.ArrayList(FaceInfo) = .empty;
    errdefer {
        for (out.items) |f| f.deinit(allocator);
        out.deinit(allocator);
    }
    for (0..n) |i| {
        const info = describeFace(allocator, data, @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        out.append(allocator, info) catch |err| {
            info.deinit(allocator);
            return err;
        };
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeFaces(allocator: Allocator, faces: []const FaceInfo) void {
    for (faces) |f| f.deinit(allocator);
    allocator.free(faces);
}

// ============================================================================
// name table
// ============================================================================

const NameRecord = struct { platform: u16, data: []const u8 };

/// Highest name ID we read (17, typographic subfamily).
const max_name_id = 17;

/// The best English record per name ID: Windows US English, then Unicode
/// platform, then Mac Roman English, then any other Windows language.
fn pickNames(name: []const u8) [max_name_id + 1]?NameRecord {
    var best: [max_name_id + 1]?NameRecord = @splat(null);
    var rank: [max_name_id + 1]u8 = @splat(0);
    const count = be16(name, 2) orelse return best;
    const strings: usize = be16(name, 4) orelse return best;
    for (0..count) |i| {
        const r = 6 + 12 * i;
        if (r + 12 > name.len) break;
        const platform = be16(name, r).?;
        const encoding = be16(name, r + 2).?;
        const lang = be16(name, r + 4).?;
        const id = be16(name, r + 6).?;
        if (id > max_name_id) continue;
        const score: u8 = switch (platform) {
            0 => 3,
            1 => if (encoding == 0 and lang == 0) 2 else 0,
            3 => if (encoding != 0 and encoding != 1 and encoding != 10) 0 else if (lang == 0x409) 4 else 1,
            else => 0,
        };
        if (score <= rank[id]) continue;
        const bytes = slice(name, strings + be16(name, r + 10).?, be16(name, r + 8).?) orelse continue;
        best[id] = .{ .platform = platform, .data = bytes };
        rank[id] = score;
    }
    return best;
}

/// UTF-16BE (platforms 0 and 3) or Mac Roman (platform 1) to UTF-8.
/// Unpaired surrogates become U+FFFD.
fn decodeName(allocator: Allocator, rec: NameRecord) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    if (rec.platform == 1) {
        for (rec.data) |c| {
            const cp: u21 = if (c < 0x80) c else mac_roman_high[c - 0x80];
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(allocator, buf[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }
    var i: usize = 0;
    while (i + 1 < rec.data.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, rec.data[i..][0..2], .big);
        if (cp >= 0xD800 and cp < 0xDC00 and i + 3 < rec.data.len) {
            const lo = std.mem.readInt(u16, rec.data[i + 2 ..][0..2], .big);
            if (lo >= 0xDC00 and lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Mac OS Roman 0x80..0xFF.
const mac_roman_high = [128]u21{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, 0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, 0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, 0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, 0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, 0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, 0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, 0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, 0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

// ============================================================================
// Helpers
// ============================================================================

fn isSfnt(data: []const u8, off: usize) bool {
    const sig = be32(data, off) orelse return false;
    if (off + 12 > data.len) return false;
    return sig == 0x00010000 or sig == 0x74727565 or sig == 0x74797031 or sig == 0x4F54544F;
}

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// data[off..][0..len], or null if out of bounds (overflow-safe).
fn slice(data: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > data.len or len > data.len - off) return null;
    return data[off..][0..len];
}

fn be16(data: []const u8, off: usize) ?u16 {
    const s = slice(data, off, 2) orelse return null;
    return std.mem.readInt(u16, s[0..2], .big);
}

fn be32(data: []const u8, off: usize) ?u32 {
    const s = slice(data, off, 4) orelse return null;
    return std.mem.readInt(u32, s[0..4], .big);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const ttf = @import("ttf.zig");

fn readTestFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20));
}

test "single sfnt is a one-face collection" {
    const data = try readTestFile("test/fonts/Courier Prime/Courier Prime.ttf");
    defer testing.allocator.free(data);
    try testing.expect(!isCollection(data));
    try testing.expectEqual(@as(u32, 1), try faceCount(data));
    try testing.expectError(Error.FaceIndexOutOfRange, faceOffset(data, 1));

    const copy = try extractFace(testing.allocator, data, 0);
    defer testing.allocator.free(copy);
    try testing.expectEqualSlices(u8, data, copy);

    const info = try describeFace(testing.allocator, data, 0);
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("Courier Prime", info.family);
    try testing.expectEqualStrings("Regular", info.subfamily);
    try testing.expectEqualStrings("CourierPrime", info.postscript_name);
}

test "extracted faces keep every table byte-identical and parse" {
    const data = try readTestFile("test/fonts/Inter/Inter.ttc");
    defer testing.allocator.free(data);
    try testing.expect(isCollection(data));
    const n = try faceCount(data);
    try testing.expectEqual(@as(u32, 36), n);
    try testing.expectError(Error.FaceIndexOutOfRange, extractFace(testing.allocator, data, n));

    for (0..n) |i| {
        const face = try extractFace(testing.allocator, data, @intCast(i));
        defer testing.allocator.free(face);
        const off = try faceOffset(data, @intCast(i));
        const num = be16(face, 4).?;
        try testing.expectEqual(be16(data, off + 4).?, num);
        try testing.expectEqual(@as(usize, 0), face.len % 4);
        for (0..num) |t| {
            const rec = 12 + 16 * t;
            const tag = face[rec..][0..4];
            try testing.expectEqual(be32(data, off + rec + 4).?, be32(face, rec + 4).?); // checksum kept
            try testing.expectEqual(@as(u32, 0), be32(face, rec + 8).? % 4);
            try testing.expectEqualSlices(u8, faceTable(data, off, tag).?, faceTable(face, 0, tag).?);
        }
        const font = try ttf.Font.parse(face);
        try testing.expect(font.head != null and font.hhea != null);
    }
}

test "listFaces names match fontTools" {
    // Expected values: scripts/gen_ttc_reference.py (fontTools) ->
    // test/reference/inter_ttc_faces.tsv (index, family, subfamily,
    // postscript name, weight, width, bold, italic).
    const data = try readTestFile("test/fonts/Inter/Inter.ttc");
    defer testing.allocator.free(data);
    const expected = try readTestFile("test/reference/inter_ttc_faces.tsv");
    defer testing.allocator.free(expected);

    const faces = try listFaces(testing.allocator, data);
    defer freeFaces(testing.allocator, faces);

    var lines = std.mem.tokenizeScalar(u8, expected, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        var buf: [256]u8 = undefined;
        const f = faces[i];
        const got = try std.fmt.bufPrint(&buf, "{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}", .{
            f.index, f.family, f.subfamily, f.postscript_name, f.weight, f.width, @intFromBool(f.bold), @intFromBool(f.italic),
        });
        try testing.expectEqualStrings(line, got);
    }
    try testing.expectEqual(faces.len, i);
}

test "decodeName handles surrogates and Mac Roman" {
    const utf16 = [_]u8{ 0x00, 'A', 0xD8, 0x3D, 0xDE, 0x00, 0xDC, 0x00 };
    const s = try decodeName(testing.allocator, .{ .platform = 3, .data = &utf16 });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("A\u{1F600}\u{FFFD}", s);

    const mac = [_]u8{ 'C', 'a', 'f', 0x8E };
    const m = try decodeName(testing.allocator, .{ .platform = 1, .data = &mac });
    defer testing.allocator.free(m);
    try testing.expectEqualStrings("Caf\u{E9}", m);
}

test "hostile collections fail cleanly" {
    // Face count far beyond the header.
    try testing.expectError(Error.InvalidCollection, faceCount("ttcf\x00\x01\x00\x00\xff\xff\xff\xff"));
    // Face offset pointing past the end.
    const bad_off = "ttcf\x00\x01\x00\x00\x00\x00\x00\x01\xff\xff\xff\xf0";
    try testing.expectError(Error.InvalidSignature, extractFace(testing.allocator, bad_off, 0));
    // Table record whose offset + length overflows.
    var buf: [48]u8 = @splat(0);
    @memcpy(buf[0..4], "ttcf");
    std.mem.writeInt(u32, buf[8..12], 1, .big);
    std.mem.writeInt(u32, buf[12..16], 16, .big);
    std.mem.writeInt(u32, buf[16..20], 0x00010000, .big);
    std.mem.writeInt(u16, buf[20..22], 1, .big);
    @memcpy(buf[28..32], "head");
    std.mem.writeInt(u32, buf[36..40], 0xffff_fff0, .big);
    std.mem.writeInt(u32, buf[40..44], 0x20, .big);
    try testing.expectError(Error.OutOfBounds, extractFace(testing.allocator, &buf, 0));
    try testing.expect(faceTable(&buf, 16, "head") == null);
    try testing.expectError(error.MissingName, describeFace(testing.allocator, &buf, 0));
}
