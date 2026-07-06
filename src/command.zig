const std = @import("std");
const Reader = @import("reader.zig");

const term = @import("terminal.zig");
const Printer = term.Printer;

const argument = @import("argument.zig");

const UnknownFlagBehaviour = enum {
    @"error",
    as_positional,
};

pub const CommandDesc = struct {
    parent: ?*CommandDesc,
    subcommands: std.StringHashMapUnmanaged(*CommandDesc),

    name: []const u8,
    brief: []const u8,

    unknown_flag_behaviour: UnknownFlagBehaviour,

    flags: std.ArrayList(FlagDesc),
    name_map: std.array_hash_map.String(usize),
    long_map: std.array_hash_map.String(usize),
    short_map: std.array_hash_map.Auto(u8, usize),

    fn asCommandPtr(self: *CommandDesc, comptime AppContext: type) *CommandWithContext(AppContext) {
        return @fieldParentPtr("desc", self);
    }
    fn asCommandConstPtr(self: *const CommandDesc, comptime AppContext: type) *const CommandWithContext(AppContext) {
        return @fieldParentPtr("desc", self);
    }
};

pub fn CommandWithContext(comptime AppContext: type) type {
    return struct {
        const CommandT = @This();

        pub const Context = struct {
            args: []const []const u8,
            values: std.array_hash_map.String(argument.Payload),

            app: AppContext,

            root: *CommandT,
            current: *CommandT,
            done: *bool,

            pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
                self.values.deinit(gpa);
            }

            pub fn getValue(self: *const Context, name: []const u8) ?argument.Payload {
                return self.values.get(name);
            }

            pub fn has(self: *const Context, name: []const u8) bool {
                return self.values.contains(name);
            }

            pub fn stop(self: *const Context) void {
                self.done.* = true;
            }

            pub fn getValueT(
                self: *const Context,
                name: []const u8,
                comptime kind: argument.Type,
            ) ?@FieldType(argument.Payload, @tagName(kind)) {
                const val = self.getValue(name) orelse return null;
                if (std.meta.activeTag(val) != kind) return null;
                return @field(val, @tagName(kind));
            }
        };

        const RunFn = *const fn (ctx: *const Context) anyerror!void;

        pub const Options = struct {
            const RunFnOption = union(enum) {
                inherit,
                custom: RunFn,

                pub fn set(cb: RunFn) RunFnOption {
                    return .{ .custom = cb };
                }
            };

            name: []const u8,
            brief: []const u8,

            unknown_flag_behaviour: UnknownFlagBehaviour = .@"error",
            // callbacks
            persistent_pre_run: ?RunFnOption = .inherit,
            pre_run: ?RunFnOption = null,
            run: ?RunFnOption = null,
            persistent_post_run: ?RunFnOption = .inherit,
            post_run: ?RunFnOption = null,
        };

        arena: std.heap.ArenaAllocator,

        desc: CommandDesc,
        /// callbacks
        pre_run: ?RunFn,
        persistent_pre_run: ?RunFn,
        run: ?RunFn,
        post_run: ?RunFn,
        persistent_post_run: ?RunFn,

        fn setup(out: *CommandT, gpa: std.mem.Allocator, options: Options, parent: ?*CommandT) !void {
            out.arena = std.heap.ArenaAllocator.init(gpa);
            errdefer out.arena.deinit();

            out.desc = .{
                .parent = if (parent) |p| &p.desc else null,
                .subcommands = .empty,

                .name = options.name,
                .brief = options.brief,

                .unknown_flag_behaviour = options.unknown_flag_behaviour,

                .flags = .empty,
                .name_map = .empty,
                .long_map = .empty,
                .short_map = .empty,
            };

            // crazy shit that resolves option callback to callback

            const fields: []const []const u8 = &.{ "persistent_pre_run", "pre_run", "run", "persistent_post_run", "post_run" };

            inline for (fields) |field| {
                const in: ?Options.RunFnOption = @field(options, field);

                @field(out, field) = if (in) |i| switch (i) {
                    .custom => |v| v,
                    .inherit => if (parent) |p| @field(p.*, field) else null,
                } else null;
            }
        }

        pub fn create(gpa: std.mem.Allocator, options: Options) !*CommandT {
            const out = try gpa.create(CommandT);
            errdefer gpa.destroy(out);

            try setup(out, gpa, options, null);

            return out;
        }

        pub fn createSub(self: *CommandT, options: Options) !*CommandT {
            const out = try self.arena.allocator().create(CommandT);
            errdefer self.arena.allocator().destroy(out);

            try setup(out, self.arena.allocator(), options, self);

            try self.desc.subcommands.put(self.arena.allocator(), options.name, &out.desc);

            return out;
        }

        /// deinits itself and subcommands then destroy itself,
        /// use on root command only!
        pub fn destroy(self: *CommandT) void {
            std.debug.assert(self.desc.parent == null);

            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self);
        }

        fn rootImpl(self: anytype) @TypeOf(self) {
            const T = @TypeOf(self);
            var curr = self;

            while (curr.desc.parent) |par| {
                curr = if (@typeInfo(T).pointer.is_const)
                    par.asCommandConstPtr(AppContext)
                else
                    par.asCommandPtr(AppContext);
            }

            return curr;
        }

        pub fn root(self: *CommandT) *CommandT {
            return self.rootImpl();
        }

        pub fn rootConst(self: *const CommandT) *const CommandT {
            return self.rootImpl();
        }

        fn executePreRun(self: *const CommandT, ctx: *const Context) anyerror!void {
            if (self.pre_run) |cb| {
                try cb(ctx);
            }
        }

        fn executePersistentPreRun(self: *const CommandT, ctx: *const Context) anyerror!void {
            if (self.persistent_pre_run) |cb| {
                try cb(ctx);

                if (ctx.done.*)
                    return;
            }

            if (self.desc.parent) |par| {
                try par.asCommandPtr(AppContext).executePersistentPreRun(ctx);
            }
        }

        fn executeRun(self: *const CommandT, ctx: *const Context) anyerror!void {
            if (self.run) |cb| {
                try cb(ctx);
            }
        }

        fn executePostRun(self: *const CommandT, ctx: *const Context) anyerror!void {
            if (self.post_run) |cb| {
                try cb(ctx);
            }
        }

        fn executePersistentPostRun(self: *const CommandT, ctx: *const Context) anyerror!void {
            if (self.persistent_post_run) |cb| {
                try cb(ctx);
                if (ctx.done.*)
                    return;
            }

            if (self.desc.parent) |par| {
                try par.asCommandConstPtr(AppContext).executePersistentPostRun(ctx);
            }
        }

        fn installFlag(self: *CommandT, flag: FlagDesc) !void {
            const index = self.desc.flags.items.len;

            try self.desc.flags.append(self.arena.allocator(), flag);

            errdefer {
                _ = self.desc.flags.pop();
                _ = self.desc.name_map.orderedRemove(flag.name);
                if (flag.long) |long| _ = self.desc.long_map.orderedRemove(long);
                if (flag.short) |short| _ = self.desc.short_map.orderedRemove(short);
            }

            if (self.desc.name_map.contains(flag.name))
                return CommandError.DuplicateFlag;

            try self.desc.name_map.put(self.arena.allocator(), flag.name, index);

            if (flag.long) |long| {
                if (self.desc.long_map.contains(long))
                    return CommandError.DuplicateFlagLong;

                try self.desc.long_map.put(self.arena.allocator(), long, index);
            }

            if (flag.short) |short| {
                if (self.desc.short_map.contains(short))
                    return CommandError.DuplicateFlagShort;

                try self.desc.short_map.put(self.arena.allocator(), short, index);
            }
        }

        pub fn addFlag(self: *CommandT, options: FlagOptions, value_type: argument.Type) !void {
            const long = if (options.long) |l|
                switch (l) {
                    .auto => options.name,
                    .custom => |c| c,
                }
            else
                null;

            const short = if (options.short) |s|
                switch (s) {
                    .auto => options.name[0],
                    .custom => |c| c,
                }
            else
                null;

            try self.installFlag(.{
                .name = options.name,
                .brief = options.brief,
                .long = long,
                .short = short,
                .global = options.global,
                .type = value_type,
            });
        }

        /// Look up a flag by canonical name, long alias, or short char.
        /// If inheritedOnly is true, only returns flags marked global — used when
        /// walking up the parent chain so subcommands only inherit global flags.
        const FlagId = union(enum) {
            canonical: []const u8,
            long: []const u8,
            short: u8,
        };

        pub fn getFlag(self: *const CommandT, id: FlagId, global_only: bool) ?*const FlagDesc {
            const index = switch (id) {
                .canonical => |key| self.desc.name_map.get(key),
                .long => |key| self.desc.long_map.get(key),
                .short => |key| self.desc.short_map.get(key),
            };

            if (index) |idx| {
                const flag = &self.desc.flags.items[idx];

                if (global_only == false or flag.global) {
                    return flag;
                }
            }

            if (self.desc.parent) |parent| {
                return parent.asCommandConstPtr(AppContext).getFlag(id, true);
            }

            return null;
        }

        const ParseResult = struct {
            positional: []const []const u8,
            values: std.array_hash_map.String(argument.Payload),
        };

        pub fn parseArgs(
            self: *CommandT,
            allocator: std.mem.Allocator,
            args: []const []const u8,
            diagnostic: *Diagnostic,
        ) !ParseResult {
            var collector: argument.Collector = .empty;
            errdefer collector.deinit(allocator);

            var positionals: usize = 0;
            var positionals_end: bool = false;

            var reader: Reader = .init(args);

            inner: while (reader.read()) |tok| {
                switch (tok.type) {
                    .value => {
                        if (positionals_end) {
                            diagnostic.* = .{
                                .positional_after_flag = .{
                                    .arg = reader.previousArg(),
                                    .after_flag = tok.lexeme,
                                },
                            };
                            return CommandError.InvalidArguments;
                        }
                        positionals += 1;
                    },
                    .long => {
                        const flag = self.getFlag(.{ .long = tok.payload }, false) orelse {
                            switch (self.desc.unknown_flag_behaviour) {
                                .as_positional => {
                                    positionals += 1;
                                    continue :inner;
                                },
                                else => {},
                            }
                            diagnostic.* = .{
                                .unknown_flag = .{
                                    .arg = tok.lexeme,
                                },
                            };
                            return CommandError.InvalidArguments;
                        };
                        positionals_end = true;

                        try collector.interceptNext(allocator, &reader, flag.name, flag.type);
                    },
                    .short => {

                        // check if each known
                        switch (self.desc.unknown_flag_behaviour) {
                            .as_positional => {
                                for (tok.payload) |s| {
                                    const known = self.desc.short_map.contains(s);
                                    if (known == false) {
                                        positionals += 1;
                                        continue :inner;
                                    }
                                }
                            },
                            else => {},
                        }
                        positionals_end = true;

                        const last = tok.payload[tok.payload.len - 1];

                        for (tok.payload[0 .. tok.payload.len - 1]) |f| {
                            const flag = self.getFlag(.{ .short = f }, false) orelse {
                                diagnostic.* = .{
                                    .unknown_flag = .{
                                        .arg = tok.lexeme,
                                    },
                                };
                                return CommandError.InvalidArguments;
                            };

                            if (flag.type != .flag) {
                                diagnostic.* = .{ .invalid_short_flag = .{
                                    .flag = tok.lexeme,
                                    .type = @tagName(tok.type),
                                } };
                                return CommandError.InvalidArguments;
                            }
                            try collector.interceptNext(allocator, &reader, flag.name, .flag);
                        }

                        const flag = self.getFlag(.{ .short = last }, false) orelse {
                            diagnostic.* = .{
                                .unknown_flag = .{
                                    .arg = tok.lexeme,
                                },
                            };
                            return CommandError.InvalidArguments;
                        };

                        try collector.interceptNext(allocator, &reader, flag.name, flag.type);
                    },
                }
            }

            const values = try collector.collect(allocator);

            return .{
                .positional = args[0..positionals],
                .values = values,
            };
        }

        const ResolvedCommand = struct {
            target: *CommandT,
            args: []const []const u8,
        };

        pub fn resolveCommand(self: *CommandT, args: []const []const u8) ResolvedCommand {
            if (args.len > 0)
                if (self.desc.subcommands.get(args[0])) |sub|
                    return sub.asCommandPtr(AppContext).resolveCommand(args[1..]);

            return .{
                .target = self,
                .args = args,
            };
        }

        pub fn call(
            self: *CommandT,
            args: []const []const u8,
            values: std.array_hash_map.String(argument.Payload),
            app: AppContext,
        ) !void {
            const CallSig = *const fn (*CommandT, *const Context) anyerror!void;

            const callfns: [5]CallSig = .{
                executePersistentPreRun,
                executePreRun,
                executeRun,
                executePostRun,
                executePersistentPostRun,
            };

            var done: bool = false;

            const ctx: Context = .{
                .app = app,
                .root = self.root(),
                .current = self,
                .done = &done,
                .args = args,
                .values = values,
            };

            for (callfns) |@"fn"| {
                try @"fn"(self, &ctx);

                if (done)
                    break;
            }
        }

        pub fn execute(
            self: *CommandT,
            allocator: std.mem.Allocator,
            args: []const []const u8,
            diagnostics: *Diagnostic,
            app: AppContext,
        ) !void {
            const cmd = self.resolveCommand(args);

            var pr = try cmd.target.parseArgs(allocator, cmd.args, diagnostics);
            defer pr.values.deinit(allocator);

            try cmd.target.call(pr.positional, pr.values, app);
        }

        pub fn writeHelp(self: *CommandT, printer: *term.Printer) !void {
            const help = @import("help.zig");

            const desc = &self.desc;
            var hw = help.HelpWriter.init(self.arena.allocator(), printer, desc);
            try hw.write();
        }
    };
}

