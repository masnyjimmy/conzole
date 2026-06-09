const std = @import("std");

pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    /// ANSI foreground escape value.
    fn fg(self: Color) u8 {
        return @intFromEnum(self);
    }

    /// ANSI background escape value (fg + 10, except for .default which stays 0).
    fn bg(self: Color) u8 {
        const v = @intFromEnum(self);
        return if (v == 0) 0 else v + 10;
    }
};

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    strikethrough: bool = false,
    fg: ?Color = null,
    bg: ?Color = null,
};

pub const Config = struct {
    indentString: []const u8 = "  ",
    processNewLine: bool = true,
    autoFlush: bool = true,
    resetOnCleanup: bool = true,
};

pub const Printer = struct {
    const Self = @This();

    writer: *std.Io.Writer,
    indent_level: usize = 0,

    current_style: ?Style = null,

    config: Config,

    pub fn init(writer: *std.Io.Writer) Self {
        return .initConfig(writer, .{});
    }

    pub fn initConfig(writer: *std.Io.Writer, config: Config) Self {
        return .{
            .writer = writer,
            .config = config,
        };
    }

    pub fn deinit(self: *Printer) void {
        if (self.config.resetOnCleanup) {
            self.resetStyle() catch {};
        }
    }

    fn sgr(self: *Printer, code: u8) !void {
        try self.writer.print("\x1b[{d}m", .{code});
    }

    pub fn resetStyle(self: *Self) !void {
        try self.sgr(0);
        self.current_style = null;
    }

    fn applyStyle(self: *Self, style: Style) !void {
        if (style.fg) |fg| try self.sgr(fg.fg());
        if (style.bg) |fg| try self.sgr(fg.bg());

        if (style.bold) try self.sgr(1);
        if (style.dim) try self.sgr(2);
        if (style.italic) try self.sgr(3);
        if (style.underline) try self.sgr(4);
        if (style.blink) try self.sgr(5);
        if (style.strikethrough) try self.sgr(9);

        self.current_style = style;
    }

    pub fn fetchSetStyle(self: *Self, style: Style) !?Style {
        const out = self.current_style;

        try self.applyStyle(style);

        return out;
    }

    pub fn setStyle(self: *Self, style: Style) !void {
        try self.applyStyle(style);
    }

    pub fn indent(self: *Self) void {
        self.indent_level +|= 1;
    }
    pub fn detend(self: *Self) void {
        self.indent_level -|= 1;
    }
    fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.writer.writeAll(self.config.indentString);
        }
    }

    pub fn print(self: *Self, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        if (self.config.processNewLine) {
            const res = try std.fmt.allocPrint(allocator, fmt, args);
            defer allocator.free(res);

            var iter = std.mem.splitScalar(u8, res, '\n');
            while (iter.next()) |str| {
                if (str.len != 0) {
                    try self.writeIndent();
                    _ = try self.writer.write(str);
                }

                const last = iter.peek() == null;

                if (last == false) {
                    try self.writer.writeByte('\n');
                }
            }
        } else {
            try self.writer.print(fmt, args);
        }

        if (self.config.autoFlush) {
            try self.flush();
        }
    }

    pub fn printStyled(self: *Self, allocator: std.mem.Allocator, style: Style, comptime fmt: []const u8, args: anytype) !void {
        const prev_style = try self.fetchSetStyle(style);

        try self.print(allocator, fmt, args);

        if (prev_style) |s| try self.applyStyle(s) else try self.resetStyle();
    }

    pub fn flush(self: *Self) !void {
        try self.writer.flush();
    }
};
