const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;

pub const ServiceMapping = struct {
    service_name: []const u8,
    ports: []const u16,
};

pub const ProjectMapping = struct {
    project_name: []const u8,
    services: []const ServiceMapping,
    pid: i32,
};

/// Get the mapping directory path.
/// Uses $XDG_RUNTIME_DIR/dockportless/ (fallback: /tmp/dockportless/).
pub fn getMappingDir(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |runtime_dir| {
        defer allocator.free(runtime_dir);
        return std.fmt.allocPrint(allocator, "{s}/dockportless", .{runtime_dir});
    } else |_| {
        return allocator.dupe(u8, "/tmp/dockportless");
    }
}

/// Write a project mapping to a JSON file.
pub fn writeMapping(allocator: Allocator, dir: std.fs.Dir, project: ProjectMapping) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{project.project_name});
    defer allocator.free(filename);

    var json_services = try allocator.alloc(JsonService, project.services.len);
    defer allocator.free(json_services);
    for (project.services, 0..) |svc, i| {
        json_services[i] = .{
            .service_name = svc.service_name,
            .ports = svc.ports,
        };
    }

    const json_data = JsonMapping{
        .project_name = project.project_name,
        .pid = project.pid,
        .services = json_services,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, json_data, .{});
    defer allocator.free(json_bytes);

    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(json_bytes);
}

/// Read all project mappings from the mapping directory.
pub fn readAllMappings(allocator: Allocator, dir_path: []const u8) ![]ProjectMapping {
    var mappings: std.ArrayListUnmanaged(ProjectMapping) = .{};
    errdefer {
        for (mappings.items) |*m| {
            freeMappingContents(allocator, m);
        }
        mappings.deinit(allocator);
    }

    var iter_dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return mappings.toOwnedSlice(allocator),
        else => return err,
    };
    defer iter_dir.close();

    var iter = iter_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        if (readSingleMapping(allocator, iter_dir, entry.name)) |mapping| {
            try mappings.append(allocator, mapping);
        } else |_| {
            // Skip invalid files
        }
    }

    return mappings.toOwnedSlice(allocator);
}

fn readSingleMapping(allocator: Allocator, dir: std.fs.Dir, filename: []const u8) !ProjectMapping {
    const content = try dir.readFileAlloc(allocator, filename, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(JsonMapping, allocator, content, .{});
    defer parsed.deinit();

    const v = parsed.value;

    const services = try allocator.alloc(ServiceMapping, v.services.len);
    errdefer allocator.free(services);

    for (v.services, 0..) |svc, i| {
        services[i] = .{
            .service_name = try allocator.dupe(u8, svc.service_name),
            .ports = try allocator.dupe(u16, svc.ports),
        };
    }

    return ProjectMapping{
        .project_name = try allocator.dupe(u8, v.project_name),
        .services = services,
        .pid = v.pid,
    };
}

/// Delete a project mapping file.
pub fn removeMapping(allocator: Allocator, dir: std.fs.Dir, project_name: []const u8) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{project_name});
    defer allocator.free(filename);

    dir.deleteFile(filename) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn freeMappingContents(allocator: Allocator, m: *ProjectMapping) void {
    for (m.services) |svc| {
        allocator.free(svc.service_name);
        allocator.free(svc.ports);
    }
    allocator.free(m.services);
    allocator.free(m.project_name);
}

pub fn freeAllMappings(allocator: Allocator, mappings: []ProjectMapping) void {
    for (mappings) |*m| {
        freeMappingContents(allocator, m);
    }
    allocator.free(mappings);
}

// JSON serialization types
const JsonService = struct {
    service_name: []const u8,
    ports: []const u16,
};

const JsonMapping = struct {
    project_name: []const u8,
    pid: i32,
    services: []const JsonService,
};

// --- Tests ---

fn tmpDirPath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return try tmp.dir.realpath(".", buf);
}

test "writeMapping and readAllMappings round-trip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &path_buf);

    const web_ports = &[_]u16{ 49152, 49154 };
    const api_ports = &[_]u16{49153};
    const services = &[_]ServiceMapping{
        .{ .service_name = "web", .ports = web_ports },
        .{ .service_name = "api", .ports = api_ports },
    };

    const project = ProjectMapping{
        .project_name = "myapp",
        .services = services,
        .pid = 12345,
    };

    try writeMapping(allocator, tmp.dir, project);

    const mappings = try readAllMappings(allocator, dir_path);
    defer freeAllMappings(allocator, mappings);

    try std.testing.expectEqual(@as(usize, 1), mappings.len);
    try std.testing.expectEqualStrings("myapp", mappings[0].project_name);
    try std.testing.expectEqual(@as(i32, 12345), mappings[0].pid);
    try std.testing.expectEqual(@as(usize, 2), mappings[0].services.len);
    try std.testing.expectEqualStrings("web", mappings[0].services[0].service_name);
    try std.testing.expectEqual(@as(usize, 2), mappings[0].services[0].ports.len);
    try std.testing.expectEqual(@as(u16, 49152), mappings[0].services[0].ports[0]);
    try std.testing.expectEqual(@as(u16, 49154), mappings[0].services[0].ports[1]);
    try std.testing.expectEqualStrings("api", mappings[0].services[1].service_name);
    try std.testing.expectEqual(@as(usize, 1), mappings[0].services[1].ports.len);
    try std.testing.expectEqual(@as(u16, 49153), mappings[0].services[1].ports[0]);
}

test "removeMapping deletes file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const web_ports = &[_]u16{8080};
    const services = &[_]ServiceMapping{
        .{ .service_name = "web", .ports = web_ports },
    };

    const project = ProjectMapping{
        .project_name = "testproj",
        .services = services,
        .pid = 999,
    };

    try writeMapping(allocator, tmp.dir, project);

    // File should exist
    _ = try tmp.dir.statFile("testproj.json");

    try removeMapping(allocator, tmp.dir, "testproj");

    // File should be gone
    const stat_result = tmp.dir.statFile("testproj.json");
    try std.testing.expectError(error.FileNotFound, stat_result);
}

test "removeMapping: nonexistent file is ok" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Should not error
    try removeMapping(allocator, tmp.dir, "nonexistent");
}

test "readAllMappings: empty directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &path_buf);

    const mappings = try readAllMappings(allocator, dir_path);
    defer freeAllMappings(allocator, mappings);

    try std.testing.expectEqual(@as(usize, 0), mappings.len);
}
