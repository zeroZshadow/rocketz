const std = @import("std");
const rocket = @import("rocket");
const network = @import("network");
const sdl = @import("sdl2");
const bass = @import("bass");

const bpm: f32 = 150.0; // beats per minute
const rpb: i32 = 8; // rows per beat
const row_rate: f64 = (bpm / 60.0) * @as(f32, @floatFromInt(rpb));

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
    const pos = bass.BASS_ChannelSeconds2Bytes(stream, @as(f64, @floatFromInt(row)) / row_rate);
    _ = bass.BASS_ChannelSetPosition(stream, pos, bass.BASS_POS_BYTE);
}

fn isPlaying(stream: u32) bool {
    return bass.BASS_ChannelIsActive(stream) == bass.BASS_ACTIVE_PLAYING;
}

pub const NetworkContext = struct {
    socket: network.Socket,
    socketSet: network.SocketSet,
};

pub const NetworkIO = struct {
    pub const Type = rocket.NetworkCallbacks(NetworkContext, network.Socket.Reader, network.Socket.Writer);
    pub const callbacks: Type = .{
        .connect = connect,
        .close = close,
        .read = read,
        .write = write,
        .poll = poll,
    };

    fn connect(allocator: std.mem.Allocator, hostname: []const u8, port: u16) anyerror!NetworkContext {
        var socket = try network.connectToHost(allocator, hostname, port, .tcp);
        errdefer socket.close();
        var socketSet = try network.SocketSet.init(allocator);
        errdefer socketSet.deinit();
        try socketSet.add(socket, .{ .read = true, .write = false });

        return .{
            .socket = socket,
            .socketSet = socketSet,
        };
    }

    fn close(context: *NetworkContext) void {
        context.socketSet.deinit();
        context.socket.close();
    }

    fn read(context: *NetworkContext) network.Socket.Reader {
        return context.socket.reader();
    }

    fn write(context: *NetworkContext) network.Socket.Writer {
        return context.socket.writer();
    }

    fn poll(context: *NetworkContext) anyerror!bool {
        return try network.waitForSocketEvent(&context.socketSet, 0) != 0 and context.socketSet.isReadyRead(context.socket);
    }
};

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

    const stream = bass.BASS_StreamCreateFile(0, "tune.ogg", 0, 0, bass.BASS_STREAM_PRESCAN);
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
        rocket.FileIO.Type,
        rocket.FileIO.callbacks,
        NetworkIO.Type,
        NetworkIO.callbacks,
    ).init(allocator, "demo/sync");
    defer device.deinit();
    device.connect("localhost", 1338) catch |err| {
        switch (err) {
            error.CouldNotConnect => {
                std.log.err("Failed to connect", .{});
                return;
            },
            else => return err,
        }
    };

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

        const row = getRow(stream);
        device.update(
            @as(u32, @intFromFloat(row)),
            stream,
        ) catch return;

        const val_r = clear_r.getValue(row);
        const val_g = clear_g.getValue(row);
        const val_b = clear_b.getValue(row);
        const r: u8 = @intFromFloat(val_r * 255.0);
        const g: u8 = @intFromFloat(val_g * 255.0);
        const b: u8 = @intFromFloat(val_b * 255.0);
        try renderer.setColorRGB(r, g, b);
        try renderer.clear();

        _ = bass.BASS_Update(0);

        renderer.present();
    }
}
