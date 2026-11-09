package gpu_null

import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core/gpu"
import "cinnabar:core/profile"
import "cinnabar:core/testlog"

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
	context.logger = testlog.expected_errors()
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
	context.logger = testlog.expected_errors()
	testing.expect(t, !submit({cb}))
}

@(test)
create_rejects_bad_descs :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	context.logger = testlog.expected_errors()
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

// A Storage cube's views write each of its mips. A view has its own write slot and handle, and no view of its own.
@(test)
texture_views_write_a_cubes_mips :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {1280, 720}))
	defer shutdown()

	cube := create_texture({size = {16, 16}, layers = 6, cube = true, format = .RGBA16_Float, mip_count = 5, usage = {.Sampled, .Storage}}, nil)
	testing.expect(t, cube != {})
	views: [5]gpu.Texture
	for &view, mip in views {
		view = create_texture_view({texture = cube, mip = u32(mip)})
		testing.expect(t, view != {} && view != cube)
		testing.expect(t, gpu.write_index(view) != gpu.write_index(cube))
	}
	context.logger = testlog.expected_errors()
	testing.expect_value(t, create_texture_view({texture = cube, mip = 5}), gpu.Texture{})
	testing.expect_value(t, create_texture_view({texture = views[1]}), gpu.Texture{})
	sampled := create_texture({size = {4, 4}, format = .RGBA8_Unorm, usage = {.Sampled}}, nil)
	testing.expect_value(t, create_texture_view({texture = sampled}), gpu.Texture{})

	destroy_texture(views[2])
	testing.expect_value(t, create_texture_view({texture = views[2]}), gpu.Texture{})
	destroy_texture(cube)
	testing.expect_value(t, create_texture_view({texture = cube}), gpu.Texture{})

	// A cube array's views write a mip of every cube.
	array := create_texture({size = {16, 16}, layers = 12, cube = true, format = .RG11B10_Float, mip_count = 3, usage = {.Sampled, .Storage}}, nil)
	testing.expect(t, array != {})
	array_view := create_texture_view({texture = array, mip = 2})
	testing.expect(t, array_view != {})
	destroy_texture(array_view)
	destroy_texture(array)
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

	context.logger = testlog.expected_errors()
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

	context.logger = testlog.expected_errors()
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

	context.logger = testlog.expected_errors()
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

	context.logger = testlog.expected_errors()
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
	testing.expect(t, request_frame_capture(1))
	// One a frame: the caller asks again next frame.
	testing.expect(t, !request_frame_capture(2))
	_, ok := poll_frame_capture()
	testing.expect(t, !ok)
	end_frame()

	capture, ready := poll_frame_capture()
	testing.expect(t, ready)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.source, gpu.Capture_Source.Frame)
	testing.expect_value(t, capture.ticket, 1)
	testing.expect_value(t, capture.size, [2]u32{1280, 720})
	testing.expect_value(t, capture.format, gpu.FRAME_TARGET_FORMAT)
	testing.expect(t, capture.row_pitch >= 4 * 1280 && capture.row_pitch % 256 == 0)
	testing.expect_value(t, len(capture.pixels), int(capture.row_pitch) * 720)
	_, again := poll_frame_capture()
	testing.expect(t, !again)

	// A held slot stays held until it is released; the others are free.
	for i in 1 ..< CAPTURE_SLOTS {
		begin_frame({1280, 720})
		testing.expect(t, request_frame_capture(u32(10 + i)))
		end_frame()
		held, got := poll_frame_capture()
		testing.expect(t, got)
		testing.expect_value(t, held.ticket, u32(10 + i))
		release_frame_capture(held)
	}
	release_frame_capture(capture)
	begin_frame({1280, 720})
	testing.expect(t, request_frame_capture(3))
	end_frame()
	last, got := poll_frame_capture()
	testing.expect(t, got)
	testing.expect_value(t, last.ticket, 3)
	release_frame_capture(last)
}

@(test)
a_frame_that_draws_nothing_cancels_its_capture :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()

	// The host asks between frames, and the window is minimized before the next one.
	begin_frame({64, 32})
	end_frame()
	testing.expect(t, request_frame_capture(1))
	begin_frame({64, 32})
	end_frame()
	testing.expect(t, request_frame_capture(2))
	begin_frame({0, 0})
	end_frame()
	// The request sees the minimized frame.
	testing.expect(t, !request_frame_capture(99))
	begin_frame({64, 32})
	end_frame()
	testing.expect(t, request_frame_capture(3))
	begin_frame({64, 32})
	end_frame()

	// Each comes back with its own ticket, the cancelled one too.
	want := [3]struct {
		ticket: u32,
		status: gpu.Capture_Status,
	}{{1, .Ready}, {2, .Cancelled}, {3, .Ready}}
	seen: [3]bool
	for _ in 0 ..< 3 {
		capture, ok := poll_frame_capture()
		testing.expect(t, ok)
		for w, i in want {
			if w.ticket == capture.ticket {
				testing.expect(t, !seen[i])
				seen[i] = true
				testing.expect_value(t, capture.status, w.status)
				testing.expect_value(t, capture.source, gpu.Capture_Source.Frame)
				testing.expect_value(t, len(capture.pixels) > 0, w.status == .Ready)
			}
		}
		release_frame_capture(capture)
	}
	testing.expect_value(t, seen, [3]bool{true, true, true})
	_, more := poll_frame_capture()
	testing.expect(t, !more)

	// Every slot is free again: each one can be held at once.
	held: [CAPTURE_SLOTS]gpu.Frame_Capture
	for &h, i in held {
		testing.expect(t, request_frame_capture(u32(100 + i)))
		begin_frame({64, 32})
		end_frame()
		got: bool
		h, got = poll_frame_capture()
		testing.expect(t, got)
	}
	for h in held {
		release_frame_capture(h)
	}
}

