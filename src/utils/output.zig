const std = @import("std");

pub const Field = struct {
    label: []const u8,
    value: []const u8,
};

pub const Column = struct {
    header: []const u8,
    width: usize = 0,
};

/// Render a table of pre-formatted cell strings to stdout.
/// `rows` is row-major: rows[row][col].
/// Every row must have exactly `columns.len` cells.
pub fn render_table(columns: []const Column, rows: []const []const []const u8) void {
    if (columns.len == 0) return;

    var widths: [32]usize = undefined;
    for (columns, 0..) |col, i| {
        widths[i] = if (col.width > 0) col.width else col.header.len;
    }
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i < columns.len and cell.len > widths[i]) {
                widths[i] = cell.len;
            }
        }
    }

    for (columns, 0..) |col, i| {
        if (i > 0) std.debug.print("  ", .{});
        std.debug.print("{s: <[1]}", .{ col.header, widths[i] });
    }
    std.debug.print("\n", .{});

    for (0..columns.len) |i| {
        if (i > 0) std.debug.print("  ", .{});
        for (0..widths[i]) |_| std.debug.print("─", .{});
    }
    std.debug.print("\n", .{});

    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) std.debug.print("  ", .{});
            std.debug.print("{s: <[1]}", .{ cell, widths[i] });
        }
        std.debug.print("\n", .{});
    }
}

/// Render label-value pairs with right-aligned labels, 2-space indent, `: ` separator.
pub fn render_detail(fields: []const Field) void {
    if (fields.len == 0) return;

    var max_label: usize = 0;
    for (fields) |f| {
        if (f.label.len > max_label) max_label = f.label.len;
    }

    for (fields) |f| {
        std.debug.print("  {s:<[2]}: {s}\n", .{ f.label, f.value, max_label });
    }
}
