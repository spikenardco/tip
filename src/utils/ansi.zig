const std = @import("std");
const models = @import("../core/models.zig");

pub fn status_icon(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "○",
        .in_progress => "⟳",
        .completed => "✓",
    };
}

pub fn status_label(status: models.Task.Status) []const u8 {
    return switch (status) {
        .pending => "Pending",
        .in_progress => "In Progress",
        .completed => "Completed",
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

pub fn priority_label(priority: models.Task.Priority) []const u8 {
    return switch (priority) {
        .high => "High",
        .medium => "Medium",
        .low => "Low",
    };
}

test "status_label maps statuses" {
    try std.testing.expectEqualStrings("Pending", status_label(.pending));
    try std.testing.expectEqualStrings("In Progress", status_label(.in_progress));
    try std.testing.expectEqualStrings("Completed", status_label(.completed));
}

test "priority_label maps priorities" {
    try std.testing.expectEqualStrings("High", priority_label(.high));
    try std.testing.expectEqualStrings("Medium", priority_label(.medium));
    try std.testing.expectEqualStrings("Low", priority_label(.low));
}
