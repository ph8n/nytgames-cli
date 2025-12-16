const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");

const api_client = @import("../../api/client.zig");
const colors = @import("../../ui/colors.zig");
const app_event = @import("../../ui/event.zig");
const ui_keys = @import("../../ui/keys.zig");
const date = @import("../../utils/date.zig");
const storage_db = @import("../../storage/db.zig");
const storage_spelling_bee = @import("../../storage/spelling_bee.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

const WordEntry = struct {
    word: []const u8,
    is_pangram: bool,
};

const StatusMessage = struct {
    text: ?[]const u8 = null,
    owned_allocator: ?std.mem.Allocator = null,

    fn clear(self: *StatusMessage) void {
        if (self.text) |_| {
            if (self.owned_allocator) |a| a.free(self.text.?);
        }
        self.text = null;
        self.owned_allocator = null;
    }

    fn set(self: *StatusMessage, s: []const u8) void {
        self.clear();
        self.text = s;
    }

    fn setOwned(self: *StatusMessage, s: []const u8, allocator: std.mem.Allocator) void {
        self.clear();
        self.text = s;
        self.owned_allocator = allocator;
    }
};

const GameState = struct {
    center: u8, // uppercase ASCII
    center_str: [1]u8 = .{0},
    outer: [6]u8, // uppercase ASCII
    outer_shuffled: [6]u8,

    input: [32]u8 = .{0} ** 32, // uppercase ASCII
    input_len: u8 = 0,

    found_words: std.ArrayListUnmanaged(WordEntry) = .{},
    found_set: std.StringHashMapUnmanaged(void) = .{},

    score: u32 = 0,
    pangrams_found: u32 = 0,
    total_words: u32 = 0,
    max_points: u32 = 0,

    list_scroll_row: u16 = 0,

    msg: StatusMessage = .{},

    fn deinit(self: *GameState, allocator: std.mem.Allocator) void {
        for (self.found_words.items) |w| allocator.free(w.word);
        self.found_words.deinit(allocator);
        self.found_set.deinit(allocator);
        self.msg.clear();
        self.* = undefined;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
    dev_mode: bool,
    direct_launch: bool,
) !Exit {
    const today = try date.todayLocalYYYYMMDD();

    var parsed = try api_client.fetchSpellingBee(allocator, today[0..]);
    defer parsed.deinit();

    var state: GameState = undefined;
    defer state.deinit(allocator);

    initStateFromApi(&state, parsed.value);
    state.total_words = @intCast(parsed.value.answers.len);
    state.max_points = computeMaxPoints(&state, parsed.value.answers);

    if (!dev_mode) {
        const progress = try storage_spelling_bee.loadOrStartProgress(
            &storage.db,
            today[0..],
            parsed.value.id,
            parsed.value.center_letter,
            parsed.value.outer_letters,
            state.total_words,
            state.max_points,
        );
        state.score = progress.points;
        state.pangrams_found = progress.pangrams_found;
        try loadFoundWords(allocator, &state, &storage.db, today[0..]);
    }

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const random = prng.random();

    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        try render(frame_allocator, vx, &state, today[0..], direct_launch);
        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .mouse, .mouse_leave => {},
            .key_press => |k| {
                if (ui_keys.isCtrlC(k)) return .quit;
                if (k.matches(vaxis.Key.escape, .{}) or k.matches('q', .{})) return if (direct_launch) .quit else .back_to_menu;

                if (k.matches(vaxis.Key.up, .{})) {
                    if (state.list_scroll_row > 0) state.list_scroll_row -= 1;
                    continue;
                }
                if (k.matches(vaxis.Key.down, .{})) {
                    if (state.list_scroll_row != std.math.maxInt(u16)) state.list_scroll_row += 1;
                    continue;
                }

                if (k.matches(vaxis.Key.backspace, .{})) {
                    state.msg.clear();
                    if (state.input_len > 0) state.input_len -= 1;
                    continue;
                }

                if (isEnterKey(k)) {
                    state.msg.clear();
                    try submitWord(allocator, &state, parsed.value, &storage.db, today[0..], dev_mode);
                    continue;
                }

                if (isSpaceKey(k)) {
                    state.msg.clear();
                    shuffleOuter(&state, random);
                    continue;
                }

                if (k.text) |t| {
                    if (t.len == 1) {
                        const c = t[0];
                        if (std.ascii.isAlphabetic(c)) {
                            const upper = std.ascii.toUpper(c);
                            if (!isAllowedLetter(&state, upper)) {
                                state.msg.set("Not in the hive");
                                continue;
                            }
                            if (state.input_len < state.input.len) {
                                state.input[state.input_len] = upper;
                                state.input_len += 1;
                            }
                        }
                    }
                }
            },
        }
    }
}

