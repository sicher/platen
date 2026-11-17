//! System font lookup.
//!
//! Finds an installed font by family name in the platform's font folders
//! (searched recursively) and returns the face as standalone sfnt bytes,
//! extracted from a collection when needed. The bytes go to
//! `Document.loadFontFromMemory` / `loadFontFamilyFromMemory`, and the
//! caller can also read metrics from the same data it embeds.
//!
//! Matching: the face's typographic family (name ID 16, else 1) must equal
//! the requested family, ignoring ASCII case. The style comes from the
//! subfamily (ID 17, else 2): Regular/Roman/Normal, Bold, Italic/Oblique,
//! Bold Italic/Bold Oblique. A face with another subfamily name still
//! counts, ranked below the exact names, when OS/2 says it is a plain
//! weight (400 or 700) at normal width; Light, Black, Condensed etc. never
//! match. Ties go to the earlier search folder, then the smaller path,
//! then the lower face index, so the result does not depend on directory
//! iteration order.
//!
//! Stateless: the user's home folder comes in through `Options.home`
//! (e.g. `init.environ_map.get("HOME")`, USERPROFILE on Windows).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const font_collection = @import("font_collection.zig");
const document = @import("document.zig");

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
};

pub const Options = struct {
    /// User's home folder; adds the per-user font folders. Ignored when
    /// `dirs` is set.
    home: ?[]const u8 = null,
    /// Folders to search instead of the platform defaults.
    dirs: ?[]const []const u8 = null,
    /// Only read files whose name looks like the family (see `nameMayMatch`);
    /// a file name with non-ASCII characters ("ヒラギノ角ゴシック W3.ttc"
    /// holds Hiragino Sans) cannot be judged that way, so only its name
    /// tables are read (`holdsFamily`). macOS ships gigabytes of fonts; turn
    /// this off only for fonts whose ASCII file name has nothing to do with
    /// their family name.
    prefilter: bool = true,
    /// Larger font files are skipped.
    max_file_size: usize = default_max_file_size,

    pub const default_max_file_size: usize = 256 << 20;
};

/// One face, owned by the caller (free with `deinit`).
pub const FoundFont = struct {
    /// Standalone sfnt, ready for `loadFontFromMemory`.
    data: []u8,
    family: []u8,
    subfamily: []u8,
    postscript_name: []u8,
    /// File the face came from.
    path: []u8,
    /// Face index within `path` (0 unless it is a collection).
    face_index: u32,
    style: Style,

    pub fn deinit(self: FoundFont, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.free(self.family);
        allocator.free(self.subfamily);
        allocator.free(self.postscript_name);
        allocator.free(self.path);
    }
};

/// The four faces of a family; any may be missing.
pub const FoundFamily = struct {
    regular: ?FoundFont = null,
    bold: ?FoundFont = null,
    italic: ?FoundFont = null,
    bold_italic: ?FoundFont = null,

    pub fn deinit(self: FoundFamily, allocator: Allocator) void {
        for ([_]?FoundFont{ self.regular, self.bold, self.italic, self.bold_italic }) |f| {
            if (f) |font| font.deinit(allocator);
        }
    }

    pub fn face(self: *FoundFamily, style: Style) *?FoundFont {
        if (style.bold) return if (style.italic) &self.bold_italic else &self.bold;
        return if (style.italic) &self.italic else &self.regular;
    }

    /// Options for `Document.loadFontFamilyFromMemory`, borrowing this
    /// family's data (keep it alive as long as the Document). Null without a
    /// regular face.
    pub fn memoryOptions(self: *const FoundFamily, encoding: document.FontEncoding) ?document.Document.FontFamilyMemoryOptions {
        const regular = self.regular orelse return null;
        return .{
            .regular = regular.data,
            .bold = if (self.bold) |f| f.data else null,
            .italic = if (self.italic) |f| f.data else null,
            .bold_italic = if (self.bold_italic) |f| f.data else null,
            .encoding = encoding,
        };
    }
};

