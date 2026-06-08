const std = @import("std");
const args_ = @import("args.zig");
const term = @import("terminal.zig");

pub fn CommandWithContext(comptime AppContext: type) type {
    return struct {
        const CommandT = @This();

        pub const Context = struct {
            gpa: std.mem.Allocator,

            values: std.StringHashMapUnmanaged(FlagPayload),
            app: AppContext,
            args: []const []const u8,
            positional: usize,
            rootCmd: *CommandT,
            currentCmd: *CommandT,

            pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
                self.values.deinit(gpa);
            }

            pub fn getValue(self: *const Context, name: []const u8) ?FlagPayload {
                return self.values.get(name);
            }

            pub fn has(self: *const Context, name: []const u8) bool {
                return self.values.contains(name);
            }

            pub fn getValueT(
                self: *const Context,
                name: []const u8,
                comptime kind: FlagType,
            ) ?@FieldType(FlagPayload, @tagName(kind)) {
                const val = self.getValue(name) orelse return null;
                if (std.meta.activeTag(val) != kind) return null;
                return @field(val, @tagName(kind));
            }
        };

        const RunFn = *const fn (ctx: *const Context) anyerror!RunResult;

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
            description: ?[]const u8 = null,
            customUsage: ?[]const u8 = null,
            examples: ?[]const ExampleDesc = null,

            // callbacks
            onPersistentPreRun: ?RunFnOption = .inherit,
            onPreRun: ?RunFnOption = null,
            onRun: ?RunFnOption = null,
            onPersistentPostRun: ?RunFnOption = .inherit,
            onPostRun: ?RunFnOption = null,

            allowUnknownFlags: bool = false,
        };

        arena: std.heap.ArenaAllocator,
        parent: ?*CommandT,
        name: []const u8,
        brief: []const u8,
        description: ?[]const u8,
        customUsage: ?[]const u8,
        examples: ?[]const ExampleDesc,

        subcommands: std.StringHashMapUnmanaged(*CommandT),
        /// All registered flags indexed by canonical name
        flags: std.ArrayList(Flag),
        positional: ?[]const []const u8,
        /// canonical flag name -> flags index
        nameIndex: std.StringHashMapUnmanaged(usize),
        /// --long-name -> flags index
        longAliases: std.StringHashMapUnmanaged(usize),
        /// -s (single byte) -> flags index
        shortAliases: std.AutoHashMapUnmanaged(u8, usize),

        /// callbacks
        preRun: ?RunFn,
        persistentPreRun: ?RunFn,
        run: ?RunFn,
        postRun: ?RunFn,
        persistentPostRun: ?RunFn,

        allowUnknownFlags: bool,

        diagnostic: ?*Diagnostic = null,

        fn setup(out: *CommandT, gpa: std.mem.Allocator, options: Options, parent: ?*CommandT) !void {
            out.diagnostic = null;

            out.arena = std.heap.ArenaAllocator.init(gpa);
            errdefer out.arena.deinit();

            const alloc = out.arena.allocator();

            out.name = options.name;
            out.brief = options.brief;
            out.description = options.description;
            out.examples = options.examples;

            // crazy shit that resolves option callback to callback
            inline for (
                .{
                    &out.persistentPreRun,
                    &out.preRun,
                    &out.run,
                    &out.persistentPostRun,
                    &out.postRun,
                },
                .{
                    options.onPersistentPreRun,
                    options.onPreRun,
                    options.onRun,
                    options.onPersistentPostRun,
                    options.onPostRun,
                },
                .{
                    if (parent) |p| p.persistentPreRun else null,
                    if (parent) |p| p.preRun else null,
                    if (parent) |p| p.run else null,
                    if (parent) |p| p.persistentPostRun else null,
                    if (parent) |p| p.postRun else null,
                },
            ) |outCb, inCb, parCb| {
                outCb.* = if (inCb) |o| switch (o) {
                    .custom => |v| v,
                    .inherit => if (parCb) |cb| cb else null,
                } else null;
            }

            out.allowUnknownFlags = options.allowUnknownFlags;

            out.flags = try .initCapacity(alloc, 0);
            out.nameIndex = .empty;
            out.longAliases = .empty;
            out.shortAliases = .empty;
            out.subcommands = .empty;
            out.parent = parent;
        }

        pub fn init(gpa: std.mem.Allocator, options: Options) !*CommandT {
            const out = try gpa.create(CommandT);
            errdefer gpa.destroy(out);

            try setup(out, gpa, options, null);

            return out;
        }

        pub fn initSub(self: *CommandT, options: Options) !*CommandT {
            const out = try self.arena.allocator().create(CommandT);
            errdefer self.arena.allocator().destroy(out);

            try setup(out, self.arena.allocator(), options, self);

            try self.subcommands.put(self.arena.allocator(), options.name, out);

            return out;
        }

        pub fn deinit(self: *CommandT) void {
            const alloc = self.arena.allocator();
            self.flags.deinit(alloc);
            self.nameIndex.deinit(alloc);
            self.longAliases.deinit(alloc);
            self.shortAliases.deinit(alloc);
            var it = self.subcommands.valueIterator();
            while (it.next()) |entry| entry.*.deinit();
            self.subcommands.deinit(self.arena.allocator());
            self.arena.deinit();
        }

        pub fn root(self: *CommandT) *CommandT {
            var curr = self;

            while (curr.parent) |par| {
                curr = par;
            }

            return curr;
        }

        /// Look up a flag by canonical name, long alias, or short char.
        /// If inheritedOnly is true, only returns flags marked global — used when
        /// walking up the parent chain so subcommands only inherit global flags.
        const FlagId = union(enum) {
            canonical: []const u8,
            long: []const u8,
            short: u8,
        };

        pub fn getFlag(self: *const CommandT, id: FlagId, inheritedOnly: bool) ?Flag {
            const index = switch (id) {
                .canonical => |v| self.nameIndex.get(v),
                .long => |v| self.longAliases.get(v),
                .short => |v| self.shortAliases.get(v),
            };

            if (index) |idx| {
                std.debug.assert(idx < self.flags.items.len);

                const flag = self.flags.items[idx];

                if (!inheritedOnly or flag.global) {
                    return flag;
                }
            }

            if (self.parent) |parent| {
                return parent.getFlag(id, true);
            }

            return null;
        }

        fn executePreRun(self: *CommandT, ctx: *const Context) !RunResult {
            if (self.preRun) |cb| {
                return try cb(ctx);
            }

            return .ok;
        }

        fn executePersistentPreRun(self: *CommandT, ctx: *const Context) !RunResult {
            if (self.persistentPreRun) |cb| {
                const res = try cb(ctx);

                if (res != .ok)
                    return res;
            }

            if (self.parent) |par| {
                return try par.executePersistentPreRun(ctx);
            }

            return .ok;
        }

        fn executeRun(self: *CommandT, ctx: *const Context) !RunResult {
            if (self.run) |cb| {
                return try cb(ctx);
            }
            return .ok;
        }

        fn executePostRun(self: *CommandT, ctx: *const Context) !RunResult {
            if (self.postRun) |cb| {
                return try cb(ctx);
            }
            return .ok;
        }

        fn executePersistentPostRun(self: *CommandT, ctx: *const Context) !RunResult {
            if (self.persistentPostRun) |cb| {
                const res = try cb(ctx);

                if (res != .done)
                    return res;
            }
            if (self.parent) |par| {
                return try par.executePersistentPostRun(ctx);
            }
            return .ok;
        }

        pub fn setCustomUsage(self: *CommandT, positionals: []const []const u8) void {
            self.positional = positionals;
        }

        pub fn commandError(self: *CommandT, diag: Diagnostic) CommandError {
            if (self.diagnostic) |out| {
                out.* = diag;
            }

            return CommandError.CommandFailed;
        }

        pub fn registerFlag(self: *CommandT, flag: Flag) !void {
            if (flag.long == null and flag.short == null) return error.InvalidOptions;

            const idx = self.flags.items.len;
            try self.flags.append(self.arena.allocator(), flag);

            try self.nameIndex.put(self.arena.allocator(), flag.name, idx);
            if (flag.long) |l| try self.longAliases.put(self.arena.allocator(), l, idx);
            if (flag.short) |s| try self.shortAliases.put(self.arena.allocator(), s, idx);
        }

        pub fn addFlag(self: *CommandT, options: FlagOptions, flagType: FlagType) !void {
            const long: ?[]const u8 = if (options.long) |l| switch (l) {
                .auto => options.name,
                .custom => |v| v,
            } else null;

            const short: ?u8 = if (options.short) |s| switch (s) {
                .auto => options.name[0],
                .custom => |v| v,
            } else null;

            try self.registerFlag(.{
                .name = options.name,
                .global = options.global,
                .long = long,
                .short = short,
                .type = flagType,
                .paramName = options.paramName,
                .bind = null,
            });
        }

        pub fn bindFlag(self: *CommandT, options: FlagOptions, ptr: anytype) !void {
            const flagType = flagTypeFromBind(ptr);

            const long: ?[]const u8 = if (options.long) |l| switch (l) {
                .auto => options.name,
                .custom => |v| v,
            } else null;

            const short: ?u8 = if (options.short) |s| switch (s) {
                .auto => options.name[0],
                .custom => |v| v,
            } else null;

            try self.registerFlag(.{
                .name = options.name,
                .global = options.global,
                .long = long,
                .short = short,
                .type = flagType,
                .paramName = options.paramName,
                .bind = @ptrCast(ptr),
            });
        }

        fn parseArgs(
            self: *CommandT,
            gpa: std.mem.Allocator,
            args: []const []const u8,
            userData: AppContext,
        ) !Context {
            if (args.len > 0) {
                if (self.subcommands.get(args[0])) |sub| {
                    return try sub.parseArgs(gpa, args[1..], userData);
                }
            }

            var ctx: Context = .{
                .gpa = gpa,
                .values = .empty,
                .app = userData,
                .args = args,
                .positional = 0,
                .rootCmd = self.root(),
                .currentCmd = self,
            };

            var parser = args_.Parser.init(args);
            var posEnd = false;

            while (parser.next()) |tok| {
                switch (tok.payload) {
                    .string => {
                        if (posEnd) { // TODO: invalid error type
                            return self.commandError(
                                .{
                                    .UnknownFlag = .{
                                        .input = tok.text,
                                    },
                                },
                            );
                        }
                        ctx.positional += 1;
                    },

                    .long => |name| {
                        const flag = self.getFlag(.{ .long = name }, false) orelse {
                            if (self.allowUnknownFlags) {
                                ctx.positional += 1;
                                continue;
                            }
                            return self.commandError(
                                .{
                                    .UnknownFlag = .{
                                        .input = tok.text,
                                    },
                                },
                            );
                        };

                        posEnd = true;

                        if (ctx.values.contains(flag.name)) {
                            return self.commandError(
                                .{
                                    .DuplicateFlag = .{
                                        .flagName = flag.name,
                                    },
                                },
                            );
                        }

                        switch (flag.type) {
                            .bool => {
                                try ctx.values.putNoClobber(
                                    gpa,
                                    flag.name,
                                    .{ .bool = true },
                                );
                                if (flag.bind) |ptr| {
                                    Flag.castPtr(ptr, .bool).* = true;
                                }
                            },
                            inline else => |t| {
                                const value = blk: {
                                    if (parser.nextAs(flagTypeToArg(t))) |out| {
                                        if (out[1]) |val|
                                            break :blk val
                                        else |_|
                                            return self.commandError(
                                                .{
                                                    .InvalidFlagType = .{
                                                        .flagName = flag.name,
                                                        .input = out[0],
                                                        .expected = flag.type,
                                                    },
                                                },
                                            );
                                    } else return self.commandError(
                                        .{
                                            .UnexpectedEnd = .{
                                                .flagName = flag.name,
                                                .expected = flag.type,
                                            },
                                        },
                                    );
                                };

                                try ctx.values.putNoClobber(
                                    gpa,
                                    flag.name,
                                    @unionInit(
                                        FlagPayload,
                                        @tagName(t),
                                        value,
                                    ),
                                );

                                if (flag.bind) |ptr| {
                                    Flag.castPtr(ptr, t).* = value;
                                }
                            },
                        }
                    },
                    .short => |short| {
                        const all_known = blk: {
                            var all_known = true;
                            for (short.flags) |flagShort| {
                                if (self.getFlag(.{ .short = flagShort }, false) == null) {
                                    all_known = false;
                                    break;
                                }
                            }
                            break :blk all_known;
                        };

                        if (!all_known) {
                            if (self.allowUnknownFlags) {
                                ctx.positional += 1;
                            } else {
                                return self.commandError(
                                    .{
                                        .UnknownFlag = .{
                                            .input = tok.text,
                                        },
                                    },
                                );
                            }
                        }
                        posEnd = true;

                        // handle flags

                        for (short.flags) |flagShort| {
                            const flag = self.getFlag(.{ .short = flagShort }, false).?; // assert not null, as checked before

                            if (flag.type != .bool) {
                                return self.commandError(
                                    .{
                                        .InvalidFlagType = .{
                                            .flagName = flag.name,
                                            .input = tok.text,
                                            .expected = .bool,
                                        },
                                    },
                                );
                            }

                            if (ctx.values.contains(flag.name)) {
                                return self.commandError(
                                    .{
                                        .DuplicateFlag = .{
                                            .flagName = flag.name,
                                        },
                                    },
                                );
                            }

                            try ctx.values.putNoClobber(
                                gpa,
                                flag.name,
                                .{ .bool = true },
                            );
                        }

                        // handle last

                        const flag = self.getFlag(.{ .short = short.last }, false) orelse {
                            return self.commandError(
                                .{
                                    .UnknownFlag = .{ .input = tok.text },
                                },
                            );
                        };

                        if (ctx.values.contains(flag.name)) {
                            return self.commandError(
                                .{
                                    .DuplicateFlag = .{ .flagName = flag.name },
                                },
                            );
                        }

                        switch (flag.type) {
                            .bool => {
                                try ctx.values.putNoClobber(gpa, flag.name, .{ .bool = true });
                                if (flag.bind) |ptr| {
                                    Flag.castPtr(ptr, .bool).* = true;
                                }
                            },
                            inline else => |t| {
                                const value = blk: {
                                    if (parser.nextAs(flagTypeToArg(t))) |out| {
                                        if (out[1]) |val| {
                                            break :blk val;
                                        } else |_| {
                                            return self.commandError(.{
                                                .InvalidFlagType = .{
                                                    .flagName = flag.name,
                                                    .input = out[0],
                                                    .expected = flag.type,
                                                },
                                            });
                                        }
                                    } else {
                                        return self.commandError(
                                            .{
                                                .UnexpectedEnd = .{
                                                    .flagName = flag.name,
                                                    .expected = flag.type,
                                                },
                                            },
                                        );
                                    }
                                };
                                try ctx.values.putNoClobber(
                                    gpa,
                                    flag.name,
                                    @unionInit(FlagPayload, @tagName(t), value),
                                );

                                if (flag.bind) |ptr| {
                                    Flag.castPtr(ptr, t).* = value;
                                }
                            },
                        }
                    },
                }
            }

            return ctx;
        }

        pub fn executeThis(
            self: *CommandT,
            gpa: std.mem.Allocator,
            args: []const []const u8,
            userData: AppContext,
            diag: ?*Diagnostic,
        ) !void {
            std.debug.assert(self.diagnostic == null);

            self.diagnostic = diag;
            defer self.diagnostic = null;

            var ctx = try self.parseArgs(gpa, args[1..], userData);

            const CallbackFn = fn (self: *@This(), ctx: *const Context) anyerror!RunResult;

            const callbacks = [_]CallbackFn{
                @This().executePersistentPreRun,
                @This().executePreRun,
                @This().executeRun,
                @This().executePostRun,
                @This().executePersistentPostRun,
            };

            inline for (callbacks) |cb| {
                const result = try cb(ctx.currentCmd, &ctx);

                switch (result) {
                    .done => return,
                    .fail => |err| {
                        return self.commandError(.{ .UserError = err });
                    },
                    .ok => {},
                }
            }
        }

        pub fn execute(
            self: *CommandT,
            gpa: std.mem.Allocator,
            args: []const []const u8,
            appContext: AppContext,
            diag: ?*Diagnostic,
        ) !void {
            try self.root().executeThis(gpa, args, appContext, diag);
        }

        pub fn writeHelp(self: *const CommandT, gpa: std.mem.Allocator, printer: *term.Printer) !void {
            var helpWriter = HelpWriter.init(gpa, printer, self);
            defer helpWriter.deinit();

            try helpWriter.write();
        }

        //================ Help writer ======================

        const HelpWriter = struct {
            arena: std.heap.ArenaAllocator,
            printer: *term.Printer,
            cmd: *const CommandT,

            pub fn init(
                gpa: std.mem.Allocator,
                printer: *term.Printer,
                cmd: *const CommandT,
            ) HelpWriter {
                return .{
                    .arena = std.heap.ArenaAllocator.init(gpa),
                    .printer = printer,
                    .cmd = cmd,
                };
            }

            pub fn deinit(self: *HelpWriter) void {
                self.arena.deinit();
            }

            fn write(self: *HelpWriter) !void {
                try self.writeBrief();

                try self.writeCommands();

                try self.writeFlags();

                try self.writeExamples();

                try self.printer.print("\n", .{});
            }

            const offset = 10;

            fn writeBrief(self: *HelpWriter) !void {
                try self.printer.printStyled(
                    .{
                        .fg = .white,
                    },
                    "{s}\n",
                    .{
                        self.cmd.description orelse self.cmd.brief,
                    },
                );
                try self.printer.printStyled(.{ .fg = .yellow }, "\nUsage:\n", .{});

                self.printer.indent();
                defer self.printer.detend();

                try self.printer.printStyled(.{ .fg = .green }, "{s}", .{self.cmd.name});
                try self.printer.printStyled(.{ .fg = .cyan }, " [COMMAND] [OPTIONS]...\n", .{});
            }

            fn writeCommands(self: *HelpWriter) !void {
                if (self.cmd.subcommands.size == 0) return;

                const width = blk: {
                    var iter = self.cmd.subcommands.valueIterator();
                    var max: usize = 0;
                    while (iter.next()) |sub| {
                        max = @max(max, sub.*.name.len);
                    }
                    break :blk @max(10, max + offset);
                };

                try self.printer.printStyled(.{ .fg = .yellow }, "\nCommands:\n", .{});
                var iter = self.cmd.subcommands.valueIterator();

                self.printer.indent();
                defer self.printer.detend();

                while (iter.next()) |cmd| {
                    try self.printer.printStyled(.{ .fg = .green }, "{[name]s: <[width]}", .{
                        .name = cmd.*.name,
                        .width = width,
                    });
                    try self.printer.printStyled(.{ .fg = .white }, " {[brief]s}\n", .{
                        .brief = cmd.*.brief,
                    });
                }
            }

            fn writeFlags(self: *HelpWriter) !void {
                // get local and global indices
                const gpa = self.arena.allocator();

                const localIndices, const globalIndices, const allIndices = blk: {
                    var localCount: usize = 0;
                    var globalCount: usize = 0;

                    var list = try gpa.alloc(usize, self.cmd.flags.items.len);

                    for (self.cmd.flags.items, 0..) |flag, idx| {
                        if (flag.global) {
                            list[list.len - (globalCount + 1)] = idx;
                            globalCount += 1;
                        } else {
                            list[localCount] = idx;
                            localCount += 1;
                        }
                    }

                    break :blk .{ list[0..localCount], list[localCount..], list };
                };
                defer gpa.free(allIndices);

                const indicesGroups = .{ localIndices, globalIndices };

                inline for (indicesGroups, 0..) |indices, groupIdx| {
                    if (indices.len != 0) {
                        var flagDefs = try std.ArrayList([]const u8).initCapacity(gpa, indices.len);
                        defer flagDefs.deinit(gpa);

                        const width = blk: {
                            var max: usize = 0;

                            for (indices) |idx| {
                                const flag = &self.cmd.flags.items[idx];
                                const def = try self.flagDefinition(flag);
                                max = @max(max, def.len);
                                flagDefs.appendAssumeCapacity(def);
                            }

                            break :blk @max(10, max + offset);
                        };

                        const header = switch (groupIdx) {
                            0 => "Options",
                            1 => "Global options",
                            else => unreachable,
                        };

                        try self.printer.printStyled(.{ .fg = .yellow }, "\n{s}:\n", .{header});

                        for (indices, flagDefs.items) |idx, def| {
                            const flag = &self.cmd.flags.items[idx];

                            self.printer.indent();
                            defer self.printer.detend();
                            try self.printer.printStyled(.{ .fg = .green }, "{[def]s: <[width]}", .{
                                .def = def,
                                .width = width,
                            });

                            try self.printer.printStyled(.{ .fg = .white }, " {s}\n", .{flag.name}); // TODO: replace flag.name with flag.brief
                        }
                    }
                }
            }

            fn writeExamples(self: *HelpWriter) !void {
                if (self.cmd.examples) |examples| {
                    try self.printer.printStyled(.{ .fg = .yellow }, "\nExamples:\n", .{});

                    for (examples) |example| {
                        self.printer.indent();
                        defer self.printer.detend();

                        try self.printer.printStyled(.{ .fg = .white }, "{s}\n", .{example[0]});
                    }
                }
            }

            fn flagDefinition(self: *HelpWriter, flag: *const Flag) ![]const u8 {
                const alloc = self.arena.allocator();
                var buf = try std.ArrayList(u8).initCapacity(alloc, flag.name.len);

                if (flag.short) |short| {
                    try buf.appendSlice(alloc, &.{ '-', short });
                }

                if (flag.long) |long| {
                    if (buf.items.len != 0) {
                        try buf.appendSlice(alloc, ", ");
                    }

                    const tmp = try alloc.alloc(u8, 2 + long.len);
                    defer alloc.free(tmp);

                    const str = try std.fmt.bufPrint(tmp, "--{s}", .{long});

                    try buf.appendSlice(alloc, str);
                }

                const pName = if (flag.paramName) |pName| pName else switch (flag.type) {
                    .string => "string",
                    .int => "integer",
                    .number => "number",
                    else => null,
                };

                if (pName) |name| {
                    if (buf.items.len != 0) {
                        try buf.append(alloc, ' ');
                    }

                    const tmp = try alloc.alloc(u8, 2 + name.len);
                    defer alloc.free(tmp);

                    const str = try std.fmt.bufPrint(tmp, "<{s}>", .{name});

                    try buf.appendSlice(alloc, str);
                }

                return try buf.toOwnedSlice(alloc);
            }
        };
    };
}

