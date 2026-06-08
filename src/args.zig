const std = @import("std");

pub const ParseError = error{
    InvalidType,
    Overflow,
};

fn mapError(in: anyerror) ParseError {
    return switch (in) {
        error.InvalidCharacter => ParseError.InvalidType,
        error.Overflow => ParseError.Overflow,
        else => unreachable,
    };
}

pub const Parser = struct {
    args: []const []const u8,
    pos: usize,

    pub fn init(args: []const []const u8) Parser {
        return .{
            .args = args,
            .pos = 0,
        };
    }

    pub fn next(self: *Parser) ?Token {
        if (self.read()) |curr| {
            if (std.mem.cutPrefix(u8, curr, "--")) |rest| {
                return .make(curr, .{
                    .long = rest,
                });
            }

            if (std.mem.cutPrefix(u8, curr, "-")) |short| {
                return .make(curr, .{
                    .short = .{
                        .flags = short[0 .. short.len - 1],
                        .last = short[short.len - 1],
                    },
                });
            }

            return .make(curr, .{
                .string = curr,
            });
        }

        return null;
    }

    pub fn nextAs(self: *Parser, comptime as: ArgType) ?AsResult(as) {
        return if (self.read()) |curr|
            .{ curr, As(curr, as) }
        else
            null;
    }

    pub fn As(in: []const u8, comptime as: ArgType) ParseError!ReturnType(as) {
        return switch (as) {
            .string => in,
            .int => std.fmt.parseInt(i64, in, 10) catch |err| mapError(err),
            .number => std.fmt.parseFloat(f64, in) catch |err| mapError(err),
        };
    }

    fn read(self: *Parser) ?[]const u8 {
        if (self.pos >= self.args.len) {
            return null;
        }
        const out = self.args[self.pos];
        self.pos += 1;
        return out;
    }
};

fn AsResult(comptime as: ArgType) type {
    return struct {
        []const u8,
        ParseError!ReturnType(as),
    };
}

fn enumSize(comptime T: type) usize {
    const ti = @typeInfo(T);

    if (ti != .@"enum") @compileError("T must be enum");

    return ti.@"enum".fields.len;
}

pub const ListHandler = struct {
    fn ArrayList(comptime t: ArgType) type {
        return std.ArrayList(ReturnType(t));
    }

    fn HashArrayMap(comptime t: ArgType) type {
        return std.StringArrayHashMapUnmanaged(ArrayList(t));
    }

    const Storage = blk: {
        const size = enumSize(ArgType);

        var types: [size]type = undefined;

        for (0..size) |idx| {
            types[idx] = HashArrayMap(@enumFromInt(idx));
        }

        break :blk @Tuple(&types);
    };

    pub const TargetType = union(enum) {
        single: ArgType,
        list: ArgType,
    };
    typeMap: std.StringArrayHashMapUnmanaged(ArgType),
    storage: Storage,
    parser: *Parser,

    pub fn init(parser: *Parser) ListHandler {
        var out: ListHandler = .{
            .typeMap = .empty,
            .storage = undefined,
            .parser = parser,
        };

        inline for (0..comptime enumSize(ArgType)) |idx| {
            out.storage[idx] = .empty;
        }

        return out;
    }

    pub fn deinit(self: *ListHandler, allocator: std.mem.Allocator) void {
        inline for (0..comptime enumSize(ArgType)) |idx| {
            self.storage[idx].deinit(allocator);
        }

        self.typeMap.deinit(allocator);
    }

    fn assertType(self: *ListHandler, allocator: std.mem.Allocator, id: []const u8, t: ArgType) !void {
        if (self.typeMap.get(id)) |ot| {
            std.debug.assert(ot == t);
        } else {
            try self.typeMap.putNoClobber(allocator, id, t);
        }
    }

    pub fn getArray(self: *ListHandler, allocator: std.mem.Allocator, comptime t: ArgType, id: []const u8) !*std.ArrayList(ReturnType(t)) {
        const gop = try @as(*HashArrayMap(t), &self.storage[@intFromEnum(t)]).getOrPut(allocator, id);

        if (gop.found_existing == false) {
            gop.value_ptr.* = .empty;
        }

        return gop.value_ptr;
    }
    pub fn extractArray(self: *ListHandler, allocator: std.mem.Allocator, comptime t: ArgType, id: []const u8) !?[]const ReturnType(t) {
        const storageIndex = @intFromEnum(t);

        if (@as(*HashArrayMap(t), &self.storage[storageIndex]).fetchSwapRemove(id)) |kv| {
            var list = kv.value;
            return try list.toOwnedSlice(allocator);
        }

        return null;
    }

    fn TargetAsResult(comptime argType: TargetType) type {
        switch (argType) {
            .single => |t| return AsResult(t),
            .list => return struct {
                []const u8,
                ParseError!void,
            },
        }
    }

    fn TargetReturnType(comptime argType: TargetType) type {
        return switch (argType) {
            .single => |t| ReturnType(t),
            .list => void,
        };
    }

    pub fn nextAs(self: *ListHandler, allocator: std.mem.Allocator, id: []const u8, comptime argType: TargetType) !?TargetAsResult(argType) {
        switch (argType) {
            .single => |t| {
                return self.parser.nextAs(t);
            },
            .list => |t| {
                try self.assertType(allocator, id, t);

                if (self.parser.nextAs(t)) |next| {
                    if (next[1]) |val| {
                        const array = try self.getArray(allocator, t, id);
                        try array.append(
                            allocator,
                            val,
                        );
                        return .{ next[0], {} };
                    } else |err| {
                        return .{ next[0], err };
                    }
                } else return null;
            },
        }
    }
};

pub const ArgType = enum {
    string,
    number,
    int,
};

pub fn ReturnType(comptime kind: ArgType) type {
    return switch (kind) {
        .string => []const u8,
        .number => f64,
        .int => i64,
    };
}

pub const TokenType = enum {
    long,
    short,
    string,
};

pub const Payload = union(TokenType) {
    long: []const u8,
    short: struct {
        flags: []const u8,
        last: u8,
    },
    string: []const u8,
};

pub const Token = struct {
    text: []const u8,
    payload: Payload,

    fn make(text: []const u8, payload: Payload) Token {
        return .{
            .text = text,
            .payload = payload,
        };
    }
};
