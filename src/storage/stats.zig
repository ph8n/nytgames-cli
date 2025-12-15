const std = @import("std");
const sqlite = @import("sqlite");

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
