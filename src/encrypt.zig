//! PDF encryption: AES-256, security handler revision 6 (PDF 2.0).
//!
//! Only the modern scheme is implemented - no RC4, no AES-128 legacy
//! handlers. R6 uses a single 32-byte file key for every string and
//! stream (no per-object key derivation), which keeps the writer hook
//! simple: encrypt bytes -> emit IV ++ AES-256-CBC ciphertext.
//!
//! References: ISO 32000-2 §7.6.4 (Algorithms 2.A/2.B, 8, 9, 10).

const std = @import("std");

const Aes256 = std.crypto.core.aes.Aes256;
const Aes128 = std.crypto.core.aes.Aes128;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;

/// A cryptographically secure RNG for callers who do not supply their own.
/// Seeded from the platform CSPRNG via std.Io.randomSecure (getrandom on
/// Linux, getentropy on BSD/macOS, CNG on Windows) - no libc-symbol floor,
/// so it builds and runs everywhere platen does. The backing state must
/// outlive the returned std.Random (keep it in the calling frame).
pub const SystemCsprng = struct {
    state: std.Random.DefaultCsprng,

    pub fn init(io: std.Io) error{EntropyUnavailable}!SystemCsprng {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        io.randomSecure(&seed) catch return error.EntropyUnavailable;
        return .{ .state = std.Random.DefaultCsprng.init(seed) };
    }

    pub fn random(self: *SystemCsprng) std.Random {
        return self.state.random();
    }
};

/// User-facing permission flags (all allowed by default). Denied actions
/// clear bits in the /P value; note PDF permissions are advisory - they
/// are honored by viewers, not enforced by cryptography (only the user
/// password gates decryption).
pub const Permissions = struct {
    printing: bool = true,
    modifying: bool = true,
    copying: bool = true,
    annotating: bool = true,
    form_filling: bool = true,
    accessibility_copying: bool = true,
    assembly: bool = true,
    print_high_res: bool = true,

    pub fn toP(self: Permissions) i32 {
        // Reserved-one bits per ISO 32000-2 table 22; permission bits are
        // 3,4,5,6,9,10,11,12 (1-based).
        var p: u32 = 0xFFFF_F0C0;
        if (self.printing) p |= 1 << 2;
        if (self.modifying) p |= 1 << 3;
        if (self.copying) p |= 1 << 4;
        if (self.annotating) p |= 1 << 5;
        if (self.form_filling) p |= 1 << 8;
        if (self.accessibility_copying) p |= 1 << 9;
        if (self.assembly) p |= 1 << 10;
        if (self.print_high_res) p |= 1 << 11;
        return @bitCast(p);
    }
};

/// Encryption options on Document.
pub const Encryption = struct {
    /// Password required to open the document ("" = none: any viewer
    /// opens it, but content is still encrypted at rest).
    user_password: []const u8 = "",
    /// Password granting full permissions. Defaults to user_password.
    owner_password: ?[]const u8 = null,
    permissions: Permissions = .{},
};

/// The computed security-handler material for the /Encrypt dictionary,
/// plus the file key used to encrypt content.
pub const Material = struct {
    file_key: [32]u8,
    u: [48]u8,
    ue: [32]u8,
    o: [48]u8,
    oe: [32]u8,
    perms: [16]u8,
    p: i32,
};

/// ISO 32000-2 Algorithm 2.B: the R6 password hash.
/// `udata` is empty for user-password hashes and the 48-byte /U string
/// for owner-password hashes.
pub fn hash2b(password: []const u8, salt: []const u8, udata: []const u8) [32]u8 {
    var k_buf: [64]u8 = undefined; // K is 32, 48, or 64 bytes
    var k_len: usize = 32;
    {
        var h = Sha256.init(.{});
        h.update(password);
        h.update(salt);
        h.update(udata);
        h.final(k_buf[0..32]);
    }

    // K1 = (password ++ K ++ udata) repeated 64 times
    var k1_buf: [64 * (127 + 64 + 48)]u8 = undefined;
    var e_buf: [64 * (127 + 64 + 48)]u8 = undefined;

    var round: usize = 0;
    while (true) {
        const chunk = password.len + k_len + udata.len;
        var off: usize = 0;
        var rep: usize = 0;
        while (rep < 64) : (rep += 1) {
            @memcpy(k1_buf[off..][0..password.len], password);
            off += password.len;
            @memcpy(k1_buf[off..][0..k_len], k_buf[0..k_len]);
            off += k_len;
            @memcpy(k1_buf[off..][0..udata.len], udata);
            off += udata.len;
        }
        const k1 = k1_buf[0 .. chunk * 64];
        const e = e_buf[0..k1.len];

        // AES-128-CBC encrypt with key K[0..16], IV K[16..32], no padding
        cbcEncryptNoPad(Aes128, k_buf[0..16].*, k_buf[16..32].*, k1, e);

        // Next hash selected by sum of first 16 bytes of E mod 3
        var sum: u32 = 0;
        for (e[0..16]) |b| sum += b;
        switch (sum % 3) {
            0 => {
                var h = Sha256.init(.{});
                h.update(e);
                h.final(k_buf[0..32]);
                k_len = 32;
            },
            1 => {
                var h = Sha384.init(.{});
                h.update(e);
                h.final(k_buf[0..48]);
                k_len = 48;
            },
            2 => {
                var h = Sha512.init(.{});
                h.update(e);
                h.final(k_buf[0..64]);
                k_len = 64;
            },
            else => unreachable,
        }

        round += 1;
        if (round >= 64 and e[e.len - 1] <= round - 32) break;
    }
    return k_buf[0..32].*;
}

