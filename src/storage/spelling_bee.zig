const std = @import("std");
const sqlite = @import("sqlite");

pub const Progress = struct {
    puzzle_id: i32,
    words_found: u32,
    total_words: ?u32,
    pangrams_found: u32,
    points: u32,
    max_points: ?u32,
    started_at: i64,
    updated_at: i64,
    completed_at: ?i64,
};

pub fn loadOrStartProgress(
    db: *sqlite.Db,
    puzzle_date: []const u8,
    puzzle_id: i32,
    center_letter: []const u8,
    outer_letters: []const u8,
    total_words: u32,
    max_points: u32,
) !Progress {
    try ensureProgressForPuzzle(
        db,
        puzzle_date,
        puzzle_id,
        center_letter,
        outer_letters,
        total_words,
        max_points,
    );

    return (try getProgress(db, puzzle_date)) orelse return error.MissingProgressRow;
}

pub const FoundWordRow = struct {
    word: sqlite.Text,
    is_pangram: i64,
};

pub fn getFoundWordsForDateAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    puzzle_date: []const u8,
) ![]FoundWordRow {
    var stmt = try db.prepare(
        \\SELECT word, is_pangram
        \\FROM spelling_bee_found_words
        \\WHERE puzzle_date = ?
        \\ORDER BY word ASC
    );
    defer stmt.deinit();

    return try stmt.all(FoundWordRow, allocator, .{}, .{puzzle_date});
}

pub const RecentProgressRow = struct {
    puzzle_date: sqlite.Text,
    words_found: i64,
    points: i64,
    pangrams_found: i64,
};

pub fn getRecentProgressAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    limit: u32,
) ![]RecentProgressRow {
    var stmt = try db.prepare(
        \\SELECT puzzle_date, words_found, points, pangrams_found
        \\FROM spelling_bee_progress
        \\ORDER BY puzzle_date DESC
        \\LIMIT ?
    );
    defer stmt.deinit();

    return try stmt.all(RecentProgressRow, allocator, .{}, .{@as(i64, @intCast(limit))});
}

pub fn hasFoundWord(db: *sqlite.Db, puzzle_date: []const u8, word: []const u8) !bool {
    const row = try db.one(
        i32,
        "SELECT 1 FROM spelling_bee_found_words WHERE puzzle_date = ? AND word = ? LIMIT 1",
        .{},
        .{ puzzle_date, word },
    );
    return row != null;
}

pub fn tryAddFoundWord(
    db: *sqlite.Db,
    puzzle_date: []const u8,
    word: []const u8,
    points: u32,
    is_pangram: bool,
) !bool {
    if (try hasFoundWord(db, puzzle_date, word)) return false;

    const now = std.time.timestamp();
    try db.exec(
        \\INSERT INTO spelling_bee_found_words (puzzle_date, word, points, is_pangram, found_at)
        \\VALUES (?, ?, ?, ?, ?)
    , .{}, .{
        puzzle_date,
        word,
        @as(i64, @intCast(points)),
        @as(i32, @intFromBool(is_pangram)),
        now,
    });

    try recomputeProgressTotals(db, puzzle_date, now);
    return true;
}

fn ensureProgressForPuzzle(
    db: *sqlite.Db,
    puzzle_date: []const u8,
    puzzle_id: i32,
    center_letter: []const u8,
    outer_letters: []const u8,
    total_words: u32,
    max_points: u32,
) !void {
    const existing_puzzle_id = try db.one(
        i64,
        "SELECT puzzle_id FROM spelling_bee_progress WHERE puzzle_date = ? LIMIT 1",
        .{},
        .{puzzle_date},
    );

    if (existing_puzzle_id != null and existing_puzzle_id.? != @as(i64, puzzle_id)) {
        try db.exec("DELETE FROM spelling_bee_progress WHERE puzzle_date = ?", .{}, .{puzzle_date});
    }

    const now = std.time.timestamp();
    try db.exec(
        \\INSERT OR IGNORE INTO spelling_bee_progress (
        \\  puzzle_date, puzzle_id, center_letter, outer_letters,
        \\  words_found, total_words, pangrams_found, points, max_points,
        \\  started_at, updated_at, completed_at
        \\) VALUES (?, ?, ?, ?, 0, ?, 0, 0, ?, ?, ?, NULL)
    , .{}, .{
        puzzle_date,
        puzzle_id,
        center_letter,
        outer_letters,
        @as(i64, @intCast(total_words)),
        @as(i64, @intCast(max_points)),
        now,
        now,
    });

    try db.exec(
        \\UPDATE spelling_bee_progress
        \\SET puzzle_id = ?, center_letter = ?, outer_letters = ?, total_words = ?, max_points = ?
        \\WHERE puzzle_date = ?
    , .{}, .{
        puzzle_id,
        center_letter,
        outer_letters,
        @as(i64, @intCast(total_words)),
        @as(i64, @intCast(max_points)),
        puzzle_date,
    });
}

