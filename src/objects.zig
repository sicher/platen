//! PDF object types and serialization
//!
//! PDF files consist of numbered objects in the format:
//! `n 0 obj ... endobj`
//!
//! Objects can be: booleans, integers, reals, strings, names,
//! arrays, dictionaries, streams, and null.

const std = @import("std");

/// Object ID (the 'n' in 'n 0 obj')
pub const ObjectId = u32;

/// PDF Object reference (n 0 R)
pub const Ref = struct {
    id: ObjectId,
    gen: u16 = 0,

    pub fn format(self: Ref, writer: anytype) @TypeOf(writer).Error!void {
        try writer.print("{d} {d} R", .{ self.id, self.gen });
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

    pub fn format(self: Name, writer: anytype) @TypeOf(writer).Error!void {
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
        return .{ .entries = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Dict) void {
        self.entries.deinit(self.allocator);
    }

    pub fn put(self: *Dict, key: []const u8, value: Value) !void {
        try self.entries.append(self.allocator, .{ .key = .{ .value = key }, .value = value });
    }

    pub fn format(self: Dict, writer: anytype) @TypeOf(writer).Error!void {
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
        return .{ .items = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Array) void {
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *Array, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn format(self: Array, writer: anytype) @TypeOf(writer).Error!void {
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

    pub fn format(self: Value, writer: anytype) @TypeOf(writer).Error!void {
        switch (self) {
            .null_val => try writer.writeAll("null"),
            .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
            .int_val => |i| try writer.print("{d}", .{i}),
            .real_val => |r| try writer.print("{d:.4}", .{r}),
            .string_val => |s| {
                try writer.writeByte('(');
                try writer.writeAll(s); // TODO: escape special chars
                try writer.writeByte(')');
            },
            .name_val => |n| try n.format(writer),
            .array_val => |a| try a.format(writer),
            .dict_val => |d| try d.format(writer),
            .ref_val => |r| try r.format(writer),
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
};

test "Ref format" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const r = Ref{ .id = 5, .gen = 0 };
    try r.format(stream.writer());
    try std.testing.expectEqualStrings("5 0 R", stream.getWritten());
}

test "Name format" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const n = Name{ .value = "Type" };
    try n.format(stream.writer());
    try std.testing.expectEqualStrings("/Type", stream.getWritten());
}

test "Value int format" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try Value.int(42).format(stream.writer());
    try std.testing.expectEqualStrings("42", stream.getWritten());
}
