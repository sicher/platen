//! platen - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = @import("version.zig");

// Core modules
pub const document = @import("document.zig");
pub const objects = @import("objects.zig");
pub const fonts = @import("fonts.zig");
pub const metrics = @import("metrics.zig");
pub const ttf = @import("ttf.zig");
pub const font_collection = @import("font_collection.zig");
pub const system_fonts = @import("system_fonts.zig");
pub const embedded = @import("embedded.zig");
pub const kern_table = @import("kern_table.zig");
pub const color = @import("color.zig");
pub const layout = @import("layout.zig");
pub const Writer = @import("writer.zig").Writer;
pub const zlib = @import("zlib.zig");
pub const images = @import("images.zig");
pub const svg = @import("svg.zig");
pub const xml = @import("xml.zig");
pub const pdf_output = @import("pdf_output.zig");
pub const pdfa = @import("pdfa.zig");
pub const encrypt = @import("encrypt.zig");

// Re-export Document as the primary type
pub const Document = document.Document;

// Re-export metadata type
pub const DocumentMetadata = document.DocumentMetadata;

// Re-export font types
pub const StandardFont = document.StandardFont;
pub const Font = document.Font;
pub const FontHandle = document.FontHandle;
pub const FontFace = document.FontFace;
pub const FontFamily = document.FontFamily;
pub const EmbeddedFont = document.EmbeddedFont;
pub const FontFamilyOptions = Document.FontFamilyOptions;
pub const FontFamilyMemoryOptions = Document.FontFamilyMemoryOptions;

// Re-export font collection and system font lookup
pub const FaceInfo = font_collection.FaceInfo;
pub const extractFace = font_collection.extractFace;
pub const listFaces = font_collection.listFaces;
pub const FoundFont = system_fonts.FoundFont;
pub const FoundFamily = system_fonts.FoundFamily;
pub const SystemFontOptions = system_fonts.Options;
pub const findSystemFont = system_fonts.find;
pub const findSystemFontFamily = system_fonts.findFamily;
pub const FamilyFace = system_fonts.FamilyFace;
pub const listSystemFontFaces = system_fonts.listFamily;
pub const shaping = @import("shaping.zig");
/// Unicode properties: extended grapheme clusters (UAX #29,
/// graphemeEndBytes) and monospaced cell counts (cells).
pub const unicode_props = @import("unicode_props.zig");
pub const ShapedGlyph = shaping.ShapedGlyph;
pub const shapeText = shaping.shape;

// Re-export metrics types
pub const TextMetrics = document.TextMetrics;
pub const FontStyle = document.FontStyle;
pub const FontMetrics = document.FontMetrics;

// Re-export color
pub const Color = document.Color;

// Re-export image types
pub const Image = document.Image;
pub const ImageFormat = images.ImageFormat;
pub const ImageColorSpace = images.ColorSpace;

// Re-export SVG types
pub const Svg = document.Svg;

// Re-export layout types
pub const Border = document.Border;
pub const Align = document.Align;
pub const VAlign = document.VAlign;
pub const LineBreaking = document.LineBreaking;
pub const TextDecoration = document.TextDecoration;
pub const FallbackAdvance = document.FallbackAdvance;
pub const TextStyle = document.TextStyle;
pub const TextStyleOptions = document.TextStyleOptions;
pub const Margins = document.Margins;
pub const Padding = document.Padding;
pub const Rect = document.Rect;
pub const Region = document.Region;
pub const Destination = document.Destination;
pub const Outline = document.Outline;
pub const OutlineItem = document.OutlineItem;
pub const PageLabelStyle = document.PageLabelStyle;
pub const PageLabel = document.PageLabel;
pub const WriteResult = document.WriteResult;
pub const WriteOptions = document.WriteOptions;
pub const WriteAtOptions = document.WriteAtOptions;
pub const PlacedGlyph = document.PlacedGlyph;
pub const Anchor = document.Anchor;
pub const BlockOptions = document.BlockOptions;
pub const ParagraphOptions = document.ParagraphOptions;
pub const TextPosition = document.TextPosition;
pub const PageSize = document.PageSize;
pub const PageOptions = document.PageOptions;
pub const Encryption = document.Encryption;
pub const Permissions = document.Permissions;
pub const PageRotation = document.PageRotation;

// Re-export graphics types
pub const LineCap = document.LineCap;
pub const LineJoin = document.LineJoin;
pub const DashPattern = document.DashPattern;
pub const Point = document.Point;
pub const StrokeStyle = document.StrokeStyle;
pub const FillStyle = document.FillStyle;
pub const ShapeStyle = document.ShapeStyle;
pub const Path = document.Path;

// Re-export gradient types
pub const LinearGradient = document.LinearGradient;
pub const RadialGradient = document.RadialGradient;
pub const ColorStop = document.ColorStop;

// Re-export OpenType features
pub const opentype = document.opentype;

// Re-export styled text types
pub const StyledText = document.StyledText;
pub const Span = document.Span;
pub const BreakPoint = document.BreakPoint;

// Re-export PDF/A types
pub const Conformance = pdfa.Conformance;
/// Largest magnitude any Document API number may have (error.InvalidNumber beyond).
pub const max_value = @import("validate.zig").max_value;
pub const ConformanceError = pdfa.ConformanceError;

// ============================================================================
// Units - all measurements in PDF are in points (1pt = 1/72 inch)
// ============================================================================

/// Points per inch.
pub const pt_per_inch = 72.0;

/// Points per millimeter.
pub const pt_per_mm = 72.0 / 25.4;

/// Points per centimeter.
pub const pt_per_cm = 72.0 / 2.54;

/// Converts inches to points.
pub fn inches(n: f64) f64 {
    return n * pt_per_inch;
}

/// Converts millimeters to points.
pub fn mm(n: f64) f64 {
    return n * pt_per_mm;
}

/// Converts centimeters to points.
pub fn cm(n: f64) f64 {
    return n * pt_per_cm;
}

// ============================================================================
// Tests
// ============================================================================

test {
    // Reference all test modules
    _ = objects;
    _ = fonts;
    _ = metrics;
    _ = ttf;
    _ = font_collection;
    _ = system_fonts;
    _ = embedded;
    _ = kern_table;
    _ = images;
    _ = xml;
    _ = svg;
    _ = pdfa;
    _ = @import("writer.zig");
    _ = @import("testing.zig");
    _ = @import("integration_tests.zig");
    _ = @import("document_test.zig");
    _ = @import("invalid_number_test.zig");
    _ = @import("embedded_hostile_test.zig");
    _ = @import("resource_names_test.zig");
    _ = @import("pdfa_conformance_test.zig");
    _ = @import("styled_span_test.zig");
    _ = @import("fallback_test.zig");
    _ = @import("fallback.zig");
    _ = @import("shaping_test.zig");
    _ = @import("glyphs_test.zig");
    _ = @import("cff_cid_test.zig");
    _ = shaping;
    _ = @import("decode.zig");
    _ = @import("unicode_props.zig");
    _ = @import("gsub.zig");
    _ = @import("gpos.zig");
    _ = @import("mark_fallback.zig");
    _ = @import("indic.zig");
    _ = @import("hangul.zig");
    _ = @import("opentype.zig");
    _ = @import("validate.zig");
    _ = @import("styled_text.zig");
    _ = @import("outline.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("colr.zig");
    _ = @import("bitmap_glyphs.zig");
    _ = @import("svg_table.zig");
    _ = @import("svg_gradient.zig");
    _ = @import("svg_path.zig");
    _ = @import("encrypt.zig");
    _ = @import("unicode_compose.zig");
}
