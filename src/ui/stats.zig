const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const ctime = @cImport({
    @cInclude("time.h");
});

const app_event = @import("event.zig");
const colors = @import("colors.zig");
const keys = @import("keys.zig");
const date = @import("../utils/date.zig");
const storage_db = @import("../storage/db.zig");
const storage_stats = @import("../storage/stats.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

pub const Game = enum {
    wordle,
    wordle_unlimited,
    connections,
};

const YearMonth = struct {
    year: std.time.epoch.Year,
    month: u8,
};

const StatsCache = struct {
    const GameSummary = struct {
        won: bool,
        guesses: u8,
    };

    days_in_month: u8,
    games: []?GameSummary,

    fn deinit(self: *StatsCache, allocator: std.mem.Allocator) void {
        allocator.free(self.games);
        self.* = undefined;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
    game: Game,
) !Exit {
    return switch (game) {
        .wordle => runWordle(allocator, tty, vx, loop, storage),
        .wordle_unlimited => runWordleUnlimited(allocator, tty, vx, loop, storage),
        .connections => runConnections(allocator, tty, vx, loop, storage),
    };
}

const ConnectionsCache = struct {
    const GameSummary = struct {
        won: bool,
        mistakes: u8,
    };

    days_in_month: u8,
    games: []?GameSummary,

    fn deinit(self: *ConnectionsCache, allocator: std.mem.Allocator) void {
        allocator.free(self.games);
        self.* = undefined;
    }
};

const DaySummary = struct {
    played: u32 = 0,
    won: u32 = 0,
    lost: u32 = 0,
    win_rate: u32 = 0,
    avg_x100: ?u32 = null, // wins-only
};

const YearMonthKey = u32; // year * 100 + month

const MonthSummary = struct {
    year: std.time.epoch.Year,
    month: u8,
    played: u32 = 0,
    won: u32 = 0,
    lost: u32 = 0,
    win_rate: u32 = 0,
    // wins-only
    avg_x100: ?u32 = null,
};

const WordleAllTime = struct {
    played: u32 = 0,
    won: u32 = 0,
    lost: u32 = 0,
    win_rate: u32 = 0,
    current_streak: u32 = 0,
    best_streak: u32 = 0,
    // Guess distribution: 1..6 plus losses at index 6.
    dist: [7]u32 = .{0} ** 7,
    avg_guesses_x100: ?u32 = null,
    median_guesses_x2: ?u32 = null,
    best_month: ?MonthSummary = null,
    worst_month: ?MonthSummary = null,
};

const ConnectionsAllTime = struct {
    played: u32 = 0,
    won: u32 = 0,
    lost: u32 = 0,
    win_rate: u32 = 0,
    current_streak: u32 = 0,
    best_streak: u32 = 0,
    // Mistake distribution: 0..3 plus losses (4) at index 4.
    dist: [5]u32 = .{0} ** 5,
    avg_mistakes_x100: ?u32 = null,
    median_mistakes_x2: ?u32 = null,
    perfect: u32 = 0,
    best_month: ?MonthSummary = null,
    worst_month: ?MonthSummary = null,
};

const UnlimitedAllTime = struct {
    played: u32 = 0,
    won: u32 = 0,
    lost: u32 = 0,
    win_rate: u32 = 0,
    current_streak: u32 = 0,
    best_streak: u32 = 0,
    dist: [7]u32 = .{0} ** 7,
    avg_guesses_x100: ?u32 = null,
    median_guesses_x2: ?u32 = null,
    // Activity
    active_days: u32 = 0,
    max_games_day: u32 = 0,
    avg_games_per_active_day_x100: ?u32 = null,
    active_weeks: u32 = 0,
    max_games_week: u32 = 0,
    avg_games_per_active_week_x100: ?u32 = null,
    // Longest consecutive wins within a single local day.
    best_day_streak: u32 = 0,
    best_day_streak_date: ?date.Date = null,
    // Rolling windows
    last50: ?DaySummary = null,
    prev50: ?DaySummary = null,
};

const GlobalActivity = struct {
    wordle_last_played_at: ?i64 = null,
    connections_last_played_at: ?i64 = null,
    unlimited_last_played_at: ?i64 = null,
    most_active_hour: ?u8 = null, // 0-23
    most_active_wday: ?u8 = null, // 0=Sun..6=Sat
};

const QuickStats = struct {
    wordle: WordleAllTime,
    connections: ConnectionsAllTime,
    unlimited: UnlimitedAllTime,
    global: GlobalActivity,
};

fn runWordle(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
) !Exit {
    const today_date = try date.todayLocal();
    var view_year: std.time.epoch.Year = today_date.year;
    var view_month: u8 = today_date.month;

    const quick = try computeAllQuickStats(allocator, storage, today_date);

    var first_played: ?YearMonth = null;
    if (try storage_stats.getWordleFirstPlayedDateAlloc(allocator, &storage.db)) |min_date| {
        defer allocator.free(min_date.data);
        first_played = parseYearMonth(min_date.data);
    }

    var cache: ?StatsCache = null;
    defer if (cache) |*c| c.deinit(allocator);

    while (true) {
        // vaxis stores pointers to the text slices you print; keep frame strings
        // alive until after `vx.render()`.
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        try ensureCache(allocator, &cache, storage, view_year, view_month);

        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "Stats";
        const subtitle = "h/l or ←/→: month   q/Esc: back   Ctrl+C: quit";
        printCentered(win, 0, title, .{ .bold = true });
        printCentered(win, 1, subtitle, .{ .fg = colors.ui.text_dim });

        try renderWordleMonth(frame_allocator, win, &cache.?, view_year, view_month, &quick);

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches('q', .{}) or k.matches(vaxis.Key.escape, .{})) return .back_to_menu;

                if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{})) {
                    if (first_played) |fp| {
                        if (!isAtOrBefore(view_year, view_month, fp.year, fp.month)) {
                            decrementMonth(&view_year, &view_month);
                            clearCache(&cache, allocator);
                        }
                    }
                } else if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
                    if (!isAtOrAfter(view_year, view_month, today_date.year, today_date.month)) {
                        incrementMonth(&view_year, &view_month);
                        clearCache(&cache, allocator);
                    }
                }
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn runConnections(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
) !Exit {
    const today_date = try date.todayLocal();
    var view_year: std.time.epoch.Year = today_date.year;
    var view_month: u8 = today_date.month;

    const quick = try computeAllQuickStats(allocator, storage, today_date);

    var first_played: ?YearMonth = null;
    if (try storage_stats.getConnectionsFirstPlayedDateAlloc(allocator, &storage.db)) |min_date| {
        defer allocator.free(min_date.data);
        first_played = parseYearMonth(min_date.data);
    }

    var cache: ?ConnectionsCache = null;
    defer if (cache) |*c| c.deinit(allocator);

    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        try ensureConnectionsCache(allocator, &cache, storage, view_year, view_month);

        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "Stats";
        const subtitle = "h/l or ←/→: month   q/Esc: back   Ctrl+C: quit";
        printCentered(win, 0, title, .{ .bold = true });
        printCentered(win, 1, subtitle, .{ .fg = colors.ui.text_dim });

        try renderConnectionsMonth(frame_allocator, win, &cache.?, view_year, view_month, &quick);

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches('q', .{}) or k.matches(vaxis.Key.escape, .{})) return .back_to_menu;

                if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{})) {
                    if (first_played) |fp| {
                        if (!isAtOrBefore(view_year, view_month, fp.year, fp.month)) {
                            decrementMonth(&view_year, &view_month);
                            clearConnectionsCache(&cache, allocator);
                        }
                    }
                } else if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
                    if (!isAtOrAfter(view_year, view_month, today_date.year, today_date.month)) {
                        incrementMonth(&view_year, &view_month);
                        clearConnectionsCache(&cache, allocator);
                    }
                }
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn runWordleUnlimited(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
) !Exit {
    const today_date = try date.todayLocal();
    const quick = try computeAllQuickStats(allocator, storage, today_date);

    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        const games = try storage_stats.getWordleUnlimitedRecentGames(frame_allocator, &storage.db, 100);
        std.mem.reverse(storage_stats.WordleUnlimitedGameRow, games);

        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "Stats";
        const subtitle = "q/Esc: back   Ctrl+C: quit";
        printCentered(win, 0, title, .{ .bold = true });
        printCentered(win, 1, subtitle, .{ .fg = colors.ui.text_dim });

        try renderWordleUnlimitedRecent(frame_allocator, win, games, &quick);

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches('q', .{}) or k.matches(vaxis.Key.escape, .{})) return .back_to_menu;
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn renderWordleUnlimitedRecent(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    games: []const storage_stats.WordleUnlimitedGameRow,
    quick: *const QuickStats,
) !void {
    const header = try std.fmt.allocPrint(allocator, "Wordle Unlimited  (last {d} games)", .{games.len});
    _ = win.print(&.{.{ .text = header, .style = .{ .bold = true } }}, .{
        .row_offset = 3,
        .col_offset = 2,
        .wrap = .none,
    });

    const chart_y: u16 = 5;
    if (chart_y + 11 >= win.height) return;

    const plot = win.child(.{
        .x_off = 2,
        .y_off = @intCast(chart_y),
        .width = if (win.width > 4) win.width - 4 else 0,
        .height = 12,
        .border = .{ .where = .all, .glyphs = .single_square, .style = .{ .fg = colors.ui.border } },
    });
    plot.clear();
    if (plot.width < 20 or plot.height < 9) return;

    const y_labels = [_][]const u8{ "X", "6", "5", "4", "3", "2", "1" };
    const y_levels: u8 = 7; // 1..6 plus loss
    const axis_w: u16 = 2; // label + y-axis line
    const col_w: u16 = 1;
    const plot_w: u16 = plot.width - axis_w;
    const max_cols: u16 = plot_w / col_w;
    const games_to_draw: u16 = @min(@as(u16, @intCast(games.len)), @min(@as(u16, 100), max_cols));
    const start_index: usize = games.len - @as(usize, @intCast(games_to_draw));

    const bars_w: u16 = games_to_draw * col_w;
    const bars_pad: u16 = if (plot_w > bars_w) (plot_w - bars_w) / 2 else 0;
    const bars_x0: u16 = axis_w + bars_pad;

    // Y labels + axis line
    for (0..y_levels) |i| {
        const label = y_labels[i];
        const row: u16 = @intCast(i);
        _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .none,
        });
        plot.writeCell(1, row, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    // X axis baseline
    const axis_row: u16 = y_levels;
    plot.writeCell(1, axis_row, .{
        .char = .{ .grapheme = "┼", .width = 1 },
        .style = .{ .fg = colors.ui.text_dim },
    });
    var col: u16 = 2;
    while (col < plot.width) : (col += 1) {
        plot.writeCell(col, axis_row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    if (games.len == 0) {
        const msg = "No games yet";
        const msg_w = win.gwidth(msg);
        const msg_x: u16 = if (plot.width > msg_w) @intCast((plot.width - msg_w) / 2) else 0;
        _ = plot.print(&.{.{ .text = msg, .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = 2,
            .col_offset = msg_x,
            .wrap = .none,
        });
    } else {
        // Bars
        for (0..games_to_draw) |i| {
            const g = games[start_index + @as(usize, @intCast(i))];
            const x: u16 = bars_x0 + @as(u16, @intCast(i)) * col_w;
            const won = g.won != 0;
            const guesses: u8 = @intCast(@max(@as(i64, 0), g.guesses));
            const height: u8 = if (won) @min(@as(u8, 6), guesses) else 7;
            const color = if (won) colors.wordle.correct else vaxis.Color{ .rgb = .{ 220, 20, 60 } };
            const style: vaxis.Style = .{ .fg = color, .bold = true };

            var level: u8 = 0;
            while (level < height) : (level += 1) {
                const row_from_bottom: u16 = @as(u16, @intCast(y_levels - 1 - level));
                plot.writeCell(x, row_from_bottom, .{
                    .char = .{ .grapheme = "█", .width = 1 },
                    .style = style,
                });
            }
        }

        // X ticks: show game number within the last-100 window.
        const n: usize = @intCast(games_to_draw);
        const tick1: usize = 1;
        const tick_mid: usize = @max(@as(usize, 1), (n + 1) / 2);
        const tick_last: usize = n;
        const tick_values = [_]usize{ tick1, tick_mid, tick_last };
        for (tick_values) |tick| {
            if (tick < 1 or tick > n) continue;
            const rel: usize = tick - 1;
            const x: u16 = bars_x0 + @as(u16, @intCast(rel)) * col_w;
            plot.writeCell(x, axis_row, .{
                .char = .{ .grapheme = "┬", .width = 1 },
                .style = .{ .fg = colors.ui.text_dim },
            });

            const label = try std.fmt.allocPrint(allocator, "{d}", .{tick});
            const label_w = win.gwidth(label);
            var label_x: u16 = x;
            if (label_w > 0) {
                const shift: u16 = @intCast(label_w - 1);
                if (label_x >= shift) label_x -= shift else label_x = 0;
                if (label_x + label_w > plot.width) label_x = plot.width - label_w;
            }

            _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
                .row_offset = axis_row + 1,
                .col_offset = label_x,
                .wrap = .none,
            });
        }
    }

    const played: u32 = @intCast(games.len);
    var wins: u32 = 0;
    var losses: u32 = 0;
    var wins_by_guess: [6]u32 = .{0} ** 6;
    for (games) |g| {
        const won = g.won != 0;
        if (won) {
            wins += 1;
            const guesses: u8 = @intCast(@max(@as(i64, 1), g.guesses));
            if (guesses >= 1 and guesses <= 6) wins_by_guess[guesses - 1] += 1;
        } else {
            losses += 1;
        }
    }

    const window_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{percent(wins, played)});
    const window_played = try std.fmt.allocPrint(allocator, "{d}", .{played});
    const window_wins = try std.fmt.allocPrint(allocator, "{d}", .{wins});
    const window_losses = try std.fmt.allocPrint(allocator, "{d}", .{losses});
    const window_dist = try std.fmt.allocPrint(
        allocator,
        "1:{d} 2:{d} 3:{d} 4:{d} 5:{d} 6:{d} X:{d}",
        .{ wins_by_guess[0], wins_by_guess[1], wins_by_guess[2], wins_by_guess[3], wins_by_guess[4], wins_by_guess[5], losses },
    );

    const all_played = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.played});
    const all_wins = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.won});
    const all_losses = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.lost});
    const all_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{quick.unlimited.win_rate});
    const all_cur_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.current_streak});
    const all_best_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.best_streak});
    const all_avg_text = try fmtX100OrDash(allocator, quick.unlimited.avg_guesses_x100);
    const all_median_text = try fmtX2OrDash(allocator, quick.unlimited.median_guesses_x2);
    const all_dist = try std.fmt.allocPrint(
        allocator,
        "1:{d} 2:{d} 3:{d} 4:{d} 5:{d} 6:{d} X:{d}",
        .{ quick.unlimited.dist[0], quick.unlimited.dist[1], quick.unlimited.dist[2], quick.unlimited.dist[3], quick.unlimited.dist[4], quick.unlimited.dist[5], quick.unlimited.dist[6] },
    );

    const active_days = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.active_days});
    const max_day = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.max_games_day});
    const avg_day = try fmtX100OrDash(allocator, quick.unlimited.avg_games_per_active_day_x100);
    const active_weeks = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.active_weeks});
    const max_week = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.max_games_week});
    const avg_week = try fmtX100OrDash(allocator, quick.unlimited.avg_games_per_active_week_x100);

    const best_day_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.unlimited.best_day_streak});
    const best_day_date = try fmtDateOrDash(allocator, quick.unlimited.best_day_streak_date);

    const last50_win = if (quick.unlimited.last50) |s| blk: {
        if (s.avg_x100) |avg| {
            const avg_text = try std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ avg / 100, avg % 100 });
            break :blk try std.fmt.allocPrint(allocator, "{d}% avg {s} ({d} games)", .{ s.win_rate, avg_text, s.played });
        }
        break :blk try std.fmt.allocPrint(allocator, "{d}% ({d} games)", .{ s.win_rate, s.played });
    } else "—";
    const prev50_win = if (quick.unlimited.prev50) |s| blk: {
        if (s.avg_x100) |avg| {
            const avg_text = try std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ avg / 100, avg % 100 });
            break :blk try std.fmt.allocPrint(allocator, "{d}% avg {s} ({d} games)", .{ s.win_rate, avg_text, s.played });
        }
        break :blk try std.fmt.allocPrint(allocator, "{d}% ({d} games)", .{ s.win_rate, s.played });
    } else "—";

    const last_wordle = try fmtLastPlayedDateOrDash(allocator, quick.global.wordle_last_played_at);
    const last_connections = try fmtLastPlayedDateOrDash(allocator, quick.global.connections_last_played_at);
    const last_unlimited = try fmtLastPlayedDateOrDash(allocator, quick.global.unlimited_last_played_at);
    const active_hour = try fmtActiveHourOrDash(allocator, quick.global.most_active_hour);
    const active_wday = fmtActiveWdayOrDash(quick.global.most_active_wday);

    var items: [40]KeyValueItem = undefined;
    var n: usize = 0;

    items[n] = .{ .label = "Last played", .value = window_played };
    n += 1;
    items[n] = .{ .label = "Last win rate", .value = window_win_rate_text };
    n += 1;
    items[n] = .{ .label = "Last wins", .value = window_wins };
    n += 1;
    items[n] = .{ .label = "Last losses", .value = window_losses };
    n += 1;
    items[n] = .{ .label = "Last dist", .value = window_dist };
    n += 1;

    items[n] = .{ .label = "All played", .value = all_played };
    n += 1;
    items[n] = .{ .label = "All win rate", .value = all_win_rate_text };
    n += 1;
    items[n] = .{ .label = "All wins", .value = all_wins };
    n += 1;
    items[n] = .{ .label = "All losses", .value = all_losses };
    n += 1;
    items[n] = .{ .label = "Cur streak", .value = all_cur_streak };
    n += 1;
    items[n] = .{ .label = "Best streak", .value = all_best_streak };
    n += 1;
    items[n] = .{ .label = "Avg guesses", .value = all_avg_text };
    n += 1;
    items[n] = .{ .label = "Median", .value = all_median_text };
    n += 1;
    items[n] = .{ .label = "Guess dist", .value = all_dist };
    n += 1;

    items[n] = .{ .label = "Active days", .value = active_days };
    n += 1;
    items[n] = .{ .label = "Avg games/day", .value = avg_day };
    n += 1;
    items[n] = .{ .label = "Max games/day", .value = max_day };
    n += 1;
    items[n] = .{ .label = "Active weeks", .value = active_weeks };
    n += 1;
    items[n] = .{ .label = "Avg games/wk", .value = avg_week };
    n += 1;
    items[n] = .{ .label = "Max games/wk", .value = max_week };
    n += 1;
    items[n] = .{ .label = "Best day streak", .value = best_day_streak };
    n += 1;
    items[n] = .{ .label = "Best day date", .value = best_day_date };
    n += 1;
    items[n] = .{ .label = "Last 50", .value = last50_win };
    n += 1;
    items[n] = .{ .label = "Prev 50", .value = prev50_win };
    n += 1;

    items[n] = .{ .label = "Last Wordle", .value = last_wordle };
    n += 1;
    items[n] = .{ .label = "Last Conn", .value = last_connections };
    n += 1;
    items[n] = .{ .label = "Last Unl", .value = last_unlimited };
    n += 1;
    items[n] = .{ .label = "Active hour", .value = active_hour };
    n += 1;
    items[n] = .{ .label = "Active day", .value = active_wday };
    n += 1;

    renderKeyValueGrid(win, chart_y + 12, items[0..n]);
}