fn initStateFromApi(state: *GameState, api: @import("../../api/models.zig").SpellingBeeData) void {
    const center = std.ascii.toUpper(api.center_letter[0]);
    state.* = .{
        .center = center,
        .center_str = .{center},
        .outer = undefined,
        .outer_shuffled = undefined,
    };
    for (0..6) |i| state.outer[i] = std.ascii.toUpper(api.outer_letters[i]);
    state.outer_shuffled = state.outer;
}

fn loadFoundWords(
    allocator: std.mem.Allocator,
    state: *GameState,
    db: *sqlite.Db,
    puzzle_date: []const u8,
) !void {
    const rows = try storage_spelling_bee.getFoundWordsForDateAlloc(allocator, db, puzzle_date);
    defer {
        for (rows) |r| allocator.free(r.word.data);
        allocator.free(rows);
    }

    for (rows) |r| {
        const owned = try allocator.dupe(u8, r.word.data);
        try state.found_words.append(allocator, .{ .word = owned, .is_pangram = r.is_pangram != 0 });
        try state.found_set.put(allocator, owned, {});
    }
}

fn submitWord(
    allocator: std.mem.Allocator,
    state: *GameState,
    api: @import("../../api/models.zig").SpellingBeeData,
    db: *sqlite.Db,
    puzzle_date: []const u8,
    dev_mode: bool,
) !void {
    if (state.input_len < 4) {
        state.msg.set("Too short");
        return;
    }
    if (!wordContains(state.input[0..state.input_len], state.center)) {
        state.msg.set("Missing center letter");
        return;
    }

    var lower_buf: [32]u8 = undefined;
    for (state.input[0..state.input_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const guess = lower_buf[0..state.input_len];

    if (state.found_set.contains(guess)) {
        state.msg.set("Already found");
        return;
    }

    if (!isAnswer(api.answers, guess)) {
        state.msg.set("Not in word list");
        return;
    }

    const is_pangram = isPangram(state, guess);
    const points: u32 = scoreWord(guess, is_pangram);

    const owned = try allocator.dupe(u8, guess);
    if (!dev_mode) {
        const inserted = try storage_spelling_bee.tryAddFoundWord(db, puzzle_date, owned, points, is_pangram);
        if (!inserted) {
            allocator.free(owned);
            state.msg.set("Already found");
            return;
        }
    }

    try state.found_words.append(allocator, .{ .word = owned, .is_pangram = is_pangram });
    try state.found_set.put(allocator, owned, {});
    sortFoundWords(state.found_words.items);

    state.score += points;
    if (is_pangram) state.pangrams_found += 1;

    state.input_len = 0;
    state.msg.set(if (is_pangram) "Pangram!" else "Good");
}

fn isAnswer(answers: []const []const u8, guess: []const u8) bool {
    for (answers) |a| {
        if (std.mem.eql(u8, a, guess)) return true;
    }
    return false;
}

fn sortFoundWords(words: []WordEntry) void {
    std.sort.insertion(WordEntry, words, {}, struct {
        fn lessThan(_: void, a: WordEntry, b: WordEntry) bool {
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lessThan);
}

fn scoreWord(word: []const u8, is_pangram: bool) u32 {
    var points: u32 = if (word.len == 4) 1 else @intCast(word.len);
    if (is_pangram) points += 7;
    return points;
}

fn computeMaxPoints(state: *const GameState, answers: []const []const u8) u32 {
    var sum: u32 = 0;
    for (answers) |a| {
        const pangram = isPangram(state, a);
        sum += scoreWord(a, pangram);
    }
    return sum;
}

fn isPangram(state: *const GameState, word: []const u8) bool {
    var seen: [26]bool = .{false} ** 26;
    inline for (&[_]u8{ state.center }) |c| {
        seen[@intCast(std.ascii.toLower(c) - 'a')] = true;
    }
    for (state.outer) |c| seen[@intCast(std.ascii.toLower(c) - 'a')] = true;

    var used: [26]bool = .{false} ** 26;
    for (word) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
        const idx: usize = @intCast(c - 'a');
        if (!seen[idx]) return false;
        used[idx] = true;
    }

    for (seen, 0..) |required, i| {
        if (required and !used[i]) return false;
    }
    return true;
}

fn isAllowedLetter(state: *const GameState, upper: u8) bool {
    if (upper == state.center) return true;
    for (state.outer) |c| if (c == upper) return true;
    return false;
}

fn wordContains(word_upper: []const u8, needle_upper: u8) bool {
    for (word_upper) |c| if (c == needle_upper) return true;
    return false;
}

fn shuffleOuter(state: *GameState, random: std.Random) void {
    state.outer_shuffled = state.outer;
    random.shuffle(u8, state.outer_shuffled[0..]);
}

fn isEnterKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.enter, .{}) or k.matches('\n', .{}) or k.matches('\r', .{});
}

fn isSpaceKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.space, .{}) or k.matches(' ', .{});
}

