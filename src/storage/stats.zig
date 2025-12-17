const std = @import("std");
const sqlite = @import("sqlite");

const date = @import("../utils/date.zig");

pub const WordleResult = struct {
    puzzle_date: []const u8, // YYYY-MM-DD (local date)
    puzzle_id: i32,
    won: bool,
    guesses: u8, // 1-6, or 0 if lost
    played_at: i64, // unix seconds
};

pub fn hasPlayedWordle(db: *sqlite.Db, puzzle_date: []const u8) !bool {
    const row = try db.one(
        i32,
        "SELECT 1 FROM wordle_games WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{puzzle_date},
    );
    return row != null;
}

pub const PlayedStatus = enum {
    not_played,
    won,
    lost,
};

pub fn getWordlePlayedStatus(db: *sqlite.Db, puzzle_date: []const u8) !PlayedStatus {
    const won = try db.one(
        i64,
        "SELECT won FROM wordle_games WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{puzzle_date},
    );
    if (won == null) return .not_played;
    return if (won.? != 0) .won else .lost;
}

pub fn getWordleDailyStreak(db: *sqlite.Db, today: date.Date) !u32 {
    var today_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDD(&today_buf, today);
    const today_str = today_buf[0..];

    const today_status = try getWordlePlayedStatus(db, today_str);
    if (today_status == .lost) return 0;

    var end_day = date.epochDayFromDate(today) catch return 0;
    if (today_status == .not_played) {
        if (end_day.day == 0) return 0;
        end_day.day -= 1;
    }

    var end_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDDFromEpochDay(&end_buf, end_day);
    const end_str = end_buf[0..];

    // The streak only exists if we actually won on the end date.
    const end_won = try db.one(
        i64,
        "SELECT won FROM wordle_games WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{end_str},
    );
    if (end_won == null or end_won.? == 0) return 0;

    const Row = struct { puzzle_date: [10]u8 };

    var stmt = try db.prepare(
        \\SELECT puzzle_date
        \\FROM wordle_games
        \\WHERE won = 1 AND puzzle_date <= ?
        \\ORDER BY puzzle_date DESC
    );
    defer stmt.deinit();

    var iter = try stmt.iterator(Row, .{end_str});
    var expected = end_day;
    var streak: u32 = 0;
    while (try iter.next(.{})) |row| {
        const row_day = date.epochDayFromYYYYMMDD(row.puzzle_date[0..]) catch break;
        if (row_day.day != expected.day) break;

        streak += 1;
        if (expected.day == 0) break;
        expected.day -= 1;
    }
    return streak;
}

pub const ConnectionsResult = struct {
    puzzle_date: []const u8, // YYYY-MM-DD (local date)
    puzzle_id: i32,
    won: bool,
    mistakes: u8, // 0-4
    played_at: i64, // unix seconds
};

pub fn getConnectionsPlayedStatus(db: *sqlite.Db, puzzle_date: []const u8) !PlayedStatus {
    const won = try db.one(
        i64,
        "SELECT won FROM connections_games WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{puzzle_date},
    );
    if (won == null) return .not_played;
    return if (won.? != 0) .won else .lost;
}

pub fn saveConnectionsResult(db: *sqlite.Db, result: ConnectionsResult) !void {
    // If the date already exists, ignore to keep "played today" idempotent.
    try db.exec(
        \\INSERT OR IGNORE INTO connections_games (puzzle_date, puzzle_id, won, mistakes, played_at)
        \\VALUES (?, ?, ?, ?, ?)
    , .{}, .{
        result.puzzle_date,
        result.puzzle_id,
        @as(i32, @intFromBool(result.won)),
        @as(i32, result.mistakes),
        result.played_at,
    });
}

pub fn getConnectionsDailyStreak(db: *sqlite.Db, today: date.Date) !u32 {
    var today_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDD(&today_buf, today);
    const today_str = today_buf[0..];

    const today_status = try getConnectionsPlayedStatus(db, today_str);
    if (today_status == .lost) return 0;

    var end_day = date.epochDayFromDate(today) catch return 0;
    if (today_status == .not_played) {
        if (end_day.day == 0) return 0;
        end_day.day -= 1;
    }

    var end_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDDFromEpochDay(&end_buf, end_day);
    const end_str = end_buf[0..];

    // The streak only exists if we actually won on the end date.
    const end_won = try db.one(
        i64,
        "SELECT won FROM connections_games WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{end_str},
    );
    if (end_won == null or end_won.? == 0) return 0;

    const Row = struct { puzzle_date: [10]u8 };

    var stmt = try db.prepare(
        \\SELECT puzzle_date
        \\FROM connections_games
        \\WHERE won = 1 AND puzzle_date <= ?
        \\ORDER BY puzzle_date DESC
    );
    defer stmt.deinit();

    var iter = try stmt.iterator(Row, .{end_str});
    var expected = end_day;
    var streak: u32 = 0;
    while (try iter.next(.{})) |row| {
        const row_day = date.epochDayFromYYYYMMDD(row.puzzle_date[0..]) catch break;
        if (row_day.day != expected.day) break;

        streak += 1;
        if (expected.day == 0) break;
        expected.day -= 1;
    }
    return streak;
}

