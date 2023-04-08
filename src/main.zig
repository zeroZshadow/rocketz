const std = @import("std");
const track = @import("track.zig");
const sync = @import("sync.zig");
const device = @import("device.zig");
const network = @import("network");

const callbacks: sync.SyncCallbacks = .{
    .pause = &pause,
    .setRow = &setRow,
    .isPlaying = &isPlaying,
};

fn pause(ptr: [*]void, flag: i32) void {
    _ = flag;
    _ = ptr;
}

fn setRow(ptr: [*]void, row: u32) void {
    _ = row;
    _ = ptr;
}

fn isPlaying(ptr: [*]void) bool {
    _ = ptr;
    return true;
}

var stream: u32 = 0;

pub fn main() !void {
    try network.init();
    defer network.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rocket = try device.SyncDevice.init(allocator, "sync");
    defer rocket.deinit();

    try device.syncTcpConnect(&rocket, "localhost", 1338);
    std.debug.print("Connected \n", .{});

    _ = try rocket.getTrack("camera:x");
    _ = try rocket.getTrack("camera:y");
    _ = try rocket.getTrack("camera:z");
    _ = try rocket.getTrack("thing");

    while (true) {
        try rocket.update(
            0,
            &callbacks,
            @ptrCast([*]void, &stream),
        );
        break;
    }
}
