const std = @import("std");
const track = @import("track.zig");
const sync = @import("sync.zig");
const network = @import("network");

//device.h
pub const SyncDevice = struct {
    allocator: std.mem.Allocator,
    base: []const u8,
    tracks: []*track.SyncTrack,

    //#ifndef SYNC_PLAYER
    row: u32,
    socket: ?network.Socket,
    socketSet: ?network.SocketSet,
    //#endif
    ioCallbacks: ?sync.SyncIOCallbacks,

    pub fn init(allocator: std.mem.Allocator, base: []const u8) !SyncDevice {
        if (base.len == 0 or base[0] == '/') {
            return error.InvalidBaseName;
        }

        var device = .{
            .allocator = allocator,
            .base = try pathEncode(allocator, base),
            .tracks = &.{},
            //#ifndef SYNC_PLAYER
            .row = 0, //-1 ?
            .socket = null,
            .socketSet = null,
            //#endif
            .ioCallbacks = null,
        };

        // device.ioCallbacks = .{
        //     .open = null,
        //     .read = null,
        //     .close = null,
        // };

        // device.ioCallbacks.open = (void *(*)(const char *, const char *))fopen;
        // device.ioCallbacks.read = (size_t (*)(void *, size_t, size_t, void *))fread;
        // device.ioCallbacks.close = (int (*)(void *))fclose;

        return device;
    }

    pub fn deinit(device: *SyncDevice) void {
        var allocator = device.allocator;

        for (device.tracks) |t| {
            allocator.free(t.name);
            t.keys.deinit();
            allocator.destroy(t);
        }

        //#ifndef SYNC_PLAYER
        if (device.socket) |*s| {
            s.close();
        }
        if (device.socketSet) |*s| {
            s.deinit();
        }
        //#endif

        allocator.free(device.tracks);
        allocator.free(device.base);
    }

    pub fn update(device: *SyncDevice, row: u32, cb: *const sync.SyncCallbacks, cb_param: *anyopaque) !void {
        var socket = device.socket.?;
        var socketSet = device.socketSet.?;
        errdefer socket.close();

        while (try network.waitForSocketEvent(&socketSet, 0) != 0 and socketSet.isReadyRead(socket)) {
            var reader = socket.reader();
            const cmd = try reader.readEnum(Commands, .Big);

            try switch (cmd) {
                Commands.SET_KEY => handleSetKeyCmd(device),
                Commands.DELETE_KEY => handleDelKeyCmd(device),
                Commands.SET_ROW => {
                    const newRow = try reader.readInt(u32, .Big);
                    cb.setRow(cb_param, newRow);
                },
                Commands.PAUSE => {
                    const flag = try reader.readInt(u8, .Big);
                    cb.pause(cb_param, flag);
                },
                Commands.SAVE_TRACKS => try syncSaveTracks(device),
                else => @panic("Unknown command"),
            };
        }

        if (cb.isPlaying(cb_param)) {
            if (device.row != row) { //and d.socket != INVALID_SOCKET
                var writer = socket.writer();
                try writer.writeByte(@enumToInt(Commands.SET_ROW));
                try writer.writeIntBig(u32, row);
                device.row = row;
            }
        }
    }

    pub fn getTrack(device: *SyncDevice, name: []const u8) !*const track.SyncTrack {
        if (findTrack(device, name)) |idx| {
            return device.tracks[idx];
        } else |err| switch (err) {
            error.NotFound => {},
            else => return err,
        }

        var t = try createTrack(device, name);

        // #ifndef SYNC_PLAYER
        if (device.socket) |_| {
            try fetchTrackData(device, t);
        }
        //} else {
        // #endif
        //readTrackData(device, t);
        //}

        return t;
    }
};

//device.c
fn findTrack(device: *SyncDevice, name: []const u8) !usize {
    for (device.tracks, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) {
            return i;
        }
    }

    return error.NotFound;
}

inline fn validPathChar(ch: u8) bool {
    return switch (ch) {
        '.', '_', '/' => true,
        else => std.ascii.isAlphanumeric(ch),
    };
}