fn runStub(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    game_label: []const u8,
) !Exit {
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "Stats";
        const subtitle = "q/Esc: back   Ctrl+C: quit";
        printCentered(win, 0, title, .{ .bold = true });
        printCentered(win, 1, subtitle, .{ .fg = colors.ui.text_dim });

        const label = try std.fmt.allocPrint(frame_allocator, "{s}", .{game_label});
        _ = win.print(&.{.{ .text = label, .style = .{ .bold = true } }}, .{
            .row_offset = 3,
            .col_offset = 2,
            .wrap = .none,
        });
        _ = win.print(&.{.{ .text = "More stats coming soon.", .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = 5,
            .col_offset = 2,
            .wrap = .none,
        });

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches('q', .{}) or k.matches(vaxis.Key.escape, .{})) return .back_to_menu;
            },
            .mouse, .mouse_leave => {},
        }
    }
}

fn computeWordleAllTime(
    allocator: std.mem.Allocator,
    storage: *storage_db.Storage,
    today_date: date.Date,
) !WordleAllTime {
    var stats: WordleAllTime = .{};

    stats.current_streak = try storage_stats.getWordleDailyStreak(&storage.db, today_date);

    const rows = try storage_stats.getWordleGamesAllAlloc(allocator, &storage.db);
    defer {
        for (rows) |r| allocator.free(r.puzzle_date.data);
        allocator.free(rows);
    }

    var wins_by_guess: [6]u32 = .{0} ** 6;
    var sum_guesses: u64 = 0;

    var month_map: std.AutoHashMapUnmanaged(YearMonthKey, struct {
        year: std.time.epoch.Year,
        month: u8,
        played: u32,
        won: u32,
        lost: u32,
        sum_wins: u64,
        wins_count: u32,
    }) = .{};
    defer month_map.deinit(allocator);

    var best_streak: u32 = 0;
    var streak_cur: u32 = 0;
    var prev_win_day: ?std.time.epoch.EpochDay = null;

    for (rows) |r| {
        stats.played += 1;
        const won = r.won != 0;
        if (won) {
            stats.won += 1;
            const guesses: u8 = @intCast(@max(@as(i64, 1), r.guesses));
            if (guesses >= 1 and guesses <= 6) {
                stats.dist[guesses - 1] += 1;
                wins_by_guess[guesses - 1] += 1;
                sum_guesses += guesses;
            }

            const day = date.epochDayFromYYYYMMDD(r.puzzle_date.data) catch continue;
            if (prev_win_day) |p| {
                if (day.day == p.day + 1) {
                    streak_cur += 1;
                } else {
                    streak_cur = 1;
                }
            } else {
                streak_cur = 1;
            }
            best_streak = @max(best_streak, streak_cur);
            prev_win_day = day;
        } else {
            stats.lost += 1;
            stats.dist[6] += 1;
        }

        const ym = parseYearMonth(r.puzzle_date.data) orelse continue;
        const key: YearMonthKey = @intCast(@as(i64, ym.year) * 100 + @as(i64, ym.month));
        const gop = try month_map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .year = ym.year, .month = ym.month, .played = 0, .won = 0, .lost = 0, .sum_wins = 0, .wins_count = 0 };
        }
        gop.value_ptr.played += 1;
        if (won) {
            gop.value_ptr.won += 1;
            gop.value_ptr.sum_wins += @intCast(@max(@as(i64, 0), r.guesses));
            gop.value_ptr.wins_count += 1;
        } else {
            gop.value_ptr.lost += 1;
        }
    }

    stats.best_streak = best_streak;
    stats.win_rate = percent(stats.won, stats.played);

    if (stats.won > 0) {
        stats.avg_guesses_x100 = avgTimes100(sum_guesses, stats.won);
        stats.median_guesses_x2 = medianX2FromHistogram(wins_by_guess[0..], 1);
    }

    // Best/worst month by win rate (tie-breaker: lower avg guesses on wins).
    var best: ?MonthSummary = null;
    var worst: ?MonthSummary = null;
    var it = month_map.iterator();
    while (it.next()) |entry| {
        const m = entry.value_ptr.*;
        var ms: MonthSummary = .{ .year = m.year, .month = m.month };
        ms.played = m.played;
        ms.won = m.won;
        ms.lost = m.lost;
        ms.win_rate = percent(m.won, m.played);
        if (m.wins_count > 0) ms.avg_x100 = avgTimes100(m.sum_wins, m.wins_count);

        best = pickBetterMonth(best, ms, true);
        worst = pickBetterMonth(worst, ms, false);
    }
    stats.best_month = best;
    stats.worst_month = worst;

    return stats;
}

