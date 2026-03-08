const std = @import("std");
const posix = std.posix;

/// Allocate a single unused port from the OS, avoiding reserved ports.
/// Uses bind(0) to let the OS assign a port, retrieves it via getsockname(), then closes the socket.
/// If the assigned port is in the reserved set, retries up to max_retries times.
fn allocatePortAvoiding(reserved: []const u16) !u16 {
    const max_retries = 100;
    var attempt: usize = 0;
    while (attempt < max_retries) : (attempt += 1) {
        const addr: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        try posix.bind(sock, &addr.any, addr.getOsSockLen());

        var bound_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(sock, &bound_addr, &addr_len);

        const in_addr: *const posix.sockaddr.in = @ptrCast(@alignCast(&bound_addr));
        const port = std.mem.bigToNative(u16, in_addr.port);

        // Check if port is reserved
        var is_reserved = false;
        for (reserved) |r| {
            if (r == port) {
                is_reserved = true;
                break;
            }
        }
        if (!is_reserved) return port;
    }
    return error.PortAllocationFailed;
}

/// Allocate a single unused port from the OS (no reserved ports).
pub fn allocatePort() !u16 {
    return allocatePortAvoiding(&.{});
}

/// Allocate multiple unused ports at once, avoiding the given reserved ports.
/// Reserved ports typically come from existing mapping files.
pub fn allocatePorts(allocator: std.mem.Allocator, count: usize, reserved_ports: []const u16) ![]u16 {
    const ports = try allocator.alloc(u16, count);
    errdefer allocator.free(ports);

    // Build combined exclusion list: reserved + already allocated in this call
    var all_excluded: std.ArrayListUnmanaged(u16) = .{};
    defer all_excluded.deinit(allocator);
    try all_excluded.appendSlice(allocator, reserved_ports);

    for (0..count) |i| {
        const p = try allocatePortAvoiding(all_excluded.items);
        ports[i] = p;
        try all_excluded.append(allocator, p);
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
    const ports = try allocatePorts(allocator, count, &.{});
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
    const ports = try allocatePorts(allocator, 0, &.{});
    defer allocator.free(ports);

    try std.testing.expectEqual(@as(usize, 0), ports.len);
}

test "allocatePorts: avoids reserved ports" {
    const allocator = std.testing.allocator;

    // First allocate a port to use as reserved
    const reserved_port = try allocatePort();
    const reserved = [_]u16{reserved_port};

    const count = 5;
    const ports = try allocatePorts(allocator, count, &reserved);
    defer allocator.free(ports);

    // None of the allocated ports should be the reserved port
    for (ports) |p| {
        try std.testing.expect(p != reserved_port);
    }
}
