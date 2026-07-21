//! Document struct for platen - PDF document creation and management.
//!
//! This module contains the core Document type that handles page management,
//! text rendering, font handling, and PDF output generation.

const std = @import("std");
const version = @import("version.zig");

// Module imports
pub const objects = @import("objects.zig");
pub const fonts = @import("fonts.zig");
pub const metrics = @import("metrics.zig");
pub const ttf = @import("ttf.zig");
pub const embedded = @import("embedded.zig");
pub const color = @import("color.zig");
pub const layout = @import("layout.zig");
pub const Writer = @import("writer.zig").Writer;
pub const zlib = @import("zlib.zig");
pub const images = @import("images.zig");
pub const svg = @import("svg.zig");
pub const pathmod = @import("path.zig");
pub const gradient = @import("gradient.zig");
pub const styled_text = @import("styled_text.zig");
pub const graphics = @import("graphics.zig");
pub const outlinemod = @import("outline.zig");
pub const pdf_output = @import("pdf_output.zig");
pub const pagemod = @import("page.zig");
pub const text_render = @import("text_render.zig");
pub const format = @import("format.zig");
pub const pdfa = @import("pdfa.zig");
const color_fonts = @import("color_fonts.zig");
pub const colr = @import("colr.zig");

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

// Type aliases
pub const StandardFont = fonts.StandardFont;

pub const Font = layout.Font;
pub const FontEncoding = layout.FontEncoding;
pub const EmbeddedFontFamily = layout.EmbeddedFontFamily;
pub const TextStyle = layout.TextStyle;
pub const TextMetrics = metrics.TextMetrics;
pub const FontStyle = metrics.FontStyle;
pub const FontMetrics = metrics.FontMetrics;
pub const EmbeddedFont = embedded.EmbeddedFont;
pub const Color = color.Color;
pub const Image = images.Image;
pub const Svg = svg.Svg;
pub const Path = pathmod.Path;
pub const StyledText = styled_text.StyledText;
pub const Span = styled_text.Span;
pub const BreakPoint = styled_text.BreakPoint;
pub const LinearGradient = gradient.LinearGradient;
pub const RadialGradient = gradient.RadialGradient;
pub const ColorStop = gradient.ColorStop;

// Layout types
pub const Border = layout.Border;
pub const Align = layout.Align;
pub const VAlign = layout.VAlign;
pub const LineBreaking = layout.LineBreaking;
pub const TextDecoration = layout.TextDecoration;
pub const TextStyleOptions = layout.TextStyleOptions;
pub const Margins = layout.Margins;
pub const Padding = layout.Padding;
pub const Point = layout.Point;
pub const Rect = layout.Rect;
pub const Region = layout.Region;
pub const Destination = layout.Destination;
pub const Outline = outlinemod.Outline;
pub const OutlineItem = outlinemod.OutlineItem;
pub const PageLabelStyle = layout.PageLabelStyle;
pub const PageLabel = layout.PageLabel;
pub const WriteResult = layout.WriteResult;
pub const WriteOptions = layout.WriteOptions;
pub const WriteAtOptions = layout.WriteAtOptions;
pub const Anchor = layout.Anchor;
pub const BlockOptions = layout.BlockOptions;
pub const ParagraphOptions = layout.ParagraphOptions;
pub const PageSize = layout.PageSize;
pub const PageOptions = layout.PageOptions;
pub const PageRotation = layout.PageRotation;

// Graphics types
pub const LineCap = layout.LineCap;
pub const LineJoin = layout.LineJoin;
pub const DashPattern = layout.DashPattern;
pub const StrokeStyle = layout.StrokeStyle;
pub const FillStyle = layout.FillStyle;
pub const ShapeStyle = layout.ShapeStyle;

pub const opentype = embedded.opentype;

// ============================================================================
// Document Metadata
// ============================================================================

/// PDF document metadata (Info dictionary fields).
/// All fields are optional - only non-null values are written to the PDF.
pub const DocumentMetadata = struct {
    /// Document title.
    title: ?[]const u8 = null,
    /// Document author.
    author: ?[]const u8 = null,
    /// Subject/description of the document.
    subject: ?[]const u8 = null,
    /// Keywords associated with the document (comma-separated).
    keywords: ?[]const u8 = null,
    /// Application that created the original document content.
    creator: ?[]const u8 = null,
    /// Application that produced the PDF (defaults to "platen <version>").
    producer: ?[]const u8 = version.full,
    /// Creation date in PDF format (D:YYYYMMDDHHmmSS).
    /// If null, current time is used automatically.
    creation_date: ?[]const u8 = null,
    /// Modification date in PDF format (D:YYYYMMDDHHmmSS).
    /// If null, same as creation_date.
    mod_date: ?[]const u8 = null,

    /// Check if any metadata field is set.
    pub fn hasAnyField(self: DocumentMetadata) bool {
        return self.title != null or
            self.author != null or
            self.subject != null or
            self.keywords != null or
            self.creator != null or
            self.producer != null or
            self.creation_date != null or
            self.mod_date != null;
    }
};

// ============================================================================
// Internal Types
// ============================================================================

// Hex conversion is in text_render.zig
const writeHex4 = text_render.writeHex4;

/// Handle to a loaded font (either standard or embedded)
pub const FontFace = embedded.FontFace;
pub const FontFamily = layout.FontFamily;
pub const StandardFamilyName = layout.StandardFamilyName;
pub const FontHandle = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,

    pub fn name(self: FontHandle) []const u8 {
        return switch (self) {
            .standard => |f| f.pdfName(),
            .embedded => |e| e.name,
        };
    }
};

/// Entry in the page labels number tree
const PageLabelEntry = struct {
    page_index: usize,
    label: PageLabel,
};

// Page types are in page.zig
const Page = pagemod.Page;
const ContentWriter = pagemod.ContentWriter;
const FontRef = pagemod.FontRef;
const TextCommand = pagemod.TextCommand;
const ContentCommand = pagemod.ContentCommand;
const LinkAnnotation = pagemod.LinkAnnotation;

/// Compute baseline y position for a given VAlign mode.
fn valignBaseline(region: *Region, line_height: f64, fm: metrics.FontMetrics, valign: VAlign) f64 {
    const base = region.y + region.padding.top + region.cursor_y;
    return switch (valign) {
        .top => base + fm.cap_height,
        .top_ascent => base + fm.ascender,
        .top_leading => base + (line_height + fm.ascender - @abs(fm.descender)) / 2,
        .middle => base + line_height / 2 + fm.ascender / 2,
        .bottom => base + line_height,
    };
}

// Resource naming functions are in pdf_output.zig
const fontResourceName = pdf_output.fontResourceName;
const embeddedFontResourceName = pdf_output.embeddedFontResourceName;
const imageResourceName = pdf_output.imageResourceName;
const svgResourceName = pdf_output.svgResourceName;
const extgstateResourceName = pdf_output.extgstateResourceName;
const shadingResourceName = pdf_output.shadingResourceName;

/// Stored gradient definition
pub const GradientDef = union(enum) {
    linear: LinearGradient,
    radial: RadialGradient,
};

const ColorFontPlan = color_fonts.ColorFontPlan;

