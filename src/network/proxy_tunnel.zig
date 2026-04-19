//! Proxy tunnel support for HTTPS downloads through HTTP CONNECT proxies.
//! Encapsulates TCP connect, CONNECT handshake, and TLS upgrade into a
//! reusable `ProxyTunnel` abstraction.

const std = @import("std");

const buf_len = std.crypto.tls.Client.min_buffer_len;

/// Proxy host/port resolved from a URL or environment variable.
pub const ProxyInfo = struct {
    host: std.Io.net.HostName,
    port: u16,
};

/// Parse a proxy URL string and configure the client's http_proxy/https_proxy fields.
pub fn setProxyFromUrl(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    proxy_url: []const u8,
) !void {
    const uri = std.Uri.parse(proxy_url) catch
        std.Uri.parseAfterScheme("http", proxy_url) catch return;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
    const raw_host = uri.getHostAlloc(allocator) catch return;

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) a: {
        const auth_buf = try allocator.alloc(u8, std.http.Client.basic_authorization.valueLengthFromUri(uri));
        errdefer allocator.free(auth_buf);
        std.debug.assert(std.http.Client.basic_authorization.value(uri, auth_buf).len == auth_buf.len);
        break :a auth_buf;
    } else null;

    const proxy = try allocator.create(std.http.Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = raw_host,
        .authorization = authorization,
        .port = uri.port orelse switch (protocol) {
            .plain => @as(u16, 80),
            .tls => @as(u16, 443),
        },
        .supports_connect = true,
    };

    // Set both proxy fields so HTTP and HTTPS traffic go through the proxy
    client.http_proxy = proxy;
    client.https_proxy = proxy;
}

/// Resolve proxy host/port from explicit URL or environment variables.
pub fn resolveProxy(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    proxy_url: []const u8,
) ?ProxyInfo {
    const url = if (proxy_url.len > 0) proxy_url else blk: {
        const names = [_][]const u8{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY" };
        for (names) |name| {
            if (environ_map.get(name)) |val| {
                if (val.len > 0) break :blk val;
            }
        }
        break :blk null;
    } orelse return null;

    const uri = std.Uri.parse(url) catch return null;
    const host = uri.getHostAlloc(allocator) catch return null;
    const port: u16 = uri.port orelse 443;
    return .{ .host = host, .port = port };
}

/// Build the request path (path + query) from a URI into the provided buffer.
pub fn buildRequestPath(target_uri: std.Uri, path_buf: []u8) ![]const u8 {
    var path_writer: std.Io.Writer = .fixed(path_buf);
    target_uri.writeToStream(&path_writer, .{ .path = true, .query = true }) catch return error.DownloadFailed;
    var request_path: []const u8 = path_writer.buffered();
    if (request_path.len == 0) {
        path_buf[0] = '/';
        request_path = path_buf[0..1];
    }
    return request_path;
}

/// Send a CONNECT request to establish a tunnel to the target.
fn sendConnectRequest(writer: *std.Io.Writer, target_host: []const u8, target_port: u16) !void {
    writer.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ target_host, target_port, target_host, target_port }) catch {
        return error.DownloadFailed;
    };
    writer.flush() catch {
        return error.DownloadFailed;
    };
}

/// Read and validate the CONNECT response (expecting 200).
fn readConnectResponse(reader: *std.Io.Reader) !void {
    const response_line = reader.takeSentinel('\n') catch {
        return error.DownloadFailed;
    };
    const status_start = std.mem.indexOfScalar(u8, response_line, ' ') orelse return error.DownloadFailed;
    const status_str = response_line[status_start + 1 ..];
    if (status_str.len < 3 or !std.mem.startsWith(u8, status_str, "200")) {
        return error.DownloadFailed;
    }

    while (true) {
        const header_line = reader.takeSentinel('\n') catch return error.DownloadFailed;
        if (header_line.len == 0 or (header_line.len == 1 and header_line[0] == '\r')) break;
    }
}

/// A proxy tunnel with TLS upgrade. Created via `create`, destroyed via `destroy`.
///
/// Manages the full lifecycle: TCP connect to proxy → HTTP CONNECT handshake →
/// TLS client initialization. The TLS client can then be used to send HTTP
/// requests and read responses over the encrypted tunnel.
pub const ProxyTunnel = struct {
    stream: std.Io.net.Stream,
    stream_read_buf: [buf_len]u8,
    stream_write_buf: [buf_len]u8,
    stream_reader: std.Io.net.Stream.Reader,
    stream_writer: std.Io.net.Stream.Writer,
    tls_read_buf: [buf_len]u8,
    tls_write_buf: [buf_len]u8,
    tls_client: std.crypto.tls.Client,

    /// Establish a TCP connection to the proxy, perform the CONNECT handshake,
    /// and upgrade to TLS. Returns a heap-allocated tunnel; caller must call
    /// `destroy` to free resources.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        target_uri: std.Uri,
        proxy_host: std.Io.net.HostName,
        proxy_port: u16,
    ) !*ProxyTunnel {
        const self = try allocator.create(ProxyTunnel);
        errdefer allocator.destroy(self);

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const target_host = try target_uri.getHost(&host_buf);
        const target_port: u16 = target_uri.port orelse 443;

        self.stream = std.Io.net.HostName.connect(proxy_host, io, proxy_port, .{ .mode = .stream }) catch {
            return error.DownloadFailed;
        };
        errdefer self.stream.close(io);

        self.stream_read_buf = undefined;
        self.stream_write_buf = undefined;
        self.stream_reader = self.stream.reader(io, &self.stream_read_buf);
        self.stream_writer = self.stream.writer(io, &self.stream_write_buf);

        try sendConnectRequest(&self.stream_writer.interface, target_host.bytes, target_port);
        try readConnectResponse(&self.stream_reader.interface);

        self.tls_read_buf = undefined;
        self.tls_write_buf = undefined;
        var random_buf: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buf);
        const now = std.Io.Clock.real.now(io);

        self.tls_client = std.crypto.tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = target_host.bytes },
                .ca = .no_verification,
                .read_buffer = &self.tls_read_buf,
                .write_buffer = &self.tls_write_buf,
                .entropy = &random_buf,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            },
        ) catch {
            return error.TlsInitializationFailed;
        };

        return self;
    }

    /// Close the underlying stream and free the tunnel memory.
    pub fn destroy(self: *ProxyTunnel, allocator: std.mem.Allocator, io: std.Io) void {
        self.stream.close(io);
        allocator.destroy(self);
    }
};
