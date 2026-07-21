//! Image handling for platen - JPEG and PNG embedding.
//!
//! Provides image parsing and data extraction for embedding in PDFs.
//! JPEG data is embedded directly (already DCT compressed).
//! PNG data uses FlateDecode (zlib compressed).

const std = @import("std");

/// Image format
pub const ImageFormat = enum {
    jpeg,
    png,
};

/// Color space for images
pub const ColorSpace = enum {
    device_rgb,
    device_gray,
    device_cmyk,

    pub fn pdfName(self: ColorSpace) []const u8 {
        return switch (self) {
            .device_rgb => "DeviceRGB",
            .device_gray => "DeviceGray",
            .device_cmyk => "DeviceCMYK",
        };
    }

    pub fn components(self: ColorSpace) u8 {
        return switch (self) {
            .device_rgb => 3,
            .device_gray => 1,
            .device_cmyk => 4,
        };
    }
};

/// Image data for embedding in PDF
pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    color_space: ColorSpace,
    bits_per_component: u8,
    format: ImageFormat,
    /// Raw image stream data (JPEG: entire file; PNG: decompressed then recompressed pixel data)
    data: []const u8,
    /// Separate alpha channel for PNG with transparency (zlib compressed)
    alpha_data: ?[]const u8,
    /// ICC color profile data (extracted from JPEG APP2 markers)
    icc_profile: ?[]const u8,
    /// Whether data/alpha_data/icc_profile are owned by this struct
    owns_data: bool,
    /// Set when a Document created this image (doc.loadImage*): it lives and
    /// dies with that document and must not be drawn into other documents.
    /// Caller-created images (Image.fromMemory) stay false and are shareable.
    document_owned: bool = false,

    pub fn deinit(self: *Image) void {
        if (self.owns_data) {
            self.allocator.free(self.data);
            if (self.alpha_data) |alpha| {
                self.allocator.free(alpha);
            }
            if (self.icc_profile) |icc| {
                self.allocator.free(icc);
            }
        }
        self.allocator.destroy(self);
    }

    /// Load image from file, detecting format from header
    pub fn fromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*Image {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024));
        errdefer allocator.free(data);

        return fromMemoryLevel(allocator, data, true, 6);
    }

    /// Load image from memory buffer. Caller-owned and shareable across
    /// documents/threads; free with deinit() after every document using it
    /// is deinitialized. Lifetime: BORROWS `data` - it must outlive the
    /// Image (JPEG bytes are embedded directly from the buffer).
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !*Image {
        return fromMemoryLevel(allocator, data, false, 6);
    }

    /// Load image from memory buffer, compressing PNG pixel data at the given
    /// zlib level (clamped to 1-9; JPEG data is embedded as-is).
    pub fn fromMemoryLevel(allocator: std.mem.Allocator, data: []const u8, owns_data: bool, level: i32) !*Image {
        // Detect format from magic bytes
        const format = detectFormat(data) orelse return error.UnknownImageFormat;

        return switch (format) {
            .jpeg => parseJpeg(allocator, data, owns_data),
            .png => parsePng(allocator, data, owns_data, std.math.clamp(level, 1, 9)),
        };
    }

    /// Detect image format from magic bytes
    fn detectFormat(data: []const u8) ?ImageFormat {
        if (data.len < 8) return null;

        // JPEG: FF D8 FF
        if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
            return .jpeg;
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47 and
            data[4] == 0x0D and data[5] == 0x0A and data[6] == 0x1A and data[7] == 0x0A)
        {
            return .png;
        }

        return null;
    }
};

// ============================================================================
// JPEG Parsing
// ============================================================================

/// JPEG marker codes
const JpegMarker = struct {
    const SOI: u8 = 0xD8; // Start of Image
    const SOF0: u8 = 0xC0; // Baseline DCT
    const SOF1: u8 = 0xC1; // Extended sequential DCT
    const SOF2: u8 = 0xC2; // Progressive DCT
    const SOF3: u8 = 0xC3; // Lossless (sequential)
    const SOF9: u8 = 0xC9; // Extended sequential DCT (arithmetic)
    const SOF10: u8 = 0xCA; // Progressive DCT (arithmetic)
    const APP0: u8 = 0xE0; // JFIF marker
    const APP2: u8 = 0xE2; // ICC profile marker
    const APP14: u8 = 0xEE; // Adobe marker
    const EOI: u8 = 0xD9; // End of Image
};