// ============================================================================
// Document
// ============================================================================

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    /// I/O context used for file operations (loadFont, loadImage, loadSvg).
    io: std.Io,
    pages: std.ArrayListUnmanaged(Page),
    /// Index of current page for content operations (0-based).
    current_page: usize = 0,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .empty,
    // Track all embedded fonts
    embedded_fonts: std.ArrayListUnmanaged(*EmbeddedFont) = .empty,
    // Track all embedded font families
    embedded_font_families: std.ArrayListUnmanaged(*EmbeddedFontFamily) = .empty,
    // Document-wide feature overrides set via setFeature; applied to every
    // font at registration so load order doesn't matter.
    feature_overrides: std.ArrayListUnmanaged(FeatureOverride) = .empty,
    // Per-document clones of caller-owned FontFaces, created on first use
    face_instances: std.AutoHashMapUnmanaged(*const embedded.FontFace, *EmbeddedFont) = .empty,
    // Track all loaded images. `image_owned` runs in lockstep: true when the
    // document created the Image (loadImage*) and must destroy it, false when
    // it was registered by drawImage from a caller-owned Image - that allows
    // sharing one decoded Image across many documents.
    loaded_images: std.ArrayListUnmanaged(*Image) = .empty,
    image_owned: std.ArrayListUnmanaged(bool) = .empty,
    // Track all loaded SVGs; `svg_owned` mirrors image_owned.
    loaded_svgs: std.ArrayListUnmanaged(*Svg) = .empty,
    svg_owned: std.ArrayListUnmanaged(bool) = .empty,
    // Track gradients used in document
    gradients: std.ArrayListUnmanaged(GradientDef) = .empty,
    // Document outline (table of contents)
    outline: ?outlinemod.Outline = null,
    // Page label ranges
    page_labels: std.ArrayListUnmanaged(PageLabelEntry) = .empty,
    /// Document metadata (title, author, etc.)
    metadata: DocumentMetadata = .{},
    /// Compression level for PDF streams: 0 = uncompressed, 1 = fastest
    /// (default), 9 = smallest; use 6 for a good size/speed balance.
    /// Out-of-range values are clamped to 1-9. Image pixel streams always
    /// compress at >= 6 (see imageCompressionLevel).
    compression_level: i32 = 1,
    /// Worker threads for compressing streams during `output()` (page
    /// contents and font subsets). Default 1 = compress inline. Values > 1
    /// require a thread-safe allocator (e.g. `std.heap.smp_allocator`).
    /// Output bytes are identical regardless of this setting.
    compress_threads: u32 = 1,
    /// PDF/A conformance level (default: none - no restrictions).
    conformance: pdfa.Conformance = .none,
    /// COLR color-font emission plans, rebuilt on each `output()` call. Each
    /// entry is heap-allocated so pointers stay stable as the list grows.
    color_plans: std.ArrayListUnmanaged(*ColorFontPlan) = .empty,
    /// Timing breakdown of the most recent `output()` call (for performance
    /// debugging). Per-document so concurrent documents don't race.
    last_output_timing: pdf_output.OutputTiming = .{},

    /// Create a new PDF document.
    /// `io` is used for file operations such as `loadFont`, `loadImage`, and `loadSvg`.
    /// In tests, pass `std.testing.io`. In a CLI, use `init.io` from the main entry point.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Document {
        return .{
            .allocator = allocator,
            .io = io,
            .pages = .empty,
        };
    }

    /// Free all document resources.
    pub fn deinit(self: *Document) void {
        color_fonts.clearColorPlans(self);
        self.color_plans.deinit(self.allocator);
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
        self.used_fonts.deinit(self.allocator);
        // Clean up embedded fonts
        for (self.embedded_fonts.items) |font| {
            font.deinit();
        }
        self.embedded_fonts.deinit(self.allocator);
        // Clean up embedded font families (fonts already freed above)
        for (self.embedded_font_families.items) |family| {
            self.allocator.destroy(family);
        }
        self.embedded_font_families.deinit(self.allocator);
        self.feature_overrides.deinit(self.allocator);
        self.face_instances.deinit(self.allocator);
        // Clean up loaded images (only ones this document created)
        for (self.loaded_images.items, self.image_owned.items) |image, owned| {
            if (owned) {
                image.deinit();
                self.allocator.destroy(image);
            }
        }
        self.loaded_images.deinit(self.allocator);
        self.image_owned.deinit(self.allocator);
        // Clean up loaded SVGs (only ones this document created)
        for (self.loaded_svgs.items, self.svg_owned.items) |s, owned| {
            if (owned) {
                s.deinit();
                self.allocator.destroy(s);
            }
        }
        self.loaded_svgs.deinit(self.allocator);
        self.svg_owned.deinit(self.allocator);
        // Clean up gradients
        self.gradients.deinit(self.allocator);
        // Clean up outline
        if (self.outline) |*o| {
            o.deinit();
        }
        // Clean up page labels
        self.page_labels.deinit(self.allocator);
    }

    /// Set document metadata (title, author, subject, etc.).
    /// Only non-null fields are written to the PDF Info dictionary.
    pub fn setMetadata(self: *Document, meta: DocumentMetadata) void {
        self.metadata = meta;
    }

    /// Set PDF/A conformance level.
    /// This must be called before adding content that violates conformance rules.
    /// For example, PDF/A-1b does not allow transparency (opacity < 1.0).
    pub fn setConformance(self: *Document, conformance: pdfa.Conformance) void {
        self.conformance = conformance;
    }

    /// Add a new page with the specified options (size, margins).
    /// The new page becomes the current page for subsequent operations.
    pub fn addPage(self: *Document, opts: PageOptions) !void {
        try self.pages.append(self.allocator, Page.init(self.allocator, opts));
        self.current_page = self.pages.items.len - 1;
    }

    /// Insert a page at the specified index.
    /// Pages at and after the index are shifted. The inserted page becomes current.
    pub fn insertPage(self: *Document, index: usize, opts: PageOptions) !void {
        try self.pages.insert(self.allocator, index, Page.init(self.allocator, opts));
        self.current_page = index;
    }

    /// Select a page by index for subsequent content operations.
    pub fn selectPage(self: *Document, index: usize) void {
        std.debug.assert(index < self.pages.items.len);
        self.current_page = index;
    }

    /// Get the total number of pages.
    pub fn getPageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Load a TrueType font from file.
    /// Returns a Font that can be used in TextStyle.
    /// Use .identity (Unicode, CID) unless you need .win_ansi legacy 256-char mode.
    pub fn loadFont(self: *Document, path: []const u8, encoding: FontEncoding) !Font {
        const emb = try EmbeddedFont.fromFile(self.io, self.allocator, path);
        emb.encoding = encoding;
        try self.registerFont(emb);
        return Font{ .embedded = emb };
    }

    /// Load a TrueType font from memory buffer.
    /// Returns a Font that can be used in TextStyle.
    /// Lifetime: BORROWS `data` - the bytes are referenced, not copied, and
    /// must outlive the Document. (Sharing one font buffer across many
    /// documents is the intended high-throughput pattern.)
    pub fn loadFontFromMemory(self: *Document, data: []const u8, encoding: FontEncoding) !Font {
        const emb = try EmbeddedFont.fromMemory(self.allocator, data, false);
        emb.encoding = encoding;
        try self.registerFont(emb);
        return Font{ .embedded = emb };
    }

    /// Options for loading a font family with multiple variants.
    pub const FontFamilyOptions = struct {
        /// Path to regular weight font file (required).
        regular: []const u8,
        /// Path to bold weight font file (optional).
        bold: ?[]const u8 = null,
        /// Path to italic font file (optional).
        italic: ?[]const u8 = null,
        /// Path to bold-italic font file (optional).
        bold_italic: ?[]const u8 = null,
        /// Font encoding (applies to all variants). Defaults to .identity
        /// (Unicode, CID); use .win_ansi for legacy 256-char mode.
        encoding: FontEncoding = .identity,
    };

    /// Load a font family with regular, bold, italic, and bold-italic variants.
    /// Only the regular variant is required; others are optional.
    /// The returned Font can be used with TextStyle.bold and TextStyle.italic
    /// to automatically select the correct variant.
    ///
    /// Example:
    /// ```
    /// const gentium = try doc.loadFontFamily(.{
    ///     .regular = "fonts/Gentium-Regular.ttf",
    ///     .bold = "fonts/Gentium-Bold.ttf",
    ///     .italic = "fonts/Gentium-Italic.ttf",
    ///     .bold_italic = "fonts/Gentium-BoldItalic.ttf",
    /// });
    /// const style = TextStyle{ .font = gentium, .size = 12, .bold = true };
    /// ```
    pub fn loadFontFamily(self: *Document, opts: FontFamilyOptions) !Font {
        const encoding = opts.encoding;

        // Load regular (required)
        const regular = try EmbeddedFont.fromFile(self.io, self.allocator, opts.regular);
        regular.encoding = encoding;
        try self.registerFont(regular);

        // Load optional variants
        var bold: ?*EmbeddedFont = null;
        if (opts.bold) |path| {
            bold = try EmbeddedFont.fromFile(self.io, self.allocator, path);
            bold.?.encoding = encoding;
            try self.registerFont(bold.?);
        }

        var italic: ?*EmbeddedFont = null;
        if (opts.italic) |path| {
            italic = try EmbeddedFont.fromFile(self.io, self.allocator, path);
            italic.?.encoding = encoding;
            try self.registerFont(italic.?);
        }

        var bold_italic: ?*EmbeddedFont = null;
        if (opts.bold_italic) |path| {
            bold_italic = try EmbeddedFont.fromFile(self.io, self.allocator, path);
            bold_italic.?.encoding = encoding;
            try self.registerFont(bold_italic.?);
        }

        // Create and store the family
        const family = try self.allocator.create(EmbeddedFontFamily);
        family.* = .{
            .regular = regular,
            .bold = bold,
            .italic = italic,
            .bold_italic = bold_italic,
        };
        try self.embedded_font_families.append(self.allocator, family);

        return Font{ .embedded_family = family };
    }

    /// Options for loading a font family from memory buffers.
    pub const FontFamilyMemoryOptions = struct {
        /// Font data for regular weight (required).
        regular: []const u8,
        /// Font data for bold weight (optional).
        bold: ?[]const u8 = null,
        /// Font data for italic (optional).
        italic: ?[]const u8 = null,
        /// Font data for bold-italic (optional).
        bold_italic: ?[]const u8 = null,
        /// Font encoding (applies to all variants). Defaults to .identity
        /// (Unicode, CID); use .win_ansi for legacy 256-char mode.
        encoding: FontEncoding = .identity,
    };

    /// Load a font family from memory buffers.
    /// Lifetime: BORROWS all buffers - they must outlive the Document.
    /// Only the regular variant is required; others are optional.
    /// The document does NOT take ownership of the data - caller must ensure buffers outlive the document.
    pub fn loadFontFamilyFromMemory(self: *Document, opts: FontFamilyMemoryOptions) !Font {
        const encoding = opts.encoding;

        // Load regular (required)
        const regular = try EmbeddedFont.fromMemory(self.allocator, opts.regular, false);
        regular.encoding = encoding;
        try self.registerFont(regular);

        // Load optional variants
        var bold: ?*EmbeddedFont = null;
        if (opts.bold) |data| {
            bold = try EmbeddedFont.fromMemory(self.allocator, data, false);
            bold.?.encoding = encoding;
            try self.registerFont(bold.?);
        }

        var italic: ?*EmbeddedFont = null;
        if (opts.italic) |data| {
            italic = try EmbeddedFont.fromMemory(self.allocator, data, false);
            italic.?.encoding = encoding;
            try self.registerFont(italic.?);
        }

        var bold_italic: ?*EmbeddedFont = null;
        if (opts.bold_italic) |data| {
            bold_italic = try EmbeddedFont.fromMemory(self.allocator, data, false);
            bold_italic.?.encoding = encoding;
            try self.registerFont(bold_italic.?);
        }

        // Create and store the family
        const family = try self.allocator.create(EmbeddedFontFamily);
        family.* = .{
            .regular = regular,
            .bold = bold,
            .italic = italic,
            .bold_italic = bold_italic,
        };
        try self.embedded_font_families.append(self.allocator, family);

        return Font{ .embedded_family = family };
    }

    /// Get index of embedded font (for resource naming)
    pub fn getEmbeddedFontIndex(self: *Document, font: *EmbeddedFont) ?usize {
        for (self.embedded_fonts.items, 0..) |f, i| {
            if (f == font) return i;
        }
        return null;
    }

    /// Load an image from file (JPEG or PNG).
    /// Returns a handle that can be used with drawImage().
    pub fn loadImage(self: *Document, path: []const u8) !*Image {
        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(100 * 1024 * 1024));
        errdefer self.allocator.free(data);
        const image = try Image.fromMemoryLevel(self.allocator, data, true, self.imageCompressionLevel());
        image.document_owned = true;
        try self.registerImage(image, true);
        return image;
    }

    /// Compression level for image pixel streams. Floor of 6: image data is
    /// compressed once at load and dominates file size, so the fast levels
    /// used for content streams are a bad trade here. Levels 7-9 are honored.
    fn imageCompressionLevel(self: *const Document) i32 {
        return @max(6, self.compression_level);
    }

    /// Load an image from memory buffer (JPEG or PNG).
    /// Returns a handle that can be used with drawImage().
    /// Lifetime: BORROWS `data` - JPEG bytes are embedded directly from the
    /// buffer, so it must outlive the Document. (PNG data is transcoded up
    /// front, but the borrow contract applies to both formats.)
    pub fn loadImageFromMemory(self: *Document, data: []const u8) !*Image {
        const image = try Image.fromMemoryLevel(self.allocator, data, false, self.imageCompressionLevel());
        image.document_owned = true;
        try self.registerImage(image, true);
        return image;
    }

    pub const FeatureOverride = struct {
        feature: opentype.Feature,
        enabled: bool,
    };

    /// Resolve .face/.family styles to this document's private clone
    /// (instantiating on first use); all other styles pass through. Internal
    /// layers below the public entry points only ever see resolved styles.
    fn normalizeStyle(self: *Document, style: TextStyle) !TextStyle {
        switch (style.font) {
            .face => |f| {
                // A single face has no variants (same rule as .embedded)
                if (style.bold or style.italic) return error.FontVariantNotLoaded;
                var s = style;
                s.font = .{ .embedded = try self.faceInstance(f) };
                return s;
            },
            .family => |fam| {
                const f = try fam.resolve(style.bold, style.italic);
                var s = style;
                s.font = .{ .embedded = try self.faceInstance(f) };
                // Flags have served their purpose (variant selection)
                s.bold = false;
                s.italic = false;
                return s;
            },
            else => return style,
        }
    }

    /// This document's clone of a caller-owned face (created on first use).
    fn faceInstance(self: *Document, f: *const embedded.FontFace) !*EmbeddedFont {
        if (self.face_instances.get(f)) |emb| return emb;
        const emb = try f.instantiate(self.allocator);
        {
            errdefer emb.deinit();
            try self.registerFont(emb);
        }
        // Registered: the document owns emb now. A failed map insert just
        // means the next use creates another clone - wasteful, not unsound.
        self.face_instances.put(self.allocator, f, emb) catch {};
        return emb;
    }

    /// Register an embedded font and apply document-wide feature overrides,
    /// so setFeature affects fonts regardless of load order.
    fn registerFont(self: *Document, emb: *EmbeddedFont) !void {
        try self.embedded_fonts.append(self.allocator, emb);
        for (self.feature_overrides.items) |o| {
            emb.setFeature(o.feature, o.enabled);
        }
    }

    /// Register an image, recording whether this document owns (and must
    /// destroy) it. Reserves capacity in both lists first so they stay in
    /// lockstep even when an allocation fails.
    fn registerImage(self: *Document, image: *Image, owned: bool) !void {
        try self.loaded_images.ensureUnusedCapacity(self.allocator, 1);
        try self.image_owned.ensureUnusedCapacity(self.allocator, 1);
        self.loaded_images.appendAssumeCapacity(image);
        self.image_owned.appendAssumeCapacity(owned);
    }

    /// Register an SVG; see registerImage for the ownership contract.
    fn registerSvg(self: *Document, s: *Svg, owned: bool) !void {
        try self.loaded_svgs.ensureUnusedCapacity(self.allocator, 1);
        try self.svg_owned.ensureUnusedCapacity(self.allocator, 1);
        self.loaded_svgs.appendAssumeCapacity(s);
        self.svg_owned.appendAssumeCapacity(owned);
    }

    /// Get index of image (for resource naming)
    fn getImageIndex(self: *Document, image: *Image) ?usize {
        for (self.loaded_images.items, 0..) |img, i| {
            if (img == image) return i;
        }
        return null;
    }

    /// Draw an image at the specified position.
    /// If width or height is 0, the original dimension is used (maintaining aspect ratio if one is specified).
    /// Coordinates are from top-left origin.
    pub fn drawImage(self: *Document, image: *Image, rect: Rect) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Calculate display dimensions
        var display_w = rect.width;
        var display_h = rect.height;

        if (display_w == 0 and display_h == 0) {
            // Use original dimensions (1 pixel = 1 point)
            display_w = @floatFromInt(image.width);
            display_h = @floatFromInt(image.height);
        } else if (display_w == 0) {
            // Calculate width from height, maintaining aspect ratio
            const aspect = @as(f64, @floatFromInt(image.width)) / @as(f64, @floatFromInt(image.height));
            display_w = display_h * aspect;
        } else if (display_h == 0) {
            // Calculate height from width, maintaining aspect ratio
            const aspect = @as(f64, @floatFromInt(image.height)) / @as(f64, @floatFromInt(image.width));
            display_h = display_w * aspect;
        }

        // Convert from top-left to PDF coordinates (bottom-left origin)
        // y is the top of the image, PDF needs the bottom
        const pdf_y = page_height - rect.y - display_h;

        // Get image resource name
        const img_idx = self.getImageIndex(image) orelse {
            // Another document's image would dangle once that document
            // deinits; only caller-created images (Image.fromMemory) are
            // shareable across documents
            if (image.document_owned) return error.ForeignImage;
            // Caller-owned: register without taking ownership
            try self.registerImage(image, false);
            return self.drawImage(image, rect);
        };

        // Mark image as used on this page
        try page.markImageUsed(self.allocator, image);

        // Generate PDF content: q cm /Im Do Q
        // The cm operator sets a transformation matrix for scaling and positioning
        var buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "q\n{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n/Im{d} Do\nQ\n", .{
            display_w,
            display_h,
            rect.x,
            pdf_y,
            img_idx + 1, // 1-indexed resource names
        }) catch unreachable;

        const raw_copy = try page.pageAllocator().dupe(u8, content);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Load an SVG from file.
    /// Returns a handle that can be used with drawSvg().
    pub fn loadSvg(self: *Document, path: []const u8) !*Svg {
        const s = try Svg.fromFile(self.io, self.allocator, path);
        s.document_owned = true;
        try self.registerSvg(s, true);
        return s;
    }

    /// Load an SVG from memory buffer.
    /// Returns a handle that can be used with drawSvg().
    /// Lifetime: COPIES - the SVG is fully parsed and `data` may be freed
    /// as soon as this returns.
    pub fn loadSvgFromMemory(self: *Document, data: []const u8) !*Svg {
        const s = try Svg.fromMemory(self.allocator, data);
        s.document_owned = true;
        try self.registerSvg(s, true);
        return s;
    }

    /// Get index of SVG (for resource naming)
    fn getSvgIndex(self: *Document, s: *Svg) ?usize {
        for (self.loaded_svgs.items, 0..) |existing, i| {
            if (existing == s) return i;
        }
        return null;
    }

    /// Draw an SVG at the specified position.
    /// If width or height is 0, the original dimension is used (maintaining aspect ratio if one is specified).
    /// Coordinates are from top-left origin.
    pub fn drawSvg(self: *Document, s: *Svg, rect: Rect) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Calculate display dimensions
        var display_w = rect.width;
        var display_h = rect.height;

        if (display_w == 0 and display_h == 0) {
            // Use original dimensions
            display_w = s.width;
            display_h = s.height;
        } else if (display_w == 0) {
            // Calculate width from height, maintaining aspect ratio
            const aspect = s.width / s.height;
            display_w = display_h * aspect;
        } else if (display_h == 0) {
            // Calculate height from width, maintaining aspect ratio
            const aspect = s.height / s.width;
            display_h = display_w * aspect;
        }

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y = page_height - rect.y - display_h;

        // Get SVG resource name
        const svg_idx = self.getSvgIndex(s) orelse {
            // Another document's SVG would dangle once that document
            // deinits; only caller-created SVGs (Svg.fromMemory) are
            // shareable across documents
            if (s.document_owned) return error.ForeignSvg;
            // Caller-owned: register without taking ownership
            try self.registerSvg(s, false);
            return self.drawSvg(s, rect);
        };

        // Mark SVG as used on this page
        try page.markSvgUsed(self.allocator, s);

        // Generate PDF content: q cm /SvN Do Q
        // Scale from SVG dimensions to display dimensions
        const scale_x = display_w / s.width;
        const scale_y = display_h / s.height;

        var buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "q\n{d:.4} 0 0 {d:.4} {d:.2} {d:.2} cm\n/{s} Do\nQ\n", .{
            scale_x,
            scale_y,
            rect.x,
            pdf_y,
            svgResourceName(svg_idx),
        }) catch unreachable;

        const raw_copy = try page.pageAllocator().dupe(u8, content);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Returns a region for the current page respecting its margins.
    /// Returns null if no pages have been added.
    pub fn getPageRegion(self: *Document) ?Region {
        if (self.pages.items.len == 0) return null;
        const page = self.pages.items[self.current_page];
        return .{
            .x = page.margins.left,
            .y = page.margins.top,
            .width = page.size.width - page.margins.left - page.margins.right,
            .height = page.size.height - page.margins.top - page.margins.bottom,
        };
    }

    /// Get current page size. Returns A4 if no pages exist.
    fn currentPageSize(self: *const Document) PageSize {
        if (self.pages.items.len == 0) return PageSize.A4;
        return self.pages.items[self.current_page].size;
    }

    /// Set OpenType feature for all embedded fonts
    /// Example: doc.setFeature(.liga, false) to disable ligatures
    pub fn setFeature(self: *Document, feature: opentype.Feature, enabled: bool) !void {
        for (self.embedded_fonts.items) |font| {
            font.setFeature(feature, enabled);
        }
        // Record the override so fonts loaded after this call get it too
        for (self.feature_overrides.items) |*o| {
            if (o.feature == feature) {
                o.enabled = enabled;
                return;
            }
        }
        try self.feature_overrides.append(self.allocator, .{ .feature = feature, .enabled = enabled });
    }

    /// Set OpenType feature for a specific embedded font
    pub fn setFontFeature(self: *Document, font: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void {
        _ = self;
        font.setFeature(feature, enabled);
    }

    /// Get font metrics for a specific TextStyle.
    pub fn getFontMetricsStyled(_: *Document, style: TextStyle) FontMetrics {
        const size = style.size;
        const scale = size / 1000.0;

        // Get embedded font - for families, resolve based on bold/italic or fall back to regular
        const emb: ?*EmbeddedFont = switch (style.font) {
            .embedded => |e| e,
            .embedded_family => |fam| fam.resolve(style.bold, style.italic) catch fam.regular,
            // Metrics are immutable prototype fields - no instantiation needed
            .face => |f| f.prototype,
            .family => |fam| if (fam.resolve(style.bold, style.italic)) |f| f.prototype else |_| fam.regular.prototype,
            else => null,
        };

        if (emb) |e| {
            return .{
                .ascender = @as(f64, @floatFromInt(e.ascent)) * scale,
                .descender = @as(f64, @floatFromInt(e.descent)) * scale,
                .cap_height = @as(f64, @floatFromInt(e.cap_height)) * scale,
                .x_height = @as(f64, @floatFromInt(e.cap_height)) * scale * 0.7,
                .y_max = @as(f64, @floatFromInt(e.bbox[3])) * scale,
                .font_size = size,
                .units_per_em = e.font.head.?.units_per_em,
            };
        } else {
            // Standard font
            const std_font = style.standardFont() orelse .helvetica;
            const m = metrics.getStandardFontMetrics(std_font);
            return .{
                .ascender = @as(f64, @floatFromInt(m.ascender)) * scale,
                .descender = @as(f64, @floatFromInt(m.descender)) * scale,
                .cap_height = @as(f64, @floatFromInt(m.cap_height)) * scale,
                .x_height = @as(f64, @floatFromInt(m.x_height)) * scale,
                .y_max = @as(f64, @floatFromInt(m.ascender)) * scale,
                .font_size = size,
                .units_per_em = 1000,
            };
        }
    }

    /// Measure text dimensions with explicit style (without rendering).
    /// Handles embedded fonts (real glyph advances plus kerning) as well as
    /// the standard 14 - it must agree with what write*/draw* actually render.
    pub fn measureStyled(self: *Document, text_str: []const u8, style: TextStyle) !TextMetrics {
        // .face/.family styles resolve to this document's clone (first use
        // may instantiate, hence the error union) so document-level feature
        // overrides are reflected in measurement
        const s = try self.normalizeStyle(style);
        return .{
            .width = metrics.measureTextStyled(text_str, s),
            .height = s.size * 1.2,
            .char_count = text_str.len,
        };
    }

    /// Get current page index (0-based).
    pub fn getPageIndex(self: *const Document) usize {
        return self.current_page;
    }

    /// Get a destination for a y position on the current page.
    /// Used as target for internal links (e.g., TOC entries).
    /// Returns null if no pages have been added.
    pub fn getDestination(self: *const Document, y: f64) ?Destination {
        if (self.pages.items.len == 0) return null;
        return .{ .page_index = self.current_page, .y = y };
    }

    /// Add an internal link (clickable area that jumps to another page position).
    /// The rect specifies the clickable area on the current page.
    /// The dest specifies the target page and y position.
    pub fn addLink(self: *Document, rect: Rect, dest: Destination) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.current_page];
        try page.annotations.append(self.allocator, .{
            .internal = .{ .rect = rect, .dest = dest },
        });
    }

    /// Add an external link (clickable area that opens a URL).
    /// The rect specifies the clickable area on the current page.
    /// The url is copied to page-local storage.
    pub fn addExternalLink(self: *Document, rect: Rect, url: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.current_page];
        const page_alloc = page.pageAllocator();
        // Copy URL to page arena (freed when page is destroyed)
        const url_copy = try page_alloc.dupe(u8, url);
        try page.annotations.append(self.allocator, .{
            .external = .{ .rect = rect, .url = url_copy },
        });
    }

    /// Create an outline builder for the document's table of contents.
    /// Build the outline with add() and addChild(), then call setOutline().
    pub fn createOutline(self: *Document) Outline {
        return Outline.init(self.allocator);
    }

    /// Set the document outline (table of contents).
    /// Takes ownership of the outline - do not use or deinit the outline after this call.
    pub fn setOutline(self: *Document, o: *Outline) void {
        // Clean up any existing outline
        if (self.outline) |*existing| {
            existing.deinit();
        }
        // Move the outline into the document
        self.outline = o.*;
        // Clear the source to prevent double-free (caller should not deinit)
        o.* = Outline.init(o.allocator);
    }

    /// Sets a page label range starting at the specified page index.
    /// Labels apply from page_index until the next setPageLabel call or end of document.
    pub fn setPageLabel(self: *Document, page_index: usize, label: PageLabel) !void {
        try self.page_labels.append(self.allocator, .{
            .page_index = page_index,
            .label = label,
        });
    }

    /// Write text at position with word spacing (styled version).
    /// Write text at (x, y) with explicit word spacing (used by justified
    /// layout). Thin wrapper over writeTextStyled.
    fn writeWithWordSpacingStyled(self: *Document, x: f64, y: f64, str: []const u8, word_spacing: f64, style: TextStyle) !void {
        _ = try self.writeTextStyled(.{ .x = x, .y = y }, str, style, word_spacing);
    }
    /// Writes text at the specified position with explicit style.
    /// pos.y is the text baseline; opts.anchor selects which part of the
    /// text sits at pos.x (left edge by default, center, or right edge).
    /// Returns the bounding rectangle of the rendered text
    /// (ascender-to-descender, from real font metrics).
    pub fn writeAt(self: *Document, pos: Point, str: []const u8, style: TextStyle, opts: WriteAtOptions) !Rect {
        const width = try self.writeTextStyled(pos, str, style, 0);

        // Anchoring: writeTextStyled shapes the text (which is where the
        // width comes from), so shift the just-appended command instead of
        // measuring up front - the text is shaped exactly once.
        const x_left = switch (opts.anchor) {
            .left => pos.x,
            .center => pos.x - width / 2,
            .right => pos.x - width,
        };
        if (opts.anchor != .left) {
            var page = &self.pages.items[self.current_page];
            page.commands.items[page.commands.items.len - 1].text.x = x_left;
        }

        const m = self.getFontMetricsStyled(style);
        return .{
            .x = x_left,
            .y = pos.y - m.ascender,
            .width = width,
            .height = m.ascender - m.descender,
        };
    }

    /// Internal: Write text at position with explicit style and word spacing.
    /// pos is in user coordinates (top-left origin), converted to PDF coordinates internally.
    /// Returns the rendered width: computed from the shaped glyph run for
    /// embedded fonts (no second shaping pass), measured otherwise.
    fn writeTextStyled(self: *Document, pos: Point, str: []const u8, style_in: TextStyle, word_spacing: f64) !f64 {
        if (self.pages.items.len == 0) return error.NoPage;
        const style = try self.normalizeStyle(style_in);

        var page = &self.pages.items[self.current_page];
        const page_alloc = page.pageAllocator();

        // Create owned copy of text, stripping soft-hyphens (U+00AD)
        const text_copy = try stripSoftHyphens(page_alloc, str);

        // Determine font reference from style
        var cached_glyphs: ?[]const u16 = null;
        const font_ref: FontRef = switch (style.font) {
            .embedded => |emb| blk: {
                // A single embedded font has no variants: bold/italic would
                // silently render regular. Load a family (loadFontFamily) to
                // use style.bold/.italic with embedded fonts.
                if (style.bold or style.italic) return error.FontVariantNotLoaded;
                // Fonts are per-document (they accumulate subset state):
                // using a font loaded into another Document would silently
                // render nothing and pollute that document's subset. Use
                // SharedFont to reuse a parsed font across documents.
                if (self.getEmbeddedFontIndex(emb) == null) return error.ForeignFont;
                try page.markEmbeddedUsed(self.allocator, emb);
                if (emb.encoding == .identity) {
                    cached_glyphs = try emb.markUnicodeCharsUsed(text_copy, page_alloc);
                } else {
                    emb.markCharsUsed(text_copy);
                }
                break :blk .{ .embedded = emb };
            },
            .embedded_family => |fam| blk: {
                const emb = try fam.resolve(style.bold, style.italic);
                if (self.getEmbeddedFontIndex(emb) == null) return error.ForeignFont;
                try page.markEmbeddedUsed(self.allocator, emb);
                if (emb.encoding == .identity) {
                    cached_glyphs = try emb.markUnicodeCharsUsed(text_copy, page_alloc);
                } else {
                    emb.markCharsUsed(text_copy);
                }
                break :blk .{ .embedded = emb };
            },
            // Normalized above - internal emission never sees these
            .face, .family => unreachable,
            .standard, .symbol, .zapf_dingbats => blk: {
                const std_font = style.standardFont() orelse return error.InvalidFont;
                try page.markFontUsed(self.allocator, std_font);
                try self.used_fonts.put(self.allocator, std_font, {}); // Track at document level
                break :blk .{ .standard = std_font };
            },
        };

        // Width of the rendered run: from the already-shaped glyphs when we
        // have them (avoids shaping the same string twice), else measured.
        const text_width = blk: {
            if (cached_glyphs) |glyphs| {
                switch (font_ref) {
                    .embedded => |emb| break :blk emb.glyphSequenceWidth(glyphs, style.size, style.char_spacing),
                    else => {},
                }
            }
            break :blk self.getTextWidthStyled(text_copy, style);
        };

        // Convert from user coordinates (top-left origin) to PDF coordinates (bottom-left origin)
        const pdf_y = self.currentPageSize().height - pos.y;

        // Reject text transparency for conformance levels that disallow it (PDF/A-1b).
        try pdfa.validateOpacity(self.conformance, style.opacity, 1.0);

        // Store deferred command
        try page.commands.append(self.allocator, .{
            .text = .{
                .x = pos.x,
                .y = pdf_y,
                .font_size = style.size,
                .char_spacing = style.char_spacing,
                .word_spacing = word_spacing,
                .text_data = text_copy,
                .font = font_ref,
                .text_color = style.color,
                .opacity = style.opacity,
                .cached_glyphs = cached_glyphs,
                .text_width = text_width,
                .underline = style.decoration.underline,
                .strikethrough = style.decoration.strikethrough,
            },
        });
        return text_width;
    }

    /// Measures text width with explicit style.
    /// Soft-hyphens (U+00AD) are excluded from measurement as they're invisible.
    fn getTextWidthStyled(self: *Document, str: []const u8, style_in: TextStyle) f64 {
        // Resolve faces to this document's clone when possible; on OOM the
        // prototype fallback in metrics still yields correct widths
        const style = self.normalizeStyle(style_in) catch style_in;

        // Fast path: no soft-hyphens
        if (!containsSoftHyphens(str)) {
            return measureTextStyled(str, style);
        }

        // Slow path: filter out soft-hyphens using stack buffer
        var buf: [4096]u8 = undefined;
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
        return measureTextStyled(buf[0..j], style);
    }

    /// Writes flowing text into a region with word wrapping.
    /// Text continues from the current cursor position (cursor_x, cursor_y).
    /// Words wrap to the next line when they don't fit. Cursor is updated to
    /// the end of the written text, allowing subsequent write() calls to continue
    /// the flow with different styles.
    ///
    /// Options:
    /// - measure_only: Track cursor position without rendering (for calculating dimensions)
    /// - wrap: If false, text stays on one line without wrapping
    /// - line_height: Line height multiplier (default 1.0)
    pub fn write(self: *Document, region: *Region, str: []const u8, style: TextStyle, opts: WriteOptions) !WriteResult {
        const line_height = style.size * opts.line_height;
        const font_metrics = self.getFontMetricsStyled(style);
        const ascender = font_metrics.ascender;
        const descender = @abs(font_metrics.descender);
        const cap_height = font_metrics.cap_height;
        const space_width = self.getTextWidthStyled(" ", style);

        // Helper to compute y position based on valign
        const getYPos = struct {
            fn call(reg: *Region, lh: f64, asc: f64, desc: f64, cap_h: f64, valign: VAlign) f64 {
                const base = reg.y + reg.padding.top + reg.cursor_y;
                return switch (valign) {
                    .top => base + cap_h,
                    .top_ascent => base + asc,
                    .top_leading => base + (lh + asc - desc) / 2,
                    .middle => base + lh / 2 + asc / 2,
                    .bottom => base + lh,
                };
            }
        }.call;

        // Track for rect calculation
        const start_cursor_x = region.cursor_x;
        const start_cursor_y = region.cursor_y;
        const rect_x = region.x + region.padding.left + start_cursor_x;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        var max_x: f64 = start_cursor_x;

        var lines_written: usize = 0;
        var remaining = str;

        // Line batching state - accumulate words and render whole line at once
        var line_text_start: usize = 0; // Byte offset in str where current line starts
        var line_text_end: usize = 0; // Byte offset where current line ends (after last word)
        var line_render_x: f64 = region.cursor_x; // X position for rendering the line
        var line_has_content = false;

        // Helper to flush (render) the current line batch
        const flushLine = struct {
            fn call(
                doc: *Document,
                text: []const u8,
                text_start: usize,
                text_end: usize,
                render_x: f64,
                render_y: f64,
                sty: TextStyle,
            ) !void {
                if (text_end <= text_start) return;
                const line_text = text[text_start..text_end];
                try doc.writeWithWordSpacingStyled(render_x, render_y, line_text, 0, sty);
            }
        }.call;

        // Skip leading whitespace only at start of line
        if (region.cursor_x == 0) {
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                remaining = remaining[1..];
            }
        }
        // Update line start after skipping whitespace
        line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
        line_text_end = line_text_start;

        while (remaining.len > 0) {
            // Check if we have room for a line (only check at start of new line)
            if (region.cursor_x == 0 and region.remainingHeight() < line_height - 0.01) {
                if (opts.measure_only) {
                    region.cursor_x = start_cursor_x;
                    region.cursor_y = start_cursor_y;
                }
                return .{
                    .lines_written = lines_written,
                    .overflow = remaining,
                    .rect = .{ .x = rect_x, .y = rect_y, .width = max_x - start_cursor_x, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Find the next word
            var word_end: usize = 0;
            var is_newline = false;
            for (remaining, 0..) |c, i| {
                if (c == ' ' or c == '\t' or c == '\n') {
                    word_end = i;
                    is_newline = (c == '\n');
                    break;
                }
            } else {
                word_end = remaining.len;
            }

            if (word_end == 0) {
                // Whitespace at start - handle newline or skip space
                if (is_newline) {
                    // Flush current line before newline
                    if (!opts.measure_only and line_has_content) {
                        const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                        try flushLine(self, str, line_text_start, line_text_end, region.x + region.padding.left + line_render_x, abs_y, style);
                    }
                    region.newLine(line_height);
                    lines_written += 1;
                    line_has_content = false;
                    line_render_x = 0;
                }
                remaining = remaining[1..];
                // Update line start for next line
                line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                line_text_end = line_text_start;
                continue;
            }

            const word = remaining[0..word_end];
            const word_width = self.getTextWidthStyled(word, style);
            const available_width = region.remainingWidth();

            // Check if word fits on current line
            if (word_width <= available_width + 0.01) {
                // Word fits - add to batch (don't render yet)
                const word_end_offset = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr) + word_end;
                line_text_end = word_end_offset;
                line_has_content = true;

                region.cursor_x += word_width;
                if (region.cursor_x > max_x) max_x = region.cursor_x;

                // Handle what comes after the word
                remaining = remaining[word_end..];
                if (remaining.len > 0) {
                    const next_char = remaining[0];
                    if (next_char == '\n') {
                        // Explicit newline - flush line and move to next
                        if (!opts.measure_only and line_has_content) {
                            const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                            try flushLine(self, str, line_text_start, line_text_end, region.x + region.padding.left + line_render_x, abs_y, style);
                        }
                        region.newLine(line_height);
                        lines_written += 1;
                        remaining = remaining[1..];
                        // Skip whitespace at start of new line
                        while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                            remaining = remaining[1..];
                        }
                        // Reset line state
                        line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                        line_text_end = line_text_start;
                        line_render_x = 0;
                        line_has_content = false;
                    } else if (next_char == ' ' or next_char == '\t') {
                        // Include space in batch, advance cursor
                        line_text_end = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr) + 1;
                        region.cursor_x += space_width;
                        remaining = remaining[1..];
                    }
                }
            } else if (!opts.wrap) {
                // No wrapping - add to batch even if it overflows
                const word_end_offset = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr) + word_end;
                line_text_end = word_end_offset;
                line_has_content = true;

                region.cursor_x += word_width;
                if (region.cursor_x > max_x) max_x = region.cursor_x;
                remaining = remaining[word_end..];
                if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                    line_text_end = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr) + 1;
                    region.cursor_x += space_width;
                    remaining = remaining[1..];
                }
            } else if (region.cursor_x == 0) {
                // Word doesn't fit and we're at start of line - must write it anyway
                // Try soft-hyphen break first
                if (self.findSoftHyphenBreakStyled(word, available_width, style)) |break_pos| {
                    const prefix = word[0..break_pos];
                    const prefix_width = self.getTextWidthStyled(prefix, style);
                    const hyphen_width = self.getTextWidthStyled("-", style);
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                        _ = try self.writeTextStyled(.{ .x = abs_x, .y = abs_y }, prefix, style, 0);
                        _ = try self.writeTextStyled(.{ .x = abs_x + prefix_width, .y = abs_y }, "-", style, 0);
                    }
                    region.cursor_x = prefix_width + hyphen_width;
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos + 2 ..]; // Skip soft-hyphen (2 bytes)
                    // Reset line state after break
                    line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                    line_text_end = line_text_start;
                    line_render_x = 0;
                    line_has_content = false;
                } else if (if (opts.break_on_hyphens) self.findHyphenBreakStyled(word, available_width, style) else null) |break_pos| {
                    const prefix = word[0..break_pos];
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                        _ = try self.writeTextStyled(.{ .x = abs_x, .y = abs_y }, prefix, style, 0);
                    }
                    region.cursor_x = self.getTextWidthStyled(prefix, style);
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos..];
                    // Reset line state after break
                    line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                    line_text_end = line_text_start;
                    line_render_x = 0;
                    line_has_content = false;
                } else if (self.findCharacterBreakStyled(word, available_width, style)) |break_pos| {
                    const prefix = word[0..break_pos];
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                        _ = try self.writeTextStyled(.{ .x = abs_x, .y = abs_y }, prefix, style, 0);
                    }
                    region.cursor_x = self.getTextWidthStyled(prefix, style);
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos..];
                    // Reset line state after break
                    line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                    line_text_end = line_text_start;
                    line_render_x = 0;
                    line_has_content = false;
                } else {
                    // Nothing fits, write word anyway (will overflow)
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                        _ = try self.writeTextStyled(.{ .x = abs_x, .y = abs_y }, word, style, 0);
                    }
                    region.cursor_x = word_width;
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    remaining = remaining[word_end..];
                    if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                        remaining = remaining[1..];
                    }
                    // Reset line state after overflow
                    line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                    line_text_end = line_text_start;
                    line_render_x = 0;
                    line_has_content = false;
                }
            } else {
                // Word doesn't fit - wrap to next line
                // Flush current line before wrapping
                if (!opts.measure_only and line_has_content) {
                    const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
                    try flushLine(self, str, line_text_start, line_text_end, region.x + region.padding.left + line_render_x, abs_y, style);
                }
                region.newLine(line_height);
                lines_written += 1;
                // Reset line state for new line
                line_text_start = @intFromPtr(remaining.ptr) - @intFromPtr(str.ptr);
                line_text_end = line_text_start;
                line_render_x = 0;
                line_has_content = false;
                // Don't consume the word, let next iteration handle it
            }
        }

        // Flush any remaining content on the last line
        if (!opts.measure_only and line_has_content) {
            const abs_y = getYPos(region, line_height, ascender, descender, cap_height, opts.valign);
            try flushLine(self, str, line_text_start, line_text_end, region.x + region.padding.left + line_render_x, abs_y, style);
        }

        // Calculate actual lines - if cursor moved vertically, that's our line count
        const final_lines: usize = if (region.cursor_y > start_cursor_y)
            @as(usize, @intFromFloat((region.cursor_y - start_cursor_y) / line_height)) + 1
        else if (region.cursor_x > start_cursor_x)
            1
        else
            0;

        // Restore cursor if measure_only (measurement should be side-effect free)
        if (opts.measure_only) {
            region.cursor_x = start_cursor_x;
            region.cursor_y = start_cursor_y;
        }

        return .{
            .lines_written = final_lines,
            .overflow = null,
            .rect = .{
                .x = rect_x,
                .y = rect_y,
                .width = max_x - start_cursor_x,
                .height = if (final_lines > 0) @as(f64, @floatFromInt(final_lines)) * line_height else 0,
            },
        };
    }

    /// Write a wrapped block of text with alignment support
    /// (left/center/right/justify). Text wraps within the region; the cursor
    /// moves to the start of the next line afterwards. Use this for table
    /// cells, headers, paragraphs - any aligned text.
    pub fn writeBlock(self: *Document, region: *Region, str: []const u8, style: TextStyle, opts: BlockOptions) !WriteResult {
        var st = StyledText.init(self.allocator);
        defer st.deinit();
        try st.append(str, .{});
        return self.writeStyled(region, &st, style, .{
            .measure_only = opts.measure_only,
            .alignment = opts.alignment,
            .valign = opts.valign,
            .break_on_hyphens = opts.break_on_hyphens,
            .line_height = opts.line_height,
        });
    }

    /// Find a soft-hyphen break point in a word that fits within max_width.
    /// Soft-hyphen (U+00AD, 0xC2 0xAD in UTF-8) marks optional break points.
    /// Returns the byte position where to break (soft-hyphen will be replaced with visible hyphen).
    fn findSoftHyphenBreakStyled(self: *Document, word: []const u8, max_width: f64, style: TextStyle) ?usize {
        var best_break: ?usize = null;
        var i: usize = 0;
        while (i + 1 < word.len) {
            if (isSoftHyphenAt(word, i)) {
                const prefix = word[0..i];
                const prefix_width = self.getTextWidthStyled(prefix, style) + self.getTextWidthStyled("-", style);
                if (prefix_width <= max_width) {
                    best_break = i;
                } else {
                    break;
                }
                i += 2;
            } else {
                i += 1;
            }
        }
        return best_break;
    }

    /// Find a regular hyphen break point in a word that fits within max_width.
    /// Regular hyphens stay visible; we break AFTER the hyphen (e.g., "state-" / "of-the-art").
    /// Returns the byte position after the hyphen where to split.
    fn findHyphenBreakStyled(self: *Document, word: []const u8, max_width: f64, style: TextStyle) ?usize {
        var best_break: ?usize = null;
        for (word, 0..) |c, i| {
            if (c == '-' and i > 0 and i + 1 < word.len) {
                const prefix = word[0 .. i + 1];
                const prefix_width = self.getTextWidthStyled(prefix, style);
                if (prefix_width <= max_width) {
                    best_break = i + 1;
                } else {
                    break;
                }
            }
        }
        return best_break;
    }

    /// Find a character break point in a word that fits within max_width.
    /// This is a last resort when no hyphen or soft-hyphen breaks are available.
    /// Returns the byte position where to break (respecting UTF-8 boundaries).
    fn findCharacterBreakStyled(self: *Document, word: []const u8, max_width: f64, style: TextStyle) ?usize {
        var best_break: ?usize = null;
        var current_width: f64 = 0;
        var i: usize = 0;

        while (i < word.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
            const char_end = @min(i + char_len, word.len);
            const prefix_width = self.getTextWidthStyled(word[0..char_end], style);

            if (prefix_width <= max_width) {
                best_break = char_end;
                current_width = prefix_width;
                i = char_end;
            } else {
                break;
            }
        }

        if (best_break) |pos| {
            if (pos > 0 and pos < word.len) {
                return pos;
            }
        }
        return null;
    }

    /// Draws a region's border and fill (without text).
    pub fn drawRegion(self: *Document, region: Region) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];

        // Convert from top-left coordinates to PDF coordinates (bottom-left origin)
        const pdf_y = self.currentPageSize().height - region.y - region.height;

        // Build raw PDF commands for the region
        // Use q/Q (save/restore) to isolate graphics state changes (colors, etc.)
        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        @memcpy(buf[len..][0..2], "q\n");
        len += 2;

        // Fill if specified
        if (region.fill) |fill_color| {
            // Write fill color command
            var color_buf: [64]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&color_buf);
            fill_color.writeFill(&fbs) catch unreachable;
            const color_str = fbs.buffered();
            @memcpy(buf[len .. len + color_str.len], color_str);
            len += color_str.len;

            len += format.writeCoord4Suffix(buf[len..], region.x, pdf_y, region.width, region.height, " re f\n");
        }

        // Draw border if specified
        if (region.border.top or region.border.bottom or region.border.left or region.border.right) {
            const s = region.border.style;

            // Set line width
            const w_str = format.writeF64_3(buf[len..], s.width);
            len += w_str.len;
            @memcpy(buf[len..][0..3], " w\n");
            len += 3;

            // Set dash pattern
            if (s.dash.dash > 0) {
                buf[len] = '[';
                len += 1;
                const dash_str = format.writeF64_3(buf[len..], s.dash.dash);
                len += dash_str.len;
                buf[len] = ' ';
                len += 1;
                const gap_str = format.writeF64_3(buf[len..], s.dash.gap);
                len += gap_str.len;
                @memcpy(buf[len..][0..2], "] ");
                len += 2;
                const phase_str = format.writeF64_3(buf[len..], s.dash.phase);
                len += phase_str.len;
                @memcpy(buf[len..][0..3], " d\n");
                len += 3;
            }

            // Set line cap and join
            buf[len] = @intCast(@intFromEnum(s.cap) + '0');
            len += 1;
            @memcpy(buf[len..][0..3], " J ");
            len += 3;
            buf[len] = @intCast(@intFromEnum(s.join) + '0');
            len += 1;
            @memcpy(buf[len..][0..3], " j\n");
            len += 3;

            // Set stroke color
            var color_buf: [64]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&color_buf);
            s.color.writeStroke(&fbs) catch unreachable;
            const color_str = fbs.buffered();
            @memcpy(buf[len .. len + color_str.len], color_str);
            len += color_str.len;

            if (region.border.top) {
                const y_top = pdf_y + region.height;
                len += format.writeCoord2Suffix(buf[len..], region.x, y_top, " m ");
                len += format.writeCoord2Suffix(buf[len..], region.x + region.width, y_top, " l S\n");
            }
            if (region.border.bottom) {
                len += format.writeCoord2Suffix(buf[len..], region.x, pdf_y, " m ");
                len += format.writeCoord2Suffix(buf[len..], region.x + region.width, pdf_y, " l S\n");
            }
            if (region.border.left) {
                len += format.writeCoord2Suffix(buf[len..], region.x, pdf_y, " m ");
                len += format.writeCoord2Suffix(buf[len..], region.x, pdf_y + region.height, " l S\n");
            }
            if (region.border.right) {
                const x_right = region.x + region.width;
                len += format.writeCoord2Suffix(buf[len..], x_right, pdf_y, " m ");
                len += format.writeCoord2Suffix(buf[len..], x_right, pdf_y + region.height, " l S\n");
            }
        }

        // Restore graphics state
        @memcpy(buf[len..][0..2], "Q\n");
        len += 2;

        if (len > 0) {
            // Allocated on page arena - freed when page is destroyed
            const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
            try page.commands.append(self.allocator, .{ .raw = raw_copy });
        }
    }

    // ========================================================================
    // Graphics Primitives
    // ========================================================================

    // Shape command helpers are in graphics.zig
    const beginShapeCommand = graphics.beginShapeCommand;
    const finishShapeCommand = graphics.finishShapeCommand;

    /// Write opacity ExtGState reference if needed.
    /// Returns the number of bytes written (0 if fully opaque).
    /// Returns ConformanceError.TransparencyNotAllowed for PDF/A-1b with non-opaque values.
    fn writeOpacityRef(self: *Document, page: *pagemod.Page, style: ShapeStyle, buf: []u8) !usize {
        const opacity = graphics.getShapeOpacity(style) orelse return 0;
        // Validate opacity against PDF/A conformance requirements
        try pdfa.validateOpacity(self.conformance, opacity.fill_opacity, opacity.stroke_opacity);
        const idx = try page.getOrAddOpacityState(self.allocator, opacity.fill_opacity, opacity.stroke_opacity) orelse return 0;
        return graphics.writeExtGStateRef(buf, idx);
    }

    /// Draw a line between two points.
    /// Coordinates are from top-left origin.
    pub fn drawLine(self: *Document, p1: Point, p2: Point, style: StrokeStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y1 = page_height - p1.y;
        const pdf_y2 = page_height - p2.y;

        const shape_style = ShapeStyle{ .stroke = style };

        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        @memcpy(buf[len..][0..2], "q\n");
        len += 2;

        // Write opacity ExtGState reference if needed
        len += try self.writeOpacityRef(page, shape_style, buf[len..]);

        // Write stroke style
        len += graphics.writeShapeGraphicsState(shape_style, buf[len..]);

        // Move to start, line to end, stroke
        len += format.writeCoord2Suffix(buf[len..], p1.x, pdf_y1, " m ");
        len += format.writeCoord2Suffix(buf[len..], p2.x, pdf_y2, " l S\n");

        // Restore graphics state
        @memcpy(buf[len..][0..2], "Q\n");
        len += 2;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a rectangle.
    /// Coordinates are from top-left origin.
    /// Style controls stroke and/or fill. If both are null, defaults to stroke with black.
    pub fn drawRect(self: *Document, rect: Rect, style: ShapeStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;
        const pdf_y = page_height - rect.y - rect.height;

        var buf: [512]u8 = undefined;
        var len = beginShapeCommand(&buf, style);
        len += try self.writeOpacityRef(page, style, buf[len..]);
        len += format.writeCoord4Suffix(buf[len..], rect.x, pdf_y, rect.width, rect.height, " re ");
        len += finishShapeCommand(buf[len..], style);

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a rectangle with rounded corners.
    /// If radius is 0 or larger than half the smallest dimension, falls back to regular rect.
    /// Coordinates are from top-left origin.
    pub fn drawRoundedRect(self: *Document, rect: Rect, radius: f64, style: ShapeStyle) !void {
        // Clamp radius to half of smallest dimension
        const max_r = @min(rect.width, rect.height) / 2.0;
        const r = @min(radius, max_r);

        // If radius is effectively 0, use regular rectangle
        if (r < 0.01) {
            return self.drawRect(rect, style);
        }

        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;
        const pdf_y = page_height - rect.y - rect.height;

        var buf: [1024]u8 = undefined;
        var len = beginShapeCommand(&buf, style);
        len += try self.writeOpacityRef(page, style, buf[len..]);
        len += graphics.writeRoundedRectPath(buf[len..], rect.x, pdf_y, rect.width, rect.height, r);
        len += finishShapeCommand(buf[len..], style);

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw an ellipse using 4 cubic Bezier curves.
    /// Rect defines the bounding box of the ellipse.
    /// Coordinates are from top-left origin.
    pub fn drawEllipse(self: *Document, rect: Rect, style: ShapeStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Calculate center and radii from bounding box
        const rx = rect.width / 2.0;
        const ry = rect.height / 2.0;
        const cx = rect.x + rx;
        const pdf_cy = page_height - (rect.y + ry);

        var buf: [1024]u8 = undefined;
        var len = beginShapeCommand(&buf, style);
        len += try self.writeOpacityRef(page, style, buf[len..]);
        len += graphics.writeEllipsePath(buf[len..], cx, pdf_cy, rx, ry);
        len += finishShapeCommand(buf[len..], style);

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a circle (special case of ellipse).
    /// Center is the center point of the circle.
    /// Coordinates are from top-left origin.
    pub fn drawCircle(self: *Document, center: Point, radius: f64, style: ShapeStyle) !void {
        // Convert center + radius to bounding box for drawEllipse
        const diameter = radius * 2.0;
        return self.drawEllipse(.{
            .x = center.x - radius,
            .y = center.y - radius,
            .width = diameter,
            .height = diameter,
        }, style);
    }

    /// Draw a closed polygon.
    /// Coordinates are from top-left origin.
    pub fn drawPolygon(self: *Document, points: []const Point, style: ShapeStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (points.len < 3) return; // Need at least 3 points for a polygon

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Calculate required buffer size: ~50 bytes per point + overhead
        const buf_size = 256 + points.len * 64;
        const buf = try page.pageAllocator().alloc(u8, buf_size);

        var len = beginShapeCommand(buf, style);
        len += try self.writeOpacityRef(page, style, buf[len..]);

        // Move to first point
        const pdf_y0 = page_height - points[0].y;
        len += format.writeCoord2Suffix(buf[len..], points[0].x, pdf_y0, " m\n");

        // Line to remaining points
        for (points[1..]) |pt| {
            const pdf_y = page_height - pt.y;
            len += format.writeCoord2Suffix(buf[len..], pt.x, pdf_y, " l\n");
        }

        // Close path
        @memcpy(buf[len..][0..2], "h ");
        len += 2;

        len += finishShapeCommand(buf[len..], style);
        try page.commands.append(self.allocator, .{ .raw = buf[0..len] });
    }

    /// Create a new path builder.
    pub fn createPath(self: *Document) Path {
        return Path.init(self.allocator);
    }

    /// Create a new styled text builder.
    pub fn createStyledText(self: *Document) StyledText {
        return StyledText.init(self.allocator);
    }

    /// Context for styledTextMeasure callback (contains document and base style).
    pub const MeasureContext = struct {
        doc: *Document,
        style: TextStyle,
    };

    /// Measure function adapter for StyledText.prepare()
    fn styledTextMeasure(text: []const u8, span_style: TextStyleOptions, ctx: *anyopaque) f64 {
        const measure_ctx: *MeasureContext = @ptrCast(@alignCast(ctx));
        // Text width doesn't depend on color/decoration, just the font
        _ = span_style;
        return measure_ctx.doc.getTextWidthStyled(text, measure_ctx.style);
    }

    /// Write styled text into a region with alignment support.
    /// Uses Knuth-Plass optimal line breaking when requested.
    pub fn writeStyled(self: *Document, region: *Region, text: *StyledText, style: TextStyle, opts: ParagraphOptions) !WriteResult {
        if (self.pages.items.len == 0) return error.NoPage;

        const line_height = style.size * opts.line_height;
        const line_width = region.contentWidth();

        // Save original cursor for measure_only restore
        const saved_cursor_x = region.cursor_x;
        const saved_cursor_y = region.cursor_y;

        // Prepare text (preprocesses words with width measurement)
        // Note: We always prepare for middle/bottom valign to count lines accurately
        var measure_ctx = MeasureContext{ .doc = self, .style = style };
        try text.prepare(styledTextMeasure, @ptrCast(&measure_ctx));

        const space_width = self.getTextWidthStyled(" ", style);

        if (text.words.items.len == 0) {
            const rect_x = region.x + region.padding.left;
            const rect_y = region.y + region.padding.top + region.cursor_y;
            return .{ .lines_written = 0, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = line_width, .height = 0 } };
        }

        // For middle/bottom valign, calculate block offset first
        if (opts.valign == .middle or opts.valign == .bottom) {
            const line_count = self.countStyledLinesStyled(text, style, line_width, space_width);
            const fm = self.getFontMetricsStyled(style);
            const ascender = fm.ascender;
            const descender = @abs(fm.descender);
            const text_height = @as(f64, @floatFromInt(line_count)) * line_height;
            const available_height = region.remainingHeight();

            // Max offset that still allows all lines to render (with small margin for precision)
            const max_offset = @max(0, available_height - text_height - 0.1);

            // Block offset positions the text block
            // For middle: center text_height, then shift down by half the leading
            // This positions text slightly below mathematical center for better optical balance
            const leading = line_height - ascender - descender;
            const offset = switch (opts.valign) {
                .top, .top_ascent, .top_leading => 0, // Won't happen due to if check
                .middle => @max(0, (available_height - text_height) / 2 + leading / 2),
                .bottom => max_offset,
            };
            region.cursor_y += offset;
        }

        // For middle, use .top per-line positioning (block offset handles centering)
        // For bottom, use .bottom per-line positioning (baseline flush with edge)
        const render_opts = ParagraphOptions{
            .measure_only = opts.measure_only,
            .alignment = opts.alignment,
            .valign = if (opts.valign == .middle) .top_leading else opts.valign,
            .break_on_hyphens = opts.break_on_hyphens,
            .line_breaking = opts.line_breaking,
            .line_height = opts.line_height,
        };

        const start_cursor_y = region.cursor_y;
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();
        var lines_written: usize = 0;

        // Use optimal or greedy line breaking based on options
        if (render_opts.line_breaking == .optimal) {
            const result = try self.writeStyledOptimal(region, text, style, render_opts, line_height, space_width, line_width, start_cursor_y);
            if (opts.measure_only) {
                region.cursor_x = saved_cursor_x;
                region.cursor_y = saved_cursor_y;
            }
            return result;
        }

        // Greedy algorithm
        const n = text.words.items.len;
        var word_idx: usize = 0;

        while (word_idx < n) {
            // Check if we have room for another line
            if (region.remainingHeight() < line_height) {
                // Return overflow - remaining words
                if (opts.measure_only) {
                    region.cursor_x = saved_cursor_x;
                    region.cursor_y = saved_cursor_y;
                }
                return .{
                    .lines_written = lines_written,
                    .overflow = text.getTextFromWord(word_idx),
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Collect words that fit on this line
            var current_width: f64 = 0;
            const line_start = word_idx;
            var line_end = word_idx;

            while (line_end < n) {
                const word = text.words.items[line_end];
                const word_with_space = if (line_end > line_start) word.width + space_width else word.width;

                if (current_width + word_with_space > line_width + 0.01) break;

                current_width += word_with_space;
                line_end += 1;

                if (word.force_break) break;
            }

            // Handle case where first word doesn't fit
            if (line_end == line_start and line_start < n) {
                const big_word = text.words.items[line_start];

                // Try to break at soft-hyphen if available
                if (big_word.break_points) |break_points| {
                    const hyphen_width = self.getTextWidthStyled("-", style);

                    // Find best break point that fits
                    var best_bp: ?styled_text.BreakPoint = null;
                    for (break_points) |bp| {
                        if (bp.width + hyphen_width <= line_width + 0.01) {
                            best_bp = bp;
                        } else {
                            break; // Break points are ordered by position
                        }
                    }

                    if (best_bp) |_| {
                        const span = text.spans.items[big_word.start_span];
                        const fm = self.getFontMetricsStyled(style);

                        // Apply span color to style for rendering
                        var render_style = style;
                        render_style.color = span.style.color;
                        render_style.decoration = span.style.decoration;

                        // Recursively break at soft-hyphens until the remaining fits
                        var remaining_start: u16 = big_word.start_offset;

                        while (remaining_start < big_word.end_offset) {
                            const remaining = span.text[remaining_start..big_word.end_offset];
                            var remaining_buf: [512]u8 = undefined;
                            const clean_remaining = stripSoftHyphensTo(remaining, &remaining_buf);
                            const remaining_width = self.getTextWidthStyled(clean_remaining, style);

                            // If remaining fits on one line, render it and we're done
                            if (remaining_width <= line_width + 0.01) {
                                if (region.remainingHeight() >= line_height) {
                                    const y_pos = valignBaseline(region, line_height, fm, render_opts.valign);
                                    _ = try self.writeAt(.{ .x = region.x + region.padding.left, .y = y_pos }, clean_remaining, render_style, .{});
                                    region.newLine(line_height);
                                    lines_written += 1;
                                }
                                break;
                            }

                            // Find best break point that fits, searching from remaining_start
                            var best_break_offset: ?u16 = null;
                            for (break_points) |bp| {
                                if (bp.offset <= remaining_start) continue; // Skip already-used break points
                                // Measure text from remaining_start to this break point
                                const segment = span.text[remaining_start..bp.offset];
                                var seg_buf: [512]u8 = undefined;
                                const clean_seg = stripSoftHyphensTo(segment, &seg_buf);
                                const seg_width = self.getTextWidthStyled(clean_seg, style);
                                if (seg_width + hyphen_width <= line_width + 0.01) {
                                    best_break_offset = bp.offset;
                                } else {
                                    break; // Break points are ordered, no point checking further
                                }
                            }

                            if (best_break_offset) |break_offset| {
                                // Render prefix + hyphen on this line
                                const prefix = span.text[remaining_start..break_offset];
                                var prefix_buf: [512]u8 = undefined;
                                const clean_prefix = stripSoftHyphensTo(prefix, &prefix_buf);
                                const prefix_width = self.getTextWidthStyled(clean_prefix, style);

                                const y_pos = valignBaseline(region, line_height, fm, render_opts.valign);
                                const x_pos = region.x + region.padding.left;
                                _ = try self.writeAt(.{ .x = x_pos, .y = y_pos }, clean_prefix, render_style, .{});
                                _ = try self.writeAt(.{ .x = x_pos + prefix_width, .y = y_pos }, "-", render_style, .{});

                                region.newLine(line_height);
                                lines_written += 1;

                                // Move to after the soft-hyphen (2 bytes for UTF-8)
                                remaining_start = break_offset + 2;
                            } else {
                                // No break point fits, render remaining as-is (will overflow)
                                if (region.remainingHeight() >= line_height) {
                                    const y_pos = valignBaseline(region, line_height, fm, render_opts.valign);
                                    _ = try self.writeAt(.{ .x = region.x + region.padding.left, .y = y_pos }, clean_remaining, render_style, .{});
                                    region.newLine(line_height);
                                    lines_written += 1;
                                }
                                break;
                            }
                        }

                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Try regular hyphen breaking if enabled (only for single-span words)
                if (render_opts.break_on_hyphens and big_word.start_span == big_word.end_span) {
                    const span = text.spans.items[big_word.start_span];
                    const word_text = span.text[big_word.start_offset..big_word.end_offset];

                    if (self.findHyphenBreakStyled(word_text, line_width, style)) |break_pos| {
                        // break_pos is position after the hyphen
                        const prefix = word_text[0..break_pos];
                        const suffix = word_text[break_pos..];

                        // CSS-style .top valign
                        const fm = self.getFontMetricsStyled(style);
                        const y_pos = valignBaseline(region, line_height, fm, render_opts.valign);

                        // Apply span color to style for rendering
                        var render_style = style;
                        render_style.color = span.style.color;
                        render_style.decoration = span.style.decoration;

                        const x_pos = region.x + region.padding.left;
                        _ = try self.writeAt(.{ .x = x_pos, .y = y_pos }, prefix, render_style, .{});

                        region.newLine(line_height);
                        lines_written += 1;

                        // Render suffix on next line
                        if (suffix.len > 0 and region.remainingHeight() >= line_height) {
                            const y_pos2 = valignBaseline(region, line_height, fm, render_opts.valign);
                            _ = try self.writeAt(.{ .x = region.x + region.padding.left, .y = y_pos2 }, suffix, render_style, .{});
                            region.newLine(line_height);
                            lines_written += 1;
                        }

                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Last resort: character-level breaking (only for single-span words)
                // Loop until entire word is consumed
                if (big_word.start_span == big_word.end_span) {
                    const span = text.spans.items[big_word.start_span];
                    var remaining_text = span.text[big_word.start_offset..big_word.end_offset];
                    // CSS-style .top valign
                    const fm = self.getFontMetricsStyled(style);
                    var did_break = false;

                    // Apply span color to style for rendering
                    var render_style = style;
                    render_style.color = span.style.color;
                    render_style.decoration = span.style.decoration;

                    while (remaining_text.len > 0 and region.remainingHeight() >= line_height) {
                        const y_pos = valignBaseline(region, line_height, fm, render_opts.valign);
                        const x_pos = region.x + region.padding.left;

                        // Check if remaining text fits on line
                        const remaining_width = self.getTextWidthStyled(remaining_text, style);
                        if (remaining_width <= line_width + 0.01) {
                            // Fits - render it and we're done
                            _ = try self.writeAt(.{ .x = x_pos, .y = y_pos }, remaining_text, render_style, .{});
                            region.newLine(line_height);
                            lines_written += 1;
                            did_break = true;
                            break;
                        }

                        // Doesn't fit - find break point
                        if (self.findCharacterBreakStyled(remaining_text, line_width, style)) |break_pos| {
                            const prefix = remaining_text[0..break_pos];
                            _ = try self.writeAt(.{ .x = x_pos, .y = y_pos }, prefix, render_style, .{});
                            region.newLine(line_height);
                            lines_written += 1;
                            remaining_text = remaining_text[break_pos..];
                            did_break = true;
                        } else {
                            // Can't break (shouldn't happen) - render what we can
                            _ = try self.writeAt(.{ .x = x_pos, .y = y_pos }, remaining_text, render_style, .{});
                            region.newLine(line_height);
                            lines_written += 1;
                            did_break = true;
                            break;
                        }
                    }

                    if (did_break) {
                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // No break point found - include oversized word as-is
                line_end = line_start + 1;
                current_width = big_word.width;
            }

            // Determine alignment
            const is_last_line = (line_end >= n);
            const has_force_break = line_end > 0 and text.words.items[line_end - 1].force_break;
            const line_alignment = if (render_opts.alignment == .justify and (is_last_line or has_force_break))
                Align.left
            else
                render_opts.alignment;

            // Render the line (or just advance cursor if measure_only)
            if (render_opts.measure_only) {
                region.cursor_y += line_height;
            } else {
                try self.renderStyledLine(region, text, style, line_start, line_end, line_alignment, render_opts.valign, line_height, line_width, space_width, current_width);
            }
            lines_written += 1;

            word_idx = line_end;
        }

        // Restore cursor if measure_only (measurement should be side-effect free)
        if (opts.measure_only) {
            region.cursor_x = saved_cursor_x;
            region.cursor_y = saved_cursor_y;
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Count styled lines with explicit style (for styled valign calculation).
    fn countStyledLinesStyled(self: *Document, text: *const StyledText, base_style: TextStyle, line_width: f64, space_width: f64) usize {
        const n = text.words.items.len;
        if (n == 0) return 0;

        var line_count: usize = 0;
        var word_idx: usize = 0;

        while (word_idx < n) {
            var current_width: f64 = 0;
            const line_start = word_idx;
            var line_end = word_idx;

            // Greedy: fill line with as many words as fit
            while (line_end < n) {
                const word = text.words.items[line_end];
                const word_with_space = if (line_end > line_start) word.width + space_width else word.width;

                if (current_width + word_with_space > line_width + 0.01) break;

                current_width += word_with_space;
                line_end += 1;

                if (word.force_break) break;
            }

            // Handle word that doesn't fit - check for soft-hyphen break
            if (line_end == line_start and line_start < n) {
                const big_word = text.words.items[line_start];
                if (big_word.break_points) |break_points| {
                    const hyphen_width = self.getTextWidthStyled("-", base_style);

                    // Count actual lines needed for recursive soft-hyphen breaking
                    const span = text.spans.items[big_word.start_span];
                    var remaining_start: u16 = big_word.start_offset;
                    var soft_hyphen_lines: usize = 0;

                    while (remaining_start < big_word.end_offset) {
                        const remaining = span.text[remaining_start..big_word.end_offset];
                        var remaining_buf: [512]u8 = undefined;
                        const clean_remaining = stripSoftHyphensTo(remaining, &remaining_buf);
                        const remaining_width = self.getTextWidthStyled(clean_remaining, base_style);

                        // If remaining fits on one line, count it and we're done
                        if (remaining_width <= line_width + 0.01) {
                            soft_hyphen_lines += 1;
                            break;
                        }

                        // Find best break point that fits
                        var best_break_offset: ?u16 = null;
                        for (break_points) |bp| {
                            if (bp.offset <= remaining_start) continue;
                            const segment = span.text[remaining_start..bp.offset];
                            var seg_buf: [512]u8 = undefined;
                            const clean_seg = stripSoftHyphensTo(segment, &seg_buf);
                            const seg_width = self.getTextWidthStyled(clean_seg, base_style);
                            if (seg_width + hyphen_width <= line_width + 0.01) {
                                best_break_offset = bp.offset;
                            } else {
                                break;
                            }
                        }

                        if (best_break_offset) |break_offset| {
                            soft_hyphen_lines += 1;
                            remaining_start = break_offset + 2;
                        } else {
                            // No break fits, count remaining as one line
                            soft_hyphen_lines += 1;
                            break;
                        }
                    }

                    if (soft_hyphen_lines > 0) {
                        line_count += soft_hyphen_lines;
                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Count character-level breaking lines (for words without soft-hyphens)
                if (big_word.start_span == big_word.end_span) {
                    const span = text.spans.items[big_word.start_span];
                    var remaining_text = span.text[big_word.start_offset..big_word.end_offset];
                    var char_break_lines: usize = 0;

                    while (remaining_text.len > 0) {
                        const remaining_width = self.getTextWidthStyled(remaining_text, base_style);
                        if (remaining_width <= line_width + 0.01) {
                            char_break_lines += 1;
                            break;
                        }
                        if (self.findCharacterBreakStyled(remaining_text, line_width, base_style)) |break_pos| {
                            char_break_lines += 1;
                            remaining_text = remaining_text[break_pos..];
                        } else {
                            char_break_lines += 1;
                            break;
                        }
                    }

                    if (char_break_lines > 0) {
                        line_count += char_break_lines;
                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Word doesn't fit at all - still takes a line
                line_end = line_start + 1;
            }

            line_count += 1;
            word_idx = line_end;
        }

        return line_count;
    }

    /// Render a single line of styled text.
    fn renderStyledLine(
        self: *Document,
        region: *Region,
        text: *const StyledText,
        base_style: TextStyle,
        line_start: usize,
        line_end: usize,
        alignment: Align,
        valign: VAlign,
        line_height: f64,
        line_width: f64,
        space_width: f64,
        content_width: f64,
    ) !void {
        const font_metrics = self.getFontMetricsStyled(base_style);
        const cap_height = font_metrics.cap_height;
        const ascender = font_metrics.ascender;
        const descender = @abs(font_metrics.descender);
        const font_size = base_style.size; // needed for decoration scaling

        // Calculate x offset based on alignment
        const slack = line_width - content_width;
        const x_offset: f64 = switch (alignment) {
            .left => 0,
            .center => slack / 2,
            .right => slack,
            .justify => 0,
        };

        // Calculate word spacing for justify
        const word_count = line_end - line_start;
        const extra_word_spacing = if (alignment == .justify and word_count > 1)
            slack / @as(f64, @floatFromInt(word_count - 1))
        else
            0;

        // Calculate y position based on valign
        const base = region.y + region.padding.top + region.cursor_y;
        const y_pos = switch (valign) {
            .top => base + cap_height,
            .top_ascent => base + ascender,
            .top_leading => base + (line_height + ascender - descender) / 2,
            .middle => base + line_height / 2 + cap_height / 2,
            .bottom => base + line_height,
        };

        const x_start = region.x + region.padding.left + x_offset;

        // Fast path: check if entire line is single-span with no decoration
        // This allows rendering as one string with word_spacing
        const first_word = text.words.items[line_start];
        const first_span = text.spans.items[first_word.start_span];
        var is_single_style = first_word.start_span == first_word.end_span and
            !first_span.style.decoration.underline and
            !first_span.style.decoration.strikethrough;

        if (is_single_style and line_end > line_start + 1) {
            // Check all words have same span
            for (line_start + 1..line_end) |word_idx| {
                const w = text.words.items[word_idx];
                if (w.start_span != first_word.start_span or w.end_span != first_word.start_span) {
                    is_single_style = false;
                    break;
                }
            }
        }

        if (is_single_style) {
            // Single style - render entire line as one string
            const last_word = text.words.items[line_end - 1];
            const line_text = first_span.text[first_word.start_offset..last_word.end_offset];

            // Apply span color to base style
            var render_style = base_style;
            render_style.color = first_span.style.color;
            render_style.decoration = first_span.style.decoration;
            try self.writeWithWordSpacingStyled(x_start, y_pos, line_text, extra_word_spacing, render_style);

            region.cursor_y += line_height;
            return;
        }

        // Multi-style path: render segments with style tracking
        var current_x = x_start;
        const actual_space_width = space_width + extra_word_spacing;

        // Track decoration runs for continuous underlines/strikethroughs
        const DecoRun = struct {
            start_x: f64,
            end_x: f64,
            color: ?Color,
            underline: bool,
            strikethrough: bool,
        };
        var deco_runs: [64]DecoRun = undefined;
        var deco_count: usize = 0;

        // Current decoration state
        var in_underline = false;
        var in_strikethrough = false;
        var deco_start_x: f64 = 0;
        var deco_color: ?Color = null;

        // Helper to end current decoration run
        const endDecoRun = struct {
            fn call(runs: *[64]DecoRun, count: *usize, start_x: f64, end_x: f64, run_color: ?Color, underline: bool, strikethrough: bool) void {
                if (count.* < 64 and (underline or strikethrough)) {
                    runs[count.*] = .{
                        .start_x = start_x,
                        .end_x = end_x,
                        .color = run_color,
                        .underline = underline,
                        .strikethrough = strikethrough,
                    };
                    count.* += 1;
                }
            }
        }.call;

        // Render each word
        for (line_start..line_end) |word_idx| {
            const word = text.words.items[word_idx];

            // Add space before word (except first)
            if (word_idx > line_start) {
                current_x += actual_space_width;
            }

            // Render word segments (may span multiple styles)
            var span_idx = word.start_span;
            while (span_idx <= word.end_span) : (span_idx += 1) {
                const span = text.spans.items[span_idx];
                const seg_start: usize = if (span_idx == word.start_span) word.start_offset else 0;
                const seg_end: usize = if (span_idx == word.end_span) word.end_offset else span.text.len;

                if (seg_end > seg_start) {
                    const segment = span.text[seg_start..seg_end];
                    const seg_underline = span.style.decoration.underline;
                    const seg_strike = span.style.decoration.strikethrough;

                    // Check if decoration state changed
                    if (seg_underline != in_underline or seg_strike != in_strikethrough) {
                        // End previous run if any
                        if (in_underline or in_strikethrough) {
                            endDecoRun(&deco_runs, &deco_count, deco_start_x, current_x, deco_color, in_underline, in_strikethrough);
                        }
                        // Start new run if needed
                        if (seg_underline or seg_strike) {
                            deco_start_x = current_x;
                            deco_color = span.style.color;
                        }
                        in_underline = seg_underline;
                        in_strikethrough = seg_strike;
                    }

                    // Apply span style to base style (no decoration - handled separately)
                    var render_style = base_style;
                    render_style.color = span.style.color;
                    render_style.decoration = .none; // Don't draw per-segment

                    // Get segment width and render using writeAt
                    const seg_width = self.getTextWidthStyled(segment, base_style);
                    _ = try self.writeAt(.{ .x = current_x, .y = y_pos }, segment, render_style, .{});
                    current_x += seg_width;
                }
            }
        }

        // End any remaining decoration run
        if (in_underline or in_strikethrough) {
            endDecoRun(&deco_runs, &deco_count, deco_start_x, current_x, deco_color, in_underline, in_strikethrough);
        }

        // Draw all decoration runs as raw commands
        if (deco_count > 0) {
            var page = &self.pages.items[self.current_page];
            const page_alloc = page.pageAllocator();

            // Get decoration metrics (scale from 1000 units)
            const scale = font_size / 1000.0;
            var underline_pos: f64 = -100;
            var underline_thick: f64 = 50;
            var strikeout_pos: f64 = 250;
            var strikeout_thick: f64 = 50;

            if (base_style.embeddedFont()) |emb| {
                underline_pos = @floatFromInt(emb.underline_position);
                underline_thick = @floatFromInt(emb.underline_thickness);
                strikeout_pos = @floatFromInt(emb.strikeout_position);
                strikeout_thick = @floatFromInt(emb.strikeout_size);
            }

            for (deco_runs[0..deco_count]) |run| {
                const width = run.end_x - run.start_x;
                if (width > 0) {
                    var buf: [512]u8 = undefined;
                    var len: usize = 0;

                    // Save graphics state and set color
                    const q_str = "q\n";
                    @memcpy(buf[len..][0..q_str.len], q_str);
                    len += q_str.len;

                    if (run.color) |c| {
                        const rgb = c.toRgbf();
                        const r_str = format.writeF64_3(buf[len..], rgb.r);
                        len += r_str.len;
                        buf[len] = ' ';
                        len += 1;
                        const g_str = format.writeF64_3(buf[len..], rgb.g);
                        len += g_str.len;
                        buf[len] = ' ';
                        len += 1;
                        const b_str = format.writeF64_3(buf[len..], rgb.b);
                        len += b_str.len;
                        @memcpy(buf[len..][0..4], " rg\n");
                        len += 4;
                    } else {
                        const g_str = "0.000 g\n";
                        @memcpy(buf[len..][0..g_str.len], g_str);
                        len += g_str.len;
                    }

                    // Draw underline
                    if (run.underline) {
                        const ul_y = self.currentPageSize().height - y_pos + underline_pos * scale;
                        const h = underline_thick * scale;
                        len += format.writeCoord4Suffix(buf[len..], run.start_x, ul_y, width, -h, " re f\n");
                    }

                    // Draw strikethrough
                    if (run.strikethrough) {
                        const st_y = self.currentPageSize().height - y_pos + strikeout_pos * scale;
                        const h = strikeout_thick * scale;
                        len += format.writeCoord4Suffix(buf[len..], run.start_x, st_y, width, -h, " re f\n");
                    }

                    // Restore graphics state
                    const Q_str = "Q\n";
                    @memcpy(buf[len..][0..Q_str.len], Q_str);
                    len += Q_str.len;

                    const raw_copy = try page_alloc.dupe(u8, buf[0..len]);
                    try page.commands.append(self.allocator, .{ .raw = raw_copy });
                }
            }
        }

        // Advance cursor
        region.cursor_y += line_height;
    }

    /// Write styled text using optimal (Knuth-Plass) line breaking.
    fn writeStyledOptimal(
        self: *Document,
        region: *Region,
        text: *StyledText,
        style: TextStyle,
        opts: ParagraphOptions,
        line_height: f64,
        space_width: f64,
        line_width: f64,
        start_cursor_y: f64,
    ) !WriteResult {
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();

        // Compute optimal break points using preprocessed word data
        const breaks = try text.computeOptimalBreaks(line_width, space_width);
        defer self.allocator.free(breaks);

        if (breaks.len == 0) {
            return .{ .lines_written = 0, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = 0 } };
        }

        var lines_written: usize = 0;
        var line_start: usize = 0;

        for (breaks, 0..) |line_end, line_idx| {
            // Check if we have room
            if (region.remainingHeight() < line_height) {
                return .{
                    .lines_written = lines_written,
                    .overflow = text.getTextFromWord(line_start),
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Calculate line content width
            var content_width: f64 = 0;
            for (line_start..line_end) |w| {
                if (w > line_start) content_width += space_width;
                content_width += text.words.items[w].width;
            }

            // Determine alignment
            const is_last_line = (line_idx == breaks.len - 1);
            const has_force_break = line_end > 0 and text.words.items[line_end - 1].force_break;
            const line_alignment = if (opts.alignment == .justify and (is_last_line or has_force_break))
                Align.left
            else
                opts.alignment;

            // Render the line (or just advance cursor if measure_only)
            if (opts.measure_only) {
                region.cursor_y += line_height;
            } else {
                try self.renderStyledLine(region, text, style, line_start, line_end, line_alignment, opts.valign, line_height, line_width, space_width, content_width);
            }
            lines_written += 1;
            line_start = line_end;
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Draw a path with the specified style.
    /// Coordinates are from top-left origin.
    /// Draw a path with the given style.
    // ========================================================================
    // Graphics state: transforms and clipping
    // ========================================================================

    /// 2D affine transform in row-vector convention: (x, y, 1) * M.
    const Affine = struct {
        a: f64,
        b: f64,
        c: f64,
        d: f64,
        e: f64,
        f: f64,

        const identity = Affine{ .a = 1, .b = 0, .c = 0, .d = 1, .e = 0, .f = 0 };

        /// Apply `m` first, then `n` (row-vector product m * n).
        fn concat(m: Affine, n: Affine) Affine {
            return .{
                .a = m.a * n.a + m.b * n.c,
                .b = m.a * n.b + m.b * n.d,
                .c = m.c * n.a + m.d * n.c,
                .d = m.c * n.b + m.d * n.d,
                .e = m.e * n.a + m.f * n.c + n.e,
                .f = m.e * n.b + m.f * n.d + n.f,
            };
        }
    };

    /// Append raw content-stream bytes as a deferred command.
    fn appendRawCommand(self: *Document, content: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.current_page];
        const copy = try page.pageAllocator().dupe(u8, content);
        try page.commands.append(self.allocator, .{ .raw = copy });
    }

    /// Emit a user-space affine transform as a PDF `cm` operator. The
    /// content stream works in PDF coordinates (bottom-left origin), so the
    /// user-space transform is conjugated with the y-flip: M = F * T * F.
    fn applyTransform(self: *Document, t_user: Affine) !void {
        const h = self.currentPageSize().height;
        const flip = Affine{ .a = 1, .b = 0, .c = 0, .d = -1, .e = 0, .f = h };
        const m = flip.concat(t_user).concat(flip);
        var buf: [128]u8 = undefined;
        const ops = std.fmt.bufPrint(&buf, "{d:.4} {d:.4} {d:.4} {d:.4} {d:.2} {d:.2} cm\n", .{ m.a, m.b, m.c, m.d, m.e, m.f }) catch unreachable;
        try self.appendRawCommand(ops);
    }

    /// Save the graphics state (current transform and clip). Every pushState
    /// must be balanced by a popState on the same page before output().
    pub fn pushState(self: *Document) !void {
        try self.appendRawCommand("q\n");
        self.pages.items[self.current_page].state_depth += 1;
    }

    /// Restore the most recently pushed graphics state.
    pub fn popState(self: *Document) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.current_page];
        if (page.state_depth == 0) return error.UnbalancedGraphicsState;
        try self.appendRawCommand("Q\n");
        page.state_depth -= 1;
    }

    /// Translate subsequent content by (dx, dy) in user space (y down).
    /// Transforms compose in call order like Canvas/Cairo: later calls apply
    /// closest to the drawn geometry. Scope with pushState/popState.
    pub fn translate(self: *Document, dx: f64, dy: f64) !void {
        try self.applyTransform(.{ .a = 1, .b = 0, .c = 0, .d = 1, .e = dx, .f = dy });
    }

    /// Rotate subsequent content by `degrees` around `center` (user space).
    /// Positive angles rotate clockwise on the page, matching CSS/Canvas
    /// convention for y-down coordinates.
    pub fn rotateAt(self: *Document, center: Point, degrees: f64) !void {
        const rad = degrees * std.math.pi / 180.0;
        const cos = @cos(rad);
        const sin = @sin(rad);
        const to_origin = Affine{ .a = 1, .b = 0, .c = 0, .d = 1, .e = -center.x, .f = -center.y };
        const rot = Affine{ .a = cos, .b = sin, .c = -sin, .d = cos, .e = 0, .f = 0 };
        const back = Affine{ .a = 1, .b = 0, .c = 0, .d = 1, .e = center.x, .f = center.y };
        try self.applyTransform(to_origin.concat(rot).concat(back));
    }

    /// Scale subsequent content by (sx, sy) around `center` (user space).
    pub fn scaleAt(self: *Document, center: Point, sx: f64, sy: f64) !void {
        const to_origin = Affine{ .a = 1, .b = 0, .c = 0, .d = 1, .e = -center.x, .f = -center.y };
        const sc = Affine{ .a = sx, .b = 0, .c = 0, .d = sy, .e = 0, .f = 0 };
        const back = Affine{ .a = 1, .b = 0, .c = 0, .d = 1, .e = center.x, .f = center.y };
        try self.applyTransform(to_origin.concat(sc).concat(back));
    }

    /// Clip subsequent content to a rectangle (user space, y = top edge).
    /// The clip lasts until the enclosing pushState is popped.
    pub fn clipRect(self: *Document, rect: Rect) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        const pdf_y = self.currentPageSize().height - rect.y - rect.height;
        var buf: [96]u8 = undefined;
        const ops = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} {d:.2} {d:.2} re W n\n", .{ rect.x, pdf_y, rect.width, rect.height }) catch unreachable;
        try self.appendRawCommand(ops);
    }

    /// Clip subsequent content to a path (non-zero winding rule).
    /// The clip lasts until the enclosing pushState is popped.
    pub fn clipPath(self: *Document, p: *const Path) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (p.isEmpty()) return;
        var page = &self.pages.items[self.current_page];
        const buf = try page.pageAllocator().alloc(u8, 64 + p.commands.items.len * 64);
        var fbs = std.Io.Writer.fixed(buf);
        try p.toPdfContent(self.currentPageSize().height, &fbs);
        var len = fbs.end;
        const tail = "W n\n";
        @memcpy(buf[len..][0..tail.len], tail);
        len += tail.len;
        try page.commands.append(self.allocator, .{ .raw = buf[0..len] });
    }

    pub fn drawPath(self: *Document, p: *const Path, style: ShapeStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (p.isEmpty()) return;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Estimate buffer size: ~60 bytes per command + overhead
        const buf_size = 256 + p.commands.items.len * 64;
        const buf = try page.pageAllocator().alloc(u8, buf_size);

        var len = beginShapeCommand(buf, style);
        len += try self.writeOpacityRef(page, style, buf[len..]);

        // Path commands (use fixedBufferStream for writer interface)
        var fbs = std.Io.Writer.fixed(buf[len..]);
        try p.toPdfContent(page_height, &fbs);
        len += fbs.end;

        len += finishShapeCommand(buf[len..], style);
        try page.commands.append(self.allocator, .{ .raw = buf[0..len] });
    }

    /// Add a linear gradient to the document and return its index.
    pub fn addLinearGradient(self: *Document, grad: LinearGradient) !usize {
        const idx = self.gradients.items.len;
        try self.gradients.append(self.allocator, .{ .linear = grad });
        return idx;
    }

    /// Add a radial gradient to the document and return its index.
    pub fn addRadialGradient(self: *Document, grad: RadialGradient) !usize {
        const idx = self.gradients.items.len;
        try self.gradients.append(self.allocator, .{ .radial = grad });
        return idx;
    }

    /// Fill a rectangle with a gradient.
    /// The gradient index must have been obtained from addLinearGradient or addRadialGradient.
    pub fn fillRectGradient(self: *Document, rect: Rect, gradient_idx: usize) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (gradient_idx >= self.gradients.items.len) return error.InvalidGradient;

        var page = &self.pages.items[self.current_page];
        const page_height = self.currentPageSize().height;

        // Track that this page uses gradients
        try page.used_gradients.put(self.allocator, gradient_idx, {});

        // Convert from top-left to PDF coordinates
        const pdf_y = page_height - rect.y - rect.height;

        var buf: [256]u8 = undefined;
        var len: usize = 0;

        // Save graphics state, set clip path, paint shading, restore
        @memcpy(buf[len..][0..2], "q\n");
        len += 2;
        len += format.writeCoord4Suffix(buf[len..], rect.x, pdf_y, rect.width, rect.height, " re W n\n");
        len += (std.fmt.bufPrint(buf[len..], "/{s} sh\n", .{shadingResourceName(gradient_idx)}) catch unreachable).len;
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Render deferred commands to page content bytes
    /// Called after subsetting so glyph IDs are properly remapped
    fn renderPageCommands(self: *Document, page: *Page) !void {
        var cw = page.writer(self.allocator);

        for (page.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| {
                    // Apply fill (non-stroking) opacity via ExtGState if not fully opaque.
                    // Wrap the whole text object (and its decorations) in q/Q so the
                    // alpha does not leak into subsequent content.
                    const opacity_gs: ?usize = if (t.opacity < 1.0)
                        try page.getOrAddOpacityState(self.allocator, t.opacity, 1.0)
                    else
                        null;
                    if (opacity_gs) |idx| {
                        try cw.append("q\n");
                        var gs_buf: [16]u8 = undefined;
                        const gs_len = graphics.writeExtGStateRef(&gs_buf, idx);
                        try cw.append(gs_buf[0..gs_len]);
                    }

                    // Begin text block
                    try cw.append("BT\n");
                    // Set text color
                    try t.text_color.writeFill(&cw);

                    switch (t.font) {
                        .embedded => |emb| {
                            const idx = self.getEmbeddedFontIndex(emb) orelse continue;

                            // COLR color path: this font has a Type3 plan and
                            // this run actually contains ≥1 color glyph.
                            const color_run: ?*ColorFontPlan = blk: {
                                if (emb.encoding != .identity) break :blk null;
                                const plan = color_fonts.colorPlanFor(self, emb) orelse break :blk null;
                                const glyphs = t.cached_glyphs orelse break :blk null;
                                for (glyphs) |g| {
                                    if (plan.slotFor(g) != null) break :blk plan;
                                }
                                break :blk null;
                            };

                            if (color_run) |plan| {
                                if (t.char_spacing != 0) {
                                    try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                                }
                                try cw.print("{d:.2} Tw\n", .{t.word_spacing});
                                try color_fonts.renderColorText(&cw, emb, plan, t.cached_glyphs.?, t.font_size, t.x, t.y);
                            } else {
                                try cw.print("/E{d} {d:.2} Tf\n", .{ idx + 1, t.font_size });

                                if (t.char_spacing != 0) {
                                    try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                                }
                                // Always emit Tw to ensure correct word spacing (state persists across text blocks)
                                try cw.print("{d:.2} Tw\n", .{t.word_spacing});

                                if (emb.encoding == .identity) {
                                    // CID mode: output with ligatures, kerning, and mark positioning
                                    // Pass absolute position for Tm-based mark positioning
                                    // Use cached glyphs if available (avoids duplicate OpenType shaping)
                                    _ = try text_render.renderCIDTextWithKerning(&cw, emb, t.text_data, t.cached_glyphs, t.font_size, t.x, t.y);
                                } else {
                                    try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
                                    // WinAnsi mode
                                    try cw.append("(");
                                    try cw.appendEscaped(t.text_data);
                                    try cw.append(") Tj\n");
                                }
                            }
                        },
                        .standard => |font| {
                            try cw.print("/{s} {d:.2} Tf\n", .{ fontResourceName(font), t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }
                            // Always emit Tw to ensure correct word spacing (state persists across text blocks)
                            try cw.print("{d:.2} Tw\n", .{t.word_spacing});

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
                            try cw.append("(");
                            try cw.appendEscaped(t.text_data);
                            try cw.append(") Tj\n");
                        },
                    }

                    try cw.append("ET\n");

                    // Draw text decorations (underline/strikethrough)
                    // These must be outside the text block (BT/ET)
                    if (t.underline or t.strikethrough) {
                        try self.drawTextDecorations(&cw, &t);
                    }

                    // Restore graphics state if we applied an opacity ExtGState.
                    if (opacity_gs != null) {
                        try cw.append("Q\n");
                    }
                },
                .raw => |data| {
                    try cw.append(data);
                },
            }
        }
    }

    /// Draw underline and/or strikethrough decorations for text.
    /// Called after text is rendered, outside the BT/ET block.
    fn drawTextDecorations(self: *Document, cw: *ContentWriter, t: *const TextCommand) !void {
        _ = self;
        // Get decoration metrics based on font type
        var underline_pos: f64 = -100; // Default in 1000 units
        var underline_thick: f64 = 50;
        var strikeout_pos: f64 = 250;
        var strikeout_thick: f64 = 50;

        switch (t.font) {
            .embedded => |emb| {
                underline_pos = @floatFromInt(emb.underline_position);
                underline_thick = @floatFromInt(emb.underline_thickness);
                strikeout_pos = @floatFromInt(emb.strikeout_position);
                strikeout_thick = @floatFromInt(emb.strikeout_size);
            },
            .standard => {
                // Standard fonts use fixed decoration metrics (from fpdf2)
                underline_pos = -100;
                underline_thick = 50;
                strikeout_pos = 250;
                strikeout_thick = 50;
            },
        }

        // Scale from 1000 units to points
        const scale = t.font_size / 1000.0;
        const x = t.x;
        const w = t.text_width;

        // Save graphics state, set stroke color to text color
        try cw.append("q\n");
        try t.text_color.writeFill(cw);

        if (t.underline) {
            // Position: baseline + underline_position (negative = below)
            const y = t.y + underline_pos * scale;
            const h = underline_thick * scale;
            // PDF rectangle: x y width height re f (filled)
            try cw.print("{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ x, y, w, -h });
        }

        if (t.strikethrough) {
            // Position: baseline + strikeout_position (positive = above)
            const y = t.y + strikeout_pos * scale;
            const h = strikeout_thick * scale;
            // PDF rectangle with negative height extends downward
            try cw.print("{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ x, y, w, -h });
        }

        // Restore graphics state
        try cw.append("Q\n");
    }

    /// Output timing information for performance analysis.
    pub const OutputTiming = pdf_output.OutputTiming;

    /// Generate PDF output
    pub fn output(self: *Document) ![]u8 {
        self.last_output_timing = .{};

        var w = Writer.init(self.allocator);
        w.compression_level = self.compression_level;
        defer w.deinit();

        // Pre-pass: plan COLR color-font (Type3) emission before reserving IDs.
        try color_fonts.buildColorFontPlans(self);
        defer color_fonts.clearColorPlans(self);

        var ids = try self.reserveObjectIds();
        defer ids.deinit(self.allocator);

        try w.writeHeader();
        try self.writeCatalog(&w, &ids);
        try self.writePagesRoot(&w, &ids);
        try self.writePdfaObjects(&w, &ids);
        try self.writeStandardFonts(&w, &ids);
        try self.subsetFontsAndRenderPages();

        // Optionally compress page-content and font-subset streams on worker
        // threads; the writer then picks up the results instead of
        // compressing inline. Output bytes are identical either way.
        var precompressed = std.AutoHashMapUnmanaged(usize, []const u8).empty;
        defer {
            var it = precompressed.valueIterator();
            while (it.next()) |v| self.allocator.free(@constCast(v.*));
            precompressed.deinit(self.allocator);
        }
        if (self.compress_threads > 1 and self.compression_level > 0) {
            try self.precompressStreams(&precompressed);
            w.precompressed = &precompressed;
        }

        try self.writeEmbeddedFonts(&w, &ids);

        // Write COLR Type3 color-font objects (font dict + CharProc streams)
        for (self.color_plans.items) |plan| {
            try color_fonts.writeColorFont(self, &w, plan);
        }

        try self.writeImages(&w, &ids);
        try self.writeSvgs(&w, &ids);
        const next_id = try self.writePages(&w, &ids);
        const info_id = try self.writeInfoDict(&w, next_id);
        try self.writeOutlines(&w, &ids);
        try self.writePageLabels(&w, &ids);
        return self.finishDocument(&w, &ids, info_id);
    }

    /// Object IDs reserved for one `output()` run, in emission order.
    /// Fixed slots: 1 = catalog, 2 = pages root, 3+ = standard fonts.
    const OutputIds = struct {
        catalog_id: ObjectId = 1,
        pages_root_id: ObjectId = 2,
        first_std_font_id: ObjectId = 3,
        font_list: std.ArrayListUnmanaged(StandardFont) = .empty, // used standard fonts
        emb_font_base_ids: std.ArrayListUnmanaged(ObjectId) = .empty,
        image_base_ids: std.ArrayListUnmanaged(ObjectId) = .empty,
        image_smask_ids: std.ArrayListUnmanaged(?ObjectId) = .empty,
        image_icc_ids: std.ArrayListUnmanaged(?ObjectId) = .empty,
        svg_base_ids: std.ArrayListUnmanaged(ObjectId) = .empty,
        outlines_root_id: ?ObjectId = null,
        page_labels_id: ?ObjectId = null,
        pdfa_metadata_id: ?ObjectId = null,
        pdfa_output_intent_id: ?ObjectId = null,
        pdfa_icc_profile_id: ?ObjectId = null,
        first_page_id: ObjectId = 0,

        fn deinit(self: *OutputIds, allocator: std.mem.Allocator) void {
            self.font_list.deinit(allocator);
            self.emb_font_base_ids.deinit(allocator);
            self.image_base_ids.deinit(allocator);
            self.image_smask_ids.deinit(allocator);
            self.image_icc_ids.deinit(allocator);
            self.svg_base_ids.deinit(allocator);
        }
    };

    /// Reserve object IDs for everything the document will emit. Also assigns
    /// outline item IDs and color-font plan IDs in place. Must run after
    /// buildColorFontPlans.
    fn reserveObjectIds(self: *Document) !OutputIds {
        var ids: OutputIds = .{};
        errdefer ids.deinit(self.allocator);

        // Build list of used standard fonts
        var font_iter = self.used_fonts.keyIterator();
        while (font_iter.next()) |font| {
            try ids.font_list.append(self.allocator, font.*);
        }
        var next_id: ObjectId = ids.first_std_font_id + @as(ObjectId, @intCast(ids.font_list.items.len));

        // Reserve IDs for embedded fonts
        // CID fonts need: Type0 + CIDFont + FontDescriptor + FontFile + ToUnicode = 5 objects
        // WinAnsi fonts need: Font + FontDescriptor + FontFile + ToUnicode = 4 objects
        for (self.embedded_fonts.items) |emb_font| {
            try ids.emb_font_base_ids.append(self.allocator, next_id);
            if (emb_font.encoding == .identity) {
                next_id += 5; // CID font objects
            } else {
                next_id += 4; // WinAnsi font objects
            }
        }

        // Reserve IDs for COLR Type3 color fonts.
        next_id = try color_fonts.reserveIds(self, next_id);

        // Reserve IDs for images
        // Each image needs: XObject stream (1 object)
        // PNG with alpha needs: +1 for SMask stream
        // Images with ICC profile need: +1 for ICC profile stream
        for (self.loaded_images.items) |image| {
            try ids.image_base_ids.append(self.allocator, next_id);
            next_id += 1;
            if (image.alpha_data != null) {
                try ids.image_smask_ids.append(self.allocator, next_id);
                next_id += 1;
            } else {
                try ids.image_smask_ids.append(self.allocator, null);
            }
            if (image.icc_profile != null) {
                try ids.image_icc_ids.append(self.allocator, next_id);
                next_id += 1;
            } else {
                try ids.image_icc_ids.append(self.allocator, null);
            }
        }

        // Reserve IDs for SVGs (Form XObjects - 1 object each)
        for (self.loaded_svgs.items) |_| {
            try ids.svg_base_ids.append(self.allocator, next_id);
            next_id += 1;
        }

        // Reserve IDs for outlines (1 root + N items)
        if (self.outline) |*o| {
            if (o.items.items.len > 0) {
                ids.outlines_root_id = next_id;
                next_id += 1; // root object
                // Assign object IDs to each outline item
                for (o.items.items) |item| {
                    item.object_id = next_id;
                    next_id += 1;
                }
            }
        }

        // Reserve ID for page labels (1 object with number tree)
        if (self.page_labels.items.len > 0) {
            ids.page_labels_id = next_id;
            next_id += 1;
        }

        // Reserve IDs for PDF/A structures (XMP metadata, OutputIntent, ICC profile)
        if (self.conformance != .none) {
            ids.pdfa_metadata_id = next_id;
            next_id += 1;
            ids.pdfa_output_intent_id = next_id;
            next_id += 1;
            ids.pdfa_icc_profile_id = next_id;
            next_id += 1;
        }

        ids.first_page_id = next_id;
        return ids;
    }

    /// Write the document catalog (object 1) with outline/page-label/PDF-A
    /// references.
    fn writeCatalog(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        try w.beginObject(ids.catalog_id);
        var catalog_dict = Dict.init(self.allocator);
        defer catalog_dict.deinit();
        // PDF/A sub-structures (declared here to stay in scope until writeDict)
        var output_intents = Array.init(self.allocator);
        defer output_intents.deinit();
        var mark_info = Dict.init(self.allocator);
        defer mark_info.deinit();

        try catalog_dict.put("Type", Value.name("Catalog"));
        try catalog_dict.put("Pages", Value.ref(.{ .id = ids.pages_root_id }));
        if (ids.outlines_root_id) |id| {
            try catalog_dict.put("Outlines", Value.ref(.{ .id = id }));
        }
        if (ids.page_labels_id) |id| {
            try catalog_dict.put("PageLabels", Value.ref(.{ .id = id }));
        }
        // PDF/A entries
        if (ids.pdfa_metadata_id) |id| {
            try catalog_dict.put("Metadata", Value.ref(.{ .id = id }));
        }
        if (ids.pdfa_output_intent_id) |id| {
            // OutputIntents is an array
            try output_intents.append(Value.ref(.{ .id = id }));
            try catalog_dict.put("OutputIntents", .{ .array_val = &output_intents });
        }
        if (self.conformance != .none) {
            // MarkInfo required for PDF/A
            try mark_info.put("Marked", .{ .bool_val = false });
            try catalog_dict.put("MarkInfo", .{ .dict_val = &mark_info });
        }
        try w.writeDict(catalog_dict);
        try w.endObject();
    }

    /// Write the pages root (object 2) with the Kids array.
    fn writePagesRoot(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        try w.beginObject(ids.pages_root_id);
        var pages_dict = Dict.init(self.allocator);
        defer pages_dict.deinit();
        try pages_dict.put("Type", Value.name("Pages"));
        try pages_dict.put("Count", Value.int(@intCast(self.pages.items.len)));

        // Build Kids array (accounting for annotations per page)
        var kids = Array.init(self.allocator);
        defer kids.deinit();
        var page_id = ids.first_page_id;
        for (self.pages.items) |page| {
            try kids.append(Value.ref(.{ .id = page_id }));
            // Each page uses: page dict + content stream + annotation objects
            page_id += 2 + @as(ObjectId, @intCast(page.annotations.items.len));
        }
        try pages_dict.put("Kids", .{ .array_val = &kids });

        try w.writeDict(pages_dict);
        try w.endObject();
    }

    /// Write PDF/A objects (XMP metadata, ICC profile, OutputIntent).
    /// No-op unless a conformance level is set.
    fn writePdfaObjects(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        if (self.conformance != .none) {
            // Generate UUIDs for XMP document/instance IDs (simple pseudo-random)
            var uuid_buf: [32]u8 = undefined;
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            const timestamp: u64 = @as(u64, @intCast(ts.sec)) *% 1000 +% @as(u64, @intCast(ts.nsec)) / 1_000_000;
            _ = std.fmt.bufPrint(&uuid_buf, "{x:0>16}{x:0>16}", .{ timestamp, timestamp ^ 0xDEADBEEF }) catch unreachable;
            const uuid_str = uuid_buf[0..32];

            // 1. XMP Metadata stream
            // Generate ISO 8601 date for XMP (required for PDF/A)
            var iso_date_buf: [21]u8 = undefined;
            const iso_date = pdf_output.formatIsoDate(&iso_date_buf);

            const xmp_data = try pdfa.generateXmpMetadata(self.allocator, .{
                .title = self.metadata.title,
                .author = self.metadata.author,
                .subject = self.metadata.subject,
                .keywords = self.metadata.keywords,
                .creator = self.metadata.creator,
                .producer = self.metadata.producer,
                .conformance = self.conformance,
                .document_id = uuid_str,
                .instance_id = uuid_str,
                .create_date = iso_date,
                .modify_date = iso_date,
            });
            defer self.allocator.free(xmp_data);

            try w.beginObject(ids.pdfa_metadata_id.?);
            var xmp_dict = Dict.init(self.allocator);
            defer xmp_dict.deinit();
            try xmp_dict.put("Type", Value.name("Metadata"));
            try xmp_dict.put("Subtype", Value.name("XML"));
            // XMP metadata must NOT be compressed for PDF/A
            try w.writeStream(&xmp_dict, xmp_data);
            try w.endObject();

            // 2. ICC Profile stream
            try w.beginObject(ids.pdfa_icc_profile_id.?);
            var icc_dict = Dict.init(self.allocator);
            defer icc_dict.deinit();
            try icc_dict.put("N", Value.int(3)); // RGB = 3 components
            try w.writeStreamCompressed(&icc_dict, pdfa.srgb_icc_profile);
            try w.endObject();

            // 3. OutputIntent dictionary
            try w.beginObject(ids.pdfa_output_intent_id.?);
            var intent_dict = Dict.init(self.allocator);
            defer intent_dict.deinit();
            try intent_dict.put("Type", Value.name("OutputIntent"));
            try intent_dict.put("S", Value.name("GTS_PDFA1"));
            try intent_dict.put("OutputConditionIdentifier", Value.string("sRGB IEC61966-2.1"));
            try intent_dict.put("RegistryName", Value.string("http://www.color.org"));
            try intent_dict.put("DestOutputProfile", Value.ref(.{ .id = ids.pdfa_icc_profile_id.? }));
            try w.writeDict(intent_dict);
            try w.endObject();
        }
    }

    /// Write Type1 dictionaries for the used standard fonts.
    fn writeStandardFonts(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        for (ids.font_list.items, 0..) |font, idx| {
            const font_id = ids.first_std_font_id + @as(ObjectId, @intCast(idx));
            try w.beginObject(font_id);
            var font_dict = Dict.init(self.allocator);
            defer font_dict.deinit();
            try font_dict.put("Type", Value.name("Font"));
            try font_dict.put("Subtype", Value.name("Type1"));
            try font_dict.put("BaseFont", Value.name(font.pdfName()));
            try w.writeDict(font_dict);
            try w.endObject();
        }
    }

    /// Generate font subsets (populating gid_remap), then render each page's
    /// deferred commands to content bytes (after subsetting so glyph IDs are
    /// properly remapped).
    fn subsetFontsAndRenderPages(self: *Document) !void {
        const subset_start = pdf_output.milliTimestamp();
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font.generateSubset();
        }
        self.last_output_timing.subset_ms = pdf_output.milliTimestamp() - subset_start;

        // Render deferred commands to content bytes (AFTER subsetting so glyph IDs are remapped)
        const render_start = pdf_output.milliTimestamp();
        for (self.pages.items) |*page| {
            if (page.state_depth != 0) return error.UnbalancedGraphicsState;
            try self.renderPageCommands(page);
        }
        self.last_output_timing.render_ms = pdf_output.milliTimestamp() - render_start;
    }

    const CompressJob = struct {
        data: []const u8,
        result: ?[]const u8 = null,
    };

    fn compressWorker(jobs: []CompressJob, next: *std.atomic.Value(usize), allocator: std.mem.Allocator, level: i32) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= jobs.len) return;
            // A failed job stays null; the writer just compresses it inline
            jobs[i].result = zlib.compressLevel(allocator, jobs[i].data, level) catch null;
        }
    }

    /// Compress page-content and font-subset streams on `compress_threads`
    /// worker threads. Results land in `map` keyed by the raw data pointer
    /// and are consumed by Writer.writeStreamCompressed. Requires a
    /// thread-safe allocator.
    fn precompressStreams(self: *Document, map: *std.AutoHashMapUnmanaged(usize, []const u8)) !void {
        var jobs = std.ArrayListUnmanaged(CompressJob).empty;
        defer jobs.deinit(self.allocator);

        for (self.pages.items) |*page| {
            if (page.content.items.len >= Writer.min_compress_len) {
                try jobs.append(self.allocator, .{ .data = page.content.items });
            }
        }
        for (self.embedded_fonts.items) |emb_font| {
            const font_data = emb_font.getFontData();
            if (font_data.len >= Writer.min_compress_len) {
                try jobs.append(self.allocator, .{ .data = font_data });
            }
        }
        if (jobs.items.len == 0) return;

        const n_threads = @min(@as(usize, self.compress_threads), jobs.items.len);
        var next = std.atomic.Value(usize).init(0);
        const threads = try self.allocator.alloc(std.Thread, n_threads);
        defer self.allocator.free(threads);

        var spawned: usize = 0;
        errdefer {
            for (threads[0..spawned]) |t| t.join();
            for (jobs.items) |job| {
                if (job.result) |res| self.allocator.free(@constCast(res));
            }
        }
        while (spawned < n_threads) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, compressWorker, .{
                jobs.items, &next, self.allocator, self.compression_level,
            });
        }
        for (threads) |t| t.join();

        // No fallible ops after the join (the errdefer above must not run
        // once threads are joined). A failed put just drops the entry - the
        // writer compresses that stream inline.
        for (jobs.items) |job| {
            if (job.result) |res| {
                map.put(self.allocator, @intFromPtr(job.data.ptr), res) catch {
                    self.allocator.free(@constCast(res));
                };
            }
        }
    }

    /// Write embedded font objects: CID fonts (Type0 + CIDFont + descriptor +
    /// font file + ToUnicode) or WinAnsi fonts (Font + descriptor + font file +
    /// ToUnicode).
    fn writeEmbeddedFonts(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        const font_write_start = pdf_output.milliTimestamp();
        for (self.embedded_fonts.items, 0..) |emb_font, i| {
            const base_id = ids.emb_font_base_ids.items[i];

            if (emb_font.encoding == .identity) {
                // CID font: Type0, CIDFont, FontDescriptor, FontFile2, ToUnicode (5 objects)
                const type0_id = base_id;
                const cidfont_id = base_id + 1;
                const descriptor_id = base_id + 2;
                const fontfile_id = base_id + 3;
                const tounicode_id = base_id + 4;

                // Generate ToUnicode CMap for CID
                const tounicode_cmap = try emb_font.generateCIDToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // Generate /W width array
                const w_array = try emb_font.generateWidthArray();
                defer self.allocator.free(w_array);

                // 1. Type0 (composite) font
                try w.beginObject(type0_id);
                {
                    var font_dict = Dict.init(self.allocator);
                    defer font_dict.deinit();
                    try font_dict.put("Type", Value.name("Font"));
                    try font_dict.put("Subtype", Value.name("Type0"));
                    try font_dict.put("BaseFont", Value.name(emb_font.name));
                    try font_dict.put("Encoding", Value.name("Identity-H"));
                    try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

                    // DescendantFonts array with single CIDFont reference
                    var descendants = Array.init(self.allocator);
                    defer descendants.deinit();
                    try descendants.append(Value.ref(.{ .id = cidfont_id }));
                    try font_dict.put("DescendantFonts", .{ .array_val = &descendants });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. CIDFont (CIDFontType2 for TrueType, CIDFontType0 for CFF)
                const is_cff = emb_font.font.isCFF();
                try w.beginObject(cidfont_id);
                {
                    var cid_dict = Dict.init(self.allocator);
                    defer cid_dict.deinit();
                    try cid_dict.put("Type", Value.name("Font"));
                    if (is_cff) {
                        try cid_dict.put("Subtype", Value.name("CIDFontType0"));
                    } else {
                        try cid_dict.put("Subtype", Value.name("CIDFontType2"));
                    }
                    try cid_dict.put("BaseFont", Value.name(emb_font.name));
                    try cid_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
                    try cid_dict.put("DW", Value.int(emb_font.getDefaultWidth()));

                    // CIDSystemInfo dictionary
                    var cidsysinfo = Dict.init(self.allocator);
                    defer cidsysinfo.deinit();
                    try cidsysinfo.put("Registry", Value.string("Adobe"));
                    try cidsysinfo.put("Ordering", Value.string("Identity"));
                    try cidsysinfo.put("Supplement", Value.int(0));
                    try cid_dict.put("CIDSystemInfo", .{ .dict_val = &cidsysinfo });

                    // /W array as raw literal (already formatted)
                    try cid_dict.put("W", Value.literal(w_array));

                    // CIDToGIDMap - Identity mapping (only for TrueType, not CFF)
                    if (!is_cff) {
                        try cid_dict.put("CIDToGIDMap", Value.name("Identity"));
                    }

                    try w.writeDict(cid_dict);
                }
                try w.endObject();

                // 3. FontDescriptor
                try self.writeFontDescriptor(w, emb_font, descriptor_id, fontfile_id, is_cff);

                // 4. FontFile stream (FontFile2 for TTF, FontFile3 for CFF)
                try self.writeFontFileStream(w, emb_font, fontfile_id, is_cff, true);

                // 5. ToUnicode CMap stream
                try self.writeToUnicodeStream(w, tounicode_id, tounicode_cmap);
            } else {
                // WinAnsi font: Font, FontDescriptor, FontFile2, ToUnicode (4 objects)
                const font_dict_id = base_id;
                const descriptor_id = base_id + 1;
                const fontfile_id = base_id + 2;
                const tounicode_id = base_id + 3;

                // Generate ToUnicode CMap
                const tounicode_cmap = try emb_font.generateToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // 1. Font dictionary
                try w.beginObject(font_dict_id);
                {
                    var font_dict = Dict.init(self.allocator);
                    defer font_dict.deinit();
                    try font_dict.put("Type", Value.name("Font"));
                    try font_dict.put("Subtype", Value.name("TrueType"));
                    try font_dict.put("BaseFont", Value.name(emb_font.name));
                    try font_dict.put("FirstChar", Value.int(0));
                    try font_dict.put("LastChar", Value.int(255));
                    try font_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
                    try font_dict.put("Encoding", Value.name("WinAnsiEncoding"));
                    try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

                    // Widths array
                    var widths_array = Array.init(self.allocator);
                    defer widths_array.deinit();
                    for (emb_font.widths) |width| {
                        try widths_array.append(Value.int(@intCast(width)));
                    }
                    try font_dict.put("Widths", .{ .array_val = &widths_array });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. FontDescriptor
                const is_cff_wa = emb_font.font.isCFF();
                try self.writeFontDescriptor(w, emb_font, descriptor_id, fontfile_id, is_cff_wa);

                // 3. FontFile stream
                try self.writeFontFileStream(w, emb_font, fontfile_id, is_cff_wa, false);

                // 4. ToUnicode CMap stream
                try self.writeToUnicodeStream(w, tounicode_id, tounicode_cmap);
            }
        }
        self.last_output_timing.font_write_ms = pdf_output.milliTimestamp() - font_write_start;
    }

    /// Write image XObjects (+ SMask / ICC profile streams where present).
    fn writeImages(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        for (self.loaded_images.items, 0..) |image, i| {
            const img_id = ids.image_base_ids.items[i];
            const smask_id = ids.image_smask_ids.items[i];
            const icc_id = ids.image_icc_ids.items[i];

            // Write ICC profile stream if present
            if (icc_id) |iid| {
                try w.beginObject(iid);
                var icc_dict = Dict.init(self.allocator);
                defer icc_dict.deinit();
                // N = number of color components (3 for RGB, 1 for Gray, 4 for CMYK)
                try icc_dict.put("N", Value.int(image.color_space.components()));
                try icc_dict.put("Alternate", Value.name(image.color_space.pdfName()));
                try w.writeStreamCompressed(&icc_dict, image.icc_profile.?);
                try w.endObject();
            }

            // Write SMask first if present (PNG with alpha)
            if (smask_id) |sid| {
                try w.beginObject(sid);
                var smask_dict = Dict.init(self.allocator);
                defer smask_dict.deinit();
                try smask_dict.put("Type", Value.name("XObject"));
                try smask_dict.put("Subtype", Value.name("Image"));
                try smask_dict.put("Width", Value.int(@intCast(image.width)));
                try smask_dict.put("Height", Value.int(@intCast(image.height)));
                try smask_dict.put("ColorSpace", Value.name("DeviceGray"));
                try smask_dict.put("BitsPerComponent", Value.int(8));
                // Alpha data is already compressed
                try smask_dict.put("Filter", Value.name("FlateDecode"));
                try w.writeStream(&smask_dict, image.alpha_data.?);
                try w.endObject();
            }

            // Write main image XObject
            try w.beginObject(img_id);
            var img_dict = Dict.init(self.allocator);
            defer img_dict.deinit();
            try img_dict.put("Type", Value.name("XObject"));
            try img_dict.put("Subtype", Value.name("Image"));
            try img_dict.put("Width", Value.int(@intCast(image.width)));
            try img_dict.put("Height", Value.int(@intCast(image.height)));

            // Color space array for ICCBased (must stay in scope until writeStream)
            var cs_array = Array.init(self.allocator);
            defer cs_array.deinit();

            // Color space: use ICCBased if we have an ICC profile, otherwise use device color space
            if (icc_id) |iid| {
                // ICCBased color space: [/ICCBased <ref>]
                try cs_array.append(Value.name("ICCBased"));
                try cs_array.append(Value.ref(.{ .id = iid }));
                try img_dict.put("ColorSpace", .{ .array_val = &cs_array });
            } else {
                try img_dict.put("ColorSpace", Value.name(image.color_space.pdfName()));
            }
            try img_dict.put("BitsPerComponent", Value.int(image.bits_per_component));

            // Filter and data handling
            switch (image.format) {
                .jpeg => {
                    try img_dict.put("Filter", Value.name("DCTDecode"));
                    // JPEG data is embedded directly
                    try w.writeStream(&img_dict, image.data);
                },
                .png => {
                    try img_dict.put("Filter", Value.name("FlateDecode"));
                    // PNG data is already re-compressed
                    if (smask_id) |sid| {
                        try img_dict.put("SMask", Value.ref(.{ .id = sid }));
                    }
                    try w.writeStream(&img_dict, image.data);
                },
            }
            try w.endObject();
        }
    }

    /// Write SVG Form XObjects with their ExtGState/Font resources.
    fn writeSvgs(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        for (self.loaded_svgs.items, 0..) |s, i| {
            const svg_id = ids.svg_base_ids.items[i];

            // Generate PDF content stream from SVG
            const svg_content = try s.toPdfContent(self.allocator);
            defer self.allocator.free(svg_content);

            try w.beginObject(svg_id);
            var form_dict = Dict.init(self.allocator);
            defer form_dict.deinit();
            try form_dict.put("Type", Value.name("XObject"));
            try form_dict.put("Subtype", Value.name("Form"));

            // BBox: [0 0 width height]
            var bbox = Array.init(self.allocator);
            defer bbox.deinit();
            try bbox.append(Value.int(0));
            try bbox.append(Value.int(0));
            try bbox.append(Value.real(s.width));
            try bbox.append(Value.real(s.height));
            try form_dict.put("BBox", .{ .array_val = &bbox });

            // Build resources dictionary (may include ExtGState, Font, or both)
            const has_transparency = s.opacity_states.items.len > 0;
            const has_text = s.used_fonts.items.len > 0;

            if (has_transparency or has_text) {
                var resources = Dict.init(self.allocator);
                defer resources.deinit();

                // Add ExtGState for transparency
                var extgstate = Dict.init(self.allocator);
                defer extgstate.deinit();
                var gs_dicts: []Dict = &.{};
                defer {
                    for (gs_dicts) |*d| d.deinit();
                    if (gs_dicts.len > 0) self.allocator.free(gs_dicts);
                }

                if (has_transparency) {
                    gs_dicts = try self.allocator.alloc(Dict, s.opacity_states.items.len);
                    for (s.opacity_states.items, 0..) |state, idx| {
                        gs_dicts[idx] = Dict.init(self.allocator);
                        try gs_dicts[idx].put("Type", Value.name("ExtGState"));
                        try gs_dicts[idx].put("ca", Value.real(state.fill_opacity));
                        try gs_dicts[idx].put("CA", Value.real(state.stroke_opacity));
                        try extgstate.put(extgstateResourceName(idx), .{ .dict_val = &gs_dicts[idx] });
                    }
                    try resources.put("ExtGState", .{ .dict_val = &extgstate });
                }

                // Add Font resources for SVG text elements
                var font_res = Dict.init(self.allocator);
                defer font_res.deinit();
                var font_dicts: []Dict = &.{};
                defer {
                    for (font_dicts) |*d| d.deinit();
                    if (font_dicts.len > 0) self.allocator.free(font_dicts);
                }

                if (has_text) {
                    // Static font names for Form XObject resources (F1-F16)
                    const svg_font_names = [_][]const u8{
                        "F1", "F2",  "F3",  "F4",  "F5",  "F6",  "F7",  "F8",
                        "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16",
                    };

                    font_dicts = try self.allocator.alloc(Dict, s.used_fonts.items.len);
                    for (s.used_fonts.items, 0..) |used_font, idx| {
                        // Create inline font dict: << /Type /Font /Subtype /Type1 /BaseFont /FontName >>
                        font_dicts[idx] = Dict.init(self.allocator);
                        try font_dicts[idx].put("Type", Value.name("Font"));
                        try font_dicts[idx].put("Subtype", Value.name("Type1"));
                        try font_dicts[idx].put("BaseFont", Value.name(used_font.toPdfName()));

                        // Font name: /F1, /F2, etc. (use static names to avoid buffer reuse)
                        const font_name = if (idx < svg_font_names.len) svg_font_names[idx] else "F99";
                        try font_res.put(font_name, .{ .dict_val = &font_dicts[idx] });
                    }
                    try resources.put("Font", .{ .dict_val = &font_res });
                }

                try form_dict.put("Resources", .{ .dict_val = &resources });
                try w.writeStreamCompressed(&form_dict, svg_content);
            } else {
                // No resources needed
                try w.writeStreamCompressed(&form_dict, svg_content);
            }
            try w.endObject();
        }
    }

    /// Write every page: page dict (with resources), content stream, and
    /// annotation objects. Returns the next free object ID.
    fn writePages(self: *Document, w: *Writer, ids: *const OutputIds) !ObjectId {
        const page_write_start = pdf_output.milliTimestamp();
        var next_id = ids.first_page_id;
        for (self.pages.items, 0..) |page, page_idx| {
            const pg_id = next_id;
            const content_id = next_id + 1;
            const first_annot_id = next_id + 2;
            const annot_count = page.annotations.items.len;
            next_id += 2 + @as(ObjectId, @intCast(annot_count));

            // Page dictionary
            try w.beginObject(pg_id);
            var page_dict = Dict.init(self.allocator);
            defer page_dict.deinit();
            try page_dict.put("Type", Value.name("Page"));
            try page_dict.put("Parent", Value.ref(.{ .id = ids.pages_root_id }));

            // MediaBox (use page's own size)
            var media_box = Array.init(self.allocator);
            defer media_box.deinit();
            try media_box.append(Value.int(0));
            try media_box.append(Value.int(0));
            try media_box.append(Value.real(page.size.width));
            try media_box.append(Value.real(page.size.height));
            try page_dict.put("MediaBox", .{ .array_val = &media_box });

            try page_dict.put("Contents", Value.ref(.{ .id = content_id }));
            if (page.rotation != .none) {
                try page_dict.put("Rotate", Value.int(@intFromEnum(page.rotation)));
            }

            // Font resources (must stay in scope until writeDict completes)
            var font_res = Dict.init(self.allocator);
            defer font_res.deinit();
            var xobject_res = Dict.init(self.allocator);
            defer xobject_res.deinit();
            var shading_res = Dict.init(self.allocator);
            defer shading_res.deinit();
            var extgstate_res = Dict.init(self.allocator);
            defer extgstate_res.deinit();
            var shading_strs = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (shading_strs.items) |s| self.allocator.free(s);
                shading_strs.deinit(self.allocator);
            }
            var resources = Dict.init(self.allocator);
            defer resources.deinit();

            var has_fonts = false;
            var has_xobjects = false;

            // Add standard font resources
            for (ids.font_list.items, 0..) |font, idx| {
                if (page.used_fonts.contains(font)) {
                    const font_obj_id = ids.first_std_font_id + @as(ObjectId, @intCast(idx));
                    try font_res.put(fontResourceName(font), Value.ref(.{ .id = font_obj_id }));
                    has_fonts = true;
                }
            }

            // Add embedded font resources
            for (page.used_embedded.items) |emb_font| {
                // Find index of this font
                for (self.embedded_fonts.items, 0..) |doc_font, idx| {
                    if (doc_font == emb_font) {
                        // Use pre-calculated base ID for this font
                        const font_obj_id = ids.emb_font_base_ids.items[idx];
                        const res_name = embeddedFontResourceName(idx);
                        try font_res.put(res_name, Value.ref(.{ .id = font_obj_id }));
                        has_fonts = true;
                        break;
                    }
                }
            }

            // Add COLR Type3 color-font resources used on this page (all of a
            // plan's subfonts; unused entries are legal and rare).
            for (self.color_plans.items) |plan| {
                if (!plan.pages.contains(page_idx)) continue;
                for (plan.font_obj_ids.items, 0..) |obj_id, sub| {
                    var name_buf: [32]u8 = undefined;
                    // Name backed by shading_strs so it outlives writeDict.
                    const res_name = try self.allocator.dupe(u8, color_fonts.subfontResName(&name_buf, plan, sub));
                    try shading_strs.append(self.allocator, res_name);
                    try font_res.put(res_name, Value.ref(.{ .id = obj_id }));
                }
                has_fonts = true;
            }

            // Add image XObject resources
            for (page.used_images.items) |img| {
                // Find index of this image
                for (self.loaded_images.items, 0..) |doc_img, idx| {
                    if (doc_img == img) {
                        const img_obj_id = ids.image_base_ids.items[idx];
                        try xobject_res.put(imageResourceName(idx), Value.ref(.{ .id = img_obj_id }));
                        has_xobjects = true;
                        break;
                    }
                }
            }

            // Add SVG XObject resources
            for (page.used_svgs.items) |s| {
                // Find index of this SVG
                for (self.loaded_svgs.items, 0..) |doc_svg, idx| {
                    if (doc_svg == s) {
                        const svg_obj_id = ids.svg_base_ids.items[idx];
                        try xobject_res.put(svgResourceName(idx), Value.ref(.{ .id = svg_obj_id }));
                        has_xobjects = true;
                        break;
                    }
                }
            }

            // Check if page uses shadings or ExtGState
            const has_shadings = page.used_gradients.count() > 0;
            const has_extgstate = page.opacity_states.items.len > 0;

            if (has_fonts or has_xobjects or has_shadings or has_extgstate) {
                if (has_fonts) {
                    try resources.put("Font", .{ .dict_val = &font_res });
                }
                if (has_xobjects) {
                    try resources.put("XObject", .{ .dict_val = &xobject_res });
                }
                if (has_extgstate) {
                    // Build ExtGState resources for opacity
                    for (page.opacity_states.items, 0..) |state, idx| {
                        // Build inline dict: << /Type /ExtGState /ca N /CA N >>
                        var gs_buf: [128]u8 = undefined;
                        var gs_fbs = std.Io.Writer.fixed(&gs_buf);
                        const gs_writer = &gs_fbs;
                        try gs_writer.writeAll("<< /Type /ExtGState /ca ");
                        var val_buf: [16]u8 = undefined;
                        var len = format.writeF64_3(&val_buf, state.fill_opacity).len;
                        try gs_writer.writeAll(val_buf[0..len]);
                        try gs_writer.writeAll(" /CA ");
                        len = format.writeF64_3(&val_buf, state.stroke_opacity).len;
                        try gs_writer.writeAll(val_buf[0..len]);
                        try gs_writer.writeAll(" >>");
                        const gs_str = try self.allocator.dupe(u8, gs_fbs.buffered());
                        try shading_strs.append(self.allocator, gs_str); // Reuse cleanup list
                        try extgstate_res.put(extgstateResourceName(idx), Value.literal(gs_str));
                    }
                    try resources.put("ExtGState", .{ .dict_val = &extgstate_res });
                }
                if (has_shadings) {
                    // Write inline shading dictionaries
                    var iter = page.used_gradients.keyIterator();
                    while (iter.next()) |grad_idx_ptr| {
                        const grad_idx = grad_idx_ptr.*;
                        if (grad_idx < self.gradients.items.len) {
                            const grad_def = self.gradients.items[grad_idx];

                            // Build shading dict with inline function
                            var shading_buf: [2048]u8 = undefined;
                            var shading_fbs = std.Io.Writer.fixed(&shading_buf);
                            const shading_writer = &shading_fbs;

                            switch (grad_def) {
                                .linear => |lg| {
                                    const pdf_y0 = self.currentPageSize().height - lg.y0;
                                    const pdf_y1 = self.currentPageSize().height - lg.y1;
                                    // Use fast formatting for coordinates
                                    try shading_writer.writeAll("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [");
                                    var coord_buf: [64]u8 = undefined;
                                    var len = format.writeCoord2(&coord_buf, lg.x0, pdf_y0);
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeByte(' ');
                                    len = format.writeCoord2(&coord_buf, lg.x1, pdf_y1);
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeAll("] /Extend [");
                                    try shading_writer.writeAll(if (lg.extend_before) "true " else "false ");
                                    try shading_writer.writeAll(if (lg.extend_after) "true" else "false");
                                    try shading_writer.writeAll("] /Function ");
                                    try gradient.writeFunctionDict(lg.stops, shading_writer);
                                    try shading_writer.writeAll(" >>");
                                },
                                .radial => |rg| {
                                    const pdf_y0 = self.currentPageSize().height - rg.y0;
                                    const pdf_y1 = self.currentPageSize().height - rg.y1;
                                    // Use fast formatting for coordinates
                                    try shading_writer.writeAll("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [");
                                    var coord_buf: [64]u8 = undefined;
                                    var len = format.writeCoord2(&coord_buf, rg.x0, pdf_y0);
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeByte(' ');
                                    len = format.writeF64_2(&coord_buf, rg.r0).len;
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeByte(' ');
                                    len = format.writeCoord2(&coord_buf, rg.x1, pdf_y1);
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeByte(' ');
                                    len = format.writeF64_2(&coord_buf, rg.r1).len;
                                    try shading_writer.writeAll(coord_buf[0..len]);
                                    try shading_writer.writeAll("] /Extend [");
                                    try shading_writer.writeAll(if (rg.extend_before) "true " else "false ");
                                    try shading_writer.writeAll(if (rg.extend_after) "true" else "false");
                                    try shading_writer.writeAll("] /Function ");
                                    try gradient.writeFunctionDict(rg.stops, shading_writer);
                                    try shading_writer.writeAll(" >>");
                                },
                            }

                            const shading_name = shadingResourceName(grad_idx);
                            // Dupe string since stack buffer goes out of scope
                            const shading_str = try self.allocator.dupe(u8, shading_fbs.buffered());
                            try shading_strs.append(self.allocator, shading_str);
                            try shading_res.put(shading_name, Value.literal(shading_str));
                        }
                    }
                    try resources.put("Shading", .{ .dict_val = &shading_res });
                }
                try page_dict.put("Resources", .{ .dict_val = &resources });
            }

            // Add annotations array if page has links
            var annots_array = Array.init(self.allocator);
            defer annots_array.deinit();
            if (annot_count > 0) {
                for (0..annot_count) |i| {
                    const annot_id = first_annot_id + @as(ObjectId, @intCast(i));
                    try annots_array.append(Value.ref(.{ .id = annot_id }));
                }
                try page_dict.put("Annots", .{ .array_val = &annots_array });
            }

            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream (compressed)
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStreamCompressed(&content_dict, page.content.items);
            try w.endObject();

            // Write annotation objects
            for (page.annotations.items, 0..) |annot, i| {
                const annot_id = first_annot_id + @as(ObjectId, @intCast(i));
                try w.beginObject(annot_id);
                var annot_dict = Dict.init(self.allocator);
                defer annot_dict.deinit();

                try annot_dict.put("Type", Value.name("Annot"));
                try annot_dict.put("Subtype", Value.name("Link"));

                // Rect: [x1 y1 x2 y2] in PDF coordinates (y from bottom)
                const rect = switch (annot) {
                    .internal => |a| a.rect,
                    .external => |a| a.rect,
                };
                var rect_array = Array.init(self.allocator);
                defer rect_array.deinit();
                // Convert from top-down to bottom-up coordinates
                const y1 = page.size.height - rect.y - rect.height;
                const y2 = page.size.height - rect.y;
                try rect_array.append(Value.real(rect.x));
                try rect_array.append(Value.real(y1));
                try rect_array.append(Value.real(rect.x + rect.width));
                try rect_array.append(Value.real(y2));
                try annot_dict.put("Rect", .{ .array_val = &rect_array });

                // Border: [0 0 0] = no visible border
                var border_array = Array.init(self.allocator);
                defer border_array.deinit();
                try border_array.append(Value.int(0));
                try border_array.append(Value.int(0));
                try border_array.append(Value.int(0));
                try annot_dict.put("Border", .{ .array_val = &border_array });

                // Destination array or action dict (must stay in scope until writeDict)
                var dest_array = Array.init(self.allocator);
                defer dest_array.deinit();
                var action_dict = Dict.init(self.allocator);
                defer action_dict.deinit();

                switch (annot) {
                    .internal => |a| {
                        // /Dest [page_ref /XYZ left top zoom]
                        // Get the page object ID for the destination
                        var dest_page_id = ids.first_page_id;
                        for (self.pages.items[0..a.dest.page_index]) |p| {
                            dest_page_id += 2 + @as(ObjectId, @intCast(p.annotations.items.len));
                        }
                        const dest_page_size = self.pages.items[a.dest.page_index].size;
                        try dest_array.append(Value.ref(.{ .id = dest_page_id }));
                        try dest_array.append(Value.name("XYZ"));
                        try dest_array.append(Value.int(0)); // left (null = unchanged)
                        // Convert y from top-down to bottom-up
                        try dest_array.append(Value.real(dest_page_size.height - a.dest.y));
                        try dest_array.append(Value.int(0)); // zoom (0 = unchanged)
                        try annot_dict.put("Dest", .{ .array_val = &dest_array });
                    },
                    .external => |a| {
                        // /A << /S /URI /URI (url) >>
                        try action_dict.put("S", Value.name("URI"));
                        try action_dict.put("URI", Value.string(a.url));
                        try annot_dict.put("A", .{ .dict_val = &action_dict });
                    },
                }

                try w.writeDict(annot_dict);
                try w.endObject();
            }
        }
        self.last_output_timing.page_write_ms = pdf_output.milliTimestamp() - page_write_start;
        return next_id;
    }

    /// Write the Info dictionary if any metadata is set, consuming `next_id`.
    /// Returns its object ID, or null when there is no metadata.
    fn writeInfoDict(self: *Document, w: *Writer, next_id: ObjectId) !?ObjectId {
        if (!self.metadata.hasAnyField()) return null;
        const info_id = next_id;

        try w.beginObject(info_id);
        var info_dict = Dict.init(self.allocator);
        defer info_dict.deinit();

        if (self.metadata.title) |title| {
            try info_dict.put("Title", Value.string(title));
        }
        if (self.metadata.author) |author| {
            try info_dict.put("Author", Value.string(author));
        }
        if (self.metadata.subject) |subject| {
            try info_dict.put("Subject", Value.string(subject));
        }
        if (self.metadata.keywords) |keywords| {
            try info_dict.put("Keywords", Value.string(keywords));
        }
        if (self.metadata.creator) |creator| {
            try info_dict.put("Creator", Value.string(creator));
        }
        if (self.metadata.producer) |producer| {
            try info_dict.put("Producer", Value.string(producer));
        }

        // Auto-generate dates if not explicitly set
        var date_buf: [24]u8 = undefined; // "D:YYYYMMDDHHmmSS+00'00'"
        const date_str = if (self.metadata.creation_date) |date|
            date
        else
            formatPdfDate(&date_buf);

        try info_dict.put("CreationDate", Value.string(date_str));

        const mod_date_str = if (self.metadata.mod_date) |date|
            date
        else
            date_str; // Same as creation date if not set

        try info_dict.put("ModDate", Value.string(mod_date_str));

        try w.writeDict(info_dict);
        try w.endObject();
        return info_id;
    }

    /// Write the outlines root and one dictionary per outline item.
    /// No-op when no outline was set.
    fn writeOutlines(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        if (ids.outlines_root_id) |root_id| {
            const o = &self.outline.?;

            // Find first and last top-level outline items
            var first_top_level: ?*OutlineItem = null;
            var last_top_level: ?*OutlineItem = null;
            var total_count: i32 = 0;

            for (o.items.items) |item| {
                if (item.parent == null) {
                    if (first_top_level == null) {
                        first_top_level = item;
                    }
                    last_top_level = item;
                }
                total_count += 1;
            }

            // Write outlines root
            try w.beginObject(root_id);
            var outlines_dict = Dict.init(self.allocator);
            defer outlines_dict.deinit();
            try outlines_dict.put("Type", Value.name("Outlines"));
            if (first_top_level) |first| {
                try outlines_dict.put("First", Value.ref(.{ .id = first.object_id }));
            }
            if (last_top_level) |last| {
                try outlines_dict.put("Last", Value.ref(.{ .id = last.object_id }));
            }
            try outlines_dict.put("Count", Value.int(total_count));
            try w.writeDict(outlines_dict);
            try w.endObject();

            // Write each outline item
            for (o.items.items) |item| {
                try w.beginObject(item.object_id);
                var item_dict = Dict.init(self.allocator);
                defer item_dict.deinit();

                try item_dict.put("Title", Value.string(item.title));

                // Parent reference
                if (item.parent) |parent| {
                    try item_dict.put("Parent", Value.ref(.{ .id = parent.object_id }));
                } else {
                    try item_dict.put("Parent", Value.ref(.{ .id = root_id }));
                }

                // Sibling references
                if (item.prev) |prev| {
                    try item_dict.put("Prev", Value.ref(.{ .id = prev.object_id }));
                }
                if (item.next) |nx| {
                    try item_dict.put("Next", Value.ref(.{ .id = nx.object_id }));
                }

                // Child references
                if (item.first_child) |first| {
                    try item_dict.put("First", Value.ref(.{ .id = first.object_id }));
                }
                if (item.last_child) |last| {
                    try item_dict.put("Last", Value.ref(.{ .id = last.object_id }));
                }

                // Count (positive = expanded, negative = collapsed)
                if (item.count != 0) {
                    try item_dict.put("Count", Value.int(item.count));
                }

                // Destination: [page_ref /XYZ left top zoom]
                var dest_array = Array.init(self.allocator);
                defer dest_array.deinit();
                // Get the page object ID for the destination
                var dest_page_id = ids.first_page_id;
                for (self.pages.items[0..item.dest.page_index]) |p| {
                    dest_page_id += 2 + @as(ObjectId, @intCast(p.annotations.items.len));
                }
                const dest_page_size = self.pages.items[item.dest.page_index].size;
                try dest_array.append(Value.ref(.{ .id = dest_page_id }));
                try dest_array.append(Value.name("XYZ"));
                try dest_array.append(Value.int(0)); // left
                try dest_array.append(Value.real(dest_page_size.height - item.dest.y));
                try dest_array.append(Value.int(0)); // zoom
                try item_dict.put("Dest", .{ .array_val = &dest_array });

                try w.writeDict(item_dict);
                try w.endObject();
            }
        }
    }

    /// Write the page-labels number tree. No-op when no labels were set.
    fn writePageLabels(self: *Document, w: *Writer, ids: *const OutputIds) !void {
        if (ids.page_labels_id) |labels_id| {
            try w.beginObject(labels_id);
            var labels_dict = Dict.init(self.allocator);
            defer labels_dict.deinit();

            // Build /Nums array: [page_index1 dict1 page_index2 dict2 ...]
            var nums_array = Array.init(self.allocator);
            defer nums_array.deinit();

            // Store label dicts to keep them in scope
            var label_dicts = try self.allocator.alloc(Dict, self.page_labels.items.len);
            defer {
                for (label_dicts) |*ld| ld.deinit();
                self.allocator.free(label_dicts);
            }

            for (self.page_labels.items, 0..) |entry, i| {
                try nums_array.append(Value.int(@intCast(entry.page_index)));

                // Build label dictionary
                label_dicts[i] = Dict.init(self.allocator);
                const label = entry.label;

                // /S - numbering style
                if (label.style.pdfCode()) |code| {
                    try label_dicts[i].put("S", Value.name(code));
                }

                // /P - prefix
                if (label.prefix) |prefix| {
                    try label_dicts[i].put("P", Value.string(prefix));
                }

                // /St - starting number (only if not 1)
                if (label.start != 1) {
                    try label_dicts[i].put("St", Value.int(@intCast(label.start)));
                }

                try nums_array.append(.{ .dict_val = &label_dicts[i] });
            }

            try labels_dict.put("Nums", .{ .array_val = &nums_array });
            try w.writeDict(labels_dict);
            try w.endObject();
        }
    }

    /// Write the xref table and trailer; returns the finished PDF bytes.
    fn finishDocument(self: *Document, w: *Writer, ids: *const OutputIds, info_id: ?ObjectId) ![]u8 {
        const finish_start = pdf_output.milliTimestamp();

        // Generate document ID for PDF/A (required in trailer)
        var doc_id_buf: [32]u8 = undefined;
        const doc_id: ?[]const u8 = if (self.conformance != .none) blk: {
            // Generate pseudo-random ID based on timestamp and content
            const timestamp = @as(u64, @intCast(pdf_output.milliTimestamp()));
            const content_hash = @as(u64, @intCast(w.output.items.len)) ^ 0xCAFEBABE;
            _ = std.fmt.bufPrint(&doc_id_buf, "{x:0>16}{x:0>16}", .{ timestamp, content_hash }) catch unreachable;
            break :blk doc_id_buf[0..32];
        } else null;

        const result = try w.finish(.{
            .catalog_ref = .{ .id = ids.catalog_id },
            .info_ref = if (info_id) |id| .{ .id = id } else null,
            .id = doc_id,
        });
        self.last_output_timing.finish_ms = pdf_output.milliTimestamp() - finish_start;
        return result;
    }

    // ========================================================================
    // Font Output Helpers (delegated to pdf_output.zig)
    // ========================================================================

    fn writeFontDescriptor(self: *Document, w: *Writer, emb_font: *EmbeddedFont, descriptor_id: ObjectId, fontfile_id: ObjectId, is_cff: bool) !void {
        return pdf_output.writeFontDescriptor(self.allocator, w, emb_font, descriptor_id, fontfile_id, is_cff);
    }

    fn writeFontFileStream(self: *Document, w: *Writer, emb_font: *EmbeddedFont, fontfile_id: ObjectId, is_cff: bool, is_cid: bool) !void {
        return pdf_output.writeFontFileStream(self.allocator, w, emb_font, fontfile_id, is_cff, is_cid);
    }

    fn writeToUnicodeStream(self: *Document, w: *Writer, tounicode_id: ObjectId, tounicode_cmap: []const u8) !void {
        return pdf_output.writeToUnicodeStream(self.allocator, w, tounicode_id, tounicode_cmap);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

// formatPdfDate is now in pdf_output.zig
const formatPdfDate = pdf_output.formatPdfDate;

// Soft-hyphen utilities are in styled_text.zig
const isSoftHyphenAt = styled_text.isSoftHyphenAt;
const stripSoftHyphens = styled_text.stripSoftHyphens;
const stripSoftHyphensTo = styled_text.stripSoftHyphensTo;
const containsSoftHyphens = styled_text.containsSoftHyphens;

// measureTextStyled is now in metrics.zig
const measureTextStyled = metrics.measureTextStyled;

// ============================================================================
// Internal tests for break helpers and text width measurement
// ============================================================================

test "findHyphenBreak finds break at regular hyphen" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // "state-of-the-art" - should find breaks after each hyphen
    const word = "state-of-the-art";

    // Width that fits "state-" but not more
    const state_width = doc.getTextWidthStyled("state-", style);
    const result = doc.findHyphenBreakStyled(word, state_width + 1, style);
    try std.testing.expectEqual(@as(?usize, 6), result); // "state-" is 6 bytes

    // Width that fits "state-of-" but not "state-of-the-"
    const state_of_width = doc.getTextWidthStyled("state-of-", style);
    const result2 = doc.findHyphenBreakStyled(word, state_of_width + 1, style);
    try std.testing.expectEqual(@as(?usize, 9), result2); // "state-of-" is 9 bytes
}

test "findHyphenBreak returns null for word without hyphens" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    const word = "supercalifragilistic";
    const result = doc.findHyphenBreakStyled(word, 1000, style);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "findSoftHyphenBreak finds break at soft hyphen" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // "ex\xc2\xadplicit" - soft-hyphen between "ex" and "plicit"
    const word = "ex\xc2\xadplicit";

    // Width that fits "ex-" (prefix + visible hyphen)
    const ex_width = doc.getTextWidthStyled("ex-", style);
    const result = doc.findSoftHyphenBreakStyled(word, ex_width + 1, style);
    try std.testing.expectEqual(@as(?usize, 2), result); // Position of soft-hyphen
}

test "findSoftHyphenBreak returns null for word without soft hyphens" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    const word = "explicit";
    const result = doc.findSoftHyphenBreakStyled(word, 1000, style);
    try std.testing.expectEqual(@as(?usize, null), result);
}

test "soft hyphens excluded from text width" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();

    try doc.addPage(.{});
    const style = TextStyle{ .font = Font.helvetica, .size = 12 };

    // Width with soft-hyphens should equal width without
    const with_soft = doc.getTextWidthStyled("ex\xc2\xadplic\xc2\xadit", style);
    const without_soft = doc.getTextWidthStyled("explicit", style);
    try std.testing.expectEqual(without_soft, with_soft);
}
