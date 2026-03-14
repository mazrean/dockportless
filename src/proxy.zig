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
    mysql,
};

/// PostgreSQL SSL Request code (80877103 = 0x04D2162F)
const PG_SSL_REQUEST_CODE: u32 = 80877103;

// MySQL protocol constants
const MYSQL_CLIENT_LONG_PASSWORD: u32 = 0x00000001;
const MYSQL_CLIENT_CONNECT_WITH_DB: u32 = 0x00000008;
const MYSQL_CLIENT_PROTOCOL_41: u32 = 0x00000200;
const MYSQL_CLIENT_SSL: u32 = 0x00000800;
const MYSQL_CLIENT_SECURE_CONNECTION: u32 = 0x00008000;
const MYSQL_CLIENT_PLUGIN_AUTH: u32 = 0x00080000;

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

/// Detect connection protocol by polling for data and peeking at initial bytes.
/// MySQL is server-speaks-first, so no client data within timeout indicates MySQL.
fn detectProtocol(fd: posix.socket_t) !Protocol {
    var fds = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const ready = posix.poll(&fds, 100) catch return .mysql;
    if (ready == 0) return .mysql;

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
        .mysql => handleMysqlClient(ctx) catch |err| {
            std.debug.print("MySQL client error: {}\n", .{err});
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

// ---- MySQL handling ----

const MysqlPacket = struct {
    payload: []const u8,
    seq: u8,
};

/// Read a MySQL packet from a TCP socket (4-byte header + payload).
fn readMysqlPacketTcp(fd: posix.socket_t, buf: []u8) !MysqlPacket {
    var header: [4]u8 = undefined;
    try readExact(fd, &header);

    const payload_len: usize = @as(usize, header[0]) | (@as(usize, header[1]) << 8) | (@as(usize, header[2]) << 16);
    if (payload_len > buf.len) return error.PacketTooLarge;

    try readExact(fd, buf[0..payload_len]);
    return .{ .payload = buf[0..payload_len], .seq = header[3] };
}

/// Read a MySQL packet from an SSL connection.
fn readMysqlPacketSsl(ssl_obj: *c.SSL, buf: []u8) !MysqlPacket {
    var header: [4]u8 = undefined;
    try sslReadExact(ssl_obj, &header);

    const payload_len: usize = @as(usize, header[0]) | (@as(usize, header[1]) << 8) | (@as(usize, header[2]) << 16);
    if (payload_len > buf.len) return error.PacketTooLarge;

    try sslReadExact(ssl_obj, buf[0..payload_len]);
    return .{ .payload = buf[0..payload_len], .seq = header[3] };
}

/// Write a MySQL packet to a TCP socket.
fn writeMysqlPacketTcp(fd: posix.socket_t, seq: u8, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    header[0] = @intCast(payload.len & 0xFF);
    header[1] = @intCast((payload.len >> 8) & 0xFF);
    header[2] = @intCast((payload.len >> 16) & 0xFF);
    header[3] = seq;
    _ = try posix.write(fd, &header);
    if (payload.len > 0) {
        _ = try posix.write(fd, payload);
    }
}

/// Write a MySQL packet over SSL (header + payload in one SSL_write).
fn writeMysqlPacketSsl(ssl_obj: *c.SSL, seq: u8, payload: []const u8) !void {
    var pkt_buf: [4100]u8 = undefined;
    const total = payload.len + 4;
    if (total > pkt_buf.len) return error.PacketTooLarge;

    pkt_buf[0] = @intCast(payload.len & 0xFF);
    pkt_buf[1] = @intCast((payload.len >> 8) & 0xFF);
    pkt_buf[2] = @intCast((payload.len >> 16) & 0xFF);
    pkt_buf[3] = seq;
    @memcpy(pkt_buf[4 .. 4 + payload.len], payload);

    if (c.SSL_write(ssl_obj, &pkt_buf, @intCast(total)) <= 0) {
        return error.SslWriteFailed;
    }
}

/// Send a MySQL Initial Handshake packet (fake greeting with SSL capability).
fn sendMysqlGreeting(fd: posix.socket_t) !void {
    const server_version = "5.7.99-dockportless";
    const auth_plugin = "mysql_clear_password";

    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    // Protocol version
    payload[pos] = 10;
    pos += 1;

    // Server version (NUL-terminated)
    @memcpy(payload[pos..][0..server_version.len], server_version);
    pos += server_version.len;
    payload[pos] = 0;
    pos += 1;

    // Connection ID (4 bytes LE)
    std.mem.writeInt(u32, payload[pos..][0..4], 1, .little);
    pos += 4;

    // Auth plugin data part 1 (8 bytes)
    const auth_data_1 = [8]u8{ 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
    @memcpy(payload[pos..][0..8], &auth_data_1);
    pos += 8;

    // Filler
    payload[pos] = 0;
    pos += 1;

    // Capability flags lower (2 bytes LE)
    const capabilities: u32 = MYSQL_CLIENT_LONG_PASSWORD | MYSQL_CLIENT_CONNECT_WITH_DB |
        MYSQL_CLIENT_PROTOCOL_41 | MYSQL_CLIENT_SSL |
        MYSQL_CLIENT_SECURE_CONNECTION | MYSQL_CLIENT_PLUGIN_AUTH;
    std.mem.writeInt(u16, payload[pos..][0..2], @intCast(capabilities & 0xFFFF), .little);
    pos += 2;

    // Character set (utf8mb4 = 45)
    payload[pos] = 45;
    pos += 1;

    // Status flags (SERVER_STATUS_AUTOCOMMIT = 0x0002)
    std.mem.writeInt(u16, payload[pos..][0..2], 0x0002, .little);
    pos += 2;

    // Capability flags upper (2 bytes LE)
    std.mem.writeInt(u16, payload[pos..][0..2], @intCast((capabilities >> 16) & 0xFFFF), .little);
    pos += 2;

    // Auth plugin data length (21 = 8 + 12 + NUL)
    payload[pos] = 21;
    pos += 1;

    // Reserved (10 bytes of zeros)
    @memset(payload[pos..][0..10], 0);
    pos += 10;

    // Auth plugin data part 2 (12 bytes + NUL)
    const auth_data_2 = [12]u8{ 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53 };
    @memcpy(payload[pos..][0..12], &auth_data_2);
    pos += 12;
    payload[pos] = 0;
    pos += 1;

    // Auth plugin name (NUL-terminated)
    @memcpy(payload[pos..][0..auth_plugin.len], auth_plugin);
    pos += auth_plugin.len;
    payload[pos] = 0;
    pos += 1;

    try writeMysqlPacketTcp(fd, 0, payload[0..pos]);
}

const MysqlClientInfo = struct {
    username: []const u8,
    database: ?[]const u8,
    password: ?[]const u8,
};

/// Parse a MySQL HandshakeResponse to extract username and database.
pub fn parseMysqlHandshakeResponse(data: []const u8) ?MysqlClientInfo {
    if (data.len < 33) return null;

    const client_flags = std.mem.readInt(u32, data[0..4], .little);

    // Skip: capability_flags(4) + max_packet_size(4) + character_set(1) + reserved(23) = 32
    var pos: usize = 32;

    // Username (NUL-terminated)
    const username_start = pos;
    while (pos < data.len and data[pos] != 0) : (pos += 1) {}
    if (pos >= data.len) return null;
    const username = data[username_start..pos];
    pos += 1; // skip NUL

    // Extract auth response (password in cleartext for mysql_clear_password)
    var password: ?[]const u8 = null;
    if (pos < data.len) {
        if (client_flags & MYSQL_CLIENT_SECURE_CONNECTION != 0) {
            if (pos >= data.len) return null;
            const auth_len: usize = data[pos];
            pos += 1;
            if (auth_len > 0 and pos + auth_len <= data.len) {
                password = data[pos .. pos + auth_len];
            }
            pos += auth_len;
        } else {
            const pw_start = pos;
            while (pos < data.len and data[pos] != 0) : (pos += 1) {}
            if (pos > pw_start) {
                password = data[pw_start..pos];
            }
            if (pos < data.len) pos += 1;
        }
    }

    // Database (if CLIENT_CONNECT_WITH_DB)
    var database: ?[]const u8 = null;
    if (client_flags & MYSQL_CLIENT_CONNECT_WITH_DB != 0 and pos < data.len) {
        const db_start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        if (pos > db_start) {
            database = data[db_start..pos];
        }
    }

    return .{
        .username = username,
        .database = database,
        .password = password,
    };
}

/// Compute mysql_native_password auth hash:
/// SHA1(password) XOR SHA1(auth_seed + SHA1(SHA1(password)))
fn computeMysqlNativeAuth(password: []const u8, auth_seed: []const u8) [20]u8 {
    const Sha1 = std.crypto.hash.Sha1;

    // SHA1(password)
    var sha1_password: [20]u8 = undefined;
    Sha1.hash(password, &sha1_password, .{});

    // SHA1(SHA1(password))
    var sha1_sha1_password: [20]u8 = undefined;
    Sha1.hash(&sha1_password, &sha1_sha1_password, .{});

    // SHA1(auth_seed + SHA1(SHA1(password)))
    var hasher = Sha1.init(.{});
    hasher.update(auth_seed);
    hasher.update(&sha1_sha1_password);
    var sha1_seed_double: [20]u8 = undefined;
    hasher.final(&sha1_seed_double);

    // XOR
    var result: [20]u8 = undefined;
    for (0..20) |i| {
        result[i] = sha1_password[i] ^ sha1_seed_double[i];
    }
    return result;
}

/// Send a MySQL HandshakeResponse to the backend, computing auth hash from
/// the plaintext password and the backend's real auth seed.
fn sendMysqlHandshakeResponse(
    fd: posix.socket_t,
    username: []const u8,
    database: ?[]const u8,
    password: ?[]const u8,
    backend_auth_seed: []const u8,
    backend_auth_plugin: []const u8,
) !void {
    var payload: [512]u8 = undefined;
    var pos: usize = 0;

    var capabilities: u32 = MYSQL_CLIENT_PROTOCOL_41 | MYSQL_CLIENT_SECURE_CONNECTION | MYSQL_CLIENT_LONG_PASSWORD | MYSQL_CLIENT_PLUGIN_AUTH;
    if (database != null) {
        capabilities |= MYSQL_CLIENT_CONNECT_WITH_DB;
    }

    // Capability flags (4 bytes LE)
    std.mem.writeInt(u32, payload[pos..][0..4], capabilities, .little);
    pos += 4;

    // Max packet size (4 bytes LE) - 16MB
    std.mem.writeInt(u32, payload[pos..][0..4], 0x01000000, .little);
    pos += 4;

    // Character set (utf8mb4 = 45)
    payload[pos] = 45;
    pos += 1;

    // Reserved (23 bytes of zeros)
    @memset(payload[pos..][0..23], 0);
    pos += 23;

    // Username (NUL-terminated)
    @memcpy(payload[pos..][0..username.len], username);
    pos += username.len;
    payload[pos] = 0;
    pos += 1;

    // Auth response
    if (password) |pw| {
        if (pw.len > 0 and std.mem.eql(u8, backend_auth_plugin, "mysql_native_password")) {
            // Compute mysql_native_password hash with backend's real seed
            const auth_hash = computeMysqlNativeAuth(pw, backend_auth_seed);
            payload[pos] = 20;
            pos += 1;
            @memcpy(payload[pos..][0..20], &auth_hash);
            pos += 20;
        } else if (pw.len > 0) {
            // For other plugins, send cleartext password (will likely trigger auth switch)
            payload[pos] = @intCast(pw.len);
            pos += 1;
            @memcpy(payload[pos..][0..pw.len], pw);
            pos += pw.len;
        } else {
            payload[pos] = 0;
            pos += 1;
        }
    } else {
        payload[pos] = 0;
        pos += 1;
    }

    // Database (NUL-terminated, if set)
    if (database) |db| {
        @memcpy(payload[pos..][0..db.len], db);
        pos += db.len;
        payload[pos] = 0;
        pos += 1;
    }

    // Auth plugin name (NUL-terminated)
    @memcpy(payload[pos..][0..backend_auth_plugin.len], backend_auth_plugin);
    pos += backend_auth_plugin.len;
    payload[pos] = 0;
    pos += 1;

    try writeMysqlPacketTcp(fd, 1, payload[0..pos]);
}

const MysqlGreetingInfo = struct {
    auth_seed: [20]u8,
    auth_plugin: []const u8,
};

/// Parse a MySQL server greeting to extract auth seed and plugin name.
fn parseMysqlGreeting(data: []const u8) ?MysqlGreetingInfo {
    if (data.len < 1 or data[0] != 10) return null; // protocol version must be 10

    var pos: usize = 1;

    // Skip server version (NUL-terminated)
    while (pos < data.len and data[pos] != 0) : (pos += 1) {}
    if (pos >= data.len) return null;
    pos += 1; // skip NUL

    // Skip connection ID (4 bytes)
    if (pos + 4 > data.len) return null;
    pos += 4;

    // Auth plugin data part 1 (8 bytes)
    if (pos + 8 > data.len) return null;
    var auth_seed: [20]u8 = undefined;
    @memcpy(auth_seed[0..8], data[pos..][0..8]);
    pos += 8;

    // Skip filler (1 byte)
    if (pos + 1 > data.len) return null;
    pos += 1;

    // Skip capability flags lower (2 bytes)
    if (pos + 2 > data.len) return null;
    pos += 2;

    // Skip character set (1), status flags (2), capability flags upper (2)
    if (pos + 5 > data.len) return null;
    pos += 5;

    // Auth plugin data length (1 byte)
    if (pos + 1 > data.len) return null;
    pos += 1;

    // Skip reserved (10 bytes)
    if (pos + 10 > data.len) return null;
    pos += 10;

    // Auth plugin data part 2 (at least 12 bytes + NUL)
    if (pos + 12 > data.len) return null;
    @memcpy(auth_seed[8..20], data[pos..][0..12]);
    pos += 12;

    // Skip NUL terminator of auth data part 2
    if (pos < data.len and data[pos] == 0) pos += 1;

    // Auth plugin name (NUL-terminated)
    var auth_plugin: []const u8 = "mysql_native_password";
    if (pos < data.len) {
        const plugin_start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        if (pos > plugin_start) {
            auth_plugin = data[plugin_start..pos];
        }
    }

    return .{
        .auth_seed = auth_seed,
        .auth_plugin = auth_plugin,
    };
}

/// Handle MySQL auth exchange between proxy and backend, forwarding result to client.
/// If password is available, handles auth switch by re-computing hashes with the correct seed.
fn handleMysqlAuth(backend_fd: posix.socket_t, ssl_obj: *c.SSL, client_hr_seq: u8, password: ?[]const u8) !void {
    const result_seq = client_hr_seq + 1;
    var attempts: usize = 0;

    while (attempts < 10) : (attempts += 1) {
        var ar_buf: [4096]u8 = undefined;
        const ar = try readMysqlPacketTcp(backend_fd, &ar_buf);

        if (ar.payload.len == 0) return error.EmptyAuthPacket;

        switch (ar.payload[0]) {
            0x00 => {
                // OK packet - auth succeeded
                try writeMysqlPacketSsl(ssl_obj, result_seq, ar.payload);
                return;
            },
            0xFF => {
                // ERR packet - auth failed
                try writeMysqlPacketSsl(ssl_obj, result_seq, ar.payload);
                return error.MysqlAuthFailed;
            },
            0xFE => {
                // AuthSwitchRequest: 0xFE + plugin_name(NUL) + auth_data
                if (ar.payload.len > 1) {
                    var switch_pos: usize = 1;
                    // Parse plugin name
                    const plugin_start = switch_pos;
                    while (switch_pos < ar.payload.len and ar.payload[switch_pos] != 0) : (switch_pos += 1) {}
                    const switch_plugin = ar.payload[plugin_start..switch_pos];
                    if (switch_pos < ar.payload.len) switch_pos += 1; // skip NUL

                    // Parse new auth seed
                    var new_seed: [20]u8 = undefined;
                    const seed_data = ar.payload[switch_pos..];
                    const seed_len = @min(seed_data.len, 20);
                    @memcpy(new_seed[0..seed_len], seed_data[0..seed_len]);
                    if (seed_len < 20) @memset(new_seed[seed_len..], 0);

                    if (password) |pw| {
                        if (pw.len > 0 and std.mem.eql(u8, switch_plugin, "mysql_native_password")) {
                            const auth_hash = computeMysqlNativeAuth(pw, &new_seed);
                            try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &auth_hash);
                        } else {
                            // Empty auth response
                            try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &[_]u8{});
                        }
                    } else {
                        try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &[_]u8{});
                    }
                } else {
                    try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &[_]u8{});
                }
            },
            0x01 => {
                // AuthMoreData (caching_sha2_password)
                if (ar.payload.len >= 2) {
                    if (ar.payload[1] == 0x03) {
                        // Fast auth success - next packet should be OK
                        continue;
                    } else if (ar.payload[1] == 0x04) {
                        // Full auth required - send password + NUL
                        if (password) |pw| {
                            var pw_buf: [256]u8 = undefined;
                            if (pw.len < pw_buf.len) {
                                @memcpy(pw_buf[0..pw.len], pw);
                                pw_buf[pw.len] = 0;
                                try writeMysqlPacketTcp(backend_fd, ar.seq + 1, pw_buf[0 .. pw.len + 1]);
                            } else {
                                try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &[_]u8{0x00});
                            }
                        } else {
                            try writeMysqlPacketTcp(backend_fd, ar.seq + 1, &[_]u8{0x00});
                        }
                    } else {
                        continue;
                    }
                }
            },
            else => return error.UnexpectedAuthPacket,
        }
    }
    return error.AuthExchangeTooLong;
}

