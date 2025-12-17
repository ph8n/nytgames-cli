const std = @import("std");

pub const WordleData = struct {
    id: i32,
    solution: []const u8,
    print_date: []const u8,
};

pub const ConnectionsData = struct {
    id: i32,
    print_date: []const u8,
    categories: []Category,

    pub const Category = struct {
        title: []const u8,
        cards: []Card,
    };

    pub const Card = struct {
        content: []const u8,
        position: ?i32 = null,
    };
};

test {
    std.testing.refAllDecls(@This());
}
