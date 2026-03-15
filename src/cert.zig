const std = @import("std");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("openssl/evp.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/ec.h");
});

pub const CertPaths = struct {
    dir: []const u8,
    ca_cert: []const u8,
    ca_key: []const u8,
};

/// CA credentials loaded into memory for signing dynamic server certs.
pub const CaCredentials = struct {
    ca_cert: *anyopaque,
    ca_key: *anyopaque,
};

/// Dynamically generated server certificate for a specific domain.
pub const DomainCert = struct {
    cert: *anyopaque,
    key: *anyopaque,
};

/// Get the certificate directory path.
/// Uses $XDG_DATA_HOME/dockportless/certs/ (fallback: ~/.local/share/dockportless/certs/).
/// Under sudo, resolves to the original user's home via SUDO_USER.
pub fn getCertDir(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |data_home| {
        defer allocator.free(data_home);
        return std.fmt.allocPrint(allocator, "{s}/dockportless/certs", .{data_home});
    } else |_| {
        const home = getEffectiveHome(allocator);
        if (home) |h| {
            defer allocator.free(h);
            return std.fmt.allocPrint(allocator, "{s}/.local/share/dockportless/certs", .{h});
        }
        return allocator.dupe(u8, "/tmp/dockportless/certs");
    }
}

/// Get the effective user's home directory.
/// When running under sudo, use SUDO_USER to resolve the original user's home.
fn getEffectiveHome(allocator: Allocator) ?[]const u8 {
    // Under sudo, HOME points to root's home. Use SUDO_USER to find the original user.
    if (std.process.getEnvVarOwned(allocator, "SUDO_USER")) |sudo_user| {
        defer allocator.free(sudo_user);
        // Try /home/<user> as a common default
        const home = std.fmt.allocPrint(allocator, "/home/{s}", .{sudo_user}) catch return null;
        // Verify the directory exists
        std.fs.accessAbsolute(home, .{}) catch {
            allocator.free(home);
            // Fall through to regular HOME
            return std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        };
        return home;
    } else |_| {}
    return std.process.getEnvVarOwned(allocator, "HOME") catch return null;
}

/// Check if CA certificates already exist. Returns null if not present.
pub fn checkCerts(allocator: Allocator) !?CertPaths {
    const cert_dir = try getCertDir(allocator);
    errdefer allocator.free(cert_dir);

    const ca_cert = try std.fmt.allocPrint(allocator, "{s}/ca.crt", .{cert_dir});
    errdefer allocator.free(ca_cert);
    const ca_key = try std.fmt.allocPrint(allocator, "{s}/ca.key", .{cert_dir});
    errdefer allocator.free(ca_key);

    const exists = blk: {
        var dir = std.fs.openDirAbsolute(cert_dir, .{}) catch break :blk false;
        defer dir.close();
        _ = dir.statFile("ca.crt") catch break :blk false;
        _ = dir.statFile("ca.key") catch break :blk false;
        break :blk true;
    };

    if (!exists) {
        allocator.free(cert_dir);
        allocator.free(ca_cert);
        allocator.free(ca_key);
        return null;
    }

    return CertPaths{
        .dir = cert_dir,
        .ca_cert = ca_cert,
        .ca_key = ca_key,
    };
}

