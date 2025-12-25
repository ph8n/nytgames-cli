const std = @import("std");

pub const Cli = struct {
    dev_mode: bool,
    direct_wordle: bool,
    wordle_unlimited: bool,
    direct_connections: bool,
};

pub const StartupAction = union(enum) {
    exit: u8,
    run: Cli,
};

pub fn parse(args: []const [:0]u8, version: []const u8) !StartupAction {
    var cli: Cli = .{
        .dev_mode = false,
        .direct_wordle = false,
        .wordle_unlimited = false,
        .direct_connections = false,
    };

    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;

    if (args.len >= 2) {
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
                try printUsage(args[0]);
                return .{ .exit = 0 };
            }
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "version")) {
                try printVersion(args[0], version);
                return .{ .exit = 0 };
            }
            if (std.mem.eql(u8, arg, "--dev") or std.mem.eql(u8, arg, "dev")) {
                cli.dev_mode = true;
                continue;
            }
            if (positional_len >= positional.len) {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                try stderr_writer.interface.print("too many arguments\n", .{});
                try printUsage(args[0]);
                return .{ .exit = 1 };
            }
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len >= 1) {
        if (std.mem.eql(u8, positional[0], "wordle")) {
            cli.direct_wordle = true;
            if (positional_len >= 2) {
                cli.wordle_unlimited = std.mem.eql(u8, positional[1], "unlimited");
                if (!cli.wordle_unlimited) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    try stderr_writer.interface.print("unknown option: {s}\n", .{positional[1]});
                    try printUsage(args[0]);
                    return .{ .exit = 1 };
                }
            }
        } else if (std.mem.eql(u8, positional[0], "unlimited")) {
            cli.direct_wordle = true;
            cli.wordle_unlimited = true;
        } else if (std.mem.eql(u8, positional[0], "connections")) {
            cli.direct_connections = true;
        } else {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            try stderr_writer.interface.print("unknown command: {s}\n", .{positional[0]});
            try printUsage(args[0]);
            return .{ .exit = 1 };
        }
    }

    return .{ .run = cli };
}

fn printUsage(argv0: []const u8) !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    try stderr_writer.interface.print(
        \\usage: {s} [--help] [--version] [--dev] [wordle [unlimited] | unlimited | connections]
        \\
    , .{argv0});
}

fn printVersion(argv0: []const u8, version: []const u8) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    try stdout_writer.interface.print("{s} {s}\n", .{ argv0, version });
}
