const std = @import("std");
const sdl_sdk = @import("external/sdl/Sdk.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const network_dep = b.dependency("network", .{});

    const rocket = b.addModule("rocket", .{
        .source_file = .{ .path = "external/rocket/rocket.zig" },
        .dependencies = &.{
            .{
                .name = "network",
                .module = network_dep.module("network"),
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig-rocket",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("network", network_dep.module("network"));

    const sdk = sdl_sdk.init(b, null);
    sdk.link(exe, .dynamic);
    exe.addModule("sdl2", sdk.getWrapperModule());

    const bassTranslatedHeader = b.addTranslateC(.{
        .source_file = .{ .path = "external/bass/bass.h" },
        .target = target,
        .optimize = optimize,
    });
    exe.step.dependOn(&bassTranslatedHeader.step);
    exe.addAnonymousModule("bass", .{
        .source_file = .{ .generated = &bassTranslatedHeader.output_file },
    });
    exe.addLibraryPath("external/bass/libs/x86_64");

    const targetInfo = (std.zig.system.NativeTargetInfo.detect(target) catch @panic("failed to detect native target info!")).target;
    if (targetInfo.os.tag == .linux) {
        b.installLibFile("external/bass/libs/x86_64/libbass.so", "libbass.so");
    } else if (targetInfo.os.tag == .windows) {
        b.installBinFile("external/bass/libs/x86_64/bass.dll", "bass.dll");
    } else {
        @panic("OS not supported");
    }
    exe.linkSystemLibrary("bass");

    exe.addModule("rocket", rocket);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
}
