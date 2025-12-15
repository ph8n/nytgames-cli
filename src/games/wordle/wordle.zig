const std = @import("std");
const vaxis = @import("vaxis");

const api_client = @import("../../api/client.zig");
const colors = @import("../../ui/colors.zig");
const app_event = @import("../../ui/event.zig");
const date = @import("../../utils/date.zig");
const storage_db = @import("../../storage/db.zig");
const storage_stats = @import("../../storage/stats.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

pub const Mode = enum {
    daily,
    unlimited,
};

const Status = enum(u2) {
    unknown,
    absent,
    present,
    correct,
};

const Tile = struct {
    letter: u8 = 0, // uppercase ASCII letter
    status: Status = .unknown,
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
    mode: Mode,
    direct_launch: bool,
) !Exit {
    var allowed = try AllowedWords.init(allocator);
    defer allowed.deinit(allocator);

    var state: GameState = .{};

    var status_msg: StatusMessage = .{};
    defer status_msg.clear();

    const today = try date.todayLocalYYYYMMDD();
    var puzzle_id: i32 = 0;

    if (mode == .daily) {
        const already_played = try storage_stats.hasPlayedWordle(&storage.db, today[0..]);
        if (already_played) {
            return runAlreadyPlayedScreen(allocator, tty, vx, loop, today[0..], direct_launch);
        }

        var parsed = try api_client.fetchWordle(allocator, today[0..]);
        defer parsed.deinit();

        state.solution = try normalizeSolution(parsed.value.solution);
        puzzle_id = parsed.value.id;
    } else {
        state.solution = try pickRandomSolution();
    }

    while (true) {
        try render(vx, &state, &status_msg, direct_launch, mode);
        try vx.render(tty.writer());

        const ev = loop.nextEvent();
        switch (ev) {
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
            .key_press => |k| {
                if (k.matches(vaxis.Key.escape, .{}) or k.matchShortcut('c', .{ .ctrl = true })) {
                    return if (direct_launch) .quit else .back_to_menu;
                }

                if (state.phase == .finished) {
                    if (k.matches(vaxis.Key.enter, .{}) or k.matches(' ', .{})) {
                        if (mode == .unlimited) {
                            status_msg.clear();
                            state = .{};
                            state.solution = try pickRandomSolution();
                            continue;
                        }
                        return if (direct_launch) .quit else .back_to_menu;
                    }
                    continue;
                }

                if (k.matches(vaxis.Key.backspace, .{})) {
                    status_msg.clear();
                    backspace(&state);
                    continue;
                }

                if (k.matches(vaxis.Key.enter, .{})) {
                    status_msg.clear();
                    if (state.col != 5) {
                        status_msg.set("Not enough letters");
                        continue;
                    }
                    var guess_lower: [5]u8 = undefined;
                    for (0..5) |i| guess_lower[i] = std.ascii.toLower(state.grid[state.row][i].letter);

                    if (isDuplicateGuess(&state, guess_lower[0..])) {
                        status_msg.set("Already guessed");
                        continue;
                    }

                    if (!allowed.contains(guess_lower[0..])) {
                        status_msg.set("Not in word list");
                        continue;
                    }

                    const evaluation = evaluateGuess(guess_lower[0..], state.solution[0..]);
                    applyEvaluation(&state, guess_lower[0..], evaluation);

                    if (std.mem.eql(u8, guess_lower[0..], state.solution[0..])) {
                        state.phase = .finished;
                        state.won = true;
                    } else if (state.row == 5) {
                        state.phase = .finished;
                        state.won = false;
                        status_msg.setOwned(try std.fmt.allocPrint(
                            allocator,
                            "Answer: {s}",
                            .{state.solution[0..]},
                        ), allocator);
                    } else {
                        state.row += 1;
                        state.col = 0;
                    }

                    if (state.phase == .finished) {
                        if (mode == .daily) {
                            try storage_stats.saveWordleResult(&storage.db, .{
                                .puzzle_date = today[0..],
                                .puzzle_id = puzzle_id,
                                .won = state.won,
                                .guesses = if (state.won) @intCast(state.row + 1) else 0,
                                .played_at = std.time.timestamp(),
                            });
                        }
                    }
                    continue;
                }

                // Letter input
                if (k.text) |t| {
                    if (t.len == 1) {
                        const c = t[0];
                        if (std.ascii.isAlphabetic(c)) {
                            status_msg.clear();
                            pushLetter(&state, std.ascii.toUpper(c));
                        }
                    }
                }
            },
        }
    }
}

const StatusMessage = struct {
    text: ?[]const u8 = null,
    owned_allocator: ?std.mem.Allocator = null,

    fn clear(self: *StatusMessage) void {
        if (self.text) |_| {
            if (self.owned_allocator) |a| {
                a.free(self.text.?);
            }
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
    grid: [6][5]Tile = ([_][5]Tile{
        .{ .{}, .{}, .{}, .{}, .{} },
    } ** 6),
    row: u8 = 0,
    col: u8 = 0,
    won: bool = false,
    solution: [5]u8 = undefined, // lowercase
    phase: enum { playing, finished } = .playing,
    keyboard: [26]Status = .{.unknown} ** 26,
};

fn normalizeSolution(s: []const u8) ![5]u8 {
    if (s.len != 5) return error.InvalidSolution;
    var out: [5]u8 = undefined;
    for (s, 0..) |c, i| {
        if (!std.ascii.isAlphabetic(c)) return error.InvalidSolution;
        out[i] = std.ascii.toLower(c);
    }
    return out;
}

fn pickRandomSolution() ![5]u8 {
    var prng = std.Random.DefaultPrng.init(seedFromTime());
    const random = prng.random();

    const data = @embedFile("../../data/solutions.txt");
    var it = std.mem.splitScalar(u8, data, '\n');

    var chosen: ?[5]u8 = null;
    var seen: u32 = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len != 5) continue;

        var sol: [5]u8 = undefined;
        var ok = true;
        for (line, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c)) {
                ok = false;
                break;
            }
            sol[i] = std.ascii.toLower(c);
        }
        if (!ok) continue;

        seen += 1;
        if (seen == 1) {
            chosen = sol;
            continue;
        }
        if (random.uintLessThan(u32, seen) == 0) {
            chosen = sol;
        }
    }
    return chosen orelse error.NoSolutions;
}

