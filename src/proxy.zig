const std = @import("std");
const posix = std.posix;
const mapping = @import("mapping.zig");
const cert = @import("cert.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("sys/socket.h");
});

pub const PROXY_PORT: u16 = 7355;

/// TLS record content type for Handshake
const TLS_CONTENT_TYPE_HANDSHAKE: u8 = 0x16;

/// Detected connection protocol
const Protocol = enum {
    http,
    tls,
    postgres_ssl,
};

/// PostgreSQL SSL Request code (80877103 = 0x04D2162F)
const PG_SSL_REQUEST_CODE: u32 = 80877103;

pub const HostInfo = struct {
    service: []const u8,
    project: []const u8,
    port_index: usize,
};

/// Extract project_name, service_name and optional port index from the Host header.
/// Formats:
///   <service_name>.<project_name>.localhost[:port]           -> port_index = 0
///   <index>.<service_name>.<project_name>.localhost[:port]   -> port_index = index
pub fn parseHost(host: []const u8) ?HostInfo {
    // Strip port if present
    const host_without_port = if (std.mem.indexOfScalar(u8, host, ':')) |colon_idx|
        host[0..colon_idx]
    else
        host;

    // Must end with .localhost
    const suffix = ".localhost";
    if (!std.mem.endsWith(u8, host_without_port, suffix)) return null;

    const prefix = host_without_port[0 .. host_without_port.len - suffix.len];
    if (prefix.len == 0) return null;

    // Find the first dot
    const first_dot = std.mem.indexOfScalar(u8, prefix, '.') orelse return null;
    if (first_dot == 0 or first_dot == prefix.len - 1) return null;

    const first_part = prefix[0..first_dot];
    const rest = prefix[first_dot + 1 ..];

    // Try to parse first_part as a port index number
    if (std.fmt.parseInt(usize, first_part, 10)) |port_index| {
        // Format: <index>.<service>.<project>.localhost
        // rest must contain at least <service>.<project>
        const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        if (second_dot == 0 or second_dot == rest.len - 1) return null;

        return HostInfo{
            .service = rest[0..second_dot],
            .project = rest[second_dot + 1 ..],
            .port_index = port_index,
        };
    } else |_| {
        // Format: <service>.<project>.localhost
        return HostInfo{
            .service = first_part,
            .project = rest,
            .port_index = 0,
        };
    }
}

/// Look up the backend port from mappings by project, service name, and port index.
fn findBackendPort(mappings: []const mapping.ProjectMapping, project: []const u8, service: []const u8, port_index: usize) ?u16 {
    for (mappings) |m| {
        if (!std.mem.eql(u8, m.project_name, project)) continue;
        for (m.services) |svc| {
            if (std.mem.eql(u8, svc.service_name, service)) {
                if (port_index < svc.ports.len) return svc.ports[port_index];
                return null;
            }
        }
    }
    return null;
}

/// Create a listening socket with SO_REUSEPORT.
fn createListenSocket() !posix.socket_t {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(sock);

    // SO_REUSEPORT
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

    // SO_REUSEADDR
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PROXY_PORT);
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
    try posix.listen(sock, 128);

    return sock;
}

/// Set socket receive timeout.
fn setRecvTimeout(fd: posix.socket_t, seconds: u32) void {
    const tv = posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Read exact number of bytes from a TCP socket.
fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch |err| return err;
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Read exact number of bytes from an SSL connection.
fn sslReadExact(ssl_obj: *c.SSL, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.SSL_read(ssl_obj, @ptrCast(buf[total..].ptr), @intCast(buf.len - total));
        if (n <= 0) return error.SslReadFailed;
        total += @as(usize, @intCast(n));
    }
}

/// Detect connection protocol by peeking at initial bytes.
fn detectProtocol(fd: posix.socket_t) !Protocol {
    var fds = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, 100) catch return error.PollFailed;

    var buf: [8]u8 = undefined;
    const n = c.recv(@intCast(fd), &buf, 8, c.MSG_PEEK);
    if (n <= 0) return error.PeekFailed;
    const bytes_read: usize = @intCast(n);

    if (buf[0] == TLS_CONTENT_TYPE_HANDSHAKE) return .tls;

    if (bytes_read >= 8) {
        const length = std.mem.readInt(u32, buf[0..4], .big);
        const code = std.mem.readInt(u32, buf[4..8], .big);
        if (length == 8 and code == PG_SSL_REQUEST_CODE) return .postgres_ssl;
    }

    return .http;
}

const ClientContext = struct {
    client_fd: posix.socket_t,
    allocator: Allocator,
    ssl_ctx: *c.SSL_CTX,
    mapping_dir_path: []const u8,
};

