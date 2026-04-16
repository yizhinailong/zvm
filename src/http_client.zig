//! HTTP client for downloading files and fetching remote content.
//! Uses Zig's std.http.Client for direct downloads, and curl subprocess when
//! a proxy is configured (Zig's HTTP client cannot handle HTTPS through HTTP
//! proxies due to missing TLS-over-CONNECT tunnel support).
//! Supports latency-based mirror selection for fastest downloads.
//! Caches preferred mirror in settings to skip probing on subsequent installs.

const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");

/// Cache TTL: 24 hours in seconds.
const MIRROR_CACHE_TTL: i64 = 86400;

/// Download a file from a URL to the given file path.
/// Uses streaming to handle large files without loading everything into memory.
pub fn downloadToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
) !void {
    return downloadToFileWithProxy(allocator, io, environ_map, url, dest_path, "", null);
}

pub fn downloadToFileWithProxy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
    proxy_url: []const u8,
    progress_writer: ?*std.Io.Writer,
) !void {
    // When a proxy is configured, use curl which correctly handles
    // HTTPS through HTTP proxies via CONNECT tunneling + TLS.
    if (proxy_url.len > 0) {
        return downloadFileViaCurl(allocator, io, url, dest_path, proxy_url, progress_writer);
    }
    return downloadFileDirect(allocator, io, environ_map, url, dest_path, progress_writer);
}

/// Download a file using curl subprocess (used when proxy is configured).
fn downloadFileViaCurl(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    dest_path: []const u8,
    proxy_url: []const u8,
    progress_writer: ?*std.Io.Writer,
) !void {
    const argv: []const []const u8 = if (progress_writer != null)
        &.{ "curl", "-#L", "-x", proxy_url, "-o", dest_path, url }
    else
        &.{ "curl", "-sL", "-x", proxy_url, "-o", dest_path, url };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch {
        return error.DownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.DownloadFailed,
        else => return error.DownloadFailed,
    }
}

/// Download a file using Zig's built-in HTTP client (direct connection).
fn downloadFileDirect(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
    progress_writer: ?*std.Io.Writer,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Auto-detect proxy from environment variables
    client.initDefaultProxies(allocator, environ_map) catch {};

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .init(5),
    });
    defer req.deinit();

    try req.sendBodiless();

    var head_buf: [16384]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    if (response.head.status != .ok) {
        return error.DownloadFailed;
    }

    const total: ?u64 = response.head.content_length;
    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
    defer file.close(io);

    var file_buf: [16384]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);

    var reader_buf: [16384]u8 = undefined;
    const body_reader = response.reader(&reader_buf);

    if (progress_writer) |pw| {
        // Download with progress display
        const chunk_limit: std.Io.Limit = .limited(64 * 1024);
        var downloaded: u64 = 0;
        const start_ns = std.Io.Timestamp.now(io, .awake);
        var last_update_ns: u64 = 0;

        while (true) {
            const n = body_reader.stream(&file_writer.interface, chunk_limit) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| {
                    if (err == error.ReadFailed) {
                        if (response.bodyErr()) |be| return be;
                    }
                    return e;
                },
            };
            downloaded += n;

            // Update progress at most ~10 times per second
            const now_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
            if (now_ns - last_update_ns > 100_000_000 or (total != null and downloaded >= total.?)) {
                last_update_ns = now_ns;
                printProgress(pw, io, downloaded, total, start_ns) catch {};
            }
        }
        try file_writer.interface.flush();

        // Final progress update and newline
        const final_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
        if (final_ns > 0) {
            printProgress(pw, io, downloaded, total, start_ns) catch {};
            try pw.writeByte('\n');
            try pw.flush();
        }
    } else {
        // Download without progress (original behavior)
        _ = body_reader.streamRemaining(&file_writer.interface) catch |err| switch (err) {
            error.ReadFailed => {
                const body_err = response.bodyErr();
                if (body_err) |be| return be;
                return error.DownloadFailed;
            },
            else => return err,
        };
        try file_writer.interface.flush();
    }
}