const RankInfo = struct {
    name: []const u8,
};

const RankDef = struct {
    name: []const u8,
    percent: u8,
};

const rank_defs = [_]RankDef{
    .{ .name = "Beginner", .percent = 0 },
    .{ .name = "Good Start", .percent = 2 },
    .{ .name = "Moving Up", .percent = 5 },
    .{ .name = "Good", .percent = 8 },
    .{ .name = "Solid", .percent = 15 },
    .{ .name = "Nice", .percent = 25 },
    .{ .name = "Great", .percent = 40 },
    .{ .name = "Amazing", .percent = 50 },
    .{ .name = "Genius", .percent = 70 },
    .{ .name = "Queen Bee", .percent = 100 },
};

fn thresholdPoints(max_points: u32, percent: u8) u32 {
    if (max_points == 0 or percent == 0) return 0;
    const scaled: u64 = @as(u64, max_points) * @as(u64, percent);
    return @intCast((scaled + 99) / 100);
}

fn currentRank(score: u32, max_points: u32) RankInfo {
    var idx: usize = 0;
    for (rank_defs, 0..) |r, i| {
        if (score >= thresholdPoints(max_points, r.percent)) idx = i;
    }
    return .{ .name = rank_defs[idx].name };
}

fn renderRankBar(
    frame_allocator: std.mem.Allocator,
    win: vaxis.Window,
    x: u16,
    y: u16,
    w: u16,
    score: u32,
    max_points: u32,
) !void {
    if (y >= win.height) return;
    if (w < 14) return;

    const bar_w_u16: u16 = @min(@as(u16, 22), w - 6);
    const bar_w: usize = @intCast(bar_w_u16);
    if (bar_w < 10) return;

    const filled_calc: usize = if (max_points == 0) 0 else @intCast((@as(u64, score) * @as(u64, bar_w)) / @as(u64, max_points));
    const filled: usize = @min(bar_w, filled_calc);
    const buf = try frame_allocator.alloc(u8, bar_w + 2);
    buf[0] = '[';
    for (0..bar_w) |i| buf[i + 1] = if (i < filled) '=' else '.';
    buf[bar_w + 1] = ']';

    _ = win.print(
        &.{.{ .text = buf, .style = .{ .fg = colors.spelling_bee.center } }},
        .{ .row_offset = y, .col_offset = x, .wrap = .none },
    );

    const pct: u32 = if (max_points == 0) 0 else @intCast(@min(@as(u64, 100), @as(u64, score) * 100 / max_points));
    const pct_text = try std.fmt.allocPrint(frame_allocator, " {d}%", .{pct});
    _ = win.print(
        &.{.{ .text = pct_text, .style = .{ .fg = colors.ui.text_dim } }},
        .{ .row_offset = y, .col_offset = x + @as(u16, @intCast(bar_w + 2)), .wrap = .none },
    );
}

fn render(frame_allocator: std.mem.Allocator, vx: *vaxis.Vaxis, state: *GameState, puzzle_date: []const u8, direct_launch: bool) !void {
    const win = vx.window();
    win.clear();
    win.hideCursor();

    const title = "Spelling Bee";
    const subtitle = if (direct_launch)
        "q/Esc: quit   Space: shuffle   Enter: submit   ↑/↓: scroll words   Ctrl+C"
    else
        "q/Esc: back   Space: shuffle   Enter: submit   ↑/↓: scroll words   Ctrl+C";

    printCentered(win, 0, title, .{ .bold = true });
    printCentered(win, 1, puzzle_date, .{ .fg = colors.ui.text_dim });
    printCentered(win, 2, subtitle, .{ .fg = colors.ui.text_dim });

    const list_w: u16 = if (win.width >= 80) 36 else if (win.width >= 60) 28 else 0;
    const gap: u16 = if (list_w > 0) 2 else 0;
    const list_x: u16 = 2;
    const right_x: u16 = list_x + list_w + gap;

    const body_y: u16 = 4;
    if (list_w > 0) {
        try renderWordList(frame_allocator, win, state, list_x, body_y, list_w);
    }
    try renderRight(frame_allocator, win, state, right_x, body_y, win.width - right_x - 2);
}

