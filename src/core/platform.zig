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

/// Returns the platform-specific executable filename for a tool.
/// Windows executables must keep their .exe suffix so shells and editors can find them.
pub fn executableName(comptime base_name: []const u8) []const u8 {
    return switch (builtin.os.tag) {
        .windows => base_name ++ ".exe",
        else => base_name,
    };
}

/// Returns true when the current target uses Windows executable semantics.
pub fn isWindows() bool {
    return builtin.os.tag == .windows;
}

/// Create a symbolic link at `link_path` pointing to `target`.
/// Removes any existing file/link at `link_path` before creation.
/// On Windows, creates a directory junction (no admin privileges required).
pub fn createSymlink(target: []const u8, link_path: []const u8, io: std.Io) !void {
    // Remove existing link/dir first
    std.Io.Dir.cwd().deleteFile(io, link_path) catch {};

    if (builtin.os.tag == .windows) {
        // On Windows, use directory junction via mklink /J.
        // Junctions work without administrator privileges and behave like
        // directory symlinks — the linked path resolves transparently.
        std.Io.Dir.cwd().deleteDir(io, link_path) catch {};

        // cmd.exe treats '/' as a flag prefix (e.g. "/share" looks like a switch),
        // so normalize both paths to backslashes before passing them to mklink.
        var link_norm: [std.fs.max_path_bytes]u8 = undefined;
        var tgt_norm: [std.fs.max_path_bytes]u8 = undefined;
        if (link_path.len > link_norm.len or target.len > tgt_norm.len)
            return error.SymlinkFailed;
        @memcpy(link_norm[0..link_path.len], link_path);
        @memcpy(tgt_norm[0..target.len], target);
        std.mem.replaceScalar(u8, link_norm[0..link_path.len], '/', '\\');
        std.mem.replaceScalar(u8, tgt_norm[0..target.len], '/', '\\');

        const result = std.process.run(std.heap.page_allocator, io, .{
            .argv = &.{ "cmd", "/c", "mklink", "/J", link_norm[0..link_path.len], tgt_norm[0..target.len] },
        }) catch return error.SymlinkFailed;
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0)
            return error.SymlinkFailed;
        return;
    }

    std.Io.Dir.symLinkAbsolute(io, target, link_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Try harder to remove
            std.Io.Dir.cwd().deleteTree(io, link_path) catch {};
            try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{});
        },
        else => return err,
    };
}

/// Remove a symbolic link at the given path (best-effort, ignores errors).
/// On Windows, junctions are removed as directories.
pub fn removeSymlink(io: std.Io, path: []const u8) void {
    if (builtin.os.tag == .windows) {
        std.Io.Dir.cwd().deleteDir(io, path) catch {};
        return;
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Resolve the home directory (used as fallback for XDG defaults).
/// Caller owns the returned memory.
fn getHomeDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (environ_map.get("USERPROFILE")) |path| {
            return allocator.dupe(u8, path);
        }
    }

    if (environ_map.get("HOME")) |path| {
        return allocator.dupe(u8, path);
    }
    return error.FileNotFound;
}

/// Resolve the XDG config directory.
/// Checks XDG_CONFIG_HOME, falls back to $HOME/.config.
/// On Windows, falls back to %APPDATA% or %USERPROFILE%/.config.
/// Caller owns the returned memory.
pub fn getConfigDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (builtin.os.tag == .windows) {
        if (environ_map.get("APPDATA")) |path| {
            if (path.len > 0) return allocator.dupe(u8, path);
        }
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config", .{home});
}

/// Resolve the XDG data directory.
/// Checks ZVM_PATH (legacy override) first, then XDG_DATA_HOME,
/// falls back to $HOME/.local/share.
/// On Windows, falls back to %USERPROFILE%/.local/share.
/// Caller owns the returned memory.
pub fn getDataDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    // Legacy ZVM_PATH override — use as-is (user already specifies full path)
    if (environ_map.get("ZVM_PATH")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (environ_map.get("XDG_DATA_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
}

/// Resolve the XDG cache directory.
/// Checks XDG_CACHE_HOME, falls back to $HOME/.cache.
/// On Windows, falls back to %LOCALAPPDATA% or %USERPROFILE%/.cache.
/// Caller owns the returned memory.
pub fn getCacheDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("XDG_CACHE_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (builtin.os.tag == .windows) {
        if (environ_map.get("LOCALAPPDATA")) |path| {
            if (path.len > 0) return allocator.dupe(u8, path);
        }
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.cache", .{home});
}

/// Build the target-specific platform string used in Zig download URLs.
/// E.g., "x86_64-macos", "aarch64-linux"
pub fn platformTarget(buf: []u8, info: SystemInfo) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ info.arch, info.os }) catch buf[0..0];
}

/// Stream-copy a file from src_path to dst_path.
/// Opens source for reading, creates destination for writing, streams content.
pub fn copyFile(io: std.Io, src_path: []const u8, dst_path: []const u8) !void {
    const src_file = try std.Io.Dir.cwd().openFile(io, src_path, .{});
    defer src_file.close(io);
    const dst_file = try std.Io.Dir.cwd().createFile(io, dst_path, .{});
    defer dst_file.close(io);

    var src_buf: [8192]u8 = undefined;
    var src_reader = src_file.reader(io, &src_buf);
    var dst_buf: [8192]u8 = undefined;
    var dst_writer = dst_file.writer(io, &dst_buf);

    _ = src_reader.interface.streamRemaining(&dst_writer.interface) catch return error.CopyFailed;
    try dst_writer.interface.flush();
}