pub const ConnectionsGameRow = struct {
    puzzle_date: sqlite.Text,
    won: i64,
    mistakes: i64,
};

pub fn getConnectionsGamesBetween(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    start_date: []const u8,
    end_date: []const u8,
) ![]ConnectionsGameRow {
    var stmt = try db.prepare(
        \\SELECT puzzle_date, won, mistakes
        \\FROM connections_games
        \\WHERE puzzle_date BETWEEN ? AND ?
        \\ORDER BY puzzle_date ASC
    );
    defer stmt.deinit();

    return try stmt.all(ConnectionsGameRow, allocator, .{}, .{ start_date, end_date });
}

pub fn getConnectionsFirstPlayedDateAlloc(allocator: std.mem.Allocator, db: *sqlite.Db) !?sqlite.Text {
    return (try db.oneAlloc(
        sqlite.Text,
        allocator,
        "SELECT MIN(puzzle_date) FROM connections_games",
        .{},
        .{},
    ));
}

pub fn saveWordleResult(db: *sqlite.Db, result: WordleResult) !void {
    // If the date already exists, ignore to keep "played today" idempotent.
    try db.exec(
        \\INSERT OR IGNORE INTO wordle_games (puzzle_date, puzzle_id, won, guesses, played_at)
        \\VALUES (?, ?, ?, ?, ?)
    , .{}, .{
        result.puzzle_date,
        result.puzzle_id,
        @as(i32, @intFromBool(result.won)),
        @as(i32, result.guesses),
        result.played_at,
    });
}

pub const WordleUnlimitedResult = struct {
    won: bool,
    guesses: u8, // 1-6, or 0 if lost
    played_at: i64, // unix seconds
};

pub fn saveWordleUnlimitedResult(db: *sqlite.Db, result: WordleUnlimitedResult) !void {
    try db.exec(
        \\INSERT INTO wordle_unlimited_games (won, guesses, played_at)
        \\VALUES (?, ?, ?)
    , .{}, .{
        @as(i32, @intFromBool(result.won)),
        @as(i32, result.guesses),
        result.played_at,
    });
}

pub fn getWordleUnlimitedStreak(db: *sqlite.Db) !u32 {
    var stmt = try db.prepare(
        \\SELECT won
        \\FROM wordle_unlimited_games
        \\ORDER BY played_at DESC, id DESC
    );
    defer stmt.deinit();

    var iter = try stmt.iterator(i64, .{});
    var streak: u32 = 0;
    while (try iter.next(.{})) |won| {
        if (won != 0) {
            streak += 1;
        } else {
            break;
        }
    }
    return streak;
}

pub const WordleUnlimitedGameRow = struct {
    won: i64,
    guesses: i64,
};

pub fn getWordleUnlimitedRecentGames(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    limit: u32,
) ![]WordleUnlimitedGameRow {
    var stmt = try db.prepare(
        \\SELECT won, guesses
        \\FROM wordle_unlimited_games
        \\ORDER BY played_at DESC, id DESC
        \\LIMIT ?
    );
    defer stmt.deinit();

    return try stmt.all(WordleUnlimitedGameRow, allocator, .{}, .{@as(i64, limit)});
}

pub const WordleGameRow = struct {
    puzzle_date: sqlite.Text,
    won: i64,
    guesses: i64,
};

pub fn getWordleGamesBetween(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    start_date: []const u8,
    end_date: []const u8,
) ![]WordleGameRow {
    var stmt = try db.prepare(
        \\SELECT puzzle_date, won, guesses
        \\FROM wordle_games
        \\WHERE puzzle_date BETWEEN ? AND ?
        \\ORDER BY puzzle_date ASC
    );
    defer stmt.deinit();

    return try stmt.all(WordleGameRow, allocator, .{}, .{ start_date, end_date });
}

pub fn getWordleFirstPlayedDateAlloc(allocator: std.mem.Allocator, db: *sqlite.Db) !?sqlite.Text {
    return (try db.oneAlloc(
        sqlite.Text,
        allocator,
        "SELECT MIN(puzzle_date) FROM wordle_games",
        .{},
        .{},
    ));
}

test {
    std.testing.refAllDecls(@This());
}
