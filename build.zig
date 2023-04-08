const std = @import("std");
const sdl_sdk = @import("external/sdl/Sdk.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-rocket",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const network_dep = b.dependency("network", .{});
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
    b.installLibFile("external/bass/libs/x86_64/libbass.so", "libbass.so");
    exe.linkSystemLibrary("bass");

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
