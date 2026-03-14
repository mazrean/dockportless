const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const compose = @import("compose.zig");
const port = @import("port.zig");
const mapping = @import("mapping.zig");
const executor = @import("executor.zig");
const proxy = @import("proxy.zig");
const tcp_proxy = @import("tcp_proxy.zig");
const cert = @import("cert.zig");

const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip executable name

    const subcmd = args.next() orelse {
        printMainHelp();
        return;
    };

    if (std.mem.eql(u8, subcmd, "run")) {
        return runCmd(allocator, &args);
    } else if (std.mem.eql(u8, subcmd, "proxy")) {
        return proxyCmd(allocator, &args);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printMainHelp();
    } else {
        std.debug.print("Unknown subcommand: {s}\n\n", .{subcmd});
        printMainHelp();
        return error.UnknownSubcommand;
    }
}

fn printMainHelp() void {
    stdout.writeAll(
        \\Usage: dockportless <command> [options]
        \\
        \\Commands:
        \\  run    Run a command with auto-assigned ports
        \\  proxy  Start the proxy server
        \\
        \\Options:
        \\  -h, --help  Show this help message
        \\
    ) catch {};
}

fn runCmd(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var project_name: ?[]const u8 = null;
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer cmd_args.deinit(allocator);

    var parsing_options = true;
    while (args.next()) |arg| {
        if (parsing_options) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printRunHelp();
                return;
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_options = false;
            } else if (project_name == null) {
                project_name = arg;
                parsing_options = false;
            } else {
                try cmd_args.append(allocator, arg);
                parsing_options = false;
            }
        } else {
            try cmd_args.append(allocator, arg);
        }
    }

    const proj_name = project_name orelse {
        std.debug.print("Error: project name is required\n\n", .{});
        printRunHelp();
        return error.MissingProjectName;
    };

    if (cmd_args.items.len == 0) {
        std.debug.print("Error: command is required\n\n", .{});
        printRunHelp();
        return error.MissingCommand;
    }

    // 1. Detect and parse compose file(s)
    const cwd = std.fs.cwd();

    const extracted_files = try compose.extractComposeFilesFromArgs(allocator, cmd_args.items);
    defer if (extracted_files) |files| allocator.free(files);

    var services: []const []const u8 = &.{};
    if (extracted_files) |files| {
        // Parse services from all specified compose files
        var all_services: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (all_services.items) |s| allocator.free(s);
            all_services.deinit(allocator);
        }
        for (files) |file| {
            const file_services = compose.parseServices(allocator, cwd, file) catch |err| {
                std.debug.print("Error: failed to parse compose file '{s}'\n", .{file});
                return err;
            };
            defer allocator.free(file_services);
            try all_services.appendSlice(allocator, file_services);
        }
        services = try all_services.toOwnedSlice(allocator);
    } else {
        // Fall back to auto-detection
        const compose_file = compose.findComposeFile(cwd) catch |err| {
            std.debug.print("Error: compose file not found. Place a docker-compose.yml or compose.yml in the current directory, or use -f flag in your compose command.\n", .{});
            return err;
        };
        services = compose.parseServices(allocator, cwd, compose_file) catch |err| {
            std.debug.print("Error: failed to parse compose file '{s}'\n", .{compose_file});
            return err;
        };
    }
    defer compose.freeServices(allocator, services);

    if (services.len == 0) {
        std.debug.print("Warning: no services found in compose file\n", .{});
    }

    // 2. Read existing mappings to get reserved ports
    const mapping_dir_path = try mapping.getMappingDir(allocator);
    defer allocator.free(mapping_dir_path);

    // Ensure mapping directory exists
    std.fs.makeDirAbsolute(mapping_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var mapping_dir = try std.fs.openDirAbsolute(mapping_dir_path, .{});
    defer mapping_dir.close();

    const existing_mappings = try mapping.readAllMappings(allocator, mapping_dir_path);
    defer mapping.freeAllMappings(allocator, existing_mappings);

    // Collect reserved ports from existing mappings
    var reserved_ports: std.ArrayListUnmanaged(u16) = .{};
    defer reserved_ports.deinit(allocator);
    for (existing_mappings) |m| {
        for (m.services) |svc| {
            try reserved_ports.append(allocator, svc.port);
        }
    }

    // 3. Allocate ports (avoiding reserved)
    const ports = try port.allocatePorts(allocator, services.len, reserved_ports.items);
    defer allocator.free(ports);

    const service_mappings = try allocator.alloc(mapping.ServiceMapping, services.len);
    defer allocator.free(service_mappings);

    for (services, ports, 0..) |svc_name, svc_port, i| {
        service_mappings[i] = .{
            .service_name = svc_name,
            .port = svc_port,
        };
    }

    const project_mapping = mapping.ProjectMapping{
        .project_name = proj_name,
        .services = service_mappings,
        .pid = switch (builtin.os.tag) {
            .linux => @intCast(std.os.linux.getpid()),
            else => 0,
        },
    };

    try mapping.writeMapping(allocator, mapping_dir, project_mapping);

    // Ensure cleanup on exit
    defer {
        mapping.removeMapping(allocator, mapping_dir, proj_name) catch {};
    }

    // Ensure TLS certificates
    var cert_paths = cert.ensureCerts(allocator) catch |err| {
        std.debug.print("Warning: failed to generate TLS certificates: {}\n", .{err});
        return err;
    };
    defer cert.freeCertPaths(allocator, &cert_paths);

    // Install CA cert to system trust store
    cert.installCaCert(cert_paths.ca_cert);

    // Print service URLs
    for (services, ports) |svc_name, svc_port| {
        std.debug.print("  {s}.{s}.localhost:{d} -> :{d} (HTTP)\n", .{ svc_name, proj_name, proxy.PROXY_PORT, svc_port });
        std.debug.print("  {s}.{s}.localhost:{d} -> :{d} (TLS)\n", .{ svc_name, proj_name, proxy.PROXY_TLS_PORT, svc_port });
    }

    // 4. Start proxy servers in background threads
    const proxy_thread = std.Thread.spawn(.{}, proxy.start, .{ allocator, mapping_dir_path }) catch |err| {
        std.debug.print("Warning: failed to start HTTP proxy server: {}\n", .{err});
        return err;
    };
    proxy_thread.detach();

    // Start TLS proxy
    const tls_proxy_thread = std.Thread.spawn(.{}, tcp_proxy.start, .{ allocator, mapping_dir_path, cert_paths }) catch |err| {
        std.debug.print("Warning: failed to start TLS proxy server: {}\n", .{err});
        return err;
    };
    tls_proxy_thread.detach();

    // 5. Set environment variables and execute command
    const exec_services = try allocator.alloc(executor.ServicePort, services.len);
    defer allocator.free(exec_services);

    for (services, ports, 0..) |svc_name, svc_port, i| {
        exec_services[i] = .{
            .service_name = svc_name,
            .port = svc_port,
        };
    }

    const term = try executor.exec(allocator, cmd_args.items, exec_services);
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Command exited with code {d}\n", .{code});
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("Command terminated abnormally\n", .{});
            return error.CommandFailed;
        },
    }
}

