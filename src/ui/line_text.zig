const std = @import("std");
const math = @import("../utils/math.zig");

pub const UIVertex = struct {
    position: [2]f32,
    color: [4]f32,
};

const GLYPH_WIDTH: usize = 5;
const GLYPH_HEIGHT: usize = 7;
const LETTER_SPACING: usize = 1;
const LINE_SPACING: usize = 2;

fn screenToNdc(screen_size: math.Vec2, x: f32, y: f32) [2]f32 {
    const ndc_x = (x / screen_size.x) * 2.0 - 1.0;
    const ndc_y = 1.0 - (y / screen_size.y) * 2.0;
    return .{ ndc_x, ndc_y };
}

pub fn appendQuad(
    builder: *std.ArrayListUnmanaged(UIVertex),
    allocator: std.mem.Allocator,
    min: math.Vec2,
    max: math.Vec2,
    screen_size: math.Vec2,
    color: [4]f32,
) !void {
    const tl = screenToNdc(screen_size, min.x, min.y);
    const tr = screenToNdc(screen_size, max.x, min.y);
    const bl = screenToNdc(screen_size, min.x, max.y);
    const br = screenToNdc(screen_size, max.x, max.y);

    // First triangle (tl, bl, br)
    try builder.append(allocator, .{ .position = tl, .color = color });
    try builder.append(allocator, .{ .position = bl, .color = color });
    try builder.append(allocator, .{ .position = br, .color = color });

    // Second triangle (tl, br, tr)
    try builder.append(allocator, .{ .position = tl, .color = color });
    try builder.append(allocator, .{ .position = br, .color = color });
    try builder.append(allocator, .{ .position = tr, .color = color });
}

pub fn lineHeightPx(scale: f32) f32 {
    return (@as(f32, @floatFromInt(GLYPH_HEIGHT + LINE_SPACING))) * scale;
}

pub fn textWidth(text: []const u8, scale: f32) f32 {
    var width: f32 = 0;
    for (text) |_| {
        width += (@as(f32, @floatFromInt(GLYPH_WIDTH + LETTER_SPACING))) * scale;
    }
    return width;
}

