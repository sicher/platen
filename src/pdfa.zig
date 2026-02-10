//! PDF/A conformance support for zapdf.
//!
//! This module provides PDF/A conformance levels and validation to ensure
//! generated PDFs meet archival standards.

const std = @import("std");

/// PDF/A conformance levels supported by zapdf.
pub const Conformance = enum {
    /// No restrictions - default mode.
    none,
    /// PDF/A-1b: PDF 1.4, no transparency, all fonts embedded.
    /// Level B (basic) conformance focused on visual preservation.
    pdfa_1b,
    /// PDF/A-2b: PDF 1.7, transparency allowed, JPEG2000 support.
    pdfa_2b,

    /// Returns the PDF version required for this conformance level.
    pub fn pdfVersion(self: Conformance) []const u8 {
        return switch (self) {
            .none, .pdfa_2b => "1.7",
            .pdfa_1b => "1.4",
        };
    }

    /// Returns the part number for XMP metadata.
    pub fn partNumber(self: Conformance) u8 {
        return switch (self) {
            .none => 0,
            .pdfa_1b => 1,
            .pdfa_2b => 2,
        };
    }

    /// Returns the conformance level letter for XMP metadata.
    pub fn conformanceLevel(self: Conformance) []const u8 {
        return switch (self) {
            .none => "",
            .pdfa_1b, .pdfa_2b => "B",
        };
    }

    /// Returns true if transparency is allowed.
    pub fn allowsTransparency(self: Conformance) bool {
        return switch (self) {
            .none, .pdfa_2b => true,
            .pdfa_1b => false,
        };
    }
};

/// Errors related to PDF/A conformance violations.
pub const ConformanceError = error{
    /// Transparency (opacity < 1.0) is not allowed in PDF/A-1b.
    TransparencyNotAllowed,
    /// Feature not permitted for the current conformance level.
    FeatureNotAllowed,
};

/// Validate opacity values against conformance requirements.
/// Returns ConformanceError.TransparencyNotAllowed for PDF/A-1b with non-opaque values.
pub fn validateOpacity(conformance: Conformance, fill_opacity: f64, stroke_opacity: f64) ConformanceError!void {
    if (!conformance.allowsTransparency()) {
        // PDF/A-1b requires fully opaque rendering
        if (fill_opacity < 1.0 or stroke_opacity < 1.0) {
            return ConformanceError.TransparencyNotAllowed;
        }
    }
}

/// Validate a single opacity value against conformance requirements.
pub fn validateSingleOpacity(conformance: Conformance, opacity: f64) ConformanceError!void {
    if (!conformance.allowsTransparency() and opacity < 1.0) {
        return ConformanceError.TransparencyNotAllowed;
    }
}

// ============================================================================
// XMP Metadata Generation
// ============================================================================

/// Metadata for XMP packet generation.
pub const XmpMetadata = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    producer: ?[]const u8 = null,
    create_date: ?[]const u8 = null,
    modify_date: ?[]const u8 = null,
    conformance: Conformance = .none,
    document_id: []const u8 = "",
    instance_id: []const u8 = "",
};

