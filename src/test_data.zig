const std = @import("std");

pub const test_arguments_each_type: []const []const u8 = &.{
    "app",
    "pos1",
    "pos2",
    "--int",
    "123",
    "--num",
    "2.5",
    "--str",
    "hey",
    "-f",
};

const term = @import("terminal.zig");

const App = struct {
    printer: *term.Printer,
};

const command_mod = @import("command.zig");
const Command = command_mod.CommandWithContext(App);

pub fn GitCommand(allocator: std.mem.Allocator) !*Command {
    var rootCmd = try Command.create(allocator, .{
        .name = "git",
        .brief = "git",
        .persistent_pre_run = .{ .custom = DefaultGlobalHandler },
    });

    try rootCmd.addFlag(.{
        .name = "help",
        .brief = "prints help message",
        .global = true,
    }, .flag);

    try rootCmd.addFlag(.{
        .name = "verbose",
        .brief = "prints extra output",
        .global = true,
    }, .flag);

    try rootCmd.addFlag(.{
        .name = "config",
        .brief = "path to config file",
        .global = true,
    }, .string);

    var addCmd = try rootCmd.createSub(.{
        .name = "add",
        .brief = "add file contents to the index",
    });

    try addCmd.addFlag(.{
        .name = "all",
        .brief = "stage all changes",
    }, .flag);

    try addCmd.addFlag(.{
        .name = "dry-run",
        .brief = "show what would be added",
        .short = null,
    }, .flag);

    var commitCmd = try rootCmd.createSub(.{
        .name = "commit",
        .brief = "record changes to the repository",
    });

    try commitCmd.addFlag(.{
        .name = "message",
        .brief = "commit message",
    }, .string);
    try commitCmd.addFlag(.{
        .name = "ammend",
        .brief = "amend previous commit",
        .short = null,
    }, .flag);
    try commitCmd.addFlag(.{
        .name = "no-verify",
        .brief = "skip pre-commit hooks",
        .short = null,
    }, .string);

    _ = blk: {
        var remoteCmd = try rootCmd.createSub(.{
            .name = "remote",
            .brief = "manage remotes",
        });

        _ = try remoteCmd.createSub(.{
            .name = "add",
            .brief = "add a remote",
        });

        _ = try remoteCmd.createSub(.{
            .name = "remove",
            .brief = "remove a remote",
        });

        var listCmd = try remoteCmd.createSub(.{
            .name = "list",
            .brief = "list remotes",
        });

        try listCmd.addFlag(.{
            .name = "verbose",
            .brief = "show urls",
        }, .flag);

        break :blk remoteCmd;
    };

    var logCmd = try rootCmd.createSub(.{
        .name = "log",
        .brief = "show commit history",
    });

    try logCmd.addFlag(.{
        .name = "limit",
        .brief = "max number of commits, default unlimited",
    }, .int);
    try logCmd.addFlag(.{
        .name = "oneline",
        .short = null,
        .brief = "max number of commits, default unlimited",
    }, .flag);
    try logCmd.addFlag(.{
        .name = "since",
        .short = null,
        .brief = "IO date, only show commits after this",
    }, .string);

    var branchCmd = try rootCmd.createSub(.{
        .name = "branch",
        .brief = "list, create, or delete branches",
    });

    try branchCmd.addFlag(.{
        .name = "delete",
        .brief = "delete the branch named by positional",
    }, .flag);
    try branchCmd.addFlag(.{
        .name = "force",
        .brief = "force operation",
    }, .flag);

    return rootCmd;
}

fn DefaultGlobalHandler(ctx: *const Command.Context) !void {
    if (ctx.getValue("help")) |_| {
        try ctx.current.writeHelp(ctx.app.printer);
        ctx.stop();
        return;
    }
}
