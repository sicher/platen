//! Version information for platen.
//!
//! The version is single-sourced from build.zig.zon (build.zig passes it in
//! as the `build_options` module), which `devkit release X.Y.Z` sets.

pub const version: []const u8 = @import("build_options").version;
pub const name = "platen";
pub const full = name ++ " " ++ version;

test "version comes from build.zig.zon" {
    const std = @import("std");
    // The manifest is the source of truth; compare at runtime from the
    // repo root (where `zig build test` runs).
    const zon = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig.zon", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(zon);
    var buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, ".version = \"{s}\",", .{version});
    try std.testing.expect(std.mem.indexOf(u8, zon, needle) != null);
}