/// Finds one face of `family`. Null if not installed.
pub fn find(io: std.Io, allocator: Allocator, family: []const u8, style: Style, opts: Options) !?FoundFont {
    var fam = try scan(io, allocator, family, style, opts);
    const slot = fam.face(style);
    const found = slot.*;
    slot.* = null;
    fam.deinit(allocator);
    return found;
}

/// Finds regular, bold, italic and bold italic of `family`. Null if no face
/// of the family is installed.
pub fn findFamily(io: std.Io, allocator: Allocator, family: []const u8, opts: Options) !?FoundFamily {
    const fam = try scan(io, allocator, family, null, opts);
    if (fam.regular == null and fam.bold == null and fam.italic == null and fam.bold_italic == null) return null;
    return fam;
}

/// One installed face of a family, as listed by `listFamily`. Owned by the
/// caller (free with `deinit`, or the whole list with `freeFamilyFaces`).
pub const FamilyFace = struct {
    /// Names, OS/2 weight/width and style; `info.index` is the face index
    /// within `path`.
    info: font_collection.FaceInfo,
    /// File the face lives in.
    path: []u8,

    pub fn deinit(self: FamilyFace, allocator: Allocator) void {
        self.info.deinit(allocator);
        allocator.free(self.path);
    }

    /// Reads `path` and returns this face as a standalone sfnt (free with
    /// `allocator`). error.FaceChanged if the file no longer holds this
    /// face (same family, subfamily and PostScript name at the index).
    pub fn load(self: FamilyFace, io: std.Io, allocator: Allocator) ![]u8 {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, self.path, allocator, .limited(Options.default_max_file_size));
        defer allocator.free(data);
        const now = font_collection.describeFace(allocator, data, self.info.index) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FaceChanged,
        };
        defer now.deinit(allocator);
        if (!std.mem.eql(u8, now.family, self.info.family) or
            !std.mem.eql(u8, now.subfamily, self.info.subfamily) or
            !std.mem.eql(u8, now.postscript_name, self.info.postscript_name)) return error.FaceChanged;
        return font_collection.extractFace(allocator, data, self.info.index);
    }
};

pub fn freeFamilyFaces(allocator: Allocator, faces: []const FamilyFace) void {
    for (faces) |f| f.deinit(allocator);
    allocator.free(faces);
}

/// Every installed face of `family`, whatever its weight, width or style
/// (Thin, Light, Condensed, Black Italic... included), unlike `findFamily`.
/// Family matching, prefilter and folders are the same as `find`'s. A face
/// is one subfamily name (ASCII case ignored): when several files hold it,
/// the copy `find` would pick wins (earlier folder, smaller path, lower face
/// index). The list is in that order too. Faces are not extracted; call
/// `FamilyFace.load` for the bytes. Empty if the family is not installed.
pub fn listFamily(io: std.Io, allocator: Allocator, family: []const u8, opts: Options) ![]FamilyFace {
    var ctx: ListCtx = .{ .allocator = allocator };
    defer ctx.ranks.deinit(allocator);
    errdefer freeList(allocator, &ctx.faces);
    try walk(io, allocator, family, opts, &ctx);

    const Pair = struct { face: FamilyFace, rank: Rank };
    const pairs = try allocator.alloc(Pair, ctx.faces.items.len);
    defer allocator.free(pairs);
    for (pairs, ctx.faces.items, ctx.ranks.items) |*p, f, r| p.* = .{ .face = f, .rank = r };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.rank.lessThan(b.rank);
        }
    }.lt);
    for (ctx.faces.items, pairs) |*f, p| f.* = p.face;
    return ctx.faces.toOwnedSlice(allocator);
}

fn freeList(allocator: Allocator, list: *std.ArrayList(FamilyFace)) void {
    for (list.items) |f| f.deinit(allocator);
    list.deinit(allocator);
}