fn seedFromTime() u64 {
    const ns: i128 = std.time.nanoTimestamp();
    return @truncate(@as(u128, @bitCast(ns)));
}

fn pushLetter(state: *GameState, upper: u8) void {
    if (state.col >= 5) return;
    state.grid[state.row][state.col].letter = upper;
    state.grid[state.row][state.col].status = .unknown;
    state.col += 1;
}

fn backspace(state: *GameState) void {
    if (state.col == 0) return;
    state.col -= 1;
    state.grid[state.row][state.col] = .{};
}

fn isDuplicateGuess(state: *const GameState, guess_lower: []const u8) bool {
    var r: u8 = 0;
    while (r < state.row) : (r += 1) {
        var same = true;
        for (0..5) |i| {
            const upper = state.grid[r][i].letter;
            if (upper == 0 or std.ascii.toLower(upper) != guess_lower[i]) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

fn statusRank(s: Status) u2 {
    return @intFromEnum(s);
}

fn upgradeKey(prev: Status, next: Status) Status {
    return if (statusRank(next) > statusRank(prev)) next else prev;
}

fn applyEvaluation(state: *GameState, guess_lower: []const u8, evaluation: [5]Status) void {
    for (0..5) |i| {
        state.grid[state.row][i].status = evaluation[i];
        const idx: usize = @intCast(guess_lower[i] - 'a');
        state.keyboard[idx] = upgradeKey(state.keyboard[idx], evaluation[i]);
    }
}

fn evaluateGuess(guess: []const u8, solution: []const u8) [5]Status {
    var res: [5]Status = .{ .absent, .absent, .absent, .absent, .absent };
    var counts: [26]u8 = .{0} ** 26;

    for (solution) |c| counts[@intCast(c - 'a')] += 1;

    for (0..5) |i| {
        if (guess[i] == solution[i]) {
            res[i] = .correct;
            counts[@intCast(guess[i] - 'a')] -= 1;
        }
    }

    for (0..5) |i| {
        if (res[i] == .correct) continue;
        const idx: usize = @intCast(guess[i] - 'a');
        if (counts[idx] > 0) {
            res[i] = .present;
            counts[idx] -= 1;
        } else {
            res[i] = .absent;
        }
    }
    return res;
}

const AllowedWords = struct {
    set: std.StringHashMapUnmanaged(void) = .{},

    fn init(allocator: std.mem.Allocator) !AllowedWords {
        var self: AllowedWords = .{};
        try self.loadEmbedded(allocator);
        return self;
    }

    fn deinit(self: *AllowedWords, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
        self.* = undefined;
    }

    fn contains(self: *const AllowedWords, lower: []const u8) bool {
        return self.set.contains(lower);
    }

    fn loadEmbedded(self: *AllowedWords, allocator: std.mem.Allocator) !void {
        try loadList(self, allocator, @embedFile("../../data/valid_guesses.txt"));
        try loadList(self, allocator, @embedFile("../../data/solutions.txt"));
    }

    fn loadList(self: *AllowedWords, allocator: std.mem.Allocator, data: []const u8) !void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimRight(u8, raw, "\r");
            if (line.len == 0) continue;
            if (line.len != 5) continue;
            try self.set.put(allocator, line, {});
        }
    }
};

fn render(vx: *vaxis.Vaxis, state: *GameState, msg: *StatusMessage, direct_launch: bool, mode: Mode) !void {
    const win = vx.window();
    win.clear();
    win.hideCursor();

    const title = switch (mode) {
        .daily => if (direct_launch) "Wordle  (Esc to quit)" else "Wordle  (Esc to menu)",
        .unlimited => if (direct_launch) "Wordle Unlimited  (Esc to quit)" else "Wordle Unlimited  (Esc to menu)",
    };

    const tile_w: u16 = 5;
    const tile_h: u16 = 3;
    const gap_x: u16 = 1;
    const gap_y: u16 = 1;
    const grid_w: u16 = 5 * tile_w + 4 * gap_x;
    const grid_h: u16 = 6 * tile_h + 5 * gap_y;

    const kb_key_w: u16 = 3;
    const kb_gap: u16 = 1;
    const kb_row1_w: u16 = 10 * kb_key_w + 9 * kb_gap;
    const kb_h: u16 = 9;

    const layout_w: u16 = if (grid_w > kb_row1_w) grid_w else kb_row1_w;
    const layout_x: u16 = if (win.width > layout_w) @intCast((win.width - layout_w) / 2) else 0;

    const header_h: u16 = 2; // title + notification line
    const header_gap: u16 = 1;
    const grid_to_keyboard_gap: u16 = 1;
    const block_h: u16 = header_h + header_gap + grid_h + grid_to_keyboard_gap + kb_h;
    const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;

    const start_x: u16 = layout_x + if (layout_w > grid_w) @as(u16, @intCast((layout_w - grid_w) / 2)) else 0;
    const start_y: u16 = block_y + header_h + header_gap;

    printCentered(win, block_y + 0, layout_x, layout_w, title, .{});

    for (0..6) |row| {
        for (0..5) |col| {
            const tile = state.grid[row][col];
            const is_current_row = state.phase == .playing and row == state.row;
            const is_current_col = is_current_row and col == state.col;

            const x: u16 = start_x + @as(u16, @intCast(col)) * (tile_w + gap_x);
            const y: u16 = start_y + @as(u16, @intCast(row)) * (tile_h + gap_y);

            renderTile(win, x, y, tile_w, tile_h, tile, is_current_col);
        }
    }

    const kb_y = start_y + grid_h + 1;
    renderKeyboard(win, layout_x, layout_w, kb_y, &state.keyboard);

    const notice_y: u16 = block_y + 1;
    if (msg.text) |t| {
        printCentered(win, notice_y, layout_x, layout_w, t, .{ .fg = colors.ui.warning });
    } else if (state.phase == .finished) {
        const end_msg = if (mode == .unlimited)
            (if (state.won) "You won!  (Enter for next)" else "Game over  (Enter for next)")
        else
            (if (state.won) "You won!  (Enter to continue)" else "Game over  (Enter to continue)");
        printCentered(win, notice_y, layout_x, layout_w, end_msg, .{ .fg = colors.ui.text });
    }
}

fn printCentered(win: vaxis.Window, y: u16, x: u16, w: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height) return;
    const text_w = win.gwidth(text);
    const col: u16 = x + if (w > text_w) @as(u16, @intCast((w - text_w) / 2)) else 0;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = y, .col_offset = col, .wrap = .none });
}

