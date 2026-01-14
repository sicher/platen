//! zpdf command line tool

const std = @import("std");
const zpdf = @import("zpdf");

pub fn main() !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zpdf version {s}\n", .{zpdf.version}) catch unreachable;
    try std.fs.File.stdout().writeAll(msg);
}