fn renderRight(frame_allocator: std.mem.Allocator, win: vaxis.Window, state: *GameState, x: u16, y: u16, w: u16) !void {
    if (w < 20) return;

    const rank = currentRank(state.score, state.max_points);
    const score_text = try std.fmt.allocPrint(frame_allocator, "Score {d}", .{state.score});
    _ = win.print(&.{.{ .text = score_text, .style = .{ .bold = true } }}, .{ .row_offset = y, .col_offset = x, .wrap = .none });

    const rank_text = try std.fmt.allocPrint(frame_allocator, "Rank {s}", .{rank.name});
    _ = win.print(&.{.{ .text = rank_text, .style = .{ .fg = colors.ui.text_dim } }}, .{ .row_offset = y + 1, .col_offset = x, .wrap = .none });

    try renderRankBar(frame_allocator, win, x, y + 2, w, state.score, state.max_points);

    const input_y = y + 4;
    _ = win.print(&.{.{ .text = "Word", .style = .{ .fg = colors.ui.text_dim } }}, .{ .row_offset = input_y, .col_offset = x, .wrap = .none });
    _ = win.print(
        &.{.{ .text = state.input[0..state.input_len], .style = .{ .bold = true } }},
        .{ .row_offset = input_y + 1, .col_offset = x, .wrap = .none },
    );

    if (state.msg.text) |t| {
        _ = win.print(&.{.{ .text = t, .style = .{ .fg = colors.ui.text_dim } }}, .{ .row_offset = input_y + 3, .col_offset = x, .wrap = .none });
    }

    const honey_y = input_y + 5;
    renderHoneycomb(win, state, x, honey_y, w);
}

fn renderWordList(frame_allocator: std.mem.Allocator, win: vaxis.Window, state: *GameState, x: u16, y: u16, w: u16) !void {
    if (w < 10) return;

    const header = try std.fmt.allocPrint(frame_allocator, "Words Found ({d})", .{state.found_words.items.len});
    _ = win.print(&.{.{ .text = header, .style = .{ .bold = true } }}, .{ .row_offset = y, .col_offset = x, .wrap = .none });

    const list_y = y + 2;
    if (list_y >= win.height) return;
    const list_h: u16 = win.height - list_y - 1;
    if (list_h == 0) return;

    var max_len: u16 = 4;
    for (state.found_words.items) |entry| {
        max_len = @max(max_len, @as(u16, @intCast(entry.word.len)));
    }
    const col_gap: u16 = 2;
    const col_w: u16 = @min(max_len, w);
    const max_cols: u16 = @max(1, (w + col_gap) / (col_w + col_gap));
    const cols: u16 = @min(@as(u16, 3), max_cols);
    const total: u32 = @intCast(state.found_words.items.len);
    const rows_per_col: u16 = if (cols == 0) 0 else @intCast((total + cols - 1) / cols);
    if (rows_per_col == 0) return;

    const scroll_max: u16 = if (rows_per_col > list_h) rows_per_col - list_h else 0;
    if (state.list_scroll_row > scroll_max) state.list_scroll_row = scroll_max;

    for (0..cols) |c| {
        const col_x = x + @as(u16, @intCast(c)) * (col_w + col_gap);
        if (col_x >= x + w) break;
        for (0..list_h) |r| {
            const row_index = state.list_scroll_row + @as(u16, @intCast(r));
            if (row_index >= rows_per_col) break;
            const idx: usize = @intCast(@as(u32, @intCast(c)) * rows_per_col + row_index);
            if (idx >= state.found_words.items.len) break;

            const entry = state.found_words.items[idx];
            const style: vaxis.Style = if (entry.is_pangram)
                .{ .fg = colors.spelling_bee.pangram, .bold = true }
            else
                .{};
            _ = win.print(
                &.{.{ .text = entry.word, .style = style }},
                .{ .row_offset = list_y + @as(u16, @intCast(r)), .col_offset = col_x, .wrap = .none },
            );
        }
    }
}

