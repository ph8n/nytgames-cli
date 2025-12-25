const std = @import("std");
const App = @import("app.zig").App;

pub fn main() void {
    const code: u8 = blk: {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        var app = App.init(gpa.allocator()) catch break :blk 1;
        defer app.deinit();

        const code = app.run() catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            break :blk 1;
        };

        break :blk code;
    };

    std.process.exit(code);
}
