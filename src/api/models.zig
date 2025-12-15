const std = @import("std");

pub const WordleData = struct {
    id: i32,
    solution: []const u8,
    print_date: []const u8,
};

test {
    std.testing.refAllDecls(@This());
}