/// ICC profile marker identifier
const ICC_PROFILE_MARKER = "ICC_PROFILE\x00";

/// ICC profile chunk from APP2 marker
const IccChunk = struct {
    sequence: u8,
    total: u8,
    data: []const u8,
};

fn parseJpeg(allocator: std.mem.Allocator, data: []const u8, owns_data: bool) !*Image {
    // Verify SOI marker (FF D8)
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) {
        return error.InvalidJpeg;
    }

    // Collect ICC profile chunks and image dimensions in a single pass
    var icc_chunks = std.ArrayListUnmanaged(IccChunk).empty;
    defer icc_chunks.deinit(allocator);

    var i: usize = 2;
    var width: u32 = 0;
    var height: u32 = 0;
    var components: u8 = 0;
    var found_sof = false;

    while (i + 1 < data.len) {
        // Find marker (FF xx)
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }

        // Skip padding FF bytes
        while (i + 1 < data.len and data[i + 1] == 0xFF) {
            i += 1;
        }

        if (i + 1 >= data.len) break;

        const marker = data[i + 1];
        i += 2;

        // Standalone markers (no length field)
        if (marker == 0x00 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9)) {
            continue;
        }

        // Markers with length field
        if (i + 2 > data.len) break;
        const length = (@as(usize, data[i]) << 8) | data[i + 1];
        if (length < 2) return error.InvalidJpeg;

        // Check for SOF markers (Start of Frame)
        if (isSOFMarker(marker) and !found_sof) {
            if (i + 8 > data.len) return error.InvalidJpeg;
            height = (@as(u32, data[i + 3]) << 8) | data[i + 4];
            width = (@as(u32, data[i + 5]) << 8) | data[i + 6];
            components = data[i + 7];
            found_sof = true;
        }

        // Check for APP2 marker with ICC profile
        if (marker == JpegMarker.APP2 and length > 14) {
            const marker_data = data[i + 2 .. i + length];
            // Check for "ICC_PROFILE\0" identifier (12 bytes)
            if (marker_data.len >= 14 and std.mem.eql(u8, marker_data[0..12], ICC_PROFILE_MARKER)) {
                const sequence = marker_data[12];
                const total = marker_data[13];
                const profile_data = marker_data[14..];
                try icc_chunks.append(allocator, .{
                    .sequence = sequence,
                    .total = total,
                    .data = profile_data,
                });
            }
        }

        i += length;
    }

    if (width == 0 or height == 0) {
        return error.NoJpegSOFMarker;
    }

    // Determine color space from component count
    const color_space: ColorSpace = switch (components) {
        1 => .device_gray,
        3 => .device_rgb,
        4 => .device_cmyk,
        else => return error.UnsupportedJpegColorSpace,
    };

    // Assemble ICC profile from chunks (if any)
    var icc_profile: ?[]u8 = null;
    if (icc_chunks.items.len > 0) {
        // Sort chunks by sequence number
        std.mem.sort(IccChunk, icc_chunks.items, {}, struct {
            fn lessThan(_: void, a: IccChunk, b: IccChunk) bool {
                return a.sequence < b.sequence;
            }
        }.lessThan);

        // Calculate total size
        var total_size: usize = 0;
        for (icc_chunks.items) |chunk| {
            total_size += chunk.data.len;
        }

        // Concatenate chunks
        icc_profile = try allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (icc_chunks.items) |chunk| {
            @memcpy(icc_profile.?[offset .. offset + chunk.data.len], chunk.data);
            offset += chunk.data.len;
        }
    }
    errdefer if (icc_profile) |p| allocator.free(p);

    const image = try allocator.create(Image);
    image.* = .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .color_space = color_space,
        .bits_per_component = 8,
        .format = .jpeg,
        .data = data,
        .alpha_data = null,
        .icc_profile = icc_profile,
        .owns_data = owns_data,
    };
    return image;
}

fn isSOFMarker(marker: u8) bool {
    return switch (marker) {
        JpegMarker.SOF0,
        JpegMarker.SOF1,
        JpegMarker.SOF2,
        JpegMarker.SOF3,
        JpegMarker.SOF9,
        JpegMarker.SOF10,
        => true,
        else => false,
    };
}