/// Print a single-line progress update (overwrites current line with \r).
fn printProgress(
    writer: *std.Io.Writer,
    io: std.Io,
    downloaded: u64,
    total: ?u64,
    start_ns: std.Io.Timestamp,
) !void {
    var dl_buf: [32]u8 = undefined;
    const dl_str = formatBytes(&dl_buf, downloaded);

    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    var speed_buf: [32]u8 = undefined;
    const speed_str: []const u8 = if (elapsed_s > 0.0) blk: {
        const speed = @as(f64, @floatFromInt(downloaded)) / elapsed_s;
        break :blk formatBytes(&speed_buf, @intFromFloat(speed));
    } else "?B";

    if (total) |t| {
        var total_buf: [32]u8 = undefined;
        const total_str = formatBytes(&total_buf, t);
        const pct = @min(@divFloor(downloaded * 100, t), 100);
        try writer.print("\x1b[2K\r  {d:>3}% [{s} / {s}] {s}/s", .{ pct, dl_str, total_str, speed_str });
    } else {
        try writer.print("\x1b[2K\r  {s}  {s}/s", .{ dl_str, speed_str });
    }
    try writer.flush();
}

/// Download content from a URL into memory.
/// Caller owns returned memory.
pub fn downloadToMemory(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    return downloadToMemoryWithProxy(allocator, io, environ_map, url, "");
}

pub fn downloadToMemoryWithProxy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    proxy_url: []const u8,
) ![]const u8 {
    if (proxy_url.len > 0) {
        return downloadMemoryViaCurl(allocator, io, url, proxy_url);
    }
    return downloadMemoryDirect(allocator, io, environ_map, url);
}

/// Download content into memory using curl subprocess (used when proxy is configured).
fn downloadMemoryViaCurl(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    proxy_url: []const u8,
) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-sL", "-x", proxy_url, url },
        .stdout_limit = .limited(10 * 1024 * 1024), // 10MB — version map JSON and other responses
    }) catch {
        return error.DownloadFailed;
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.DownloadFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.DownloadFailed;
        },
    }
    return result.stdout;
}

/// Download content into memory using Zig's built-in HTTP client (direct connection).
fn downloadMemoryDirect(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    client.initDefaultProxies(allocator, environ_map) catch {};

    var body_buf: [1024 * 1024]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer,
    });

    if (result.status != .ok) return error.DownloadFailed;

    const body = body_writer.buffered();
    return allocator.dupe(u8, body);
}

/// A candidate URL with its measured latency.
const MirrorCandidate = struct {
    url: []const u8,
    latency_ns: u64,
    owned: bool,
};

/// Maximum number of concurrent latency probes.
/// Each concurrent fiber allocates ~60MB of stack on macOS, so this limits memory overhead.
const MAX_CONCURRENT_PROBES: usize = 8;

/// Result of a single latency probe, produced by a concurrent fiber.
const ProbeResult = struct {
    url: []const u8,
    latency_ns: u64,
};

/// Context for a single concurrent probe fiber (must fit in 1024-byte fiber context limit).
const ProbeContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    result: *?ProbeResult,
};

/// Measure the latency of a URL by sending a HEAD request.
fn measureLatency(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, url: []const u8, proxy_url: []const u8) ?u64 {
    if (proxy_url.len > 0) {
        return measureLatencyViaCurl(allocator, io, url, proxy_url);
    }
    return measureLatencyDirect(allocator, io, environ_map, url);
}

/// Measure latency using curl subprocess (when proxy is configured).
fn measureLatencyViaCurl(allocator: std.mem.Allocator, io: std.Io, url: []const u8, proxy_url: []const u8) ?u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-sI", "-x", proxy_url, "-o", "/dev/null", "-w", "%{http_code}", url },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const end = std.Io.Timestamp.now(io, .awake);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    // Check HTTP status code starts with '2' (2xx)
    const status = std.mem.trim(u8, result.stdout, " \n\r");
    if (status.len < 1 or status[0] != '2') return null;
    const duration = std.Io.Timestamp.durationTo(start, end);
    return @intCast(duration.nanoseconds);
}

