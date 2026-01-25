//! StyledText API for building styled paragraphs.
//!
//! Provides a builder pattern for constructing text with inline style changes.
//! Supports preprocessing for efficient Knuth-Plass optimal line breaking.

const std = @import("std");
const layout = @import("layout.zig");

pub const Color = layout.Color;
pub const TextDecoration = layout.TextDecoration;
pub const TextStyleOptions = layout.TextStyleOptions;

// ============================================================================
// Soft-Hyphen Utilities
// ============================================================================

/// Check if a soft-hyphen (U+00AD, 0xC2 0xAD in UTF-8) starts at position i.
pub inline fn isSoftHyphenAt(str: []const u8, i: usize) bool {
    return i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD;
}

/// Check if text contains any soft-hyphens.
pub fn containsSoftHyphens(str: []const u8) bool {
    return std.mem.indexOf(u8, str, "\xC2\xAD") != null;
}

/// Strip soft-hyphens (U+00AD) from text.
/// Soft-hyphens are invisible formatting characters that only appear as visible
/// hyphens when text breaks at that point. Returns allocated copy without soft-hyphens.
pub fn stripSoftHyphens(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    // Fast path: check if any soft-hyphens exist
    if (!containsSoftHyphens(str)) {
        return allocator.dupe(u8, str);
    }

    // Slow path: count non-soft-hyphen bytes
    var count: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (isSoftHyphenAt(str, i)) {
            i += 2; // Skip soft-hyphen
        } else {
            count += 1;
            i += 1;
        }
    }

    // Copy without soft-hyphens
    const result = try allocator.alloc(u8, count);
    var j: usize = 0;
    i = 0;
    while (i < str.len) {
        if (isSoftHyphenAt(str, i)) {
            i += 2; // Skip soft-hyphen
        } else {
            result[j] = str[i];
            j += 1;
            i += 1;
        }
    }
    return result;
}

/// Strip soft-hyphens to a provided buffer. Returns slice of buffer used.
pub fn stripSoftHyphensTo(str: []const u8, buf: []u8) []const u8 {
    // Fast path: no soft-hyphens
    if (!containsSoftHyphens(str)) {
        const len = @min(str.len, buf.len);
        @memcpy(buf[0..len], str[0..len]);
        return buf[0..len];
    }

    // Strip soft-hyphens
    var j: usize = 0;
    var i: usize = 0;
    while (i < str.len and j < buf.len) {
        if (isSoftHyphenAt(str, i)) {
            i += 2; // Skip soft-hyphen
        } else {
            buf[j] = str[i];
            j += 1;
            i += 1;
        }
    }
    return buf[0..j];
}

/// A span of text with uniform styling.
pub const Span = struct {
    text: []const u8,
    style: TextStyleOptions = .{},
};

