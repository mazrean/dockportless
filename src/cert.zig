const std = @import("std");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("openssl/evp.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/bio.h");
});

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

    // Check if certs already exist
    const needs_generation = blk: {
        var dir = std.fs.openDirAbsolute(cert_dir, .{}) catch break :blk true;
        defer dir.close();
        _ = dir.statFile("ca.crt") catch break :blk true;
        _ = dir.statFile("server.crt") catch break :blk true;
        _ = dir.statFile("server.key") catch break :blk true;
        break :blk false;
    };

    if (needs_generation) {
        try generateCerts(allocator, ca_cert, ca_key, server_cert, server_key);
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
            if (std.fs.path.dirname(path)) |parent| {
                makeDirRecursive(parent);
                std.fs.makeDirAbsolute(path) catch {};
            }
        },
        else => {},
    };
}

fn generateCerts(allocator: Allocator, ca_cert_path: []const u8, ca_key_path: []const u8, server_cert_path: []const u8, server_key_path: []const u8) !void {
    std.debug.print("Generating TLS certificates...\n", .{});

    // Generate CA key pair
    const ca_pkey = generateRsaKey() orelse return error.KeyGenerationFailed;
    defer c.EVP_PKEY_free(ca_pkey);

    // Create self-signed CA certificate
    const ca_x509 = try createCaCert(ca_pkey);
    defer c.X509_free(ca_x509);

    // Generate server key pair
    const server_pkey = generateRsaKey() orelse return error.KeyGenerationFailed;
    defer c.EVP_PKEY_free(server_pkey);

    // Create server certificate signed by CA
    const server_x509 = try createServerCert(server_pkey, ca_x509, ca_pkey);
    defer c.X509_free(server_x509);

    // Write PEM files
    try writePemKey(allocator, ca_key_path, ca_pkey);
    try writePemCert(allocator, ca_cert_path, ca_x509);
    try writePemKey(allocator, server_key_path, server_pkey);
    try writePemCert(allocator, server_cert_path, server_x509);

    std.debug.print("TLS certificates generated successfully\n", .{});
}

fn generateRsaKey() ?*c.EVP_PKEY {
    const ctx = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_RSA, null) orelse return null;
    defer c.EVP_PKEY_CTX_free(ctx);

    if (c.EVP_PKEY_keygen_init(ctx) <= 0) return null;
    if (c.EVP_PKEY_CTX_ctrl(ctx, c.EVP_PKEY_RSA, c.EVP_PKEY_OP_KEYGEN, c.EVP_PKEY_CTRL_RSA_KEYGEN_BITS, 2048, null) <= 0) return null;

    var pkey: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(ctx, &pkey) <= 0) return null;
    return pkey;
}

fn createCaCert(ca_key: *c.EVP_PKEY) !*c.X509 {
    const x509 = c.X509_new() orelse return error.CertCreationFailed;
    errdefer c.X509_free(x509);

    _ = c.X509_set_version(x509, 2); // V3
    _ = c.ASN1_INTEGER_set(c.X509_get_serialNumber(x509), 1);
    _ = c.X509_gmtime_adj(c.X509_getm_notBefore(x509), 0);
    _ = c.X509_gmtime_adj(c.X509_getm_notAfter(x509), 3650 * 24 * 60 * 60);
    _ = c.X509_set_pubkey(x509, ca_key);

    const name = c.X509_get_subject_name(x509);
    _ = c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_ASC, "dockportless CA", -1, -1, 0);
    _ = c.X509_set_issuer_name(x509, name);

    // Add basicConstraints: CA:TRUE
    var v3ctx: c.X509V3_CTX = undefined;
    c.X509V3_set_ctx(&v3ctx, x509, x509, null, null, 0);
    const bc_ext = c.X509V3_EXT_nconf(null, &v3ctx, "basicConstraints", "critical,CA:TRUE") orelse return error.ExtensionFailed;
    defer c.X509_EXTENSION_free(bc_ext);
    _ = c.X509_add_ext(x509, bc_ext, -1);

    // Add keyUsage
    const ku_ext = c.X509V3_EXT_nconf(null, &v3ctx, "keyUsage", "critical,keyCertSign,cRLSign") orelse return error.ExtensionFailed;
    defer c.X509_EXTENSION_free(ku_ext);
    _ = c.X509_add_ext(x509, ku_ext, -1);

    if (c.X509_sign(x509, ca_key, c.EVP_sha256()) == 0) return error.CertSignFailed;

    return x509;
}

fn createServerCert(server_key: *c.EVP_PKEY, ca_cert: *c.X509, ca_key: *c.EVP_PKEY) !*c.X509 {
    const x509 = c.X509_new() orelse return error.CertCreationFailed;
    errdefer c.X509_free(x509);

    _ = c.X509_set_version(x509, 2);
    _ = c.ASN1_INTEGER_set(c.X509_get_serialNumber(x509), 2);
    _ = c.X509_gmtime_adj(c.X509_getm_notBefore(x509), 0);
    _ = c.X509_gmtime_adj(c.X509_getm_notAfter(x509), 3650 * 24 * 60 * 60);
    _ = c.X509_set_pubkey(x509, server_key);

    const subj_name = c.X509_get_subject_name(x509);
    _ = c.X509_NAME_add_entry_by_txt(subj_name, "CN", c.MBSTRING_ASC, "localhost", -1, -1, 0);
    _ = c.X509_set_issuer_name(x509, c.X509_get_subject_name(ca_cert));

    // Add subjectAltName
    var v3ctx: c.X509V3_CTX = undefined;
    c.X509V3_set_ctx(&v3ctx, ca_cert, x509, null, null, 0);
    const san_ext = c.X509V3_EXT_nconf(null, &v3ctx, "subjectAltName", "DNS:*.localhost,DNS:localhost") orelse return error.ExtensionFailed;
    defer c.X509_EXTENSION_free(san_ext);
    _ = c.X509_add_ext(x509, san_ext, -1);

    if (c.X509_sign(x509, ca_key, c.EVP_sha256()) == 0) return error.CertSignFailed;

    return x509;
}