/// Keeps the best-ranked copy of each subfamily.
const ListCtx = struct {
    allocator: Allocator,
    faces: std.ArrayList(FamilyFace) = .empty,
    /// Parallel to `faces`; each `path` points into that face's own path.
    ranks: std.ArrayList(Rank) = .empty,

    fn visit(self: *ListCtx, c: Candidate) !void {
        const rank: Rank = .{ .inexact = false, .dir = c.dir_rank, .path = c.rel, .face = c.info.index };
        const at: ?usize = for (self.faces.items, 0..) |f, i| {
            if (std.ascii.eqlIgnoreCase(f.info.subfamily, c.info.subfamily)) break i;
        } else null;
        if (at) |i| if (!rank.lessThan(self.ranks.items[i])) return;

        const face = try makeFamilyFace(self.allocator, c);
        if (at) |i| {
            self.faces.items[i].deinit(self.allocator);
            self.faces.items[i] = face;
        } else {
            errdefer face.deinit(self.allocator);
            try self.ranks.ensureUnusedCapacity(self.allocator, 1);
            try self.faces.append(self.allocator, face);
            self.ranks.appendAssumeCapacity(undefined);
        }
        const i = at orelse self.faces.items.len - 1;
        self.ranks.items[i] = rank;
        // The rank must outlive the walker's path buffer.
        self.ranks.items[i].path = face.path[face.path.len - c.rel.len ..];
    }
};

fn makeFamilyFace(allocator: Allocator, c: Candidate) !FamilyFace {
    const family = try allocator.dupe(u8, c.info.family);
    errdefer allocator.free(family);
    const subfamily = try allocator.dupe(u8, c.info.subfamily);
    errdefer allocator.free(subfamily);
    const ps = try allocator.dupe(u8, c.info.postscript_name);
    errdefer allocator.free(ps);
    const path = try std.fs.path.join(allocator, &.{ c.dir, c.rel });
    var info = c.info;
    info.family = family;
    info.subfamily = subfamily;
    info.postscript_name = ps;
    return .{ .info = info, .path = path };
}