// ============================================================================
// PNG Parsing
// ============================================================================

/// PNG chunk types
const PngChunk = struct {
    const IHDR: u32 = 0x49484452; // Image header
    const PLTE: u32 = 0x504C5445; // Palette
    const IDAT: u32 = 0x49444154; // Image data
    const IEND: u32 = 0x49454E44; // Image end
    const tRNS: u32 = 0x74524E53; // Transparency
};

/// PNG color types
const PngColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

fn parsePng(allocator: std.mem.Allocator, data: []const u8, owns_data: bool, level: i32) !*Image {
    // Verify PNG signature
    const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_sig)) {
        return error.InvalidPng;
    }

    // Parse IHDR chunk (must be first after signature)
    if (data.len < 8 + 8 + 13 + 4) return error.InvalidPng; // sig + chunk header + IHDR data + CRC

    const chunk_length = std.mem.readInt(u32, data[8..12], .big);
    const chunk_type = std.mem.readInt(u32, data[12..16], .big);

    if (chunk_type != PngChunk.IHDR or chunk_length != 13) {
        return error.InvalidPngIHDR;
    }

    // IHDR structure:
    // Width (4 bytes), Height (4 bytes), Bit depth (1), Color type (1),
    // Compression (1), Filter (1), Interlace (1)
    const ihdr_data = data[16..29];
    const width = std.mem.readInt(u32, ihdr_data[0..4], .big);
    const height = std.mem.readInt(u32, ihdr_data[4..8], .big);
    const bit_depth = ihdr_data[8];
    const color_type_byte = ihdr_data[9];
    const compression = ihdr_data[10];
    const filter = ihdr_data[11];
    const interlace = ihdr_data[12];

    // Validate
    if (compression != 0) return error.UnsupportedPngCompression;
    if (filter != 0) return error.UnsupportedPngFilter;
    if (interlace != 0) return error.InterlacedPngNotSupported;

    const color_type = std.enums.fromInt(PngColorType, color_type_byte) orelse {
        return error.UnsupportedPngColorType;
    };

    // Collect all IDAT chunks (plus PLTE/tRNS for indexed color)
    var idat_chunks = std.ArrayListUnmanaged([]const u8).empty;
    defer idat_chunks.deinit(allocator);
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;

    var pos: usize = 8; // After signature
    while (pos + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const ctype = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);

        if (pos + 12 + len > data.len) break;

        if (ctype == PngChunk.IDAT) {
            try idat_chunks.append(allocator, data[pos + 8 .. pos + 8 + len]);
        } else if (ctype == PngChunk.PLTE) {
            plte = data[pos + 8 .. pos + 8 + len];
        } else if (ctype == PngChunk.tRNS) {
            trns = data[pos + 8 .. pos + 8 + len];
        } else if (ctype == PngChunk.IEND) {
            break;
        }

        pos += 12 + len; // header + data + CRC
    }

    if (idat_chunks.items.len == 0) {
        return error.NoPngImageData;
    }

    // Concatenate IDAT chunks and decompress
    var total_compressed: usize = 0;
    for (idat_chunks.items) |chunk| {
        total_compressed += chunk.len;
    }

    const compressed_data = try allocator.alloc(u8, total_compressed);
    defer allocator.free(compressed_data);

    var offset: usize = 0;
    for (idat_chunks.items) |chunk| {
        @memcpy(compressed_data[offset .. offset + chunk.len], chunk);
        offset += chunk.len;
    }

    // Calculate expected decompressed size
    // Each scanline has: 1 filter byte + scanline_width pixels
    const scanline_width = calculateScanlineWidth(width, color_type, bit_depth);
    const expected_raw_len = height * (1 + scanline_width);

    // Decompress using zlib
    const zlib = @import("zlib.zig");
    const raw_data = try zlib.decompress(allocator, compressed_data, expected_raw_len);
    defer allocator.free(raw_data);

    // Determine bytes per pixel and output color space
    const bytes_per_pixel: usize = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1, // Will need palette expansion
        .grayscale_alpha => 2,
        .rgba => 4,
    };
    _ = bytes_per_pixel;

    const has_alpha = (color_type == .rgba or color_type == .grayscale_alpha);
    const output_color_space: ColorSpace = switch (color_type) {
        .grayscale, .grayscale_alpha => .device_gray,
        .rgb, .rgba, .indexed => .device_rgb,
    };

    // Verify decompressed data size
    if (raw_data.len < expected_raw_len) {
        return error.InvalidPngData;
    }

    // Unfilter the image data
    const unfiltered = try unfilterPng(allocator, raw_data, width, height, color_type, bit_depth);
    defer allocator.free(unfiltered);

    // Separate RGB and alpha channels, compress each
    var rgb_data: []u8 = undefined;
    var alpha_data: ?[]u8 = null;

    if (has_alpha) {
        const separated = try separateAlphaChannel(allocator, unfiltered, width, height, color_type);
        rgb_data = separated.rgb;
        alpha_data = separated.alpha;
    } else if (color_type == .indexed) {
        const palette = plte orelse return error.MissingPngPalette;
        const expanded = try expandIndexedPng(allocator, unfiltered, width, height, bit_depth, palette, trns);
        rgb_data = expanded.rgb;
        alpha_data = expanded.alpha;
    } else {
        // RGB or grayscale without alpha - use data directly
        rgb_data = try allocator.dupe(u8, unfiltered);
    }
    errdefer allocator.free(rgb_data);
    errdefer if (alpha_data) |a| allocator.free(a);

    // Compress RGB data for PDF embedding
    const compressed_rgb = try zlib.compressLevel(allocator, rgb_data, level);
    allocator.free(rgb_data);
    errdefer allocator.free(compressed_rgb);

    // Compress alpha data if present
    var compressed_alpha: ?[]u8 = null;
    if (alpha_data) |alpha| {
        compressed_alpha = try zlib.compressLevel(allocator, alpha, level);
        allocator.free(alpha);
    }
    errdefer if (compressed_alpha) |a| allocator.free(a);

    // Free original data if we own it (we've processed it)
    if (owns_data) {
        allocator.free(data);
    }

    const image = try allocator.create(Image);
    image.* = .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .color_space = output_color_space,
        // Indexed data is expanded to 8-bit RGB regardless of index depth.
        .bits_per_component = if (color_type == .indexed) 8 else bit_depth,
        .format = .png,
        .data = compressed_rgb,
        .alpha_data = compressed_alpha,
        .icc_profile = null, // PNG ICC profile extraction not yet implemented
        .owns_data = true, // We created the compressed data
    };
    return image;
}

