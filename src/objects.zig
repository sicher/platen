//! PDF object types and serialization
//!
//! PDF files consist of numbered objects in the format:
//! `n 0 obj ... endobj`
//!
//! Objects can be: booleans, integers, reals, strings, names,
//! arrays, dictionaries, streams, and null.

const std = @import("std");
const fmt = @import("format.zig");

/// Object ID (the 'n' in 'n 0 obj')
pub const ObjectId = u32;

/// PDF Object reference (n 0 R)
pub const Ref = struct {
    id: ObjectId,
    gen: u16 = 0,

    pub fn format(self: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        try writer.writeAll(fmt.writeInt(&buf, self.id));
        try writer.writeByte(' ');
        try writer.writeAll(fmt.writeInt(&buf, self.gen));
        try writer.writeAll(" R");
    }
};

/// Tracks object IDs for a document
pub const ObjectIdAllocator = struct {
    next_id: ObjectId = 1, // Object IDs start at 1

    pub fn alloc(self: *ObjectIdAllocator) ObjectId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn ref(self: *ObjectIdAllocator) Ref {
        return .{ .id = self.alloc() };
    }
};

/// PDF Name (e.g., /Type, /Page)
pub const Name = struct {
    value: []const u8,

    pub fn format(self: Name, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('/');
        try writer.writeAll(self.value);
    }
};

/// PDF Dictionary
pub const Dict = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        key: Name,
        value: Value,
    };

    pub fn init(allocator: std.mem.Allocator) Dict {
        return .{ .entries = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Dict) void {
        self.entries.deinit(self.allocator);
    }

    pub fn put(self: *Dict, key: []const u8, value: Value) !void {
        try self.entries.append(self.allocator, .{ .key = .{ .value = key }, .value = value });
    }

    pub fn format(self: Dict, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<<\n");
        for (self.entries.items) |entry| {
            try entry.key.format(writer);
            try writer.writeByte(' ');
            try entry.value.format(writer);
            try writer.writeByte('\n');
        }
        try writer.writeAll(">>");
    }
};

/// PDF Array
pub const Array = struct {
    items: std.ArrayListUnmanaged(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Array {
        return .{ .items = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Array) void {
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *Array, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn format(self: Array, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('[');
        for (self.items.items, 0..) |item, i| {
            if (i > 0) try writer.writeByte(' ');
            try item.format(writer);
        }
        try writer.writeByte(']');
    }
};

/// PDF Value (union of all value types)
pub const Value = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    real_val: f64,
    string_val: []const u8,
    name_val: Name,
    array_val: *Array,
    dict_val: *Dict,
    ref_val: Ref,
    literal_val: []const u8, // Raw output (no escaping/wrapping)

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        switch (self) {
            .null_val => try writer.writeAll("null"),
            .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
            .int_val => |i| try writer.writeAll(fmt.writeInt(&buf, i)),
            .real_val => |r| try writer.writeAll(fmt.writeF64_3(&buf, r)),
            .string_val => |s| {
                try writer.writeByte('(');
                // Escape special PDF string characters: \, (, )
                for (s) |c| {
                    switch (c) {
                        '\\' => try writer.writeAll("\\\\"),
                        '(' => try writer.writeAll("\\("),
                        ')' => try writer.writeAll("\\)"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeByte(')');
            },
            .name_val => |n| try n.format(writer),
            .array_val => |a| try a.format(writer),
            .dict_val => |d| try d.format(writer),
            .ref_val => |r| try r.format(writer),
            .literal_val => |l| try writer.writeAll(l),
        }
    }

    // Convenience constructors
    pub fn int(i: i64) Value {
        return .{ .int_val = i };
    }

    pub fn real(r: f64) Value {
        return .{ .real_val = r };
    }

    pub fn name(n: []const u8) Value {
        return .{ .name_val = .{ .value = n } };
    }

    pub fn ref(r: Ref) Value {
        return .{ .ref_val = r };
    }

    pub fn string(s: []const u8) Value {
        return .{ .string_val = s };
    }

    pub fn literal(s: []const u8) Value {
        return .{ .literal_val = s };
    }
};

test "Ref format" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const r = Ref{ .id = 5, .gen = 0 };
    try r.format(&w);
    try std.testing.expectEqualStrings("5 0 R", w.buffered());
}

test "Name format" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const n = Name{ .value = "Type" };
    try n.format(&w);
    try std.testing.expectEqualStrings("/Type", w.buffered());
}

test "Value int format" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Value.int(42).format(&w);
    try std.testing.expectEqualStrings("42", w.buffered());
}
