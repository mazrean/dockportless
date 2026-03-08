const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;

/// Convert a service name to an environment variable name.
/// - Convert to uppercase
/// - Replace hyphens with underscores
/// - Append _PORT suffix
pub fn serviceNameToEnvVar(allocator: Allocator, service_name: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, service_name.len + "_PORT".len);

    for (service_name, 0..) |c, i| {
        result[i] = switch (c) {
            '-' => '_',
            'a'...'z' => c - ('a' - 'A'),
            else => c,
        };
    }

    @memcpy(result[service_name.len..], "_PORT");

    return result;
}

pub const ServicePort = struct {
    service_name: []const u8,
    port: u16,
};

/// Set environment variables and execute the user command as a child process, waiting for it to finish.
pub fn exec(allocator: Allocator, argv: []const []const u8, services: []const ServicePort) !std.process.Child.Term {
    // Copy current environment
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Add service port environment variables
    for (services) |svc| {
        const env_name = try serviceNameToEnvVar(allocator, svc.service_name);
        defer allocator.free(env_name);

        var port_buf: [5]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{svc.port}) catch unreachable;

        try env_map.put(env_name, port_str);
    }

    // Spawn child process and wait
    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;

    try child.spawn();
    const term = try child.wait();
    return term;
}

// --- Tests ---

test "serviceNameToEnvVar: simple name" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "web");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("WEB_PORT", result);
}

test "serviceNameToEnvVar: name with hyphen" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my-web");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_WEB_PORT", result);
}

test "serviceNameToEnvVar: already uppercase" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "API");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("API_PORT", result);
}

test "serviceNameToEnvVar: mixed case with hyphens" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my-Web-App");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_WEB_APP_PORT", result);
}

test "serviceNameToEnvVar: name with underscore" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my_db");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_DB_PORT", result);
}
