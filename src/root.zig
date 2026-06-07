pub const args = @import("args.zig");

pub const command = @import("command.zig");

pub const types = struct {
    pub const Bool = command.Bool;
    pub const Int = command.Int;
    pub const Number = command.Number;
    pub const String = command.String;
};

pub const Command = command.Command;
pub const CommandWithContext = command.CommandWithContext;

pub const RunResult = command.RunResult;

pub const terminal = @import("terminal.zig");
