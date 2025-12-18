const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("event.zig");
const colors = @import("colors.zig");
const keys = @import("keys.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

pub const Mark = enum {
    won,
    lost,
};

pub const Options = struct {
    title: []const u8,
    puzzle_date: []const u8,
    direct_launch: bool = false,
    mark: ?Mark = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    options: Options,
) !Exit {
    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        const hint = "Esc: back   Enter/Space: ok   Ctrl+C: quit";

        const body_h: u16 = if (options.mark == null) 3 else 4;
        const block_h: u16 = 2 + 1 + body_h; // title + hint + gap + body
        const block_y: u16 = if (win.height > block_h) @intCast((win.height - block_h) / 2) else 0;

        printCentered(win, block_y + 0, options.title, .{ .bold = true });
        printCentered(win, block_y + 1, hint, .{ .fg = colors.ui.text_dim });

        printCentered(win, block_y + 3, "Already played today", .{});
        printCentered(win, block_y + 4, options.puzzle_date, .{ .fg = colors.ui.text_dim });
        if (options.mark) |m| {
            const mark_text: []const u8 = switch (m) {
                .won => "✓",
                .lost => "X",
            };
            const mark_color = switch (m) {
                .won => colors.ui.success,
                .lost => vaxis.Color{ .rgb = .{ 220, 20, 60 } },
            };
            printCentered(win, block_y + 5, mark_text, .{ .fg = mark_color, .bold = true });
        }

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .mouse, .mouse_leave => {},
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches(vaxis.Key.escape, .{}) or isEnterKey(k) or isSpaceKey(k)) {
                    return if (options.direct_launch) .quit else .back_to_menu;
                }
            },
        }
    }
}

fn isEnterKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.enter, .{}) or k.matches('\n', .{}) or k.matches('\r', .{});
}

fn isSpaceKey(k: vaxis.Key) bool {
    return k.matches(vaxis.Key.space, .{}) or k.matches(' ', .{});
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