pub const Command = CommandWithContext(std.process.Init);

pub const CommandError = error{
    CommandFailed,
} || std.mem.Allocator.Error;

pub const Diagnostic = union(enum) {
    UnknownFlag: struct {
        input: []const u8,
    },
    InvalidFlagType: struct {
        flagName: []const u8,
        input: []const u8,
        expected: FlagType,
    },
    DuplicateFlag: struct {
        flagName: []const u8,
    },
    UnexpectedEnd: struct {
        flagName: []const u8,
        expected: FlagType,
    },
    UserError: ErrorInfo,

    pub fn toMessage(self: *const Diagnostic, gpa: std.mem.Allocator) !struct {
        message: ?[]const u8,
        code: u8,
    } {
        return switch (self.*) {
            .UnknownFlag => |f| .{
                .message = try std.fmt.allocPrint(gpa, "unknown flag '{s}'", .{f.input}),
                .code = 1,
            },
            .InvalidFlagType => |f| .{
                .message = try std.fmt.allocPrint(gpa, "invalid '{s}' flag type, got '{s}' expected '{s}'", .{
                    f.flagName, f.input, @tagName(f.expected),
                }),
                .code = 1,
            },
            .DuplicateFlag => |f| .{
                .message = try std.fmt.allocPrint(gpa, "duplicate flag '{s}'", .{f.flagName}),
                .code = 1,
            },
            .UnexpectedEnd => |f| .{
                .message = try std.fmt.allocPrint(gpa, "unexpected end, expected '{s}' value for '{s}' flag", .{ @tagName(f.expected), f.flagName }),
                .code = 1,
            },
            .UserError => |f| .{
                .message = f.message,
                .code = f.code,
            },
        };
    }
};

