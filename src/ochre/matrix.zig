//! The matrices of the conversions, from CSS Color 4's sample code:
//! https://drafts.csswg.org/css-color-4/conversions.js
//!
//! The tables are copied from there unchanged. Only the products are ours, and
//! they are taken at comptime so `f32` and `f64` both round from the same exact
//! values.

const Table = [3][3]comptime_float;

const srgb_to_xyz: Table = .{
    .{ 506752.0 / 1228815.0, 87881.0 / 245763.0, 12673.0 / 70218.0 },
    .{ 87098.0 / 409605.0, 175762.0 / 245763.0, 12673.0 / 175545.0 },
    .{ 7918.0 / 409605.0, 87881.0 / 737289.0, 1001167.0 / 1053270.0 },
};

pub const xyz_to_srgb: Table = .{
    .{ 12831.0 / 3959.0, -329.0 / 214.0, -1974.0 / 3959.0 },
    .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
    .{ 705.0 / 12673.0, -2585.0 / 12673.0, 705.0 / 667.0 },
};

const xyz_to_lms: Table = .{
    .{ 0.8190224379967030, 0.3619062600528904, -0.1288737815209879 },
    .{ 0.0329836539323885, 0.9292868615863434, 0.0361446663506424 },
    .{ 0.0481771893596242, 0.2642395317527308, 0.6335478284694309 },
};

const lms_to_xyz: Table = .{
    .{ 1.2268798758459243, -0.5578149944602171, 0.2813910456659647 },
    .{ -0.0405757452148008, 1.1122868032803170, -0.0717110580655164 },
    .{ -0.0763729366746601, -0.4214933324022432, 1.5869240198367816 },
};

pub const lms_to_oklab: Table = .{
    .{ 0.2104542683093140, 0.7936177747023054, -0.0040720430116193 },
    .{ 1.9779985324311684, -2.4285922420485799, 0.4505937096174110 },
    .{ 0.0259040424655478, 0.7827717124575296, -0.8086757549230774 },
};

pub const oklab_to_lms: Table = .{
    .{ 1.0000000000000000, 0.3963377773761749, 0.2158037573099136 },
    .{ 1.0000000000000000, -0.1055613458156586, -0.0638541728258133 },
    .{ 1.0000000000000000, -0.0894841775298119, -1.2914855480194092 },
};

pub const srgb_to_lms: Table = product(xyz_to_lms, srgb_to_xyz);
pub const lms_to_srgb: Table = product(xyz_to_srgb, lms_to_xyz);

fn product(comptime a: Table, comptime b: Table) Table {
    var result: Table = undefined;
    for (0..3) |row| {
        for (0..3) |col| {
            result[row][col] = a[row][0] * b[0][col] + a[row][1] * b[1][col] + a[row][2] * b[2][col];
        }
    }
    return result;
}

/// `m` times the column vector (`x`, `y`, `z`).
pub fn apply(comptime T: type, comptime m: Table, x: T, y: T, z: T) [3]T {
    return .{
        @as(T, m[0][0]) * x + @as(T, m[0][1]) * y + @as(T, m[0][2]) * z,
        @as(T, m[1][0]) * x + @as(T, m[1][1]) * y + @as(T, m[1][2]) * z,
        @as(T, m[2][0]) * x + @as(T, m[2][1]) * y + @as(T, m[2][2]) * z,
    };
}