@(test)
a_texture_capture_comes_back_with_its_ticket :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()
	texture := create_texture({size = {16, 8}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "thumbnail"}, nil)
	defer destroy_texture(texture)
	testing.expect(t, request_texture_capture(texture, 7))
	// One a frame: the caller asks again next frame.
	testing.expect(t, !request_texture_capture(texture, 8))
	end_frame()

	capture, ok := poll_frame_capture()
	testing.expect(t, ok)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.source, gpu.Capture_Source.Texture)
	testing.expect_value(t, capture.ticket, 7)
	testing.expect_value(t, capture.size, [2]u32{16, 8})
	testing.expect_value(t, capture.mode, gpu.Output_Mode.Sdr)
	testing.expect(t, int(capture.row_pitch) * 8 == len(capture.pixels))
	release_frame_capture(capture)

	// A copy of the frame target says so, and its ticket is the frame request's own.
	begin_frame({64, 32})
	testing.expect(t, request_frame_capture(7))
	end_frame()
	frame, frame_ok := poll_frame_capture()
	testing.expect(t, frame_ok)
	testing.expect_value(t, frame.source, gpu.Capture_Source.Frame)
	testing.expect_value(t, frame.ticket, 7)
	release_frame_capture(frame)
}

@(test)
a_failed_frame_copy_keeps_the_texture_copy :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()
	texture := create_texture({size = {16, 8}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "thumbnail"}, nil)
	defer destroy_texture(texture)

	testing.expect(t, request_frame_capture(1))
	begin_frame({64, 32})
	testing.expect(t, request_texture_capture(texture, 2))
	fail_next_frame_copy()
	end_frame()

	frame_seen, texture_seen := false, false
	for _ in 0 ..< 2 {
		capture, ok := poll_frame_capture()
		testing.expect(t, ok)
		switch capture.source {
		case .Frame:
			frame_seen = true
			testing.expect_value(t, capture.ticket, 1)
			testing.expect_value(t, capture.status, gpu.Capture_Status.Cancelled)
			testing.expect_value(t, len(capture.pixels), 0)
		case .Texture:
			texture_seen = true
			testing.expect_value(t, capture.ticket, 2)
			testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
			testing.expect_value(t, capture.size, [2]u32{16, 8})
		}
		release_frame_capture(capture)
	}
	testing.expect(t, frame_seen && texture_seen)

	// The failure was the one copy's: the next frame copies.
	testing.expect(t, request_frame_capture(3))
	begin_frame({64, 32})
	end_frame()
	next, ok := poll_frame_capture()
	testing.expect(t, ok)
	testing.expect_value(t, next.status, gpu.Capture_Status.Ready)
	release_frame_capture(next)
}

@(test)
a_pipeline_is_ready_once_it_exists_and_failed_without_one :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 64}))
	defer shutdown()
	pipeline := create_compute_pipeline({compute = []byte{1}, label = "test"})
	testing.expect_value(t, pipeline_status(pipeline), gpu.Pipeline_Status.Ready)
	testing.expect(t, pipeline_ready(pipeline))
	destroy_pipeline(pipeline)
	testing.expect_value(t, pipeline_status(pipeline), gpu.Pipeline_Status.Failed)
	testing.expect_value(t, pipeline_status({}), gpu.Pipeline_Status.Failed)
}

// poll_one polls the one capture that a frame finished, and releases it: only its description is left.
@(private = "file")
poll_one :: proc(t: ^testing.T) -> (capture: gpu.Frame_Capture, ok: bool) {
	capture, ok = poll_frame_capture()
	testing.expect(t, ok)
	release_frame_capture(capture)
	capture.pixels = nil
	return
}

