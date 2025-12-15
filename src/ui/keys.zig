const vaxis = @import("vaxis");

pub fn isCtrlC(k: vaxis.Key) bool {
    // Depending on terminal mode, Ctrl+C may arrive as:
    // - 'c' with ctrl modifier, or
    // - ETX (0x03) with no modifiers.
    return k.matchShortcut('c', .{ .ctrl = true }) or
        k.matches('c', .{ .ctrl = true }) or
        k.matches(0x03, .{});
}

test {
    @import("std").testing.refAllDecls(@This());
}