fn renderTile(parent: vaxis.Window, x: u16, y: u16, w: u16, h: u16, tile: Tile, highlight: bool) void {
    const bg = switch (tile.status) {
        .correct => colors.wordle.correct,
        .present => colors.wordle.present,
        .absent => colors.wordle.absent,
        .unknown => vaxis.Color.default,
    };

    const border_fg = if (tile.status == .unknown) colors.wordle.empty_border else bg;
    const border_bg = if (tile.status == .unknown) vaxis.Color.default else bg;

    const border_style: vaxis.Style = .{
        .fg = if (highlight) colors.ui.highlight else border_fg,
        .bg = border_bg,
        .bold = highlight,
    };

    const win = parent.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .style = border_style, .glyphs = .single_square },
    });

    win.fill(.{ .style = .{ .bg = bg } });

    if (tile.letter != 0) {
        const letter_style: vaxis.Style = .{
            .fg = .{ .rgb = .{ 255, 255, 255 } },
            .bg = bg,
            .bold = true,
        };
        win.writeCell(@intCast((win.width - 1) / 2), @intCast((win.height - 1) / 2), .{
            .char = .{ .grapheme = glyphUpper(tile.letter), .width = 1 },
            .style = letter_style,
        });
    }
}

fn renderKeyboard(parent: vaxis.Window, layout_x: u16, layout_w: u16, y: u16, keys: *const [26]Status) void {
    const row1 = "QWERTYUIOP";
    const row2 = "ASDFGHJKL";
    const row3 = "ZXCVBNM";

    renderKeyboardRow(parent, layout_x, layout_w, y, row1, keys);
    renderKeyboardRow(parent, layout_x, layout_w, y + 3, row2, keys);
    renderKeyboardRow(parent, layout_x, layout_w, y + 6, row3, keys);
}

