//! Page and content writer types for platen.
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
const PageRotation = layout.PageRotation;
pub const Rect = layout.Rect;
pub const Destination = layout.Destination;
pub const OpacityState = layout.OpacityState;
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
    /// Fill (non-stroking) opacity: 1.0 = opaque. Applies to glyphs and decorations.
    opacity: f64 = 1.0,
    /// Cached glyph IDs for CID fonts (avoids duplicate OpenType shaping)
    cached_glyphs: ?[]const u16 = null,
    /// Placement of each of `cached_glyphs` (EmbeddedFont.shapeRun): the
    /// renderer advances by these instead of the glyphs' widths.
    cached_positions: ?[]const EmbeddedFont.GlyphPos = null,
    /// Text width (for decoration drawing)
    text_width: f64 = 0,
    /// Draw underline
    underline: bool = false,
    /// Draw strikethrough
    strikethrough: bool = false,
    /// Glyphs start this far right of x; decorations still start at x (a
    /// `.monospace` fallback glyph centered in its cell).
    glyph_dx: f64 = 0,
    /// Glyphs are drawn at font_size * glyph_scale (a `.monospace` fallback
    /// glyph shrunk to its cell); decorations keep font_size.
    glyph_scale: f64 = 1,
    /// Synthesized bold: the outline is stroked too (fallback.embolden_per_em).
    synth_bold: bool = false,
    /// Synthesized italic: the text matrix is slanted (fallback.oblique_shear).
    synth_italic: bool = false,
    /// Decoration metrics come from this font rather than `font`, so a
    /// fallback run is underlined like the text around it.
    decoration_font: ?*EmbeddedFont = null,
    /// Shaped glyphs placed one by one (a `.monospace` fallback cluster):
    /// each glyph's offset in points from (x + glyph_dx, y), y up. The
    /// renderer then draws these instead of shaping `text_data`.
    placed: ?[]const PlacedOffset = null,
    /// Begins a marked-content span with this /ActualText before the
    /// command (consecutive `.monospace` fallback clusters: text
    /// extraction takes their text whole, where the gaps around glyphs
    /// centered in their cells read as word breaks)
    actual_text: ?[]const u8 = null,
    /// Ends the span an earlier command's `actual_text` began, after this one
    actual_text_end: bool = false,
};

/// A glyph of a TextCommand's `placed` run.
pub const PlacedOffset = struct { id: u16, dx: f64, dy: f64 };

/// Glyphs drawn by ID at absolute positions (Document.drawGlyphs).
pub const GlyphsCommand = struct {
    font: *EmbeddedFont,
    font_size: f64,
    /// Glyph IDs (unremapped) and their origins in PDF coordinates
    /// (bottom-left origin); owned by the page arena.
    ids: []const u16,
    xs: []const f64,
    ys: []const f64,
    text_color: Color,
    opacity: f64 = 1.0,
};

/// Content command for deferred rendering (enables glyph ID remapping)
pub const ContentCommand = union(enum) {
    /// Text command with all rendering parameters
    text: TextCommand,
    /// Glyphs by ID
    glyphs: GlyphsCommand,
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
    opacity_states: std.ArrayListUnmanaged(OpacityState), // ExtGState opacity values
    annotations: std.ArrayListUnmanaged(LinkAnnotation), // Link annotations
    size: PageSize, // Page dimensions
    margins: Margins, // Page margins
    rotation: PageRotation, // Viewer rotation (/Rotate)
    state_depth: usize = 0, // pushState/popState balance (must be 0 at output)

    // Arena allocator for page-local allocations (text_data, cached_glyphs, etc.)
    // All page allocations freed at once in deinit - no individual free() calls
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator, opts: PageOptions) Page {
        return .{
            .content = .empty,
            .commands = .empty,
            .used_fonts = .empty,
            .used_embedded = .empty,
            .used_images = .empty,
            .used_svgs = .empty,
            .used_gradients = .empty,
            .opacity_states = .empty,
            .annotations = .empty,
            .size = opts.size,
            .rotation = opts.rotation,
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
        self.opacity_states.deinit(backing_allocator);
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

    /// Get or add an opacity state, returning its index.
    /// If the state already exists, returns the existing index.
    /// Returns null if the state is fully opaque (no ExtGState needed).
    pub fn getOrAddOpacityState(self: *Page, allocator: std.mem.Allocator, fill_op: f64, stroke_op: f64) !?usize {
        const state = OpacityState{ .fill_opacity = fill_op, .stroke_opacity = stroke_op };
        // No ExtGState needed for fully opaque
        if (state.isOpaque()) return null;
        // Check for existing state
        for (self.opacity_states.items, 0..) |s, i| {
            if (s.eql(state)) return i;
        }
        // Add new state
        try self.opacity_states.append(allocator, state);
        return self.opacity_states.items.len - 1;
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

    /// Write "1 0 0 1 x y Tm " with 3 decimals (glyphs placed by ID keep
    /// their position to a thousandth of a point).
    pub fn writeTm3(self: *ContentWriter, x: f64, y: f64) !void {
        var buf: [80]u8 = undefined;
        @memcpy(buf[0..8], "1 0 0 1 ");
        var len: usize = 8;
        len += format.writeF64_3(buf[len..], x).len;
        buf[len] = ' ';
        len += 1;
        len += format.writeF64_3(buf[len..], y).len;
        @memcpy(buf[len..][0..4], " Tm ");
        len += 4;
        try self.append(buf[0..len]);
    }

    /// Write "1 0 shear 1 x y Tm ": the text matrix with a horizontal shear
    /// (slanted text), or writeTm's plain matrix when shear is 0.
    pub fn writeTmShear(self: *ContentWriter, x: f64, y: f64, shear: f64) !void {
        if (shear == 0) return self.writeTm(x, y);
        var buf: [96]u8 = undefined;
        @memcpy(buf[0..4], "1 0 ");
        var len: usize = 4;
        len += format.writeF64_3(buf[len..], shear).len;
        @memcpy(buf[len..][0..3], " 1 ");
        len += 3;
        len += format.writeCoord2Suffix(buf[len..], x, y, " Tm ");
        try self.append(buf[0..len]);
    }

    /// Write "> N <" for TJ kerning adjustment (fast integer formatting)
    pub fn writeKernAdjust(self: *ContentWriter, kern: i32) !void {
        var buf: [24]u8 = undefined;
        buf[0] = '>';
        buf[1] = ' ';
        var len: usize = 2;
        const int_str = format.writeInt(buf[len..], kern);
        len += int_str.len;
        @memcpy(buf[len..][0..2], " <");
        len += 2;
        try self.append(buf[0..len]);
    }
};
