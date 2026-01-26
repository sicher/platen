//! Page and content writer types for zpdf.
//!
//! This module contains the internal page representation and content stream writer.

const std = @import("std");
const fonts = @import("fonts.zig");
const embedded = @import("embedded.zig");
const images = @import("images.zig");
const svg = @import("svg.zig");
const layout = @import("layout.zig");
const color = @import("color.zig");
const format = @import("format.zig");

pub const StandardFont = fonts.StandardFont;
pub const EmbeddedFont = embedded.EmbeddedFont;
pub const Image = images.Image;
pub const Svg = svg.Svg;
pub const PageSize = layout.PageSize;
pub const Margins = layout.Margins;
pub const PageOptions = layout.PageOptions;
pub const Rect = layout.Rect;
pub const Destination = layout.Destination;
pub const Color = color.Color;

/// Font reference for deferred text commands
pub const FontRef = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,
};

/// Text command parameters for deferred rendering
pub const TextCommand = struct {
    x: f64,
    y: f64,
    font_size: f64,
    char_spacing: f64,
    word_spacing: f64, // Extra space added between words for justification
    text_data: []const u8, // Owned copy of text
    font: FontRef,
    /// Text color
    text_color: Color,
    /// Cached glyph IDs for CID fonts (avoids duplicate OpenType shaping)
    cached_glyphs: ?[]const u16 = null,
    /// Text width (for decoration drawing)
    text_width: f64 = 0,
    /// Draw underline
    underline: bool = false,
    /// Draw strikethrough
    strikethrough: bool = false,
};

/// Content command for deferred rendering (enables glyph ID remapping)
pub const ContentCommand = union(enum) {
    /// Text command with all rendering parameters
    text: TextCommand,
    /// Raw content (for non-text operations that don't need deferred processing)
    raw: []const u8, // Owned copy
};

/// Link annotation for internal or external links
pub const LinkAnnotation = union(enum) {
    /// Internal link to page position
    internal: struct {
        rect: Rect,
        dest: Destination,
    },
    /// External link to URL
    external: struct {
        rect: Rect,
        url: []const u8, // Owned by page arena
    },
};

/// Internal page representation
pub const Page = struct {
    content: std.ArrayListUnmanaged(u8), // Legacy: direct content bytes
    commands: std.ArrayListUnmanaged(ContentCommand), // Deferred commands
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void),
    used_embedded: std.ArrayListUnmanaged(*EmbeddedFont),
    used_images: std.ArrayListUnmanaged(*Image),
    used_svgs: std.ArrayListUnmanaged(*Svg),
    used_gradients: std.AutoHashMapUnmanaged(usize, void),
    annotations: std.ArrayListUnmanaged(LinkAnnotation), // Link annotations
    size: PageSize, // Page dimensions
    margins: Margins, // Page margins

    // Arena allocator for page-local allocations (text_data, cached_glyphs, etc.)
    // All page allocations freed at once in deinit - no individual free() calls
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator, opts: PageOptions) Page {
        return .{
            .content = .{},
            .commands = .{},
            .used_fonts = .{},
            .used_embedded = .{},
            .used_images = .{},
            .used_svgs = .{},
            .used_gradients = .{},
            .annotations = .{},
            .size = opts.size,
            .margins = opts.margins,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    /// Get the arena allocator for page-local allocations
    pub fn pageAllocator(self: *Page) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Page, backing_allocator: std.mem.Allocator) void {
        // Arena frees all text_data, cached_glyphs, etc. in one operation
        self.arena.deinit();

        // These use the backing allocator, not the arena
        self.commands.deinit(backing_allocator);
        self.content.deinit(backing_allocator);
        self.used_fonts.deinit(backing_allocator);
        self.used_embedded.deinit(backing_allocator);
        self.used_images.deinit(backing_allocator);
        self.used_svgs.deinit(backing_allocator);
        self.used_gradients.deinit(backing_allocator);
        self.annotations.deinit(backing_allocator);
    }

    pub fn markFontUsed(self: *Page, allocator: std.mem.Allocator, font: StandardFont) !void {
        try self.used_fonts.put(allocator, font, {});
    }

    pub fn markEmbeddedUsed(self: *Page, allocator: std.mem.Allocator, font: *EmbeddedFont) !void {
        // Check if already in list
        for (self.used_embedded.items) |f| {
            if (f == font) return;
        }
        try self.used_embedded.append(allocator, font);
    }

    pub fn markImageUsed(self: *Page, allocator: std.mem.Allocator, image: *Image) !void {
        // Check if already in list
        for (self.used_images.items) |img| {
            if (img == image) return;
        }
        try self.used_images.append(allocator, image);
    }

    pub fn markSvgUsed(self: *Page, allocator: std.mem.Allocator, s: *Svg) !void {
        // Check if already in list
        for (self.used_svgs.items) |existing| {
            if (existing == s) return;
        }
        try self.used_svgs.append(allocator, s);
    }

    pub fn writer(self: *Page, allocator: std.mem.Allocator) ContentWriter {
        return ContentWriter{ .page = self, .allocator = allocator };
    }
};

