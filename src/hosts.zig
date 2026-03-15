const std = @import("std");
const Allocator = std.mem.Allocator;

const HOSTS_PATH = "/etc/hosts";
const MARKER_START = "# dockportless-start";
const MARKER_END = "# dockportless-end";

/// Build the managed block content for the given hostnames.
/// Each hostname maps to 127.0.0.1.
fn buildBlock(allocator: Allocator, hostnames: []const []const u8) ![]const u8 {
    if (hostnames.len == 0) return allocator.dupe(u8, "");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, MARKER_START);
    try buf.append(allocator, '\n');
    for (hostnames) |h| {
        try buf.appendSlice(allocator, "127.0.0.1 ");
        try buf.appendSlice(allocator, h);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, MARKER_END);
    try buf.append(allocator, '\n');

    return buf.toOwnedSlice(allocator);
}

/// Remove the dockportless-managed block from hosts file content.
/// Returns cleaned content with normalized trailing newlines.
fn removeBlock(allocator: Allocator, content: []const u8) ![]const u8 {
    const start_idx = std.mem.indexOf(u8, content, MARKER_START) orelse
        return allocator.dupe(u8, content);
    const end_idx = std.mem.indexOf(u8, content, MARKER_END) orelse
        return allocator.dupe(u8, content);
    if (end_idx <= start_idx) return allocator.dupe(u8, content);

    const end_of_marker = end_idx + MARKER_END.len;
    // Skip trailing newline after marker end
    const after_start = if (end_of_marker < content.len and content[end_of_marker] == '\n')
        end_of_marker + 1
    else
        end_of_marker;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, content[0..start_idx]);
    try buf.appendSlice(allocator, content[after_start..]);

    // Normalize: collapse 3+ consecutive newlines to 2
    const raw = try buf.toOwnedSlice(allocator);
    defer allocator.free(raw);

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var newline_count: usize = 0;
    for (raw) |c| {
        if (c == '\n') {
            newline_count += 1;
            if (newline_count <= 2) try result.append(allocator, c);
        } else {
            newline_count = 0;
            try result.append(allocator, c);
        }
    }

    // Ensure trailing newline
    if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

/// Sync /etc/hosts to include entries for all given hostnames.
/// Replaces any existing dockportless-managed block.
/// Requires write access to /etc/hosts (typically root).
pub fn syncHostsFile(allocator: Allocator, hostnames: []const []const u8) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, HOSTS_PATH, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    const cleaned = try removeBlock(allocator, content);
    defer allocator.free(cleaned);

    if (hostnames.len == 0) {
        const file = try std.fs.cwd().createFile(HOSTS_PATH, .{});
        defer file.close();
        try file.writeAll(cleaned);
        return;
    }

    const block = try buildBlock(allocator, hostnames);
    defer allocator.free(block);

    const file = try std.fs.cwd().createFile(HOSTS_PATH, .{});
    defer file.close();

    // Write cleaned content (trimmed) + separator + block
    const trimmed = std.mem.trimRight(u8, cleaned, "\n");
    try file.writeAll(trimmed);
    try file.writeAll("\n\n");
    try file.writeAll(block);
}

/// Remove the dockportless-managed block from /etc/hosts.
pub fn cleanHostsFile(allocator: Allocator) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, HOSTS_PATH, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, MARKER_START) == null) return;

    const cleaned = try removeBlock(allocator, content);
    defer allocator.free(cleaned);

    const file = try std.fs.cwd().createFile(HOSTS_PATH, .{});
    defer file.close();
    try file.writeAll(cleaned);
}

/// Collect all hostnames for a project's services.
/// Returns hostnames like "web.myapp.localhost", "1.web.myapp.localhost", etc.
pub fn collectHostnames(
    allocator: Allocator,
    project_name: []const u8,
    services: []const Service,
) ![]const []const u8 {
    var hostnames: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (hostnames.items) |h| allocator.free(h);
        hostnames.deinit(allocator);
    }

    for (services) |svc| {
        // Primary: <service>.<project>.localhost
        try hostnames.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}.{s}.localhost", .{ svc.name, project_name }),
        );
        // Multi-port: <index>.<service>.<project>.localhost (index 1+)
        for (1..svc.port_count) |idx| {
            try hostnames.append(
                allocator,
                try std.fmt.allocPrint(allocator, "{d}.{s}.{s}.localhost", .{ idx, svc.name, project_name }),
            );
        }
    }

    return hostnames.toOwnedSlice(allocator);
}

