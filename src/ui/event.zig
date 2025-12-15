const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    mouse: vaxis.Mouse,
    mouse_leave,
};

test {
    std.testing.refAllDecls(@This());
}