fn computeConnectionsAllTime(
    allocator: std.mem.Allocator,
    storage: *storage_db.Storage,
    today_date: date.Date,
) !ConnectionsAllTime {
    var stats: ConnectionsAllTime = .{};

    stats.current_streak = try storage_stats.getConnectionsDailyStreak(&storage.db, today_date);

    const rows = try storage_stats.getConnectionsGamesAllAlloc(allocator, &storage.db);
    defer {
        for (rows) |r| allocator.free(r.puzzle_date.data);
        allocator.free(rows);
    }

    var wins_by_mistakes: [4]u32 = .{0} ** 4; // 0..3
    var sum_mistakes: u64 = 0;

    var month_map: std.AutoHashMapUnmanaged(YearMonthKey, struct {
        year: std.time.epoch.Year,
        month: u8,
        played: u32,
        won: u32,
        lost: u32,
        sum_wins: u64,
        wins_count: u32,
    }) = .{};
    defer month_map.deinit(allocator);

    var best_streak: u32 = 0;
    var streak_cur: u32 = 0;
    var prev_win_day: ?std.time.epoch.EpochDay = null;

    for (rows) |r| {
        stats.played += 1;
        const won = r.won != 0;
        if (won) {
            stats.won += 1;
            const mistakes: u8 = @intCast(@max(@as(i64, 0), r.mistakes));
            const m_clamped: u8 = @min(@as(u8, 3), mistakes);
            stats.dist[m_clamped] += 1;
            wins_by_mistakes[m_clamped] += 1;
            sum_mistakes += m_clamped;
            if (m_clamped == 0) stats.perfect += 1;

            const day = date.epochDayFromYYYYMMDD(r.puzzle_date.data) catch continue;
            if (prev_win_day) |p| {
                if (day.day == p.day + 1) {
                    streak_cur += 1;
                } else {
                    streak_cur = 1;
                }
            } else {
                streak_cur = 1;
            }
            best_streak = @max(best_streak, streak_cur);
            prev_win_day = day;
        } else {
            stats.lost += 1;
            stats.dist[4] += 1;
        }

        const ym = parseYearMonth(r.puzzle_date.data) orelse continue;
        const key: YearMonthKey = @intCast(@as(i64, ym.year) * 100 + @as(i64, ym.month));
        const gop = try month_map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .year = ym.year, .month = ym.month, .played = 0, .won = 0, .lost = 0, .sum_wins = 0, .wins_count = 0 };
        }
        gop.value_ptr.played += 1;
        if (won) {
            gop.value_ptr.won += 1;
            gop.value_ptr.sum_wins += @intCast(@max(@as(i64, 0), r.mistakes));
            gop.value_ptr.wins_count += 1;
        } else {
            gop.value_ptr.lost += 1;
        }
    }

    stats.best_streak = best_streak;
    stats.win_rate = percent(stats.won, stats.played);

    if (stats.won > 0) {
        stats.avg_mistakes_x100 = avgTimes100(sum_mistakes, stats.won);
        stats.median_mistakes_x2 = medianX2FromHistogram(wins_by_mistakes[0..], 0);
    }

    var best: ?MonthSummary = null;
    var worst: ?MonthSummary = null;
    var it = month_map.iterator();
    while (it.next()) |entry| {
        const m = entry.value_ptr.*;
        var ms: MonthSummary = .{ .year = m.year, .month = m.month };
        ms.played = m.played;
        ms.won = m.won;
        ms.lost = m.lost;
        ms.win_rate = percent(m.won, m.played);
        if (m.wins_count > 0) ms.avg_x100 = avgTimes100(m.sum_wins, m.wins_count);

        best = pickBetterMonth(best, ms, true);
        worst = pickBetterMonth(worst, ms, false);
    }
    stats.best_month = best;
    stats.worst_month = worst;

    return stats;
}