const mac_dirs = [_][]const u8{ "/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts" };
const mac_home_dirs = [_][]const u8{"Library/Fonts"};
const unix_dirs = [_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" };
const unix_home_dirs = [_][]const u8{ ".local/share/fonts", ".fonts" };
const windows_dirs = [_][]const u8{"C:\\Windows\\Fonts"};
const windows_home_dirs = [_][]const u8{"AppData\\Local\\Microsoft\\Windows\\Fonts"};

/// The platform's font folders, per-user ones after the system ones when
/// `home` is given. Free with `freeDirs`.
pub fn defaultDirs(allocator: Allocator, home: ?[]const u8) ![][]u8 {
    const system: []const []const u8, const user: []const []const u8 = switch (builtin.os.tag) {
        .macos, .ios => .{ &mac_dirs, &mac_home_dirs },
        .windows => .{ &windows_dirs, &windows_home_dirs },
        else => .{ &unix_dirs, &unix_home_dirs },
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |d| allocator.free(d);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, system.len + user.len);
    for (system) |d| out.appendAssumeCapacity(try allocator.dupe(u8, d));
    if (home) |h| for (user) |d| out.appendAssumeCapacity(try std.fs.path.join(allocator, &.{ h, d }));
    return out.toOwnedSlice(allocator);
}

pub fn freeDirs(allocator: Allocator, dirs: []const []u8) void {
    for (dirs) |d| allocator.free(d);
    allocator.free(dirs);
}

/// Cheap file-name filter. `key` is the squashed family (`squash`). Passes
/// when the squashed file stem starts with the key ("Helvetica.ttc",
/// "Georgia Bold.ttf", "DejaVuSans-Bold.ttf"), or for 8.3-style stems
/// (Windows: "timesbd.ttf", "cour.ttf") when they share the key's first
/// four characters.
pub fn nameMayMatch(basename: []const u8, key: []const u8) bool {
    const stem_raw = basename[0 .. basename.len - std.fs.path.extension(basename).len];
    var buf: [256]u8 = undefined;
    const stem = squashInto(&buf, stem_raw);
    if (std.mem.startsWith(u8, stem, key)) return true;
    if (stem.len > 8) return false;
    const common = std.mem.indexOfDiff(u8, stem, key) orelse stem.len;
    return common >= @min(key.len, 4);
}

/// Lowercase ASCII without spaces, hyphens or underscores.
pub fn squash(allocator: Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    return allocator.realloc(out, squashInto(out, s).len);
}

fn squashInto(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| switch (c) {
        ' ', '-', '_' => {},
        else => {
            if (n == buf.len) break;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        },
    };
    return buf[0..n];
}

fn isAsciiName(basename: []const u8) bool {
    for (basename) |c| if (c >= 0x80) return false;
    return true;
}

/// Longest name table `holdsFamily` reads.
const max_name_table = 1 << 20;

/// Whether the font file `basename` in `dir` has a face of `family` (ASCII
/// case ignored), reading only the collection header, each face's table
/// directory and its name table, not the whole file.
fn holdsFamily(io: std.Io, fa: Allocator, dir: std.Io.Dir, basename: []const u8, family: []const u8) !bool {
    const file = dir.openFile(io, basename, .{}) catch return false;
    defer file.close(io);
    const head = readAt(io, fa, file, 0, 12) catch |err| return skipUnlessOom(err);
    const offsets: []const u8 = if (font_collection.isCollection(head)) blk: {
        const n = std.mem.readInt(u32, head[8..12], .big);
        if (n == 0 or n > 1 << 12) return false;
        break :blk readAt(io, fa, file, 12, 4 * n) catch |err| return skipUnlessOom(err);
    } else &.{ 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < offsets.len) : (i += 4) {
        const off = std.mem.readInt(u32, offsets[i..][0..4], .big);
        if (faceHasFamily(io, fa, file, off, family) catch |err| return skipUnlessOom(err)) return true;
    }
    return false;
}

fn skipUnlessOom(err: anyerror) error{OutOfMemory}!bool {
    return if (err == error.OutOfMemory) error.OutOfMemory else false;
}

/// Whether the face at `off` is of `family`: its name table, read alone,
/// goes into a one-table sfnt for `font_collection.describeFace`.
fn faceHasFamily(io: std.Io, fa: Allocator, file: std.Io.File, off: u32, family: []const u8) !bool {
    const sfnt = try readAt(io, fa, file, off, 12);
    const num = std.mem.readInt(u16, sfnt[4..6], .big);
    const dir = try readAt(io, fa, file, @as(u64, off) + 12, 16 * @as(usize, num));
    const rec = for (0..num) |t| {
        if (std.mem.eql(u8, dir[16 * t ..][0..4], "name")) break dir[16 * t ..][0..16];
    } else return false;
    const len = std.mem.readInt(u32, rec[12..16], .big);
    if (len > max_name_table) return false;
    const table = try readAt(io, fa, file, std.mem.readInt(u32, rec[8..12], .big), len);

    const one = try fa.alloc(u8, 28 + len);
    @memcpy(one[0..12], sfnt);
    std.mem.writeInt(u16, one[4..6], 1, .big);
    @memcpy(one[12..28], rec);
    std.mem.writeInt(u32, one[20..24], 28, .big);
    @memcpy(one[28..], table);
    const info = font_collection.describeFace(fa, one, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.ascii.eqlIgnoreCase(info.family, family);
}

/// `len` bytes at `offset`; error.EndOfStream if the file is shorter.
fn readAt(io: std.Io, fa: Allocator, file: std.Io.File, offset: u64, len: usize) ![]u8 {
    const buf = try fa.alloc(u8, len);
    if (try file.readPositionalAll(io, buf, offset) != len) return error.EndOfStream;
    return buf;
}

fn isFontFile(basename: []const u8) bool {
    const ext = std.fs.path.extension(basename);
    for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

const Match = struct { style: Style, exact: bool };

/// Style of a face, or null for weights/widths we do not map.
pub fn classify(info: font_collection.FaceInfo) ?Match {
    var buf: [64]u8 = undefined;
    const sub = squashInto(&buf, info.subfamily);
    const canon = [_]struct { []const u8, Style }{
        .{ "regular", .{} },                                  .{ "roman", .{} },
        .{ "normal", .{} },                                   .{ "bold", .{ .bold = true } },
        .{ "italic", .{ .italic = true } },                   .{ "oblique", .{ .italic = true } },
        .{ "bolditalic", .{ .bold = true, .italic = true } }, .{ "boldoblique", .{ .bold = true, .italic = true } },
    };
    if (info.subfamily.len <= buf.len) for (canon) |c| {
        if (std.mem.eql(u8, sub, c[0])) return .{ .style = c[1], .exact = true };
    };
    if (info.width != 5) return null;
    if (info.weight != 400 and info.weight != 700) return null;
    return .{ .style = .{ .bold = info.weight == 700, .italic = info.italic }, .exact = false };
}

/// Ranking of a candidate; lower wins.
const Rank = struct {
    inexact: bool,
    dir: usize,
    path: []const u8,
    face: u32,

    fn lessThan(a: Rank, b: Rank) bool {
        if (a.inexact != b.inexact) return !a.inexact;
        if (a.dir != b.dir) return a.dir < b.dir;
        return switch (std.mem.order(u8, a.path, b.path)) {
            .lt => true,
            .gt => false,
            .eq => a.face < b.face,
        };
    }
};

/// A face of the requested family met while walking the folders. All
/// slices are valid only during the `visit` call.
const Candidate = struct {
    /// The whole file (a collection or a single sfnt).
    data: []const u8,
    info: font_collection.FaceInfo,
    dir: []const u8,
    /// Path below `dir`.
    rel: []const u8,
    dir_rank: usize,
};

/// Walks the folders and calls `ctx.visit(candidate)` for every face whose
/// typographic family equals `family` (ASCII case ignored).
fn walk(io: std.Io, allocator: Allocator, family: []const u8, opts: Options, ctx: anytype) !void {
    const owned_dirs: ?[][]u8 = if (opts.dirs == null) try defaultDirs(allocator, opts.home) else null;
    defer if (owned_dirs) |d| freeDirs(allocator, d);
    const dirs: []const []const u8 = opts.dirs orelse owned_dirs.?;

    const key = try squash(allocator, family);
    defer allocator.free(key);

    var file_arena: std.heap.ArenaAllocator = .init(allocator);
    defer file_arena.deinit();

    for (dirs, 0..) |dir_path, dir_rank| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walkSelectively(allocator);
        defer walker.deinit();
        while (true) {
            const e = (walker.next(io) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue, // unreadable folder: the walker skips it
            }) orelse break;
            if (e.kind == .directory) {
                walker.enter(io, e) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                continue;
            }
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!isFontFile(e.basename)) continue;
            _ = file_arena.reset(.retain_capacity);
            const fa = file_arena.allocator();
            if (opts.prefilter and !nameMayMatch(e.basename, key)) {
                if (isAsciiName(e.basename)) continue;
                if (!try holdsFamily(io, fa, e.dir, e.basename, family)) continue;
            }
            const data = e.dir.readFileAlloc(io, e.basename, fa, .limited(opts.max_file_size)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const n = font_collection.faceCount(data) catch continue;
            for (0..n) |i| {
                const info = font_collection.describeFace(fa, data, @intCast(i)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                if (!std.ascii.eqlIgnoreCase(info.family, family)) continue;
                try ctx.visit(.{ .data = data, .info = info, .dir = dir_path, .rel = e.path, .dir_rank = dir_rank });
            }
        }
    }
}

/// Keeps the best face per style (only `want` when given).
const ScanCtx = struct {
    allocator: Allocator,
    want: ?Style,
    result: FoundFamily = .{},
    ranks: [4]Rank = undefined,

    fn visit(self: *ScanCtx, c: Candidate) !void {
        const m = classify(c.info) orelse return;
        if (self.want) |w| if (w.bold != m.style.bold or w.italic != m.style.italic) return;

        const slot = self.result.face(m.style);
        const slot_i = @as(usize, @intFromBool(m.style.bold)) + 2 * @as(usize, @intFromBool(m.style.italic));
        const rank: Rank = .{ .inexact = !m.exact, .dir = c.dir_rank, .path = c.rel, .face = c.info.index };
        if (slot.* != null and !rank.lessThan(self.ranks[slot_i])) return;

        const found = try makeFound(self.allocator, c.data, c.info, c.dir, c.rel, m.style);
        if (slot.*) |old| old.deinit(self.allocator);
        slot.* = found;
        self.ranks[slot_i] = rank;
        // The rank must outlive the walker's path buffer.
        self.ranks[slot_i].path = found.path[found.path.len - c.rel.len ..];
    }
};

fn scan(io: std.Io, allocator: Allocator, family: []const u8, want: ?Style, opts: Options) !FoundFamily {
    var ctx: ScanCtx = .{ .allocator = allocator, .want = want };
    errdefer ctx.result.deinit(allocator);
    try walk(io, allocator, family, opts, &ctx);
    return ctx.result;
}

fn makeFound(allocator: Allocator, data: []const u8, info: font_collection.FaceInfo, dir: []const u8, rel: []const u8, style: Style) !FoundFont {
    const sfnt = try font_collection.extractFace(allocator, data, info.index);
    errdefer allocator.free(sfnt);
    const family = try allocator.dupe(u8, info.family);
    errdefer allocator.free(family);
    const subfamily = try allocator.dupe(u8, info.subfamily);
    errdefer allocator.free(subfamily);
    const ps = try allocator.dupe(u8, info.postscript_name);
    errdefer allocator.free(ps);
    const path = try std.fs.path.join(allocator, &.{ dir, rel });
    return .{
        .data = sfnt,
        .family = family,
        .subfamily = subfamily,
        .postscript_name = ps,
        .path = path,
        .face_index = info.index,
        .style = style,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testFace(subfamily: []const u8, weight: u16, width: u16, italic: bool) font_collection.FaceInfo {
    return .{ .index = 0, .family = "F", .subfamily = subfamily, .postscript_name = "", .weight = weight, .width = width, .bold = weight >= 700, .italic = italic };
}

test "classify: canonical names, then plain OS/2 weights" {
    try testing.expectEqual(Match{ .style = .{ .bold = true, .italic = true }, .exact = true }, classify(testFace("Bold Oblique", 700, 5, true)).?);
    try testing.expectEqual(Match{ .style = .{ .bold = true, .italic = true }, .exact = true }, classify(testFace("BoldItalic", 700, 5, true)).?);
    try testing.expectEqual(Match{ .style = .{}, .exact = true }, classify(testFace("Roman", 400, 5, false)).?);
    try testing.expectEqual(Match{ .style = .{ .italic = true }, .exact = false }, classify(testFace("Book Italic", 400, 5, true)).?);
    try testing.expect(classify(testFace("Light", 300, 5, false)) == null);
    try testing.expect(classify(testFace("Black Italic", 900, 5, true)) == null);
    try testing.expect(classify(testFace("Condensed", 400, 3, false)) == null);
}

test "nameMayMatch" {
    try testing.expect(nameMayMatch("Helvetica.ttc", "helvetica"));
    try testing.expect(nameMayMatch("Georgia Bold Italic.ttf", "georgia"));
    try testing.expect(nameMayMatch("DejaVuSans-Bold.ttf", "dejavusans"));
    try testing.expect(nameMayMatch("timesbd.ttf", "timesnewroman"));
    try testing.expect(nameMayMatch("cour.ttf", "couriernew"));
    try testing.expect(nameMayMatch("Inter.ttc", "interdisplay"));
    try testing.expect(!nameMayMatch("Geneva.ttf", "georgia"));
    try testing.expect(!nameMayMatch("HelveticaNeue.ttc", "helveticaneuedisplay"));
    try testing.expect(!nameMayMatch("NotoSansArabic-Regular.ttf", "notoserif"));
}

test "findFamily picks the four plain faces of a collection-only family" {
    // "Inter Display" exists only inside Inter.ttc, next to Thin..Black
    // weights that must not match; the 8.3 rule lets "Inter.ttc" through
    // the prefilter.
    const opts: Options = .{ .dirs = &.{"test/fonts/Inter"} };
    var fam = (try findFamily(testing.io, testing.allocator, "inter display", opts)).?;
    defer fam.deinit(testing.allocator);
    const expect = [_]struct { Style, u32, []const u8 }{
        .{ .{}, 20, "InterDisplay-Regular" },
        .{ .{ .bold = true }, 32, "InterDisplay-Bold" },
        .{ .{ .italic = true }, 21, "InterDisplay-Italic" },
        .{ .{ .bold = true, .italic = true }, 33, "InterDisplay-BoldItalic" },
    };
    for (expect) |x| {
        const f = fam.face(x[0]).*.?;
        try testing.expectEqual(x[1], f.face_index);
        try testing.expectEqualStrings(x[2], f.postscript_name);
        try testing.expectEqualStrings("Inter Display", f.family);
        try testing.expect(std.mem.endsWith(u8, f.path, "Inter.ttc"));
        // The data is the face itself, not the whole collection.
        try testing.expectEqual(@as(u32, 1), try font_collection.faceCount(f.data));
        const info = try font_collection.describeFace(testing.allocator, f.data, 0);
        defer info.deinit(testing.allocator);
        try testing.expectEqualStrings(x[2], info.postscript_name);
    }
    try testing.expect(fam.memoryOptions(.identity) != null);
}

test "find: ties go to the smallest path, missing families are null" {
    // Inter Bold is in Inter-Bold.otf, Inter-Bold.ttf and Inter.ttc.
    const opts: Options = .{ .dirs = &.{"test/fonts/Inter"} };
    const bold = (try find(testing.io, testing.allocator, "Inter", .{ .bold = true }, opts)).?;
    defer bold.deinit(testing.allocator);
    try testing.expectEqualStrings("Inter", bold.family);
    try testing.expectEqualStrings("Bold", bold.subfamily);
    try testing.expect(std.mem.endsWith(u8, bold.path, "Inter-Bold.otf"));

    try testing.expect(try find(testing.io, testing.allocator, "No Such Family", .{}, opts) == null);
    try testing.expect(try findFamily(testing.io, testing.allocator, "Inter", .{ .dirs = &.{"test/no/such/dir"} }) == null);
}

test "find searches folders recursively, earlier folders first" {
    const opts: Options = .{ .dirs = &.{ "test/fonts/Charter", "test/fonts" } };
    const f = (try find(testing.io, testing.allocator, "Courier Prime", .{ .italic = true }, opts)).?;
    defer f.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, f.path, "Courier Prime Italic.ttf"));

    const c = (try find(testing.io, testing.allocator, "Charter", .{}, opts)).?;
    defer c.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, c.path, "test/fonts/Charter/"));
    try testing.expect(std.mem.endsWith(u8, c.path, "Charter Regular.otf"));
}

