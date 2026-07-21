//! Invoice throughput benchmark
//!
//! Mirrors the published SlothPDF benchmark as closely as possible:
//! N unique single-page A4 invoices with 3-10 line items, custom fonts
//! (Inter Regular + Bold) and the platen wordmark embedded as vector SVG,
//! rendered with unique data per render. Reports latency
//! per PDF and PDFs/sec.
//!
//! Run with: zig build bench-invoice -Doptimize=ReleaseFast -- [options]
//!
//! Options:
//!   --count=N       Number of invoices to render (default: 1000)
//!   --compress=N    Compression level 0-9 (default: 0, matching SlothPDF's
//!                   uncompressed default mode)
//!   --threads=N     Worker threads, each rendering its own documents
//!                   (default: 1; the library is stateless, so concurrent
//!                   documents need no locking)
//!   --shared        Parse fonts and logo once (FontFace + caller-owned
//!                   Svg) instead of per document
//!   --output=PATH   Write a sample invoice to a file for inspection

const std = @import("std");
const platen = @import("platen");

var app_io: std.Io = undefined;

fn nanoNow() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

const Config = struct {
    count: u32 = 1000,
    compress: i32 = 0,
    threads: u32 = 1,
    shared: bool = false,
    output_path: ?[]const u8 = null,
};

const customers = [_]struct { name: []const u8, street: []const u8, city: []const u8 }{
    .{ .name = "Acme Corporation", .street = "742 Evergreen Terrace", .city = "Springfield, OR 97477" },
    .{ .name = "Globex International", .street = "1 Hammond Drive", .city = "Cypress Creek, CA 90210" },
    .{ .name = "Initech LLC", .street = "4120 Freidrich Lane", .city = "Austin, TX 78744" },
    .{ .name = "Umbrella Health", .street = "545 Raccoon Blvd", .city = "Raccoon City, WI 53186" },
    .{ .name = "Stark Industries", .street = "10880 Malibu Point", .city = "Malibu, CA 90265" },
    .{ .name = "Wayne Enterprises", .street = "1007 Mountain Drive", .city = "Gotham, NJ 07001" },
    .{ .name = "Tyrell Corp", .street = "2019 Nexus Way", .city = "Los Angeles, CA 90013" },
    .{ .name = "Soylent Foods", .street = "2022 Green Street", .city = "New York, NY 10001" },
    .{ .name = "Aperture Science", .street = "1 Portal Park", .city = "Cleveland, OH 44101" },
    .{ .name = "Hooli Inc", .street = "1401 Silicon Ave", .city = "Palo Alto, CA 94301" },
    .{ .name = "Vandelay Industries", .street = "129 W 81st Street", .city = "New York, NY 10024" },
    .{ .name = "Wernham Hogg", .street = "Slough Trading Estate", .city = "Slough, SL1 4QT, UK" },
};

const line_items = [_]struct { desc: []const u8, unit_cents: u32 }{
    .{ .desc = "Consulting services (hourly)", .unit_cents = 15000 },
    .{ .desc = "Cloud hosting - standard tier", .unit_cents = 4900 },
    .{ .desc = "Cloud hosting - premium tier", .unit_cents = 14900 },
    .{ .desc = "SSL certificate (annual)", .unit_cents = 8900 },
    .{ .desc = "Domain registration (.com)", .unit_cents = 1450 },
    .{ .desc = "Design retainer", .unit_cents = 250000 },
    .{ .desc = "API access - 100k requests", .unit_cents = 9900 },
    .{ .desc = "On-site training day", .unit_cents = 120000 },
    .{ .desc = "Priority support (monthly)", .unit_cents = 19900 },
    .{ .desc = "Database migration", .unit_cents = 75000 },
    .{ .desc = "Performance audit", .unit_cents = 95000 },
    .{ .desc = "Custom report module", .unit_cents = 62500 },
    .{ .desc = "License renewal - 5 seats", .unit_cents = 49500 },
    .{ .desc = "Data backup service (monthly)", .unit_cents = 2900 },
    .{ .desc = "Email delivery - 50k sends", .unit_cents = 3500 },
    .{ .desc = "PDF generation add-on", .unit_cents = 9500 },
    .{ .desc = "Load balancer (monthly)", .unit_cents = 1800 },
    .{ .desc = "Monitoring dashboard", .unit_cents = 5900 },
    .{ .desc = "Penetration test", .unit_cents = 180000 },
    .{ .desc = "Accessibility review", .unit_cents = 45000 },
};