fn computeUnlimitedAllTime(
    allocator: std.mem.Allocator,
    storage: *storage_db.Storage,
) !UnlimitedAllTime {
    var stats: UnlimitedAllTime = .{};

    stats.current_streak = try storage_stats.getWordleUnlimitedStreak(&storage.db);

    const rows = try storage_stats.getWordleUnlimitedGamesAllAlloc(allocator, &storage.db);
    defer allocator.free(rows);

    var wins_by_guess: [6]u32 = .{0} ** 6;
    var sum_guesses: u64 = 0;
    var best_streak: u32 = 0;
    var cur_streak: u32 = 0;

    // Activity aggregations.
    var active_days: u32 = 0;
    var max_games_day: u32 = 0;
    var day_key: ?u32 = null;
    var day_games: u32 = 0;
    var day_best: u32 = 0;
    var day_cur: u32 = 0;
    var day_date: ?date.Date = null;

    var best_day_streak: u32 = 0;
    var best_day_date: ?date.Date = null;

    var active_weeks: u32 = 0;
    var max_games_week: u32 = 0;
    var week_key: ?u32 = null;
    var week_games: u32 = 0;

    for (rows) |r| {
        stats.played += 1;
        const won = r.won != 0;
        if (won) {
            stats.won += 1;
            cur_streak += 1;
            best_streak = @max(best_streak, cur_streak);

            const guesses: u8 = @intCast(@max(@as(i64, 1), r.guesses));
            if (guesses >= 1 and guesses <= 6) {
                stats.dist[guesses - 1] += 1;
                wins_by_guess[guesses - 1] += 1;
                sum_guesses += guesses;
            }
        } else {
            stats.lost += 1;
            stats.dist[6] += 1;
            cur_streak = 0;
        }

        const local_day = date.localDateFromUnixTimestampSeconds(r.played_at) catch continue;
        const epoch_day = date.epochDayFromDate(local_day) catch continue;
        const cur_day_key: u32 = @intCast(epoch_day.day);
        const cur_week_key: u32 = cur_day_key / 7;

        if (day_key == null or cur_day_key != day_key.?) {
            if (day_key != null) {
                active_days += 1;
                max_games_day = @max(max_games_day, day_games);
                if (day_best > best_day_streak) {
                    best_day_streak = day_best;
                    best_day_date = day_date;
                }
            }
            day_key = cur_day_key;
            day_games = 0;
            day_best = 0;
            day_cur = 0;
            day_date = local_day;
        }
        day_games += 1;
        if (won) {
            day_cur += 1;
            day_best = @max(day_best, day_cur);
        } else {
            day_cur = 0;
        }

        if (week_key == null or cur_week_key != week_key.?) {
            if (week_key != null) {
                active_weeks += 1;
                max_games_week = @max(max_games_week, week_games);
            }
            week_key = cur_week_key;
            week_games = 0;
        }
        week_games += 1;
    }

    if (day_key != null) {
        active_days += 1;
        max_games_day = @max(max_games_day, day_games);
        if (day_best > best_day_streak) {
            best_day_streak = day_best;
            best_day_date = day_date;
        }
    }
    if (week_key != null) {
        active_weeks += 1;
        max_games_week = @max(max_games_week, week_games);
    }

    stats.best_streak = best_streak;
    stats.win_rate = percent(stats.won, stats.played);

    if (stats.won > 0) {
        stats.avg_guesses_x100 = avgTimes100(sum_guesses, stats.won);
        stats.median_guesses_x2 = medianX2FromHistogram(wins_by_guess[0..], 1);
    }

    stats.active_days = active_days;
    stats.max_games_day = max_games_day;
    if (active_days > 0) stats.avg_games_per_active_day_x100 = avgTimes100(stats.played, active_days);

    stats.active_weeks = active_weeks;
    stats.max_games_week = max_games_week;
    if (active_weeks > 0) stats.avg_games_per_active_week_x100 = avgTimes100(stats.played, active_weeks);

    stats.best_day_streak = best_day_streak;
    stats.best_day_streak_date = best_day_date;

    if (rows.len > 0) {
        const n: usize = @min(@as(usize, 50), rows.len);
        stats.last50 = computeWindowSummary(rows[rows.len - n ..]);
        if (rows.len > n) {
            const prev_n: usize = @min(n, rows.len - n);
            stats.prev50 = computeWindowSummary(rows[rows.len - n - prev_n .. rows.len - n]);
        }
    }

    return stats;
}

fn computeGlobalActivity(
    allocator: std.mem.Allocator,
    storage: *storage_db.Storage,
) !GlobalActivity {
    var stats: GlobalActivity = .{};

    var hour_counts: [24]u32 = .{0} ** 24;
    var wday_counts: [7]u32 = .{0} ** 7;

    const Queries = struct {
        fn scan(
            alloc: std.mem.Allocator,
            db: *storage_db.Storage,
            comptime query: []const u8,
            max_out: *?i64,
            hour_counts_: *[24]u32,
            wday_counts_: *[7]u32,
        ) !void {
            var stmt = try db.db.prepare(query);
            defer stmt.deinit();
            const rows = try stmt.all(i64, alloc, .{}, .{});
            defer alloc.free(rows);
            for (rows) |ts| {
                if (ts < 0) continue;
                if (max_out.* == null or ts > max_out.*.?) max_out.* = ts;
                if (localHourWday(ts)) |hw| {
                    hour_counts_[hw.hour] += 1;
                    wday_counts_[hw.wday] += 1;
                }
            }
        }
    };

    try Queries.scan(allocator, storage, "SELECT played_at FROM wordle_games", &stats.wordle_last_played_at, &hour_counts, &wday_counts);
    try Queries.scan(allocator, storage, "SELECT played_at FROM connections_games", &stats.connections_last_played_at, &hour_counts, &wday_counts);
    try Queries.scan(allocator, storage, "SELECT played_at FROM wordle_unlimited_games", &stats.unlimited_last_played_at, &hour_counts, &wday_counts);

    stats.most_active_hour = indexOfMax(hour_counts[0..]);
    stats.most_active_wday = indexOfMax(wday_counts[0..]);
    return stats;
}