pub fn freeHostnames(allocator: Allocator, hostnames: []const []const u8) void {
    for (hostnames) |h| allocator.free(h);
    allocator.free(hostnames);
}

pub const Service = struct {
    name: []const u8,
    port_count: usize,
};

// --- Tests ---

test "buildBlock: empty hostnames" {
    const allocator = std.testing.allocator;
    const block = try buildBlock(allocator, &.{});
    defer allocator.free(block);
    try std.testing.expectEqualStrings("", block);
}

test "buildBlock: single hostname" {
    const allocator = std.testing.allocator;
    const hostnames = &[_][]const u8{"web.myapp.localhost"};
    const block = try buildBlock(allocator, hostnames);
    defer allocator.free(block);
    try std.testing.expectEqualStrings(
        "# dockportless-start\n127.0.0.1 web.myapp.localhost\n# dockportless-end\n",
        block,
    );
}

test "buildBlock: multiple hostnames" {
    const allocator = std.testing.allocator;
    const hostnames = &[_][]const u8{ "web.myapp.localhost", "api.myapp.localhost" };
    const block = try buildBlock(allocator, hostnames);
    defer allocator.free(block);
    try std.testing.expectEqualStrings(
        "# dockportless-start\n127.0.0.1 web.myapp.localhost\n127.0.0.1 api.myapp.localhost\n# dockportless-end\n",
        block,
    );
}

test "removeBlock: no markers" {
    const allocator = std.testing.allocator;
    const content = "127.0.0.1 localhost\n";
    const result = try removeBlock(allocator, content);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n", result);
}

test "removeBlock: with markers" {
    const allocator = std.testing.allocator;
    const content =
        "127.0.0.1 localhost\n" ++
        "\n" ++
        "# dockportless-start\n" ++
        "127.0.0.1 web.myapp.localhost\n" ++
        "# dockportless-end\n";
    const result = try removeBlock(allocator, content);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n\n", result);
}

test "removeBlock: markers in middle" {
    const allocator = std.testing.allocator;
    const content =
        "127.0.0.1 localhost\n" ++
        "\n" ++
        "# dockportless-start\n" ++
        "127.0.0.1 web.myapp.localhost\n" ++
        "# dockportless-end\n" ++
        "\n" ++
        "::1 localhost\n";
    const result = try removeBlock(allocator, content);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n\n::1 localhost\n", result);
}

test "collectHostnames: single port services" {
    const allocator = std.testing.allocator;
    const services = &[_]Service{
        .{ .name = "web", .port_count = 1 },
        .{ .name = "api", .port_count = 1 },
    };
    const hostnames = try collectHostnames(allocator, "myapp", services);
    defer freeHostnames(allocator, hostnames);

    try std.testing.expectEqual(@as(usize, 2), hostnames.len);
    try std.testing.expectEqualStrings("web.myapp.localhost", hostnames[0]);
    try std.testing.expectEqualStrings("api.myapp.localhost", hostnames[1]);
}

test "collectHostnames: multi-port service" {
    const allocator = std.testing.allocator;
    const services = &[_]Service{
        .{ .name = "web", .port_count = 3 },
    };
    const hostnames = try collectHostnames(allocator, "myapp", services);
    defer freeHostnames(allocator, hostnames);

    try std.testing.expectEqual(@as(usize, 3), hostnames.len);
    try std.testing.expectEqualStrings("web.myapp.localhost", hostnames[0]);
    try std.testing.expectEqualStrings("1.web.myapp.localhost", hostnames[1]);
    try std.testing.expectEqualStrings("2.web.myapp.localhost", hostnames[2]);
}
