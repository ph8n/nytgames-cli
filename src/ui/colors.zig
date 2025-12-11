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

// Spelling Bee colors
pub const spelling_bee = struct {
    pub const center = Color{ .rgb = .{ 247, 218, 33 } }; // #f7da21 - Center letter (yellow)
    pub const outer = Color{ .rgb = .{ 230, 230, 230 } }; // #e6e6e6 - Outer letters (gray)
    pub const found = Color{ .rgb = .{ 248, 205, 5 } }; // #f8cd05 - Found word highlight
    pub const pangram = Color{ .rgb = .{ 247, 218, 33 } }; // #f7da21 - Pangram highlight
};

// Strands colors
pub const strands = struct {
    pub const theme = Color{ .rgb = .{ 248, 205, 5 } }; // #f8cd05 - Theme word (yellow)
    pub const found = Color{ .rgb = .{ 175, 200, 233 } }; // #afc8e9 - Found word (blue)
    pub const spangram = Color{ .rgb = .{ 248, 205, 5 } }; // #f8cd05 - Spangram (yellow)
    pub const hint = Color{ .rgb = .{ 135, 206, 235 } }; // #87ceeb - Hint indicator
};

// Sudoku colors
pub const sudoku = struct {
    pub const selected = Color{ .rgb = .{ 187, 222, 251 } }; // #bbdefb - Selected cell
    pub const error_cell = Color{ .rgb = .{ 255, 205, 210 } }; // #ffcdd2 - Error highlight
    pub const input = Color{ .rgb = .{ 25, 118, 210 } }; // #1976d2 - User input text
    pub const given = Color{ .rgb = .{ 50, 50, 50 } }; // #323232 - Pre-filled numbers
    pub const same_number = Color{ .rgb = .{ 195, 215, 234 } }; // #c3d7ea - Same number highlight
    pub const box_border = Color{ .rgb = .{ 52, 52, 52 } }; // #343434 - 3x3 box borders
    pub const cell_border = Color{ .rgb = .{ 189, 189, 189 } }; // #bdbdbd - Cell borders
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