fn computeAllQuickStats(allocator: std.mem.Allocator, storage: *storage_db.Storage, today_date: date.Date) !QuickStats {
    const wordle = try computeWordleAllTime(allocator, storage, today_date);
    const connections = try computeConnectionsAllTime(allocator, storage, today_date);
    const unlimited = try computeUnlimitedAllTime(allocator, storage);
    const global = try computeGlobalActivity(allocator, storage);
    return .{
        .wordle = wordle,
        .connections = connections,
        .unlimited = unlimited,
        .global = global,
    };
}

fn localHourWday(ts: i64) ?struct { hour: u8, wday: u8 } {
    if (ts < 0) return null;
    if (builtin.os.tag == .windows) return null;

    var t: ctime.time_t = @intCast(ts);
    var tm: ctime.tm = undefined;
    const tm_ptr = ctime.localtime_r(&t, &tm);
    if (tm_ptr == null) return null;

    if (tm.tm_hour < 0 or tm.tm_hour > 23) return null;
    if (tm.tm_wday < 0 or tm.tm_wday > 6) return null;

    return .{
        .hour = @intCast(tm.tm_hour),
        .wday = @intCast(tm.tm_wday),
    };
}

fn indexOfMax(counts: []const u32) ?u8 {
    var best_i: ?u8 = null;
    var best_v: u32 = 0;
    for (counts, 0..) |v, i| {
        if (v == 0 and best_i == null) continue;
        if (best_i == null or v > best_v) {
            best_v = v;
            best_i = @intCast(i);
        }
    }
    return best_i;
}

fn percent(numer: u32, denom: u32) u32 {
    if (denom == 0) return 0;
    return @intCast((@as(u64, numer) * 100 + @as(u64, denom) / 2) / @as(u64, denom));
}

fn avgTimes100(sum: u64, count: u32) u32 {
    if (count == 0) return 0;
    return @intCast((sum * 100 + @as(u64, count) / 2) / @as(u64, count));
}

fn valueAtHistogramIndex(counts: []const u32, base_value: u32, index: u32) u32 {
    var remaining = index;
    for (counts, 0..) |c, i| {
        if (remaining < c) return base_value + @as(u32, @intCast(i));
        remaining -= c;
    }
    return base_value;
}

fn medianX2FromHistogram(counts: []const u32, base_value: u32) ?u32 {
    var total: u32 = 0;
    for (counts) |c| total += c;
    if (total == 0) return null;

    if ((total & 1) == 1) {
        const mid = total / 2;
        const v = valueAtHistogramIndex(counts, base_value, mid);
        return v * 2;
    }
    const mid2 = total / 2;
    const mid1 = mid2 - 1;
    const v1 = valueAtHistogramIndex(counts, base_value, mid1);
    const v2 = valueAtHistogramIndex(counts, base_value, mid2);
    return v1 + v2;
}

fn fmtX100OrDash(allocator: std.mem.Allocator, x100: ?u32) ![]const u8 {
    if (x100) |v| {
        return try std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ v / 100, v % 100 });
    }
    return "-";
}

fn fmtX2OrDash(allocator: std.mem.Allocator, x2: ?u32) ![]const u8 {
    if (x2) |v| {
        if ((v & 1) == 0) return try std.fmt.allocPrint(allocator, "{d}", .{v / 2});
        return try std.fmt.allocPrint(allocator, "{d}.5", .{v / 2});
    }
    return "-";
}

fn fmtMonthSummaryOrDash(allocator: std.mem.Allocator, m: ?MonthSummary) ![]const u8 {
    if (m) |ms| {
        if (ms.avg_x100) |avg| {
            const avg_text = try std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ avg / 100, avg % 100 });
            return try std.fmt.allocPrint(
                allocator,
                "{d:0>4}-{d:0>2} {d}% avg {s}",
                .{ ms.year, ms.month, ms.win_rate, avg_text },
            );
        }
        return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2} {d}%", .{ ms.year, ms.month, ms.win_rate });
    }
    return "-";
}

fn fmtLastPlayedDateOrDash(allocator: std.mem.Allocator, ts: ?i64) ![]const u8 {
    if (ts) |t| {
        const d = date.localDateFromUnixTimestampSeconds(t) catch return "-";
        return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
    }
    return "-";
}

fn fmtDateOrDash(allocator: std.mem.Allocator, d: ?date.Date) ![]const u8 {
    if (d) |dd| {
        return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ dd.year, dd.month, dd.day });
    }
    return "-";
}

fn fmtActiveHourOrDash(allocator: std.mem.Allocator, hour: ?u8) ![]const u8 {
    if (hour) |h| return try std.fmt.allocPrint(allocator, "{d:0>2}:00", .{h});
    return "-";
}

fn fmtActiveWdayOrDash(wday: ?u8) []const u8 {
    if (wday) |d| {
        const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        if (d < names.len) return names[d];
    }
    return "-";
}

fn computeWindowSummary(rows: []const storage_stats.WordleUnlimitedGameFullRow) DaySummary {
    var s: DaySummary = .{};
    s.played = @intCast(rows.len);
    var sum_wins: u64 = 0;
    for (rows) |r| {
        if (r.won != 0) {
            s.won += 1;
            const guesses_i64 = @max(@as(i64, 1), r.guesses);
            const guesses_u8: u8 = @intCast(@min(@as(i64, 6), guesses_i64));
            sum_wins += @as(u64, guesses_u8);
        } else {
            s.lost += 1;
        }
    }
    s.win_rate = percent(s.won, s.played);
    if (s.won > 0) s.avg_x100 = avgTimes100(sum_wins, s.won);
    return s;
}

fn pickBetterMonth(cur: ?MonthSummary, cand: MonthSummary, want_best: bool) ?MonthSummary {
    if (cur == null) return cand;
    const a = cur.?;
    const b = cand;

    if (want_best) {
        if (b.win_rate > a.win_rate) return b;
        if (b.win_rate < a.win_rate) return a;
        // tie: lower avg wins-only
        if (a.avg_x100 == null and b.avg_x100 != null) return b;
        if (a.avg_x100 != null and b.avg_x100 == null) return a;
        if (a.avg_x100 != null and b.avg_x100 != null) {
            if (b.avg_x100.? < a.avg_x100.?) return b;
            if (b.avg_x100.? > a.avg_x100.?) return a;
        }
        return a;
    }

    // worst
    if (b.win_rate < a.win_rate) return b;
    if (b.win_rate > a.win_rate) return a;
    // tie: higher avg wins-only
    if (a.avg_x100 == null and b.avg_x100 != null) return b;
    if (a.avg_x100 != null and b.avg_x100 == null) return a;
    if (a.avg_x100 != null and b.avg_x100 != null) {
        if (b.avg_x100.? > a.avg_x100.?) return b;
        if (b.avg_x100.? < a.avg_x100.?) return a;
    }
    return a;
}