/// Writer for page content stream
pub const ContentWriter = struct {
    page: *Page,
    allocator: std.mem.Allocator,

    pub fn append(self: *ContentWriter, data: []const u8) !void {
        try self.page.content.appendSlice(self.allocator, data);
    }

    pub fn print(self: *ContentWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
            // Buffer too small, allocate
            const str = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(str);
            try self.append(str);
            return;
        };
        try self.append(slice);
    }

    /// Append a string with PDF string escaping (for literal strings)
    /// Escapes (, ), and \ characters
    pub fn appendEscaped(self: *ContentWriter, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '\\' => try self.page.content.appendSlice(self.allocator, "\\\\"),
                '(' => try self.page.content.appendSlice(self.allocator, "\\("),
                ')' => try self.page.content.appendSlice(self.allocator, "\\)"),
                else => try self.page.content.append(self.allocator, c),
            }
        }
    }

    /// Return std.io.Writer interface for this ContentWriter
    pub fn writer(self: *ContentWriter) std.io.GenericWriter(*ContentWriter, error{OutOfMemory}, writeBytes) {
        return .{ .context = self };
    }

    fn writeBytes(self: *ContentWriter, bytes: []const u8) error{OutOfMemory}!usize {
        self.page.content.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
        return bytes.len;
    }

    // ========================================================================
    // Fast formatting methods - bypass std.fmt for common patterns
    // ========================================================================

    /// Write "x y Td\n" with fast formatting (text position)
    pub fn writeTd(self: *ContentWriter, x: f64, y: f64) !void {
        var buf: [64]u8 = undefined;
        const len = format.writeCoord2Suffix(&buf, x, y, " Td\n");
        try self.append(buf[0..len]);
    }

    /// Write "1 0 0 1 x y Tm " with fast formatting (absolute text position matrix)
    pub fn writeTm(self: *ContentWriter, x: f64, y: f64) !void {
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..8], "1 0 0 1 ");
        const len = 8 + format.writeCoord2Suffix(buf[8..], x, y, " Tm ");
        try self.append(buf[0..len]);
    }

    /// Write "x y l\n" with fast formatting (line to)
    pub fn writeLineTo(self: *ContentWriter, x: f64, y: f64) !void {
        var buf: [64]u8 = undefined;
        const len = format.writeCoord2Suffix(&buf, x, y, " l\n");
        try self.append(buf[0..len]);
    }

    /// Write "x y m\n" with fast formatting (move to)
    pub fn writeMoveTo(self: *ContentWriter, x: f64, y: f64) !void {
        var buf: [64]u8 = undefined;
        const len = format.writeCoord2Suffix(&buf, x, y, " m\n");
        try self.append(buf[0..len]);
    }

    /// Write "x y w h re" with fast formatting (rectangle)
    pub fn writeRect(self: *ContentWriter, x: f64, y: f64, w: f64, h: f64, suffix: []const u8) !void {
        var buf: [128]u8 = undefined;
        var len = format.writeCoord2(&buf, x, y);
        buf[len] = ' ';
        len += 1;
        len += format.writeCoord2Suffix(buf[len..], w, h, " re ");
        @memcpy(buf[len..][0..suffix.len], suffix);
        len += suffix.len;
        try self.append(buf[0..len]);
    }
};
