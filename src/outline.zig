//! Outline builder for PDF document table of contents.
//!
//! Provides a builder pattern for constructing document outlines (bookmarks)
//! with hierarchical structure.

const std = @import("std");
const layout = @import("layout.zig");

pub const OutlineItem = layout.OutlineItem;
pub const Destination = layout.Destination;

/// Outline builder for document table of contents.
/// Build the outline hierarchy, then pass to document with setOutline().
pub const Outline = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(*OutlineItem) = .empty,
    last_top_level: ?*OutlineItem = null,

    pub fn init(allocator: std.mem.Allocator) Outline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Outline) void {
        for (self.items.items) |item| {
            self.allocator.destroy(item);
        }
        self.items.deinit(self.allocator);
    }

    /// Add a top-level outline item.
    /// Returns the item so it can be used as parent for addChild().
    pub fn add(self: *Outline, title: []const u8, dest: Destination) !*OutlineItem {
        const item = try self.allocator.create(OutlineItem);
        item.* = .{ .title = title, .dest = dest };

        if (self.last_top_level) |last| {
            last.next = item;
            item.prev = last;
        }
        self.last_top_level = item;

        try self.items.append(self.allocator, item);
        return item;
    }

    /// Add a child outline item under a parent.
    /// Returns the item so it can be used as parent for deeper nesting.
    pub fn addChild(self: *Outline, parent: *OutlineItem, title: []const u8, dest: Destination) !*OutlineItem {
        const item = try self.allocator.create(OutlineItem);
        item.* = .{ .title = title, .dest = dest, .parent = parent };

        if (parent.last_child) |last| {
            last.next = item;
            item.prev = last;
        } else {
            parent.first_child = item;
        }
        parent.last_child = item;
        parent.count += 1;

        try self.items.append(self.allocator, item);
        return item;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Outline add top-level items" {
    var outline = Outline.init(std.testing.allocator);
    defer outline.deinit();

    const ch1 = try outline.add("Chapter 1", .{ .page_index = 0, .y = 100 });
    const ch2 = try outline.add("Chapter 2", .{ .page_index = 1, .y = 100 });

    try std.testing.expectEqual(@as(usize, 2), outline.items.items.len);
    try std.testing.expectEqualStrings("Chapter 1", ch1.title);
    try std.testing.expectEqualStrings("Chapter 2", ch2.title);
    try std.testing.expect(ch1.next == ch2);
    try std.testing.expect(ch2.prev == ch1);
}

test "Outline add children" {
    var outline = Outline.init(std.testing.allocator);
    defer outline.deinit();

    const ch1 = try outline.add("Chapter 1", .{ .page_index = 0, .y = 100 });
    const sec1 = try outline.addChild(ch1, "Section 1.1", .{ .page_index = 0, .y = 200 });
    const sec2 = try outline.addChild(ch1, "Section 1.2", .{ .page_index = 0, .y = 300 });

    try std.testing.expectEqual(@as(usize, 3), outline.items.items.len);
    try std.testing.expect(sec1.parent == ch1);
    try std.testing.expect(sec2.parent == ch1);
    try std.testing.expect(ch1.first_child == sec1);
    try std.testing.expect(ch1.last_child == sec2);
    try std.testing.expectEqual(@as(i32, 2), ch1.count);
    try std.testing.expect(sec1.next == sec2);
    try std.testing.expect(sec2.prev == sec1);
}

test "Outline nested children" {
    var outline = Outline.init(std.testing.allocator);
    defer outline.deinit();

    const ch1 = try outline.add("Chapter 1", .{ .page_index = 0, .y = 100 });
    const sec1 = try outline.addChild(ch1, "Section 1.1", .{ .page_index = 0, .y = 200 });
    const subsec1 = try outline.addChild(sec1, "Subsection 1.1.1", .{ .page_index = 0, .y = 250 });

    try std.testing.expect(subsec1.parent == sec1);
    try std.testing.expect(sec1.first_child == subsec1);
    try std.testing.expectEqual(@as(i32, 1), sec1.count);
}
