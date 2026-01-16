//! PDF Standard Fonts (Base 14)
//!
//! PDF viewers are required to have these 14 fonts available.
//! They don't need to be embedded in the PDF.

const std = @import("std");

/// Standard PDF font families
pub const Family = enum {
    helvetica,
    times,
    courier,
    symbol,
    zapf_dingbats,
};

/// Font style
pub const Style = enum {
    normal,
    bold,
    italic,
    bold_italic,
};

/// Standard font identifier
pub const StandardFont = enum {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    symbol,
    zapf_dingbats,

    /// Get the PDF name for this font
    pub fn pdfName(self: StandardFont) []const u8 {
        return switch (self) {
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .times_roman => "Times-Roman",
            .times_bold => "Times-Bold",
            .times_italic => "Times-Italic",
            .times_bold_italic => "Times-BoldItalic",
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
            .symbol => "Symbol",
            .zapf_dingbats => "ZapfDingbats",
        };
    }

    /// Get a standard font from family and style
    pub fn fromFamilyStyle(family: Family, style: Style) StandardFont {
        return switch (family) {
            .helvetica => switch (style) {
                .normal => .helvetica,
                .bold => .helvetica_bold,
                .italic => .helvetica_oblique,
                .bold_italic => .helvetica_bold_oblique,
            },
            .times => switch (style) {
                .normal => .times_roman,
                .bold => .times_bold,
                .italic => .times_italic,
                .bold_italic => .times_bold_italic,
            },
            .courier => switch (style) {
                .normal => .courier,
                .bold => .courier_bold,
                .italic => .courier_oblique,
                .bold_italic => .courier_bold_oblique,
            },
            .symbol => .symbol,
            .zapf_dingbats => .zapf_dingbats,
        };
    }
};

/// Font instance with size
pub const Font = struct {
    standard: StandardFont,
    size: f64,

    pub fn init(standard: StandardFont, size: f64) Font {
        return .{ .standard = standard, .size = size };
    }
};

test "StandardFont pdfName" {
    try std.testing.expectEqualStrings("Helvetica", StandardFont.helvetica.pdfName());
    try std.testing.expectEqualStrings("Times-Bold", StandardFont.times_bold.pdfName());
    try std.testing.expectEqualStrings("Courier-Oblique", StandardFont.courier_oblique.pdfName());
}

test "fromFamilyStyle" {
    try std.testing.expectEqual(StandardFont.helvetica_bold, StandardFont.fromFamilyStyle(.helvetica, .bold));
    try std.testing.expectEqual(StandardFont.times_italic, StandardFont.fromFamilyStyle(.times, .italic));
}
