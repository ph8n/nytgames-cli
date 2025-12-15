const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("event.zig");
const colors = @import("colors.zig");
const keys = @import("keys.zig");
const date = @import("../utils/date.zig");
const storage_db = @import("../storage/db.zig");
const storage_stats = @import("../storage/stats.zig");

pub const Choice = enum {
    wordle,
    stats,
    quit,
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    storage: *storage_db.Storage,
) !Choice {
    var selected: u8 = 0;
    const today = try date.todayLocalYYYYMMDD();
    const wordle_status = try storage_stats.getWordlePlayedStatus(&storage.db, today[0..]);

    const items = [_]struct { label: []const u8, choice: Choice, status: storage_stats.PlayedStatus }{
        .{ .label = "Wordle", .choice = .wordle, .status = wordle_status },
        .{ .label = "Stats", .choice = .stats, .status = .not_played },
        .{ .label = "Quit", .choice = .quit, .status = .not_played },
    };

    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        const title = "nytg-cli";
        const hint = "↑/↓ or j/k  •  Enter/Space";
        const win_mark = "✓";
        const lose_mark = "X";

        // Determine menu layout width
        var list_w: u16 = 0;
        for (items) |it| {
            // prefix + label + space + mark
            const w = win.gwidth(it.label) + win.gwidth("> ") + 1 + 1;
            if (w > list_w) list_w = w;
        }

        const title_w = win.gwidth(title);
        const hint_w = win.gwidth(hint);
        var layout_w = list_w;
        if (title_w > layout_w) layout_w = title_w;
        if (hint_w > layout_w) layout_w = hint_w;

        const block_h: u16 = 2 + 1 + @as(u16, @intCast(items.len)); // title + hint + gap + items
        const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;
        const block_x: u16 = if (win.width > layout_w) @intCast((win.width - layout_w) / 2) else 0;

        _ = win.print(&.{.{ .text = title }}, .{
            .row_offset = block_y,
            .col_offset = block_x + if (layout_w > title_w) @as(u16, @intCast((layout_w - title_w) / 2)) else 0,
            .wrap = .none,
        });
        _ = win.print(&.{.{ .text = hint }}, .{
            .row_offset = block_y + 1,
            .col_offset = block_x + if (layout_w > hint_w) @as(u16, @intCast((layout_w - hint_w) / 2)) else 0,
            .wrap = .none,
        });

        const start_y: u16 = block_y + 3;
        for (items, 0..) |it, i| {
            const is_sel = selected == i;
            const prefix = if (is_sel) "> " else "  ";
            const style: vaxis.Style = if (is_sel) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
            _ = win.print(&.{
                .{ .text = prefix, .style = style },
                .{ .text = it.label, .style = style },
            }, .{
                .row_offset = start_y + @as(u16, @intCast(i)),
                .col_offset = block_x,
                .wrap = .none,
            });

            const mark: ?[]const u8 = switch (it.status) {
                .not_played => null,
                .won => win_mark,
                .lost => lose_mark,
            };
            if (mark) |m| {
                const mark_style: vaxis.Style = .{
                    .fg = switch (it.status) {
                        .won => colors.wordle.correct,
                        .lost => .{ .rgb = .{ 220, 20, 60 } },
                        .not_played => colors.ui.text_dim,
                    },
                    .bold = true,
                };
                const mark_col: u16 = block_x + layout_w - win.gwidth(m);
                _ = win.print(&.{.{ .text = m, .style = mark_style }}, .{
                    .row_offset = start_y + @as(u16, @intCast(i)),
                    .col_offset = mark_col,
                    .wrap = .none,
                });
            }
        }

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;

                if (k.matches(vaxis.Key.up, .{}) or k.matches('k', .{})) {
                    if (selected > 0) selected -= 1;
                } else if (k.matches(vaxis.Key.down, .{}) or k.matches('j', .{})) {
                    if (selected + 1 < items.len) selected += 1;
                } else if (isConfirmKey(k)) {
                    return items[selected].choice;
                }
            },
        }
    }
}

fn isConfirmKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.enter, .{}) or
        k.matches('\n', .{}) or
        k.matches('\r', .{}) or
        k.matches(vaxis.Key.space, .{}) or
        k.matches(' ', .{});
}

test {
    std.testing.refAllDecls(@This());
}