fn renderConnectionsMonth(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    cache: *const ConnectionsCache,
    year: std.time.epoch.Year,
    month: u8,
    quick: *const QuickStats,
) !void {
    const month_label = try std.fmt.allocPrint(allocator, "Connections  {d:0>4}-{d:0>2}", .{ year, month });
    _ = win.print(&.{.{ .text = month_label, .style = .{ .bold = true } }}, .{
        .row_offset = 3,
        .col_offset = 2,
        .wrap = .none,
    });

    const chart_y: u16 = 5;
    if (chart_y + 11 >= win.height) return;

    const plot = win.child(.{
        .x_off = 2,
        .y_off = @intCast(chart_y),
        .width = if (win.width > 4) win.width - 4 else 0,
        .height = 12,
        .border = .{ .where = .all, .glyphs = .single_square, .style = .{ .fg = colors.ui.border } },
    });
    plot.clear();
    if (plot.width < 20 or plot.height < 9) return;

    const y_levels: u8 = 5; // 0..3 plus loss
    const y_labels = [_][]const u8{ "X", "3", "2", "1", "0" };
    const axis_w: u16 = 2; // label + y-axis line
    const plot_w: u16 = plot.width - axis_w;
    const days_in_month_u16: u16 = @intCast(cache.days_in_month);

    var col_w: u16 = 2;
    if (plot_w < days_in_month_u16 * col_w) col_w = 1;

    const max_cols: u16 = plot_w / col_w;
    const days_to_draw: u16 = @min(days_in_month_u16, max_cols);

    const bars_w: u16 = days_to_draw * col_w;
    const bars_pad: u16 = if (plot_w > bars_w) (plot_w - bars_w) / 2 else 0;
    const bars_x0: u16 = axis_w + bars_pad;

    for (0..y_levels) |i| {
        const label = y_labels[i];
        const row: u16 = @intCast(i);
        _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .none,
        });
        plot.writeCell(1, row, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    const axis_row: u16 = y_levels;
    plot.writeCell(1, axis_row, .{
        .char = .{ .grapheme = "┼", .width = 1 },
        .style = .{ .fg = colors.ui.text_dim },
    });
    var col: u16 = 2;
    while (col < plot.width) : (col += 1) {
        plot.writeCell(col, axis_row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    for (0..days_to_draw) |d0| {
        const day_index: usize = @intCast(d0);
        const x: u16 = bars_x0 + @as(u16, @intCast(d0)) * col_w;
        if (cache.games[day_index]) |g| {
            const mistakes: u8 = @min(@as(u8, 3), g.mistakes);
            const height: u8 = if (g.won) mistakes + 1 else y_levels;
            const color = if (g.won) colors.wordle.correct else vaxis.Color{ .rgb = .{ 220, 20, 60 } };
            const style: vaxis.Style = .{ .fg = color, .bold = true };

            var level: u8 = 0;
            while (level < height) : (level += 1) {
                const row_from_bottom: u16 = @as(u16, @intCast(y_levels - 1 - level));
                plot.writeCell(x, row_from_bottom, .{
                    .char = .{ .grapheme = "█", .width = 1 },
                    .style = style,
                });
            }
        }

        if ((day_index % 7) == 0) {
            plot.writeCell(x, axis_row, .{
                .char = .{ .grapheme = "┬", .width = 1 },
                .style = .{ .fg = colors.ui.text_dim },
            });

            const day_num: u8 = @intCast(day_index + 1);
            const label = try std.fmt.allocPrint(allocator, "{d}", .{day_num});
            const label_w = win.gwidth(label);
            var label_x: u16 = x;
            if (label_w > 0) {
                const shift: u16 = @intCast(label_w - 1);
                if (label_x >= shift) label_x -= shift else label_x = 0;
                if (label_x + label_w > plot.width) label_x = plot.width - label_w;
            }
            _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
                .row_offset = axis_row + 1,
                .col_offset = label_x,
                .wrap = .none,
            });
        }
    }

    var played: u32 = 0;
    var wins: u32 = 0;
    var losses: u32 = 0;
    var wins_by_mistakes: [4]u32 = .{0} ** 4;
    var sum_mistakes: u64 = 0;
    var perfect: u32 = 0;
    for (cache.games) |gopt| {
        if (gopt) |g| {
            played += 1;
            if (g.won) {
                wins += 1;
                const m: u8 = @min(@as(u8, 3), g.mistakes);
                wins_by_mistakes[m] += 1;
                sum_mistakes += m;
                if (m == 0) perfect += 1;
            } else {
                losses += 1;
            }
        }
    }

    const month_win_rate = percent(wins, played);
    const month_avg_x100: ?u32 = if (wins > 0) avgTimes100(sum_mistakes, wins) else null;
    const month_median_x2: ?u32 = medianX2FromHistogram(wins_by_mistakes[0..], 0);

    const month_dist = try std.fmt.allocPrint(
        allocator,
        "0:{d} 1:{d} 2:{d} 3:{d} X:{d}",
        .{ wins_by_mistakes[0], wins_by_mistakes[1], wins_by_mistakes[2], wins_by_mistakes[3], losses },
    );
    const all_dist = try std.fmt.allocPrint(
        allocator,
        "0:{d} 1:{d} 2:{d} 3:{d} X:{d}",
        .{ quick.connections.dist[0], quick.connections.dist[1], quick.connections.dist[2], quick.connections.dist[3], quick.connections.dist[4] },
    );

    const month_played = try std.fmt.allocPrint(allocator, "{d}", .{played});
    const month_wins = try std.fmt.allocPrint(allocator, "{d}", .{wins});
    const month_losses = try std.fmt.allocPrint(allocator, "{d}", .{losses});
    const month_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{month_win_rate});
    const month_avg_text = try fmtX100OrDash(allocator, month_avg_x100);
    const month_median_text = try fmtX2OrDash(allocator, month_median_x2);
    const month_perfect = try std.fmt.allocPrint(allocator, "{d}", .{perfect});

    const all_played = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.played});
    const all_wins = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.won});
    const all_losses = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.lost});
    const all_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{quick.connections.win_rate});
    const all_cur_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.current_streak});
    const all_best_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.best_streak});
    const all_avg_text = try fmtX100OrDash(allocator, quick.connections.avg_mistakes_x100);
    const all_median_text = try fmtX2OrDash(allocator, quick.connections.median_mistakes_x2);
    const all_perfect = try std.fmt.allocPrint(allocator, "{d}", .{quick.connections.perfect});
    const all_perfect_rate = try std.fmt.allocPrint(
        allocator,
        "{d}%",
        .{percent(quick.connections.perfect, quick.connections.won)},
    );

    const best_month_text = try fmtMonthSummaryOrDash(allocator, quick.connections.best_month);
    const worst_month_text = try fmtMonthSummaryOrDash(allocator, quick.connections.worst_month);

    const last_wordle = try fmtLastPlayedDateOrDash(allocator, quick.global.wordle_last_played_at);
    const last_connections = try fmtLastPlayedDateOrDash(allocator, quick.global.connections_last_played_at);
    const last_unlimited = try fmtLastPlayedDateOrDash(allocator, quick.global.unlimited_last_played_at);
    const active_hour = try fmtActiveHourOrDash(allocator, quick.global.most_active_hour);
    const active_wday = fmtActiveWdayOrDash(quick.global.most_active_wday);

    var items: [34]KeyValueItem = undefined;
    var n: usize = 0;

    items[n] = .{ .label = "Month played", .value = month_played };
    n += 1;
    items[n] = .{ .label = "Month win rate", .value = month_win_rate_text };
    n += 1;
    items[n] = .{ .label = "Month wins", .value = month_wins };
    n += 1;
    items[n] = .{ .label = "Month losses", .value = month_losses };
    n += 1;
    items[n] = .{ .label = "Month avg mistakes", .value = month_avg_text };
    n += 1;
    items[n] = .{ .label = "Month median", .value = month_median_text };
    n += 1;
    items[n] = .{ .label = "Month perfect", .value = month_perfect };
    n += 1;
    items[n] = .{ .label = "Month dist", .value = month_dist };
    n += 1;

    items[n] = .{ .label = "All played", .value = all_played };
    n += 1;
    items[n] = .{ .label = "All win rate", .value = all_win_rate_text };
    n += 1;
    items[n] = .{ .label = "All wins", .value = all_wins };
    n += 1;
    items[n] = .{ .label = "All losses", .value = all_losses };
    n += 1;
    items[n] = .{ .label = "Cur streak", .value = all_cur_streak };
    n += 1;
    items[n] = .{ .label = "Best streak", .value = all_best_streak };
    n += 1;
    items[n] = .{ .label = "Avg mistakes", .value = all_avg_text };
    n += 1;
    items[n] = .{ .label = "Median", .value = all_median_text };
    n += 1;
    items[n] = .{ .label = "Perfect", .value = all_perfect };
    n += 1;
    items[n] = .{ .label = "Perfect %", .value = all_perfect_rate };
    n += 1;
    items[n] = .{ .label = "Mistake dist", .value = all_dist };
    n += 1;
    items[n] = .{ .label = "Best month", .value = best_month_text };
    n += 1;
    items[n] = .{ .label = "Worst month", .value = worst_month_text };
    n += 1;

    items[n] = .{ .label = "Last Wordle", .value = last_wordle };
    n += 1;
    items[n] = .{ .label = "Last Conn", .value = last_connections };
    n += 1;
    items[n] = .{ .label = "Last Unl", .value = last_unlimited };
    n += 1;
    items[n] = .{ .label = "Active hour", .value = active_hour };
    n += 1;
    items[n] = .{ .label = "Active day", .value = active_wday };
    n += 1;

    renderKeyValueGrid(win, chart_y + 12, items[0..n]);
}