pub const Diagnostic = union(enum) {
    positional_after_flag: struct {
        arg: []const u8,
        after_flag: []const u8,
    },
    unknown_flag: struct {
        arg: []const u8,
    },
    unexpected_end: struct {
        flag: []const u8,
        expected: []const u8,
    },
    invalid_type: struct {
        flag: []const u8,
        value: []const u8,
        expected: []const u8,
    },
    invalid_short_flag: struct {
        flag: []const u8,
        type: []const u8,
    },

    pub fn format(self: *const Diagnostic, w: *std.Io.Writer) !void {
        switch (self.*) {
            .unknown_flag => |data| {
                try w.print("Unknown flag: {s}", .{data.arg});
            },
            else => |t| {
                try w.print("type: {s}", .{@tagName(t)});
            },
        }
    }
};

pub const Command = CommandWithContext(std.process.Init);

pub const CommandError = error{
    DuplicateCommand,
    DuplicateFlag,
    DuplicateFlagLong,
    DuplicateFlagShort,
    InvalidArguments,
    CommandFailed,
} || std.mem.Allocator.Error;

pub const FlagOptions = struct {
    fn NameOption(comptime T: type) type {
        return union(enum) {
            const Self = @This();

            auto,
            custom: T,
        };
    }

    name: []const u8,
    brief: []const u8,

    long: ?NameOption([]const u8) = .auto,
    short: ?NameOption(u8) = .auto,

    global: bool = false,
};

