const std = @import("std");
const rocket = @import("rocket");
const network = @import("network");
const bass = @import("bass");

pub const bpm: f32 = 150.0; // beats per minute
pub const rpb: i32 = 8; // rows per beat
pub const row_rate: f64 = (bpm / 60.0) * @as(f32, @floatFromInt(rpb));

pub const Device = rocket.SyncDevice(
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
);

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
