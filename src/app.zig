const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");

const app_event = @import("ui/event.zig");
const menu = @import("ui/menu.zig");
const stats = @import("ui/stats.zig");
const connections = @import("games/connections/connections.zig");
const wordle = @import("games/wordle/wordle.zig");
const storage_db = @import("storage/db.zig");
const option = @import("option.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    args: []const [:0]u8,

    pub fn init(allocator: std.mem.Allocator) !App {
        const args = try std.process.argsAlloc(allocator);
        return .{ .allocator = allocator, .args = args };
    }

    pub fn deinit(self: *App) void {
        std.process.argsFree(self.allocator, self.args);
    }

    pub fn run(self: *App) !u8 {
        const action = try option.parse(self.args, build_options.version);
        return switch (action) {
            .exit => |code| code,
            .run => |cli| try runUi(self.allocator, cli),
        };
    }

    fn runUi(allocator: std.mem.Allocator, cli: option.Cli) !u8 {
        var buffer: [1024]u8 = undefined;
        var tty = try vaxis.Tty.init(&buffer);
        defer tty.deinit();

        var vx = try vaxis.init(allocator, .{});
        defer vx.deinit(allocator, tty.writer());
        defer vx.resetState(tty.writer()) catch {};

        var loop: vaxis.Loop(app_event.Event) = .{ .tty = &tty, .vaxis = &vx };
        try loop.init();
        try loop.start();
        defer loop.stop();

        try vx.enterAltScreen(tty.writer());
        try vx.setMouseMode(tty.writer(), true);
        try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

        var storage = try storage_db.open(allocator, .{});
        defer storage.deinit();

        if (cli.direct_connections) {
            switch (try connections.run(allocator, &tty, &vx, &loop, &storage, cli.dev_mode, true)) {
                .quit => {
                    try flashQuit(&tty, &vx);
                    return 0;
                },
                .back_to_menu => {},
            }
        }

        if (cli.direct_wordle) {
            const mode: wordle.Mode = if (cli.wordle_unlimited) .unlimited else .daily;
            switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, mode, cli.dev_mode, true)) {
                .quit => {
                    try flashQuit(&tty, &vx);
                    return 0;
                },
                .back_to_menu => {},
            }
        }

        while (true) {
            switch (try menu.run(allocator, &tty, &vx, &loop, &storage, cli.dev_mode)) {
                .quit => {
                    try flashQuit(&tty, &vx);
                    return 0;
                },
                .wordle => switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, .daily, cli.dev_mode, false)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
                .wordle_unlimited => switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, .unlimited, cli.dev_mode, false)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
                .connections => switch (try connections.run(allocator, &tty, &vx, &loop, &storage, cli.dev_mode, false)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
                .stats_wordle => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .wordle)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
                .stats_wordle_unlimited => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .wordle_unlimited)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
                .stats_connections => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .connections)) {
                    .back_to_menu => continue,
                    .quit => {
                        try flashQuit(&tty, &vx);
                        return 0;
                    },
                },
            }
        }
    }
};

fn flashQuit(tty: *vaxis.Tty, vx: *vaxis.Vaxis) !void {
    const win = vx.window();
    win.clear();
    win.hideCursor();
    _ = win.print(&.{.{ .text = "Saving..." }}, .{ .row_offset = 0, .col_offset = 2, .wrap = .none });
    try vx.render(tty.writer());
    std.Thread.sleep(120 * std.time.ns_per_ms);
}
