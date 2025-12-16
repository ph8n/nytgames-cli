const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("event.zig");
const colors = @import("colors.zig");
const keys = @import("keys.zig");
const date = @import("../utils/date.zig");
const storage_db = @import("../storage/db.zig");
const storage_stats = @import("../storage/stats.zig");

pub const Choice = enum {
    wordle,
    wordle_unlimited,
    connections,
    spelling_bee,
    stats_wordle,
    stats_wordle_unlimited,
    stats_connections,
    stats_spelling_bee,
    quit,
};

const Row = enum(u4) {
    wordle,
    connections,
    spelling_bee,
    stats,
    quit,
};

const WordleMode = enum {
    today,
    unlimited,
};

const StatsOption = struct {
    label: []const u8,
    choice: Choice,
};

const stats_options = [_]StatsOption{
    .{ .label = "Wordle", .choice = .stats_wordle },
    .{ .label = "Wordle Unlimited", .choice = .stats_wordle_unlimited },
    .{ .label = "Connections", .choice = .stats_connections },
    .{ .label = "Spelling Bee", .choice = .stats_spelling_bee },
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
    dev_mode: bool,
) !Choice {
    var selected_row: Row = .wordle;
    var selected_wordle: WordleMode = .today;
    var selected_stats: usize = 0;
    var stats_window_start: usize = 0;

    const today_date = try date.todayLocal();
    var today_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDD(&today_buf, today_date);

    const wordle_status: storage_stats.PlayedStatus = if (dev_mode) .not_played else try storage_stats.getWordlePlayedStatus(&storage.db, today_buf[0..]);
    const wordle_streak = try storage_stats.getWordleDailyStreak(&storage.db, today_date);
    const wordle_unlimited_streak = try storage_stats.getWordleUnlimitedStreak(&storage.db);
    const connections_status: storage_stats.PlayedStatus = if (dev_mode) .not_played else try storage_stats.getConnectionsPlayedStatus(&storage.db, today_buf[0..]);
    const connections_streak = try storage_stats.getConnectionsDailyStreak(&storage.db, today_date);

    const rows_count_u4: u4 = @intCast(@typeInfo(Row).@"enum".fields.len);
    const rows_count: u16 = @intCast(rows_count_u4);

    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "nytgames-cli";
        const hint = "↑/↓ j/k  •  ←/→ h/l  •  Enter/Space  •  Ctrl+C";

        var streak_today_buf: [32]u8 = undefined;
        const streak_today_text = std.fmt.bufPrint(&streak_today_buf, "streak {d}", .{wordle_streak}) catch unreachable;
        var streak_unlimited_buf: [32]u8 = undefined;
        const streak_unlimited_text = std.fmt.bufPrint(&streak_unlimited_buf, "streak {d}", .{wordle_unlimited_streak}) catch unreachable;

        var streak_connections_buf: [32]u8 = undefined;
        const streak_connections_text = std.fmt.bufPrint(&streak_connections_buf, "streak {d}", .{connections_streak}) catch unreachable;

        const today_mark: []const u8 = switch (wordle_status) {
            .not_played => " ",
            .won => "✓",
            .lost => "X",
        };

        var wordle_right_buf: [256]u8 = undefined;
        const wordle_right_text = std.fmt.bufPrint(
            &wordle_right_buf,
            "  [ Today {s} ] {s}  [ Unlimited ] {s}",
            .{ today_mark, streak_today_text, streak_unlimited_text },
        ) catch unreachable;

        const connections_mark: []const u8 = switch (connections_status) {
            .not_played => " ",
            .won => "✓",
            .lost => "X",
        };
        var connections_right_buf: [128]u8 = undefined;
        const connections_right_text = std.fmt.bufPrint(
            &connections_right_buf,
            "  [ Today {s} ] {s}",
            .{ connections_mark, streak_connections_text },
        ) catch unreachable;

        const prefix_w = win.gwidth("> ");

        const label_wordle = "Wordle";
        const label_connections = "Connections";
        const label_spelling_bee = "Spelling Bee";
        const label_stats = "Stats";
        const label_quit = "Quit";

        var label_w: u16 = win.gwidth(label_wordle);
        label_w = @max(label_w, win.gwidth(label_connections));
        label_w = @max(label_w, win.gwidth(label_spelling_bee));
        label_w = @max(label_w, win.gwidth(label_stats));
        label_w = @max(label_w, win.gwidth(label_quit));

        const gap: u16 = 2;
        const wordle_right_w = win.gwidth(wordle_right_text);
        const connections_right_w = win.gwidth(connections_right_text);
        const stats_right_max_w = calcStatsRightWidthMax(win);
        const single_today_right_w = win.gwidth("  [ Today ]");
        const right_region_w = @max(@max(@max(wordle_right_w, connections_right_w), stats_right_max_w), single_today_right_w);

        var layout_w: u16 = prefix_w + label_w;
        layout_w = @max(layout_w, prefix_w + label_w + gap + right_region_w);

        const title_w = win.gwidth(title);
        const hint_w = win.gwidth(hint);
        layout_w = @max(layout_w, title_w);
        layout_w = @max(layout_w, hint_w);

        const block_h: u16 = 2 + 1 + rows_count; // title + hint + gap + rows
        const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;
        const block_x: u16 = if (win.width > layout_w) @intCast((win.width - layout_w) / 2) else 0;

        _ = win.print(&.{.{ .text = title }}, .{
            .row_offset = block_y,
            .col_offset = block_x + if (layout_w > title_w) @as(u16, @intCast((layout_w - title_w) / 2)) else 0,
            .wrap = .none,
        });
        _ = win.print(&.{.{ .text = hint }}, .{
            .row_offset = block_y + 1,
            .col_offset = block_x + if (layout_w > hint_w) @as(u16, @intCast((layout_w - hint_w) / 2)) else 0,
            .wrap = .none,
        });

        const start_y: u16 = block_y + 3;
        const right_region_x: u16 = block_x + layout_w - right_region_w;
        renderWordleRow(
            win,
            block_x,
            right_region_x,
            start_y,
            label_wordle,
            wordle_status,
            streak_today_text,
            streak_unlimited_text,
            selected_row,
            selected_wordle,
        );

        renderConnectionsRow(
            win,
            block_x,
            right_region_x,
            start_y + 1,
            label_connections,
            connections_status,
            streak_connections_text,
            selected_row,
        );

        renderSingleTodayRow(win, block_x, right_region_x, start_y + 2, label_spelling_bee, selected_row == .spelling_bee);

        renderStatsRow(
            win,
            block_x,
            right_region_x,
            start_y + 3,
            label_stats,
            selected_row,
            selected_stats,
            stats_window_start,
        );
        renderSimpleRow(win, block_x, start_y + 4, label_quit, selected_row == .quit);

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;

                if (k.matches(vaxis.Key.up, .{}) or k.matches('k', .{})) {
                    const cur: u4 = @intCast(@intFromEnum(selected_row));
                    if (cur > 0) selected_row = @enumFromInt(cur - 1);
                } else if (k.matches(vaxis.Key.down, .{}) or k.matches('j', .{})) {
                    const cur: u4 = @intCast(@intFromEnum(selected_row));
                    if (cur + 1 < rows_count_u4) selected_row = @enumFromInt(cur + 1);
                } else if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{})) {
                    if (selected_row == .wordle) selected_wordle = .today;
                    if (selected_row == .stats and selected_stats > 0) {
                        selected_stats -= 1;
                        ensureVisible(&stats_window_start, selected_stats, stats_options.len, 3);
                    }
                } else if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
                    if (selected_row == .wordle) selected_wordle = .unlimited;
                    if (selected_row == .stats and selected_stats + 1 < stats_options.len) {
                        selected_stats += 1;
                        ensureVisible(&stats_window_start, selected_stats, stats_options.len, 3);
                    }
                } else if (isConfirmKey(k)) {
                    return switch (selected_row) {
                        .wordle => switch (selected_wordle) {
                            .today => .wordle,
                            .unlimited => .wordle_unlimited,
                        },
                        .connections => .connections,
                        .spelling_bee => .spelling_bee,
                        .stats => stats_options[selected_stats].choice,
                        .quit => .quit,
                    };
                }
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn renderSingleTodayRow(win: vaxis.Window, block_x: u16, right_x: u16, y: u16, label: []const u8, selected: bool) void {
    const prefix = if (selected) "> " else "  ";
    const label_style: vaxis.Style = if (selected) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
    _ = win.print(&.{
        .{ .text = prefix, .style = label_style },
        .{ .text = label, .style = label_style },
    }, .{ .row_offset = y, .col_offset = block_x, .wrap = .none });

    const selected_button: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = colors.ui.highlight, .bold = true };
    const btn_style: vaxis.Style = if (selected) selected_button else .{};
    _ = win.print(&.{
        .{ .text = "  ", .style = .{} },
        .{ .text = "[ Today ]", .style = btn_style },
    }, .{ .row_offset = y, .col_offset = right_x, .wrap = .none });
}