/// CBC without padding: `input.len` must be a multiple of 16 and
/// `output.len == input.len`.
fn cbcEncryptNoPad(comptime Cipher: type, key: anytype, iv: [16]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % 16 == 0 and output.len == input.len);
    const ctx = Cipher.initEnc(key);
    var prev = iv;
    var i: usize = 0;
    while (i < input.len) : (i += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |j| block[j] = input[i + j] ^ prev[j];
        ctx.encrypt(&block, &block);
        @memcpy(output[i..][0..16], &block);
        prev = block;
    }
}

fn cbcDecryptNoPad(comptime Cipher: type, key: anytype, iv: [16]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % 16 == 0 and output.len == input.len);
    const ctx = Cipher.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i < input.len) : (i += 16) {
        const cblock: [16]u8 = input[i..][0..16].*;
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, &cblock);
        for (0..16) |j| output[i + j] = block[j] ^ prev[j];
        prev = cblock;
    }
}

/// Truncate a password to the 127 bytes R6 allows.
fn clampPassword(pw: []const u8) []const u8 {
    return pw[0..@min(pw.len, 127)];
}

/// Build the full security-handler material (Algorithms 8, 9, 10).
pub fn buildMaterial(opts: Encryption, random: std.Random) Material {
    const user_pw = clampPassword(opts.user_password);
    const owner_pw = clampPassword(opts.owner_password orelse opts.user_password);

    var m: Material = undefined;
    m.p = opts.permissions.toP();
    random.bytes(&m.file_key);

    // Algorithm 8: U and UE
    var u_valsalt: [8]u8 = undefined;
    var u_keysalt: [8]u8 = undefined;
    random.bytes(&u_valsalt);
    random.bytes(&u_keysalt);
    const u_hash = hash2b(user_pw, &u_valsalt, "");
    @memcpy(m.u[0..32], &u_hash);
    @memcpy(m.u[32..40], &u_valsalt);
    @memcpy(m.u[40..48], &u_keysalt);
    const u_ikey = hash2b(user_pw, &u_keysalt, "");
    cbcEncryptNoPad(Aes256, u_ikey, std.mem.zeroes([16]u8), &m.file_key, &m.ue);

    // Algorithm 9: O and OE (udata = the 48-byte U string)
    var o_valsalt: [8]u8 = undefined;
    var o_keysalt: [8]u8 = undefined;
    random.bytes(&o_valsalt);
    random.bytes(&o_keysalt);
    const o_hash = hash2b(owner_pw, &o_valsalt, &m.u);
    @memcpy(m.o[0..32], &o_hash);
    @memcpy(m.o[32..40], &o_valsalt);
    @memcpy(m.o[40..48], &o_keysalt);
    const o_ikey = hash2b(owner_pw, &o_keysalt, &m.u);
    cbcEncryptNoPad(Aes256, o_ikey, std.mem.zeroes([16]u8), &m.file_key, &m.oe);

    // Algorithm 10: /Perms
    var perms_plain: [16]u8 = undefined;
    std.mem.writeInt(i32, perms_plain[0..4], m.p, .little);
    @memset(perms_plain[4..8], 0xFF);
    perms_plain[8] = 'T'; // EncryptMetadata = true
    perms_plain[9] = 'a';
    perms_plain[10] = 'd';
    perms_plain[11] = 'b';
    random.bytes(perms_plain[12..16]);
    const ctx = Aes256.initEnc(m.file_key);
    ctx.encrypt(&m.perms, &perms_plain);

    return m;
}

/// Test/validation helper: recover the file key from a user password and
/// the U/UE entries. Returns null if the password is wrong.
pub fn fileKeyFromUserPassword(password: []const u8, u: [48]u8, ue: [32]u8) ?[32]u8 {
    const pw = clampPassword(password);
    const check = hash2b(pw, u[32..40], "");
    if (!std.mem.eql(u8, &check, u[0..32])) return null;
    const ikey = hash2b(pw, u[40..48], "");
    var key: [32]u8 = undefined;
    cbcDecryptNoPad(Aes256, ikey, std.mem.zeroes([16]u8), &ue, &key);
    return key;
}

