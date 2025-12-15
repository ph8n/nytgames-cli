const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");

const api_client = @import("../../api/client.zig");
const colors = @import("../../ui/colors.zig");
const already_played = @import("../../ui/already_played.zig");
const app_event = @import("../../ui/event.zig");
const ui_keys = @import("../../ui/keys.zig");
const date = @import("../../utils/date.zig");
const storage_db = @import("../../storage/db.zig");
const storage_stats = @import("../../storage/stats.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

const Difficulty = enum(u2) {
    yellow,
    green,
    blue,
    purple,
};

fn difficultyColor(d: Difficulty) vaxis.Color {
    return switch (d) {
        .yellow => colors.connections.yellow,
        .green => colors.connections.green,
        .blue => colors.connections.blue,
        .purple => colors.connections.purple,
    };
}

const CardId = u8; // 0..15

const Card = struct {
    text: []const u8,
};

const Category = struct {
    title: []const u8,
    difficulty: Difficulty,
    ids: [4]CardId,
    key: u32,
};

const SolvedGroup = struct {
    title: []const u8,
    difficulty: Difficulty,
    ids: [4]CardId,
};

const HoverTarget = union(enum) {
    none,
    tile: usize,
    button: Button,
};

const Button = enum {
    shuffle,
    deselect,
    submit,
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
    cards: [16]Card = undefined,
    categories: [4]Category = undefined,

    board: [16]CardId = undefined,
    board_len: u8 = 0,

    selected: [16]bool = .{false} ** 16,
    selected_count: u8 = 0,

    focus_index: usize = 0, // index into board[0..board_len]
    hover: HoverTarget = .none,

    mistakes: u8 = 0,
    max_mistakes: u8 = 4,

    solved: [4]SolvedGroup = undefined,
    solved_count: u8 = 0,

    guessed: std.AutoHashMapUnmanaged(u32, void) = .{},

    prompt_msg: StatusMessage = .{},
    last_msg: StatusMessage = .{},

    phase: enum { playing, finished } = .playing,
    won: bool = false,

    fn deinit(self: *GameState, allocator: std.mem.Allocator) void {
        self.guessed.deinit(allocator);
        self.prompt_msg.clear();
        self.last_msg.clear();
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
    var state: GameState = .{};
    defer state.deinit(allocator);

    const today_date = try date.todayLocal();
    var today_buf: date.YyyyMmDd = undefined;
    date.formatYYYYMMDD(&today_buf, today_date);
    const today = today_buf[0..];

    const played_status: storage_stats.PlayedStatus = if (dev_mode) .not_played else try storage_stats.getConnectionsPlayedStatus(&storage.db, today);
    if (!dev_mode and played_status != .not_played) {
        const mark: ?already_played.Mark = switch (played_status) {
            .not_played => null,
            .won => .won,
            .lost => .lost,
        };
        return switch (try already_played.run(allocator, tty, vx, loop, .{
            .title = "Connections",
            .puzzle_date = today,
            .direct_launch = direct_launch,
            .mark = mark,
        })) {
            .quit => .quit,
            .back_to_menu => .back_to_menu,
        };
    }

    var parsed = try api_client.fetchConnections(allocator, today);
    defer parsed.deinit();

    const puzzle_id = parsed.value.id;
    try initFromApi(allocator, &state, parsed.value);
    initBoard(&state);
    shuffleBoard(&state);

    while (true) {
        try render(vx, &state, direct_launch);
        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .mouse_leave => {
                state.hover = .none;
                vx.setMouseShape(.default);
            },
            .mouse => |m| {
                handleMouse(allocator, vx, &state, m, puzzle_id, today, &storage.db) catch |err| switch (err) {
                    error.Quit => return .quit,
                    error.BackToMenu => return .back_to_menu,
                    else => return err,
                };
            },
            .key_press => |k| {
                handleKey(allocator, vx, &state, k, puzzle_id, today, &storage.db) catch |err| switch (err) {
                    error.Quit => return .quit,
                    error.BackToMenu => return .back_to_menu,
                    else => return err,
                };
            },
        }
    }
}

const InputExit = error{ Quit, BackToMenu };

fn handleKey(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    state: *GameState,
    k: vaxis.Key,
    puzzle_id: i32,
    today: []const u8,
    db: *sqlite.Db,
) !void {
    if (ui_keys.isCtrlC(k)) return InputExit.Quit;
    if (k.matches(vaxis.Key.escape, .{}) or k.matches('q', .{})) return InputExit.BackToMenu;

    if (state.phase == .finished) {
        if (isEnterKey(k) or k.matches(' ', .{})) return InputExit.BackToMenu;
        return;
    }

    if (k.matches('s', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        vx.setMouseShape(.default);
        shuffleBoard(state);
        clampFocus(state);
        return;
    }
    if (k.matches('d', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        vx.setMouseShape(.default);
        deselectAll(state);
        return;
    }

    if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        moveFocus(state, .left);
        vx.setMouseShape(.default);
        return;
    }
    if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        moveFocus(state, .right);
        vx.setMouseShape(.default);
        return;
    }
    if (k.matches(vaxis.Key.up, .{}) or k.matches('k', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        moveFocus(state, .up);
        vx.setMouseShape(.default);
        return;
    }
    if (k.matches(vaxis.Key.down, .{}) or k.matches('j', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        moveFocus(state, .down);
        vx.setMouseShape(.default);
        return;
    }

    if (k.matches(' ', .{})) {
        state.prompt_msg.clear();
        state.hover = .none;
        vx.setMouseShape(.default);
        if (state.board_len == 0) return;
        toggleSelection(state, state.focus_index);
        return;
    }

    if (isEnterKey(k)) {
        state.hover = .none;
        vx.setMouseShape(.default);
        try submit(allocator, state, puzzle_id, today, db);
        return;
    }
}

fn handleMouse(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    state: *GameState,
    m: vaxis.Mouse,
    puzzle_id: i32,
    today: []const u8,
    db: *sqlite.Db,
) !void {
    if (state.phase == .finished) {
        if (m.type == .press and m.button == .left) return InputExit.BackToMenu;
        return;
    }

    const target = hitTest(vx.window(), state, m.col, m.row);
    state.hover = target;
    vx.setMouseShape(if (target != .none) .pointer else .default);
    switch (target) {
        .tile => |i| state.focus_index = i,
        else => {},
    }

    if (m.type == .press and m.button == .left) {
        state.prompt_msg.clear();
        switch (target) {
            .none => {},
            .tile => |i| {
                toggleSelection(state, i);
            },
            .button => |b| switch (b) {
                .shuffle => {
                    shuffleBoard(state);
                    clampFocus(state);
                },
                .deselect => deselectAll(state),
                .submit => try submit(allocator, state, puzzle_id, today, db),
            },
        }
    }
}

fn submit(allocator: std.mem.Allocator, state: *GameState, puzzle_id: i32, today: []const u8, db: *sqlite.Db) !void {
    if (state.selected_count < 4) {
        state.prompt_msg.set("Select 4");
        return;
    }

    var ids: [4]CardId = undefined;
    var n: usize = 0;
    for (0..16) |i| {
        if (!state.selected[i]) continue;
        ids[n] = @intCast(i);
        n += 1;
        if (n == 4) break;
    }
    std.sort.insertion(CardId, ids[0..], {}, struct {
        fn lessThan(_: void, a: CardId, b: CardId) bool {
            return a < b;
        }
    }.lessThan);

    const guess_key = packIds(ids);
    const gop = try state.guessed.getOrPut(allocator, guess_key);
    if (gop.found_existing) {
        state.last_msg.set("Already guessed");
        return;
    }

    // Check for exact match
    for (state.categories) |cat| {
        if (isCategorySolved(state, cat)) continue;
        if (cat.key == guess_key) {
            try solveCategory(state, cat);
            state.last_msg.clear();
            if (state.solved_count == 4) {
                state.phase = .finished;
                state.won = true;
                try storage_stats.saveConnectionsResult(db, .{
                    .puzzle_date = today,
                    .puzzle_id = puzzle_id,
                    .won = true,
                    .mistakes = state.mistakes,
                    .played_at = std.time.timestamp(),
                });
            }
            return;
        }
    }

    // Not correct
    state.mistakes += 1;
    if (isOneAway(state, guess_key)) {
        state.last_msg.set("One away…");
    } else {
        state.last_msg.set("Not quite");
    }

    if (state.mistakes >= state.max_mistakes) {
        state.phase = .finished;
        state.won = false;
        state.prompt_msg.clear();
        state.prompt_msg.setOwned(
            try std.fmt.allocPrint(allocator, "Out of mistakes  ({d}/{d} solved)", .{ state.solved_count, 4 }),
            allocator,
        );
        try storage_stats.saveConnectionsResult(db, .{
            .puzzle_date = today,
            .puzzle_id = puzzle_id,
            .won = false,
            .mistakes = state.mistakes,
            .played_at = std.time.timestamp(),
        });
    }
}

fn solveCategory(state: *GameState, cat: Category) !void {
    // Record solved group
    const idx: usize = @intCast(state.solved_count);
    state.solved[idx] = .{ .title = cat.title, .difficulty = cat.difficulty, .ids = cat.ids };
    state.solved_count += 1;

    // Remove from board
    var next: [16]CardId = undefined;
    var out_len: u8 = 0;
    outer: for (state.board[0..state.board_len]) |id| {
        for (cat.ids) |cid| {
            if (id == cid) continue :outer;
        }
        next[out_len] = id;
        out_len += 1;
    }
    state.board = next;
    state.board_len = out_len;

    // Clear selection
    deselectAll(state);
    clampFocus(state);
}

fn isCategorySolved(state: *const GameState, cat: Category) bool {
    for (state.solved[0..state.solved_count]) |g| {
        if (g.difficulty == cat.difficulty and std.mem.eql(u8, g.title, cat.title)) return true;
    }
    return false;
}

fn isOneAway(state: *const GameState, packed_guess: u32) bool {
    var guess_ids: [4]CardId = undefined;
    unpackIds(packed_guess, &guess_ids);
    for (state.categories) |cat| {
        if (isCategorySolved(state, cat)) continue;
        var matches: u8 = 0;
        for (guess_ids) |gid| {
            for (cat.ids) |cid| {
                if (gid == cid) {
                    matches += 1;
                    break;
                }
            }
        }
        if (matches == 3) return true;
    }
    return false;
}

fn packIds(ids: [4]CardId) u32 {
    return @as(u32, ids[0]) |
        (@as(u32, ids[1]) << 8) |
        (@as(u32, ids[2]) << 16) |
        (@as(u32, ids[3]) << 24);
}

fn unpackIds(key: u32, out: *[4]CardId) void {
    out[0] = @intCast(key & 0xFF);
    out[1] = @intCast((key >> 8) & 0xFF);
    out[2] = @intCast((key >> 16) & 0xFF);
    out[3] = @intCast((key >> 24) & 0xFF);
}

fn isEnterKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.enter, .{}) or k.matches('\n', .{}) or k.matches('\r', .{});
}

fn initFromApi(
    allocator: std.mem.Allocator,
    state: *GameState,
    data: @import("../../api/models.zig").ConnectionsData,
) !void {
    if (data.categories.len != 4) return error.InvalidConnectionsPuzzle;
    // NYT orders these from easiest to hardest.
    const diffs = [_]Difficulty{ .yellow, .green, .blue, .purple };

    var map = std.StringHashMap(CardId).init(allocator);
    defer map.deinit();

    var next_id: CardId = 0;
    for (data.categories, 0..) |cat, ci| {
        if (cat.cards.len != 4) return error.InvalidConnectionsPuzzle;
        var ids: [4]CardId = undefined;

        for (cat.cards, 0..) |card, i| {
            const content = std.mem.trim(u8, card.content, " \t\r\n");
            if (map.get(content)) |existing| {
                ids[i] = existing;
                continue;
            }
            if (next_id >= 16) return error.InvalidConnectionsPuzzle;
            const id = next_id;
            next_id += 1;
            try map.put(content, id);
            state.cards[id] = .{ .text = content };
            ids[i] = id;
        }

        var sorted = ids;
        std.sort.insertion(CardId, sorted[0..], {}, struct {
            fn lessThan(_: void, a: CardId, b: CardId) bool {
                return a < b;
            }
        }.lessThan);

        state.categories[ci] = .{
            .title = cat.title,
            .difficulty = diffs[ci],
            .ids = ids,
            .key = packIds(sorted),
        };
    }

    if (next_id != 16) return error.InvalidConnectionsPuzzle;
}

fn initBoard(state: *GameState) void {
    for (0..16) |i| state.board[i] = @intCast(i);
    state.board_len = 16;
    state.focus_index = 0;
}

fn seedFromTime() u64 {
    const ns: i128 = std.time.nanoTimestamp();
    return @truncate(@as(u128, @bitCast(ns)));
}

fn shuffleBoard(state: *GameState) void {
    if (state.board_len <= 1) return;
    var prng = std.Random.DefaultPrng.init(seedFromTime());
    const random = prng.random();
    random.shuffle(CardId, state.board[0..state.board_len]);
}

fn deselectAll(state: *GameState) void {
    @memset(state.selected[0..], false);
    state.selected_count = 0;
}

fn toggleSelection(state: *GameState, board_index: usize) void {
    if (board_index >= state.board_len) return;
    const id = state.board[board_index];
    if (state.selected[id]) {
        state.selected[id] = false;
        state.selected_count -= 1;
        return;
    }
    if (state.selected_count >= 4) {
        state.prompt_msg.set("Only 4 selections");
        return;
    }
    state.selected[id] = true;
    state.selected_count += 1;
}

const Dir = enum { left, right, up, down };

fn moveFocus(state: *GameState, dir: Dir) void {
    if (state.board_len == 0) return;
    const idx = state.focus_index;
    const row: usize = idx / 4;
    const col: usize = idx % 4;
    const len: usize = state.board_len;

    switch (dir) {
        .left => {
            if (col > 0) state.focus_index = idx - 1;
        },
        .right => {
            if (col < 3 and idx + 1 < len) state.focus_index = idx + 1;
        },
        .up => {
            if (row > 0) state.focus_index = idx - 4;
        },
        .down => {
            if (idx + 4 < len) state.focus_index = idx + 4;
        },
    }
}

fn clampFocus(state: *GameState) void {
    const len: usize = state.board_len;
    if (len == 0) {
        state.focus_index = 0;
        return;
    }
    if (state.focus_index >= len) state.focus_index = len - 1;
}

fn hitTest(win: vaxis.Window, state: *const GameState, mouse_col: i16, mouse_row: i16) HoverTarget {
    if (mouse_col < 0 or mouse_row < 0) return .none;
    const col_u: u16 = @intCast(mouse_col);
    const row_u: u16 = @intCast(mouse_row);

    const layout = computeLayout(win, state);
    if (layout == null) return .none;

    const l = layout.?;

    // Tiles
    const len: usize = state.board_len;
    for (0..len) |i| {
        const tile_x = l.grid_x + @as(u16, @intCast(i % 4)) * (l.tile_w + l.gap);
        const tile_y = l.grid_y + @as(u16, @intCast(i / 4)) * (l.tile_h + l.gap_y);
        if (col_u >= tile_x and col_u < tile_x + l.tile_w and row_u >= tile_y and row_u < tile_y + l.tile_h) {
            return .{ .tile = i };
        }
    }

    // Buttons
    for (l.buttons, 0..) |b, i| {
        if (b.width == 0 or b.height == 0) continue;
        if (col_u >= b.x and col_u < b.x + b.width and row_u >= b.y and row_u < b.y + b.height) {
            return .{ .button = @enumFromInt(@as(u2, @intCast(i))) };
        }
    }

    return .none;
}

const ButtonRect = struct { x: u16, y: u16, width: u16, height: u16 };

const Layout = struct {
    tile_w: u16,
    tile_h: u16,
    gap: u16,
    gap_y: u16,
    header_y: u16,
    grid_x: u16,
    grid_y: u16,
    solved_y: u16,
    buttons: [3]ButtonRect,
    buttons_y: u16,
};

fn computeLayout(win: vaxis.Window, state: *const GameState) ?Layout {
    const tile_w: u16 = 18;
    const tile_h: u16 = 3;
    const gap: u16 = 1;
    const gap_y: u16 = 1;

    const grid_cols: u16 = 4;
    const grid_w: u16 = grid_cols * tile_w + (grid_cols - 1) * gap;
    const grid_rows: u16 = @intCast(state.board_len / 4);
    const grid_h: u16 = if (grid_rows == 0) 0 else grid_rows * tile_h + (grid_rows - 1) * gap_y;

    const solved_rows: u16 = @intCast(state.solved_count);
    const solved_h: u16 = solved_rows * tile_h + if (solved_rows > 0) (solved_rows - 1) * gap_y else 0;

    const header_h: u16 = 4; // title + keymap + last_msg + prompt
    const header_gap: u16 = 1;
    const solved_gap: u16 = if (solved_rows > 0 and grid_rows > 0) 1 else 0;
    const grid_gap: u16 = 1;
    const buttons_h: u16 = tile_h;
    const footer_h: u16 = buttons_h + 1;

    const block_h: u16 = header_h + header_gap + solved_h + solved_gap + grid_h + grid_gap + footer_h;
    const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;

    const grid_x: u16 = if (win.width > grid_w) @intCast((win.width - grid_w) / 2) else 0;
    const header_y: u16 = block_y;
    const solved_y: u16 = block_y + header_h + header_gap;
    const grid_y: u16 = solved_y + solved_h + solved_gap;
    const buttons_y: u16 = grid_y + grid_h + grid_gap;

    // Buttons: centered row with 3 tiles: Shuffle, Deselect, Submit
    const btn_gap: u16 = 2;
    const btn_w: u16 = 12;
    const btn_h: u16 = tile_h;
    const btn_row_w: u16 = 3 * btn_w + 2 * btn_gap;
    const btn_x0: u16 = if (win.width > btn_row_w) @intCast((win.width - btn_row_w) / 2) else 0;

    const buttons = [_]ButtonRect{
        .{ .x = btn_x0, .y = buttons_y, .width = btn_w, .height = btn_h },
        .{ .x = btn_x0 + btn_w + btn_gap, .y = buttons_y, .width = btn_w, .height = btn_h },
        .{ .x = btn_x0 + 2 * (btn_w + btn_gap), .y = buttons_y, .width = btn_w, .height = btn_h },
    };

    return .{
        .tile_w = tile_w,
        .tile_h = tile_h,
        .gap = gap,
        .gap_y = gap_y,
        .header_y = header_y,
        .grid_x = grid_x,
        .grid_y = grid_y,
        .solved_y = solved_y,
        .buttons = buttons,
        .buttons_y = buttons_y,
    };
}

fn render(vx: *vaxis.Vaxis, state: *GameState, direct_launch: bool) !void {
    const win = vx.window();
    win.clear();
    win.hideCursor();

    _ = direct_launch;

    const layout = computeLayout(win, state) orelse return;

    printCentered(win, layout.header_y, "Connections", .{ .bold = true });
    printCentered(
        win,
        layout.header_y + 1,
        "Space: select  Enter: submit  s: shuffle  d: deselect  q/Esc: menu  Ctrl+C: quit",
        .{ .fg = colors.ui.text_dim },
    );

    if (state.last_msg.text) |t| {
        printCentered(win, layout.header_y + 2, t, .{ .fg = colors.ui.text_dim });
    }
    if (state.prompt_msg.text) |t| {
        printCentered(win, layout.header_y + 3, t, .{ .fg = colors.ui.warning, .bold = true });
    }

    // Solved groups
    var y: u16 = layout.solved_y;
    for (state.solved[0..state.solved_count]) |g| {
        renderSolvedGroup(win, layout.grid_x, y, layout.tile_w * 4 + layout.gap * 3, layout.tile_h, g, &state.cards);
        y += layout.tile_h + layout.gap_y;
    }

    // Grid
    const len: usize = state.board_len;
    for (0..len) |i| {
        const id = state.board[i];
        const tile_x = layout.grid_x + @as(u16, @intCast(i % 4)) * (layout.tile_w + layout.gap);
        const tile_y = layout.grid_y + @as(u16, @intCast(i / 4)) * (layout.tile_h + layout.gap_y);

        const focused = state.focus_index == i;
        const hovered = switch (state.hover) {
            .tile => |ti| ti == i,
            else => false,
        };
        const selected = state.selected[id];
        renderTile(win, tile_x, tile_y, layout.tile_w, layout.tile_h, state.cards[id].text, selected, focused, hovered);
    }

    // Footer: mistakes + buttons
    renderMistakes(win, layout.buttons_y + layout.tile_h, state.mistakes, state.max_mistakes);
    renderButtonRow(win, layout.buttons, state);

    if (state.phase == .finished) {
        const end_msg = if (state.won) "You solved it!  (Enter to continue)" else "Game over  (Enter to continue)";
        printCentered(win, layout.header_y + 3, end_msg, .{ .fg = colors.ui.text, .bold = true });
    }
}

fn printCentered(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height) return;
    const w = win.gwidth(text);
    const col: u16 = if (win.width > w) @as(u16, @intCast((win.width - w) / 2)) else 0;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = row, .col_offset = col, .wrap = .none });
}

