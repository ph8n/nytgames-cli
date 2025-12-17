const vaxis = @import("vaxis");
const Color = vaxis.Cell.Color;

// Wordle colors
pub const wordle = struct {
    pub const correct = Color{ .rgb = .{ 106, 170, 100 } }; // #6aaa64 - Green
    pub const present = Color{ .rgb = .{ 201, 180, 88 } }; // #c9b458 - Yellow
    pub const absent = Color{ .rgb = .{ 120, 124, 126 } }; // #787c7e - Gray
    pub const empty_border = Color{ .rgb = .{ 211, 214, 218 } }; // #d3d6da - Light gray
};

// Connections colors (category difficulty)
pub const connections = struct {
    pub const yellow = Color{ .rgb = .{ 249, 223, 109 } }; // #f9df6d - Easiest
    pub const green = Color{ .rgb = .{ 160, 195, 90 } }; // #a0c35a
    pub const blue = Color{ .rgb = .{ 176, 196, 239 } }; // #b0c4ef
    pub const purple = Color{ .rgb = .{ 186, 129, 197 } }; // #ba81c5 - Hardest
};

// Common UI colors
pub const ui = struct {
    pub const text = Color.default; // Primary text - use terminal default
    pub const text_dim = Color{ .rgb = .{ 150, 150, 150 } }; // #969696 - Secondary text
    pub const border = Color{ .rgb = .{ 100, 100, 100 } }; // #646464 - Borders/frames
    pub const highlight = Color{ .rgb = .{ 66, 133, 244 } }; // #4285f4 - Selection highlight
    pub const success = Color{ .rgb = .{ 106, 170, 100 } }; // #6aaa64 - Success (same as wordle correct)
    pub const warning = Color{ .rgb = .{ 201, 180, 88 } }; // #c9b458 - Warning (same as wordle present)
};