fn clientThread(ctx: ClientContext) void {
    defer posix.close(ctx.client_fd);

    const protocol = detectProtocol(ctx.client_fd) catch return;
    setRecvTimeout(ctx.client_fd, 10);

    switch (protocol) {
        .tls => handleTlsClient(ctx) catch |err| {
            std.debug.print("TLS client error: {}\n", .{err});
        },
        .postgres_ssl => handlePostgresClient(ctx) catch |err| {
            std.debug.print("PostgreSQL client error: {}\n", .{err});
        },
        .http => handleHttpClient(ctx.allocator, ctx.client_fd, ctx.mapping_dir_path) catch |err| {
            std.debug.print("HTTP client error: {}\n", .{err});
        },
    }
}

/// Start the unified proxy server (blocking).
pub fn start(allocator: Allocator, mapping_dir_path: []const u8, cert_paths: cert.CertPaths) !void {
    // Initialize OpenSSL TLS context
    const method = c.TLS_server_method() orelse return error.SslInitFailed;
    const ssl_ctx = c.SSL_CTX_new(method) orelse return error.SslCtxFailed;
    defer c.SSL_CTX_free(ssl_ctx);

    // Load certificate and private key
    const cert_path_z = try allocator.dupeZ(u8, cert_paths.server_cert);
    defer allocator.free(cert_path_z);
    const key_path_z = try allocator.dupeZ(u8, cert_paths.server_key);
    defer allocator.free(key_path_z);

    if (c.SSL_CTX_use_certificate_chain_file(ssl_ctx, cert_path_z.ptr) != 1) {
        return error.SslCertLoadFailed;
    }
    if (c.SSL_CTX_use_PrivateKey_file(ssl_ctx, key_path_z.ptr, c.SSL_FILETYPE_PEM) != 1) {
        return error.SslKeyLoadFailed;
    }

    const listen_fd = try createListenSocket();
    defer posix.close(listen_fd);

    std.debug.print("Proxy server listening on :{d} (HTTP + TLS)\n", .{PROXY_PORT});

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_fd = posix.accept(listen_fd, &client_addr, &addr_len, 0) catch continue;

        const ctx = ClientContext{
            .client_fd = client_fd,
            .allocator = allocator,
            .ssl_ctx = ssl_ctx,
            .mapping_dir_path = mapping_dir_path,
        };

        const thread = std.Thread.spawn(.{}, clientThread, .{ctx}) catch {
            posix.close(client_fd);
            continue;
        };
        thread.detach();
    }
}

// ---- HTTP handling ----

fn handleHttpClient(allocator: Allocator, client_fd: posix.socket_t, mapping_dir_path: []const u8) !void {
    const result = try readRequestAndExtractHost(allocator, client_fd);
    defer {
        const ptr: [*]u8 = @constCast(result.request_data.ptr);
        allocator.free(ptr[0..8192]);
    }

    const host_info = parseHost(result.host) orelse {
        sendErrorResponse(client_fd, "404 Not Found", "Unknown host");
        return;
    };

    const mappings = try mapping.readAllMappings(allocator, mapping_dir_path);
    defer mapping.freeAllMappings(allocator, mappings);

    const backend_port = findBackendPort(mappings, host_info.project, host_info.service, host_info.port_index) orelse {
        sendErrorResponse(client_fd, "404 Not Found", "Service not found");
        return;
    };

    try forwardHttpRequest(allocator, client_fd, result.request_data, backend_port);
}

/// Read an HTTP request and extract the Host header.
fn readRequestAndExtractHost(allocator: Allocator, client_fd: posix.socket_t) !struct { host: []const u8, request_data: []u8 } {
    var buf = try allocator.alloc(u8, 8192);
    errdefer allocator.free(buf);

    var total_read: usize = 0;
    while (total_read < buf.len) {
        const n = posix.read(client_fd, buf[total_read..]) catch |err| {
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        total_read += n;

        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |_| break;
    }

    const headers = buf[0..total_read];
    const host = extractHostHeader(headers) orelse return error.NoHostHeader;

    return .{
        .host = host,
        .request_data = buf[0..total_read],
    };
}

fn extractHostHeader(headers: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // Skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "host:")) {
            const value = std.mem.trimLeft(u8, line["host:".len..], " \t");
            return value;
        }
    }
    return null;
}

