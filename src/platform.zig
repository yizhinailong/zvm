//! Platform detection and OS abstraction layer.
//! Provides system info detection (OS, arch), symlink management,
//! and home directory resolution for cross-platform support.

const std = @import("std");
const builtin = @import("builtin");

/// System information containing OS and architecture as Zig-style strings.
pub const SystemInfo = struct {
    os: []const u8,
    arch: []const u8,

    /// Returns the Zig-style target triple (e.g., "x86_64-macos").
    /// Note: the returned slice references a stack-local buffer — use immediately.
    pub fn zigTarget(self: SystemInfo) []const u8 {
        var buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{s}-{s}", .{ self.arch, self.os }) catch unreachable;
        return result;
    }
};

/// Detect the current OS and architecture at comptime.
/// Returns Zig-style names: os = "macos"|"linux"|"windows"|..., arch = "x86_64"|"aarch64"|...
pub fn zigStyleSystemInfo() SystemInfo {
    const os_tag = builtin.os.tag;
    const arch = builtin.cpu.arch;

    const os_name: []const u8 = switch (os_tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .dragonfly => "dragonfly",
        else => @tagName(os_tag),
    };

    const arch_name: []const u8 = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .riscv64 => "riscv64",
        .powerpc64, .powerpc64le => "powerpc64le",
        .x86 => "x86",
        else => @tagName(arch),
    };

    return .{
        .os = os_name,
        .arch = arch_name,
    };
}

/// Returns the archive file extension for the current platform.
/// Windows uses .zip, all other platforms use .tar.xz.
pub fn getArchiveExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".zip",
        else => ".tar.xz",
    };
}

/// Create a symbolic link at `link_path` pointing to `target`.
/// Removes any existing file/link at `link_path` before creation.
/// On Windows, creates a directory junction (no admin privileges required).
pub fn createSymlink(target: []const u8, link_path: []const u8) !void {
    // Remove existing link/dir first
    std.fs.cwd().deleteFile(link_path) catch {};

    if (builtin.os.tag == .windows) {
        // On Windows, use directory junction via mklink /J.
        // Junctions work without administrator privileges and behave like
        // directory symlinks — the linked path resolves transparently.
        std.fs.cwd().deleteDir(link_path) catch {};
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "cmd", "/c", "mklink", "/J", link_path, target },
        }) catch return error.SymlinkFailed;
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0)
            return error.SymlinkFailed;
        return;
    }

    std.posix.symlink(target, link_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Try harder to remove
            std.fs.cwd().deleteTree(link_path) catch {};
            try std.posix.symlink(target, link_path);
        },
        else => return err,
    };
}

/// Remove a symbolic link at the given path (best-effort, ignores errors).
/// On Windows, junctions are removed as directories.
pub fn removeSymlink(path: []const u8) void {
    if (builtin.os.tag == .windows) {
        std.fs.cwd().deleteDir(path) catch {};
        return;
    }
    std.fs.cwd().deleteFile(path) catch {};
}

/// Resolve the user's home directory.
/// Checks ZVM_PATH env var first, then falls back to HOME (or USERPROFILE on Windows).
/// Caller owns the returned memory.
pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    // Try ZVM_PATH first, then HOME
    if (std.process.getEnvVarOwned(allocator, "ZVM_PATH")) |path| {
        return path;
    } else |_| {}

    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |path| {
            return path;
        } else |_| {}
    }

    return std.process.getEnvVarOwned(allocator, "HOME");
}

/// Build the target-specific platform string used in Zig download URLs.
/// E.g., "x86_64-macos", "aarch64-linux"
pub fn platformTarget(buf: []u8, info: SystemInfo) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ info.arch, info.os }) catch buf[0..0];
}
