//! StyledText API for building styled paragraphs.
//!
//! Provides a builder pattern for constructing text with inline style changes.
//! Supports preprocessing for efficient Knuth-Plass optimal line breaking.

const std = @import("std");
const layout = @import("layout.zig");

pub const Color = layout.Color;
pub const TextDecoration = layout.TextDecoration;
pub const TextStyleOptions = layout.TextStyleOptions;

/// A span of text with uniform styling.
pub const Span = struct {
    text: []const u8,
    style: TextStyleOptions = .{},
};

/// Preprocessed word info for line breaking.
/// A word may span multiple styled segments.
const StyledWord = struct {
    /// Index of first span containing this word.
    start_span: u16,
    /// Byte offset within start span.
    start_offset: u16,
    /// Index of last span containing this word.
    end_span: u16,
    /// Byte offset within end span (exclusive).
    end_offset: u16,
    /// Total width of word in points.
    width: f64,
    /// Must break after this word (newline follows).
    force_break: bool,
};

/// Function type for measuring text width.
pub const MeasureFn = *const fn (text: []const u8, style: TextStyleOptions, ctx: *anyopaque) f64;

/// Builder for constructing styled text with inline style changes.
/// Mirrors the Path API pattern.
pub const StyledText = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(Span) = .{},
    /// Owned copies of text (if using appendOwned).
    owned_text: std.ArrayListUnmanaged([]const u8) = .{},

    // Preprocessed data for Knuth-Plass (populated by prepare())
    words: std.ArrayListUnmanaged(StyledWord) = .{},
    prepared: bool = false,

    pub fn init(allocator: std.mem.Allocator) StyledText {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StyledText) void {
        // Free owned text copies
        for (self.owned_text.items) |text| {
            self.allocator.free(text);
        }
        self.owned_text.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.words.deinit(self.allocator);
    }

    /// Append a span of text with the given style.
    /// The text slice must remain valid until rendering.
    pub fn append(self: *StyledText, text: []const u8, style: TextStyleOptions) !void {
        try self.spans.append(self.allocator, .{ .text = text, .style = style });
        self.prepared = false;
    }

    /// Append a span, taking ownership of the text (copies it).
    /// Use when the source text won't remain valid.
    pub fn appendOwned(self: *StyledText, text: []const u8, style: TextStyleOptions) !void {
        const copy = try self.allocator.dupe(u8, text);
        try self.owned_text.append(self.allocator, copy);
        try self.spans.append(self.allocator, .{ .text = copy, .style = style });
        self.prepared = false;
    }

    /// Returns true if no text has been added.
    pub fn isEmpty(self: *const StyledText) bool {
        return self.spans.items.len == 0;
    }

    /// Total text length across all spans.
    pub fn totalLength(self: *const StyledText) usize {
        var len: usize = 0;
        for (self.spans.items) |span| {
            len += span.text.len;
        }
        return len;
    }

    /// Prepare for rendering by preprocessing word boundaries and measuring widths.
    /// Must be called before writeStyled() and requires the document's font context.
    pub fn prepare(self: *StyledText, measure_fn: MeasureFn, ctx: *anyopaque) !void {
        if (self.prepared) return;

        self.words.clearRetainingCapacity();

        if (self.spans.items.len == 0) {
            self.prepared = true;
            return;
        }

        // Walk through all spans, identifying words and measuring them
        var span_idx: u16 = 0;
        var byte_idx: u16 = 0;

        // Current word being built
        var word_start_span: u16 = 0;
        var word_start_offset: u16 = 0;
        var word_width: f64 = 0;
        var in_word = false;

        while (span_idx < self.spans.items.len) {
            const span = self.spans.items[span_idx];

            while (byte_idx < span.text.len) {
                const c = span.text[byte_idx];
                const is_space = (c == ' ' or c == '\t' or c == '\n');

                if (is_space) {
                    if (in_word) {
                        // End of word - measure all spans that contribute to this word
                        word_width = self.measureWord(word_start_span, word_start_offset, span_idx, byte_idx, measure_fn, ctx);

                        // Check if newline follows (force break)
                        var force_break = (c == '\n');
                        if (!force_break) {
                            // Look ahead for newline
                            var look_span = span_idx;
                            var look_byte = byte_idx + 1;
                            outer: while (look_span < self.spans.items.len) {
                                const ls = self.spans.items[look_span];
                                while (look_byte < ls.text.len) {
                                    const lc = ls.text[look_byte];
                                    if (lc == '\n') {
                                        force_break = true;
                                        break :outer;
                                    } else if (lc != ' ' and lc != '\t') {
                                        break :outer;
                                    }
                                    look_byte += 1;
                                }
                                look_span += 1;
                                look_byte = 0;
                            }
                        }

                        // Store word
                        try self.words.append(self.allocator, .{
                            .start_span = word_start_span,
                            .start_offset = word_start_offset,
                            .end_span = span_idx,
                            .end_offset = byte_idx,
                            .width = word_width,
                            .force_break = force_break,
                        });

                        in_word = false;
                        word_width = 0;
                    }
                } else {
                    if (!in_word) {
                        // Start of new word
                        word_start_span = span_idx;
                        word_start_offset = byte_idx;
                        in_word = true;
                    }
                }

                byte_idx += 1;
            }

            // Move to next span
            span_idx += 1;
            byte_idx = 0;
        }

        // Handle final word if text doesn't end with whitespace
        if (in_word) {
            const last_span_idx = @as(u16, @intCast(self.spans.items.len - 1));
            const last_span = self.spans.items[last_span_idx];
            word_width = self.measureWord(word_start_span, word_start_offset, last_span_idx, @intCast(last_span.text.len), measure_fn, ctx);

            try self.words.append(self.allocator, .{
                .start_span = word_start_span,
                .start_offset = word_start_offset,
                .end_span = last_span_idx,
                .end_offset = @intCast(last_span.text.len),
                .width = word_width,
                .force_break = false,
            });
        }

        self.prepared = true;
    }

    /// Measure the width of a word spanning from (start_span, start_offset) to (end_span, end_offset).
    fn measureWord(
        self: *const StyledText,
        start_span: u16,
        start_offset: u16,
        end_span: u16,
        end_offset: u16,
        measure_fn: MeasureFn,
        ctx: *anyopaque,
    ) f64 {
        var width: f64 = 0;

        var s = start_span;
        while (s <= end_span) : (s += 1) {
            const span = self.spans.items[s];
            const seg_start: usize = if (s == start_span) start_offset else 0;
            const seg_end: usize = if (s == end_span) end_offset else span.text.len;

            if (seg_end > seg_start) {
                const segment = span.text[seg_start..seg_end];
                width += measure_fn(segment, span.style, ctx);
            }
        }

        return width;
    }

    /// Reset preparation state (call after modifying spans).
    pub fn invalidate(self: *StyledText) void {
        self.prepared = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

fn testMeasure(text: []const u8, _: TextStyleOptions, _: *anyopaque) f64 {
    // Simple test: 10 points per character
    return @floatFromInt(text.len * 10);
}

test "StyledText basic append" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    try st.append("Hello ", .{});
    try st.append("world", .{ .color = Color.red });

    try std.testing.expectEqual(@as(usize, 2), st.spans.items.len);
    try std.testing.expectEqualStrings("Hello ", st.spans.items[0].text);
    try std.testing.expectEqualStrings("world", st.spans.items[1].text);
    try std.testing.expectEqual(@as(usize, 11), st.totalLength());
}

