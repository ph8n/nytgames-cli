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

test {
    std.testing.refAllDecls(@This());
}
