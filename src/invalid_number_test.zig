//! Regression tests: every Document entry point rejects NaN, infinities,
//! and magnitudes above validate.max_value with error.InvalidNumber, and
//! leaves the document unchanged. (Found by `zig build test --fuzz`: a
//! huge coordinate in drawCircle panicked in format.writeF64N.)

const std = @import("std");
const platen = @import("platen.zig");

const Document = platen.Document;
const Rect = platen.Rect;
const Point = platen.Point;
const Color = platen.Color;

const bad_values = [_]f64{
    std.math.nan(f64),
    std.math.inf(f64),
    -std.math.inf(f64),
    1e300,
    -1e300,
    1_000_000.5,
};

/// Shared fixtures so each case can reach its entry point.
const Fixture = struct {
    svg: *platen.Svg,
    image: *platen.Image,
    gradient: usize,
};

const helv = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };

fn region(v: f64) platen.Region {
    return .{ .x = v, .y = 72, .width = 200, .height = 200 };
}

const Case = struct {
    name: []const u8,
    run: *const fn (*Document, f64, *Fixture) anyerror!void,
};

const cases = [_]Case{
    .{ .name = "addPage size", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.addPage(.{ .size = .{ .width = v, .height = 800 } });
        }
    }.f },
    .{ .name = "insertPage margins", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.insertPage(0, .{ .margins = .{ .left = v } });
        }
    }.f },
    .{ .name = "drawImage", .run = struct {
        fn f(d: *Document, v: f64, x: *Fixture) !void {
            try d.drawImage(x.image, .{ .x = v, .y = 10, .width = 10, .height = 10 });
        }
    }.f },
    .{ .name = "drawSvg", .run = struct {
        fn f(d: *Document, v: f64, x: *Fixture) !void {
            try d.drawSvg(x.svg, .{ .x = 10, .y = v });
        }
    }.f },
    .{ .name = "addLink rect", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.addLink(.{ .x = v, .y = 0, .width = 1, .height = 1 }, .{ .page_index = 0, .y = 0 });
        }
    }.f },
    .{ .name = "addLink dest", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.addLink(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .page_index = 0, .y = v });
        }
    }.f },
    .{ .name = "addExternalLink", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.addExternalLink(.{ .x = 0, .y = 0, .width = v, .height = 1 }, "https://example.com");
        }
    }.f },
    .{ .name = "writeAt pos", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            _ = try d.writeAt(.{ .x = v, .y = 50 }, "x", helv, .{});
        }
    }.f },
    .{ .name = "writeAt size", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            _ = try d.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = platen.Font.helvetica, .size = v }, .{});
        }
    }.f },
    .{ .name = "writeAt char_spacing", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            _ = try d.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = platen.Font.helvetica, .size = 12, .char_spacing = v }, .{});
        }
    }.f },
    .{ .name = "writeAt color", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            _ = try d.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = platen.Font.helvetica, .size = 12, .color = Color.rgbf(v, 0, 0) }, .{});
        }
    }.f },
    .{ .name = "write region", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var r = region(v);
            _ = try d.write(&r, "x", helv, .{});
        }
    }.f },
    .{ .name = "write line_height", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var r = region(72);
            _ = try d.write(&r, "x", helv, .{ .line_height = v });
        }
    }.f },
    .{ .name = "writeBlock padding", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var r = region(72);
            r.padding.top = v;
            _ = try d.writeBlock(&r, "x", helv, .{});
        }
    }.f },
    .{ .name = "writeStyled cursor", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var st = d.createStyledText();
            defer st.deinit();
            try st.append("x", .{});
            var r = region(72);
            r.cursor_y = v;
            _ = try d.writeStyled(&r, &st, helv, .{});
        }
    }.f },
    .{ .name = "writeStyled span color", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var st = d.createStyledText();
            defer st.deinit();
            try st.append("x", .{ .color = .{ .greyscale_val = v } });
            var r = region(72);
            _ = try d.writeStyled(&r, &st, helv, .{});
        }
    }.f },
    .{ .name = "measureStyled", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            _ = try d.measureStyled("x", .{ .font = platen.Font.helvetica, .size = v });
        }
    }.f },
    .{ .name = "drawRegion border", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var r = region(72);
            r.border = .{ .top = true, .style = .{ .width = v } };
            try d.drawRegion(r);
        }
    }.f },
    .{ .name = "drawLine point", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawLine(.{ .x = 0, .y = 0 }, .{ .x = v, .y = 0 }, .{});
        }
    }.f },
    .{ .name = "drawLine dash", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawLine(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .dash = .{ .dash = v, .gap = 1 } });
        }
    }.f },
    .{ .name = "drawRect fill opacity", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .fill = .{ .opacity = v } });
        }
    }.f },
    .{ .name = "drawRoundedRect radius", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawRoundedRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, v, .{});
        }
    }.f },
    .{ .name = "drawEllipse", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawEllipse(.{ .x = 0, .y = 0, .width = v, .height = 10 }, .{});
        }
    }.f },
    .{ .name = "drawCircle (fuzz finding)", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.drawCircle(.{ .x = 50, .y = 50 }, v, .{});
        }
    }.f },
    .{ .name = "drawPolygon", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            const pts = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = v } };
            try d.drawPolygon(&pts, .{});
        }
    }.f },
    .{ .name = "drawPath", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var p = d.createPath();
            defer p.deinit();
            try p.moveTo(.{ .x = 0, .y = 0 });
            try p.curveTo(.{ .x = 1, .y = 1 }, .{ .x = v, .y = 2 }, .{ .x = 3, .y = 3 });
            try d.drawPath(&p, .{});
        }
    }.f },
    .{ .name = "clipPath", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            var p = d.createPath();
            defer p.deinit();
            try p.moveTo(.{ .x = 0, .y = 0 });
            try p.quadTo(.{ .x = v, .y = 1 }, .{ .x = 2, .y = 2 });
            try d.clipPath(&p);
        }
    }.f },
    .{ .name = "clipRect", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.clipRect(.{ .x = 0, .y = v, .width = 10, .height = 10 });
        }
    }.f },
    .{ .name = "translate", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.translate(0, v);
        }
    }.f },
    .{ .name = "rotateAt degrees", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.rotateAt(.{ .x = 0, .y = 0 }, v);
        }
    }.f },
    .{ .name = "scaleAt factor", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            try d.scaleAt(.{ .x = 10, .y = 10 }, v, 1);
        }
    }.f },
    .{ .name = "addLinearGradient", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            const stops = [_]platen.ColorStop{ .{ .offset = 0, .color = Color.red }, .{ .offset = 1, .color = Color.blue } };
            _ = try d.addLinearGradient(.{ .x0 = v, .y0 = 0, .x1 = 1, .y1 = 0, .stops = &stops });
        }
    }.f },
    .{ .name = "addRadialGradient stop", .run = struct {
        fn f(d: *Document, v: f64, _: *Fixture) !void {
            const stops = [_]platen.ColorStop{ .{ .offset = 0, .color = Color.red }, .{ .offset = v, .color = Color.blue } };
            _ = try d.addRadialGradient(.{ .x0 = 0, .y0 = 0, .r0 = 0, .x1 = 0, .y1 = 0, .r1 = 5, .stops = &stops });
        }
    }.f },
    .{ .name = "fillRectGradient", .run = struct {
        fn f(d: *Document, v: f64, x: *Fixture) !void {
            try d.fillRectGradient(.{ .x = 0, .y = 0, .width = v, .height = 1 }, x.gradient);
        }
    }.f },
};

