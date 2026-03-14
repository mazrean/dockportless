const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CertPaths = struct {
    dir: []const u8,
    ca_cert: []const u8,
    ca_key: []const u8,
    server_cert: []const u8,
    server_key: []const u8,
};

/// Get the certificate directory path.
/// Uses $XDG_DATA_HOME/dockportless/certs/ (fallback: ~/.local/share/dockportless/certs/).
pub fn getCertDir(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |data_home| {
        defer allocator.free(data_home);
        return std.fmt.allocPrint(allocator, "{s}/dockportless/certs", .{data_home});
    } else |_| {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fmt.allocPrint(allocator, "{s}/.local/share/dockportless/certs", .{home});
        } else |_| {
            return allocator.dupe(u8, "/tmp/dockportless/certs");
        }
    }
}

/// Ensure certificates exist. Generate if not present.
pub fn ensureCerts(allocator: Allocator) !CertPaths {
    const cert_dir = try getCertDir(allocator);
    errdefer allocator.free(cert_dir);

    // Create directory hierarchy
    makeDirRecursive(cert_dir);

    const ca_cert = try std.fmt.allocPrint(allocator, "{s}/ca.crt", .{cert_dir});
    errdefer allocator.free(ca_cert);
    const ca_key = try std.fmt.allocPrint(allocator, "{s}/ca.key", .{cert_dir});
    errdefer allocator.free(ca_key);
    const server_cert = try std.fmt.allocPrint(allocator, "{s}/server.crt", .{cert_dir});
    errdefer allocator.free(server_cert);
    const server_key = try std.fmt.allocPrint(allocator, "{s}/server.key", .{cert_dir});
    errdefer allocator.free(server_key);

    // Check if CA cert already exists
    const needs_generation = blk: {
        var dir = std.fs.openDirAbsolute(cert_dir, .{}) catch break :blk true;
        defer dir.close();
        _ = dir.statFile("ca.crt") catch break :blk true;
        _ = dir.statFile("server.crt") catch break :blk true;
        _ = dir.statFile("server.key") catch break :blk true;
        break :blk false;
    };

    if (needs_generation) {
        try generateCerts(allocator, cert_dir, ca_cert, ca_key, server_cert, server_key);
    }

    return CertPaths{
        .dir = cert_dir,
        .ca_cert = ca_cert,
        .ca_key = ca_key,
        .server_cert = server_cert,
        .server_key = server_key,
    };
}

fn makeDirRecursive(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Parent doesn't exist, create it first
            if (std.fs.path.dirname(path)) |parent| {
                makeDirRecursive(parent);
                std.fs.makeDirAbsolute(path) catch {};
            }
        },
        else => {},
    };
}

fn generateCerts(allocator: Allocator, cert_dir: []const u8, ca_cert: []const u8, ca_key: []const u8, server_cert: []const u8, server_key: []const u8) !void {
    std.debug.print("Generating TLS certificates in {s}\n", .{cert_dir});

    // 1. Generate CA key + self-signed cert
    try runOpenssl(allocator, &.{
        "openssl", "req",                 "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", ca_key,                "-out",  ca_cert,   "-days",    "3650",
        "-subj",   "/CN=dockportless CA",
    });

    // 2. Generate server key + CSR
    const csr_path = try std.fmt.allocPrint(allocator, "{s}/server.csr", .{cert_dir});
    defer allocator.free(csr_path);

    try runOpenssl(allocator, &.{
        "openssl",       "req",      "-newkey", "rsa:2048", "-nodes",
        "-keyout",       server_key, "-out",    csr_path,   "-subj",
        "/CN=localhost",
    });

    // 3. Create extension config file for SAN
    const ext_path = try std.fmt.allocPrint(allocator, "{s}/ext.cnf", .{cert_dir});
    defer allocator.free(ext_path);

    {
        const file = try std.fs.createFileAbsolute(ext_path, .{});
        defer file.close();
        try file.writeAll("subjectAltName=DNS:*.localhost,DNS:localhost\n");
    }

    // 4. Sign server cert with CA
    try runOpenssl(allocator, &.{
        "openssl",         "x509",   "-req",
        "-in",             csr_path, "-CA",
        ca_cert,           "-CAkey", ca_key,
        "-CAcreateserial", "-out",   server_cert,
        "-days",           "3650",   "-sha256",
        "-extfile",        ext_path,
    });

    // Cleanup temp files
    std.fs.deleteFileAbsolute(csr_path) catch {};
    std.fs.deleteFileAbsolute(ext_path) catch {};
    const serial_path = try std.fmt.allocPrint(allocator, "{s}/ca.srl", .{cert_dir});
    defer allocator.free(serial_path);
    std.fs.deleteFileAbsolute(serial_path) catch {};

    std.debug.print("TLS certificates generated successfully\n", .{});
}

