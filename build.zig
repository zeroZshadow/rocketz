const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const network_dep = b.dependency("network", .{});
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,

        //Parts
        .core = true,
    });

    const rocket_module = b.addModule("rocket", .{
        .root_source_file = .{ .path = "external/rocket/rocket.zig" },
    });

    const bassTranslatedHeader = b.addTranslateC(.{
        .root_source_file = .{ .path = "external/bass/bass.h" },
        .target = target,
        .optimize = optimize,
    });

    const bass_module = bassTranslatedHeader.addModule("bass");
    bass_module.addLibraryPath(.{ .path = "external/bass/libs/x86_64" });

    if (target.result.os.tag == .linux) {
        b.installLibFile("external/bass/libs/x86_64/libbass.so", "libbass.so");
    } else if (target.result.os.tag == .windows) {
        b.installBinFile("external/bass/libs/x86_64/bass.dll", "bass.dll");
    } else {
        @panic("OS not supported");
    }

    // Demo
    const app = try mach.CoreApp.init(b, mach_dep.builder, .{
        .name = "zig-rocket",
        .src = "src/app.zig",
        .target = target,
        .optimize = optimize,
        .deps = &[_]std.Build.Module.Import{
            .{ .name = "network", .module = network_dep.module("network") },
            .{ .name = "rocket", .module = rocket_module },
            .{ .name = "bass", .module = bass_module },
        },
        .res_dirs = &[_][]const u8{
            "res",
        },
    });
    app.compile.linkSystemLibrary("bass");

    if (b.args) |args| app.run.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&app.run.step);
}
