//! ochre: color math and representation. See DESIGN.md.

const std = @import("std");

const rgb = @import("rgb.zig");
const oklab = @import("oklab.zig");
const parsing = @import("parse.zig");
const ramps = @import("ramp.zig");

pub const Rgba8 = rgb.Rgba8;
pub const Srgb = rgb.Srgb;
pub const Gamut = rgb.Gamut;
pub const LinearSrgb = rgb.LinearSrgb;
pub const Oklab = oklab.Oklab;
pub const Oklch = oklab.Oklch;
pub const HuePath = oklab.HuePath;
pub const Parsed = parsing.Parsed;
pub const parse = parsing.parse;
pub const ParseOptions = parsing.Options;
pub const ramp = ramps.ramp;
pub const RampOptions = ramps.Options;
pub const Ramp = ramps.Ramp;
pub const Stop = ramps.Stop;
pub const pixels = @import("pixels.zig");
