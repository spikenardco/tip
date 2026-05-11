const std = @import("std");

pub fn uuid(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // ---- head: Date.now().toString(36)
    const millis = std.Io.Timestamp.now(io, .real).toMilliseconds();

    var head_buf: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "{x}", .{millis});

    // ---- tail: random bytes encoded as hex
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const rnd = std.mem.readInt(u64, &random_bytes, .little);

    var tail_buf: [32]u8 = undefined;
    const tail = try std.fmt.bufPrint(&tail_buf, "{x}", .{rnd});

    // ---- concatenate head + tail
    return try std.mem.concat(allocator, u8, &.{ head, tail });
}
