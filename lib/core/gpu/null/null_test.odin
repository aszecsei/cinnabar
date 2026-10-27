package gpu_null

import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core/gpu"
import "cinnabar:core/profile"

// The backend is a singleton, and the test runner runs tests on several threads.
@(private = "file")
backend_lock: sync.Mutex

@(test)
submit_accepts_valid_frame :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	shader := []byte{0}
	pipeline := create_graphics_pipeline({vertex = shader, pixel = shader, colors = {{format = gpu.FRAME_TARGET_FORMAT}}})
	testing.expect(t, pipeline != {})

	cb := gpu.command_buffer(virtual.arena_allocator(&arena))
	gpu.cmd_begin_pass(&cb, {{texture = frame_target(), load = .Clear}})
	gpu.cmd_set_pipeline(&cb, pipeline)
	gpu.cmd_draw(&cb, 3)
	gpu.cmd_end_pass(&cb)
	testing.expect(t, submit({cb}))
}

@(test)
submit_rejects_unknown_texture :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	valid := gpu.command_buffer(virtual.arena_allocator(&arena))
	gpu.cmd_begin_pass(&valid, {{texture = frame_target()}})
	gpu.cmd_end_pass(&valid)

	invalid := gpu.command_buffer(virtual.arena_allocator(&arena))
	gpu.cmd_begin_pass(&invalid, {{texture = {index = 7, generation = 1}}})
	gpu.cmd_end_pass(&invalid)

	// The test runner fails a test that logs an error, and this rejection is expected.
	context.logger = log.nil_logger()
	testing.expect(t, !submit({valid, invalid}))
}

@(test)
destroyed_handles_are_invalid :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)

	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	buffer := create_buffer({size = 64}, nil)
	testing.expect(t, buffer != {})
	destroy_buffer(buffer)
	reused := create_buffer({size = 64}, nil)
	testing.expect_value(t, reused.index, buffer.index)

	cb := gpu.command_buffer(virtual.arena_allocator(&arena))
	gpu.cmd_set_pass_constants(&cb, {buffer = buffer})
	context.logger = log.nil_logger()
	testing.expect(t, !submit({cb}))
}

@(test)
create_rejects_bad_descs :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	context.logger = log.nil_logger()
	testing.expect_value(t, create_buffer({size = 6}, nil), gpu.Buffer{})
	testing.expect_value(t, create_buffer({size = 4}, {1, 2, 3, 4, 5}), gpu.Buffer{})
	testing.expect_value(t, create_texture({size = {4, 4}, format = .D32_Float, usage = {.Sampled}}, nil), gpu.Texture{})
	testing.expect_value(t, create_texture({size = {4, 4}, format = .RGBA8_Unorm, usage = {.Sampled}}, {1, 2, 3}), gpu.Texture{})
	testing.expect_value(t, create_texture({size = {4, 4}, format = .RGBA8_Unorm, mip_count = 4, usage = {.Sampled}}, nil), gpu.Texture{})
	testing.expect_value(t, create_graphics_pipeline({vertex = {0}, colors = {{format = .RGBA8_Unorm}}}), gpu.Pipeline{})
	testing.expect_value(t, create_graphics_pipeline({vertex = {0}, pixel = {0}, colors = {{format = .D32_Float}}}), gpu.Pipeline{})
	testing.expect_value(t, create_compute_pipeline({}), gpu.Pipeline{})

	testing.expect(t, create_texture({size = {4, 4}, format = .RGBA8_Unorm, mip_count = 3, usage = {.Sampled}}, nil) != {})
	testing.expect(t, create_graphics_pipeline({vertex = {0}, depth_format = .D32_Float}) != {})
}

@(test)
upload_ring_resets_each_frame :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	a, a_ok := upload(3, 1)
	b, b_ok := upload(16, gpu.PASS_CONSTANTS_ALIGN)
	testing.expect(t, a_ok && b_ok)
	testing.expect_value(t, len(a.data), 3)
	testing.expect_value(t, b.offset, gpu.PASS_CONSTANTS_ALIGN)
	_, full_ok := upload(UPLOAD_RING_SIZE, 1)
	testing.expect(t, !full_ok)

	begin_frame({1280, 720})
	c, _ := upload(4, 4)
	testing.expect_value(t, c.offset, 0)
}

