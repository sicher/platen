//! zpdf - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = "0.1.0";

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Document) void {
        _ = self;
    }
};

test "Document init/deinit" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
}