fn renderKeyboardRow(parent: vaxis.Window, layout_x: u16, layout_w: u16, y: u16, letters: []const u8, keys: *const [26]Status) void {
    const key_w: u16 = 3;
    const key_h: u16 = 3;
    const gap: u16 = 1;
    const row_w: u16 = @as(u16, @intCast(letters.len)) * key_w + @as(u16, @intCast(letters.len - 1)) * gap;

    const offset: u16 = layout_x + if (layout_w > row_w) @as(u16, @intCast((layout_w - row_w) / 2)) else 0;

    var x: u16 = offset;
    for (letters) |c| {
        renderKey(parent, x, y, key_w, key_h, c, keys);
        x += key_w + gap;
    }
}

fn renderKey(parent: vaxis.Window, x: u16, y: u16, w: u16, h: u16, letter: u8, keys: *const [26]Status) void {
    const lower = std.ascii.toLower(letter);
    const idx: usize = @intCast(lower - 'a');
    const status = keys[idx];

    const bg = switch (status) {
        .correct => colors.wordle.correct,
        .present => colors.wordle.present,
        .absent => colors.wordle.absent,
        .unknown => vaxis.Color.default,
    };

    const border_style: vaxis.Style = .{
        .fg = if (status == .unknown) colors.wordle.empty_border else bg,
        .bg = if (status == .unknown) vaxis.Color.default else bg,
    };

    const win = parent.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .style = border_style, .glyphs = .single_square },
    });
    win.fill(.{ .style = .{ .bg = bg } });

    const style: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = bg, .bold = true };
    win.writeCell(0, 0, .{
        .char = .{ .grapheme = glyphUpper(letter), .width = 1 },
        .style = style,
    });
}

fn glyphUpper(letter: u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    if (letter < 'A' or letter > 'Z') return " ";
    const i: usize = @intCast(letter - 'A');
    return alphabet[i .. i + 1];
}

fn runAlreadyPlayedScreen(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    puzzle_date: []const u8,
    direct_launch: bool,
) !Exit {
    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();
        _ = win.print(&.{.{ .text = "Wordle" }}, .{ .row_offset = 0, .col_offset = 2, .wrap = .none });
        _ = win.print(&.{.{ .text = "Already played today!" }}, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });
        _ = win.print(&.{.{ .text = puzzle_date }}, .{ .row_offset = 3, .col_offset = 2, .wrap = .none });
        _ = win.print(&.{.{ .text = "Press Esc to go back" }}, .{ .row_offset = 5, .col_offset = 2, .wrap = .none });

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (k.matches(vaxis.Key.escape, .{}) or k.matches(vaxis.Key.enter, .{}) or k.matches(' ', .{})) {
                    return if (direct_launch) .quit else .back_to_menu;
                }
            },
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