@(test)
destroy_scope_keeps_other_scopes :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	game_buffer := create_buffer({size = 64}, nil)
	game_pipeline := create_compute_pipeline({compute = {0}})
	level_texture := create_texture({size = {4, 4}, format = .RGBA8_Unorm, usage = {.Sampled}, scope = .Level}, nil)
	level_sampler := create_sampler({scope = .Level})

	testing.expect_value(t, destroy_scope(.Game), 2)
	_, buffer_ok := RESOURCES.buffer(game_buffer)
	_, pipeline_ok := RESOURCES.pipeline(game_pipeline)
	_, texture_ok := RESOURCES.texture(level_texture)
	_, target_ok := RESOURCES.texture(frame_target())
	testing.expect(t, !buffer_ok && !pipeline_ok, "a Game resource survived")
	testing.expect(t, texture_ok && target_ok, "a resource outside the Game scope was destroyed")

	testing.expect_value(t, destroy_scope(.Level), 2)
	testing.expect_value(t, destroy_scope(.Level), 0)
	_ = level_sampler
}

@(test)
updates_keep_the_attachment_formats :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	shader := []byte{0}
	desc := gpu.Graphics_Pipeline_Desc {
		vertex = shader,
		pixel  = shader,
		colors = {{format = gpu.FRAME_TARGET_FORMAT}},
	}
	pipeline := create_graphics_pipeline(desc)
	compute := create_compute_pipeline({compute = shader})
	testing.expect(t, update_graphics_pipeline(pipeline, desc))
	testing.expect(t, update_compute_pipeline(compute, {compute = shader}))

	context.logger = log.nil_logger()
	other := desc
	other.colors = {{format = .RGBA16_Float}}
	testing.expect(t, !update_graphics_pipeline(pipeline, other), "an update changed the attachment formats")
	testing.expect(t, !update_compute_pipeline(pipeline, {compute = shader}), "an update changed the pipeline kind")
	destroy_pipeline(compute)
	testing.expect(t, !update_compute_pipeline(compute, {compute = shader}), "an update of a destroyed pipeline")
}

@(test)
mesh_updates_keep_the_kind :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	shader := []byte{0}
	mesh := gpu.Graphics_Pipeline_Desc {
		mesh   = shader,
		pixel  = shader,
		colors = {{format = gpu.FRAME_TARGET_FORMAT}},
	}
	pipeline := create_graphics_pipeline(mesh)
	testing.expect(t, pipeline != {})
	testing.expect(t, update_graphics_pipeline(pipeline, mesh))

	context.logger = log.nil_logger()
	vertex := mesh
	vertex.mesh, vertex.vertex = nil, shader
	testing.expect(t, !update_graphics_pipeline(pipeline, vertex), "an update turned a mesh pipeline into a vertex pipeline")
}

@(test)
ray_tracing_resources :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	desc := gpu.Ray_Tracing_Pipeline_Desc {
		library          = {0},
		ray_generation   = "ray_generation",
		max_payload_size = 4,
	}
	pipeline := create_ray_tracing_pipeline(desc)
	testing.expect(t, pipeline != {})
	testing.expect(t, update_ray_tracing_pipeline(pipeline, desc))

	vertices := create_buffer({size = 96}, nil)
	blas := create_accel({kind = .Bottom, geometries = {{vertices = vertices, vertex_stride = 32, vertex_count = 3}}})
	tlas := create_accel({kind = .Top, max_instances = 4})
	testing.expect(t, blas != {} && tlas != {})
	testing.expect(t, accel_reference(blas) != accel_reference(tlas))

	context.logger = log.nil_logger()
	testing.expect(t, !update_compute_pipeline(pipeline, {compute = {0}}), "an update turned a ray tracing pipeline into a compute pipeline")
	testing.expect_value(t, create_accel({kind = .Bottom, geometries = {{vertices = {index = 99, generation = 1}, vertex_stride = 32, vertex_count = 3}}}), gpu.Accel_Struct{})

	// Destroying a geometry buffer leaves the bottom-level structure unbuildable.
	cb := gpu.command_buffer(context.temp_allocator)
	gpu.cmd_build_accel(&cb, blas)
	testing.expect(t, submit({cb}))
	destroy_buffer(vertices)
	testing.expect(t, !submit({cb}))
	testing.expect_value(t, destroy_scope(.Game), 3)
}

