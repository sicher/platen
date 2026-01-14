//! zpdf - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = "0.1.0";

// Modules
pub const objects = @import("objects.zig");
pub const Writer = @import("writer.zig").Writer;

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

/// Page size in points (1 point = 1/72 inch)
pub const PageSize = struct {
    width: f64,
    height: f64,

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
};

/// Internal page representation
const Page = struct {
    content: std.ArrayListUnmanaged(u8),

    fn init() Page {
        return .{ .content = .{} };
    }

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }
};

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .pages = .{},
            .page_size = PageSize.A4,
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
    }

    /// Add a new page
    pub fn addPage(self: *Document) !void {
        try self.pages.append(self.allocator, Page.init());
    }

    /// Output the PDF document as bytes
    /// Caller owns the returned memory and must free it with the document's allocator
    pub fn output(self: *Document) ![]u8 {
        // Ensure at least one page
        if (self.pages.items.len == 0) {
            try self.addPage();
        }

        var w = Writer.init(self.allocator);
        defer w.offsets.deinit(self.allocator); // Clean up offsets, output is transferred

        try w.writeHeader();

        // Object ID allocation:
        // 1 = Catalog
        // 2 = Pages (root)
        // 3+ = Individual pages (each page needs 2 objects: page dict + content stream)

        const catalog_id: ObjectId = 1;
        const pages_root_id: ObjectId = 2;
        const first_page_id: ObjectId = 3;

        // Build page refs array for Pages object
        var page_refs = Array.init(self.allocator);
        defer page_refs.deinit();

        var next_id = first_page_id;
        for (self.pages.items) |_| {
            try page_refs.append(Value.ref(.{ .id = next_id }));
            next_id += 2; // Each page uses 2 objects (page dict + content stream)
        }

        // Write Catalog
        try w.beginObject(catalog_id);
        var catalog = Dict.init(self.allocator);
        defer catalog.deinit();
        try catalog.put("Type", Value.name("Catalog"));
        try catalog.put("Pages", Value.ref(.{ .id = pages_root_id }));
        try w.writeDict(catalog);
        try w.endObject();

        // Write Pages (root)
        try w.beginObject(pages_root_id);
        var pages_dict = Dict.init(self.allocator);
        defer pages_dict.deinit();
        try pages_dict.put("Type", Value.name("Pages"));
        try pages_dict.put("Kids", .{ .array_val = &page_refs });
        try pages_dict.put("Count", Value.int(@intCast(self.pages.items.len)));
        try w.writeDict(pages_dict);
        try w.endObject();

        // Write each page
        next_id = first_page_id;
        for (self.pages.items) |page| {
            const page_id = next_id;
            const content_id = next_id + 1;
            next_id += 2;

            // Page dictionary
            try w.beginObject(page_id);
            var page_dict = Dict.init(self.allocator);
            defer page_dict.deinit();
            try page_dict.put("Type", Value.name("Page"));
            try page_dict.put("Parent", Value.ref(.{ .id = pages_root_id }));

            // MediaBox
            var media_box = Array.init(self.allocator);
            defer media_box.deinit();
            try media_box.append(Value.int(0));
            try media_box.append(Value.int(0));
            try media_box.append(Value.real(self.page_size.width));
            try media_box.append(Value.real(self.page_size.height));
            try page_dict.put("MediaBox", .{ .array_val = &media_box });

            try page_dict.put("Contents", Value.ref(.{ .id = content_id }));
            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStream(&content_dict, page.content.items);
            try w.endObject();
        }

        // Finish with xref and trailer
        return try w.finish(.{ .id = catalog_id });
    }
};

test "Document init/deinit" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
}

test "Document output minimal PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF structure
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test {
    _ = objects;
    _ = @import("writer.zig");
}
