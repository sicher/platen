//! Minimal XML parser for SVG parsing.
//!
//! This is a simple pull-parser for XML documents, designed specifically
//! for SVG parsing. It does not handle all XML features (DTD, CDATA, etc.)
//! but supports the subset needed for SVG documents.

const std = @import("std");

/// XML Element parsed from the stream
pub const Element = struct {
    /// Tag name (e.g., "svg", "rect", "path")
    tag: []const u8,
    /// Raw attributes string (to be parsed with AttributeIterator)
    attributes_raw: []const u8,
    /// Whether this is a self-closing tag (e.g., <rect />)
    is_self_closing: bool,
    /// Whether this is an end tag (e.g., </svg>)
    is_end_tag: bool,

    /// Iterate over attributes
    pub fn attributes(self: Element) AttributeIterator {
        return AttributeIterator.init(self.attributes_raw);
    }
};

/// Iterator over XML attributes
pub const AttributeIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) AttributeIterator {
        return .{ .data = data, .pos = 0 };
    }

    /// Get next attribute name/value pair
    pub fn next(self: *AttributeIterator) ?struct { name: []const u8, value: []const u8 } {
        // Skip whitespace
        while (self.pos < self.data.len and isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return null;

        // Parse attribute name
        const name_start = self.pos;
        while (self.pos < self.data.len and
            self.data[self.pos] != '=' and
            !isWhitespace(self.data[self.pos]))
        {
            self.pos += 1;
        }
        const name = self.data[name_start..self.pos];
        if (name.len == 0) return null;

        // Skip whitespace around =
        while (self.pos < self.data.len and isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len or self.data[self.pos] != '=') {
            // Attribute without value - return empty value
            return .{ .name = name, .value = "" };
        }
        self.pos += 1; // Skip =

        // Skip whitespace after =
        while (self.pos < self.data.len and isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return null;

        // Parse attribute value (quoted)
        const quote = self.data[self.pos];
        if (quote != '"' and quote != '\'') {
            // Unquoted value - read until whitespace
            const val_start = self.pos;
            while (self.pos < self.data.len and !isWhitespace(self.data[self.pos])) {
                self.pos += 1;
            }
            return .{ .name = name, .value = self.data[val_start..self.pos] };
        }

        self.pos += 1; // Skip opening quote
        const val_start = self.pos;

        while (self.pos < self.data.len and self.data[self.pos] != quote) {
            self.pos += 1;
        }

        const value = self.data[val_start..self.pos];

        if (self.pos < self.data.len) {
            self.pos += 1; // Skip closing quote
        }

        return .{ .name = name, .value = value };
    }
};

/// XML Pull Parser
pub const XmlParser = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) XmlParser {
        return .{ .data = data, .pos = 0 };
    }

    /// Get the next element from the XML stream
    pub fn nextElement(self: *XmlParser) ?Element {
        // Skip to next <
        while (self.pos < self.data.len and self.data[self.pos] != '<') {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return null;

        self.pos += 1; // Skip <

        // Skip comments <!-- ... -->
        if (self.pos + 2 < self.data.len and
            self.data[self.pos] == '!' and
            self.data[self.pos + 1] == '-' and
            self.data[self.pos + 2] == '-')
        {
            // Find -->
            self.pos += 3;
            while (self.pos + 2 < self.data.len) {
                if (self.data[self.pos] == '-' and
                    self.data[self.pos + 1] == '-' and
                    self.data[self.pos + 2] == '>')
                {
                    self.pos += 3;
                    return self.nextElement();
                }
                self.pos += 1;
            }
            return null;
        }

        // Skip <?xml ... ?> and <!DOCTYPE ... >
        if (self.pos < self.data.len and (self.data[self.pos] == '?' or self.data[self.pos] == '!')) {
            // Find closing >
            while (self.pos < self.data.len and self.data[self.pos] != '>') {
                self.pos += 1;
            }
            if (self.pos < self.data.len) self.pos += 1;
            return self.nextElement();
        }

        // Check for end tag
        var is_end_tag = false;
        if (self.pos < self.data.len and self.data[self.pos] == '/') {
            is_end_tag = true;
            self.pos += 1;
        }

        // Skip whitespace
        while (self.pos < self.data.len and isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }

        // Parse tag name
        const tag_start = self.pos;
        while (self.pos < self.data.len and
            !isWhitespace(self.data[self.pos]) and
            self.data[self.pos] != '>' and
            self.data[self.pos] != '/')
        {
            self.pos += 1;
        }
        const tag = self.data[tag_start..self.pos];

        if (tag.len == 0) {
            // Invalid tag, skip to next >
            while (self.pos < self.data.len and self.data[self.pos] != '>') {
                self.pos += 1;
            }
            if (self.pos < self.data.len) self.pos += 1;
            return self.nextElement();
        }

        // Skip whitespace after tag name
        while (self.pos < self.data.len and isWhitespace(self.data[self.pos])) {
            self.pos += 1;
        }

        // Parse attributes until > or />
        const attr_start = self.pos;
        var is_self_closing = false;

        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            if (self.data[self.pos] == '/') {
                is_self_closing = true;
                self.pos += 1;
                continue;
            }

            // Skip quoted strings in attributes
            if (self.data[self.pos] == '"' or self.data[self.pos] == '\'') {
                const quote = self.data[self.pos];
                self.pos += 1;
                while (self.pos < self.data.len and self.data[self.pos] != quote) {
                    self.pos += 1;
                }
            }

            self.pos += 1;
        }

        // Calculate attribute bounds (exclude trailing / if self-closing)
        var attr_end = self.pos;
        if (is_self_closing and attr_end > attr_start) {
            // Back up past the /
            var temp = attr_end;
            while (temp > attr_start and (self.data[temp - 1] == '/' or isWhitespace(self.data[temp - 1]))) {
                temp -= 1;
            }
            attr_end = temp;
        }

        const attributes_raw = self.data[attr_start..attr_end];

        // Skip >
        if (self.pos < self.data.len and self.data[self.pos] == '>') {
            self.pos += 1;
        }

        return Element{
            .tag = tag,
            .attributes_raw = attributes_raw,
            .is_self_closing = is_self_closing,
            .is_end_tag = is_end_tag,
        };
    }

    /// Get text content from current position until the next tag
    /// Returns the trimmed text between current position and next '<'
    pub fn getTextContent(self: *XmlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '<') {
            self.pos += 1;
        }
        return std.mem.trim(u8, self.data[start..self.pos], " \t\n\r");
    }

    /// Skip to the end of the current element (past the matching end tag)
    pub fn skipElement(self: *XmlParser, tag_name: []const u8) void {
        var depth: usize = 1;
        while (self.nextElement()) |elem| {
            if (std.mem.eql(u8, elem.tag, tag_name)) {
                if (elem.is_end_tag) {
                    depth -= 1;
                    if (depth == 0) break;
                } else if (!elem.is_self_closing) {
                    depth += 1;
                }
            }
        }
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple element" {
    var parser = XmlParser.init("<rect width=\"10\" height=\"20\" />");
    const elem = parser.nextElement().?;
    try std.testing.expectEqualStrings("rect", elem.tag);
    try std.testing.expect(elem.is_self_closing);
    try std.testing.expect(!elem.is_end_tag);
}

