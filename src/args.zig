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

    pub fn nextAs(self: *Parser, comptime as: Type) ?struct {
        []const u8, // token text
        ParseError!ReturnType(as), // value / error
    } {
        return if (self.read()) |curr|
            .{ curr, As(curr, as) }
        else
            null;
    }

    pub fn As(in: []const u8, comptime as: Type) ParseError!ReturnType(as) {
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

pub const Type = enum {
    string,
    number,
    int,
};

fn ReturnType(comptime kind: Type) type {
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
