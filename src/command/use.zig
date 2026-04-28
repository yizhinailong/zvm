//! Use command — switch the active Zig version.
//! Updates the bin symlink in the data directory to point to the requested version directory.

const std = @import("std");

const Console = @import("../core/Console.zig");
const platform = @import("../core/platform.zig");
const zvm_mod = @import("../core/zvm.zig");

/// Switch to an installed Zig version by updating the bin symlink.
/// Prints an error if the requested version is not installed.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    flags: anytype,
    console: Console,
) !void {
    _ = allocator;
    _ = flags;

    if (!zvm.isVersionInstalled(version)) {
        console.plain("Zig {s} is not installed. Run 'zvm install {s}' first.", .{ version, version });
        return;
    }

    try zvm.setBin(version);
    console.plain("Now using Zig {s}", .{version});

    // On Windows, ensure the bin directory is in the user PATH
    if (platform.isWindows()) {
        var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bin_path = zvm.binPath(&bin_buf);

        if (platform.addToUserPath(zvm.io, bin_path)) |added| {
            if (added) {
                console.plain("Added zvm bin directory to PATH. Please restart your terminal for changes to take effect.", .{});
            }
        } else |err| {
            console.warn("Failed to update PATH ({s}). Please add {s} to your PATH manually.", .{ @errorName(err), bin_path });
        }
    }
}