fn renderTile(
    parent: vaxis.Window,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    text: []const u8,
    selected: bool,
    focused: bool,
    hovered: bool,
) void {
    const bg = if (selected) vaxis.Color{ .rgb = .{ 80, 80, 80 } } else vaxis.Color.default;
    const border_fg = if (focused or hovered) colors.ui.highlight else colors.ui.border;
    const border_style: vaxis.Style = .{ .fg = border_fg, .bg = bg, .bold = focused };

    const inner = parent.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .glyphs = .single_square, .style = border_style },
    });
    inner.fill(.{ .style = .{ .bg = bg } });

    const text_style: vaxis.Style = .{
        .fg = if (selected) vaxis.Color{ .rgb = .{ 255, 255, 255 } } else vaxis.Color.default,
        .bg = bg,
        .bold = selected,
    };

    const tw = inner.gwidth(text);
    const col: u16 = if (inner.width > tw) @intCast((inner.width - tw) / 2) else 0;
    _ = inner.print(&.{.{ .text = text, .style = text_style }}, .{ .row_offset = 0, .col_offset = col, .wrap = .none });
}

fn renderSolvedGroup(parent: vaxis.Window, x: u16, y: u16, w: u16, h: u16, g: SolvedGroup, cards: *const [16]Card) void {
    const bg = difficultyColor(g.difficulty);
    const border_style: vaxis.Style = .{ .fg = bg, .bg = bg };
    const inner = parent.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .glyphs = .single_square, .style = border_style },
    });
    inner.fill(.{ .style = .{ .bg = bg } });

    // Print title + words as segments so we don't build frame-local strings.
    const style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = bg, .bold = true };

    var segs: [9]vaxis.Segment = undefined;
    var n: usize = 0;
    segs[n] = .{ .text = g.title, .style = style };
    n += 1;
    segs[n] = .{ .text = " — ", .style = style };
    n += 1;
    for (g.ids, 0..) |id, i| {
        if (i != 0) {
            segs[n] = .{ .text = " · ", .style = style };
            n += 1;
        }
        segs[n] = .{ .text = cards[@intCast(id)].text, .style = style };
        n += 1;
    }

    var total_w: u16 = 0;
    for (segs[0..n]) |s| total_w += inner.gwidth(s.text);
    const col: u16 = if (inner.width > total_w) @intCast((inner.width - total_w) / 2) else 0;
    _ = inner.print(segs[0..n], .{ .row_offset = 0, .col_offset = col, .wrap = .none });
}

