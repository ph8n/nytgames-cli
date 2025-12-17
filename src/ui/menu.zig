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
    stats_wordle,
    stats_wordle_unlimited,
    stats_connections,
    quit,
};

const Action = enum {
    play,
    stats,
};

const GameOption = struct {
    label: []const u8,
    choice: Choice,
};

const game_options = [_]GameOption{
    .{ .label = "Wordle", .choice = .wordle },
    .{ .label = "Wordle Unlimited", .choice = .wordle_unlimited },
    .{ .label = "Connections", .choice = .connections },
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
    dev_mode: bool,
) !Choice {
    var selected_action: Action = .play;
    var selected_game: usize = 0;

    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        const base_title = game_options[selected_game].label;
        var title_buf: [128]u8 = undefined;
        const big_title = makeBigTitle(&title_buf, base_title);
        const title = if (win.gwidth(big_title) <= win.width) big_title else base_title;

        const hint = "Left/Right h/l: game  •  Up/Down j/k: action  •  Enter/Space  •  Ctrl+C";

        var info_buf: [128]u8 = undefined;
        const info = try formatGameInfo(&info_buf, storage, dev_mode, game_options[selected_game].choice);

        const block_h: u16 = 6; // title + keymap + info + gap + 2 options
        const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;

        printCentered(win, block_y + 0, title, .{ .bold = true });
        printCentered(win, block_y + 1, hint, .{ .fg = colors.ui.text_dim });
        printCentered(win, block_y + 2, info, .{ .fg = colors.ui.text_dim });

        const play_style: vaxis.Style = if (selected_action == .play) .{ .bold = true } else .{ .fg = colors.ui.text_dim };
        const stats_style: vaxis.Style = if (selected_action == .stats) .{ .bold = true } else .{ .fg = colors.ui.text_dim };

        const action_max_w = @max(win.gwidth("Play"), win.gwidth("Stats"));
        const action_col: u16 = if (win.width > action_max_w) @as(u16, @intCast((win.width - action_max_w) / 2)) else 0;
        printAt(win, block_y + 4, action_col, "Play", play_style);
        printAt(win, block_y + 5, action_col, "Stats", stats_style);

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;

                if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{})) {
                    if (selected_game > 0) selected_game -= 1;
                } else if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
                    if (selected_game + 1 < game_options.len) selected_game += 1;
                } else if (k.matches(vaxis.Key.up, .{}) or k.matches('k', .{})) {
                    selected_action = .play;
                } else if (k.matches(vaxis.Key.down, .{}) or k.matches('j', .{})) {
                    selected_action = .stats;
                } else if (isConfirmKey(k)) {
                    const game_choice = game_options[selected_game].choice;
                    return switch (selected_action) {
                        .play => game_choice,
                        .stats => statsChoiceForGame(game_choice),
                    };
                }
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn statsChoiceForGame(choice: Choice) Choice {
    return switch (choice) {
        .wordle => .stats_wordle,
        .wordle_unlimited => .stats_wordle_unlimited,
        .connections => .stats_connections,
        else => unreachable,
    };
}

fn makeBigTitle(buf: []u8, title: []const u8) []const u8 {
    var i: usize = 0;
    for (title) |c| {
        if (i >= buf.len) break;
        buf[i] = std.ascii.toUpper(c);
        i += 1;
        if (i >= buf.len) break;
        buf[i] = ' ';
        i += 1;
    }
    if (i > 0) i -= 1; // trailing space
    return buf[0..i];
}

fn formatGameInfo(buf: []u8, storage: *storage_db.Storage, dev_mode: bool, game: Choice) ![]const u8 {
    const today_date = try date.todayLocal();
    var today_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDD(&today_buf, today_date);
    const today = today_buf[0..];

    switch (game) {
        .wordle => {
            const status: storage_stats.PlayedStatus = if (dev_mode) .not_played else try storage_stats.getWordlePlayedStatus(&storage.db, today);
            const streak: u32 = if (dev_mode) 0 else try storage_stats.getWordleDailyStreak(&storage.db, today_date);
            const mark: []const u8 = switch (status) {
                .won => "✓",
                .lost => "X",
                .not_played => "-",
            };
            return std.fmt.bufPrint(buf, "Today: {s}  •  Streak: {d}", .{ mark, streak }) catch unreachable;
        },
        .connections => {
            const status: storage_stats.PlayedStatus = if (dev_mode) .not_played else try storage_stats.getConnectionsPlayedStatus(&storage.db, today);
            const streak: u32 = if (dev_mode) 0 else try storage_stats.getConnectionsDailyStreak(&storage.db, today_date);
            const mark: []const u8 = switch (status) {
                .won => "✓",
                .lost => "X",
                .not_played => "-",
            };
            return std.fmt.bufPrint(buf, "Today: {s}  •  Streak: {d}", .{ mark, streak }) catch unreachable;
        },
        .wordle_unlimited => {
            const streak: u32 = if (dev_mode) 0 else try storage_stats.getWordleUnlimitedStreak(&storage.db);
            const last_won = if (dev_mode)
                null
            else
                try storage.db.one(
                    i64,
                    "SELECT won FROM wordle_unlimited_games ORDER BY played_at DESC, id DESC LIMIT 1",
                    .{},
                    .{},
                );
            const mark: []const u8 = if (last_won) |won| if (won != 0) "✓" else "X" else "-";
            return std.fmt.bufPrint(buf, "Last: {s}  •  Streak: {d}", .{ mark, streak }) catch unreachable;
        },
        else => unreachable,
    }
}

fn printCentered(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height) return;
    const w = win.gwidth(text);
    const col: u16 = if (win.width > w) @as(u16, @intCast((win.width - w) / 2)) else 0;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

fn printAt(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height) return;
    if (col >= win.width) return;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = row, .col_offset = col, .wrap = .none });
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