fn printRunHelp() void {
    stdout.writeAll(
        \\Usage: dockportless run [options] <project_name> <command...>
        \\
        \\Run a command with auto-assigned ports for compose services.
        \\Compose files are detected from the command's -f/--file flags
        \\(docker compose / podman compose). Falls back to auto-detection
        \\from the current directory if no -f flag is found.
        \\
        \\Arguments:
        \\  project_name  Name of the project
        \\  command...    Command to execute (e.g. docker compose up)
        \\
        \\Options:
        \\  -h, --help  Show this help message
        \\
        \\Examples:
        \\  dockportless run myapp docker compose up
        \\  dockportless run myapp docker compose -f custom.yml up
        \\  dockportless run myapp podman compose -f a.yml -f b.yml up
        \\
    ) catch {};
}

fn proxyCmd(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printProxyHelp();
            return;
        }
    }

    const mapping_dir_path = try mapping.getMappingDir(allocator);
    defer allocator.free(mapping_dir_path);

    // Ensure mapping directory exists
    std.fs.makeDirAbsolute(mapping_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Ensure TLS certificates
    var cert_paths = cert.ensureCerts(allocator) catch |err| {
        std.debug.print("Warning: failed to generate TLS certificates: {}\n", .{err});
        return err;
    };
    defer cert.freeCertPaths(allocator, &cert_paths);

    // Install CA cert to system trust store
    cert.installCaCert(cert_paths.ca_cert);

    std.debug.print("Starting proxy servers\n", .{});
    std.debug.print("  HTTP: :{d}\n", .{proxy.PROXY_PORT});
    std.debug.print("  TLS:  :{d}\n", .{proxy.PROXY_TLS_PORT});
    std.debug.print("Mapping directory: {s}\n", .{mapping_dir_path});

    // Start TLS proxy in background thread
    const tls_proxy_thread = std.Thread.spawn(.{}, tcp_proxy.start, .{ allocator, mapping_dir_path, cert_paths }) catch |err| {
        std.debug.print("Warning: failed to start TLS proxy server: {}\n", .{err});
        return err;
    };
    tls_proxy_thread.detach();

    // Start HTTP proxy server (blocking)
    try proxy.start(allocator, mapping_dir_path);
}

fn printProxyHelp() void {
    stdout.writeAll(
        \\Usage: dockportless proxy [options]
        \\
        \\Start the proxy server for routing requests to services.
        \\
        \\Options:
        \\  -h, --help  Show this help message
        \\
    ) catch {};
}