fn renderMistakes(parent: vaxis.Window, y: u16, mistakes: u8, max_mistakes: u8) void {
    if (y >= parent.height) return;
    var segs: [32]vaxis.Segment = undefined;
    var n: usize = 0;
    segs[n] = .{ .text = "Mistakes: ", .style = .{ .fg = colors.ui.text_dim } };
    n += 1;
    for (0..max_mistakes) |i| {
        const filled = i < mistakes;
        segs[n] = .{ .text = if (filled) "●" else "○", .style = .{ .fg = colors.ui.text_dim } };
        n += 1;
    }

    var w: u16 = 0;
    for (segs[0..n]) |s| w += parent.gwidth(s.text);
    const col: u16 = if (parent.width > w) @intCast((parent.width - w) / 2) else 0;
    _ = parent.print(segs[0..n], .{ .row_offset = y, .col_offset = col, .wrap = .none });
}

fn renderButtonRow(parent: vaxis.Window, rects: [3]ButtonRect, state: *const GameState) void {
    const labels = [_][]const u8{ "Shuffle", "Deselect", "Submit" };
    const buttons = [_]Button{ .shuffle, .deselect, .submit };
    for (rects, 0..) |r, i| {
        const b = buttons[i];
        const hovered = switch (state.hover) {
            .button => |hb| hb == b,
            else => false,
        };
        const style: vaxis.Style = .{ .fg = if (hovered) colors.ui.highlight else colors.ui.border };
        const inner = parent.child(.{
            .x_off = @intCast(r.x),
            .y_off = @intCast(r.y),
            .width = r.width,
            .height = r.height,
            .border = .{ .where = .all, .glyphs = .single_square, .style = style },
        });
        inner.fill(.{ .style = .{ .bg = vaxis.Color.default } });
        const tw = inner.gwidth(labels[i]);
        const col: u16 = if (inner.width > tw) @intCast((inner.width - tw) / 2) else 0;
        _ = inner.print(&.{.{ .text = labels[i], .style = .{ .bold = true } }}, .{
            .row_offset = 0,
            .col_offset = col,
            .wrap = .none,
        });
    }
}

test {
    std.testing.refAllDecls(@This());
}