fn forwardHttpRequest(allocator: Allocator, client_fd: posix.socket_t, request_data: []const u8, backend_port: u16) !void {
    const backend_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, backend_port);
    const backend_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(backend_fd);

    posix.connect(backend_fd, &backend_addr.any, backend_addr.getOsSockLen()) catch {
        sendErrorResponse(client_fd, "502 Bad Gateway", "Backend service is not available");
        return;
    };

    setRecvTimeout(backend_fd, 5);

    _ = posix.write(backend_fd, request_data) catch {
        sendErrorResponse(client_fd, "502 Bad Gateway", "Failed to forward request");
        return;
    };

    var buf = try allocator.alloc(u8, 65536);
    defer allocator.free(buf);

    while (true) {
        const n = posix.read(backend_fd, buf) catch break;
        if (n == 0) break;
        _ = posix.write(client_fd, buf[0..n]) catch break;
    }
}

fn sendErrorResponse(client_fd: posix.socket_t, status: []const u8, body: []const u8) void {
    var buf: [512]u8 = undefined;
    const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;
    _ = posix.write(client_fd, response) catch {};
}

// ---- PostgreSQL handling ----

fn handlePostgresClient(ctx: ClientContext) !void {
    // Consume the SSLRequest message (8 bytes)
    var buf: [8]u8 = undefined;
    try readExact(ctx.client_fd, &buf);

    // Verify it's a valid SSLRequest
    const length = std.mem.readInt(u32, buf[0..4], .big);
    const code = std.mem.readInt(u32, buf[4..8], .big);
    if (length != 8 or code != PG_SSL_REQUEST_CODE) {
        return error.InvalidSSLRequest;
    }

    // Reply with 'S' (SSL supported)
    _ = try posix.write(ctx.client_fd, "S");

    // Client will now start TLS handshake - delegate to TLS handler
    try handleTlsClient(ctx);
}

// ---- TLS handling ----

fn handleTlsClient(ctx: ClientContext) !void {
    const ssl_obj = c.SSL_new(ctx.ssl_ctx) orelse return error.SslNewFailed;
    defer c.SSL_free(ssl_obj);

    _ = c.SSL_set_fd(ssl_obj, @intCast(ctx.client_fd));

    // TLS handshake
    if (c.SSL_accept(ssl_obj) != 1) {
        return error.SslAcceptFailed;
    }

    // Get SNI hostname
    const servername = c.SSL_get_servername(ssl_obj, c.TLSEXT_NAMETYPE_host_name) orelse {
        return error.NoSni;
    };
    const hostname = std.mem.span(servername);

    const host_info = parseHost(hostname) orelse {
        return error.InvalidHost;
    };

    // Look up backend port
    const mappings = try mapping.readAllMappings(ctx.allocator, ctx.mapping_dir_path);
    defer mapping.freeAllMappings(ctx.allocator, mappings);

    const backend_port = findBackendPort(mappings, host_info.project, host_info.service, host_info.port_index) orelse {
        return error.ServiceNotFound;
    };

    // Connect to backend (plain TCP)
    const backend_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, backend_port);
    const backend_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(backend_fd);

    posix.connect(backend_fd, &backend_addr.any, backend_addr.getOsSockLen()) catch {
        return error.BackendConnectionFailed;
    };

    // Bidirectional forwarding: TLS client <-> plain TCP backend
    forwardBidirectional(ssl_obj, ctx.client_fd, backend_fd);

    _ = c.SSL_shutdown(ssl_obj);
}