fn patternForGlyph(ch: u8) ?[]const []const u8 {
    const upper = std.ascii.toUpper(ch);
    return switch (upper) {
        'A' => &[_][]const u8{
            "  #  ",
            " # # ",
            "#   #",
            "#####",
            "#   #",
            "#   #",
            "#   #",
        },
        'B' => &[_][]const u8{
            "#### ",
            "#   #",
            "#   #",
            "#### ",
            "#   #",
            "#   #",
            "#### ",
        },
        'C' => &[_][]const u8{
            " ### ",
            "#   #",
            "#    ",
            "#    ",
            "#    ",
            "#   #",
            " ### ",
        },
        'D' => &[_][]const u8{
            "#### ",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            "#### ",
        },
        'E' => &[_][]const u8{
            "#####",
            "#    ",
            "#    ",
            "#### ",
            "#    ",
            "#    ",
            "#####",
        },
        'F' => &[_][]const u8{
            "#####",
            "#    ",
            "#    ",
            "#### ",
            "#    ",
            "#    ",
            "#    ",
        },
        'G' => &[_][]const u8{
            " ### ",
            "#   #",
            "#    ",
            "# ###",
            "#   #",
            "#   #",
            " ### ",
        },
        'H' => &[_][]const u8{
            "#   #",
            "#   #",
            "#   #",
            "#####",
            "#   #",
            "#   #",
            "#   #",
        },
        'I' => &[_][]const u8{
            " ### ",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
            " ### ",
        },
        'J' => &[_][]const u8{
            "  ###",
            "   # ",
            "   # ",
            "   # ",
            "#  # ",
            "#  # ",
            " ##  ",
        },
        'K' => &[_][]const u8{
            "#   #",
            "#  # ",
            "# #  ",
            "##   ",
            "# #  ",
            "#  # ",
            "#   #",
        },
        'L' => &[_][]const u8{
            "#    ",
            "#    ",
            "#    ",
            "#    ",
            "#    ",
            "#    ",
            "#####",
        },
        'M' => &[_][]const u8{
            "#   #",
            "## ##",
            "# # #",
            "# # #",
            "#   #",
            "#   #",
            "#   #",
        },
        'N' => &[_][]const u8{
            "#   #",
            "##  #",
            "# # #",
            "#  ##",
            "#   #",
            "#   #",
            "#   #",
        },
        'O' => &[_][]const u8{
            " ### ",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            " ### ",
        },
        'P' => &[_][]const u8{
            "#### ",
            "#   #",
            "#   #",
            "#### ",
            "#    ",
            "#    ",
            "#    ",
        },
        'Q' => &[_][]const u8{
            " ### ",
            "#   #",
            "#   #",
            "#   #",
            "# # #",
            "#  ##",
            " ####",
        },
        'R' => &[_][]const u8{
            "#### ",
            "#   #",
            "#   #",
            "#### ",
            "#  # ",
            "#   #",
            "#   #",
        },
        'S' => &[_][]const u8{
            " ####",
            "#    ",
            "#    ",
            " ### ",
            "    #",
            "    #",
            "#### ",
        },
        'T' => &[_][]const u8{
            "#####",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
        },
        'U' => &[_][]const u8{
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            " ### ",
        },
        'V' => &[_][]const u8{
            "#   #",
            "#   #",
            "#   #",
            "#   #",
            " # # ",
            " # # ",
            "  #  ",
        },
        'W' => &[_][]const u8{
            "#   #",
            "#   #",
            "#   #",
            "# # #",
            "# # #",
            "## ##",
            "#   #",
        },
        'X' => &[_][]const u8{
            "#   #",
            " # # ",
            "  #  ",
            "  #  ",
            "  #  ",
            " # # ",
            "#   #",
        },
        'Y' => &[_][]const u8{
            "#   #",
            "#   #",
            " # # ",
            "  #  ",
            "  #  ",
            "  #  ",
            "  #  ",
        },
        'Z' => &[_][]const u8{
            "#####",
            "    #",
            "   # ",
            "  #  ",
            " #   ",
            "#    ",
            "#####",
        },
        '0' => &[_][]const u8{
            " ### ",
            "#   #",
            "#  ##",
            "# # #",
            "##  #",
            "#   #",
            " ### ",
        },
        '1' => &[_][]const u8{
            "  #  ",
            " ##  ",
            "# #  ",
            "  #  ",
            "  #  ",
            "  #  ",
            "#####",
        },
        '2' => &[_][]const u8{
            " ### ",
            "#   #",
            "    #",
            "   # ",
            "  #  ",
            " #   ",
            "#####",
        },
        '3' => &[_][]const u8{
            " ### ",
            "#   #",
            "    #",
            "  ## ",
            "    #",
            "#   #",
            " ### ",
        },
        '4' => &[_][]const u8{
            "#   #",
            "#   #",
            "#   #",
            "#####",
            "    #",
            "    #",
            "    #",
        },
        '5' => &[_][]const u8{
            "#####",
            "#    ",
            "#    ",
            "#### ",
            "    #",
            "#   #",
            " ### ",
        },
        '6' => &[_][]const u8{
            " ### ",
            "#   #",
            "#    ",
            "#### ",
            "#   #",
            "#   #",
            " ### ",
        },
        '7' => &[_][]const u8{
            "#####",
            "    #",
            "   # ",
            "  #  ",
            " #   ",
            " #   ",
            " #   ",
        },
        '8' => &[_][]const u8{
            " ### ",
            "#   #",
            "#   #",
            " ### ",
            "#   #",
            "#   #",
            " ### ",
        },
        '9' => &[_][]const u8{
            " ### ",
            "#   #",
            "#   #",
            " ####",
            "    #",
            "#   #",
            " ### ",
        },
        '-' => &[_][]const u8{
            "     ",
            "     ",
            "     ",
            " ### ",
            "     ",
            "     ",
            "     ",
        },
        ':' => &[_][]const u8{
            "     ",
            "  #  ",
            "  #  ",
            "     ",
            "  #  ",
            "  #  ",
            "     ",
        },
        '=' => &[_][]const u8{
            "     ",
            "     ",
            "#####",
            "     ",
            "#####",
            "     ",
            "     ",
        },
        '>' => &[_][]const u8{
            "#    ",
            " #   ",
            "  #  ",
            "   # ",
            "  #  ",
            " #   ",
            "#    ",
        },
        '<' => &[_][]const u8{
            "    #",
            "   # ",
            "  #  ",
            " #   ",
            "  #  ",
            "   # ",
            "    #",
        },
        '#' => &[_][]const u8{
            " # # ",
            "#####",
            " # # ",
            " # # ",
            "#####",
            " # # ",
            " # # ",
        },
        else => null,
    };
}

pub fn appendText(
    builder: *std.ArrayListUnmanaged(UIVertex),
    allocator: std.mem.Allocator,
    text: []const u8,
    origin: math.Vec2,
    scale: f32,
    screen_size: math.Vec2,
    color: [4]f32,
) !void {
    var cursor = origin;
    for (text) |ch| {
        if (ch == '\n') {
            cursor.x = origin.x;
            cursor.y += lineHeightPx(scale);
            continue;
        }

        if (ch == ' ') {
            cursor.x += (@as(f32, @floatFromInt(GLYPH_WIDTH + LETTER_SPACING))) * scale;
            continue;
        }

        const pattern_opt = patternForGlyph(ch);
        if (pattern_opt == null) {
            cursor.x += (@as(f32, @floatFromInt(GLYPH_WIDTH + LETTER_SPACING))) * scale;
            continue;
        }

        const pattern = pattern_opt.?;
        var row: usize = 0;
        while (row < pattern.len) : (row += 1) {
            const row_str = pattern[row];
            var col: usize = 0;
            while (col < row_str.len) : (col += 1) {
                if (row_str[col] != '#') continue;
                const px = cursor.x + @as(f32, @floatFromInt(col)) * scale;
                const py = cursor.y + @as(f32, @floatFromInt(row)) * scale;
                try appendQuad(
                    builder,
                    allocator,
                    math.Vec2.init(px, py),
                    math.Vec2.init(px + scale, py + scale),
                    screen_size,
                    color,
                );
            }
        }

        cursor.x += (@as(f32, @floatFromInt(GLYPH_WIDTH + LETTER_SPACING))) * scale;
    }
}