const Assets = struct {
    inter_regular: []u8,
    inter_bold: []u8,
    logo_svg: []u8,
    // --shared mode: parsed once, reused by every document (and thread)
    shared_regular: ?platen.FontFace = null,
    shared_bold: ?platen.FontFace = null,
    shared_svg: ?*platen.Svg = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    app_io = init.io;

    const config = parseArgs(init.minimal.args) catch {
        std.debug.print("Usage: bench-invoice [--count=N] [--compress=N] [--threads=N] [--output=PATH]\n", .{});
        return;
    };

    // Load assets once (process lifetime), mirroring SlothPDF's init() which
    // preloads fonts and images before its measured loop.
    var assets = Assets{
        .inter_regular = try std.Io.Dir.cwd().readFileAlloc(app_io, "test/fonts/Inter/Inter-Regular.ttf", allocator, .limited(16 * 1024 * 1024)),
        .inter_bold = try std.Io.Dir.cwd().readFileAlloc(app_io, "test/fonts/Inter/Inter-Bold.ttf", allocator, .limited(16 * 1024 * 1024)),
        .logo_svg = try std.Io.Dir.cwd().readFileAlloc(app_io, "platen.svg", allocator, .limited(1024 * 1024)),
    };
    if (config.shared) {
        assets.shared_regular = try platen.FontFace.fromMemory(allocator, assets.inter_regular);
        assets.shared_bold = try platen.FontFace.fromMemory(allocator, assets.inter_bold);
        assets.shared_svg = try platen.Svg.fromMemory(allocator, assets.logo_svg);
    }
    defer {
        if (assets.shared_regular) |*s| s.deinit();
        if (assets.shared_bold) |*s| s.deinit();
        if (assets.shared_svg) |s| {
            s.deinit();
        }
        allocator.free(assets.inter_regular);
        allocator.free(assets.inter_bold);
        allocator.free(assets.logo_svg);
    }

    std.debug.print("=== platen invoice benchmark ===\n", .{});
    std.debug.print("invoices: {d}, compression level: {d}, threads: {d}, shared assets: {}\n\n", .{ config.count, config.compress, config.threads, config.shared });

    // Warmup (excluded from timing; SlothPDF reports post-warmup numbers)
    var prng = std.Random.DefaultPrng.init(0xbe4c4);
    for (0..20) |i| {
        const pdf = try renderInvoice(allocator, assets, @intCast(i), config.compress, prng.random());
        allocator.free(pdf);
    }

    phase_ns = .{ 0, 0, 0, 0 };
    var total_bytes: u64 = 0;
    var elapsed_ns: i128 = 0;

    if (config.threads <= 1) {
        prng = std.Random.DefaultPrng.init(0xbe4c4);
        const t0 = nanoNow();
        for (0..config.count) |i| {
            const pdf = try renderInvoice(allocator, assets, @intCast(i), config.compress, prng.random());
            total_bytes += pdf.len;
            allocator.free(pdf);
        }
        elapsed_ns = nanoNow() - t0;
    } else {
        // Concurrent documents: each worker renders its own share with its
        // own Document instances. The library shares nothing between
        // documents, so no synchronization is needed beyond the join.
        const workers = try allocator.alloc(Worker, config.threads);
        defer allocator.free(workers);

        const per_worker = config.count / config.threads;
        var start: u32 = 0;
        for (workers, 0..) |*worker, t| {
            const n_docs = if (t + 1 == config.threads) config.count - start else per_worker;
            worker.* = .{
                .allocator = allocator,
                .assets = &assets,
                .first_index = start,
                .doc_count = n_docs,
                .compress = config.compress,
            };
            start += n_docs;
        }

        const t0 = nanoNow();
        for (workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }
        for (workers) |*worker| {
            worker.thread.?.join();
        }
        elapsed_ns = nanoNow() - t0;

        for (workers) |*worker| {
            if (worker.err) |e| return e;
            total_bytes += worker.bytes;
        }
    }

    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_pdf_ms = elapsed_ms / @as(f64, @floatFromInt(config.count));
    const per_sec = 1000.0 / per_pdf_ms;

    std.debug.print("total:      {d:.1}ms for {d} PDFs\n", .{ elapsed_ms, config.count });
    std.debug.print("latency:    {d:.3}ms per PDF (wall time / count)\n", .{per_pdf_ms});
    std.debug.print("throughput: {d:.0} PDFs/sec\n", .{per_sec});
    std.debug.print("avg size:   {d:.1} KB\n", .{@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(config.count)) / 1024.0});

    const n = @as(f64, @floatFromInt(config.count));
    std.debug.print("\nper-PDF breakdown (cpu time):\n", .{});
    std.debug.print("  font load:      {d:.3}ms\n", .{@as(f64, @floatFromInt(phase_ns[0])) / n / 1_000_000.0});
    std.debug.print("  logo (svg):     {d:.3}ms\n", .{@as(f64, @floatFromInt(phase_ns[3])) / n / 1_000_000.0});
    std.debug.print("  text+layout:    {d:.3}ms\n", .{@as(f64, @floatFromInt(phase_ns[1])) / n / 1_000_000.0});
    std.debug.print("  output:         {d:.3}ms\n", .{@as(f64, @floatFromInt(phase_ns[2])) / n / 1_000_000.0});

    if (config.output_path) |path| {
        // Render the sample outside the timed loop so --output works in
        // every mode
        var sample_prng = std.Random.DefaultPrng.init(0xbe4c4);
        const pdf = try renderInvoice(allocator, assets, config.count - 1, config.compress, sample_prng.random());
        defer allocator.free(pdf);
        try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = path, .data = pdf });
        std.debug.print("\nwrote sample invoice: {s}\n", .{path});
    }
}

