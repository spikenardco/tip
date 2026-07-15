const std = @import("std");

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Encodes a ULID: 48-bit millisecond timestamp (first 10 chars) plus
/// 80 bits of randomness (last 16 chars) into 26 Crockford base32 chars.
fn encode_ulid(ts_ms: u64, rand: [10]u8, out: *[26]u8) void {
    // Timestamp: low 48 bits -> chars [0..10), most significant first.
    var t: u64 = ts_ms & 0xFFFF_FFFF_FFFF;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@intCast(t & 0x1F)];
        t >>= 5;
    }

    // Randomness: 80 bits -> chars [10..26), most significant first.
    var r: u128 = 0;
    for (rand) |b| r = (r << 8) | b;
    var j: usize = 26;
    while (j > 10) {
        j -= 1;
        out[j] = alphabet[@intCast(r & 0x1F)];
        r >>= 5;
    }
}

/// Generates a new ULID as a 26-char Crockford base32 string.
/// The returned slice is owned by `allocator`; the caller must free it.
pub fn generate_id(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts_ms: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());

    var rand: [10]u8 = undefined;
    io.random(&rand);

    const buf = try allocator.alloc(u8, 26);
    encode_ulid(ts_ms, rand, buf[0..26]);
    return buf;
}