fn pathEncode(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var tempBuffer: [std.fs.MAX_NAME_BYTES]u8 = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    var pos: usize = 0;
    for (path) |ch| {
        if (validPathChar(ch)) {
            if (pos >= tempBuffer.len - 1) {
                break;
            }
            tempBuffer[pos] = ch;
            pos += 1;
        } else {
            if (pos >= tempBuffer.len - 3) {
                break;
            }

            tempBuffer[pos] = '-';
            tempBuffer[pos + 1] = "0123456789ABCDEF"[(ch >> 4) & 0xF];
            tempBuffer[pos + 2] = "0123456789ABCDEF"[ch & 0xF];
            pos += 3;
        }
    }

    var buffer = try allocator.alloc(u8, pos);
    std.mem.copy(u8, buffer, tempBuffer[0..pos]);

    return buffer;
}

fn syncTrackPath(base: []const u8, name: []const u8) []const u8 {
    var temp: [std.fs.MAX_NAME_BYTES]u8 = [_]u8{0} ** std.fs.MAX_NAME_BYTES;
    _ = name;
    _ = base;
    _ = temp;
    // {base}_{pathEncode(name)}.track
    // strncpy(syncTrackPathTemp, base, sizeof(syncTrackPathTemp) - 1);
    // syncTrackPathTemp[sizeof(syncTrackPathTemp) - 1] = '\0';
    // strncat(syncTrackPathTemp, "_", sizeof(syncTrackPathTemp) - strlen(syncTrackPathTemp) - 1);
    // strncat(syncTrackPathTemp, path_encode(syncTrackPathTemp), sizeof(syncTrackPathTemp) - strlen(syncTrackPathTemp) - 1);
    // strncat(syncTrackPathTemp, ".track", sizeof(syncTrackPathTemp) - strlen(syncTrackPathTemp) - 1);
    // return syncTrackPathTemp;
}

//#ifndef SYNC_PLAYER

const clientGreet: []const u8 = "hello, synctracker!";
const serverGreet: []const u8 = "hello, demo!";

const Commands = enum(u8) {
    SET_KEY = 0,
    DELETE_KEY = 1,
    GET_TRACK = 2,
    SET_ROW = 3,
    PAUSE = 4,
    SAVE_TRACKS = 5,
};

// //#else

fn syncSetIOCallbacks(d: *SyncDevice, cb: *sync.SyncIOCallbacks) void {
    d.ioCallbacks = cb.*;
}

// //#endif

fn readTrackData(d: *SyncDevice, t: *track.SyncTrack) !void {
    _ = t;
    _ = d;
    @panic("NOT IMPLEMENTED");
    // 	int i;
    // 	void *fp = d->io_cb.open(sync_track_path(d->base, t->name), "rb");
    // 	if (!fp)
    // 		return -1;

    // 	d->io_cb.read(&t->num_keys, sizeof(int), 1, fp);
    // 	t->keys = malloc(sizeof(struct track_key) * t->num_keys);
    // 	if (!t->keys)
    // 		return -1;

    // 	for (i = 0; i < (int)t->num_keys; ++i) {
    // 		struct track_key *key = t->keys + i;
    // 		char type;
    // 		d->io_cb.read(&key->row, sizeof(int), 1, fp);
    // 		d->io_cb.read(&key->value, sizeof(float), 1, fp);
    // 		d->io_cb.read(&type, sizeof(char), 1, fp);
    // 		key->type = (enum key_type)type;
    //}

    // 	d->io_cb.close(fp);
    // 	return 0;
}

// static int create_leading_dirs(const char *path)
// {
// 	char *pos, buf[FILENAME_MAX];

// 	strncpy(buf, path, sizeof(buf));
// 	buf[sizeof(buf) - 1] = '\0';
// 	pos = buf;

// 	while (1) {
// 		struct stat st;

// 		pos = strchr(pos, '/');
// 		if (!pos)
// 			break;
// 		*pos = '\0';

// 		/* does path exist, but isn't a dir? */
// 		if (!stat(buf, &st)) {
// 			if (!S_ISDIR(st.st_mode))
// 				return -1;
// 		} else {
// 			if (mkdir(buf, 0777))
// 				return -1;
// 		}

// 		*pos++ = '/';
// 	}

// 	return 0;
// }

