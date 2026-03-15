const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{});
    const zig_yaml = b.dependency("zig_yaml", .{});
    // OpenSSL uses function pointer casts (e.g. OPENSSL_sk_pop_free) that are
    // technically undefined behavior in C. ReleaseSafe enables UBSan which
    // traps on these, so always build OpenSSL with ReleaseFast.
    const openssl = b.dependency("openssl", .{
        .target = target,
        .optimize = .ReleaseFast,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "yaml", .module = zig_yaml.module("yaml") },
        },
    });
    root_module.linkLibrary(openssl.artifact("openssl"));

    const exe = b.addExecutable(.{
        .name = "dockportless",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run dockportless");
    run_step.dependOn(&run_cmd.step);

    // Tests: main (includes proxy, tcp_proxy, cert via imports)
    const main_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "yaml", .module = zig_yaml.module("yaml") },
        },
    });
    main_test_module.linkLibrary(openssl.artifact("openssl"));

    const exe_unit_tests = b.addTest(.{
        .root_module = main_test_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const compose_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compose.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "yaml", .module = zig_yaml.module("yaml") },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(compose_tests).step);

    const port_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/port.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(port_tests).step);

    const mapping_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mapping.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mapping_tests).step);

    const executor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/executor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(executor_tests).step);

    // proxy tests need OpenSSL because proxy.zig imports tcp_proxy.zig
    const proxy_test_module = b.createModule(.{
        .root_source_file = b.path("src/proxy.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    proxy_test_module.linkLibrary(openssl.artifact("openssl"));

    const proxy_tests = b.addTest(.{
        .root_module = proxy_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(proxy_tests).step);

    const watcher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/watcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(watcher_tests).step);

    // cert tests need OpenSSL because cert.zig uses OpenSSL C API
    const cert_test_module = b.createModule(.{
        .root_source_file = b.path("src/cert.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cert_test_module.linkLibrary(openssl.artifact("openssl"));

    const cert_tests = b.addTest(.{
        .root_module = cert_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(cert_tests).step);

}
