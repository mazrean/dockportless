const std = @import("std");
const yaml = @import("yaml");

const Allocator = std.mem.Allocator;

pub const ComposeError = error{
    FileNotFound,
    NoServicesFound,
    InvalidYaml,
};

const compose_filenames = [_][]const u8{
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
};

/// Auto-detect and return a compose file from the given directory.
pub fn findComposeFile(dir: std.fs.Dir) ComposeError![]const u8 {
    for (&compose_filenames) |name| {
        if (dir.statFile(name)) |_| {
            return name;
        } else |_| {}
    }
    return ComposeError.FileNotFound;
}

pub const ServiceInfo = struct {
    name: []const u8,
    port_count: usize,
};

/// Parse a compose file and return a list of services with port counts.
pub fn parseServices(allocator: Allocator, dir: std.fs.Dir, file_path: []const u8) ![]const ServiceInfo {
    const source = dir.readFileAlloc(allocator, file_path, 1024 * 1024) catch {
        return ComposeError.FileNotFound;
    };
    defer allocator.free(source);

    return parseServicesFromSource(allocator, source);
}

/// Extract service info (name + port count) from YAML source.
fn parseServicesFromSource(allocator: Allocator, source: []const u8) ![]const ServiceInfo {
    var doc = yaml.Yaml{ .source = source };
    defer doc.deinit(allocator);

    doc.load(allocator) catch {
        return ComposeError.InvalidYaml;
    };

    if (doc.docs.items.len == 0) {
        return ComposeError.NoServicesFound;
    }

    const root = doc.docs.items[0];
    const root_map = root.asMap() orelse return ComposeError.NoServicesFound;

    const services_value = root_map.get("services") orelse return ComposeError.NoServicesFound;
    const services_map = services_value.asMap() orelse return ComposeError.NoServicesFound;

    const keys = services_map.keys();
    const values = services_map.values();
    const result = try allocator.alloc(ServiceInfo, keys.len);
    for (keys, values, 0..) |key, value, i| {
        var port_count: usize = 1; // default: 1 port per service
        if (value.asMap()) |svc_map| {
            if (svc_map.get("ports")) |ports_value| {
                if (ports_value.asList()) |ports_list| {
                    if (ports_list.len > 0) {
                        port_count = ports_list.len;
                    }
                }
            }
        }
        result[i] = .{
            .name = try allocator.dupe(u8, key),
            .port_count = port_count,
        };
    }

    return result;
}

/// Extract compose file paths from command arguments.
/// Scans for -f/--file flags in the command arguments.
/// Returns null if no -f flags found.
pub fn extractComposeFilesFromArgs(allocator: Allocator, cmd_args: []const []const u8) !?[]const []const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < cmd_args.len) {
                try files.append(allocator, cmd_args[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            try files.append(allocator, arg["--file=".len..]);
        }
    }

    if (files.items.len == 0) return null;

    const result = try allocator.alloc([]const u8, files.items.len);
    @memcpy(result, files.items);
    return result;
}

pub fn freeServices(allocator: Allocator, services: []const ServiceInfo) void {
    for (services) |service| {
        allocator.free(service.name);
    }
    allocator.free(services);
}

// --- Tests ---

test "parseServicesFromSource: basic compose file" {
    const source =
        \\services:
        \\  web:
        \\    image: nginx
        \\  api:
        \\    image: node
    ;

    const allocator = std.testing.allocator;
    const services = try parseServicesFromSource(allocator, source);
    defer freeServices(allocator, services);

    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("web", services[0].name);
    try std.testing.expectEqual(@as(usize, 1), services[0].port_count);
    try std.testing.expectEqualStrings("api", services[1].name);
    try std.testing.expectEqual(@as(usize, 1), services[1].port_count);
}

test "parseServicesFromSource: no services key" {
    const source =
        \\version: "3"
        \\networks:
        \\  default:
    ;

    const allocator = std.testing.allocator;
    const result = parseServicesFromSource(allocator, source);
    try std.testing.expectError(ComposeError.NoServicesFound, result);
}

