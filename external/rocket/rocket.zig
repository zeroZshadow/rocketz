const std = @import("std");
const os = std.os;
const math = std.math;
const assert = std.debug.assert;
const network = @import("network");

pub const IOCallbacks = struct {
    //    open: *const fn (file_path: []const u8) OpenError!*anyopaque,
    //  read: *const fn (handle: *anyopaque, bytes: []u8) ReadError!void,
    //close: *const fn (handle: *anyopaque) void,
};

pub const SyncCallbacks = struct {
    pause: *const fn (ptr: *anyopaque, flag: i32) void,
    setRow: *const fn (ptr: *anyopaque, row: u32) void,
    isPlaying: *const fn (ptr: *anyopaque) bool,
};

pub fn SyncDevice(comptime callbacks: IOCallbacks) type {
    return struct {
        const Self = @This();
        const ioCallbacks = callbacks;

        allocator: std.mem.Allocator,
        base: []const u8,
        tracks: []*Track,

        //#ifndef SYNC_PLAYER
        row: u32,
        socket: ?network.Socket,
        socketSet: ?network.SocketSet,
        //#endif

        pub fn init(allocator: std.mem.Allocator, base: []const u8) !Self {
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
            };

            return device;
        }

        pub fn deinit(device: *Self) void {
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

        pub fn update(device: *Self, row: u32, cb: *const SyncCallbacks, cb_param: *anyopaque) !void {
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
                if (device.row != row and device.socket != null) {
                    var writer = socket.writer();
                    try writer.writeByte(@enumToInt(Commands.SET_ROW));
                    try writer.writeIntBig(u32, row);
                    device.row = row;
                }
            }
        }

        pub fn getTrack(device: *Self, name: []const u8) !*const Track {
            if (findTrack(device, name)) |idx| {
                return device.tracks[idx];
            } else |err| switch (err) {
                error.NotFound => {},
                else => return err,
            }

            var t = try createTrack(device, name);

            if (device.socket) |_| {
                try fetchTrackData(device, t);
            } else {
                try readTrackData(device, t);
            }

            return t;
        }

        fn findTrack(device: *Self, name: []const u8) !usize {
            for (device.tracks, 0..) |t, i| {
                if (std.mem.eql(u8, t.name, name)) {
                    return i;
                }
            }

            return error.NotFound;
        }

        fn readTrackData(d: *Self, t: *Track) !void {
            _ = t;
            _ = d;
            // var callbacks = d.ioCallbacks.?;

            // const trackPath = try syncTrackPath(d.allocator, d.base, t.name);
            // defer d.allocator.free(trackPath);

            // var reader = try callbacks.open(trackPath);

            // var keyCount = try reader.readIntBig(u32);
            // t.keys = try std.ArrayList(track.TrackKey).initCapacity(d.allocator, keyCount);

            // for (0..keyCount) |idx| {
            //     var key = track.TrackKey{
            //         .row = try reader.readIntBig(u32),
            //         .value = @bitCast(f32, try reader.readIntBig(u32)),
            //         .type = try @intToEnum(track.KeyType, reader.readIntBig(u8)),
            //     };
            //     t.keys.insertAssumeCapacity(idx, key);
            // }

            // // close
            // callbacks.close(reader);
        }

        pub fn syncSaveTracks(d: *const Self) !void {
            for (d.tracks) |t| {
                const path = try syncTrackPath(d.allocator, d.base, t.name);
                defer d.allocator.free(path);

                try saveTrack(t, path);
            }
        }

        fn fetchTrackData(device: *Self, t: *Track) !void {
            if (device.socket) |socket| {
                var writer = socket.writer();
                try writer.writeByte(@enumToInt(Commands.GET_TRACK));
                try writer.writeIntBig(u32, @truncate(u32, t.name.len));
                try writer.writeAll(t.name);
            }
        }

        fn handleSetKeyCmd(device: *Self) !void {
            var socket = device.socket.?;

            var reader = socket.reader();
            var trackIdx = try reader.readIntBig(u32);
            var row = try reader.readIntBig(u32);
            var floatAsInt = try reader.readIntBig(u32);
            var keyType = try reader.readIntBig(u8);
            var floatVal = @bitCast(f32, floatAsInt);

            var key: TrackKey = .{
                .row = row,
                .value = floatVal,
                .type = @intToEnum(KeyType, keyType),
            };

            if (trackIdx >= device.tracks.len) {
                return error.OutOfRange;
            }

            return device.tracks[trackIdx].setKey(key);
        }

        fn handleDelKeyCmd(device: *Self) !void {
            var socket = device.socket.?;

            var reader = socket.reader();
            var trackIdx = try reader.readIntBig(u32);
            var row = try reader.readIntBig(u32);

            if (trackIdx >= device.tracks.len) {
                return error.OutOfRange;
            }

            return device.tracks[trackIdx].deleteKey(row);
        }

        pub fn connectTcp(device: *Self, host: []const u8, port: u16) !void {
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

            // Handhshake
            const clientGreet: []const u8 = "hello, synctracker!";
            const serverGreet: []const u8 = "hello, demo!";

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

        fn createTrack(d: *Self, name: []const u8) !*Track {
            var allocator = d.allocator;

            var t = try allocator.create(Track);
            errdefer allocator.destroy(t);

            t.name = try allocator.dupe(u8, name);
            t.keys = Track.Keys.init(d.allocator);

            const newLength = d.tracks.len + 1;
            d.tracks = try allocator.realloc(d.tracks, newLength);
            d.tracks[newLength - 1] = t;

            return t;
        }
    };
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

fn syncTrackPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    const nameEncoded = try pathEncode(allocator, name);
    defer allocator.free(nameEncoded);

    return try std.mem.concat(allocator, u8, &[_][]const u8{
        base,
        "_",
        nameEncoded,
        ".track",
    });
}

