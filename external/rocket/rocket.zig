const std = @import("std");
const os = std.os;
const math = std.math;
const assert = std.debug.assert;

pub fn NetworkCallbacks(comptime contextType: type, comptime readerType: type, comptime writerType: type) type {
    return struct {
        const Context = contextType;
        const Reader = readerType;
        const Writer = writerType;

        connect: fn (allocator: std.mem.Allocator, hostname: []const u8, port: u16) anyerror!Context,
        close: fn (context: *Context) void,
        read: fn (context: *Context) Reader,
        write: fn (context: *Context) Writer,
        poll: fn (context: *Context) anyerror!bool,
    };
}

pub fn IOCallbacks(comptime contextType: type, comptime readerType: type) type {
    return struct {
        const Context = contextType;
        const Reader = readerType;

        open: fn (allocator: std.mem.Allocator, name: []const u8) anyerror!Context,
        close: fn (context: Context) void,
        read: fn (context: Context) Reader,
    };
}

pub const FileIO = struct {
    pub const Type = IOCallbacks(std.fs.File, std.fs.File.Reader);
    pub const callbacks: Type = .{
        .open = openTrackFile,
        .close = closeTrackFile,
        .read = readTrackFile,
    };

    fn openTrackFile(_: std.mem.Allocator, name: []const u8) anyerror!std.fs.File {
        const cwd = std.fs.cwd();
        return try cwd.openFile(name, .{});
    }

    fn closeTrackFile(file: std.fs.File) void {
        file.close();
    }

    fn readTrackFile(file: std.fs.File) std.fs.File.Reader {
        return file.reader();
    }
};

pub fn SyncCallbacks(comptime syncContextType: type) type {
    return struct {
        const Context = syncContextType;

        pause: fn (context: Context, flag: i32) void,
        setRow: fn (context: Context, row: u32) void,
        isPlaying: fn (context: Context) bool,
    };
}

