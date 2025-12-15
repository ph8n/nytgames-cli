const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("ui/event.zig");
const menu = @import("ui/menu.zig");
const wordle = @import("games/wordle/wordle.zig");
const storage_db = @import("storage/db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var direct_wordle = false;
    var wordle_unlimited = false;
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "wordle")) {
            direct_wordle = true;
            if (args.len >= 3) {
                wordle_unlimited = std.mem.eql(u8, args[2], "unlimited");
                if (!wordle_unlimited) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    try stderr_writer.interface.print("unknown option: {s}\n", .{args[2]});
                    try stderr_writer.interface.print("usage: {s} [wordle [unlimited]]\n", .{args[0]});
                    return;
                }
            }
        } else if (std.mem.eql(u8, args[1], "unlimited")) {
            direct_wordle = true;
            wordle_unlimited = true;
        } else {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            try stderr_writer.interface.print("unknown command: {s}\n", .{args[1]});
            try stderr_writer.interface.print("usage: {s} [wordle [unlimited]]\n", .{args[0]});
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
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var storage = try storage_db.open(allocator, .{});
    defer storage.deinit();

    if (direct_wordle) {
        const mode: wordle.Mode = if (wordle_unlimited) .unlimited else .daily;
        _ = try wordle.run(allocator, &tty, &vx, &loop, &storage, mode, true);
        return;
    }

    while (true) {
        switch (try menu.run(allocator, &tty, &vx, &loop)) {
            .quit => return,
            .wordle => switch (try wordle.run(allocator, &tty, &vx, &loop, &storage, .daily, false)) {
                .back_to_menu => continue,
                .quit => return,
            },
        }
    }
}