/// Expand unfiltered indexed-color scanlines (palette indices at 1/2/4/8
/// bits) into 8-bit RGB, plus an alpha channel when tRNS marks any palette
/// entry as translucent. Entries beyond the tRNS array are opaque.
fn expandIndexedPng(
    allocator: std.mem.Allocator,
    unfiltered: []const u8,
    width: u32,
    height: u32,
    bit_depth: u8,
    palette: []const u8,
    trns: ?[]const u8,
) !struct { rgb: []u8, alpha: ?[]u8 } {
    if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8) {
        return error.UnsupportedPngBitDepth;
    }
    const scanline_width = calculateScanlineWidth(width, .indexed, bit_depth);

    const rgb = try allocator.alloc(u8, @as(usize, width) * height * 3);
    errdefer allocator.free(rgb);
    var alpha: ?[]u8 = if (trns != null) try allocator.alloc(u8, @as(usize, width) * height) else null;
    errdefer if (alpha) |a| allocator.free(a);

    var any_translucent = false;
    for (0..height) |y| {
        const row = unfiltered[y * scanline_width ..];
        for (0..width) |x| {
            const bit_pos = x * bit_depth;
            const byte = row[bit_pos / 8];
            const shift: u3 = @intCast(8 - bit_depth - (bit_pos % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(bit_depth)) - 1);
            const idx: usize = (byte >> shift) & mask;

            const out = (y * width + x) * 3;
            if (idx * 3 + 2 >= palette.len) return error.InvalidPngPaletteIndex;
            rgb[out] = palette[idx * 3];
            rgb[out + 1] = palette[idx * 3 + 1];
            rgb[out + 2] = palette[idx * 3 + 2];
            if (alpha) |a| {
                const av: u8 = if (idx < trns.?.len) trns.?[idx] else 255;
                a[y * width + x] = av;
                if (av != 255) any_translucent = true;
            }
        }
    }

    // A tRNS chunk whose entries are all opaque needs no SMask.
    if (alpha != null and !any_translucent) {
        allocator.free(alpha.?);
        alpha = null;
    }
    return .{ .rgb = rgb, .alpha = alpha };
}

