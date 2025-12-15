const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("../ui/event.zig");
const colors = @import("../ui/colors.zig");
const keys = @import("../ui/keys.zig");

pub const Exit = enum {
    back_to_menu,
    quit,
};

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
    title: []const u8,
) !Exit {
    while (true) {
        const win = vx.window();
        win.clear();
        win.hideCursor();

        printCentered(win, 0, title, .{ .bold = true });
        printCentered(win, 1, "q/Esc: back   Ctrl+C: quit", .{ .fg = colors.ui.text_dim });
        printCentered(win, 3, "Coming soon.", .{ .fg = colors.ui.text_dim });

        try vx.render(tty.writer());

        switch (loop.nextEvent()) {
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .mouse, .mouse_leave => {},
            .key_press => |k| {
                if (keys.isCtrlC(k)) return .quit;
                if (k.matches('q', .{}) or k.matches(vaxis.Key.escape, .{})) return .back_to_menu;
            },
        }
    }
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