test "parseServicesFromSource: empty services" {
    const source =
        \\services:
    ;

    const allocator = std.testing.allocator;
    const result = parseServicesFromSource(allocator, source);
    // "services:" with no children is parsed as a non-map value
    try std.testing.expectError(ComposeError.NoServicesFound, result);
}

test "parseServicesFromSource: invalid yaml" {
    const source =
        \\[invalid: yaml: content
    ;

    const allocator = std.testing.allocator;
    const result = parseServicesFromSource(allocator, source);
    try std.testing.expectError(ComposeError.InvalidYaml, result);
}

test "parseServicesFromSource: single service" {
    const source =
        \\services:
        \\  db:
        \\    image: postgres
    ;

    const allocator = std.testing.allocator;
    const services = try parseServicesFromSource(allocator, source);
    defer freeServices(allocator, services);

    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("db", services[0].name);
    try std.testing.expectEqual(@as(usize, 1), services[0].port_count);
}

test "parseServicesFromSource: service with multiple ports" {
    const source =
        \\services:
        \\  web:
        \\    image: nginx
        \\    ports:
        \\      - "8080:80"
        \\      - "8443:443"
        \\  api:
        \\    image: node
        \\    ports:
        \\      - "3000:3000"
    ;

    const allocator = std.testing.allocator;
    const services = try parseServicesFromSource(allocator, source);
    defer freeServices(allocator, services);

    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("web", services[0].name);
    try std.testing.expectEqual(@as(usize, 2), services[0].port_count);
    try std.testing.expectEqualStrings("api", services[1].name);
    try std.testing.expectEqual(@as(usize, 1), services[1].port_count);
}

// --- extractComposeFilesFromArgs tests ---

test "extractComposeFilesFromArgs: docker compose -f" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "docker", "compose", "-f", "custom.yml", "up" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("custom.yml", result.?[0]);
}

test "extractComposeFilesFromArgs: podman compose --file" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "podman", "compose", "--file", "my-compose.yaml", "up", "-d" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("my-compose.yaml", result.?[0]);
}

test "extractComposeFilesFromArgs: multiple -f flags" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "docker", "compose", "-f", "a.yml", "-f", "b.yml", "up" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.len);
    try std.testing.expectEqualStrings("a.yml", result.?[0]);
    try std.testing.expectEqualStrings("b.yml", result.?[1]);
}

test "extractComposeFilesFromArgs: --file= syntax" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "docker", "compose", "--file=custom.yml", "up" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("custom.yml", result.?[0]);
}

test "extractComposeFilesFromArgs: docker-compose (single binary)" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "docker-compose", "-f", "test.yml", "up" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test.yml", result.?[0]);
}

test "extractComposeFilesFromArgs: no -f flag returns null" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "docker", "compose", "up" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    try std.testing.expect(result == null);
}

test "extractComposeFilesFromArgs: any command with -f" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "make", "-f", "Makefile", "build" };
    const result = try extractComposeFilesFromArgs(allocator, args);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Makefile", result.?[0]);
}

test "extractComposeFilesFromArgs: empty args" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{};
    const result = try extractComposeFilesFromArgs(allocator, args);
    try std.testing.expect(result == null);
}

test "findComposeFile: file not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = findComposeFile(tmp.dir);
    try std.testing.expectError(ComposeError.FileNotFound, result);
}

test "findComposeFile: compose.yml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.writeFile(.{ .sub_path = "compose.yml", .data = "services:\n  web:\n    image: nginx\n" }) catch unreachable;

    const result = try findComposeFile(tmp.dir);
    try std.testing.expectEqualStrings("compose.yml", result);
}

test "findComposeFile: docker-compose.yml has priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.writeFile(.{ .sub_path = "docker-compose.yml", .data = "services:\n  web:\n    image: nginx\n" }) catch unreachable;
    tmp.dir.writeFile(.{ .sub_path = "compose.yml", .data = "services:\n  api:\n    image: node\n" }) catch unreachable;

    const result = try findComposeFile(tmp.dir);
    try std.testing.expectEqualStrings("docker-compose.yml", result);
}
