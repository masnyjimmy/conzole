const std = @import("std");
const arguments = @import("argument.zig");

const Reader = @This();

pub const Error = error{
    UnexpectedEnd,
    InvalidType,
};

args: []const []const u8,
pos: usize,

pub fn init(args: []const []const u8) Reader {
    return .{
        .args = args,
        .pos = 0,
    };
}

pub fn readAs(self: *Reader, comptime T: type) Error!Token(T) {
    const arg = self.nextArg() orelse return Error.UnexpectedEnd;

    return .{
        .lexeme = arg,
        .payload = try parseAs(arg, T),
        .type = .value,
    };
}

pub fn read(self: *Reader) ?BasicToken {
    const arg = self.nextArg() orelse return null;

    return makeToken(arg);
}

pub fn previousArg(self: *Reader) []const u8 {
    std.debug.assert(self.pos != 0);

    return self.args[self.pos - 1];
}

fn makeToken(input: []const u8) BasicToken {
    var payload: []const u8 = undefined;

    const token_type: TokenType = blk: {
        if (std.mem.cutPrefix(u8, input, "--")) |p| {
            payload = p;
            break :blk .long;
        }

        if (std.mem.cutPrefix(u8, input, "-")) |p| {
            // FIX: handle negative values in positional arguments properly
            if (std.ascii.isDigit(p[0])) {
                payload = input;
                break :blk .value;
            }

            payload = p;
            break :blk .short;
        }

        payload = input;
        break :blk .value;
    };

    return .{
        .lexeme = input,
        .payload = payload,
        .type = token_type,
    };
}

fn nextArg(self: *Reader) ?[]const u8 {
    if (self.pos >= self.args.len) {
        return null;
    }
    defer self.pos += 1;
    return self.args[self.pos];
}

pub const BasicToken = Token([]const u8);

pub fn Token(comptime PT: type) type {
    return struct {
        lexeme: []const u8,
        payload: PT,
        type: TokenType,
    };
}

pub fn parseAs(input: []const u8, comptime T: type) Error!T {
    const ti = @typeInfo(T);

    if (T == []const u8) {
        return input;
    } else {
        return switch (ti) {
            .int => |int| switch (int.signedness) {
                .signed => std.fmt.parseInt(T, input, 10) catch |err| return switch (err) {
                    error.InvalidCharacter => Error.InvalidType,
                    else => unreachable,
                },
                .unsigned => std.fmt.parseUnsigned(T, input, 10) catch |err| return switch (err) {
                    error.InvalidCharacter => Error.InvalidType,
                    else => unreachable,
                },
            },
            .float => std.fmt.parseFloat(T, input) catch |err| return switch (err) {
                error.InvalidCharacter => Error.InvalidType,
                else => unreachable,
            },
            else => @compileError(""),
        };
    }
}

pub const TokenType = enum {
    short,
    long,
    value,
};

//============== test ============

fn testReadAs(input: []const u8, comptime T: type, expected: T) !void {
    var reader = Reader.init(&.{input});

    const token = try reader.readAs(T);

    try std.testing.expectEqualStrings(input, token.lexeme);
    try std.testing.expectEqual(expected, token.payload);
    try std.testing.expect(token.type == .value);
}

test "read each type" {
    try testReadAs("51", arguments.types.Int, 51);
    try testReadAs("25.5", arguments.types.Number, 25.5);
    try testReadAs("hey", arguments.types.String, "hey");
}
