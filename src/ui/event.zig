const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

test {
    std.testing.refAllDecls(@This());
}
