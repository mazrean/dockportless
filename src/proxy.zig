const std = @import("std");
const posix = std.posix;
const mapping = @import("mapping.zig");

const Allocator = std.mem.Allocator;

pub const PROXY_PORT: u16 = 7355;

pub const HostInfo = struct {
    service: []const u8,
    project: []const u8,
};

/// Extract project_name and service_name from the Host header.
/// Format: <service_name>.<project_name>.localhost[:port]
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

    // Find the first dot: <service>.<project>
    const dot_idx = std.mem.indexOfScalar(u8, prefix, '.') orelse return null;
    if (dot_idx == 0 or dot_idx == prefix.len - 1) return null;

    return HostInfo{
        .service = prefix[0..dot_idx],
        .project = prefix[dot_idx + 1 ..],
    };
}

/// Look up the backend port from mappings by project and service name.
fn findBackendPort(mappings: []const mapping.ProjectMapping, project: []const u8, service: []const u8) ?u16 {
    for (mappings) |m| {
        if (!std.mem.eql(u8, m.project_name, project)) continue;
        for (m.services) |svc| {
            if (std.mem.eql(u8, svc.service_name, service)) return svc.port;
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

        // Check if we have the complete headers (look for \r\n\r\n)
        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |_| break;
    }

    // Extract Host header
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

/// Set socket receive timeout.
fn setRecvTimeout(fd: posix.socket_t, seconds: u32) void {
    const tv = posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Forward the request to the backend service.
fn forwardRequest(allocator: Allocator, client_fd: posix.socket_t, request_data: []const u8, backend_port: u16) !void {
    const backend_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, backend_port);
    const backend_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(backend_fd);

    posix.connect(backend_fd, &backend_addr.any, backend_addr.getOsSockLen()) catch {
        sendErrorResponse(client_fd, "502 Bad Gateway", "Backend service is not available");
        return;
    };

    // Set receive timeout on backend to avoid hanging on keep-alive connections
    setRecvTimeout(backend_fd, 5);

    // Forward the request
    _ = posix.write(backend_fd, request_data) catch {
        sendErrorResponse(client_fd, "502 Bad Gateway", "Failed to forward request");
        return;
    };

    // Read and forward the response
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

const ClientContext = struct {
    client_fd: posix.socket_t,
    allocator: Allocator,
    mapping_dir_path: []const u8,
};

fn clientThread(ctx: ClientContext) void {
    defer posix.close(ctx.client_fd);

    // Set receive timeout on client socket
    setRecvTimeout(ctx.client_fd, 10);

    handleClient(ctx.allocator, ctx.client_fd, ctx.mapping_dir_path) catch |err| {
        std.debug.print("Error handling client: {}\n", .{err});
    };
}

/// Start the proxy server (blocking).
pub fn start(allocator: Allocator, mapping_dir_path: []const u8) !void {
    const listen_fd = try createListenSocket();
    defer posix.close(listen_fd);

    std.debug.print("Proxy server listening on :{d}\n", .{PROXY_PORT});

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_fd = posix.accept(listen_fd, &client_addr, &addr_len, 0) catch continue;

        const ctx = ClientContext{
            .client_fd = client_fd,
            .allocator = allocator,
            .mapping_dir_path = mapping_dir_path,
        };

        const thread = std.Thread.spawn(.{}, clientThread, .{ctx}) catch {
            posix.close(client_fd);
            continue;
        };
        thread.detach();
    }
}

fn handleClient(allocator: Allocator, client_fd: posix.socket_t, mapping_dir_path: []const u8) !void {
    const result = try readRequestAndExtractHost(allocator, client_fd);
    // request_data is a slice into a larger allocation; we need to track the original buf
    defer {
        // The buf was allocated with 8192 bytes, but we only got a slice
        // We need to free the original allocation
        // Since request_data points into the allocated buffer, we can reconstruct the pointer
        const ptr: [*]u8 = @constCast(result.request_data.ptr);
        allocator.free(ptr[0..8192]);
    }

    const host_info = parseHost(result.host) orelse {
        sendErrorResponse(client_fd, "404 Not Found", "Unknown host");
        return;
    };

    // Read current mappings
    const mappings = try mapping.readAllMappings(allocator, mapping_dir_path);
    defer mapping.freeAllMappings(allocator, mappings);

    const backend_port = findBackendPort(mappings, host_info.project, host_info.service) orelse {
        sendErrorResponse(client_fd, "404 Not Found", "Service not found");
        return;
    };

    try forwardRequest(allocator, client_fd, result.request_data, backend_port);
}

// --- Tests ---

test "parseHost: valid host" {
    const result = parseHost("web.myapp.localhost:7355").?;
    try std.testing.expectEqualStrings("web", result.service);
    try std.testing.expectEqualStrings("myapp", result.project);
}

test "parseHost: without port" {
    const result = parseHost("api.backend.localhost").?;
    try std.testing.expectEqualStrings("api", result.service);
    try std.testing.expectEqualStrings("backend", result.project);
}

test "parseHost: just localhost" {
    try std.testing.expect(parseHost("localhost:7355") == null);
}

test "parseHost: single component before localhost" {
    // "web.localhost" has no project
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
}

test "findBackendPort: found" {
    const mappings = &[_]mapping.ProjectMapping{
        .{
            .project_name = "myapp",
            .pid = 123,
            .services = &[_]mapping.ServiceMapping{
                .{ .service_name = "web", .port = 49152 },
                .{ .service_name = "api", .port = 49153 },
            },
        },
    };

    try std.testing.expectEqual(@as(?u16, 49152), findBackendPort(mappings, "myapp", "web"));
    try std.testing.expectEqual(@as(?u16, 49153), findBackendPort(mappings, "myapp", "api"));
}

test "findBackendPort: not found" {
    const mappings = &[_]mapping.ProjectMapping{
        .{
            .project_name = "myapp",
            .pid = 123,
            .services = &[_]mapping.ServiceMapping{
                .{ .service_name = "web", .port = 49152 },
            },
        },
    };

    try std.testing.expectEqual(@as(?u16, null), findBackendPort(mappings, "myapp", "db"));
    try std.testing.expectEqual(@as(?u16, null), findBackendPort(mappings, "other", "web"));
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
