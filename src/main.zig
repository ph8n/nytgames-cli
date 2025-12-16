const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("ui/event.zig");
const menu = @import("ui/menu.zig");
const stats = @import("ui/stats.zig");
const connections = @import("games/connections/connections.zig");
const spelling_bee = @import("games/spelling_bee/spelling_bee.zig");
const wordle = @import("games/wordle/wordle.zig");
const storage_db = @import("storage/db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var dev_mode = false;
    var direct_wordle = false;
    var wordle_unlimited = false;
    var direct_connections = false;
    var direct_spelling_bee = false;
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;

    if (args.len >= 2) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "dev")) {
                dev_mode = true;
                continue;
            }
            if (positional_len >= positional.len) {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                try stderr_writer.interface.print("too many arguments\n", .{});
                try stderr_writer.interface.print(
                    "usage: {s} [--dev] [wordle [unlimited] | unlimited | connections | spelling-bee]\n",
                    .{args[0]},
                );
                return;
            }
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len >= 1) {
        if (std.mem.eql(u8, positional[0], "wordle")) {
            direct_wordle = true;
            if (positional_len >= 2) {
                wordle_unlimited = std.mem.eql(u8, positional[1], "unlimited");
                if (!wordle_unlimited) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    try stderr_writer.interface.print("unknown option: {s}\n", .{positional[1]});
                    try stderr_writer.interface.print(
                        "usage: {s} [--dev] [wordle [unlimited] | unlimited | connections | spelling-bee]\n",
                        .{args[0]},
                    );
                    return;
                }
            }
        } else if (std.mem.eql(u8, positional[0], "unlimited")) {
            direct_wordle = true;
            wordle_unlimited = true;
        } else if (std.mem.eql(u8, positional[0], "connections")) {
            direct_connections = true;
        } else if (std.mem.eql(u8, positional[0], "spelling-bee") or std.mem.eql(u8, positional[0], "bee")) {
            direct_spelling_bee = true;
        } else {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            try stderr_writer.interface.print("unknown command: {s}\n", .{positional[0]});
            try stderr_writer.interface.print(
                "usage: {s} [--dev] [wordle [unlimited] | unlimited | connections | spelling-bee]\n",
                .{args[0]},
            );
            return;
        }
    }

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

    if (direct_connections) {
        switch (try connections.run(allocator, &tty, &vx, &loop, &storage, dev_mode, true)) {
            .quit => {
                try flashQuit(&tty, &vx);
                return;
            },
            .back_to_menu => {},
        }
    }

    if (direct_wordle) {
        const mode: wordle.Mode = if (wordle_unlimited) .unlimited else .daily;
        switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, mode, dev_mode, true)) {
            .quit => {
                try flashQuit(&tty, &vx);
                return;
            },
            .back_to_menu => {},
        }
    }

    if (direct_spelling_bee) {
        switch (try spelling_bee.run(allocator, &tty, &vx, &loop, &storage, dev_mode, true)) {
            .quit => {
                try flashQuit(&tty, &vx);
                return;
            },
            .back_to_menu => {},
        }
    }

    while (true) {
        switch (try menu.run(allocator, &tty, &vx, &loop, &storage, dev_mode)) {
            .quit => {
                try flashQuit(&tty, &vx);
                return;
            },
            .wordle => switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, .daily, dev_mode, false)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .wordle_unlimited => switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, .unlimited, dev_mode, false)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .connections => switch (try connections.run(allocator, &tty, &vx, &loop, &storage, dev_mode, false)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .spelling_bee => switch (try spelling_bee.run(allocator, &tty, &vx, &loop, &storage, dev_mode, false)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .stats_wordle => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .wordle)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .stats_wordle_unlimited => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .wordle_unlimited)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .stats_connections => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .connections)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
            .stats_spelling_bee => switch (try stats.run(allocator, &tty, &vx, &loop, &storage, .spelling_bee)) {
                .back_to_menu => continue,
                .quit => {
                    try flashQuit(&tty, &vx);
                    return;
                },
            },
        }
    }
}

fn flashQuit(tty: *vaxis.Tty, vx: *vaxis.Vaxis) !void {
    const win = vx.window();
    win.clear();
    win.hideCursor();
    _ = win.print(&.{.{ .text = "Saving..." }}, .{ .row_offset = 0, .col_offset = 2, .wrap = .none });
    try vx.render(tty.writer());
    std.Thread.sleep(120 * std.time.ns_per_ms);
}