pub const FlagDesc = struct {
    name: []const u8,
    brief: []const u8,
    global: bool,
    long: ?[]const u8,
    short: ?u8,
    type: argument.Type,
    // bind: ?*anyopaque,

    // pub fn castPtr(ptr: *anyopaque, comptime kind: FlagType) *@FieldType(FlagPayload, @tagName(kind)) {
    //     return @ptrCast(@alignCast(ptr));
    // }
};

// fn flagTypeFromBind(ptr: anytype) FlagType {
//     const T = @TypeOf(ptr);
//     const ti = @typeInfo(T);

//     if (ti != .pointer) @compileError("bind must be a pointer");
//     if (ti.pointer.is_const) @compileError("bind must not be const");

//     const ft: FlagType = inline for (@typeInfo(FlagPayload).@"union".fields, 0..) |f, idx| {
//         if (f.type == ti.pointer.child) break @enumFromInt(idx);
//     } else @compileError("unsupported bind type — must be *bool, *i64, *f64, or *[]const u8");

//     return ft;
// }

const TestCommand = CommandWithContext(void);

fn createTestCommand() !*TestCommand {
    const Context = TestCommand.Context;

    const Fns = struct {
        fn Cmd(ctx: *const Context) !void {
            var file = try std.Io.Dir.cwd().createFile(std.testing.io, "test.log", .{
                .truncate = true,
            });
            defer file.close(std.testing.io);

            var buffer: [1024]u8 = undefined;
            var file_writer = file.writer(std.testing.io, &buffer);

            var writer = &file_writer.interface;

            try writer.print("Args:", .{});
            for (ctx.args) |arg| {
                try writer.print(" {s},", .{arg});
            }
            try writer.print("\nValues:", .{});

            var iter = ctx.values.iterator();

            while (iter.next()) |kv| {
                try writer.print("\n\t{s}: {any}", .{ kv.key_ptr.*, kv.value_ptr.* });
            }

            try writer.flush();
        }
    };

    var rootCmd = try TestCommand.create(std.testing.allocator, .{
        .name = "test",
        .brief = "root test command",
    });

    var subCmd = try rootCmd.createSub(.{
        .name = "cmd",
        .brief = "sub test command",
        .run = .{ .custom = &Fns.Cmd },
    });

    try subCmd.addFlag(.{
        .name = "flag",
        .short = null,
        .brief = "just flag",
    }, .flag);

    return rootCmd;
}