/// Handle a MySQL client connection with TLS termination and SNI-based routing.
/// Uses mysql_clear_password in the fake greeting to receive the plaintext password,
/// then re-authenticates with the backend using the proper auth plugin and seed.
fn handleMysqlClient(ctx: ClientContext) !void {
    // 1. Send fake MySQL greeting (with mysql_clear_password plugin)
    try sendMysqlGreeting(ctx.client_fd);

    // 2. Read client response (SSL Request or HandshakeResponse)
    var response_buf: [4096]u8 = undefined;
    const response = try readMysqlPacketTcp(ctx.client_fd, &response_buf);

    // Check for SSL capability
    if (response.payload.len < 4) return error.InvalidPacket;
    const client_flags = std.mem.readInt(u32, response.payload[0..4], .little);
    if (client_flags & MYSQL_CLIENT_SSL == 0) {
        std.debug.print("MySQL client does not support SSL, cannot route via SNI\n", .{});
        return error.SslRequired;
    }

    // 3. TLS handshake
    const ssl_obj = c.SSL_new(ctx.ssl_ctx) orelse return error.SslNewFailed;
    defer c.SSL_free(ssl_obj);

    _ = c.SSL_set_fd(ssl_obj, @intCast(ctx.client_fd));
    if (c.SSL_accept(ssl_obj) != 1) return error.SslAcceptFailed;

    // 4. Get SNI hostname
    const servername = c.SSL_get_servername(ssl_obj, c.TLSEXT_NAMETYPE_host_name) orelse return error.NoSni;
    const hostname = std.mem.span(servername);
    const host_info = parseHost(hostname) orelse return error.InvalidHost;

    // 5. Look up backend
    const mappings = try mapping.readAllMappings(ctx.allocator, ctx.mapping_dir_path);
    defer mapping.freeAllMappings(ctx.allocator, mappings);
    const backend_port = findBackendPort(mappings, host_info.project, host_info.service, host_info.port_index) orelse return error.ServiceNotFound;

    // 6. Read client's HandshakeResponse (over TLS, contains cleartext password)
    var hr_buf: [4096]u8 = undefined;
    const hr = try readMysqlPacketSsl(ssl_obj, &hr_buf);
    const mysql_info = parseMysqlHandshakeResponse(hr.payload) orelse return error.InvalidHandshakeResponse;

    // 7. Connect to backend MySQL (plain TCP)
    const backend_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, backend_port);
    const backend_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(backend_fd);

    posix.connect(backend_fd, &backend_addr.any, backend_addr.getOsSockLen()) catch {
        return error.BackendConnectionFailed;
    };

    // 8. Read and parse backend greeting to get real auth seed and plugin
    var bg_buf: [4096]u8 = undefined;
    const bg = try readMysqlPacketTcp(backend_fd, &bg_buf);
    const greeting_info = parseMysqlGreeting(bg.payload) orelse return error.InvalidBackendGreeting;

    // 9. Send HandshakeResponse to backend with proper auth hash
    try sendMysqlHandshakeResponse(
        backend_fd,
        mysql_info.username,
        mysql_info.database,
        mysql_info.password,
        &greeting_info.auth_seed,
        greeting_info.auth_plugin,
    );

    // 10. Handle backend auth exchange (with password for auth switch)
    handleMysqlAuth(backend_fd, ssl_obj, hr.seq, mysql_info.password) catch |err| {
        if (err == error.MysqlAuthFailed) {
            std.debug.print("MySQL auth failed for user via SNI proxy\n", .{});
        }
        return err;
    };

    // 11. Bidirectional forwarding (TLS client <-> plain TCP backend)
    forwardBidirectional(ssl_obj, ctx.client_fd, backend_fd);

    _ = c.SSL_shutdown(ssl_obj);
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