fn calculateScanlineWidth(width: u32, color_type: PngColorType, bit_depth: u8) usize {
    const samples_per_pixel: usize = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };
    const bits_per_pixel = samples_per_pixel * bit_depth;
    return (width * bits_per_pixel + 7) / 8;
}

fn unfilterPng(
    allocator: std.mem.Allocator,
    raw_data: []const u8,
    width: u32,
    height: u32,
    color_type: PngColorType,
    bit_depth: u8,
) ![]u8 {
    const bytes_per_pixel: usize = switch (color_type) {
        .grayscale => if (bit_depth < 8) 1 else bit_depth / 8,
        .rgb => 3 * (bit_depth / 8),
        .indexed => 1,
        .grayscale_alpha => 2 * (bit_depth / 8),
        .rgba => 4 * (bit_depth / 8),
    };

    const scanline_width = calculateScanlineWidth(width, color_type, bit_depth);
    const output = try allocator.alloc(u8, height * scanline_width);
    errdefer allocator.free(output);

    var prev_row: ?[]const u8 = null;

    for (0..height) |y| {
        const row_start = y * (1 + scanline_width);
        if (row_start >= raw_data.len) return error.InvalidPngData;

        const filter_type = raw_data[row_start];
        const row_data = raw_data[row_start + 1 ..][0..scanline_width];
        const out_row = output[y * scanline_width ..][0..scanline_width];

        switch (filter_type) {
            0 => {
                // None - copy as-is
                @memcpy(out_row, row_data);
            },
            1 => {
                // Sub - add left pixel
                for (0..scanline_width) |x| {
                    const left: u8 = if (x >= bytes_per_pixel) out_row[x - bytes_per_pixel] else 0;
                    out_row[x] = row_data[x] +% left;
                }
            },
            2 => {
                // Up - add pixel above
                for (0..scanline_width) |x| {
                    const up: u8 = if (prev_row) |pr| pr[x] else 0;
                    out_row[x] = row_data[x] +% up;
                }
            },
            3 => {
                // Average - add average of left and up
                for (0..scanline_width) |x| {
                    const left: u16 = if (x >= bytes_per_pixel) out_row[x - bytes_per_pixel] else 0;
                    const up: u16 = if (prev_row) |pr| pr[x] else 0;
                    out_row[x] = row_data[x] +% @as(u8, @intCast((left + up) / 2));
                }
            },
            4 => {
                // Paeth predictor
                for (0..scanline_width) |x| {
                    const a: i16 = if (x >= bytes_per_pixel) out_row[x - bytes_per_pixel] else 0;
                    const b: i16 = if (prev_row) |pr| pr[x] else 0;
                    const c: i16 = if (x >= bytes_per_pixel and prev_row != null)
                        prev_row.?[x - bytes_per_pixel]
                    else
                        0;
                    out_row[x] = row_data[x] +% paethPredictor(a, b, c);
                }
            },
            else => return error.InvalidPngFilterType,
        }

        prev_row = out_row;
    }

    return output;
}

fn paethPredictor(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @intCast(a);
    } else if (pb <= pc) {
        return @intCast(b);
    } else {
        return @intCast(c);
    }
}

const SeparatedChannels = struct {
    rgb: []u8,
    alpha: []u8,
};