fn flagTypeToArg(comptime kind: FlagType) args_.ArgType {
    return switch (kind) {
        .int => .int,
        .number => .number,
        .string => .string,
        else => unreachable,
    };
}

pub const RunResult = union(enum) {
    ok,
    done,
    fail: ErrorInfo,

    pub fn Fail(statusCode: u8, message: ?[]const u8) RunResult {
        return .{
            .fail = .{
                .code = statusCode,
                .message = message,
            },
        };
    }
};

const ErrorInfo = struct {
    message: ?[]const u8,
    code: u8,
};

pub const ExampleDesc = struct {
    []const u8,
    []const u8,
};

pub const FlagOptions = struct {
    name: []const u8,
    brief: []const u8,

    long: ?union(enum) {
        auto,
        custom: []const u8,
    } = .auto,
    short: ?union(enum) {
        auto,
        custom: u8,
    } = .auto,
    paramName: ?[]const u8 = null,
    global: bool = false,
};

const Flag = struct {
    name: []const u8,
    global: bool,
    long: ?[]const u8,
    short: ?u8,
    type: FlagType,
    paramName: ?[]const u8,
    bind: ?*anyopaque,

    pub fn castPtr(ptr: *anyopaque, comptime kind: FlagType) *@FieldType(FlagPayload, @tagName(kind)) {
        return @ptrCast(@alignCast(ptr));
    }
};

fn flagTypeFromBind(ptr: anytype) FlagType {
    const T = @TypeOf(ptr);
    const ti = @typeInfo(T);

    if (ti != .pointer) @compileError("bind must be a pointer");
    if (ti.pointer.is_const) @compileError("bind must not be const");

    const ft: FlagType = inline for (@typeInfo(FlagPayload).@"union".fields, 0..) |f, idx| {
        if (f.type == ti.pointer.child) break @enumFromInt(idx);
    } else @compileError("unsupported bind type — must be *bool, *i64, *f64, or *[]const u8");

    return ft;
}

pub const Bool = bool;
pub const Int = i64;
pub const Number = f64;
pub const String = []const u8;

pub const FlagType = enum {
    bool,
    int,
    number,
    string,
};

const FlagPayload = union(FlagType) {
    bool: Bool,
    int: Int,
    number: Number,
    string: String,
};