test "parseMysqlHandshakeResponse: with username and database" {
    // Build a minimal HandshakeResponse
    var data: [128]u8 = undefined;

    // Capability flags (CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_CONNECT_WITH_DB)
    const flags: u32 = MYSQL_CLIENT_PROTOCOL_41 | MYSQL_CLIENT_SECURE_CONNECTION | MYSQL_CLIENT_CONNECT_WITH_DB;
    std.mem.writeInt(u32, data[0..4], flags, .little);

    // Max packet size
    std.mem.writeInt(u32, data[4..8], 0x01000000, .little);

    // Character set
    data[8] = 45;

    // Reserved (23 zeros)
    @memset(data[9..32], 0);

    // Username "root" + NUL
    @memcpy(data[32..36], "root");
    data[36] = 0;

    // Auth response length = 0 (empty password)
    data[37] = 0;

    // Database "testdb" + NUL
    @memcpy(data[38..44], "testdb");
    data[44] = 0;

    const info = parseMysqlHandshakeResponse(data[0..45]).?;
    try std.testing.expectEqualStrings("root", info.username);
    try std.testing.expectEqualStrings("testdb", info.database.?);
    try std.testing.expect(info.password == null);
}

test "parseMysqlHandshakeResponse: without database" {
    var data: [128]u8 = undefined;

    const flags: u32 = MYSQL_CLIENT_PROTOCOL_41 | MYSQL_CLIENT_SECURE_CONNECTION;
    std.mem.writeInt(u32, data[0..4], flags, .little);
    std.mem.writeInt(u32, data[4..8], 0x01000000, .little);
    data[8] = 45;
    @memset(data[9..32], 0);

    @memcpy(data[32..36], "user");
    data[36] = 0;

    // Auth response length = 0
    data[37] = 0;

    const info = parseMysqlHandshakeResponse(data[0..38]).?;
    try std.testing.expectEqualStrings("user", info.username);
    try std.testing.expect(info.database == null);
    try std.testing.expect(info.password == null);
}

