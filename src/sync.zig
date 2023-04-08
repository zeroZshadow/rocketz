pub const SyncIOCallbacks = struct {
    open: *const fn (filename: []u8, mode: []u8) void,
    read: *const fn (ptr: *anyopaque, size: usize, count: usize, stream: *anyopaque) usize,
    close: *const fn (stream: *anyopaque) u32,
};

pub const SyncCallbacks = struct {
    pause: *const fn (ptr: *anyopaque, flag: i32) void,
    setRow: *const fn (ptr: *anyopaque, row: u32) void,
    isPlaying: *const fn (ptr: *anyopaque) bool,
};
