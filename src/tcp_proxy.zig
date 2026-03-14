const std = @import("std");
const posix = std.posix;
const mapping = @import("mapping.zig");
const proxy = @import("proxy.zig");
const cert = @import("cert.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const PROXY_TLS_PORT: u16 = 7356;

/// Start the TLS proxy server (blocking).
pub fn start(allocator: Allocator, mapping_dir_path: []const u8, cert_paths: cert.CertPaths) !void {
    // Initialize OpenSSL context
    const method = c.TLS_server_method() orelse return error.SslInitFailed;
    const ctx = c.SSL_CTX_new(method) orelse return error.SslCtxFailed;
    defer c.SSL_CTX_free(ctx);

    // Convert paths to null-terminated for C API
    const cert_path_z = try allocator.dupeZ(u8, cert_paths.server_cert);
    defer allocator.free(cert_path_z);
    const key_path_z = try allocator.dupeZ(u8, cert_paths.server_key);
    defer allocator.free(key_path_z);

    // Load certificate and private key
    if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path_z.ptr) != 1) {
        return error.SslCertLoadFailed;
    }
    if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path_z.ptr, c.SSL_FILETYPE_PEM) != 1) {
        return error.SslKeyLoadFailed;
    }

    // Create listening socket
    const listen_fd = try createListenSocket();
    defer posix.close(listen_fd);

    std.debug.print("TLS proxy server listening on :{d}\n", .{PROXY_TLS_PORT});

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_fd = posix.accept(listen_fd, &client_addr, &addr_len, 0) catch continue;

        const thread_ctx = TlsClientContext{
            .client_fd = client_fd,
            .allocator = allocator,
            .ssl_ctx = ctx,
            .mapping_dir_path = mapping_dir_path,
        };

        const thread = std.Thread.spawn(.{}, tlsClientThread, .{thread_ctx}) catch {
            posix.close(client_fd);
            continue;
        };
        thread.detach();
    }
}

fn createListenSocket() !posix.socket_t {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(sock);

    // SO_REUSEPORT
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    // SO_REUSEADDR
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, PROXY_TLS_PORT);
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
    try posix.listen(sock, 128);

    return sock;
}

const TlsClientContext = struct {
    client_fd: posix.socket_t,
    allocator: Allocator,
    ssl_ctx: *c.SSL_CTX,
    mapping_dir_path: []const u8,
};

fn tlsClientThread(ctx: TlsClientContext) void {
    defer posix.close(ctx.client_fd);

    handleTlsClient(ctx) catch |err| {
        std.debug.print("TLS client error: {}\n", .{err});
    };
}

fn handleTlsClient(ctx: TlsClientContext) !void {
    // Create SSL object
    const ssl_obj = c.SSL_new(ctx.ssl_ctx) orelse return error.SslNewFailed;
    defer c.SSL_free(ssl_obj);

    _ = c.SSL_set_fd(ssl_obj, @intCast(ctx.client_fd));

    // TLS handshake
    if (c.SSL_accept(ssl_obj) != 1) {
        return error.SslAcceptFailed;
    }

    // Get SNI hostname from the completed handshake
    const servername = c.SSL_get_servername(ssl_obj, c.TLSEXT_NAMETYPE_host_name) orelse {
        return error.NoSni;
    };
    const hostname = std.mem.span(servername);

    // Parse hostname: <service>.<project>.localhost
    const host_info = proxy.parseHost(hostname) orelse {
        return error.InvalidHost;
    };

    // Look up backend port
    const mappings = try mapping.readAllMappings(ctx.allocator, ctx.mapping_dir_path);
    defer mapping.freeAllMappings(ctx.allocator, mappings);

    const backend_port = findBackendPort(mappings, host_info.project, host_info.service) orelse {
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

        // Check if SSL has buffered decrypted data
        const ssl_pending = c.SSL_pending(ssl_obj);
        const timeout: i32 = if (ssl_pending > 0) 0 else 60_000;

        const ready = posix.poll(&fds, timeout) catch break;

        // Timeout with no pending data
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

        // Check for errors
        if (ready > 0) {
            if (fds[0].revents & posix.POLL.ERR != 0) break;
            if (fds[1].revents & posix.POLL.ERR != 0) break;
        }
    }
}

fn findBackendPort(mappings: []const mapping.ProjectMapping, project: []const u8, service: []const u8) ?u16 {
    for (mappings) |m| {
        if (!std.mem.eql(u8, m.project_name, project)) continue;
        for (m.services) |svc| {
            if (std.mem.eql(u8, svc.service_name, service)) return svc.port;
        }
    }
    return null;
}