fn saveTrack(t: *const track.SyncTrack, path: []const u8) !void {
    _ = path;
    _ = t;
    // 	int i;
    // 	FILE *fp;

    // 	if (create_leading_dirs(path))
    // 		return -1;

    // 	fp = fopen(path, "wb");
    // 	if (!fp)
    // 		return -1;

    // 	fwrite(&t->num_keys, sizeof(int), 1, fp);
    // 	for (i = 0; i < (int)t->num_keys; ++i) {
    // 		char type = (char)t->keys[i].type;
    // 		fwrite(&t->keys[i].row, sizeof(int), 1, fp);
    // 		fwrite(&t->keys[i].value, sizeof(float), 1, fp);
    // 		fwrite(&type, sizeof(char), 1, fp);
    // 	}

    // 	fclose(fp);
    // 	return 0;
}

pub fn syncSaveTracks(d: *const SyncDevice) !void {
    _ = d;
    // 	int i;
    // 	for (i = 0; i < (int)d->num_tracks; ++i) {
    // 		const struct sync_track *t = d->tracks[i];
    // 		if (save_track(t, sync_track_path(d->base, t->name)))
    // 			return -1;
    // 	}
    // 	return 0;
}

// #ifndef SYNC_PLAYER

fn fetchTrackData(device: *SyncDevice, t: *track.SyncTrack) !void {
    if (device.socket) |socket| {
        var writer = socket.writer();
        try writer.writeByte(@enumToInt(Commands.GET_TRACK));
        try writer.writeIntBig(u32, @truncate(u32, t.name.len));
        try writer.writeAll(t.name);
    }
}

fn handleSetKeyCmd(device: *SyncDevice) !void {
    var socket = device.socket.?;

    var reader = socket.reader();
    var trackIdx = try reader.readIntBig(u32);
    var row = try reader.readIntBig(u32);
    var floatAsInt = try reader.readIntBig(u32);
    var t = try reader.readIntBig(u8);
    var floatVal = @bitCast(f32, floatAsInt);

    var key: track.TrackKey = .{
        .row = row,
        .value = floatVal,
        .type = @intToEnum(track.KeyType, t),
    };

    if (trackIdx >= device.tracks.len) {
        return error.OutOfRange;
    }

    return track.syncSetKey(device.tracks[trackIdx], key);
}

fn handleDelKeyCmd(device: *SyncDevice) !void {
    var socket = device.socket.?;

    var reader = socket.reader();
    var trackIdx = try reader.readIntBig(u32);
    var row = try reader.readIntBig(u32);

    if (trackIdx >= device.tracks.len) {
        return error.OutOfRange;
    }

    return track.syncDelKey(device.tracks[trackIdx], row);
}

pub fn syncTcpConnect(device: *SyncDevice, host: []const u8, port: u16) !void {
    if (device.socket) |s| {
        s.close();
        device.socketSet.?.deinit();
    }

    device.socket = try network.connectToHost(device.allocator, host, port, .tcp);
    errdefer device.socket.?.close();

    device.socketSet = try network.SocketSet.init(device.allocator);
    errdefer device.socketSet.?.deinit();

    try device.socketSet.?.add(device.socket.?, .{
        .read = true,
        .write = false,
    });

    var writer = device.socket.?.writer();
    try writer.writeAll(clientGreet);

    var greet: [serverGreet.len]u8 = undefined;
    var reader = device.socket.?.reader();
    _ = try reader.readAll(&greet);

    if (!std.mem.eql(u8, &greet, serverGreet)) {
        return error.InvalidGreeting;
    }

    // Destroy all old keys
    for (device.tracks) |t| {
        t.keys.deinit();
    }

    // Update new data
    for (device.tracks) |t| {
        try fetchTrackData(device, t);
    }
}

// #endif /* !defined(SYNC_PLAYER) */

fn createTrack(d: *SyncDevice, name: []const u8) !*track.SyncTrack {
    var allocator = d.allocator;

    var t = try allocator.create(track.SyncTrack);
    errdefer allocator.destroy(t);

    t.name = try allocator.dupe(u8, name);
    t.keys = std.ArrayList(track.TrackKey).init(d.allocator);

    const newLength = d.tracks.len + 1;
    d.tracks = try allocator.realloc(d.tracks, newLength);
    d.tracks[newLength - 1] = t;

    return t;
}
