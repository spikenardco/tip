const std = @import("std");

/// User-input problems. Rendered as clean one-line messages.
pub const ValidationError = error{EmptyTitle};

/// Task-domain outcomes the user can act on.
pub const TaskError = error{ TaskNotFound, AmbiguousPrefix };

/// Internal / unexpected failures (I/O, storage). The "something went wrong" bucket.
pub const StorageError = error{StorageFailure};

/// The full application error set. Later sub-projects add CryptoError, VaultError, etc.
pub const AppError = ValidationError || TaskError || StorageError;

/// Maps an error to a clean, user-facing one-line message.
/// Unknown errors are treated as internal and get a generic message.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyTitle => "task title cannot be empty",
        error.TaskNotFound => "no task found matching that id",
        error.AmbiguousPrefix => "id matches multiple tasks; use more characters",
        error.StorageFailure => "could not read or write task data",
        else => "an unexpected error occurred",
    };
}

/// Maps an error to a process exit code:
/// 1 internal · 2 usage · 3 not found · 4 validation/conflict.
/// Unknown errors are treated as internal (1).
pub fn exit_code(err: anyerror) u8 {
    return switch (err) {
        error.EmptyTitle, error.AmbiguousPrefix => 4,
        error.TaskNotFound => 3,
        error.StorageFailure => 1,
        else => 1,
    };
}

test "describe returns clean messages for known errors" {
    try std.testing.expectEqualStrings("task title cannot be empty", describe(error.EmptyTitle));
    try std.testing.expectEqualStrings("no task found matching that id", describe(error.TaskNotFound));
    try std.testing.expectEqualStrings("id matches multiple tasks; use more characters", describe(error.AmbiguousPrefix));
    try std.testing.expectEqualStrings("could not read or write task data", describe(error.StorageFailure));
}

test "describe falls back to generic for unknown errors" {
    try std.testing.expectEqualStrings("an unexpected error occurred", describe(error.OutOfMemory));
}

test "exit_code maps errors to semantic codes" {
    try std.testing.expectEqual(@as(u8, 4), exit_code(error.EmptyTitle));
    try std.testing.expectEqual(@as(u8, 4), exit_code(error.AmbiguousPrefix));
    try std.testing.expectEqual(@as(u8, 3), exit_code(error.TaskNotFound));
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.StorageFailure));
    try std.testing.expectEqual(@as(u8, 1), exit_code(error.OutOfMemory));
}