test "parseMysqlHandshakeResponse: with auth data" {
    var data: [128]u8 = undefined;

    const flags: u32 = MYSQL_CLIENT_PROTOCOL_41 | MYSQL_CLIENT_SECURE_CONNECTION | MYSQL_CLIENT_CONNECT_WITH_DB;
    std.mem.writeInt(u32, data[0..4], flags, .little);
    std.mem.writeInt(u32, data[4..8], 0x01000000, .little);
    data[8] = 45;
    @memset(data[9..32], 0);

    @memcpy(data[32..37], "admin");
    data[37] = 0;

    // Auth response length = 20 (sha1 hash)
    data[38] = 20;
    @memset(data[39..59], 0xAA); // fake auth data

    // Database "mydb" + NUL
    @memcpy(data[59..63], "mydb");
    data[63] = 0;

    const info = parseMysqlHandshakeResponse(data[0..64]).?;
    try std.testing.expectEqualStrings("admin", info.username);
    try std.testing.expectEqualStrings("mydb", info.database.?);
    // Auth data is the 20 bytes of 0xAA (cleartext password from mysql_clear_password)
    try std.testing.expectEqual(@as(usize, 20), info.password.?.len);
}

test "parseMysqlHandshakeResponse: too short" {
    const data = [_]u8{0} ** 20;
    try std.testing.expect(parseMysqlHandshakeResponse(&data) == null);
}