/// Generate XMP metadata packet for PDF/A conformance.
/// The returned slice must be freed by the caller.
pub fn generateXmpMetadata(allocator: std.mem.Allocator, meta: XmpMetadata) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    const w = buf.writer(allocator);

    // XMP packet header
    try w.writeAll(
        \\<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        \\<x:xmpmeta xmlns:x="adobe:ns:meta/">
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \\
    );

    // Dublin Core description
    try w.writeAll(
        \\<rdf:Description rdf:about=""
        \\    xmlns:dc="http://purl.org/dc/elements/1.1/">
        \\
    );
    if (meta.title) |title| {
        try w.print("  <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">{s}</rdf:li></rdf:Alt></dc:title>\n", .{title});
    }
    if (meta.author) |author| {
        try w.print("  <dc:creator><rdf:Seq><rdf:li>{s}</rdf:li></rdf:Seq></dc:creator>\n", .{author});
    }
    if (meta.subject) |subject| {
        try w.print("  <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">{s}</rdf:li></rdf:Alt></dc:description>\n", .{subject});
    }
    try w.writeAll("</rdf:Description>\n");

    // XMP Basic
    try w.writeAll(
        \\<rdf:Description rdf:about=""
        \\    xmlns:xmp="http://ns.adobe.com/xap/1.0/">
        \\
    );
    if (meta.creator) |creator| {
        try w.print("  <xmp:CreatorTool>{s}</xmp:CreatorTool>\n", .{creator});
    }
    if (meta.create_date) |date| {
        try w.print("  <xmp:CreateDate>{s}</xmp:CreateDate>\n", .{date});
    }
    if (meta.modify_date) |date| {
        try w.print("  <xmp:ModifyDate>{s}</xmp:ModifyDate>\n", .{date});
    }
    try w.writeAll("</rdf:Description>\n");

    // PDF properties
    try w.writeAll(
        \\<rdf:Description rdf:about=""
        \\    xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
        \\
    );
    if (meta.producer) |producer| {
        try w.print("  <pdf:Producer>{s}</pdf:Producer>\n", .{producer});
    }
    if (meta.keywords) |keywords| {
        try w.print("  <pdf:Keywords>{s}</pdf:Keywords>\n", .{keywords});
    }
    try w.writeAll("</rdf:Description>\n");

    // PDF/A identification (only for PDF/A conformance)
    if (meta.conformance != .none) {
        try w.writeAll(
            \\<rdf:Description rdf:about=""
            \\    xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
            \\
        );
        try w.print("  <pdfaid:part>{d}</pdfaid:part>\n", .{meta.conformance.partNumber()});
        try w.print("  <pdfaid:conformance>{s}</pdfaid:conformance>\n", .{meta.conformance.conformanceLevel()});
        try w.writeAll("</rdf:Description>\n");
    }

    // XMP Media Management (document/instance IDs)
    if (meta.document_id.len > 0 or meta.instance_id.len > 0) {
        try w.writeAll(
            \\<rdf:Description rdf:about=""
            \\    xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/">
            \\
        );
        if (meta.document_id.len > 0) {
            try w.print("  <xmpMM:DocumentID>uuid:{s}</xmpMM:DocumentID>\n", .{meta.document_id});
        }
        if (meta.instance_id.len > 0) {
            try w.print("  <xmpMM:InstanceID>uuid:{s}</xmpMM:InstanceID>\n", .{meta.instance_id});
        }
        try w.writeAll("</rdf:Description>\n");
    }

    // Close XMP packet
    try w.writeAll(
        \\</rdf:RDF>
        \\</x:xmpmeta>
        \\<?xpacket end="w"?>
    );

    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// ICC Profile
// ============================================================================

/// Embedded sRGB ICC profile (IEC61966-2.1).
/// This is the standard sRGB color profile required for PDF/A output intents.
/// Profile: sRGB2014.icc from ICC - see data/sRGB2014.icc.LICENSE
pub const srgb_icc_profile = @embedFile("data/sRGB2014.icc");

// ============================================================================
// Tests
// ============================================================================

test "Conformance.allowsTransparency" {
    const testing = std.testing;
    try testing.expect(Conformance.none.allowsTransparency());
    try testing.expect(!Conformance.pdfa_1b.allowsTransparency());
    try testing.expect(Conformance.pdfa_2b.allowsTransparency());
}

test "validateOpacity allows transparency for none" {
    try validateOpacity(.none, 0.5, 0.5);
}

test "validateOpacity allows transparency for pdfa_2b" {
    try validateOpacity(.pdfa_2b, 0.5, 0.5);
}

test "validateOpacity rejects transparency for pdfa_1b" {
    const testing = std.testing;
    try testing.expectError(ConformanceError.TransparencyNotAllowed, validateOpacity(.pdfa_1b, 0.5, 1.0));
    try testing.expectError(ConformanceError.TransparencyNotAllowed, validateOpacity(.pdfa_1b, 1.0, 0.5));
    try testing.expectError(ConformanceError.TransparencyNotAllowed, validateOpacity(.pdfa_1b, 0.5, 0.5));
}

test "validateOpacity allows fully opaque for pdfa_1b" {
    try validateOpacity(.pdfa_1b, 1.0, 1.0);
}

test "Conformance.pdfVersion" {
    const testing = std.testing;
    try testing.expectEqualStrings("1.7", Conformance.none.pdfVersion());
    try testing.expectEqualStrings("1.4", Conformance.pdfa_1b.pdfVersion());
    try testing.expectEqualStrings("1.7", Conformance.pdfa_2b.pdfVersion());
}

test "Conformance.partNumber" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0), Conformance.none.partNumber());
    try testing.expectEqual(@as(u8, 1), Conformance.pdfa_1b.partNumber());
    try testing.expectEqual(@as(u8, 2), Conformance.pdfa_2b.partNumber());
}

test "generateXmpMetadata basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const xmp = try generateXmpMetadata(allocator, .{
        .title = "Test Document",
        .author = "Test Author",
        .conformance = .pdfa_1b,
    });
    defer allocator.free(xmp);

    // Check required elements
    try testing.expect(std.mem.indexOf(u8, xmp, "<?xpacket begin") != null);
    try testing.expect(std.mem.indexOf(u8, xmp, "Test Document") != null);
    try testing.expect(std.mem.indexOf(u8, xmp, "Test Author") != null);
    try testing.expect(std.mem.indexOf(u8, xmp, "<pdfaid:part>1</pdfaid:part>") != null);
    try testing.expect(std.mem.indexOf(u8, xmp, "<pdfaid:conformance>B</pdfaid:conformance>") != null);
    try testing.expect(std.mem.indexOf(u8, xmp, "<?xpacket end") != null);
}

test "generateXmpMetadata no pdfa for none conformance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const xmp = try generateXmpMetadata(allocator, .{
        .title = "Test",
        .conformance = .none,
    });
    defer allocator.free(xmp);

    // Should not have PDF/A identification for .none
    try testing.expect(std.mem.indexOf(u8, xmp, "pdfaid:part") == null);
}