/// Ensure CA certificates exist. Generate if not present.
pub fn ensureCerts(allocator: Allocator) !CertPaths {
    const cert_dir = try getCertDir(allocator);
    errdefer allocator.free(cert_dir);

    // Create directory hierarchy
    makeDirRecursive(cert_dir);

    const ca_cert = try std.fmt.allocPrint(allocator, "{s}/ca.crt", .{cert_dir});
    errdefer allocator.free(ca_cert);
    const ca_key = try std.fmt.allocPrint(allocator, "{s}/ca.key", .{cert_dir});
    errdefer allocator.free(ca_key);

    // Check if CA certs already exist
    const needs_generation = blk: {
        var dir = std.fs.openDirAbsolute(cert_dir, .{}) catch break :blk true;
        defer dir.close();
        _ = dir.statFile("ca.crt") catch break :blk true;
        _ = dir.statFile("ca.key") catch break :blk true;
        break :blk false;
    };

    if (needs_generation) {
        try generateCaCerts(allocator, ca_cert, ca_key);
    }

    return CertPaths{
        .dir = cert_dir,
        .ca_cert = ca_cert,
        .ca_key = ca_key,
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

fn generateCaCerts(allocator: Allocator, ca_cert_path: []const u8, ca_key_path: []const u8) !void {
    std.debug.print("Generating CA certificate...\n", .{});

    // Generate CA key pair (RSA 2048)
    const ca_pkey = generateRsaKey() orelse return error.KeyGenerationFailed;
    defer c.EVP_PKEY_free(ca_pkey);

    // Create self-signed CA certificate
    const ca_x509 = try createCaCert(ca_pkey);
    defer c.X509_free(ca_x509);

    // Write PEM files
    try writePemKey(allocator, ca_key_path, ca_pkey);
    try writePemCert(allocator, ca_cert_path, ca_x509);

    std.debug.print("CA certificate generated successfully\n", .{});
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

/// Load CA certificate and key from files for runtime cert generation.
pub fn loadCaCredentials(allocator: Allocator, ca_cert_path: []const u8, ca_key_path: []const u8) !CaCredentials {
    const cert_path_z = try allocator.dupeZ(u8, ca_cert_path);
    defer allocator.free(cert_path_z);
    const key_path_z = try allocator.dupeZ(u8, ca_key_path);
    defer allocator.free(key_path_z);

    const cert_bio = c.BIO_new_file(cert_path_z.ptr, "r") orelse return error.CaCertLoadFailed;
    defer _ = c.BIO_free(cert_bio);
    const ca_cert = c.PEM_read_bio_X509(cert_bio, null, null, null) orelse return error.CaCertParseFailed;
    errdefer c.X509_free(ca_cert);

    const key_bio = c.BIO_new_file(key_path_z.ptr, "r") orelse return error.CaKeyLoadFailed;
    defer _ = c.BIO_free(key_bio);
    const ca_key = c.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse return error.CaKeyParseFailed;

    return CaCredentials{ .ca_cert = @ptrCast(ca_cert), .ca_key = @ptrCast(ca_key) };
}

pub fn freeCaCredentials(creds: *CaCredentials) void {
    c.X509_free(@ptrCast(@alignCast(creds.ca_cert)));
    c.EVP_PKEY_free(@ptrCast(@alignCast(creds.ca_key)));
}

/// Generate a server certificate for a specific hostname, signed by the CA.
/// Uses EC P-256 for fast key generation.
pub fn generateDomainCert(allocator: Allocator, hostname: []const u8, ca_creds: CaCredentials) !DomainCert {
    const ca_cert: *c.X509 = @ptrCast(@alignCast(ca_creds.ca_cert));
    const ca_key: *c.EVP_PKEY = @ptrCast(@alignCast(ca_creds.ca_key));

    // Generate EC P-256 key
    const ec_key = c.EC_KEY_new_by_curve_name(c.NID_X9_62_prime256v1) orelse return error.EcKeyCreationFailed;
    if (c.EC_KEY_generate_key(ec_key) != 1) {
        c.EC_KEY_free(ec_key);
        return error.EcKeyGenFailed;
    }

    const pkey = c.EVP_PKEY_new() orelse {
        c.EC_KEY_free(ec_key);
        return error.PKeyCreationFailed;
    };
    errdefer c.EVP_PKEY_free(pkey);

    // EVP_PKEY_assign takes ownership of ec_key
    if (c.EVP_PKEY_assign(pkey, c.EVP_PKEY_EC, @ptrCast(ec_key)) != 1) {
        c.EC_KEY_free(ec_key);
        return error.PKeyAssignFailed;
    }

    // Create X509 cert
    const x509 = c.X509_new() orelse return error.CertCreationFailed;
    errdefer c.X509_free(x509);

    _ = c.X509_set_version(x509, 2);
    _ = c.ASN1_INTEGER_set(c.X509_get_serialNumber(x509), @intCast(@as(i64, @truncate(std.time.nanoTimestamp()))));
    _ = c.X509_gmtime_adj(c.X509_getm_notBefore(x509), 0);
    _ = c.X509_gmtime_adj(c.X509_getm_notAfter(x509), 365 * 24 * 60 * 60);
    _ = c.X509_set_pubkey(x509, pkey);

    const subj_name = c.X509_get_subject_name(x509);
    const hostname_z = try allocator.dupeZ(u8, hostname);
    defer allocator.free(hostname_z);
    _ = c.X509_NAME_add_entry_by_txt(subj_name, "CN", c.MBSTRING_ASC, hostname_z.ptr, -1, -1, 0);
    _ = c.X509_set_issuer_name(x509, c.X509_get_subject_name(ca_cert));

    // Add SAN with exact hostname
    var v3ctx: c.X509V3_CTX = undefined;
    c.X509V3_set_ctx(&v3ctx, ca_cert, x509, null, null, 0);

    const san_value = try std.fmt.allocPrint(allocator, "DNS:{s}", .{hostname});
    defer allocator.free(san_value);
    const san_value_z = try allocator.dupeZ(u8, san_value);
    defer allocator.free(san_value_z);

    const san_ext = c.X509V3_EXT_nconf(null, &v3ctx, "subjectAltName", san_value_z.ptr) orelse return error.ExtensionFailed;
    defer c.X509_EXTENSION_free(san_ext);
    _ = c.X509_add_ext(x509, san_ext, -1);

    // Sign with CA key
    if (c.X509_sign(x509, ca_key, c.EVP_sha256()) == 0) return error.CertSignFailed;

    return DomainCert{ .cert = @ptrCast(x509), .key = @ptrCast(pkey) };
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

    for (linux_trust_stores) |store| {
        if (tryCopyCert(ca_cert_path, store.cert_path)) {
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
    for (linux_trust_stores) |store| {
        if (tryCopyCert(ca_cert_path, store.cert_path)) {
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

fn tryCopyCert(src_path: []const u8, dest_path: []const u8) bool {
    // Check if already installed
    std.fs.accessAbsolute(dest_path, .{}) catch {
        // Not present, try to copy
        std.fs.copyFileAbsolute(src_path, dest_path, .{}) catch return false;
        return true;
    };
    // Already exists, overwrite to ensure up-to-date
    std.fs.copyFileAbsolute(src_path, dest_path, .{}) catch return false;
    return true;
}

pub fn freeCertPaths(allocator: Allocator, paths: *CertPaths) void {
    allocator.free(paths.dir);
    allocator.free(paths.ca_cert);
    allocator.free(paths.ca_key);
}