test "computeMysqlNativeAuth: produces 20-byte hash" {
    const password = "secret";
    const seed = [20]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14 };
    const result = computeMysqlNativeAuth(password, &seed);
    // Result should be 20 bytes and non-zero
    try std.testing.expectEqual(@as(usize, 20), result.len);
    var all_zero = true;
    for (result) |b| {
        if (b != 0) all_zero = false;
    }
    try std.testing.expect(!all_zero);
}

test "computeMysqlNativeAuth: same inputs produce same output" {
    const password = "test123";
    const seed = [20]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x01, 0x02, 0x03, 0x04, 0x05 };
    const result1 = computeMysqlNativeAuth(password, &seed);
    const result2 = computeMysqlNativeAuth(password, &seed);
    try std.testing.expectEqualSlices(u8, &result1, &result2);
}

test "computeMysqlNativeAuth: different seeds produce different output" {
    const password = "test123";
    const seed1 = [20]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14 };
    const seed2 = [20]u8{ 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1, 0xF0, 0xEF, 0xEE, 0xED, 0xEC };
    const result1 = computeMysqlNativeAuth(password, &seed1);
    const result2 = computeMysqlNativeAuth(password, &seed2);
    try std.testing.expect(!std.mem.eql(u8, &result1, &result2));
}