//#ifndef SYNC_PLAYER

const Commands = enum(u8) {
    SET_KEY = 0,
    DELETE_KEY = 1,
    GET_TRACK = 2,
    SET_ROW = 3,
    PAUSE = 4,
    SAVE_TRACKS = 5,
};

// //#endif

fn createLeadingDirs(path: []const u8) !void {
    _ = path;
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
}

fn saveTrack(t: *const Track, path: []const u8) !void {
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

pub const KeyType = enum {
    Step,
    Linear,
    Smooth,
    Ramp,
};

pub const TrackKey = struct {
    row: u32,
    value: f32,
    type: KeyType,
};

pub const Track = struct {
    const Keys = std.ArrayList(TrackKey);

    name: []u8,
    keys: Keys,

    inline fn keyIndexFloor(track: *const Track, row: u32) u32 {
        var result = track.findKey(row);
        if (result.found) {
            return result.index;
        } else {
            return result.index - 1;
        }
    }

    //#ifndef SYNC_PLAYER
    inline fn isKeyFrame(track: *const Track, row: u32) bool {
        return track.findKey(row).found;
    }

    //#endif /* !defined(SYNC_PLAYER) */

    // track.c
    fn keyLinear(keys: [2]TrackKey, row: f64) f64 {
        var t = (row - @intToFloat(f64, keys[0].row)) / @intToFloat(f64, keys[1].row - keys[0].row);
        return keys[0].value + (keys[1].value - keys[0].value) * t;
    }

    fn keySmooth(keys: [2]TrackKey, row: f64) f64 {
        var t = (row - @intToFloat(f64, keys[0].row)) / @intToFloat(f64, keys[1].row - keys[0].row);
        t = t * t * (3.0 - 2.0 * t);
        return keys[0].value + (keys[1].value - keys[0].value) * t;
    }

    fn keyRamp(keys: [2]TrackKey, row: f64) f64 {
        var t = (row - @intToFloat(f64, keys[0].row)) / @intToFloat(f64, keys[1].row - keys[0].row);
        t = math.pow(f64, t, 2.0);
        return keys[0].value + (keys[1].value - keys[0].value) * t;
    }

    pub fn getValue(track: *const Track, row: f64) f64 {
        // If we have no keys at all, return a constant 0
        if (track.keys.items.len == 0) {
            return 0.0;
        }

        var irow = @floatToInt(u32, row);
        var idx = keyIndexFloor(track, irow);

        // at the edges, return the first/last value
        if (idx < 0) {
            return track.keys.items[0].value;
        }
        if (track.keys.items[idx..].len < 2) {
            return track.keys.items[track.keys.items.len - 1].value;
        }

        // interpolate according to key-type
        return switch (track.keys.items[idx].type) {
            .Step => track.keys.items[idx].value,
            .Linear => keyLinear(track.keys.items[idx..][0..2].*, row),
            .Smooth => keySmooth(track.keys.items[idx..][0..2].*, row),
            .Ramp => keyRamp(track.keys.items[idx..][0..2].*, row),
        };
    }

    pub fn findKey(t: *const Track, row: u32) struct { index: u32, found: bool } {
        var lo = @as(usize, 0);
        var hi = t.keys.items.len;

        // binary search, t->keys is sorted by row
        while (lo < hi) {
            var mi = (lo + hi) / 2;
            assert(mi != hi);

            if (t.keys.items[mi].row < row) {
                lo = mi + 1;
            } else if (t.keys.items[mi].row > row) {
                hi = mi;
            } else {
                return .{ .index = @truncate(u32, mi), .found = true }; // exact hit
            }
        }
        assert(lo == hi);

        return .{ .index = @truncate(u32, lo), .found = false };
    }

    //#ifndef SYNC_PLAYER
    pub fn setKey(track: *Track, key: TrackKey) !void {
        const result = track.findKey(key.row);
        if (!result.found) {
            // no exact hit, we need to allocate a new key
            return try track.keys.insert(result.index, key);
        }

        track.keys.items[result.index] = key;
    }

    pub fn deleteKey(track: *Track, pos: u32) !void {
        var result = track.findKey(pos);
        assert(result.found);

        _ = track.keys.orderedRemove(result.index);
    }
};