/// Poll-based bidirectional forwarding between TLS client and plain TCP backend.
fn forwardBidirectional(ssl_obj: *c.SSL, client_fd: posix.socket_t, backend_fd: posix.socket_t) void {
    var client_buf: [65536]u8 = undefined;
    var backend_buf: [65536]u8 = undefined;

    while (true) {
        var fds = [2]posix.pollfd{
            .{ .fd = client_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = backend_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const ssl_pending = c.SSL_pending(ssl_obj);
        const timeout: i32 = if (ssl_pending > 0) 0 else 60_000;

        const ready = posix.poll(&fds, timeout) catch break;

        if (ready == 0 and ssl_pending <= 0) break;

        // Client → Backend (TLS read → plain write)
        if (ssl_pending > 0 or (ready > 0 and (fds[0].revents & posix.POLL.IN != 0))) {
            const n = c.SSL_read(ssl_obj, &client_buf, @intCast(client_buf.len));
            if (n <= 0) break;
            _ = posix.write(backend_fd, client_buf[0..@intCast(n)]) catch break;
        }

        // Backend → Client (plain read → TLS write)
        if (ready > 0 and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0)) {
            const n = posix.read(backend_fd, &backend_buf) catch break;
            if (n == 0) break;
            const written = c.SSL_write(ssl_obj, &backend_buf, @intCast(n));
            if (written <= 0) break;
        }

        if (ready > 0) {
            if (fds[0].revents & posix.POLL.ERR != 0) break;
            if (fds[1].revents & posix.POLL.ERR != 0) break;
        }
    }
}

// --- Tests ---

test "parseHost: valid host" {
    const result = parseHost("web.myapp.localhost:7355").?;
    try std.testing.expectEqualStrings("web", result.service);
    try std.testing.expectEqualStrings("myapp", result.project);
    try std.testing.expectEqual(@as(usize, 0), result.port_index);
}

test "parseHost: without port" {
    const result = parseHost("api.backend.localhost").?;
    try std.testing.expectEqualStrings("api", result.service);
    try std.testing.expectEqualStrings("backend", result.project);
    try std.testing.expectEqual(@as(usize, 0), result.port_index);
}

test "parseHost: with port index" {
    const result = parseHost("0.web.myapp.localhost:7355").?;
    try std.testing.expectEqualStrings("web", result.service);
    try std.testing.expectEqualStrings("myapp", result.project);
    try std.testing.expectEqual(@as(usize, 0), result.port_index);
}

test "parseHost: with port index 1" {
    const result = parseHost("1.web.myapp.localhost:7355").?;
    try std.testing.expectEqualStrings("web", result.service);
    try std.testing.expectEqualStrings("myapp", result.project);
    try std.testing.expectEqual(@as(usize, 1), result.port_index);
}

test "parseHost: with port index and multi-level project" {
    const result = parseHost("2.api.my.app.localhost").?;
    try std.testing.expectEqualStrings("api", result.service);
    try std.testing.expectEqualStrings("my.app", result.project);
    try std.testing.expectEqual(@as(usize, 2), result.port_index);
}

test "parseHost: just localhost" {
    try std.testing.expect(parseHost("localhost:7355") == null);
}

test "parseHost: single component before localhost" {
    try std.testing.expect(parseHost("web.localhost") == null);
}

test "parseHost: non-localhost host" {
    try std.testing.expect(parseHost("web.myapp.example.com") == null);
}

test "parseHost: empty string" {
    try std.testing.expect(parseHost("") == null);
}

test "parseHost: multi-level project name" {
    const result = parseHost("web.my.app.localhost:7355").?;
    try std.testing.expectEqualStrings("web", result.service);
    try std.testing.expectEqualStrings("my.app", result.project);
    try std.testing.expectEqual(@as(usize, 0), result.port_index);
}

test "findBackendPort: found index 0" {
    const web_ports = &[_]u16{ 49152, 49154 };
    const api_ports = &[_]u16{49153};
    const mappings = &[_]mapping.ProjectMapping{
        .{
            .project_name = "myapp",
            .pid = 123,
            .services = &[_]mapping.ServiceMapping{
                .{ .service_name = "web", .ports = web_ports },
                .{ .service_name = "api", .ports = api_ports },
            },
        },
    };

    try std.testing.expectEqual(@as(?u16, 49152), findBackendPort(mappings, "myapp", "web", 0));
    try std.testing.expectEqual(@as(?u16, 49154), findBackendPort(mappings, "myapp", "web", 1));
    try std.testing.expectEqual(@as(?u16, 49153), findBackendPort(mappings, "myapp", "api", 0));
}

test "findBackendPort: index out of range" {
    const web_ports = &[_]u16{49152};
    const mappings = &[_]mapping.ProjectMapping{
        .{
            .project_name = "myapp",
            .pid = 123,
            .services = &[_]mapping.ServiceMapping{
                .{ .service_name = "web", .ports = web_ports },
            },
        },
    };

    try std.testing.expectEqual(@as(?u16, null), findBackendPort(mappings, "myapp", "web", 1));
}

test "findBackendPort: not found" {
    const web_ports = &[_]u16{49152};
    const mappings = &[_]mapping.ProjectMapping{
        .{
            .project_name = "myapp",
            .pid = 123,
            .services = &[_]mapping.ServiceMapping{
                .{ .service_name = "web", .ports = web_ports },
            },
        },
    };

    try std.testing.expectEqual(@as(?u16, null), findBackendPort(mappings, "myapp", "db", 0));
    try std.testing.expectEqual(@as(?u16, null), findBackendPort(mappings, "other", "web", 0));
}

test "extractHostHeader: standard header" {
    const headers = "GET / HTTP/1.1\r\nHost: web.myapp.localhost:7355\r\nAccept: */*\r\n\r\n";
    const host = extractHostHeader(headers).?;
    try std.testing.expectEqualStrings("web.myapp.localhost:7355", host);
}

test "extractHostHeader: case insensitive" {
    const headers = "GET / HTTP/1.1\r\nhost: web.myapp.localhost\r\n\r\n";
    const host = extractHostHeader(headers).?;
    try std.testing.expectEqualStrings("web.myapp.localhost", host);
}

test "extractHostHeader: no host header" {
    const headers = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n";
    try std.testing.expect(extractHostHeader(headers) == null);
}