/// Measure latency using Zig's built-in HTTP client (direct connection).
fn measureLatencyDirect(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, url: []const u8) ?u64 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    client.initDefaultProxies(allocator, environ_map) catch {};

    const uri = std.Uri.parse(url) catch return null;
    var req = client.request(.HEAD, uri, .{
        .redirect_behavior = .init(3),
    }) catch return null;
    defer req.deinit();

    req.sendBodiless() catch return null;

    var buf: [4096]u8 = undefined;
    const start = std.Io.Timestamp.now(io, .awake);
    const response = req.receiveHead(&buf) catch return null;
    const end = std.Io.Timestamp.now(io, .awake);

    // Accept 2xx status codes
    if (response.head.status.class() != .success) return null;

    const duration = std.Io.Timestamp.durationTo(start, end);
    return @intCast(duration.nanoseconds);
}

/// Compare two MirrorCandidates by latency (for sorting).
fn lessThanByLatency(_: void, a: MirrorCandidate, b: MirrorCandidate) bool {
    return a.latency_ns < b.latency_ns;
}

/// Fiber entry point for concurrent latency probing.
/// Creates its own HTTP client, sends a HEAD request, and writes the result.
fn concurrentProbe(ctx: ProbeContext) std.Io.Cancelable!void {
    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    client.initDefaultProxies(ctx.allocator, ctx.environ_map) catch {};

    const uri = std.Uri.parse(ctx.url) catch return;
    var req = client.request(.HEAD, uri, .{
        .redirect_behavior = .init(3),
    }) catch return;
    defer req.deinit();

    req.sendBodiless() catch return;

    var buf: [4096]u8 = undefined;
    const start = std.Io.Timestamp.now(ctx.io, .awake);
    const response = req.receiveHead(&buf) catch return;
    const end = std.Io.Timestamp.now(ctx.io, .awake);

    if (response.head.status.class() != .success) return;

    const duration = std.Io.Timestamp.durationTo(start, end);
    ctx.result.* = .{
        .url = ctx.url,
        .latency_ns = @intCast(duration.nanoseconds),
    };
}

/// Probe all candidate URLs concurrently using Io fibers (direct path only).
fn probeAllConcurrent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    original_url: []const u8,
    mirrors: *std.ArrayList([]const u8),
    filename: []const u8,
    candidates: *std.ArrayList(MirrorCandidate),
) !void {
    // Build full URL list with owned URLs
    var all_urls: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_urls.items) |u| {
            if (u.len > 0) allocator.free(u);
        }
        all_urls.deinit(allocator);
    }

    const owned_original = allocator.dupe(u8, original_url) catch unreachable;
    try all_urls.append(allocator, owned_original);

    for (mirrors.items) |mirror_base| {
        const mirror_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ mirror_base, filename }) catch continue;
        try all_urls.append(allocator, mirror_url);
    }

    // Probe in batches
    var idx: usize = 0;
    while (idx < all_urls.items.len) {
        const batch_end = @min(idx + MAX_CONCURRENT_PROBES, all_urls.items.len);
        const batch_size = batch_end - idx;

        var results = try allocator.alloc(?ProbeResult, batch_size);
        defer allocator.free(results);
        @memset(results, null);

        var contexts = try allocator.alloc(ProbeContext, batch_size);
        defer allocator.free(contexts);

        for (0..batch_size) |i| {
            contexts[i] = .{
                .allocator = allocator,
                .io = io,
                .environ_map = environ_map,
                .url = all_urls.items[idx + i],
                .result = &results[i],
            };
        }

        var group: std.Io.Group = .init;
        for (0..batch_size) |i| {
            group.concurrent(io, concurrentProbe, .{contexts[i]}) catch {
                // Concurrency unavailable — run inline as fallback
                concurrentProbe(contexts[i]) catch {};
            };
        }
        group.await(io) catch {};

        // Collect successful results
        for (results) |res| {
            if (res) |r| {
                try candidates.append(allocator, .{
                    .url = r.url,
                    .latency_ns = r.latency_ns,
                    .owned = true,
                });
                // Mark as transferred so defer doesn't free it
                for (all_urls.items) |*u| {
                    if (u.*.ptr == r.url.ptr) {
                        u.* = "";
                        break;
                    }
                }
            }
        }

        idx = batch_end;
    }
}

