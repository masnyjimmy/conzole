const std = @import("std");
const Reader = @import("reader.zig");

pub const Collector = struct {
    const List = struct {
        flag_type: Type,
        array: std.ArrayList(Payload),
    };

    pub const Error = Reader.Error || std.mem.Allocator.Error;

    values: std.array_hash_map.String(Payload),
    lists: std.array_hash_map.String(List),

    pub const empty: Collector = .{
        .values = .empty,
        .lists = .empty,
    };

    pub fn interceptNext(
        self: *Collector,
        allocator: std.mem.Allocator,
        reader: *Reader,
        name: []const u8,
        flag_type: Type,
    ) Error!void {
        switch (flag_type) {
            .flag => {
                if (self.values.contains(name)) {
                    unreachable; //TODO: handle duplicate
                }

                try self.values.putNoClobber(allocator, name, .{ .flag = true });
            },
            inline .int, .number, .string => |tag| {
                if (self.values.contains(name)) {
                    unreachable; //TODO: handle duplicate
                }

                const value = try reader.readAs(tag.ReadType());

                try self.values.putNoClobber(
                    allocator,
                    name,
                    @unionInit(
                        Payload,
                        @tagName(tag),
                        value.payload,
                    ),
                );
            },
            inline .list_int, .list_number, .list_string => |tag| {
                const value = try reader.readAs(tag.ReadType());

                const gop = try self.lists.getOrPut(allocator, name);

                if (gop.found_existing == false)
                    gop.value_ptr.* = .{
                        .flag_type = tag,
                        .array = .empty,
                    };

                try gop.value_ptr.array.append(allocator, @unionInit(Payload, @tagName(tag.elementType()), value.payload));
            },
        }
    }

    pub fn collect(self: *Collector, allocator: std.mem.Allocator) !std.array_hash_map.String(Payload) {
        defer {
            var it = self.lists.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.array.deinit(allocator);
            }
            self.lists.clearAndFree(allocator);
        }
        errdefer {
            self.values.deinit(allocator);
        }

        var iter = self.lists.iterator();

        while (iter.next()) |kv| {
            const slice = kv.value_ptr.array.items;

            switch (kv.value_ptr.flag_type) {
                inline .list_int, .list_number, .list_string => |tag| {
                    var out: std.ArrayList(tag.ReadType()) = try .initCapacity(allocator, slice.len);

                    for (slice) |v| {
                        out.appendAssumeCapacity(@field(v, @tagName(tag.elementType())));
                    }

                    try self.values.put(
                        allocator,
                        kv.key_ptr.*,
                        @unionInit(
                            Payload,
                            @tagName(tag),
                            out.toOwnedSliceAssert(),
                        ),
                    );
                },
                else => unreachable,
            }
        }

        return self.values.move();
    }

    pub fn deinit(self: *Collector, allocator: std.mem.Allocator) void {
        var iter = self.lists.iterator();
        while (iter.next()) |list| {
            list.value_ptr.array.deinit(allocator);
        }

        self.lists.deinit(allocator);

        self.values.deinit(allocator);
    }
};

pub const types = struct {
    pub const Flag = bool;
    pub const Int = i64;
    pub const Number = f64;
    pub const String = []const u8;
};

pub const Type = enum {
    flag,
    int,
    list_int,
    number,
    list_number,
    string,
    list_string,

    pub fn elementType(self: Type) Type {
        return switch (self) {
            .int, .list_int => .int,
            .number, .list_number => .number,
            .string, .list_string => .string,
            .flag => .flag,
        };
    }

    pub fn ReadType(comptime self: Type) type {
        return switch (self) {
            .int, .list_int => types.Int,
            .number, .list_number => types.Number,
            .string, .list_string => types.String,
            else => unreachable,
        };
    }
};

pub const Payload = union(Type) {
    flag: types.Flag,
    int: types.Int,
    list_int: []const types.Int,
    number: types.Number,
    list_number: []const types.Number,
    string: types.String,
    list_string: []const types.String,
};

test "collect list" {
    const args = [_][]const u8{ "--arg", "1", "--arg", "2", "--arg", "3" };

    var reader: Reader = .init(&args);
    var collector: Collector = .empty;

    while (reader.read()) |tok| {
        switch (tok.type) {
            .long => {
                try std.testing.expectEqualStrings("arg", tok.payload);
                try collector.interceptNext(std.testing.allocator, &reader, "arg", .list_int);
            },
            .short => unreachable,
            .value => unreachable,
        }
    }

    var values = try collector.collect(std.testing.allocator);
    defer values.deinit(std.testing.allocator);

    const list = values.get("arg").?.list_int;

    const expected: []const i64 = &.{ 1, 2, 3 };
    try std.testing.expectEqualDeep(
        expected,
        list,
    );

    std.testing.allocator.free(list);
}
