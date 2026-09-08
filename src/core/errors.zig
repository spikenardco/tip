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