/// Content encryptor: file key plus the RNG that supplies per-item IVs.
pub const Encryptor = struct {
    key: [32]u8,
    random: std.Random,

    /// Encrypted size of `len` plaintext bytes: IV + PKCS#7-padded CBC.
    pub fn encryptedLen(len: usize) usize {
        return 16 + (len - len % 16) + 16; // pad always adds 1..16 bytes
    }

    /// Encrypt data as AESV3 expects: 16-byte IV, then AES-256-CBC with
    /// PKCS#7 padding. `out` must be encryptedLen(data.len) bytes.
    pub fn encrypt(self: *const Encryptor, data: []const u8, out: []u8) void {
        std.debug.assert(out.len == encryptedLen(data.len));
        var iv: [16]u8 = undefined;
        self.random.bytes(&iv);
        @memcpy(out[0..16], &iv);

        const pad: u8 = @intCast(16 - data.len % 16);
        const ctx = Aes256.initEnc(self.key);
        var prev = iv;
        var i: usize = 0;
        while (i < data.len + pad) : (i += 16) {
            var block: [16]u8 = undefined;
            for (0..16) |j| {
                const src: u8 = if (i + j < data.len) data[i + j] else pad;
                block[j] = src ^ prev[j];
            }
            ctx.encrypt(&block, &block);
            @memcpy(out[16 + i ..][0..16], &block);
            prev = block;
        }
    }

    /// Test helper: inverse of encrypt. Returns the plaintext length, or
    /// null if the padding is invalid.
    pub fn decrypt(key: [32]u8, data: []const u8, out: []u8) ?usize {
        if (data.len < 32 or (data.len - 16) % 16 != 0) return null;
        const body = data[16..];
        if (out.len < body.len) return null;
        cbcDecryptNoPad(Aes256, key, data[0..16].*, body, out[0..body.len]);
        const pad = out[body.len - 1];
        if (pad == 0 or pad > 16 or pad > body.len) return null;
        return body.len - pad;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hash2b is deterministic and password-sensitive" {
    const a = hash2b("secret", "01234567", "");
    const b = hash2b("secret", "01234567", "");
    const c = hash2b("Secret", "01234567", "");
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "user password roundtrip recovers the file key" {
    var prng = std.Random.DefaultPrng.init(0xdec0de);
    const m = buildMaterial(.{ .user_password = "hunter2" }, prng.random());

    const key = fileKeyFromUserPassword("hunter2", m.u, m.ue) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &m.file_key, &key);
    try std.testing.expectEqual(@as(?[32]u8, null), fileKeyFromUserPassword("wrong", m.u, m.ue));
    // Empty user password must also roundtrip (encrypted-at-rest, open access)
    const m2 = buildMaterial(.{}, prng.random());
    try std.testing.expect(fileKeyFromUserPassword("", m2.u, m2.ue) != null);
}

test "content encrypt/decrypt roundtrip at padding boundaries" {
    var prng = std.Random.DefaultPrng.init(7);
    var enc = Encryptor{ .key = undefined, .random = prng.random() };
    prng.random().bytes(&enc.key);

    inline for (.{ "", "a", "fifteen bytes..", "sixteen bytes...", "seventeen bytes.." }) |msg| {
        var out: [64]u8 = undefined;
        const elen = Encryptor.encryptedLen(msg.len);
        enc.encrypt(msg, out[0..elen]);
        var plain: [64]u8 = undefined;
        const plen = Encryptor.decrypt(enc.key, out[0..elen], &plain) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, msg, plain[0..plen]);
    }
}

test "perms block decrypts to the P value and marker bytes" {
    var prng = std.Random.DefaultPrng.init(3);
    const perms = Permissions{ .printing = false, .copying = false };
    const m = buildMaterial(.{ .user_password = "x", .permissions = perms }, prng.random());

    var plain: [16]u8 = undefined;
    const ctx = Aes256.initDec(m.file_key);
    ctx.decrypt(&plain, &m.perms);
    try std.testing.expectEqual(m.p, std.mem.readInt(i32, plain[0..4], .little));
    try std.testing.expectEqualSlices(u8, "adb", plain[9..12]);
    try std.testing.expectEqual(@as(u8, 'T'), plain[8]);
    // printing (bit 3) and copying (bit 5) denied
    const p: u32 = @bitCast(m.p);
    try std.testing.expect(p & (1 << 2) == 0);
    try std.testing.expect(p & (1 << 4) == 0);
    try std.testing.expect(p & (1 << 3) != 0);
}
