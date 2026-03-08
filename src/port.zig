const std = @import("std");
const posix = std.posix;

/// Allocate a single unused port from the OS.
/// Uses bind(0) to let the OS assign a port, retrieves it via getsockname(), then closes the socket.
pub fn allocatePort() !u16 {
    const addr: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    try posix.bind(sock, &addr.any, addr.getOsSockLen());

    var bound_addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(sock, &bound_addr, &addr_len);

    const in_addr: *const posix.sockaddr.in = @ptrCast(@alignCast(&bound_addr));
    const port = std.mem.bigToNative(u16, in_addr.port);
    return port;
}

/// Allocate multiple unused ports at once.
pub fn allocatePorts(allocator: std.mem.Allocator, count: usize) ![]u16 {
    const ports = try allocator.alloc(u16, count);
    errdefer allocator.free(ports);

    for (0..count) |i| {
        ports[i] = try allocatePort();
    }

    return ports;
}

// --- Tests ---

test "allocatePort: returns valid port" {
    const port = try allocatePort();
    try std.testing.expect(port > 0);
}

test "allocatePort: port is actually unused" {
    const port = try allocatePort();

    // Verify we can bind to the returned port
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    posix.bind(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        std.debug.print("Failed to bind to allocated port {d}: {}\n", .{ port, err });
        return err;
    };
}

test "allocatePorts: no duplicates" {
    const allocator = std.testing.allocator;
    const count = 10;
    const ports = try allocatePorts(allocator, count);
    defer allocator.free(ports);

    try std.testing.expectEqual(@as(usize, count), ports.len);

    // Check no duplicates
    for (0..count) |i| {
        try std.testing.expect(ports[i] > 0);
        for (i + 1..count) |j| {
            try std.testing.expect(ports[i] != ports[j]);
        }
    }
}

test "allocatePorts: zero count" {
    const allocator = std.testing.allocator;
    const ports = try allocatePorts(allocator, 0);
    defer allocator.free(ports);

    try std.testing.expectEqual(@as(usize, 0), ports.len);
}
