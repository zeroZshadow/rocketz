pub const SyncIOCallbacks = struct {
    open: *const fn (filename: []u8, mode: []u8) void,
    read: *const fn (ptr: [*]void, size: usize, count: usize, stream: [*]void) usize,
    close: *const fn (stream: [*]void) u32,
};

pub const SyncCallbacks = struct {
    pause: *const fn (ptr: [*]void, flag: i32) void,
    setRow: *const fn (ptr: [*]void, row: u32) void,
    isPlaying: *const fn (ptr: [*]void) bool,
};