// ─────────────────────────────────────────────────────────────────────────────
// Windows PATH management — automatically add zvm bin directory to user PATH
// ─────────────────────────────────────────────────────────────────────────────

/// Check if a directory is already in the Windows user PATH environment variable.
/// Performs case-insensitive comparison (Windows paths are case-insensitive).
/// Returns false on non-Windows platforms or on any error.
pub fn isInUserPath(io: std.Io, dir_path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    // Normalize dir_path to use backslashes
    var dir_norm: [std.fs.max_path_bytes]u8 = undefined;
    if (dir_path.len > dir_norm.len) return false;
    @memcpy(dir_norm[0..dir_path.len], dir_path);
    std.mem.replaceScalar(u8, dir_norm[0..dir_path.len], '/', '\\');
    const normalized = dir_norm[0..dir_path.len];

    // Read current user PATH from registry
    const read_result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "reg", "query", "HKCU\\Environment", "/v", "PATH" },
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer std.heap.page_allocator.free(read_result.stdout);
    defer std.heap.page_allocator.free(read_result.stderr);

    if (read_result.term != .exited or read_result.term.exited != 0) return false;

    // Parse reg query output to find PATH value
    // Output format: "    PATH    REG_EXPAND_SZ    C:\Users\..."
    const stdout = read_result.stdout;
    var line_iter = std.mem.splitScalar(u8, stdout, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        // Look for REG_EXPAND_SZ or REG_SZ and extract the value
        if (std.mem.indexOf(u8, trimmed, "REG_EXPAND_SZ")) |idx| {
            const value_start = idx + "REG_EXPAND_SZ".len;
            const value = std.mem.trim(u8, trimmed[value_start..], " \t");
            return containsPathEntry(value, normalized);
        }
        if (std.mem.indexOf(u8, trimmed, "REG_SZ")) |idx| {
            const value_start = idx + "REG_SZ".len;
            const value = std.mem.trim(u8, trimmed[value_start..], " \t");
            return containsPathEntry(value, normalized);
        }
    }

    return false;
}

/// Add a directory to the Windows user PATH environment variable in the registry.
/// Does nothing if the directory is already present.
/// Returns true if PATH was updated, false if already present.
/// No-op on non-Windows platforms (returns false).
pub fn addToUserPath(io: std.Io, dir_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return false;

    // Normalize dir_path to use backslashes
    var dir_norm: [std.fs.max_path_bytes]u8 = undefined;
    if (dir_path.len > dir_norm.len) return error.PathTooLong;
    @memcpy(dir_norm[0..dir_path.len], dir_path);
    std.mem.replaceScalar(u8, dir_norm[0..dir_path.len], '/', '\\');
    const normalized = dir_norm[0..dir_path.len];

    // Read current user PATH from registry
    const read_result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "reg", "query", "HKCU\\Environment", "/v", "PATH" },
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(4096),
    }) catch return error.PathUpdateFailed;
    defer std.heap.page_allocator.free(read_result.stdout);
    defer std.heap.page_allocator.free(read_result.stderr);

    // If reg query failed (e.g., PATH doesn't exist), create initial PATH
    if (read_result.term != .exited or read_result.term.exited != 0) {
        return try createInitialUserPath(io, normalized);
    }

    // Parse reg query output to find current PATH value
    const stdout = read_result.stdout;
    var current_path: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, stdout, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.indexOf(u8, trimmed, "REG_EXPAND_SZ")) |idx| {
            const value_start = idx + "REG_EXPAND_SZ".len;
            current_path = std.mem.trim(u8, trimmed[value_start..], " \t");
            break;
        }
        if (std.mem.indexOf(u8, trimmed, "REG_SZ")) |idx| {
            const value_start = idx + "REG_SZ".len;
            current_path = std.mem.trim(u8, trimmed[value_start..], " \t");
            break;
        }
    }

    // Check if already in PATH
    if (containsPathEntry(current_path, normalized)) return false;

    // Build new PATH with the directory appended
    var new_path_buf: [65536]u8 = undefined;
    const separator = if (current_path.len > 0) ";" else "";
    const new_path = std.fmt.bufPrint(&new_path_buf, "{s}{s}{s}", .{ current_path, separator, normalized }) catch return error.PathTooLong;

    // Write updated PATH to registry using reg add
    try writeUserPath(io, new_path);

    return true;
}

/// Create an initial user PATH entry in the registry with just the given directory.
fn createInitialUserPath(io: std.Io, dir_path: []const u8) !bool {
    try writeUserPath(io, dir_path);
    return true;
}

/// Write a value to the user PATH in the Windows registry.
fn writeUserPath(io: std.Io, path_value: []const u8) !void {
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "reg", "add", "HKCU\\Environment", "/v", "PATH", "/t", "REG_EXPAND_SZ", "/d", path_value, "/f" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.PathUpdateFailed;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0)
        return error.PathUpdateFailed;
}

/// Check if a semicolon-separated PATH string contains a specific entry.
/// Performs case-insensitive, slash-normalized comparison and trims trailing backslashes.
fn containsPathEntry(path_str: []const u8, entry: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path_str, ';');
    while (iter.next()) |part| {
        var p = std.mem.trim(u8, part, " \t");
        // Trim trailing backslashes for comparison
        while (p.len > 0 and p[p.len - 1] == '\\') {
            p = p[0 .. p.len - 1];
        }
        // Case-insensitive, slash-normalized comparison
        if (pathEqual(p, entry)) return true;
    }
    return false;
}

/// Compare two path strings case-insensitively, treating '/' and '\\' as equal.
fn pathEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        const ca: u8 = if (a[i] == '/') '\\' else a[i];
        const cb: u8 = if (b[i] == '/') '\\' else b[i];
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}