fn renderHoneycomb(win: vaxis.Window, state: *GameState, x: u16, y: u16, w: u16) void {
    const cell_w: u16 = 7;
    const cell_h: u16 = 3;
    const gap_x: u16 = 2;
    const gap_y: u16 = 1;

    const honey_w: u16 = 3 * cell_w + 2 * gap_x;
    if (w < honey_w) return;
    const base_x: u16 = x + @as(u16, @intCast((w - honey_w) / 2));

    const indent: u16 = @intCast((cell_w + gap_x) / 2);
    const row0_y = y;
    const row1_y = y + cell_h + gap_y;
    const row2_y = y + 2 * (cell_h + gap_y);

    drawCell(win, base_x + indent + 0 * (cell_w + gap_x), row0_y, cell_w, state.outer_shuffled[0..1], colors.spelling_bee.outer);
    drawCell(win, base_x + indent + 1 * (cell_w + gap_x), row0_y, cell_w, state.outer_shuffled[1..2], colors.spelling_bee.outer);

    drawCell(win, base_x + 0 * (cell_w + gap_x), row1_y, cell_w, state.outer_shuffled[2..3], colors.spelling_bee.outer);
    drawCell(win, base_x + 1 * (cell_w + gap_x), row1_y, cell_w, state.center_str[0..], colors.spelling_bee.center);
    drawCell(win, base_x + 2 * (cell_w + gap_x), row1_y, cell_w, state.outer_shuffled[3..4], colors.spelling_bee.outer);

    drawCell(win, base_x + indent + 0 * (cell_w + gap_x), row2_y, cell_w, state.outer_shuffled[4..5], colors.spelling_bee.outer);
    drawCell(win, base_x + indent + 1 * (cell_w + gap_x), row2_y, cell_w, state.outer_shuffled[5..6], colors.spelling_bee.outer);
}

fn drawCell(win: vaxis.Window, x: u16, y: u16, w: u16, letter: []const u8, bg: vaxis.Color) void {
    const fg_dark = vaxis.Color{ .rgb = .{ 0, 0, 0 } };
    const fill_style: vaxis.Style = .{ .bg = bg, .fg = fg_dark };

    const blank7 = "       ";
    const ww: usize = @min(@as(usize, @intCast(w)), blank7.len);
    const blank = blank7[0..ww];

    if (y < win.height) _ = win.print(&.{.{ .text = blank, .style = fill_style }}, .{ .row_offset = y, .col_offset = x, .wrap = .none });
    if (y + 1 < win.height) _ = win.print(&.{.{ .text = blank, .style = fill_style }}, .{ .row_offset = y + 1, .col_offset = x, .wrap = .none });
    if (y + 1 < win.height and w >= 1) {
        const letter_x = x + @as(u16, @intCast(w / 2));
        _ = win.print(&.{.{ .text = letter, .style = .{ .bg = bg, .fg = fg_dark, .bold = true } }}, .{ .row_offset = y + 1, .col_offset = letter_x, .wrap = .none });
    }
    if (y + 2 < win.height) _ = win.print(&.{.{ .text = blank, .style = fill_style }}, .{ .row_offset = y + 2, .col_offset = x, .wrap = .none });
}

fn printCentered(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height) return;
    const w = win.gwidth(text);
    const col: u16 = if (win.width > w) @as(u16, @intCast((win.width - w) / 2)) else 0;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

test "scoreWord" {
    try std.testing.expectEqual(@as(u32, 1), scoreWord("able", false));
    try std.testing.expectEqual(@as(u32, 5), scoreWord("about", false));
    try std.testing.expectEqual(@as(u32, 15), scoreWord("guffawing", true));
}

test "currentRank thresholds" {
    try std.testing.expectEqualStrings("Beginner", currentRank(0, 100).name);
    try std.testing.expectEqualStrings("Good Start", currentRank(2, 100).name);
    try std.testing.expectEqualStrings("Moving Up", currentRank(5, 100).name);
    try std.testing.expectEqualStrings("Genius", currentRank(99, 100).name);
    try std.testing.expectEqualStrings("Queen Bee", currentRank(100, 100).name);
}

test "pangram detection" {
    var state: GameState = .{
        .center = 'I',
        .center_str = .{ 'I' },
        .outer = .{ 'A', 'F', 'G', 'N', 'U', 'W' },
        .outer_shuffled = .{ 'A', 'F', 'G', 'N', 'U', 'W' },
    };
    try std.testing.expect(isPangram(&state, "guffawing"));
    try std.testing.expect(!isPangram(&state, "gunning"));
    try std.testing.expect(!isPangram(&state, "guffawingz"));
}

test {
    std.testing.refAllDecls(@This());
}
