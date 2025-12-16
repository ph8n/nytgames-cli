const std = @import("std");
const sqlite = @import("sqlite");

pub const AppName = "nytg-cli";
pub const DbFilename = "stats.db";

pub const Storage = struct {
    allocator: std.mem.Allocator,
    db: sqlite.Db,
    /// Owned by `allocator`.
    path: []u8,

    pub fn deinit(self: *Storage) void {
        self.db.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const OpenOptions = struct {
    /// If provided, overrides the default DB location.
    /// If the parent directory doesn't exist, it will be created.
    db_path: ?[]const u8 = null,
};

pub fn open(allocator: std.mem.Allocator, options: OpenOptions) !Storage {
    const path = try resolveDbPath(allocator, options);
    errdefer allocator.free(path);

    try ensureParentDirExists(path);

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = true, .create = true },
    });
    errdefer db.deinit();

    try configureDb(&db);
    try migrate(&db);

    return .{
        .allocator = allocator,
        .db = db,
        .path = path,
    };
}

fn resolveDbPath(allocator: std.mem.Allocator, options: OpenOptions) ![]u8 {
    if (options.db_path) |p| {
        return try allocator.dupe(u8, p);
    }

    const app_dir = try std.fs.getAppDataDir(allocator, AppName);
    defer allocator.free(app_dir);

    // Ensure the per-app directory exists.
    // This may be an absolute path; on POSIX mkdir-at ignores dirfd for absolute paths.
    try std.fs.cwd().makePath(app_dir);

    return try std.fs.path.join(allocator, &.{ app_dir, DbFilename });
}

fn ensureParentDirExists(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(parent);
}

fn configureDb(db: *sqlite.Db) !void {
    _ = try db.pragma(void, .{}, "foreign_keys", "1");
    // Improves concurrency and reduces "database is locked" in practice.
    _ = try db.pragma([16:0]u8, .{}, "journal_mode", "WAL");
    _ = try db.pragma(void, .{}, "synchronous", "NORMAL");
    _ = try db.pragma(i64, .{}, "busy_timeout", "5000");
}

const LatestSchemaVersion: i64 = 3;

fn migrate(db: *sqlite.Db) !void {
    var version = (try db.pragma(i64, .{}, "user_version", null)) orelse 0;
    if (version >= LatestSchemaVersion) return;

    if (version < 1) {
        try migrateToV1(db);
        _ = try db.pragma(void, .{}, "user_version", "1");
        version = 1;
    }

    if (version < 2) {
        try migrateToV2(db);
        _ = try db.pragma(void, .{}, "user_version", "2");
        version = 2;
    }

    if (version < 3) {
        try migrateToV3(db);
        _ = try db.pragma(void, .{}, "user_version", "3");
        version = 3;
    }
}

fn migrateToV1(db: *sqlite.Db) !void {
    // Wordle
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS wordle_games (
        \\  id INTEGER PRIMARY KEY,
        \\  puzzle_date TEXT NOT NULL UNIQUE,
        \\  puzzle_id INTEGER NOT NULL,
        \\  won INTEGER NOT NULL,
        \\  guesses INTEGER NOT NULL,
        \\  played_at INTEGER NOT NULL
        \\)
    , .{}, .{});

    // Connections
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS connections_games (
        \\  id INTEGER PRIMARY KEY,
        \\  puzzle_date TEXT NOT NULL UNIQUE,
        \\  puzzle_id INTEGER NOT NULL,
        \\  won INTEGER NOT NULL,
        \\  mistakes INTEGER NOT NULL,
        \\  played_at INTEGER NOT NULL
        \\)
    , .{}, .{});

    // Spelling Bee
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS spelling_bee_games (
        \\  id INTEGER PRIMARY KEY,
        \\  puzzle_date TEXT NOT NULL UNIQUE,
        \\  puzzle_id INTEGER NOT NULL,
        \\  words_found INTEGER NOT NULL,
        \\  total_words INTEGER NOT NULL,
        \\  pangrams_found INTEGER NOT NULL,
        \\  points INTEGER NOT NULL,
        \\  max_points INTEGER NOT NULL,
        \\  played_at INTEGER NOT NULL
        \\)
    , .{}, .{});

}

fn migrateToV2(db: *sqlite.Db) !void {
    // Wordle Unlimited
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS wordle_unlimited_games (
        \\  id INTEGER PRIMARY KEY,
        \\  won INTEGER NOT NULL,
        \\  guesses INTEGER NOT NULL,
        \\  played_at INTEGER NOT NULL
        \\)
    , .{}, .{});
}

fn migrateToV3(db: *sqlite.Db) !void {
    // Spelling Bee progress (resumable)
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS spelling_bee_progress (
        \\  puzzle_date TEXT NOT NULL PRIMARY KEY,
        \\  puzzle_id INTEGER NOT NULL,
        \\  center_letter TEXT NOT NULL,
        \\  outer_letters TEXT NOT NULL,
        \\  words_found INTEGER NOT NULL DEFAULT 0,
        \\  total_words INTEGER,
        \\  pangrams_found INTEGER NOT NULL DEFAULT 0,
        \\  points INTEGER NOT NULL DEFAULT 0,
        \\  max_points INTEGER,
        \\  started_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  completed_at INTEGER
        \\)
    , .{}, .{});

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS spelling_bee_found_words (
        \\  id INTEGER PRIMARY KEY,
        \\  puzzle_date TEXT NOT NULL,
        \\  word TEXT NOT NULL,
        \\  points INTEGER NOT NULL,
        \\  is_pangram INTEGER NOT NULL DEFAULT 0,
        \\  found_at INTEGER NOT NULL,
        \\  UNIQUE(puzzle_date, word),
        \\  FOREIGN KEY(puzzle_date) REFERENCES spelling_bee_progress(puzzle_date) ON DELETE CASCADE
        \\)
    , .{}, .{});

    try db.exec(
        \\CREATE INDEX IF NOT EXISTS idx_spelling_bee_found_words_puzzle_date
        \\  ON spelling_bee_found_words(puzzle_date)
    , .{}, .{});
}

test {
    std.testing.refAllDecls(@This());
}
