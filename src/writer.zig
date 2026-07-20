//! PDF Writer
//!
//! Handles serializing PDF structure to a byte stream:
//! - Header with version and binary marker
//! - Objects with tracking of byte offsets
//! - Cross-reference table
//! - Trailer

const std = @import("std");
const objects = @import("objects.zig");
const zlib = @import("zlib.zig");

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Value = objects.Value;

pub const PDF_VERSION = "1.4";

/// Tracks byte offset for each object (for xref table)
const ObjectOffset = struct {
    id: ObjectId,
    offset: u64,
};

/// PDF Writer - serializes PDF structure to output
pub const Writer = struct {
    output: std.ArrayListUnmanaged(u8),
    offsets: std.ArrayListUnmanaged(ObjectOffset),
    allocator: std.mem.Allocator,
    /// Compression level for FlateDecode streams (0-9, default 1 for speed)
    compression_level: i32 = 1,
    /// Optional map of already-compressed stream data, keyed by
    /// @intFromPtr(data.ptr) of the raw stream. writeStreamCompressed uses a
    /// hit instead of compressing inline; entries must be produced with the
    /// same compression_level so output stays byte-identical.
    precompressed: ?*const std.AutoHashMapUnmanaged(usize, []const u8) = null,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .output = .empty,
            .offsets = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.output.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }

    /// Write PDF header with binary marker
    pub fn writeHeader(self: *Writer) !void {
        // PDF version
        try self.output.appendSlice(self.allocator, "%PDF-" ++ PDF_VERSION ++ "\n");
        // Binary marker (high-bit bytes to indicate binary content)
        try self.output.appendSlice(self.allocator, "%\xE2\xE3\xCF\xD3\n");
    }

    /// Begin an object and record its offset
    pub fn beginObject(self: *Writer, id: ObjectId) !void {
        try self.offsets.append(self.allocator, .{ .id = id, .offset = self.output.items.len });
        var buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{id}) catch unreachable;
        try self.output.appendSlice(self.allocator, header);
    }

    /// End an object
    pub fn endObject(self: *Writer) !void {
        try self.output.appendSlice(self.allocator, "endobj\n");
    }

    /// Write a dictionary as the object content
    pub fn writeDict(self: *Writer, dict: Dict) !void {
        try self.output.ensureUnusedCapacity(self.allocator, 4096);
        var w = std.Io.Writer.fixed(self.output.unusedCapacitySlice());
        dict.format(&w) catch {
            // Need more space, expand and retry
            try self.output.ensureUnusedCapacity(self.allocator, 8192);
            w = std.Io.Writer.fixed(self.output.unusedCapacitySlice());
            try dict.format(&w);
        };
        self.output.items.len += w.end;
        try self.output.append(self.allocator, '\n');
    }

    /// Write a stream object (dictionary + stream data)
    pub fn writeStream(self: *Writer, dict: *Dict, data: []const u8) !void {
        try dict.put("Length", Value.int(@intCast(data.len)));
        try self.writeDict(dict.*);
        try self.output.appendSlice(self.allocator, "stream\n");
        try self.output.appendSlice(self.allocator, data);
        try self.output.appendSlice(self.allocator, "\nendstream\n");
    }

    /// Streams below this size skip the compression attempt entirely: zlib's
    /// fixed overhead (~6 bytes plus block framing) means tiny streams
    /// almost never shrink, and emoji/pixel fonts emit hundreds of tiny
    /// CharProc streams per document.
    pub const min_compress_len = 64;

    /// Write a compressed stream object using FlateDecode (zlib)
    /// Compresses the data and adds appropriate Filter entry to dict
    pub fn writeStreamCompressed(self: *Writer, dict: *Dict, data: []const u8) !void {
        if (data.len < min_compress_len or self.compression_level == 0) {
            return self.writeStream(dict, data);
        }

        // Use a precompressed result if one was prepared (parallel
        // compression); falls through to inline compression on miss
        if (self.precompressed) |map| {
            if (map.get(@intFromPtr(data.ptr))) |pre| {
                return self.writeStreamPicking(dict, data, pre);
            }
        }

        // Compress the data using configured level (default 1 for speed)
        const compressed = try zlib.compressLevel(self.allocator, data, self.compression_level);
        defer self.allocator.free(compressed);

        return self.writeStreamPicking(dict, data, compressed);
    }

    /// Emit the compressed variant if it is smaller, the raw stream otherwise.
    fn writeStreamPicking(self: *Writer, dict: *Dict, data: []const u8, compressed: []const u8) !void {
        // Only use compression if it actually saves space
        if (compressed.len < data.len) {
            try dict.put("Filter", Value.name("FlateDecode"));
            try dict.put("Length", Value.int(@intCast(compressed.len)));
            try self.writeDict(dict.*);
            try self.output.appendSlice(self.allocator, "stream\n");
            try self.output.appendSlice(self.allocator, compressed);
            try self.output.appendSlice(self.allocator, "\nendstream\n");
        } else {
            // Fall back to uncompressed if compression doesn't help
            try self.writeStream(dict, data);
        }
    }

    /// Options for finishing the PDF
    pub const FinishOptions = struct {
        catalog_ref: Ref,
        info_ref: ?Ref = null,
        /// Document ID for trailer (required for PDF/A). Two 16-byte hex strings.
        /// Format: "<hex1><hex2>" where each hex is 16 bytes
        id: ?[]const u8 = null,
    };

    /// Write xref table and trailer, return the final PDF bytes
    /// Caller owns the returned memory
    pub fn finish(self: *Writer, opts: FinishOptions) ![]u8 {
        const xref_offset = self.output.items.len;

        // Sort offsets by object ID
        std.mem.sort(ObjectOffset, self.offsets.items, {}, struct {
            fn lessThan(_: void, a: ObjectOffset, b: ObjectOffset) bool {
                return a.id < b.id;
            }
        }.lessThan);

        // Find max object ID
        var max_id: ObjectId = 0;
        for (self.offsets.items) |off| {
            if (off.id > max_id) max_id = off.id;
        }

        // Write xref table
        try self.output.appendSlice(self.allocator, "xref\n");
        var buf: [64]u8 = undefined;
        var header = std.fmt.bufPrint(&buf, "0 {d}\n", .{max_id + 1}) catch unreachable;
        try self.output.appendSlice(self.allocator, header);

        // Object 0 is always free
        try self.output.appendSlice(self.allocator, "0000000000 65535 f \n");

        // Write entries for each object
        var offset_idx: usize = 0;
        var obj_id: ObjectId = 1;
        while (obj_id <= max_id) : (obj_id += 1) {
            if (offset_idx < self.offsets.items.len and
                self.offsets.items[offset_idx].id == obj_id)
            {
                const offset = self.offsets.items[offset_idx].offset;
                const entry = std.fmt.bufPrint(&buf, "{d:0>10} 00000 n \n", .{offset}) catch unreachable;
                try self.output.appendSlice(self.allocator, entry);
                offset_idx += 1;
            } else {
                // Missing object, mark as free
                try self.output.appendSlice(self.allocator, "0000000000 65535 f \n");
            }
        }

        // Write trailer
        try self.output.appendSlice(self.allocator, "trailer\n<<\n");
        header = std.fmt.bufPrint(&buf, "/Size {d}\n", .{max_id + 1}) catch unreachable;
        try self.output.appendSlice(self.allocator, header);
        header = std.fmt.bufPrint(&buf, "/Root {d} 0 R\n", .{opts.catalog_ref.id}) catch unreachable;
        try self.output.appendSlice(self.allocator, header);
        if (opts.info_ref) |info| {
            header = std.fmt.bufPrint(&buf, "/Info {d} 0 R\n", .{info.id}) catch unreachable;
            try self.output.appendSlice(self.allocator, header);
        }
        if (opts.id) |id| {
            // Write ID array: two identical hex strings for new documents
            try self.output.appendSlice(self.allocator, "/ID [<");
            try self.output.appendSlice(self.allocator, id);
            try self.output.appendSlice(self.allocator, "><");
            try self.output.appendSlice(self.allocator, id);
            try self.output.appendSlice(self.allocator, ">]\n");
        }
        try self.output.appendSlice(self.allocator, ">>\n");

        // Write startxref
        try self.output.appendSlice(self.allocator, "startxref\n");
        header = std.fmt.bufPrint(&buf, "{d}\n", .{xref_offset}) catch unreachable;
        try self.output.appendSlice(self.allocator, header);
        try self.output.appendSlice(self.allocator, "%%EOF\n");

        return self.output.toOwnedSlice(self.allocator);
    }

    /// Get current byte position
    pub fn pos(self: *Writer) u64 {
        return self.output.items.len;
    }
};

test "Writer header" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();

    try w.writeHeader();
    try std.testing.expect(std.mem.startsWith(u8, w.output.items, "%PDF-1.4\n"));
}

test "Writer object" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();

    try w.beginObject(1);
    try w.output.appendSlice(w.allocator, "<< /Type /Catalog >>\n");
    try w.endObject();

    try std.testing.expect(std.mem.indexOf(u8, w.output.items, "1 0 obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.output.items, "endobj") != null);
}
