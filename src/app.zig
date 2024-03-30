const std = @import("std");
const rocket = @import("rocket");
const network = @import("network");
const bass = @import("bass");
const core = @import("mach").core;
const gpu = core.gpu;

const rocketsync = @import("./rocketsync.zig");

pub const App = @This();

pub const RocketDevice = rocketsync.Device;

title_timer: core.Timer,
pipeline: *gpu.RenderPipeline,
bass_stream: u32,
rocket_device: RocketDevice,

fn getRow(stream: u32) f64 {
    const pos = bass.BASS_ChannelGetPosition(stream, bass.BASS_POS_BYTE);
    const time = bass.BASS_ChannelBytes2Seconds(stream, pos);
    return time * rocketsync.row_rate;
}

pub fn init(app: *App) !void {
    try core.init(.{});

    // network
    try network.init();

    // bass
    if (bass.BASS_Init(-1, 44100, 0, null, null) == 0) {
        return error.BassError;
    }

    const stream = bass.BASS_StreamCreateFile(0, "res/tune.ogg", 0, 0, bass.BASS_STREAM_PRESCAN);
    if (stream == 0) {
        const err = bass.BASS_ErrorGetCode();
        switch (err) {
            bass.BASS_ERROR_FILEOPEN => std.debug.print("Failed to open file", .{}),
            else => std.debug.print("BassError: .{}", .{err}),
        }
        @breakpoint();

        return error.BassError;
    }

    const shader_module = core.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Fragment state
    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertex_main",
        },
    };
    const pipeline = core.device.createRenderPipeline(&pipeline_descriptor);

    var device = try RocketDevice.init(core.allocator, "demo/sync");
    device.connect("localhost", 1338) catch |err| {
        switch (err) {
            error.CouldNotConnect => {
                std.log.err("Failed to connect", .{});
                return error.CouldNotConnect;
            },
            else => return err,
        }
    };

    _ = bass.BASS_Start();
    _ = bass.BASS_ChannelPlay(stream, 1);

    app.* = .{
        .title_timer = try core.Timer.start(),
        .pipeline = pipeline,
        .bass_stream = stream,
        .rocket_device = device,
    };
}

pub fn deinit(app: *App) void {
    app.rocket_device.deinit();

    if (app.bass_stream != 0) {
        _ = bass.BASS_StreamFree(app.bass_stream);
    }
    _ = bass.BASS_Free();

    network.deinit();

    defer core.deinit();
    app.pipeline.release();
}

pub fn update(app: *App) !bool {
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => return true,
            else => {},
        }
    }

    const row = getRow(app.bass_stream);
    if (row < 0)
        return false;
    try app.rocket_device.update(
        @intFromFloat(row),
        app.bass_stream,
    );

    _ = bass.BASS_Update(0);

    const clear_r = try app.rocket_device.getTrack("clear_r");
    const red = clear_r.getValue(row);

    const queue = core.queue;
    const back_buffer_view = core.swap_chain.getCurrentTextureView().?;
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = .{ .a = 0, .r = red, .g = 0, .b = 0 },
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });
    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.draw(3, 1, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    core.swap_chain.present();
    back_buffer_view.release();

    // update the window title every second
    if (app.title_timer.read() >= 1.0) {
        app.title_timer.reset();
        try core.printTitle("Triangle [ {d}fps ] [ Input {d}hz ]", .{
            core.frameRate(),
            core.inputRate(),
        });
    }

    return false;
}