test "parseMysqlGreeting: valid greeting" {
    // Construct a minimal MySQL greeting
    var data: [128]u8 = undefined;
    var pos: usize = 0;

    // Protocol version
    data[pos] = 10;
    pos += 1;

    // Server version "8.0.0" + NUL
    @memcpy(data[pos..][0..5], "8.0.0");
    pos += 5;
    data[pos] = 0;
    pos += 1;

    // Connection ID
    std.mem.writeInt(u32, data[pos..][0..4], 42, .little);
    pos += 4;

    // Auth data part 1 (8 bytes)
    const seed_part1 = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    @memcpy(data[pos..][0..8], &seed_part1);
    pos += 8;

    // Filler
    data[pos] = 0;
    pos += 1;

    // Capability flags lower
    std.mem.writeInt(u16, data[pos..][0..2], 0xFFFF, .little);
    pos += 2;

    // Character set, status flags, capability upper
    data[pos] = 45;
    pos += 1;
    std.mem.writeInt(u16, data[pos..][0..2], 0x0002, .little);
    pos += 2;
    std.mem.writeInt(u16, data[pos..][0..2], 0x00FF, .little);
    pos += 2;

    // Auth plugin data length
    data[pos] = 21;
    pos += 1;

    // Reserved (10 zeros)
    @memset(data[pos..][0..10], 0);
    pos += 10;

    // Auth data part 2 (12 bytes + NUL)
    const seed_part2 = [12]u8{ 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05 };
    @memcpy(data[pos..][0..12], &seed_part2);
    pos += 12;
    data[pos] = 0;
    pos += 1;

    // Auth plugin name
    const plugin = "mysql_native_password";
    @memcpy(data[pos..][0..plugin.len], plugin);
    pos += plugin.len;
    data[pos] = 0;
    pos += 1;

    const info = parseMysqlGreeting(data[0..pos]).?;
    try std.testing.expectEqualSlices(u8, &seed_part1, info.auth_seed[0..8]);
    try std.testing.expectEqualSlices(u8, &seed_part2, info.auth_seed[8..20]);
    try std.testing.expectEqualStrings("mysql_native_password", info.auth_plugin);
}

test "parseMysqlGreeting: invalid protocol version" {
    const data = [_]u8{ 9, 0 }; // protocol version 9, not 10
    try std.testing.expect(parseMysqlGreeting(&data) == null);
}
