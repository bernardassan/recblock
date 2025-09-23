const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const lto = b.option(bool, "lto", "Enable link time optimization") orelse false;
    const no_bin = b.option(bool, "no-bin", "skip emitting binary for incremental compilation checks") orelse false;

    //Add lmdb library for embeded key/value store
    const lmdb_dep = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
    });

    const target_name = target.query.allocDescription(b.allocator) catch unreachable;
    const exe_name = std.fmt.allocPrint(
        b.allocator,
        "{[program]s}-{[target]s}",
        .{
            .program = "recblock",
            .target = target_name,
        },
    ) catch unreachable;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = mod,
    });
    exe.want_lto = lto;

    const s2s_dep = b.dependency("s2s", .{
        .target = target,
        .optimize = optimize,
    });
    const s2s = s2s_dep.module("s2s");
    const liblmdb = lmdb_dep.artifact("lmdb");
    const lmdb = lmdb_dep.module("lmdb");

    exe.root_module.addImport("s2s", s2s);
    exe.root_module.addImport("mdb", lmdb);
    exe.linkLibrary(liblmdb);
    b.installArtifact(exe);

    const check = b.addExecutable(.{
        .name = "check",
        .root_module = mod,
    });
    check.root_module.addImport("s2s", s2s);
    check.root_module.addImport("mdb", lmdb);
    check.linkLibrary(liblmdb);

    // zls with build_on_save_args = ["check", "--watch", "-fincremental"]
    // for ultra fast zig error reporting using incremental compilation
    const check_step = b.step("check", "Zls: Check if recblock compiles");
    check_step.dependOn(&check.step);

    // For use with incremental compilation checks
    // zig build -Dno-bin -fincremental --watch
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = mod,
    });
    exe_tests.root_module.addImport("s2s", s2s);
    exe_tests.root_module.addImport("mdb", lmdb);
    exe_tests.linkLibrary(liblmdb);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