fn runOpenssl(allocator: Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CertGenerationFailed;
        },
        else => return error.CertGenerationFailed,
    }
}

/// Install CA certificate to system trust store.
/// Attempts Debian/Ubuntu and RHEL/Fedora paths.
pub fn installCaCert(allocator: Allocator, ca_cert_path: []const u8) void {
    // Try Debian/Ubuntu path
    if (tryInstallDebian(allocator, ca_cert_path)) {
        std.debug.print("CA certificate installed to system trust store\n", .{});
        return;
    }

    // Try RHEL/Fedora path
    if (tryInstallRedhat(allocator, ca_cert_path)) {
        std.debug.print("CA certificate installed to system trust store\n", .{});
        return;
    }

    std.debug.print("Could not install CA certificate to system trust store.\n", .{});
    std.debug.print("Manually trust: {s}\n", .{ca_cert_path});
}

fn tryInstallDebian(allocator: Allocator, ca_cert_path: []const u8) bool {
    const dest = "/usr/local/share/ca-certificates/dockportless-ca.crt";

    // Check if already installed
    if (std.fs.accessAbsolute(dest, .{})) |_| {
        return true;
    } else |_| {}

    var cp = std.process.Child.init(&.{ "sudo", "-n", "cp", ca_cert_path, dest }, allocator);
    cp.stderr_behavior = .Ignore;
    cp.spawn() catch return false;
    const cp_term = cp.wait() catch return false;
    if (cp_term != .Exited or cp_term.Exited != 0) return false;

    var update = std.process.Child.init(&.{ "sudo", "-n", "update-ca-certificates" }, allocator);
    update.stderr_behavior = .Ignore;
    update.spawn() catch return false;
    const update_term = update.wait() catch return false;
    return update_term == .Exited and update_term.Exited == 0;
}

fn tryInstallRedhat(allocator: Allocator, ca_cert_path: []const u8) bool {
    const dest = "/etc/pki/ca-trust/source/anchors/dockportless-ca.crt";

    if (std.fs.accessAbsolute(dest, .{})) |_| {
        return true;
    } else |_| {}

    var cp = std.process.Child.init(&.{ "sudo", "-n", "cp", ca_cert_path, dest }, allocator);
    cp.stderr_behavior = .Ignore;
    cp.spawn() catch return false;
    const cp_term = cp.wait() catch return false;
    if (cp_term != .Exited or cp_term.Exited != 0) return false;

    var update = std.process.Child.init(&.{ "sudo", "-n", "update-ca-trust" }, allocator);
    update.stderr_behavior = .Ignore;
    update.spawn() catch return false;
    const update_term = update.wait() catch return false;
    return update_term == .Exited and update_term.Exited == 0;
}

pub fn freeCertPaths(allocator: Allocator, paths: *CertPaths) void {
    allocator.free(paths.dir);
    allocator.free(paths.ca_cert);
    allocator.free(paths.ca_key);
    allocator.free(paths.server_cert);
    allocator.free(paths.server_key);
}
