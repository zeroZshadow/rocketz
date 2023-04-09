const std = @import("std");
const rocket = @import("rocket");
const network = @import("network");
const sdl = @import("sdl2");
const bass = @import("bass");

const bpm: f32 = 150.0; // beats per minute
const rpb: i32 = 8; // rows per beat
const row_rate: f64 = (@as(f64, bpm) / 60.0) * @intToFloat(f32, rpb);

fn getRow(stream: u32) f64 {
    const pos = bass.BASS_ChannelGetPosition(stream, bass.BASS_POS_BYTE);
    const time = bass.BASS_ChannelBytes2Seconds(stream, pos);
    return time * row_rate;
}

fn pause(stream: u32, flag: i32) void {
    if (flag != 0) {
        _ = bass.BASS_ChannelPause(stream);
    } else {
        _ = bass.BASS_ChannelPlay(stream, 0);
    }
}

fn setRow(stream: u32, row: u32) void {
    var pos = bass.BASS_ChannelSeconds2Bytes(stream, @intToFloat(f64, row) / row_rate);
    _ = bass.BASS_ChannelSetPosition(stream, pos, bass.BASS_POS_BYTE);
}

fn isPlaying(stream: u32) bool {
    return bass.BASS_ChannelIsActive(stream) == bass.BASS_ACTIVE_PLAYING;
}

fn openTrackFile(name: []const u8) anyerror!std.fs.File {
    const cwd = std.fs.cwd();
    return try cwd.openFile(name, .{});
}

fn closeTrackFile(file: std.fs.File) void {
    file.close();
}

fn readTrackFile(file: std.fs.File) std.fs.File.Reader {
    return file.reader();
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
        .audio = false,
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
    var device = try rocket.SyncDevice(
        rocket.SyncCallbacks(u32),
        .{
            .pause = pause,
            .setRow = setRow,
            .isPlaying = isPlaying,
        },
        rocket.IOCallbacks(std.fs.File, std.fs.File.Reader),
        .{
            .open = openTrackFile,
            .close = closeTrackFile,
            .read = readTrackFile,
        },
    ).init(allocator, "demo/sync");
    defer device.deinit();
    try device.connectTcp("localhost", 1338);

    // Start app
    var clear_r = try device.getTrack("clear.r");
    var clear_g = try device.getTrack("clear.g");
    var clear_b = try device.getTrack("clear.b");
    _ = try device.getTrack("camera:rot.y");
    _ = try device.getTrack("camera:dist");

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
        try device.update(
            @floatToInt(u32, row),
            stream,
        );

        const val_r = clear_r.getValue(row);
        const val_g = clear_g.getValue(row);
        const val_b = clear_b.getValue(row);
        const r = @floatToInt(u8, val_r * 255.0);
        const g = @floatToInt(u8, val_g * 255.0);
        const b = @floatToInt(u8, val_b * 255.0);
        try renderer.setColorRGB(r, g, b);
        try renderer.clear();

        _ = bass.BASS_Update(0);

        renderer.present();
    }
}