pub fn getProgress(db: *sqlite.Db, puzzle_date: []const u8) !?Progress {
    const Row = struct {
        puzzle_id: i64,
        words_found: i64,
        total_words: ?i64,
        pangrams_found: i64,
        points: i64,
        max_points: ?i64,
        started_at: i64,
        updated_at: i64,
        completed_at: ?i64,
    };

    var stmt = try db.prepare(
        \\SELECT puzzle_id, words_found, total_words, pangrams_found, points, max_points, started_at, updated_at, completed_at
        \\FROM spelling_bee_progress
        \\WHERE puzzle_date = ?
        \\LIMIT 1
    );
    defer stmt.deinit();

    var iter = try stmt.iterator(Row, .{puzzle_date});
    const row = (try iter.next(.{})) orelse return null;

    return .{
        .puzzle_id = @intCast(row.puzzle_id),
        .words_found = @intCast(row.words_found),
        .total_words = if (row.total_words) |v| @intCast(v) else null,
        .pangrams_found = @intCast(row.pangrams_found),
        .points = @intCast(row.points),
        .max_points = if (row.max_points) |v| @intCast(v) else null,
        .started_at = row.started_at,
        .updated_at = row.updated_at,
        .completed_at = row.completed_at,
    };
}

fn recomputeProgressTotals(db: *sqlite.Db, puzzle_date: []const u8, now: i64) !void {
    const Totals = struct {
        words_found: i64,
        points: i64,
        pangrams_found: i64,
    };

    var stmt = try db.prepare(
        \\SELECT COUNT(*) as words_found, COALESCE(SUM(points), 0) as points, COALESCE(SUM(is_pangram), 0) as pangrams_found
        \\FROM spelling_bee_found_words
        \\WHERE puzzle_date = ?
    );
    defer stmt.deinit();

    var iter = try stmt.iterator(Totals, .{puzzle_date});
    const totals = (try iter.next(.{})) orelse Totals{ .words_found = 0, .points = 0, .pangrams_found = 0 };

    try db.exec(
        \\UPDATE spelling_bee_progress
        \\SET words_found = ?, pangrams_found = ?, points = ?, updated_at = ?
        \\WHERE puzzle_date = ?
    , .{}, .{
        totals.words_found,
        totals.pangrams_found,
        totals.points,
        now,
        puzzle_date,
    });

    const ProgressPoints = struct { points: i64, max_points: ?i64, total_words: ?i64 };
    var stmt2 = try db.prepare(
        \\SELECT points, max_points, total_words
        \\FROM spelling_bee_progress
        \\WHERE puzzle_date = ?
        \\LIMIT 1
    );
    defer stmt2.deinit();

    var iter2 = try stmt2.iterator(ProgressPoints, .{puzzle_date});
    if (try iter2.next(.{})) |p| {
        const done_by_points = p.max_points != null and p.points >= p.max_points.?;
        const done_by_words = p.total_words != null and totals.words_found >= p.total_words.?;
        if (done_by_points or done_by_words) {
            try db.exec(
                \\UPDATE spelling_bee_progress
                \\SET completed_at = COALESCE(completed_at, ?)
                \\WHERE puzzle_date = ?
            , .{}, .{ now, puzzle_date });
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
