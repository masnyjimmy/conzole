const std = @import("std");

pub const BumpVersionStep = struct {
    step: std.Build.Step,

    pub fn create(b: *std.Build) *BumpVersionStep {
        const self = b.allocator.create(@This()) catch unreachable;

        self.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "bump-version",
                .owner = b,
                .makeFn = make,
            }),
        };

        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const zon = @import("build.zig.zon");

        const b = step.owner;
        const io = b.graph.io;

        const alloc = b.allocator;

        const cwd = std.Io.Dir.cwd();

        const src = try cwd.readFileAlloc(io, "build.zig.zon", alloc, .unlimited);

        defer alloc.free(src);

        var parsed = try std.SemanticVersion.parse(zon.version);
        parsed.patch += 1;

        const version_out = try std.fmt.allocPrint(alloc, "{f}", .{parsed});
        defer alloc.free(version_out);

        const new = try std.mem.replaceOwned(u8, alloc, src, zon.version, version_out);
        defer alloc.free(new);

        try cwd.writeFile(io, .{ .sub_path = "build.zig.zon", .data = new });

        std.debug.print("just update \"\" {s}\n", .{version_out});
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("conzole", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bump = BumpVersionStep.create(b);
    const bump_step = b.step("bump-version", "Bumps version");

    bump_step.dependOn(&bump.step);

    // optional but recommended: expose tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