const Worker = struct {
    allocator: std.mem.Allocator,
    assets: *const Assets,
    first_index: u32,
    doc_count: u32,
    compress: i32,
    thread: ?std.Thread = null,
    bytes: u64 = 0,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        var prng = std.Random.DefaultPrng.init(0xbe4c4 ^ (@as(u64, self.first_index) << 20));
        for (0..self.doc_count) |i| {
            const index = self.first_index + @as(u32, @intCast(i));
            const pdf = renderInvoice(self.allocator, self.assets.*, index, self.compress, prng.random()) catch |e| {
                self.err = e;
                return;
            };
            self.bytes += pdf.len;
            self.allocator.free(pdf);
        }
    }
};

/// Accumulated per-phase nanoseconds: [font load, text+layout, output, logo].
/// Updated with atomic adds so the threaded mode can share it.
var phase_ns = [4]u64{ 0, 0, 0, 0 };

fn renderInvoice(allocator: std.mem.Allocator, assets: Assets, index: u32, compress: i32, rand: std.Random) ![]u8 {
    var doc = platen.Document.init(allocator, app_io);
    defer doc.deinit();
    doc.compression_level = compress;

    const t_font = nanoNow();
    // Face styles need no load call at all - the document instantiates its
    // private clones lazily on first use
    const inter: platen.Font = if (assets.shared_regular != null)
        .{ .family = .{
            .regular = &assets.shared_regular.?,
            .bold = &assets.shared_bold.?,
        } }
    else
        try doc.loadFontFamilyFromMemory(.{
            .regular = assets.inter_regular,
            .bold = assets.inter_bold,
        });
    _ = @atomicRmw(u64, &phase_ns[0], .Add, @intCast(nanoNow() - t_font), .monotonic);
    const t_img = nanoNow();
    const logo = assets.shared_svg orelse try doc.loadSvgFromMemory(assets.logo_svg);
    _ = @atomicRmw(u64, &phase_ns[3], .Add, @intCast(nanoNow() - t_img), .monotonic);
    const t_content = nanoNow();

    try doc.addPage(.{ .size = platen.PageSize.A4 });

    const margin: f64 = 50;
    const right: f64 = platen.PageSize.A4.width - margin; // 545.28

    const h2 = platen.TextStyle{ .font = inter, .size = 22, .bold = true, .color = platen.Color.rgb(30, 64, 140) };
    const body = platen.TextStyle{ .font = inter, .size = 9 };
    const body_bold = platen.TextStyle{ .font = inter, .size = 9, .bold = true };
    const small_gray = platen.TextStyle{ .font = inter, .size = 8, .color = platen.Color.dimgray };
    const total_style = platen.TextStyle{ .font = inter, .size = 11, .bold = true };

    var buf: [128]u8 = undefined;

    // Header: platen wordmark (SVG, vector), "INVOICE" + number/dates on the right
    try doc.drawSvg(logo, .{ .x = margin, .y = 42, .width = 110, .height = 0 });
    _ = try doc.writeAt(.{ .x = margin, .y = 80 }, "Letterpress Lane 1, 111 22 Stockholm", small_gray, .{});

    try writeRight(&doc, right, 62, "INVOICE", h2);
    const inv_no = try std.fmt.bufPrint(&buf, "No. 2026-{d:0>5}", .{index + 1});
    try writeRight(&doc, right, 80, inv_no, body_bold);
    const day = rand.intRangeAtMost(u8, 1, 28);
    const month = rand.intRangeAtMost(u8, 1, 12);
    var buf2: [128]u8 = undefined;
    const date = try std.fmt.bufPrint(&buf2, "Date: 2026-{d:0>2}-{d:0>2}   Due: 30 days net", .{ month, day });
    try writeRight(&doc, right, 93, date, body);

    // Bill-to block
    const cust = customers[rand.uintLessThan(usize, customers.len)];
    _ = try doc.writeAt(.{ .x = margin, .y = 130 }, "BILL TO", small_gray, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = 144 }, cust.name, body_bold, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = 157 }, cust.street, body, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = 170 }, cust.city, body, .{});

    // Table header band
    const col_qty: f64 = 360;
    const col_unit: f64 = 450;
    const table_top: f64 = 195;
    try doc.drawRect(.{ .x = margin, .y = table_top, .width = right - margin, .height = 18 }, .{
        .fill = .{ .color = platen.Color.rgb(238, 241, 247) },
    });
    _ = try doc.writeAt(.{ .x = margin + 6, .y = table_top + 13 }, "Description", body_bold, .{});
    try writeRight(&doc, col_qty, table_top + 13, "Qty", body_bold);
    try writeRight(&doc, col_unit, table_top + 13, "Unit", body_bold);
    try writeRight(&doc, right - 6, table_top + 13, "Amount", body_bold);

    // Line items: 3-10 unique rows
    const n_items = rand.intRangeAtMost(u32, 3, 10);
    var y: f64 = table_top + 18;
    var subtotal_cents: u64 = 0;
    for (0..n_items) |_| {
        const item = line_items[rand.uintLessThan(usize, line_items.len)];
        const qty = rand.intRangeAtMost(u32, 1, 12);
        const amount_cents: u64 = @as(u64, item.unit_cents) * qty;
        subtotal_cents += amount_cents;

        y += 16;
        _ = try doc.writeAt(.{ .x = margin + 6, .y = y }, item.desc, body, .{});
        const qty_s = try std.fmt.bufPrint(&buf, "{d}", .{qty});
        try writeRight(&doc, col_qty, y, qty_s, body);
        try writeRight(&doc, col_unit, y, try money(&buf2, item.unit_cents), body);
        try writeRight(&doc, right - 6, y, try money(&buf, amount_cents), body);
        try doc.drawLine(.{ .x = margin, .y = y + 5 }, .{ .x = right, .y = y + 5 }, .{
            .color = platen.Color.gainsboro,
            .width = 0.4,
        });
    }

    // Totals
    y += 30;
    const vat_cents = subtotal_cents / 4; // 25% VAT
    try writeRight(&doc, col_unit, y, "Subtotal", body);
    try writeRight(&doc, right - 6, y, try money(&buf, subtotal_cents), body);
    y += 14;
    try writeRight(&doc, col_unit, y, "VAT 25%", body);
    try writeRight(&doc, right - 6, y, try money(&buf, vat_cents), body);
    y += 8;
    try doc.drawLine(.{ .x = col_unit - 60, .y = y }, .{ .x = right, .y = y }, .{ .width = 0.8 });
    y += 14;
    try writeRight(&doc, col_unit, y, "Total", total_style);
    try writeRight(&doc, right - 6, y, try money(&buf, subtotal_cents + vat_cents), total_style);

    // Footer with invoice-unique payment reference
    const ref = try std.fmt.bufPrint(&buf2, "Payment ref: PLT-2026-{d:0>5}  |  IBAN SE12 3456 7890 1234  |  BIC PLTNSES1", .{index + 1});
    _ = try doc.writeAt(.{ .x = margin, .y = 790 }, ref, small_gray, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = 802 }, "Platen Industries AB  |  Org.nr 556677-8899  |  VAT SE556677889901", small_gray, .{});

    _ = @atomicRmw(u64, &phase_ns[1], .Add, @intCast(nanoNow() - t_content), .monotonic);
    const t_output = nanoNow();
    const pdf = try doc.output();
    _ = @atomicRmw(u64, &phase_ns[2], .Add, @intCast(nanoNow() - t_output), .monotonic);
    return pdf;
}

fn writeRight(doc: *platen.Document, x_right: f64, y: f64, text: []const u8, style: platen.TextStyle) !void {
    _ = try doc.writeAt(.{ .x = x_right, .y = y }, text, style, .{ .anchor = .right });
}

fn money(buf: []u8, cents: u64) ![]u8 {
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ cents / 100, cents % 100 });
}

fn parseArgs(args_obj: std.process.Args) !Config {
    var config = Config{};
    var args = args_obj.iterate();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--count=")) {
            config.count = try std.fmt.parseInt(u32, arg["--count=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--compress=")) {
            config.compress = try std.fmt.parseInt(i32, arg["--compress=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            config.threads = try std.fmt.parseInt(u32, arg["--threads=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--shared")) {
            config.shared = true;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            config.output_path = arg["--output=".len..];
        } else {
            return error.InvalidArgument;
        }
    }
    return config;
}
