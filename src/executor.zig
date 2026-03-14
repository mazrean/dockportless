const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;

/// Convert a service name to an uppercase env var prefix.
/// - Convert to uppercase
/// - Replace hyphens with underscores
fn serviceNameToUpperCase(allocator: Allocator, service_name: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, service_name.len);

    for (service_name, 0..) |c, i| {
        result[i] = switch (c) {
            '-' => '_',
            'a'...'z' => c - ('a' - 'A'),
            else => c,
        };
    }

    return result;
}

/// Convert a service name to a base environment variable name (no index).
/// e.g. "web" -> "WEB_PORT"
pub fn serviceNameToBaseEnvVar(allocator: Allocator, service_name: []const u8) ![]u8 {
    const upper = try serviceNameToUpperCase(allocator, service_name);
    defer allocator.free(upper);

    return std.fmt.allocPrint(allocator, "{s}_PORT", .{upper});
}

/// Convert a service name to an indexed environment variable name.
/// e.g. ("web", 0) -> "WEB_PORT_0"
pub fn serviceNameToEnvVar(allocator: Allocator, service_name: []const u8, index: usize) ![]u8 {
    const upper = try serviceNameToUpperCase(allocator, service_name);
    defer allocator.free(upper);

    return std.fmt.allocPrint(allocator, "{s}_PORT_{d}", .{ upper, index });
}

pub const ServicePorts = struct {
    service_name: []const u8,
    ports: []const u16,
};

/// Set environment variables and execute the user command as a child process, waiting for it to finish.
pub fn exec(allocator: Allocator, argv: []const []const u8, services: []const ServicePorts) !std.process.Child.Term {
    // Copy current environment
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Add service port environment variables
    for (services) |svc| {
        for (svc.ports, 0..) |svc_port, idx| {
            const env_name = try serviceNameToEnvVar(allocator, svc.service_name, idx);
            defer allocator.free(env_name);

            var port_buf: [5]u8 = undefined;
            const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{svc_port}) catch unreachable;

            try env_map.put(env_name, port_str);

            // SERVICE_PORT alias for index 0
            if (idx == 0) {
                const alias = try serviceNameToBaseEnvVar(allocator, svc.service_name);
                defer allocator.free(alias);
                try env_map.put(alias, port_str);
            }
        }
    }

    // Spawn child process and wait
    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;

    try child.spawn();
    const term = try child.wait();
    return term;
}

// --- Tests ---

test "serviceNameToEnvVar: simple name index 0" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "web", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("WEB_PORT_0", result);
}

test "serviceNameToEnvVar: name with hyphen index 1" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my-web", 1);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_WEB_PORT_1", result);
}

test "serviceNameToEnvVar: already uppercase" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "API", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("API_PORT_0", result);
}

test "serviceNameToEnvVar: mixed case with hyphens" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my-Web-App", 2);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_WEB_APP_PORT_2", result);
}

test "serviceNameToEnvVar: name with underscore" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToEnvVar(allocator, "my_db", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_DB_PORT_0", result);
}

test "serviceNameToBaseEnvVar: simple name" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToBaseEnvVar(allocator, "web");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("WEB_PORT", result);
}

test "serviceNameToBaseEnvVar: name with hyphen" {
    const allocator = std.testing.allocator;
    const result = try serviceNameToBaseEnvVar(allocator, "my-web");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MY_WEB_PORT", result);
}