/// A potential break point within a word (soft-hyphen location).
pub const BreakPoint = struct {
    /// Byte offset within word where soft-hyphen is located.
    offset: u16,
    /// Width of text up to this point (not including the hyphen that would be added).
    width: f64,
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
    /// Optional break points within word (soft-hyphen locations).
    /// null for most words. When breaking, a visible hyphen is added.
    break_points: ?[]const BreakPoint = null,
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
    /// Storage for break point arrays (freed in deinit).
    break_point_storage: std.ArrayListUnmanaged([]const BreakPoint) = .{},
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
        // Free break point arrays
        for (self.break_point_storage.items) |bp_array| {
            self.allocator.free(bp_array);
        }
        self.break_point_storage.deinit(self.allocator);
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

        // Estimate word count and pre-allocate (assume ~6 chars per word on average)
        var total_len: usize = 0;
        for (self.spans.items) |span| {
            total_len += span.text.len;
        }
        const estimated_words = (total_len / 6) + 1;
        try self.words.ensureTotalCapacity(self.allocator, estimated_words);

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
                        const force_break = if (c == '\n')
                            true
                        else
                            self.checkNewlineAhead(span_idx, byte_idx + 1);

                        // Store word
                        try self.words.append(self.allocator, .{
                            .start_span = word_start_span,
                            .start_offset = word_start_offset,
                            .end_span = span_idx,
                            .end_offset = byte_idx,
                            .width = word_width,
                            .force_break = force_break,
                        });

                        // Check for soft-hyphens and add break points (only for single-span words)
                        if (word_start_span == span_idx) {
                            if (try self.findSoftHyphenBreaks(word_start_span, word_start_offset, span_idx, byte_idx, measure_fn, ctx)) |bp| {
                                self.words.items[self.words.items.len - 1].break_points = bp;
                            }
                        }

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

            const end_offset: u16 = @intCast(last_span.text.len);
            try self.words.append(self.allocator, .{
                .start_span = word_start_span,
                .start_offset = word_start_offset,
                .end_span = last_span_idx,
                .end_offset = end_offset,
                .width = word_width,
                .force_break = false,
            });

            // Check for soft-hyphens and add break points (only for single-span words)
            if (word_start_span == last_span_idx) {
                if (try self.findSoftHyphenBreaks(word_start_span, word_start_offset, last_span_idx, end_offset, measure_fn, ctx)) |bp| {
                    self.words.items[self.words.items.len - 1].break_points = bp;
                }
            }
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

    /// Check if a newline follows before the next word (skipping spaces/tabs).
    fn checkNewlineAhead(self: *const StyledText, start_span: u16, start_byte: u16) bool {
        var look_span = start_span;
        var look_byte: usize = start_byte;

        while (look_span < self.spans.items.len) {
            const ls = self.spans.items[look_span];
            while (look_byte < ls.text.len) {
                const lc = ls.text[look_byte];
                if (lc == '\n') return true;
                if (lc != ' ' and lc != '\t') return false;
                look_byte += 1;
            }
            look_span += 1;
            look_byte = 0;
        }
        return false;
    }

    /// Find soft-hyphens in a word and create break points.
    /// Only handles single-span words for now; returns null for multi-span words.
    fn findSoftHyphenBreaks(
        self: *StyledText,
        start_span: u16,
        start_offset: u16,
        end_span: u16,
        end_offset: u16,
        measure_fn: MeasureFn,
        ctx: *anyopaque,
    ) !?[]const BreakPoint {
        // Only handle single-span words for now
        if (start_span != end_span) return null;

        const span = self.spans.items[start_span];
        const word_text = span.text[start_offset..end_offset];

        // Fast path: check if soft-hyphen exists at all (0xC2 0xAD in UTF-8)
        if (std.mem.indexOf(u8, word_text, "\xC2\xAD") == null) return null;

        // Count soft-hyphens (UTF-8: 0xC2 0xAD)
        var count: usize = 0;
        var i: usize = 0;
        while (i < word_text.len) {
            if (isSoftHyphenAt(word_text, i)) {
                count += 1;
                i += 2;
            } else {
                i += 1;
            }
        }

        if (count == 0) return null; // Shouldn't happen after indexOf check, but defensive

        // Allocate break points
        const break_points = try self.allocator.alloc(BreakPoint, count);
        errdefer self.allocator.free(break_points);

        // Fill in break points with positions and widths
        var bp_idx: usize = 0;
        i = 0;
        while (i < word_text.len) {
            if (isSoftHyphenAt(word_text, i)) {
                // Measure width up to this point (excluding soft-hyphen bytes)
                // We need to measure the text with soft-hyphens removed
                const prefix = word_text[0..i];
                const width = self.measureTextWithoutSoftHyphens(prefix, span.style, measure_fn, ctx);

                break_points[bp_idx] = .{
                    .offset = @intCast(start_offset + i),
                    .width = width,
                };
                bp_idx += 1;
                i += 2;
            } else {
                i += 1;
            }
        }

        // Store in break_point_storage for cleanup
        try self.break_point_storage.append(self.allocator, break_points);

        return break_points;
    }

    /// Measure text width, stripping soft-hyphens.
    fn measureTextWithoutSoftHyphens(
        self: *const StyledText,
        text: []const u8,
        style: TextStyleOptions,
        measure_fn: MeasureFn,
        ctx: *anyopaque,
    ) f64 {
        _ = self;
        // Check if text contains soft-hyphens
        var has_soft_hyphen = false;
        for (0..text.len) |i| {
            if (isSoftHyphenAt(text, i)) {
                has_soft_hyphen = true;
                break;
            }
        }

        if (!has_soft_hyphen) {
            return measure_fn(text, style, ctx);
        }

        // Strip soft-hyphens using stack buffer
        var buf: [1024]u8 = undefined;
        var buf_len: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (isSoftHyphenAt(text, i)) {
                i += 2; // Skip soft-hyphen
            } else {
                if (buf_len < buf.len) {
                    buf[buf_len] = text[i];
                    buf_len += 1;
                }
                i += 1;
            }
        }

        return measure_fn(buf[0..buf_len], style, ctx);
    }

    /// Reset preparation state (call after modifying spans).
    pub fn invalidate(self: *StyledText) void {
        self.prepared = false;
        // Clear break points when invalidating
        for (self.break_point_storage.items) |bp_array| {
            self.allocator.free(bp_array);
        }
        self.break_point_storage.clearRetainingCapacity();
    }

    /// Get the remaining text starting from a word index.
    /// Returns null if word_idx is out of bounds.
    pub fn getTextFromWord(self: *const StyledText, word_idx: usize) ?[]const u8 {
        if (word_idx >= self.words.items.len) return null;
        const word = self.words.items[word_idx];
        const span = self.spans.items[word.start_span];
        return span.text[word.start_offset..];
    }

    /// Compute optimal line breaks using Knuth-Plass algorithm.
    /// Returns array of word indices where lines end (caller owns the slice).
    pub fn computeOptimalBreaks(self: *const StyledText, line_width: f64, space_width: f64) ![]usize {
        const n = self.words.items.len;
        if (n == 0) return self.allocator.alloc(usize, 0);

        const INFINITY: f64 = 1e18;

        var dp = try self.allocator.alloc(f64, n + 1);
        defer self.allocator.free(dp);
        var prev = try self.allocator.alloc(usize, n + 1);
        defer self.allocator.free(prev);

        dp[0] = 0;
        prev[0] = 0;

        // For each ending position
        for (1..n + 1) |j| {
            dp[j] = INFINITY;
            prev[j] = 0;

            // Try each starting position
            var line_w: f64 = 0;
            var start_i = j;
            while (start_i > 0) {
                start_i -= 1;
                const word = self.words.items[start_i];

                // Check force break constraint
                if (word.force_break and start_i + 1 < j) break;

                // Add word width
                if (start_i + 1 < j) line_w += space_width;
                line_w += word.width;

                // Line too wide
                if (line_w > line_width + 0.01) break;

                // Compute badness
                const slack = line_width - line_w;
                const is_last_line = (j == n);
                const is_forced = self.words.items[j - 1].force_break;
                const badness = if (is_last_line or is_forced) 0.0 else slack * slack;

                const total = dp[start_i] + badness;
                if (total < dp[j]) {
                    dp[j] = total;
                    prev[j] = start_i;
                }
            }
        }

        // Backtrack
        var breaks = std.ArrayListUnmanaged(usize){};
        errdefer breaks.deinit(self.allocator);

        var pos = n;
        while (pos > 0) {
            try breaks.append(self.allocator, pos);
            pos = prev[pos];
        }

        std.mem.reverse(usize, breaks.items);
        return breaks.toOwnedSlice(self.allocator);
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

test "StyledText detects soft-hyphens during prepare" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    // Word with soft-hyphens: "in­com­pre­hen­si­ble" (U+00AD = 0xC2 0xAD in UTF-8)
    try st.append("in\xC2\xADcom\xC2\xADpre\xC2\xADhen\xC2\xADsi\xC2\xADble", .{});

    try st.prepare(testMeasure, @constCast(@ptrCast(&@as(u8, 0))));

    // Should have one word
    try std.testing.expectEqual(@as(usize, 1), st.words.items.len);

    // Word should have 5 break points (one for each soft-hyphen)
    const word = st.words.items[0];
    try std.testing.expect(word.break_points != null);
    try std.testing.expectEqual(@as(usize, 5), word.break_points.?.len);

    // Break points should be at increasing offsets
    const bps = word.break_points.?;
    try std.testing.expect(bps[0].offset < bps[1].offset);
    try std.testing.expect(bps[1].offset < bps[2].offset);
    try std.testing.expect(bps[2].offset < bps[3].offset);
    try std.testing.expect(bps[3].offset < bps[4].offset);
}

test "StyledText word without soft-hyphens has no break points" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    try st.append("hello world", .{});
    try st.prepare(testMeasure, @constCast(@ptrCast(&@as(u8, 0))));

    // Should have two words
    try std.testing.expectEqual(@as(usize, 2), st.words.items.len);

    // Neither word should have break points
    try std.testing.expect(st.words.items[0].break_points == null);
    try std.testing.expect(st.words.items[1].break_points == null);
}

test "StyledText break point widths are measured correctly" {
    const allocator = std.testing.allocator;
    var st = StyledText.init(allocator);
    defer st.deinit();

    // "ab­cd" - soft-hyphen after "ab"
    try st.append("ab\xC2\xADcd", .{});
    try st.prepare(testMeasure, @constCast(@ptrCast(&@as(u8, 0))));

    try std.testing.expectEqual(@as(usize, 1), st.words.items.len);

    const word = st.words.items[0];
    try std.testing.expect(word.break_points != null);
    try std.testing.expectEqual(@as(usize, 1), word.break_points.?.len);

    // Width at break point should be width of "ab" (2 chars * 10 = 20)
    const bp = word.break_points.?[0];
    try std.testing.expectEqual(@as(f64, 20.0), bp.width);
}
