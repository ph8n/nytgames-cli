const std = @import("std");
const vaxis = @import("vaxis");

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
    spelling_bee,
    strands,
    sudoku,
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
        .connections => runStub(allocator, tty, vx, loop, "Connections"),
        .spelling_bee => runStub(allocator, tty, vx, loop, "Spelling Bee"),
        .strands => runStub(allocator, tty, vx, loop, "Strands"),
        .sudoku => runStub(allocator, tty, vx, loop, "Sudoku"),
    };
}

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

        try renderWordleMonth(frame_allocator, win, &cache.?, view_year, view_month);

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

fn runWordleUnlimited(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
) !Exit {
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

        try renderWordleUnlimitedRecent(frame_allocator, win, games);

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

    if (games.len == 0) {
        const msg = "No games yet";
        const msg_w = win.gwidth(msg);
        const col: u16 = if (plot.width > msg_w) @intCast((plot.width - msg_w) / 2) else 0;
        _ = plot.print(&.{.{ .text = msg, .style = .{ .fg = colors.ui.text_dim } }}, .{
            .row_offset = 2,
            .col_offset = col,
            .wrap = .none,
        });
        return;
    }

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

fn renderWordleMonth(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    cache: *const StatsCache,
    year: std.time.epoch.Year,
    month: u8,
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
    const col_w: u16 = 2;
    const max_cols: u16 = plot_w / col_w;
    const days_to_draw: u16 = @min(@as(u16, cache.days_in_month), max_cols);

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
        const x: u16 = axis_w + @as(u16, @intCast(d0)) * col_w;
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
            _ = plot.print(&.{.{ .text = label, .style = .{ .fg = colors.ui.text_dim } }}, .{
                .row_offset = axis_row + 1,
                .col_offset = x,
                .wrap = .none,
            });
        }
    }
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

fn clearCache(cache: *?StatsCache, allocator: std.mem.Allocator) void {
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

test {
    std.testing.refAllDecls(@This());
}