@(test)
streams_are_checked :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	texture := create_texture({size = {4, 4}, format = .RGBA8_Unorm, usage = {.Sampled, .Streamed}}, nil)
	buffer := create_buffer({size = 64}, nil)
	data := make([]byte, 64, context.temp_allocator)
	transfer := stream_texture(texture, data)
	testing.expect(t, transfer != 0 && transfer_done(transfer))
	testing.expect(t, stream_buffer(buffer, 0, data) != 0)

	context.logger = log.nil_logger()
	testing.expect_value(t, stream_texture(texture, data), gpu.Transfer(0))
	testing.expect_value(t, stream_buffer(buffer, 4, data), gpu.Transfer(0))
	testing.expect_value(t, stream_buffer({index = 99, generation = 1}, 0, data[:4]), gpu.Transfer(0))
}

@(test)
readback_buffers_are_readable :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 64}))
	defer shutdown()

	readback := create_buffer({size = 16, usage = {.Readback}}, nil)
	data, ok := read_buffer(readback)
	testing.expect(t, ok && len(data) == 16)
	plain := create_buffer({size = 16}, nil)
	_, ok = read_buffer(plain)
	testing.expect(t, !ok)
	destroy_buffer(readback)
	_, ok = read_buffer(readback)
	testing.expect(t, !ok)
}

when profile.ENABLED {
	@(test)
	timed_markers_reach_the_profiler_late :: proc(t: ^testing.T) {
		arena: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&arena) == nil)
		defer virtual.arena_destroy(&arena)

		sync.guard(&backend_lock)
		testing.expect(t, profile.init())
		defer profile.shutdown()
		testing.expect(t, init(nil, {64, 64}))
		defer shutdown()

		profile.frame_boundary()
		begin_frame({64, 64})
		frame := profile.current_frame()
		cb := gpu.command_buffer(virtual.arena_allocator(&arena))
		gpu.cmd_begin_marker(&cb, "pass", timed = true)
		gpu.cmd_begin_marker(&cb, "untimed")
		gpu.cmd_begin_marker(&cb, "inner", timed = true)
		gpu.cmd_end_marker(&cb)
		gpu.cmd_end_marker(&cb)
		gpu.cmd_end_marker(&cb)
		testing.expect(t, submit({cb}, .Compute))
		end_frame()

		for _ in 0 ..< FRAMES_IN_FLIGHT - 1 {
			profile.frame_boundary()
			begin_frame({64, 64})
			end_frame()
			_, ready := profile.frame_state(frame)
			testing.expect(t, !ready)
		}
		profile.frame_boundary()
		begin_frame({64, 64})
		_, ready := profile.frame_state(frame)
		testing.expect(t, ready)

		c, _ := profile.capture(frame, context.temp_allocator)
		testing.expect_value(t, len(c.gpu), 2)
		if len(c.gpu) == 2 {
			inner, pass := c.gpu[0], c.gpu[1]
			testing.expect_value(t, inner.name, profile.intern("inner", .Render))
			testing.expect_value(t, inner.depth, 1)
			testing.expect_value(t, pass.depth, 0)
			testing.expect_value(t, pass.queue, u8(gpu.Queue.Compute))
			testing.expect(t, pass.start < inner.start && inner.end < pass.end)
		}
		testing.expect(t, c.frame.gpu_end > c.frame.gpu_begin)
	}
}

@(test)
frame_captures_are_ready_after_end_frame :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	begin_frame({1280, 720})
	testing.expect(t, request_frame_capture())
	// A second request in the frame is the same capture.
	testing.expect(t, request_frame_capture())
	_, ok := poll_frame_capture()
	testing.expect(t, !ok)
	end_frame()

	capture, ready := poll_frame_capture()
	testing.expect(t, ready)
	testing.expect_value(t, capture.size, [2]u32{1280, 720})
	testing.expect_value(t, capture.format, gpu.FRAME_TARGET_FORMAT)
	testing.expect(t, capture.row_pitch >= 4 * 1280 && capture.row_pitch % 256 == 0)
	testing.expect_value(t, len(capture.pixels), int(capture.row_pitch) * 720)
	_, again := poll_frame_capture()
	testing.expect(t, !again)

	// A held slot stays held until it is released; the others are free.
	for _ in 1 ..< CAPTURE_SLOTS {
		begin_frame({1280, 720})
		testing.expect(t, request_frame_capture())
		end_frame()
		held, got := poll_frame_capture()
		testing.expect(t, got)
		release_frame_capture(held)
	}
	release_frame_capture(capture)
	begin_frame({1280, 720})
	testing.expect(t, request_frame_capture())
	end_frame()
	last, got := poll_frame_capture()
	testing.expect(t, got)
	release_frame_capture(last)
}
