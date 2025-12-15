const std = @import("std");

const api_client = @import("api/client.zig");
const date = @import("utils/date.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();
    var stdout_writer = stdout_file.writer(&.{});
    var stderr_writer = stderr_file.writer(&.{});

    const today = try date.todayLocalYYYYMMDD();

    try stdout_writer.interface.print("nytg-cli Phase 1 check\n", .{});
    try stdout_writer.interface.print("date (local): {s}\n", .{today[0..]});
    try stdout_writer.interface.print("url: https://www.nytimes.com/svc/wordle/v2/{s}.json\n", .{today[0..]});

    var parsed = api_client.fetchWordle(allocator, today[0..]) catch |err| {
        try stderr_writer.interface.print("fetchWordle failed: {any}\n", .{err});
        return;
    };
    defer parsed.deinit();

    try stdout_writer.interface.print("fetch: ok\n", .{});
    try stdout_writer.interface.print("wordle.id: {d}\n", .{parsed.value.id});
    try stdout_writer.interface.print("wordle.print_date: {s}\n", .{parsed.value.print_date});
    try stdout_writer.interface.print("print_date matches requested: {}\n", .{std.mem.eql(u8, parsed.value.print_date, today[0..])});
    try stdout_writer.interface.print("wordle.solution: {s}\n", .{parsed.value.solution});
}