fn separateAlphaChannel(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    color_type: PngColorType,
) !SeparatedChannels {
    const pixel_count = width * height;

    switch (color_type) {
        .rgba => {
            // RGBA -> RGB + A
            const rgb = try allocator.alloc(u8, pixel_count * 3);
            errdefer allocator.free(rgb);
            const alpha = try allocator.alloc(u8, pixel_count);

            for (0..pixel_count) |i| {
                rgb[i * 3 + 0] = data[i * 4 + 0]; // R
                rgb[i * 3 + 1] = data[i * 4 + 1]; // G
                rgb[i * 3 + 2] = data[i * 4 + 2]; // B
                alpha[i] = data[i * 4 + 3]; // A
            }

            return .{ .rgb = rgb, .alpha = alpha };
        },
        .grayscale_alpha => {
            // GA -> G + A
            const gray = try allocator.alloc(u8, pixel_count);
            errdefer allocator.free(gray);
            const alpha = try allocator.alloc(u8, pixel_count);

            for (0..pixel_count) |i| {
                gray[i] = data[i * 2 + 0]; // G
                alpha[i] = data[i * 2 + 1]; // A
            }

            return .{ .rgb = gray, .alpha = alpha };
        },
        else => return error.NoAlphaChannel,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "detect JPEG format" {
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46 };
    try std.testing.expectEqual(ImageFormat.jpeg, Image.detectFormat(&jpeg_header).?);
}

test "detect PNG format" {
    const png_header = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqual(ImageFormat.png, Image.detectFormat(&png_header).?);
}

test "unknown format" {
    const unknown = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    try std.testing.expectEqual(@as(?ImageFormat, null), Image.detectFormat(&unknown));
}

test "parse JPEG file" {
    const allocator = std.testing.allocator;

    const image = Image.fromFile(std.testing.io, allocator, "test/images/madonna_and_child_1939.1.256.jpg") catch |err| {
        // Skip test if file doesn't exist
        if (err == error.FileNotFound) return;
        return err;
    };
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 2924), image.width);
    try std.testing.expectEqual(@as(u32, 4096), image.height);
    try std.testing.expectEqual(ColorSpace.device_rgb, image.color_space);
    try std.testing.expectEqual(ImageFormat.jpeg, image.format);
    try std.testing.expectEqual(@as(?[]const u8, null), image.alpha_data);
}

test "parse PNG file" {
    const allocator = std.testing.allocator;

    const image = Image.fromFile(std.testing.io, allocator, "test/images/robot.png") catch |err| {
        // Skip test if file doesn't exist
        if (err == error.FileNotFound) return;
        return err;
    };
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 1024), image.width);
    try std.testing.expectEqual(@as(u32, 1536), image.height);
    try std.testing.expectEqual(ColorSpace.device_rgb, image.color_space);
    try std.testing.expectEqual(ImageFormat.png, image.format);
    // PNG with alpha should have alpha_data
    try std.testing.expect(image.alpha_data != null);
}

test "parse indexed PNG with tRNS (2-bit palette)" {
    const allocator = std.testing.allocator;

    // Hand-built 4x2 indexed PNG, bit depth 2. Palette: red, green, blue;
    // tRNS marks blue as alpha 128. Pixels: (0,1,2,0) / (2,1,0,2).
    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x02, 0x03, 0x00, 0x00, 0x00, 0x02, 0xC6, 0x95,
        0xF0, 0x00, 0x00, 0x00, 0x09, 0x50, 0x4C, 0x54, 0x45, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x2D, 0x4A, 0xCD, 0x8A, 0x00, 0x00, 0x00, 0x03, 0x74, 0x52, 0x4E, 0x53, 0xFF, 0xFF,
        0x80, 0x3A, 0x72, 0x8E, 0x61, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
        0x90, 0x60, 0x98, 0x04, 0x00, 0x00, 0xDE, 0x00, 0xAB, 0x1A, 0xFC, 0x37, 0x77, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    const image = try Image.fromMemory(allocator, &png);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(ColorSpace.device_rgb, image.color_space);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_component); // expanded from 2-bit indices

    const zlib = @import("zlib.zig");
    const rgb = try zlib.decompress(allocator, image.data, 24);
    defer allocator.free(rgb);
    try std.testing.expectEqualSlices(u8, &.{
        255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 0, 0, // red green blue red
        0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 255, // blue green red blue
    }, rgb);

    const alpha = try zlib.decompress(allocator, image.alpha_data.?, 8);
    defer allocator.free(alpha);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 128, 255, 128, 255, 255, 128 }, alpha);
}

test "Paeth predictor" {
    // Test basic Paeth prediction
    // p = a + b - c = 10 + 20 - 5 = 25
    // pa = |25 - 10| = 15, pb = |25 - 20| = 5, pc = |25 - 5| = 20
    // pb is smallest, so return b = 20
    try std.testing.expectEqual(@as(u8, 20), paethPredictor(10, 20, 5));
    try std.testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 100), paethPredictor(100, 100, 100));
}
