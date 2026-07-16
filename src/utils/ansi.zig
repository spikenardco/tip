const std = @import("std");
const models = @import("../core/models.zig");

pub const Ansi = enum {
    red,
    green,
    yellow,
    cyan,
    reset,
};

pub fn ansi_code(c: Ansi) []const u8 {
    return switch (c) {
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .reset => "\x1b[0m",
    };
}

pub fn priority_glyph(priority: ?models.Task.Priority) []const u8 {
    if (priority) |p| {
        return switch (p) {
            .high => "↑",
            .medium => "-",
            .low => "↓",
        };
    }
    return "";
}

pub fn priority_color(priority: ?models.Task.Priority) Ansi {
    if (priority) |p| {
        return switch (p) {
            .high => .red,
            .medium => .yellow,
            .low => .green,
        };
    }
    return .reset;
}

pub fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

pub fn status_color(status: models.Task.Status) Ansi {
    return switch (status) {
        .pending => .reset,
        .in_progress => .cyan,
        .completed => .green,
    };
}

test "ansi_code returns escape sequences" {
    try std.testing.expectEqualStrings("\x1b[31m", ansi_code(.red));
    try std.testing.expectEqualStrings("\x1b[0m", ansi_code(.reset));
}

test "priority_glyph maps priorities" {
    try std.testing.expectEqualStrings("↑", priority_glyph(.high));
    try std.testing.expectEqualStrings("-", priority_glyph(.medium));
    try std.testing.expectEqualStrings("↓", priority_glyph(.low));
    try std.testing.expectEqualStrings("", priority_glyph(null));
}

test "status_icon maps statuses" {
    try std.testing.expectEqualStrings("○", status_icon(.pending));
    try std.testing.expectEqualStrings("⟳", status_icon(.in_progress));
    try std.testing.expectEqualStrings("✓", status_icon(.completed));
}
