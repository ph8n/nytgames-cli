const std = @import("std");
const vaxis = @import("vaxis");

const app_event = @import("../../ui/event.zig");
const stub = @import("../stub.zig");

pub const Exit = stub.Exit;

pub fn run(
    allocator: std.mem.Allocator,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(app_event.Event),
) !Exit {
    return stub.run(allocator, tty, vx, loop, "Mini");
}

test {
    std.testing.refAllDecls(@This());
}