/// Everything a rejected call could have mutated.
const Snapshot = struct {
    pages: usize,
    gradients: usize,
    content: usize = 0,
    commands: usize = 0,
    annotations: usize = 0,
    images: usize = 0,
    svgs: usize = 0,
    opacity_states: usize = 0,
    state_depth: usize = 0,

    fn take(d: *const Document) Snapshot {
        var s = Snapshot{ .pages = d.pages.items.len, .gradients = d.gradients.items.len };
        for (d.pages.items) |p| {
            s.content += p.content.items.len;
            s.commands += p.commands.items.len;
            s.annotations += p.annotations.items.len;
            s.images += p.used_images.items.len;
            s.svgs += p.used_svgs.items.len;
            s.opacity_states += p.opacity_states.items.len;
            s.state_depth += p.state_depth;
        }
        return s;
    }
};

test "every entry point rejects invalid numbers and leaves the document unchanged" {
    const allocator = std.testing.allocator;

    const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/images/robot.png", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(png);
    const image = try platen.Image.fromMemory(allocator, png);
    defer image.deinit();
    const svg = try platen.Svg.fromMemory(allocator,
        \\<svg width="40" height="40"><rect width="40" height="40" fill="blue"/></svg>
    );
    defer svg.deinit();

    for (cases) |case| {
        for (bad_values) |v| {
            var doc = Document.init(allocator, std.testing.io);
            defer doc.deinit();
            try doc.addPage(.{});
            const stops = [_]platen.ColorStop{ .{ .offset = 0, .color = Color.red }, .{ .offset = 1, .color = Color.blue } };
            var fx = Fixture{
                .svg = svg,
                .image = image,
                .gradient = try doc.addLinearGradient(.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0, .stops = &stops }),
            };

            const before = Snapshot.take(&doc);
            case.run(&doc, v, &fx) catch |err| {
                if (err != error.InvalidNumber) {
                    std.debug.print("case '{s}' value {d}: got {t}\n", .{ case.name, v, err });
                    return err;
                }
                try std.testing.expectEqual(before, Snapshot.take(&doc));
                continue;
            };
            std.debug.print("case '{s}' value {d}: accepted\n", .{ case.name, v });
            return error.TestUnexpectedResult;
        }
    }
}

test "the limit itself is accepted" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const max = platen.max_value;
    try doc.drawLine(.{ .x = -max, .y = max }, .{ .x = max, .y = -max }, .{});
    try doc.drawCircle(.{ .x = max, .y = max }, max, .{});
    try doc.clipRect(.{ .x = -max, .y = -max, .width = max, .height = max });
    try doc.scaleAt(.{ .x = max, .y = -max }, max, -max);
    const pdf = try doc.output();
    defer std.testing.allocator.free(pdf);
}

test "Outline rejects invalid destinations" {
    var doc = Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    var outline = doc.createOutline();
    defer outline.deinit();
    for (bad_values) |v| {
        try std.testing.expectError(error.InvalidNumber, outline.add("x", .{ .page_index = 0, .y = v }));
    }
    const item = try outline.add("ok", .{ .page_index = 0, .y = 0 });
    try std.testing.expectError(error.InvalidNumber, outline.addChild(item, "x", .{ .page_index = 0, .y = std.math.nan(f64) }));
}