fn renderWordleMonth(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    cache: *const StatsCache,
    year: std.time.epoch.Year,
    month: u8,
    quick: *const QuickStats,
) !void {
    const month_label = try std.fmt.allocPrint(allocator, "Wordle  {d:0>4}-{d:0>2}", .{ year, month });
    _ = win.print(&.{.{ .text = month_label, .style = .{ .bold = true } }}, .{
        .row_offset = 3,
        .col_offset = 2,
        .wrap = .none,
    });

    const chart_y: u16 = 5;
    if (chart_y + 11 >= win.height) return;

    // `Window.child` returns the inner window (inside the border).
    const plot = win.child(.{
        .x_off = 2,
        .y_off = @intCast(chart_y),
        .width = if (win.width > 4) win.width - 4 else 0,
        .height = 12,
        .border = .{ .where = .all, .glyphs = .single_square, .style = .{ .fg = colors.ui.border } },
    });
    plot.clear();
    if (plot.width < 20 or plot.height < 9) return;

    const y_levels: u8 = 7; // 1..6 plus loss
    const y_labels = [_][]const u8{ "X", "6", "5", "4", "3", "2", "1" };
    const axis_w: u16 = 2; // label + y-axis line
    const plot_w: u16 = plot.width - axis_w;
    const days_in_month_u16: u16 = @intCast(cache.days_in_month);

    // Prefer 2 columns per day, but fall back to 1 when the terminal is too narrow
    // so we can still show the full month without cutting off the last days.
    var col_w: u16 = 2;
    if (plot_w < days_in_month_u16 * col_w) col_w = 1;

    const max_cols: u16 = plot_w / col_w;
    const days_to_draw: u16 = @min(days_in_month_u16, max_cols);

    const bars_w: u16 = days_to_draw * col_w;
    const bars_pad: u16 = if (plot_w > bars_w) (plot_w - bars_w) / 2 else 0;
    const bars_x0: u16 = axis_w + bars_pad;

    // Y labels + axis line
    for (0..y_levels) |i| {
        const label = y_labels[i];
        const row: u16 = @intCast(i);
        _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .none,
        });
        plot.writeCell(1, row, .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    // X axis baseline
    const axis_row: u16 = y_levels;
    plot.writeCell(1, axis_row, .{
        .char = .{ .grapheme = "┼", .width = 1 },
        .style = .{ .fg = colors.ui.text_dim },
    });
    var col: u16 = 2;
    while (col < plot.width) : (col += 1) {
        plot.writeCell(col, axis_row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = colors.ui.text_dim },
        });
    }

    // Bars + weekly ticks
    for (0..days_to_draw) |d0| {
        const day_index: usize = @intCast(d0);
        const x: u16 = bars_x0 + @as(u16, @intCast(d0)) * col_w;
        if (cache.games[day_index]) |g| {
            const height: u8 = if (g.won) @min(@as(u8, 6), g.guesses) else 7;
            const color = if (g.won) colors.wordle.correct else vaxis.Color{ .rgb = .{ 220, 20, 60 } };
            const style: vaxis.Style = .{ .fg = color, .bold = true };

            var level: u8 = 0;
            while (level < height) : (level += 1) {
                const row_from_bottom: u16 = @as(u16, @intCast(y_levels - 1 - level));
                plot.writeCell(x, row_from_bottom, .{
                    .char = .{ .grapheme = "█", .width = 1 },
                    .style = style,
                });
            }
        }

        if ((day_index % 7) == 0) {
            plot.writeCell(x, axis_row, .{
                .char = .{ .grapheme = "┬", .width = 1 },
                .style = .{ .fg = colors.ui.text_dim },
            });

            const day_num: u8 = @intCast(day_index + 1);
            const label = try std.fmt.allocPrint(allocator, "{d}", .{day_num});
            const label_w = win.gwidth(label);
            var label_x: u16 = x;
            if (label_w > 0) {
                const shift: u16 = @intCast(label_w - 1);
                if (label_x >= shift) label_x -= shift else label_x = 0;
                if (label_x + label_w > plot.width) label_x = plot.width - label_w;
            }
            _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
                .row_offset = axis_row + 1,
                .col_offset = label_x,
                .wrap = .none,
            });
        }
    }

    var played: u32 = 0;
    var wins: u32 = 0;
    var losses: u32 = 0;
    var wins_by_guess: [6]u32 = .{0} ** 6;
    var sum_guesses: u64 = 0;
    for (cache.games) |gopt| {
        if (gopt) |g| {
            played += 1;
            if (g.won) {
                wins += 1;
                const guesses: u8 = @min(@as(u8, 6), g.guesses);
                if (guesses >= 1) {
                    wins_by_guess[guesses - 1] += 1;
                    sum_guesses += guesses;
                }
            } else {
                losses += 1;
            }
        }
    }

    const month_win_rate = percent(wins, played);
    const month_avg_x100: ?u32 = if (wins > 0) avgTimes100(sum_guesses, wins) else null;
    const month_median_x2: ?u32 = medianX2FromHistogram(wins_by_guess[0..], 1);

    const month_dist = try std.fmt.allocPrint(
        allocator,
        "1:{d} 2:{d} 3:{d} 4:{d} 5:{d} 6:{d} X:{d}",
        .{ wins_by_guess[0], wins_by_guess[1], wins_by_guess[2], wins_by_guess[3], wins_by_guess[4], wins_by_guess[5], losses },
    );
    const all_dist = try std.fmt.allocPrint(
        allocator,
        "1:{d} 2:{d} 3:{d} 4:{d} 5:{d} 6:{d} X:{d}",
        .{ quick.wordle.dist[0], quick.wordle.dist[1], quick.wordle.dist[2], quick.wordle.dist[3], quick.wordle.dist[4], quick.wordle.dist[5], quick.wordle.dist[6] },
    );

    const month_played = try std.fmt.allocPrint(allocator, "{d}", .{played});
    const month_wins = try std.fmt.allocPrint(allocator, "{d}", .{wins});
    const month_losses = try std.fmt.allocPrint(allocator, "{d}", .{losses});
    const month_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{month_win_rate});
    const month_avg_text = try fmtX100OrDash(allocator, month_avg_x100);
    const month_median_text = try fmtX2OrDash(allocator, month_median_x2);

    const all_played = try std.fmt.allocPrint(allocator, "{d}", .{quick.wordle.played});
    const all_wins = try std.fmt.allocPrint(allocator, "{d}", .{quick.wordle.won});
    const all_losses = try std.fmt.allocPrint(allocator, "{d}", .{quick.wordle.lost});
    const all_win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{quick.wordle.win_rate});
    const all_cur_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.wordle.current_streak});
    const all_best_streak = try std.fmt.allocPrint(allocator, "{d}", .{quick.wordle.best_streak});
    const all_avg_text = try fmtX100OrDash(allocator, quick.wordle.avg_guesses_x100);
    const all_median_text = try fmtX2OrDash(allocator, quick.wordle.median_guesses_x2);

    const best_month_text = try fmtMonthSummaryOrDash(allocator, quick.wordle.best_month);
    const worst_month_text = try fmtMonthSummaryOrDash(allocator, quick.wordle.worst_month);

    const last_wordle = try fmtLastPlayedDateOrDash(allocator, quick.global.wordle_last_played_at);
    const last_connections = try fmtLastPlayedDateOrDash(allocator, quick.global.connections_last_played_at);
    const last_unlimited = try fmtLastPlayedDateOrDash(allocator, quick.global.unlimited_last_played_at);
    const active_hour = try fmtActiveHourOrDash(allocator, quick.global.most_active_hour);
    const active_wday = fmtActiveWdayOrDash(quick.global.most_active_wday);

    var items: [32]KeyValueItem = undefined;
    var n: usize = 0;

    items[n] = .{ .label = "Month played", .value = month_played };
    n += 1;
    items[n] = .{ .label = "Month win rate", .value = month_win_rate_text };
    n += 1;
    items[n] = .{ .label = "Month wins", .value = month_wins };
    n += 1;
    items[n] = .{ .label = "Month losses", .value = month_losses };
    n += 1;
    items[n] = .{ .label = "Month avg guesses", .value = month_avg_text };
    n += 1;
    items[n] = .{ .label = "Month median", .value = month_median_text };
    n += 1;
    items[n] = .{ .label = "Month dist", .value = month_dist };
    n += 1;

    items[n] = .{ .label = "All played", .value = all_played };
    n += 1;
    items[n] = .{ .label = "All win rate", .value = all_win_rate_text };
    n += 1;
    items[n] = .{ .label = "All wins", .value = all_wins };
    n += 1;
    items[n] = .{ .label = "All losses", .value = all_losses };
    n += 1;
    items[n] = .{ .label = "Cur streak", .value = all_cur_streak };
    n += 1;
    items[n] = .{ .label = "Best streak", .value = all_best_streak };
    n += 1;
    items[n] = .{ .label = "Avg guesses", .value = all_avg_text };
    n += 1;
    items[n] = .{ .label = "Median", .value = all_median_text };
    n += 1;
    items[n] = .{ .label = "Guess dist", .value = all_dist };
    n += 1;
    items[n] = .{ .label = "Best month", .value = best_month_text };
    n += 1;
    items[n] = .{ .label = "Worst month", .value = worst_month_text };
    n += 1;

    items[n] = .{ .label = "Last Wordle", .value = last_wordle };
    n += 1;
    items[n] = .{ .label = "Last Conn", .value = last_connections };
    n += 1;
    items[n] = .{ .label = "Last Unl", .value = last_unlimited };
    n += 1;
    items[n] = .{ .label = "Active hour", .value = active_hour };
    n += 1;
    items[n] = .{ .label = "Active day", .value = active_wday };
    n += 1;

    renderKeyValueGrid(win, chart_y + 12, items[0..n]);
}

