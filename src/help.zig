const std = @import("std");

const command_mod = @import("command.zig");
const CommandDesc = command_mod.CommandDesc;
const Flag = command_mod.FlagDesc;
const terminal = @import("terminal.zig");
const Printer = terminal.Printer;
const Style = terminal.Style;
//================ Help writer ======================

pub const HelpWriter = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    printer: *Printer,
    desc: *const CommandDesc,

    const Theme = struct {
        const head: Style = .{ .bold = true, .fg = .yellow };
        const name: Style = .{ .fg = .green };
        const body: Style = .{ .fg = .cyan };
        const desc: Style = .{ .fg = .white };
    };

    pub fn init(
        allocator: std.mem.Allocator,
        printer: *Printer,
        desc: *const CommandDesc,
    ) HelpWriter {
        return .{
            .allocator = allocator,
            .arena = .init(allocator),
            .printer = printer,
            .desc = desc,
        };
    }
    pub fn deinit(self: *HelpWriter) void {
        self.arena.deinit();
    }

    pub fn write(self: *HelpWriter) !void {
        try self.writeBrief();

        try self.writeCommands();

        try self.writeFlags();

        try self.printer.print(self.allocator, "\n", .{});
    }

    const offset = 10;

    fn writeBrief(self: *HelpWriter) !void {
        try self.printer.printStyled(
            self.allocator,
            .{
                .fg = .white,
            },
            "{s}\n",
            .{self.desc.brief},
        );
        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .yellow },
            "\nUsage:\n",
            .{},
        );

        self.printer.indent();
        defer self.printer.detend();

        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .green },
            "{s}",
            .{self.desc.name},
        );

        try self.printer.printStyled(
            self.allocator,
            .{ .fg = .cyan },
            " [COMMAND] [OPTIONS]...\n",
            .{},
        );
    }

    fn writeCommands(self: *HelpWriter) !void {
        if (self.desc.subcommands.count() == 0) return;

        const width = blk: {
            var iter = self.desc.subcommands.valueIterator();
            var max: usize = 0;
            while (iter.next()) |sub| {
                max = @max(max, sub.*.name.len);
            }
            break :blk @max(10, max + offset);
        };

        try self.printer.printStyled(self.allocator, .{ .fg = .yellow }, "\nCommands:\n", .{});
        var iter = self.desc.subcommands.valueIterator();

        self.printer.indent();
        defer self.printer.detend();

        while (iter.next()) |cmd| {
            try self.printer.printStyled(
                self.allocator,
                .{ .fg = .green },
                "{[name]s: <[width]}",
                .{
                    .name = cmd.*.name,
                    .width = width,
                },
            );
            try self.printer.printStyled(
                self.allocator,
                .{ .fg = .white },
                " {[brief]s}\n",
                .{
                    .brief = cmd.*.brief,
                },
            );
        }
    }

    fn collectLocalFlags(self: *HelpWriter) ![]*Flag {
        var count: usize = 0;
        for (self.desc.flags.items) |flag| {
            if (flag.global == false)
                count += 1;
        }

        const out = try self.arena.allocator().alloc(*Flag, count);
        var curr: usize = 0;

        for (self.desc.flags.items) |*flag| {
            if (flag.global == false) {
                out[curr] = flag;
                curr += 1;
            }
        }
        std.debug.assert(out.len == curr);

        return out;
    }
    fn collectGlobalFlags(self: *HelpWriter) ![]*Flag {
        const out = blk: {
            var count: usize = 0;

            var curr: ?*const CommandDesc = self.desc;

            while (curr) |c| {
                for (c.flags.items) |flag| {
                    if (flag.global)
                        count += 1;
                }

                curr = c.parent;
            }
            break :blk try self.arena.allocator().alloc(*Flag, count);
        };

        var index: usize = 0;
        var curr: ?*const CommandDesc = self.desc;

        while (curr) |c| {
            for (c.flags.items) |*flag|
                if (flag.global) {
                    out[index] = flag;
                    index += 1;
                };

            curr = c.parent;
        }

        std.debug.assert(index == out.len);

        return out;
    }

    fn writeTheFlags(self: *HelpWriter, comptime head: []const u8, flags: []*Flag) !void {
        if (flags.len == 0) {
            return;
        }

        var buffer: [50]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);

        const precomputed_names = try self.arena.allocator().alloc([]const u8, flags.len);
        const names_column_width = blk: {
            var max: usize = 0;
            for (flags, 0..) |flag, idx| {
                if (flag.short) |short| {
                    try w.print("-{c}", .{short});
                } else {
                    try w.print(" " ** 4, .{});
                }

                if (flag.long) |long| {
                    if (flag.short) |_| {
                        try w.print(", ", .{});
                    }
                    try w.print("--{s}", .{long});
                }
                const name = try self.arena.allocator().dupe(u8, w.buffered());
                defer _ = w.consumeAll();
                max = @max(name.len, max);
                precomputed_names[idx] = name;
            }
            break :blk max;
        };

        const precomputed_type_names = try self.arena.allocator().alloc(?[]const u8, flags.len);
        const type_column_width = blk: {
            var max: usize = 0;

            for (flags, 0..) |flag, idx| {
                switch (flag.type) {
                    .flag => {
                        precomputed_type_names[idx] = null;
                    },
                    else => |tag| {
                        const type_name = @tagName(tag);
                        try w.print("<{s}>", .{type_name});

                        const result = try self.arena.allocator().dupe(u8, w.buffered());
                        defer _ = w.consumeAll();

                        max = @max(result.len, max);
                        precomputed_type_names[idx] = result;
                    },
                }
            }
            break :blk max;
        };

        try self.printer.printStyled(self.allocator, Theme.head, "\n{s}:", .{head});

        self.printer.indent();
        defer self.printer.detend();

        for (flags, 0..) |flag, idx| {
            try self.printer.printStyled(self.allocator, Theme.name, "\n{[name]s: <[width]}", .{
                .name = precomputed_names[idx],
                .width = names_column_width,
            });

            try self.printer.printStyled(
                self.allocator,
                Theme.body,
                "{[name]s: <[width]}",
                .{
                    .name = precomputed_type_names[idx] orelse "",
                    .width = type_column_width,
                },
            );
            try self.printer.printStyled(self.allocator, Theme.desc, "{s}", .{flag.brief});
        }
    }
    fn writeFlags(self: *HelpWriter) !void {
        // get local and global indices

        // -s, --long | <value> | desc

        const local = try self.collectLocalFlags();

        try self.writeTheFlags("Options", local);

        const global = try self.collectGlobalFlags();

        try self.writeTheFlags("Global options", global);
    }
};

test "help no crash" {
    const test_data = @import("test_data.zig");

    const cmd = try test_data.GitCommand(std.testing.allocator);
    defer cmd.destroy();

    var aw = std.Io.Writer.Discarding.init(&.{});
    const w = &aw.writer;

    var printer = Printer.initConfig(w, .{ .colored = false });

    var help_writer = HelpWriter.init(std.testing.allocator, &printer, &cmd.desc);
    defer help_writer.deinit();
    try help_writer.write();
}