test "parse attributes" {
    var parser = XmlParser.init("<rect x=\"10\" y=\"20\" fill=\"red\" />");
    const elem = parser.nextElement().?;

    var attrs = elem.attributes();

    const x = attrs.next().?;
    try std.testing.expectEqualStrings("x", x.name);
    try std.testing.expectEqualStrings("10", x.value);

    const y = attrs.next().?;
    try std.testing.expectEqualStrings("y", y.name);
    try std.testing.expectEqualStrings("20", y.value);

    const fill = attrs.next().?;
    try std.testing.expectEqualStrings("fill", fill.name);
    try std.testing.expectEqualStrings("red", fill.value);

    try std.testing.expectEqual(@as(?@TypeOf(attrs.next().?), null), attrs.next());
}

test "parse end tag" {
    var parser = XmlParser.init("</g>");
    const elem = parser.nextElement().?;
    try std.testing.expectEqualStrings("g", elem.tag);
    try std.testing.expect(elem.is_end_tag);
    try std.testing.expect(!elem.is_self_closing);
}

test "skip xml declaration and doctype" {
    var parser = XmlParser.init("<?xml version=\"1.0\"?><!DOCTYPE svg><svg></svg>");
    const elem = parser.nextElement().?;
    try std.testing.expectEqualStrings("svg", elem.tag);
    try std.testing.expect(!elem.is_end_tag);
}

test "skip comments" {
    var parser = XmlParser.init("<!-- comment --><rect />");
    const elem = parser.nextElement().?;
    try std.testing.expectEqualStrings("rect", elem.tag);
}

test "parse nested elements" {
    var parser = XmlParser.init("<svg><g><rect /></g></svg>");

    const svg = parser.nextElement().?;
    try std.testing.expectEqualStrings("svg", svg.tag);
    try std.testing.expect(!svg.is_self_closing);

    const g = parser.nextElement().?;
    try std.testing.expectEqualStrings("g", g.tag);

    const rect = parser.nextElement().?;
    try std.testing.expectEqualStrings("rect", rect.tag);
    try std.testing.expect(rect.is_self_closing);

    const g_end = parser.nextElement().?;
    try std.testing.expectEqualStrings("g", g_end.tag);
    try std.testing.expect(g_end.is_end_tag);

    const svg_end = parser.nextElement().?;
    try std.testing.expectEqualStrings("svg", svg_end.tag);
    try std.testing.expect(svg_end.is_end_tag);
}

test "single quotes in attributes" {
    var parser = XmlParser.init("<rect fill='blue' />");
    const elem = parser.nextElement().?;

    var attrs = elem.attributes();
    const fill = attrs.next().?;
    try std.testing.expectEqualStrings("fill", fill.name);
    try std.testing.expectEqualStrings("blue", fill.value);
}

test "attribute with special characters" {
    var parser = XmlParser.init("<path d=\"M 0 0 L 10 10\" />");
    const elem = parser.nextElement().?;

    var attrs = elem.attributes();
    const d = attrs.next().?;
    try std.testing.expectEqualStrings("d", d.name);
    try std.testing.expectEqualStrings("M 0 0 L 10 10", d.value);
}