/// Probe all candidate URLs sequentially (used when proxy/curl path is active).
fn probeAllSequential(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    original_url: []const u8,
    mirrors: *std.ArrayList([]const u8),
    filename: []const u8,
    proxy: []const u8,
    candidates: *std.ArrayList(MirrorCandidate),
) !void {
    if (measureLatency(allocator, io, environ_map, original_url, proxy)) |latency| {
        const owned = allocator.dupe(u8, original_url) catch unreachable;
        try candidates.append(allocator, .{ .url = owned, .latency_ns = latency, .owned = true });
    }

    for (mirrors.items) |mirror_base| {
        const mirror_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ mirror_base, filename }) catch continue;
        defer allocator.free(mirror_url);

        if (measureLatency(allocator, io, environ_map, mirror_url, proxy)) |latency| {
            const owned_url = allocator.dupe(u8, mirror_url) catch continue;
            try candidates.append(allocator, .{ .url = owned_url, .latency_ns = latency, .owned = true });
        }
    }
}

/// Probe all candidates: concurrently for direct path, sequentially for proxy/curl path.
fn probeAllCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    original_url: []const u8,
    mirrors: *std.ArrayList([]const u8),
    filename: []const u8,
    proxy: []const u8,
    candidates: *std.ArrayList(MirrorCandidate),
) !void {
    if (proxy.len > 0) {
        try probeAllSequential(allocator, io, environ_map, original_url, mirrors, filename, proxy, candidates);
    } else {
        try probeAllConcurrent(allocator, io, environ_map, original_url, mirrors, filename, candidates);
    }
}

/// Format nanoseconds as a human-readable string (e.g., "123ms", "1.2s").
fn formatLatency(buf: []u8, ns: u64) []const u8 {
    if (ns < 1000) {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
    } else if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.0}us", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch "?";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.0}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch "?";
    }
}

/// Format a byte count as a human-readable string (e.g., "1.5MB", "234KB").
fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    if (bytes < KB) {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    } else if (bytes < MB) {
        return std.fmt.bufPrint(buf, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB))}) catch "?";
    } else if (bytes < GB) {
        return std.fmt.bufPrint(buf, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB))}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}GB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB))}) catch "?";
    }
}

/// Select the fastest mirror by measuring latency to all candidates,
/// then download the file from the fastest responsive source.
/// Returns the actual URL that was successfully downloaded from (caller owns the memory).
pub fn attemptMirrorDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    mirror_list_url: []const u8,
    original_url: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    progress_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    // Extract filename once (used for constructing mirror URLs and extracting base URL)
    const filename = if (std.mem.lastIndexOfScalar(u8, original_url, '/')) |idx| original_url[idx + 1 ..] else original_url;

    // --- Cache-fast path: try cached mirror if fresh ---
    if (settings.preferred_mirror.len > 0 and settings.mirror_updated_at > 0) {
        const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        const age = now - settings.mirror_updated_at;
        if (age >= 0 and age < MIRROR_CACHE_TTL) {
            const cached_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ settings.preferred_mirror, filename }) catch
                return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
            defer allocator.free(cached_url);

            downloadToFileWithProxy(allocator, io, environ_map, cached_url, dest_path, settings.proxy, progress_writer) catch {
                // Cached mirror failed — clear cache and fall through to full probe
                settings.clearPreferredMirror(allocator, io);
                if (verbose_writer) |vw| {
                    try vw.print("  Cached mirror unavailable, re-probing...\n", .{});
                    try vw.flush();
                }
                return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
            };

            if (verbose_writer) |vw| {
                try vw.print("  from: {s} (cached)\n", .{shortUrl(settings.preferred_mirror)});
                try vw.flush();
            }
            return allocator.dupe(u8, cached_url);
        }
    }

    // No cache or stale — full probe
    return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
}