test "listFamily: every weight once, the copy find would pick, in rank order" {
    const opts: Options = .{ .dirs = &.{"test/fonts/Inter"} };
    const faces = try listFamily(testing.io, testing.allocator, "inter", opts);
    defer freeFamilyFaces(testing.allocator, faces);
    // Regular/Bold/Italic/BoldItalic come from the .otf files (smallest
    // paths), the other 14 from Inter.ttc in face order; Inter Display and
    // Inter Variable are other families.
    const expect = [_]struct { []const u8, []const u8, u32 }{
        .{ "Inter-Bold", "Inter-Bold.otf", 0 },     .{ "Inter-BoldItalic", "Inter-BoldItalic.otf", 0 },
        .{ "Inter-Italic", "Inter-Italic.otf", 0 }, .{ "Inter-Regular", "Inter-Regular.otf", 0 },
        .{ "Inter-Black", "Inter.ttc", 1 },         .{ "Inter-BlackItalic", "Inter.ttc", 2 },
        .{ "Inter-Thin", "Inter.ttc", 4 },          .{ "Inter-ThinItalic", "Inter.ttc", 5 },
        .{ "Inter-Light", "Inter.ttc", 6 },         .{ "Inter-LightItalic", "Inter.ttc", 7 },
        .{ "Inter-ExtraLight", "Inter.ttc", 8 },    .{ "Inter-ExtraLightItalic", "Inter.ttc", 9 },
        .{ "Inter-Medium", "Inter.ttc", 10 },       .{ "Inter-MediumItalic", "Inter.ttc", 11 },
        .{ "Inter-SemiBold", "Inter.ttc", 12 },     .{ "Inter-SemiBoldItalic", "Inter.ttc", 13 },
        .{ "Inter-ExtraBold", "Inter.ttc", 16 },    .{ "Inter-ExtraBoldItalic", "Inter.ttc", 17 },
    };
    try testing.expectEqual(expect.len, faces.len);
    for (expect, faces) |x, f| {
        try testing.expectEqualStrings(x[0], f.info.postscript_name);
        try testing.expectEqualStrings(x[1], std.fs.path.basename(f.path));
        try testing.expectEqual(x[2], f.info.index);
        try testing.expectEqualStrings("Inter", f.info.family);
    }
    // Weight and italic come through for the caller's own choice.
    try testing.expectEqual(@as(u16, 300), faces[8].info.weight);
    try testing.expect(!faces[8].info.italic and faces[9].info.italic);

    const missing = try listFamily(testing.io, testing.allocator, "No Such Family", opts);
    defer freeFamilyFaces(testing.allocator, missing);
    try testing.expectEqual(@as(usize, 0), missing.len);
}