fn ensureCache(
    allocator: std.mem.Allocator,
    cache: *?StatsCache,
    storage: *storage_db.Storage,
    year: std.time.epoch.Year,
    month: u8,
) !void {
    if (cache.* != null) return;

    const days_in_month = daysInMonth(year, month);

    const start = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-01", .{ year, month });
    defer allocator.free(start);
    const end = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, days_in_month });
    defer allocator.free(end);

    const rows = try storage_stats.getWordleGamesBetween(allocator, &storage.db, start, end);
    defer {
        for (rows) |r| allocator.free(r.puzzle_date.data);
        allocator.free(rows);
    }

    var games = try allocator.alloc(?StatsCache.GameSummary, days_in_month);
    @memset(games, null);

    for (rows) |r| {
        const day = parseDayFromYyyyMmDd(r.puzzle_date.data) orelse continue;
        if (day == 0 or day > days_in_month) continue;
        games[day - 1] = .{ .won = r.won != 0, .guesses = @intCast(r.guesses) };
    }

    cache.* = .{
        .days_in_month = days_in_month,
        .games = games,
    };
}

fn ensureConnectionsCache(
    allocator: std.mem.Allocator,
    cache: *?ConnectionsCache,
    storage: *storage_db.Storage,
    year: std.time.epoch.Year,
    month: u8,
) !void {
    if (cache.* != null) return;

    const days_in_month = daysInMonth(year, month);

    const start = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-01", .{ year, month });
    defer allocator.free(start);
    const end = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, days_in_month });
    defer allocator.free(end);

    const rows = try storage_stats.getConnectionsGamesBetween(allocator, &storage.db, start, end);
    defer {
        for (rows) |r| allocator.free(r.puzzle_date.data);
        allocator.free(rows);
    }

    var games = try allocator.alloc(?ConnectionsCache.GameSummary, days_in_month);
    @memset(games, null);

    for (rows) |r| {
        const day = parseDayFromYyyyMmDd(r.puzzle_date.data) orelse continue;
        if (day == 0 or day > days_in_month) continue;
        games[day - 1] = .{ .won = r.won != 0, .mistakes = @intCast(r.mistakes) };
    }

    cache.* = .{
        .days_in_month = days_in_month,
        .games = games,
    };
}

fn clearCache(cache: *?StatsCache, allocator: std.mem.Allocator) void {
    if (cache.*) |*c| c.deinit(allocator);
    cache.* = null;
}

fn clearConnectionsCache(cache: *?ConnectionsCache, allocator: std.mem.Allocator) void {
    if (cache.*) |*c| c.deinit(allocator);
    cache.* = null;
}

fn parseYearMonth(s: []const u8) ?YearMonth {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(std.time.epoch.Year, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    if (month < 1 or month > 12) return null;
    return .{ .year = year, .month = month };
}

fn parseDayFromYyyyMmDd(s: []const u8) ?u8 {
    if (s.len < 10) return null;
    return std.fmt.parseInt(u8, s[8..10], 10) catch null;
}

fn daysInMonth(year: std.time.epoch.Year, month: u8) u8 {
    const m: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
    return @intCast(std.time.epoch.getDaysInMonth(year, m));
}

fn decrementMonth(year: *std.time.epoch.Year, month: *u8) void {
    if (month.* == 1) {
        year.* -= 1;
        month.* = 12;
    } else {
        month.* -= 1;
    }
}

fn incrementMonth(year: *std.time.epoch.Year, month: *u8) void {
    if (month.* == 12) {
        year.* += 1;
        month.* = 1;
    } else {
        month.* += 1;
    }
}

fn isAtOrAfter(y: std.time.epoch.Year, m: u8, y2: std.time.epoch.Year, m2: u8) bool {
    return (y > y2) or (y == y2 and m >= m2);
}

fn isAtOrBefore(y: std.time.epoch.Year, m: u8, y2: std.time.epoch.Year, m2: u8) bool {
    return (y < y2) or (y == y2 and m <= m2);
}

fn printCentered(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height) return;
    const w = win.gwidth(text);
    const col: u16 = if (win.width > w) @as(u16, @intCast((win.width - w) / 2)) else 0;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

fn renderSummaryGrid(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    start_y: u16,
    played: u32,
    wins: u32,
    losses: u32,
) !void {
    const win_rate: u32 = percent(wins, played);

    const played_text = try std.fmt.allocPrint(allocator, "{d}", .{played});
    const win_rate_text = try std.fmt.allocPrint(allocator, "{d}%", .{win_rate});
    const wins_text = try std.fmt.allocPrint(allocator, "{d}", .{wins});
    const losses_text = try std.fmt.allocPrint(allocator, "{d}", .{losses});

    const items = [_]KeyValueItem{
        .{ .label = "Games played", .value = played_text },
        .{ .label = "Win rate %", .value = win_rate_text },
        .{ .label = "Wins", .value = wins_text },
        .{ .label = "Losses", .value = losses_text },
    };

    renderKeyValueGrid(win, start_y, items[0..]);
}

const KeyValueItem = struct {
    label: []const u8,
    value: []const u8,
};

fn renderKeyValueGrid(win: vaxis.Window, start_y: u16, items: []const KeyValueItem) void {
    if (start_y >= win.height or win.width <= 4) return;
    if (items.len == 0) return;

    const avail_rows_u16: u16 = win.height - start_y;
    const rows_per_col: usize = @intCast(@min(@as(u16, @intCast(items.len)), avail_rows_u16));
    if (rows_per_col == 0) return;

    const needed_cols: usize = (items.len + rows_per_col - 1) / rows_per_col;
    var cols: usize = @min(needed_cols, @as(usize, 2));
    if (cols == 0) return;

    var max_label_w: u16 = 0;
    var max_value_w: u16 = 0;
    for (items) |it| {
        max_label_w = @max(max_label_w, win.gwidth(it.label));
        max_value_w = @max(max_value_w, win.gwidth(it.value));
    }

    const col_w: u16 = max_label_w + 2 + max_value_w;
    const col_gap: u16 = 6;
    const total_w: u16 = @intCast(@as(u16, @intCast(cols)) * col_w + @as(u16, @intCast(cols - 1)) * col_gap);

    const region_x: u16 = 2;
    const region_w: u16 = win.width - 4;
    if (total_w > region_w) cols = 1;

    const total_w2: u16 = @intCast(@as(u16, @intCast(cols)) * col_w + @as(u16, @intCast(cols - 1)) * col_gap);
    const x0: u16 = if (region_w > total_w2) region_x + (region_w - total_w2) / 2 else region_x;

    const max_items: usize = @min(items.len, cols * rows_per_col);
    const label_style: vaxis.Style = .{ .fg = colors.ui.text_dim };
    const value_style: vaxis.Style = .{ .fg = colors.ui.text, .bold = true };
    const pad_spaces = "                                                                ";

    for (0..max_items) |i| {
        const col_i: usize = i / rows_per_col;
        const row_i: usize = i % rows_per_col;
        const x: u16 = x0 + @as(u16, @intCast(col_i)) * (col_w + col_gap);
        const y: u16 = start_y + @as(u16, @intCast(row_i));

        const it = items[i];
        const label_w = win.gwidth(it.label);
        const pad_w: u16 = if (max_label_w > label_w) max_label_w - label_w else 0;
        const pad_len: usize = @intCast(@min(@as(u16, @intCast(pad_spaces.len)), pad_w));

        _ = win.print(&.{
            .{ .text = it.label, .style = label_style },
            .{ .text = pad_spaces[0..pad_len], .style = label_style },
            .{ .text = "  ", .style = label_style },
            .{ .text = it.value, .style = value_style },
        }, .{
            .row_offset = y,
            .col_offset = x,
            .wrap = .none,
        });
    }
}

test {
    std.testing.refAllDecls(@This());
}