fn renderSimpleRow(win: vaxis.Window, x: u16, y: u16, label: []const u8, selected: bool) void {
    const prefix = if (selected) "> " else "  ";
    const style: vaxis.Style = if (selected) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
    _ = win.print(&.{
        .{ .text = prefix, .style = style },
        .{ .text = label, .style = style },
    }, .{ .row_offset = y, .col_offset = x, .wrap = .none });
}

fn renderWordleRow(
    win: vaxis.Window,
    block_x: u16,
    right_x: u16,
    y: u16,
    label: []const u8,
    wordle_status: storage_stats.PlayedStatus,
    streak_today_text: []const u8,
    streak_unlimited_text: []const u8,
    selected_row: Row,
    selected_wordle: WordleMode,
) void {
    const row_selected = selected_row == .wordle;
    const prefix = if (row_selected) "> " else "  ";
    const label_style: vaxis.Style = if (row_selected) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
    _ = win.print(&.{
        .{ .text = prefix, .style = label_style },
        .{ .text = label, .style = label_style },
    }, .{ .row_offset = y, .col_offset = block_x, .wrap = .none });

    const selected_button: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = colors.ui.highlight, .bold = true };

    const today_selected = row_selected and selected_wordle == .today;
    const unlimited_selected = row_selected and selected_wordle == .unlimited;
    const today_style: vaxis.Style = if (today_selected) selected_button else .{};
    const unlimited_style: vaxis.Style = if (unlimited_selected) selected_button else .{};

    const mark: []const u8 = switch (wordle_status) {
        .not_played => " ",
        .won => "✓",
        .lost => "X",
    };

    const mark_fg = switch (wordle_status) {
        .not_played => colors.ui.text_dim,
        .won => colors.wordle.correct,
        .lost => vaxis.Color{ .rgb = .{ 220, 20, 60 } },
    };
    const mark_style: vaxis.Style = .{
        .fg = mark_fg,
        .bg = if (today_selected) colors.ui.highlight else vaxis.Color.default,
        .bold = true,
    };

    _ = win.print(&.{
        .{ .text = "  ", .style = .{} },
        .{ .text = "[ Today ", .style = today_style },
        .{ .text = mark, .style = mark_style },
        .{ .text = " ]", .style = today_style },
        .{ .text = " ", .style = .{} },
        .{ .text = streak_today_text, .style = .{ .fg = colors.ui.text_dim } },
        .{ .text = "  ", .style = .{} },
        .{ .text = "[ Unlimited ]", .style = unlimited_style },
        .{ .text = " ", .style = .{} },
        .{ .text = streak_unlimited_text, .style = .{ .fg = colors.ui.text_dim } },
    }, .{ .row_offset = y, .col_offset = right_x, .wrap = .none });
}

