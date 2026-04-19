//! List command — displays installed or remote Zig versions.
//! Three modes:
//!   - Default: list locally installed versions (mark active with color)
//!   - --all / available / remote: list all versions from the remote version map
//!   - --vmu: show configured version map URLs

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");
const version_map = @import("../network/version_map.zig");
const http_client = @import("../network/http_client.zig");

pub const ListFlags = @import("../cli.zig").ListFlags;

/// Main entry point for the `zvm list` command.
/// Dispatches to the appropriate listing mode based on flags.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    flags: ListFlags,
    console: Console,
) !void {
    // Show configured version map URLs
    if (flags.vmu) {
        console.plain(
            \\Zig Version Map: {s}
            \\ZLS VMU:         {s}
            \\Mirror List:     {s}
        , .{
            zvm.settings.version_map_url,
            zvm.settings.zls_vmu,
            zvm.settings.mirror_list_url,
        });
        return;
    }

    // List remote versions from the version map
    if (flags.all) {
        try listRemote(zvm, allocator, console);
        return;
    }

    // Default: list locally installed versions
    var versions = try zvm.getInstalledVersions(allocator);
    defer {
        for (versions.items) |v| allocator.free(v);
        versions.deinit(allocator);
    }

    const active = zvm.getActiveVersion(allocator);
    defer if (active) |a| allocator.free(a);

    if (versions.items.len == 0) {
        console.plain(
            \\No Zig versions installed.
            \\Use 'zvm install <version>' to install one.
        , .{});
        return;
    }

    for (versions.items) |ver| {
        const is_active = if (active) |a| std.mem.eql(u8, a, ver) else false;
        if (is_active) {
            console.colorize(.stdout, .green, "{s} (active)", .{ver});
        } else {
            console.print(.stdout, "{s}", .{ver});
        }
        console.newline(.stdout);
    }
    console.flush(.stdout);
}

/// Fetch and display all remote versions from the version map.
/// Shows version name, installation status, and remote ZLS availability.
fn listRemote(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    console: Console,
) !void {
    console.plain("Fetching available versions...", .{});

    const parsed = version_map.fetchVersionMap(allocator, zvm.io, zvm.environ_map, zvm.settings.version_map_url, zvm.settings.proxy) catch {
        console.err("Failed to fetch version map", .{});
        return;
    };
    defer parsed.deinit();

    const vmap = &parsed.value.object;

    // Fetch ZLS index to check remote ZLS availability per version
    const zls_index = fetchZlsIndex(allocator, zvm.io, zvm.environ_map, zvm.settings.proxy) catch null;
    defer if (zls_index) |zi| zi.deinit();

    // Get installed versions for marking status
    var installed = try zvm.getInstalledVersions(allocator);
    defer {
        for (installed.items) |v| allocator.free(v);
        installed.deinit(allocator);
    }

    const active = zvm.getActiveVersion(allocator);
    defer if (active) |a| allocator.free(a);

    // Collect and sort version keys
    var keys = try version_map.getVersionKeys(allocator, vmap);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    // Print table header
    console.print(.stdout, "{s:<30} {s:<12} {s:<6}", .{ "Version", "Installed", "ZLS" });
    console.newline(.stdout);
    console.print(.stdout, "{s:<30} {s:<12} {s:<6}", .{ "-------", "---------", "---" });
    console.newline(.stdout);

    // Print master version first (with its dev build version number)
    if (vmap.get("master")) |master| {
        const master_ver = switch (master) {
            .object => |obj| if (obj.get("version")) |v| v.string else "?",
            else => "?",
        };
        var master_buf: [128]u8 = undefined;
        const master_display = std.fmt.bufPrint(&master_buf, "master ({s})", .{master_ver}) catch "master";
        printVersionRow(console, installed.items, active, "master", master_display, false);
    }

    // Print all tagged release versions
    for (keys.items) |key| {
        if (std.mem.eql(u8, key, "master")) continue;
        const zls_ok = hasRemoteZls(zls_index, key);
        printVersionRow(console, installed.items, active, key, key, zls_ok);
    }
    console.flush(.stdout);
}

/// Fetch ZLS index from builds.zigtools.org.
/// Returns parsed JSON with version keys (e.g. "0.16.0", "0.15.1").
fn fetchZlsIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    proxy: []const u8,
) !std.json.Parsed(std.json.Value) {
    const json_bytes = try http_client.downloadToMemoryWithProxy(
        allocator,
        io,
        environ_map,
        "https://builds.zigtools.org/index.json",
        proxy,
    );
    defer allocator.free(json_bytes);

    return try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
}

/// Check if a Zig version has a corresponding ZLS release in the remote index.
fn hasRemoteZls(zls_index: ?std.json.Parsed(std.json.Value), version: []const u8) bool {
    const idx = zls_index orelse return false;
    return switch (idx.value) {
        .object => |obj| obj.get(version) != null,
        else => false,
    };
}

/// Print a single version row with installed status and ZLS column.
fn printVersionRow(
    console: Console,
    installed: []const []const u8,
    active: ?[]const u8,
    key: []const u8,
    display: []const u8,
    zls_ok: bool,
) void {
    const is_installed = for (installed) |inst| {
        if (std.mem.eql(u8, inst, key)) break true;
    } else false;
    const is_active = if (active) |a| std.mem.eql(u8, a, key) else false;

    // Column 1: Version
    console.print(.stdout, "{s:<30}", .{display});

    // Column 2: Installed status
    if (is_active) {
        console.colorize(.stdout, .green, "active", .{});
        console.print(.stdout, "      ", .{});
    } else if (is_installed) {
        console.print(.stdout, "yes         ", .{});
    } else {
        console.print(.stdout, "-           ", .{});
    }

    // Column 3: ZLS availability
    if (zls_ok) {
        if (is_active) {
            console.colorize(.stdout, .green, "yes", .{});
        } else {
            console.print(.stdout, "yes", .{});
        }
    } else {
        console.print(.stdout, "-", .{});
    }

    console.newline(.stdout);
}
