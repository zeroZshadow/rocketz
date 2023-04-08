const std = @import("std");
const track = @import("track.zig");
const sync = @import("sync.zig");
const device = @import("device.zig");
const network = @import("network");
const sdl = @import("sdl2");
const bass = @import("bass");

const bpm: f32 = 150.0; // beats per minute
const rpb: i32 = 8; // rows per beat
const row_rate: f64 = (@as(f64, bpm) / 60.0) * @intToFloat(f32, rpb);

const callbacks: sync.SyncCallbacks = .{
    .pause = &pause,
    .setRow = &setRow,
    .isPlaying = &isPlaying,
};

fn getRow(stream: u32) f64 {
    const pos = bass.BASS_ChannelGetPosition(stream, bass.BASS_POS_BYTE);
    const time = bass.BASS_ChannelBytes2Seconds(stream, pos);
    return time * row_rate;
}

fn pause(ptr: *anyopaque, flag: i32) void {
    var stream = @ptrCast(*u32, @alignCast(@alignOf(u32), ptr)).*;

    if (flag != 0) {
        _ = bass.BASS_ChannelPause(stream);
    } else {
        _ = bass.BASS_ChannelPlay(stream, 0);
    }
}

fn setRow(ptr: *anyopaque, row: u32) void {
    var stream = @ptrCast(*u32, @alignCast(@alignOf(u32), ptr)).*;

    var pos = bass.BASS_ChannelSeconds2Bytes(stream, @intToFloat(f64, row) / row_rate);
    _ = bass.BASS_ChannelSetPosition(stream, pos, bass.BASS_POS_BYTE);
}

fn isPlaying(ptr: *anyopaque) bool {
    var stream = @ptrCast(*u32, @alignCast(@alignOf(u32), ptr)).*;

    return bass.BASS_ChannelIsActive(stream) == bass.BASS_ACTIVE_PLAYING;
}

pub fn main() !void {
    errdefer @breakpoint();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Network init
    try network.init();
    defer network.deinit();

    // SDL Init
    try sdl.init(.{
        .video = true,
        .events = true,
        .audio = true,
    });
    defer sdl.quit();

    var window = try sdl.createWindow(
        "Zig Rocket Demo",
        .{ .centered = {} },
        .{ .centered = {} },
        640,
        480,
        .{ .vis = .shown },
    );
    defer window.destroy();

    var renderer = try sdl.createRenderer(
        window,
        null,
        .{ .accelerated = true },
    );
    defer renderer.destroy();

    // Bass init
    if (bass.BASS_Init(-1, 44100, 0, null, null) == 0) {
        return error.BassError;
    }
    defer _ = bass.BASS_Free();

    var stream = bass.BASS_StreamCreateFile(0, "tune.ogg", 0, 0, bass.BASS_STREAM_PRESCAN);
    if (stream == 0) {
        return error.BassError;
    }
    defer _ = bass.BASS_StreamFree(stream);

    // Rocket init
    var rocket = try device.SyncDevice.init(allocator, "sync");
    defer rocket.deinit();

    try device.syncTcpConnect(&rocket, "localhost", 1338);
    std.debug.print("Connected \n", .{});

    // Start app
    var clear_r = try rocket.getTrack("clear.r");
    var clear_g = try rocket.getTrack("clear.g");
    var clear_b = try rocket.getTrack("clear.b");
    _ = try rocket.getTrack("camera:rot.y");
    _ = try rocket.getTrack("camera:dist");

    _ = bass.BASS_Start();
    _ = bass.BASS_ChannelPlay(stream, 0);

    mainLoop: while (true) {
        while (sdl.pollEvent()) |ev| {
            switch (ev) {
                .quit => break :mainLoop,
                else => {},
            }
        }

        var row = getRow(stream);
        try rocket.update(
            @floatToInt(u32, row),
            &callbacks,
            @ptrCast(*anyopaque, &stream),
        );

        const val_r = track.syncGetVal(clear_r, row);
        const val_g = track.syncGetVal(clear_g, row);
        const val_b = track.syncGetVal(clear_b, row);
        const r = @floatToInt(u8, val_r * 255.0);
        const g = @floatToInt(u8, val_g * 255.0);
        const b = @floatToInt(u8, val_b * 255.0);
        try renderer.setColorRGB(r, g, b);
        try renderer.clear();

        _ = bass.BASS_Update(0);

        renderer.present();
    }
}