@(test)
a_viewports_target_has_its_size_and_a_generation_for_each_size :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()

	begin_frame({64, 32})
	a, ok := viewport_target(2, {40, 20})
	testing.expect(t, ok)
	testing.expect_value(t, a.size, [2]u32{40, 20})
	testing.expect_value(t, a.generation, 0)
	end_frame()

	// A side beyond the largest is clamped, and a new size is a new generation.
	begin_frame({64, 32})
	b, _ := viewport_target(2, {gpu.MAX_VIEWPORT_SIZE + 1, 20})
	testing.expect_value(t, b.size, [2]u32{gpu.MAX_VIEWPORT_SIZE, 20})
	testing.expect_value(t, b.generation, 1)
	testing.expect_value(t, b.texture, a.texture)
	end_frame()

	// Not for a viewport that does not exist, with no size, or in a frame that records nothing.
	begin_frame({64, 32})
	_, bad := viewport_target(gpu.MAX_VIEWPORT_TARGETS, {8, 8})
	testing.expect(t, !bad)
	_, empty := viewport_target(0, {0, 8})
	testing.expect(t, !empty)
	end_frame()
	begin_frame({0, 0})
	_, minimized := viewport_target(0, {8, 8})
	testing.expect(t, !minimized)
	end_frame()

	// Released, it starts again as a new generation.
	release_viewport_target(2)
	begin_frame({64, 32})
	c, again := viewport_target(2, {40, 20})
	testing.expect(t, again)
	testing.expect_value(t, c.generation, 2)
	end_frame()
}

@(test)
a_capture_of_a_viewport_reads_its_target_when_the_frame_drew_it :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()
	testing.expect_value(t, capture_source(), nil)

	// The start: the frame target.
	begin_frame({64, 32})
	end_frame()
	testing.expect(t, request_frame_capture(1))
	begin_frame({64, 32})
	end_frame()
	capture, _ := poll_one(t)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.viewport, nil)
	testing.expect_value(t, capture.size, [2]u32{64, 32})

	// The viewport's target has its own size, and the frame target's mode does not apply to it.
	set_capture_source(1)
	testing.expect_value(t, capture_source(), 1)
	testing.expect(t, request_frame_capture(2))
	begin_frame({64, 32})
	_, drawn := viewport_target(1, {40, 20})
	testing.expect(t, drawn)
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.ticket, 2)
	testing.expect_value(t, capture.source, gpu.Capture_Source.Frame)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.viewport, 1)
	testing.expect_value(t, capture.size, [2]u32{40, 20})
	testing.expect_value(t, capture.format, gpu.FRAME_TARGET_FORMAT)
	testing.expect_value(t, capture.mode, gpu.Output_Mode.Sdr)
}

@(test)
a_capture_of_a_viewport_that_the_frame_did_not_draw_is_cancelled :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()
	begin_frame({64, 32})
	end_frame()

	// A viewport that never opened, one that exists but the frame skipped, and one that is out of range.
	set_capture_source(0)
	testing.expect(t, request_frame_capture(1))
	begin_frame({64, 32})
	end_frame()
	capture, _ := poll_one(t)
	testing.expect_value(t, capture.ticket, 1)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Cancelled)
	testing.expect_value(t, capture.viewport, 0)

	begin_frame({64, 32})
	_, made := viewport_target(0, {16, 8})
	testing.expect(t, made)
	end_frame()
	testing.expect(t, request_frame_capture(2))
	begin_frame({64, 32})
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Cancelled)

	set_capture_source(gpu.MAX_VIEWPORT_TARGETS + 3)
	testing.expect(t, request_frame_capture(3))
	begin_frame({64, 32})
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Cancelled)

	// A closed viewport has no target to copy, though it drew before.
	set_capture_source(0)
	release_viewport_target(0)
	testing.expect(t, request_frame_capture(4))
	begin_frame({64, 32})
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Cancelled)

	// And back to the frame target, which the frame always draws.
	set_capture_source(nil)
	testing.expect(t, request_frame_capture(5))
	begin_frame({64, 32})
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.viewport, nil)
}

@(test)
a_request_keeps_the_source_that_it_was_made_with :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, init(nil, {64, 32}))
	defer shutdown()
	begin_frame({64, 32})
	end_frame()

	// The editor changes the source between the request and its frame: the copy is of the source at the request.
	set_capture_source(3)
	testing.expect(t, request_frame_capture(1))
	set_capture_source(nil)
	begin_frame({64, 32})
	_, drawn := viewport_target(3, {32, 16})
	testing.expect(t, drawn)
	end_frame()
	capture, _ := poll_one(t)
	testing.expect_value(t, capture.viewport, 3)
	testing.expect_value(t, capture.status, gpu.Capture_Status.Ready)
	testing.expect_value(t, capture.size, [2]u32{32, 16})

	// A texture's copy is of its texture, whatever the source.
	set_capture_source(3)
	texture := create_texture({size = {16, 8}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "thumbnail"}, nil)
	defer destroy_texture(texture)
	begin_frame({64, 32})
	testing.expect(t, request_texture_capture(texture, 9))
	end_frame()
	capture, _ = poll_one(t)
	testing.expect_value(t, capture.source, gpu.Capture_Source.Texture)
	testing.expect_value(t, capture.viewport, nil)
	testing.expect_value(t, capture.size, [2]u32{16, 8})
}