/// Full probe: fetch mirror list, measure latency for all candidates, download from fastest.
fn probeAndDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    mirror_list_url: []const u8,
    original_url: []const u8,
    filename: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    progress_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    const proxy = settings.proxy;

    // No mirror list — download directly from the original URL
    if (mirror_list_url.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Fetch the mirror list
    const mirror_list_content = downloadToMemoryWithProxy(allocator, io, environ_map, mirror_list_url, proxy) catch {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    };
    defer allocator.free(mirror_list_content);

    // Parse mirrors (one URL per line)
    var mirrors: std.ArrayList([]const u8) = .empty;
    defer mirrors.deinit(allocator);

    var lines = std.mem.splitSequence(u8, mirror_list_content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        try mirrors.append(allocator, trimmed);
    }

    if (mirrors.items.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Build candidate list with owned URLs
    var candidates: std.ArrayList(MirrorCandidate) = .empty;
    defer candidates.deinit(allocator);

    // Probe all candidates: concurrently for direct connections, sequentially when using proxy
    try probeAllCandidates(allocator, io, environ_map, original_url, &mirrors, filename, proxy, &candidates);

    // If no candidates responded, fall back to the original URL
    if (candidates.items.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Sort candidates by latency (fastest first)
    std.mem.sort(MirrorCandidate, candidates.items, {}, lessThanByLatency);

    // Print latency results if verbose output is requested
    if (verbose_writer) |vw| {
        var time_buf: [64]u8 = undefined;
        try vw.print("  Probed {d} source(s):\n", .{candidates.items.len});
        for (candidates.items, 1..) |candidate, rank| {
            const time_str = formatLatency(&time_buf, candidate.latency_ns);
            const marker = if (rank == 1) " <-- fastest" else "";
            // Shorten URL for display: show only the host
            const short_url = shortUrl(candidate.url);
            try vw.print("    {d}. {s}  ({s}{s})\n", .{ rank, short_url, time_str, marker });
        }
        try vw.flush();
    }

    // Try downloading from candidates in latency order
    for (candidates.items, 0..) |candidate, idx| {
        downloadToFileWithProxy(allocator, io, environ_map, candidate.url, dest_path, proxy, progress_writer) catch {
            continue;
        };
        // Success — cache the winning mirror base URL for next time
        const base_url = extractBaseUrl(candidate.url);
        if (base_url.len > 0) {
            settings.setPreferredMirror(allocator, io, base_url);
        }
        // Return the winning URL (caller owns it)
        const result = candidate.url;
        // Free all other candidate URLs
        for (candidates.items, 0..) |c, i| {
            if (i != idx) allocator.free(c.url);
        }
        // Prevent defer from freeing the returned URL
        candidates.items.len = 0;
        return result;
    }

    // All candidates failed during actual download — last resort
    for (candidates.items) |c| {
        allocator.free(c.url);
    }
    candidates.items.len = 0;

    try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
    return allocator.dupe(u8, original_url);
}

/// Extract the base URL (scheme + host + path up to last '/') from a full URL.
fn extractBaseUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        return url[0..idx];
    }
    return url;
}

/// Extract the host part of a URL for concise display.
fn shortUrl(url: []const u8) []const u8 {
    // Skip "https://"
    const start: usize = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        0;
    // Find end of host (first '/' after scheme)
    const rest = url[start..];
    for (rest, 0..) |ch, i| {
        if (ch == '/') return rest[0..i];
    }
    return rest;
}
