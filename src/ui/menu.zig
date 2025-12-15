const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("event.zig");

pub const Choice = enum {
    wordle,
    quit,
};

pub fn run(allocator: std.mem.Allocator, tty: *vaxis.Tty, vx: *vaxis.Vaxis, loop: *vaxis.Loop(app_event.Event)) !Choice {
    var selected: u8 = 0;
    const items = [_]struct { label: []const u8, choice: Choice }{
        .{ .label = "Wordle", .choice = .wordle },
        .{ .label = "Quit", .choice = .quit },
    };

    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        _ = win.print(&.{.{ .text = "nytg-cli" }}, .{ .row_offset = 0, .col_offset = 2, .wrap = .none });
        _ = win.print(&.{.{ .text = "Use ↑/↓ and Enter" }}, .{ .row_offset = 2, .col_offset = 2, .wrap = .none });

        const start_y: u16 = 4;
        for (items, 0..) |it, i| {
            const is_sel = selected == i;
            const prefix = if (is_sel) "> " else "  ";
            const style: vaxis.Style = if (is_sel) .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true } else .{};
            _ = win.print(&.{
                .{ .text = prefix, .style = style },
                .{ .text = it.label, .style = style },
            }, .{
                .row_offset = start_y + @as(u16, @intCast(i)),
                .col_offset = 2,
                .wrap = .none,
            });
        }

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .key_press => |k| {
                if (k.matches(vaxis.Key.escape, .{}) or k.matchShortcut('c', .{ .ctrl = true })) return .quit;
                if (k.matches(vaxis.Key.up, .{}) or k.matches('k', .{})) {
                    if (selected > 0) selected -= 1;
                } else if (k.matches(vaxis.Key.down, .{}) or k.matches('j', .{})) {
                    if (selected + 1 < items.len) selected += 1;
                } else if (k.matches(vaxis.Key.enter, .{})) {
                    return items[selected].choice;
                }
            },
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