test "FamilyFace.load extracts the face; a changed file is refused" {
    const opts: Options = .{ .dirs = &.{"test/fonts/Inter"} };
    const faces = try listFamily(testing.io, testing.allocator, "Inter", opts);
    defer freeFamilyFaces(testing.allocator, faces);
    const light = faces[8];
    const data = try light.load(testing.io, testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(u32, 1), try font_collection.faceCount(data));
    const info = try font_collection.describeFace(testing.allocator, data, 0);
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("Inter-Light", info.postscript_name);

    // Index 8 of Inter.ttc is ExtraLight, not Light.
    var moved = light;
    moved.info.index = 8;
    try testing.expectError(error.FaceChanged, moved.load(testing.io, testing.allocator));
    moved.info.index = 99;
    try testing.expectError(error.FaceChanged, moved.load(testing.io, testing.allocator));
}

test "prefilter: a non-ASCII file name is judged by its name table" {
    // As macOS ships Hiragino Sans in "ヒラギノ角ゴシック W0.ttc" etc., with
    // the names in NFD ("ギ" = "キ" + U+3099). ASCII names still go by
    // `nameMayMatch`: "Zz.otf" holds Charter but is not opened.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const copies = [_][2][]const u8{
        .{ "test/fonts/Inter/Inter.ttc", "\u{30A4}\u{30F3}\u{30BF}\u{30FC}.ttc" },
        .{ "test/fonts/Charter/Charter Regular.otf", "\u{30C1}\u{30E3}\u{30FC}\u{30BF}\u{30FC} \u{30AD}\u{3099}.otf" },
        .{ "test/fonts/Charter/Charter Bold.otf", "Zz.otf" },
    };
    for (copies) |c| try std.Io.Dir.cwd().copyFile(c[0], tmp.dir, c[1], io, .{});
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const opts: Options = .{ .dirs = &.{dir} };

    const inter = try listFamily(io, testing.allocator, "Inter", opts);
    defer freeFamilyFaces(testing.allocator, inter);
    try testing.expectEqual(@as(usize, 18), inter.len);
    for (inter) |f| try testing.expect(std.mem.endsWith(u8, f.path, copies[0][1]));

    var charter = (try findFamily(io, testing.allocator, "charter", opts)).?;
    defer charter.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, charter.regular.?.path, copies[1][1]));
    try testing.expectEqualStrings("Charter", charter.regular.?.family);
    try testing.expect(charter.bold == null);

    try testing.expect(try findFamily(io, testing.allocator, "Inter Displays", opts) == null);
}