fn renderStatsRow(
    win: vaxis.Window,
    block_x: u16,
    right_x: u16,
    y: u16,
    label: []const u8,
    selected_row: Row,
    selected_stats: usize,
    window_start: usize,
) void {
    const row_selected = selected_row == .stats;
    const prefix = if (row_selected) "> " else "  ";
    const label_style: vaxis.Style = if (row_selected) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
    _ = win.print(&.{
        .{ .text = prefix, .style = label_style },
        .{ .text = label, .style = label_style },
    }, .{ .row_offset = y, .col_offset = block_x, .wrap = .none });

    const selected_button: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = colors.ui.highlight, .bold = true };

    const visible: usize = @min(@as(usize, 3), stats_options.len);
    const end: usize = @min(window_start + visible, stats_options.len);

    const can_left = window_start > 0;
    const can_right = (window_start + visible) < stats_options.len;
    const arrow_style: vaxis.Style = .{ .fg = if (row_selected) colors.ui.text else colors.ui.text_dim };
    const arrow_dim: vaxis.Style = .{ .fg = colors.ui.text_dim };

    var col: u16 = right_x;

    _ = win.print(&.{.{ .text = "<", .style = if (can_left) arrow_style else arrow_dim }}, .{
        .row_offset = y,
        .col_offset = col,
        .wrap = .none,
    });
    col += 1;
    _ = win.print(&.{.{ .text = " ", .style = .{} }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
    col += 1;

    for (window_start..end) |i| {
        const opt = stats_options[i];
        const is_sel = row_selected and i == selected_stats;
        const style: vaxis.Style = if (is_sel) selected_button else .{};

        _ = win.print(&.{.{ .text = "[ ", .style = style }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
        col += 2;
        _ = win.print(&.{.{ .text = opt.label, .style = style }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
        col += win.gwidth(opt.label);
        _ = win.print(&.{.{ .text = " ]", .style = style }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
        col += 2;

        if (i + 1 < end) {
            _ = win.print(&.{.{ .text = " ", .style = .{} }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
            col += 1;
        }
    }

    _ = win.print(&.{.{ .text = " ", .style = .{} }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
    col += 1;
    _ = win.print(&.{.{ .text = ">", .style = if (can_right) arrow_style else arrow_dim }}, .{
        .row_offset = y,
        .col_offset = col,
        .wrap = .none,
    });
}

fn renderConnectionsRow(
    win: vaxis.Window,
    block_x: u16,
    right_x: u16,
    y: u16,
    label: []const u8,
    status: storage_stats.PlayedStatus,
    streak_text: []const u8,
    selected_row: Row,
) void {
    const row_selected = selected_row == .connections;
    const prefix = if (row_selected) "> " else "  ";
    const label_style: vaxis.Style = if (row_selected) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
    _ = win.print(&.{
        .{ .text = prefix, .style = label_style },
        .{ .text = label, .style = label_style },
    }, .{ .row_offset = y, .col_offset = block_x, .wrap = .none });

    const selected_button: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = colors.ui.highlight, .bold = true };
    const btn_style: vaxis.Style = if (row_selected) selected_button else .{};

    const mark: []const u8 = switch (status) {
        .not_played => " ",
        .won => "✓",
        .lost => "X",
    };
    const mark_fg = switch (status) {
        .not_played => colors.ui.text_dim,
        .won => colors.wordle.correct,
        .lost => vaxis.Color{ .rgb = .{ 220, 20, 60 } },
    };
    const mark_style: vaxis.Style = .{
        .fg = mark_fg,
        .bg = if (row_selected) colors.ui.highlight else vaxis.Color.default,
        .bold = true,
    };

    _ = win.print(&.{
        .{ .text = "  ", .style = .{} },
        .{ .text = "[ Today ", .style = btn_style },
        .{ .text = mark, .style = mark_style },
        .{ .text = " ]", .style = btn_style },
        .{ .text = " ", .style = .{} },
        .{ .text = streak_text, .style = .{ .fg = colors.ui.text_dim } },
    }, .{ .row_offset = y, .col_offset = right_x, .wrap = .none });
}

fn calcStatsRightWidth(win: vaxis.Window, window_start: usize) u16 {
    const visible: usize = @min(@as(usize, 3), stats_options.len);
    var w: u16 = 0;
    w += 1; // <
    w += 1; // space

    const end: usize = @min(window_start + visible, stats_options.len);
    for (window_start..end) |i| {
        const opt = stats_options[i];
        w += 2; // "[ "
        w += win.gwidth(opt.label);
        w += 2; // " ]"
        if (i + 1 < end) w += 1; // space between buttons
    }

    w += 1; // space
    w += 1; // >
    return w;
}

fn calcStatsRightWidthMax(win: vaxis.Window) u16 {
    if (stats_options.len == 0) return 0;
    const visible: usize = @min(@as(usize, 3), stats_options.len);
    if (visible == 0) return 0;

    var max_w = calcStatsRightWidth(win, 0);
    const last_start: usize = if (stats_options.len > visible) stats_options.len - visible else 0;
    var start: usize = 0;
    while (start <= last_start) : (start += 1) {
        max_w = @max(max_w, calcStatsRightWidth(win, start));
    }
    return max_w;
}

fn ensureVisible(window_start: *usize, selected: usize, len: usize, max_visible: usize) void {
    if (len == 0) {
        window_start.* = 0;
        return;
    }
    const visible = @min(max_visible, len);
    if (selected < window_start.*) window_start.* = selected;
    if (selected >= window_start.* + visible) window_start.* = selected - (visible - 1);
    if (window_start.* + visible > len) window_start.* = len - visible;
}

fn isConfirmKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.enter, .{}) or
        k.matches('\n', .{}) or
        k.matches('\r', .{}) or
        k.matches(vaxis.Key.space, .{}) or
        k.matches(' ', .{});
}

test {
    std.testing.refAllDecls(@This());
}
