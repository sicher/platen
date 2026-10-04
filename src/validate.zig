//! Number validation at the Document API boundary.
//!
//! Every f64 a caller hands to a fallible Document entry point must be
//! finite and within ±max_value; otherwise the call returns
//! error.InvalidNumber before touching the document. This is the
//! precondition format.writeF64N and the fixed-size content-stream
//! buffers rely on: they never see NaN, infinities, or magnitudes whose
//! digits would overflow a u64 or the buffer (found by the Document fuzz
//! target: a huge drawCircle radius panicked in writeF64N).
//!
//! Error, not clamp: a silently moved coordinate is a wrong document.

const std = @import("std");

/// Largest accepted magnitude, in points (or unitless for factors).
/// ~353 m: 70x the largest PDF page (14,400 pt), so off-page content and
/// translations fit, while products inside transforms stay <= 1e12 and
/// every formatted number keeps its fixed decimals within the buffers.
pub const max_value: f64 = 1_000_000;

pub const Error = error{InvalidNumber};

/// Reject NaN, infinities, and |v| > max_value.
pub inline fn number(v: f64) Error!void {
    // NaN fails every comparison, so it lands in the error branch.
    if (!(@abs(v) <= max_value)) return error.InvalidNumber;
}

/// Validate every f64 reachable through `value`'s fields: structs,
/// tagged unions (active field), optionals, and arrays are walked;
/// pointers and slices are not (validate those explicitly), so font and
/// asset handles inside styles are skipped.
pub fn check(value: anytype) Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => try number(value),
        .@"struct" => |info| {
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") try check(@field(value, name));
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("validate.check: untagged union " ++ @typeName(T));
            switch (value) {
                inline else => |payload| try check(payload),
            }
        },
        .optional => if (value) |v| try check(v),
        .array => for (value) |item| try check(item),
        else => {},
    }
}

/// Validate each element of a slice.
pub fn checkEach(items: anytype) Error!void {
    for (items) |item| try check(item);
}

test "number accepts the limit and rejects beyond it" {
    try number(0);
    try number(max_value);
    try number(-max_value);
    try std.testing.expectError(error.InvalidNumber, number(std.math.nextAfter(f64, max_value, std.math.inf(f64))));
    try std.testing.expectError(error.InvalidNumber, number(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidNumber, number(-std.math.inf(f64)));
}

test "check walks structs, unions, optionals, arrays" {
    const U = union(enum) { a: f64, b: void, p: *const f64 };
    const S = struct { x: f64, u: U, o: ?f64 = null, arr: [2]f64 = .{ 0, 0 }, n: u32 = 7 };
    const huge: f64 = 1e300;

    try check(S{ .x = 1, .u = .b });
    try check(S{ .x = 1, .u = .{ .p = &huge } }); // pointers are not followed
    try std.testing.expectError(error.InvalidNumber, check(S{ .x = 1e300, .u = .b }));
    try std.testing.expectError(error.InvalidNumber, check(S{ .x = 1, .u = .{ .a = std.math.nan(f64) } }));
    try std.testing.expectError(error.InvalidNumber, check(S{ .x = 1, .u = .b, .o = std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidNumber, check(S{ .x = 1, .u = .b, .arr = .{ 0, 2e6 } }));
}
