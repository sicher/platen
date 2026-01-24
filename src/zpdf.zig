//! zpdf - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = "0.1.0";

// Core modules
pub const document = @import("document.zig");
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
pub const xml = @import("xml.zig");
pub const testing = @import("testing.zig");
pub const integration_tests = @import("integration_tests.zig");

// Re-export Document as the primary type
pub const Document = document.Document;

// Re-export metadata type
pub const DocumentMetadata = document.DocumentMetadata;

// Re-export font types
pub const StandardFont = document.StandardFont;
pub const Font = document.Font;
pub const FontHandle = document.FontHandle;
pub const EmbeddedFont = document.EmbeddedFont;

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
pub const TextStyleOptions = document.TextStyleOptions;
pub const Margins = document.Margins;
pub const Padding = document.Padding;
pub const Rect = document.Rect;
pub const Region = document.Region;
pub const Destination = document.Destination;
pub const Outline = document.Outline;
pub const PageLabelStyle = document.PageLabelStyle;
pub const PageLabel = document.PageLabel;
pub const WriteResult = document.WriteResult;
pub const WriteOptions = document.WriteOptions;
pub const ParagraphOptions = document.ParagraphOptions;
pub const PageSize = document.PageSize;

// Re-export graphics types
pub const LineCap = document.LineCap;
pub const LineJoin = document.LineJoin;
pub const DashPattern = document.DashPattern;
pub const Point = document.Point;
pub const StrokeStyle = document.StrokeStyle;
pub const FillStyle = document.FillStyle;
pub const ShapeStyle = document.ShapeStyle;

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
    _ = embedded;
    _ = images;
    _ = xml;
    _ = svg;
    _ = @import("writer.zig");
    _ = @import("testing.zig");
    _ = @import("integration_tests.zig");
    _ = @import("document_test.zig");
    _ = @import("styled_text.zig");
}
