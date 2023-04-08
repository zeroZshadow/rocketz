const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

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

pub const SyncTrack = struct {
    name: []u8,
    keys: std.ArrayList(TrackKey),

    inline fn keyIndexFloor(track: *const SyncTrack, row: u32) u32 {
        var result = track.findKey(row);
        if (result.found) {
            return result.index;
        } else {
            return result.index - 1;
        }
    }

    //#ifndef SYNC_PLAYER
    inline fn isKeyFrame(track: *const SyncTrack, row: u32) bool {
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

    pub fn getValue(track: *const SyncTrack, row: f64) f64 {
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

    pub fn findKey(t: *const SyncTrack, row: u32) struct { index: u32, found: bool } {
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
    pub fn setKey(track: *SyncTrack, key: TrackKey) !void {
        const result = track.findKey(key.row);
        if (!result.found) {
            // no exact hit, we need to allocate a new key
            return try track.keys.insert(result.index, key);
        }

        track.keys.items[result.index] = key;
    }

    pub fn deleteKey(track: *SyncTrack, pos: u32) !void {
        var result = track.findKey(pos);
        assert(result.found);

        _ = track.keys.orderedRemove(result.index);
    }
};