test "test command" {
    const cmd = try createTestCommand();
    defer cmd.destroy();

    var diag: Diagnostic = undefined;

    cmd.execute(std.testing.allocator, &.{ "cmd", "pos", "--flag" }, &diag, {}) catch |err| return switch (err) {
        error.InvalidArguments => {
            std.debug.print("{any}\n", .{diag});
        },
        else => err,
    };
}

test "test git command" {
    const test_data = @import("test_data.zig");

    const cmd = try test_data.GitCommand(std.testing.allocator);
    defer cmd.destroy();

    var diag: Diagnostic = undefined;

    const arguments: []const []const []const u8 = &.{
        &.{ "add", "-a" },
        &.{ "add", "file1.txt", "file2.txt" },
        &.{
            "add",
            "src/",
            "tests/",
            "--all",
            "--dry-run",
        },
        &.{
            "add",
            "README.md",
            "-a",
            "--dry-run",
        },
    };

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer {
        aw.deinit();
    }

    const w = &aw.writer;
    var printer = term.Printer.initConfig(w, .{ .colored = false });

    for (arguments) |arg|
        cmd.execute(
            std.testing.allocator,
            arg,
            &diag,
            .{ .printer = &printer },
        ) catch |err| return switch (err) {
            error.InvalidArguments => {
                std.debug.print("error: {f}\n", .{diag});
            },
            else => err,
        };
}

test "test help flag" {
    const test_data = @import("test_data.zig");

    const args: []const []const []const u8 = &.{
        &.{"--help"},
        &.{ "remote", "--help" },
        &.{ "add", "-h" },
    };
    const cmd = try test_data.GitCommand(std.testing.allocator);
    defer cmd.destroy();

    var diag: Diagnostic = undefined;

    var aw = std.Io.Writer.Discarding.init(&.{});
    const w = &aw.writer;

    var printer = Printer.initConfig(w, .{ .colored = false });

    for (args) |arg|
        cmd.execute(
            std.testing.allocator,
            arg,
            &diag,
            .{ .printer = &printer },
        ) catch |err| return switch (err) {
            error.InvalidArguments => {
                std.debug.print("error: {f}\n", .{diag});
            },
            else => err,
        };

    try w.flush();
}

test {
    std.testing.refAllDecls(@import("help.zig"));
}