pub fn SyncDevice(
    comptime syncCallbacksType: type,
    comptime callbacks: syncCallbacksType,
    comptime ioCallbacksType: type,
    comptime ioProvider: ioCallbacksType,
    comptime networkCallbacksType: type,
    comptime networkProvider: networkCallbacksType,
) type {
    return struct {
        const Self = @This();

        const syncCallbacks = callbacks;
        const ioCallbacks = ioProvider;
        const networkCallbacks = networkProvider;

        allocator: std.mem.Allocator,
        base: []const u8,
        tracks: []*Track,

        //#ifndef SYNC_PLAYER
        row: u32,
        networkContext: ?networkCallbacksType.Context,
        //#endif

        const SyncCallbacks = syncCallbacksType;
        const IOCallbacks = ioCallbacksType;

        pub fn init(allocator: std.mem.Allocator, base: []const u8) !Self {
            if (base.len == 0 or base[0] == '/') {
                return error.InvalidBaseName;
            }

            const device = .{
                .allocator = allocator,
                .base = try pathEncode(allocator, base),
                .tracks = &.{},
                //#ifndef SYNC_PLAYER
                .row = 0, //-1 ?
                .networkContext = null,
                //#endif
            };

            return device;
        }

        pub fn deinit(device: *Self) void {
            const allocator = device.allocator;

            for (device.tracks) |t| {
                allocator.free(t.name);
                t.keys.deinit();
                allocator.destroy(t);
            }

            //#ifndef SYNC_PLAYER
            if (device.networkContext) |*context| {
                networkCallbacks.close(context);
            }
            //#endif

            allocator.free(device.tracks);
            allocator.free(device.base);
        }

        pub fn update(device: *Self, row: u32, cb_param: Self.SyncCallbacks.Context) !void {
            if (device.networkContext == null) {
                return;
            }

            var networkContext = &device.networkContext.?;
            errdefer networkCallbacks.close(networkContext);

            while (try networkCallbacks.poll(networkContext)) {
                var reader = networkCallbacks.read(networkContext);
                const cmd = try reader.readEnum(Commands, .Big);

                try switch (cmd) {
                    Commands.SET_KEY => handleSetKeyCmd(device),
                    Commands.DELETE_KEY => handleDelKeyCmd(device),
                    Commands.SET_ROW => {
                        const newRow = try reader.readInt(u32, .Big);
                        syncCallbacks.setRow(cb_param, newRow);
                    },
                    Commands.PAUSE => {
                        const flag = try reader.readInt(u8, .Big);
                        syncCallbacks.pause(cb_param, flag);
                    },
                    Commands.SAVE_TRACKS => try syncSaveTracks(device),
                    else => @panic("Unknown command"),
                };
            }

            if (syncCallbacks.isPlaying(cb_param) and device.row != row) {
                var writer = networkCallbacks.write(networkContext);
                try writer.writeByte(@enumToInt(Commands.SET_ROW));
                try writer.writeIntBig(u32, row);
                device.row = row;
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

            if (device.networkContext) |_| {
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
            const trackPath = try syncTrackPath(d.allocator, d.base, t.name);
            defer d.allocator.free(trackPath);

            const context = try ioCallbacks.open(d.allocator, trackPath);
            defer ioCallbacks.close(context);

            var reader = ioCallbacks.read(context);

            var keyCount = try reader.readIntBig(u32);
            t.keys = try std.ArrayList(TrackKey).initCapacity(d.allocator, keyCount);

            for (0..keyCount) |idx| {
                var key = TrackKey{
                    .row = try reader.readIntBig(u32),
                    .value = @bitCast(f32, try reader.readIntBig(u32)),
                    .type = @intToEnum(KeyType, try reader.readIntBig(u8)),
                };
                t.keys.insertAssumeCapacity(idx, key);
            }
        }

        pub fn syncSaveTracks(d: *const Self) !void {
            for (d.tracks) |track| {
                const path = try syncTrackPath(d.allocator, d.base, track.name);
                defer d.allocator.free(path);

                try saveTrack(track, path);
            }
        }

        fn fetchTrackData(device: *Self, t: *Track) !void {
            if (device.networkContext) |*networkContext| {
                var writer = networkCallbacks.write(networkContext);
                try writer.writeByte(@enumToInt(Commands.GET_TRACK));
                try writer.writeIntBig(u32, @truncate(u32, t.name.len));
                try writer.writeAll(t.name);
            }
        }

        fn handleSetKeyCmd(device: *Self) !void {
            var reader = networkCallbacks.read(&device.networkContext.?);
            var trackIdx = try reader.readIntBig(u32);
            var row = try reader.readIntBig(u32);
            var floatAsInt = try reader.readIntBig(u32);
            var keyType = try reader.readEnum(KeyType, .Big);

            var key: TrackKey = .{
                .row = row,
                .value = @bitCast(f32, floatAsInt),
                .type = keyType,
            };

            if (trackIdx >= device.tracks.len) {
                return error.OutOfRange;
            }

            return device.tracks[trackIdx].setKey(key);
        }

        fn handleDelKeyCmd(device: *Self) !void {
            var reader = networkCallbacks.read(&device.networkContext.?);
            var trackIdx = try reader.readIntBig(u32);
            var row = try reader.readIntBig(u32);

            if (trackIdx >= device.tracks.len) {
                return error.OutOfRange;
            }

            return device.tracks[trackIdx].deleteKey(row);
        }

        pub fn connect(device: *Self, host: []const u8, port: u16) !void {
            if (device.networkContext) |*context| {
                networkCallbacks.close(context);
            }

            var networkContext = try networkCallbacks.connect(device.allocator, host, port);
            errdefer networkCallbacks.close(&networkContext);

            // Handhshake
            const clientGreet: []const u8 = "hello, synctracker!";
            const serverGreet: []const u8 = "hello, demo!";

            var writer = networkCallbacks.write(&networkContext);
            try writer.writeAll(clientGreet);

            var greet: [serverGreet.len]u8 = undefined;
            var reader = networkCallbacks.read(&networkContext);
            _ = try reader.readAll(&greet);

            if (!std.mem.eql(u8, &greet, serverGreet)) {
                return error.InvalidGreeting;
            }

            device.networkContext = networkContext;

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
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |dirpath| {
        try cwd.makePath(dirpath);
    }
}

fn saveTrack(t: *const Track, path: []const u8) !void {
    try createLeadingDirs(path);

    const cwd = std.fs.cwd();
    var file = try cwd.createFile(path, .{});
    defer file.close();
    var writer = file.writer();

    try writer.writeIntBig(u32, @truncate(u32, t.keys.items.len));
    for (t.keys.items) |key| {
        try writer.writeIntBig(u32, key.row);
        try writer.writeIntBig(u32, @bitCast(u32, key.value));
        try writer.writeByte(@enumToInt(key.type));
    }
}

pub const KeyType = enum(u8) {
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

    name: []const u8,
    keys: Keys,

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
        const keys = track.keys.items;
        // If we have no keys at all, return a constant 0
        if (keys.len == 0) {
            return 0.0;
        }

        var irow = @floatToInt(u32, row);
        if (keys[0].row > irow) {
            return 0.0;
        }

        var result = track.findKey(irow);
        var idx = if (result.found) result.index else result.index - 1;

        // at the edges, return the first/last value
        if (keys[idx..].len < 2) {
            return keys[keys.len - 1].value;
        }

        // interpolate according to key-type
        return switch (keys[idx].type) {
            .Step => keys[idx].value,
            .Linear => keyLinear(keys[idx..][0..2].*, row),
            .Smooth => keySmooth(keys[idx..][0..2].*, row),
            .Ramp => keyRamp(keys[idx..][0..2].*, row),
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