test "StyledText prepare identifies words" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    try st.append("Hello world", .{});

    var dummy: u8 = 0;
    try st.prepare(testMeasure, @ptrCast(&dummy));

    try std.testing.expectEqual(@as(usize, 2), st.words.items.len);
    try std.testing.expectEqual(@as(f64, 50), st.words.items[0].width); // "Hello" = 5 chars
    try std.testing.expectEqual(@as(f64, 50), st.words.items[1].width); // "world" = 5 chars
}

test "StyledText word spanning multiple spans" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    // "Hello" in normal, "World" in red, no space between
    try st.append("Hello", .{});
    try st.append("World ", .{ .color = Color.red });
    try st.append("test", .{});

    var dummy: u8 = 0;
    try st.prepare(testMeasure, @ptrCast(&dummy));

    // Should be 2 words: "HelloWorld" and "test"
    try std.testing.expectEqual(@as(usize, 2), st.words.items.len);
    try std.testing.expectEqual(@as(f64, 100), st.words.items[0].width); // "HelloWorld" = 10 chars
    try std.testing.expectEqual(@as(f64, 40), st.words.items[1].width); // "test" = 4 chars
}

test "StyledText force break on newline" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    try st.append("Line one\nLine two", .{});

    var dummy: u8 = 0;
    try st.prepare(testMeasure, @ptrCast(&dummy));

    try std.testing.expectEqual(@as(usize, 4), st.words.items.len);
    try std.testing.expect(st.words.items[1].force_break); // "one" has force_break
    try std.testing.expect(!st.words.items[3].force_break); // "two" doesn't
}

test "StyledText appendOwned copies text" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    {
        var buf: [10]u8 = "temporary!".*;
        try st.appendOwned(&buf, .{});
        // Modify original - should not affect StyledText
        buf[0] = 'X';
    }

    try std.testing.expectEqualStrings("temporary!", st.spans.items[0].text);
}