fn writePemKey(allocator: Allocator, path: []const u8, pkey: *c.EVP_PKEY) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const bio = c.BIO_new_file(path_z.ptr, "w") orelse return error.FileCreateFailed;
    defer _ = c.BIO_free(bio);

    if (c.PEM_write_bio_PrivateKey(bio, pkey, null, null, 0, null, null) != 1) {
        return error.PemWriteFailed;
    }
}

fn writePemCert(allocator: Allocator, path: []const u8, x509: *c.X509) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const bio = c.BIO_new_file(path_z.ptr, "w") orelse return error.FileCreateFailed;
    defer _ = c.BIO_free(bio);

    if (c.PEM_write_bio_X509(bio, x509) != 1) {
        return error.PemWriteFailed;
    }
}

const builtin = @import("builtin");

const TrustStoreEntry = struct {
    cert_path: []const u8,
    update_cmd: []const []const u8,
    label: []const u8,
};

/// Linux distro trust store definitions.
const linux_trust_stores = [_]TrustStoreEntry{
    // Debian / Ubuntu
    .{
        .cert_path = "/usr/local/share/ca-certificates/dockportless-ca.crt",
        .update_cmd = &.{"update-ca-certificates"},
        .label = "Debian/Ubuntu",
    },
    // RHEL / Fedora
    .{
        .cert_path = "/etc/pki/ca-trust/source/anchors/dockportless-ca.crt",
        .update_cmd = &.{"update-ca-trust"},
        .label = "RHEL/Fedora",
    },
    // Arch Linux
    .{
        .cert_path = "/etc/ca-certificates/trust-source/anchors/dockportless-ca.crt",
        .update_cmd = &.{ "trust", "extract-compat" },
        .label = "Arch Linux",
    },
    // SUSE
    .{
        .cert_path = "/etc/pki/trust/anchors/dockportless-ca.crt",
        .update_cmd = &.{"update-ca-certificates"},
        .label = "SUSE",
    },
};

/// Install CA certificate to system trust store using filesystem operations.
/// This is a best-effort attempt without elevated privileges.
pub fn installCaCert(ca_cert_path: []const u8) void {
    if (comptime builtin.os.tag == .macos) {
        // macOS requires the security command; filesystem-only is not possible
        std.debug.print("CA certificate: {s}\n", .{ca_cert_path});
        std.debug.print("Run 'sudo dockportless trust' to trust it system-wide\n", .{});
        return;
    }

    const content = readFileContent(ca_cert_path) orelse return;

    for (linux_trust_stores) |store| {
        if (tryCopyCert(content, store.cert_path)) {
            std.debug.print("CA certificate installed to system trust store\n", .{});
            return;
        }
    }

    std.debug.print("CA certificate: {s}\n", .{ca_cert_path});
    std.debug.print("Run 'sudo dockportless trust' to trust it system-wide\n", .{});
}

/// Install CA certificate to system trust store with elevated privileges.
/// Intended to be called from the `trust` subcommand run with sudo.
pub fn installCaCertPrivileged(allocator: Allocator, ca_cert_path: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        return installCaCertMacos(allocator, ca_cert_path);
    }

    return installCaCertLinux(allocator, ca_cert_path);
}

fn installCaCertMacos(allocator: Allocator, ca_cert_path: []const u8) !void {
    var child = std.process.Child.init(&.{
        "security",                           "add-trusted-cert",
        "-d",                                 "-r",
        "trustRoot",                          "-k",
        "/Library/Keychains/System.keychain", ca_cert_path,
    }, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                std.debug.print("CA certificate installed and trusted (macOS)\n", .{});
                return;
            }
        },
        else => {},
    }
    std.debug.print("Error: could not install CA certificate to macOS system keychain\n", .{});
    return error.TrustInstallFailed;
}

fn installCaCertLinux(allocator: Allocator, ca_cert_path: []const u8) !void {
    const content = readFileContent(ca_cert_path) orelse return error.CaCertReadFailed;

    for (linux_trust_stores) |store| {
        if (tryCopyCert(content, store.cert_path)) {
            if (runUpdateCmd(allocator, store.update_cmd)) {
                std.debug.print("CA certificate installed and trusted ({s})\n", .{store.label});
                return;
            }
        }
    }

    std.debug.print("Error: could not install CA certificate to system trust store\n", .{});
    return error.TrustInstallFailed;
}

fn runUpdateCmd(allocator: Allocator, argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

fn readFileContent(path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    return buf[0..n];
}

fn tryCopyCert(content: []const u8, dest_path: []const u8) bool {
    // Check if already installed
    std.fs.accessAbsolute(dest_path, .{}) catch {
        // Not present, try to write
        const dest = std.fs.createFileAbsolute(dest_path, .{}) catch return false;
        defer dest.close();
        dest.writeAll(content) catch return false;
        return true;
    };
    // Already exists
    return true;
}

pub fn freeCertPaths(allocator: Allocator, paths: *CertPaths) void {
    allocator.free(paths.dir);
    allocator.free(paths.ca_cert);
    allocator.free(paths.ca_key);
    allocator.free(paths.server_cert);
    allocator.free(paths.server_key);
}
