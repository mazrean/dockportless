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

/// Parse a compose file and return a list of service names.
pub fn parseServices(allocator: Allocator, dir: std.fs.Dir, file_path: []const u8) ![]const []const u8 {
    const source = dir.readFileAlloc(allocator, file_path, 1024 * 1024) catch {
        return ComposeError.FileNotFound;
    };
    defer allocator.free(source);

    return parseServicesFromSource(allocator, source);
}

/// Extract service names from YAML source.
fn parseServicesFromSource(allocator: Allocator, source: []const u8) ![]const []const u8 {
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
    const result = try allocator.alloc([]const u8, keys.len);
    for (keys, 0..) |key, i| {
        result[i] = try allocator.dupe(u8, key);
    }

    return result;
}

pub fn freeServices(allocator: Allocator, services: []const []const u8) void {
    for (services) |service| {
        allocator.free(service);
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
    try std.testing.expectEqualStrings("web", services[0]);
    try std.testing.expectEqualStrings("api", services[1]);
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
    try std.testing.expectEqualStrings("db", services[0]);
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
