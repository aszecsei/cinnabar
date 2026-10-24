package render

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
// The tests submit to the null backend, which validates barriers against the layouts it tracks.
// Engine code itself never imports a backend.
import null "cinnabar:core/gpu/null"

// The null backend and the job system are singletons, and the test runner runs tests on several threads.
@(private = "file")
backend_lock: sync.Mutex

@(private = "file")
Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	cache:    Texture_Cache,
}

@(private = "file")
setup :: proc(t: ^testing.T, f: ^Fixture) {
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	testing.expect(t, jobs.init(2))
	testing.expect(t, null.init(nil, {64, 64}))
	f.platform = {
		frame_allocator     = virtual.arena_allocator(&f.arena),
		jobs_run            = jobs.run,
		jobs_wait           = jobs.wait,
		gpu_frame_target    = null.frame_target,
		gpu_submit          = null.submit,
		gpu_create_texture  = null.create_texture,
		gpu_destroy_texture = null.destroy_texture,
	}
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	cache_destroy(&f.cache, &f.platform)
	null.shutdown()
	jobs.shutdown()
	virtual.arena_destroy(&f.arena)
}

@(private = "file")
nothing :: proc(ctx: ^Pass_Context) {}

@(private = "file")
SIZE :: [2]u32{64, 64}

@(private = "file")
Recorded :: struct {
	buffers:  [dynamic]gpu.Buffer_Barrier,
	textures: [dynamic]gpu.Texture_Barrier,
	markers:  [dynamic]string,
}

@(private = "file")
inspect :: proc(cbs: []gpu.Command_Buffer, allocator := context.allocator) -> (r: Recorded) {
	r.buffers = make([dynamic]gpu.Buffer_Barrier, allocator)
	r.textures = make([dynamic]gpu.Texture_Barrier, allocator)
	r.markers = make([dynamic]string, allocator)
	for cb in cbs {
		it := gpu.packet_iterator(cb)
		for p in gpu.next_packet(&it) {
			#partial switch p.kind {
			case .Barriers:
				buffers, textures := gpu.barrier_data(p)
				append(&r.buffers, ..buffers)
				append(&r.textures, ..textures)
			case .Begin_Marker:
				append(&r.markers, gpu.marker_label(p))
			}
		}
	}
	return
}

@(private = "file")
Transition :: struct {
	texture: gpu.Texture,
	before:  gpu.Texture_Layout,
	after:   gpu.Texture_Layout,
}

@(private = "file")
expect_transitions :: proc(t: ^testing.T, got: []gpu.Texture_Barrier, want: []Transition, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc = loc)
	for b, i in got[:min(len(got), len(want))] {
		testing.expectf(
			t,
			Transition{b.texture, b.layout_before, b.layout_after} == want[i],
			"barrier %d: got %v %v -> %v, want %v",
			i,
			b.texture,
			b.layout_before,
			b.layout_after,
			want[i],
			loc = loc,
		)
	}
}

@(test)
multi_pass_barriers :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	scene := create_texture(&g, {size = SIZE, format = .RGBA16_Float, label = "scene"})
	scene_depth := create_texture(&g, {size = SIZE, format = .D32_Float, label = "depth"})
	post := create_texture(&g, {size = SIZE, format = .RGBA16_Float, label = "post"})

	p := add_render_pass(&g, "scene", nothing)
	color(&g, p, scene, .Clear)
	depth(&g, p, scene_depth, .Clear, store = .Discard)
	p = add_compute_pass(&g, "post", nothing)
	read(&g, p, scene)
	write(&g, p, post)
	p = add_render_pass(&g, "composite", nothing)
	read(&g, p, post)
	color(&g, p, target, .Discard)

	subs, ok := record(&g)
	cb := all_buffers(subs)
	testing.expect(t, ok)
	r := inspect(cb, f.platform.frame_allocator)
	s, d, o := gpu_texture(&g, scene), gpu_texture(&g, scene_depth), gpu_texture(&g, post)
	expect_transitions(
		t,
		r.textures[:],
		{
			{s, .Undefined, .Render_Target},
			{d, .Undefined, .Depth_Stencil_Write},
			{s, .Render_Target, .Shader_Resource},
			{o, .Undefined, .Unordered_Access},
			{o, .Unordered_Access, .Shader_Resource},
		},
	)
	if len(r.textures) == 5 {
		testing.expect_value(t, r.textures[2].sync_before, gpu.Syncs{.Render_Target})
		testing.expect_value(t, r.textures[2].sync_after, gpu.Syncs{.Compute_Shading})
		testing.expect_value(t, r.textures[4].sync_after, gpu.Syncs{.Vertex_Shading, .Pixel_Shading})
	}
	testing.expect_value(t, len(r.markers), 3)
	for entry in f.cache.entries {
		switch entry.texture {
		case s:
			testing.expect_value(t, entry.desc.usage, gpu.Texture_Usages{.Render_Target, .Sampled})
		case o:
			testing.expect_value(t, entry.desc.usage, gpu.Texture_Usages{.Storage, .Sampled})
		}
	}
	testing.expect(t, null.submit(cb))
	null.end_frame()
}

@(test)
unused_passes_are_culled :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	unused := create_texture(&g, {size = SIZE, format = .RGBA8_Unorm, label = "unused"})

	p := add_render_pass(&g, "unread", nothing)
	color(&g, p, unused, .Clear)
	p = add_render_pass(&g, "overwritten", nothing)
	color(&g, p, target, .Clear)
	p = add_render_pass(&g, "final", nothing)
	color(&g, p, target, .Clear)
	p = add_compute_pass(&g, "kept", nothing)
	keep_pass(&g, p)

	subs, ok := record(&g)
	cb := all_buffers(subs)
	testing.expect(t, ok)
	r := inspect(cb, f.platform.frame_allocator)
	testing.expect_value(t, len(r.markers), 2)
	if len(r.markers) == 2 {
		testing.expect_value(t, r.markers[0], "final")
		testing.expect_value(t, r.markers[1], "kept")
	}
	testing.expect_value(t, gpu_texture(&g, unused), gpu.Texture{})
	testing.expect_value(t, len(r.textures), 0)
	testing.expect(t, null.submit(cb))
}

@(test)
imported_textures_return_to_resting_layout :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	field := null.create_texture({size = SIZE, format = .RGBA16_Float, usage = {.Sampled, .Storage}, label = "field"}, nil)
	defer null.destroy_texture(field)

	// The second frame checks that the first one left the texture in its resting layout.
	for _ in 0 ..< 2 {
		g := begin(&f.platform, &f.cache)
		target := import_texture(&g, null.frame_target(), .Color)
		imported := import_texture(&g, field, .Storage)
		p := add_compute_pass(&g, "simulate", nothing)
		write(&g, p, imported)
		p = add_render_pass(&g, "draw", nothing)
		read(&g, p, imported)
		color(&g, p, target, .Clear)

		subs, ok := record(&g)
		cb := all_buffers(subs)
		testing.expect(t, ok)
		r := inspect(cb, f.platform.frame_allocator)
		expect_transitions(t, r.textures[:], {{field, .Unordered_Access, .Shader_Resource}, {field, .Shader_Resource, .Unordered_Access}})
		testing.expect(t, null.submit(cb))
		null.end_frame()
		virtual.arena_free_all(&f.arena)
	}
}

@(test)
reads_merge_without_barriers :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	checker := null.create_texture({size = SIZE, format = .RGBA8_Unorm, usage = {.Sampled}}, nil)
	defer null.destroy_texture(checker)
	mesh := null.create_buffer({size = 64, usage = {.Index, .Storage}}, nil)
	defer null.destroy_buffer(mesh)

	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	sampled := import_texture(&g, checker, .Sampled)
	buffer := import_buffer(&g, mesh)

	p := add_compute_pass(&g, "generate", nothing)
	read(&g, p, sampled)
	write(&g, p, buffer)
	p = add_render_pass(&g, "draw", nothing)
	read(&g, p, sampled)
	index_buffer(&g, p, buffer)
	read(&g, p, buffer)
	color(&g, p, target, .Clear)

	subs, ok := record(&g)
	cb := all_buffers(subs)
	testing.expect(t, ok)
	r := inspect(cb, f.platform.frame_allocator)
	testing.expect_value(t, len(r.textures), 0)
	testing.expect_value(t, len(r.buffers), 1)
	if len(r.buffers) == 1 {
		b := r.buffers[0]
		testing.expect_value(t, b.access_before, gpu.Accesses{.Unordered_Access})
		testing.expect_value(t, b.access_after, gpu.Accesses{.Index_Buffer, .Shader_Resource})
		testing.expect_value(t, b.sync_after, gpu.Syncs{.Index_Input, .Vertex_Shading, .Pixel_Shading})
	}
	testing.expect(t, null.submit(cb))
}

@(test)
sampling_an_unwritten_texture_fails :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	empty := create_texture(&g, {size = SIZE, format = .RGBA8_Unorm})
	p := add_render_pass(&g, "draw", nothing)
	read(&g, p, empty)
	color(&g, p, target, .Clear)

	// The test runner fails a test that logs an error, and this error is expected.
	context.logger = log.nil_logger()
	_, ok := record(&g)
	testing.expect(t, !ok)
}

@(test)
cache_reuses_and_evicts :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	desc := gpu.Texture_Desc {
		size   = SIZE,
		format = .RGBA8_Unorm,
		usage  = {.Render_Target},
		label  = "cached",
	}
	cache_begin_frame(&f.cache, &f.platform)
	a := cache_acquire(&f.cache, &f.platform, desc)
	b := cache_acquire(&f.cache, &f.platform, desc)
	testing.expect(t, a != {} && b != {} && a != b, "one frame got the same texture twice")

	cache_begin_frame(&f.cache, &f.platform)
	testing.expect_value(t, cache_acquire(&f.cache, &f.platform, desc), a)
	relabeled := desc
	relabeled.label = "other"
	testing.expect(t, cache_acquire(&f.cache, &f.platform, relabeled) != b, "a different label reused a texture")

	for _ in 0 ..< CACHE_LIFETIME + 1 {
		cache_begin_frame(&f.cache, &f.platform)
	}
	for entry in f.cache.entries {
		testing.expect_value(t, entry.texture, gpu.Texture{})
	}
}

@(private = "file")
mark_ran :: proc(ctx: ^Pass_Context) {
	sync.atomic_store((^bool)(ctx.data), true)
}

@(test)
parallel_passes_keep_their_order :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	COUNT :: 20
	names: [COUNT]string
	ran: [COUNT]bool
	g := begin(&f.platform, &f.cache)
	for i in 0 ..< COUNT {
		names[i] = fmt.aprintf("pass %d", i, allocator = f.platform.frame_allocator)
		keep_pass(&g, add_compute_pass(&g, names[i], mark_ran, &ran[i]))
	}
	subs, ok := record(&g)
	cbs := all_buffers(subs)
	testing.expect(t, ok)
	testing.expect_value(t, len(cbs), COUNT)
	r := inspect(cbs, f.platform.frame_allocator)
	testing.expect_value(t, len(r.markers), COUNT)
	for i in 0 ..< min(COUNT, len(r.markers)) {
		testing.expect_value(t, r.markers[i], names[i])
		testing.expect(t, ran[i])
	}
	testing.expect(t, null.submit(cbs))
}

@(private = "file")
mark_piece :: proc(ctx: ^Pass_Context) {
	ran := (^[4]bool)(ctx.data)
	assert(ctx.piece_count == len(ran))
	sync.atomic_store(&ran[ctx.piece], true)
}

@(test)
split_passes_form_a_chain :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	ran: [4]bool
	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	scene_depth := create_texture(&g, {size = SIZE, format = .D32_Float, label = "depth"})
	p := add_render_pass(&g, "scene", mark_piece, &ran, pieces = len(ran))
	color(&g, p, target, .Clear)
	depth(&g, p, scene_depth, .Clear, store = .Discard)

	subs, ok := record(&g)
	cbs := all_buffers(subs)
	testing.expect(t, ok)
	testing.expect_value(t, len(cbs), len(ran))
	for cb, i in cbs[:min(len(cbs), len(ran))] {
		testing.expect(t, ran[i])
		r := inspect({cb}, f.platform.frame_allocator)
		// The depth texture's transition from Undefined is in the first piece only.
		testing.expect_value(t, len(r.textures), i == 0 ? 1 : 0)
		it := gpu.packet_iterator(cb)
		for packet in gpu.next_packet(&it) {
			if packet.kind != .Begin_Pass {
				continue
			}
			pass := gpu.payload(packet, gpu.Begin_Pass)
			want_flags: gpu.Pass_Flags
			if i > 0 {
				want_flags += {.Resuming}
			}
			if i < len(ran) - 1 {
				want_flags += {.Suspending}
			}
			testing.expect_value(t, pass.flags, want_flags)
			testing.expect_value(t, pass.colors[0].load, i == 0 ? gpu.Load_Op.Clear : .Load)
			testing.expect_value(t, pass.depth.store, i == len(ran) - 1 ? gpu.Store_Op.Discard : .Store)
		}
	}
	testing.expect(t, null.submit(cbs))

	// The test runner fails a test that logs an error, and these rejections are expected.
	context.logger = log.nil_logger()
	testing.expect(t, !null.submit(cbs[1:]), "a submission started with a resumed piece")
	testing.expect(t, !null.submit(cbs[:len(cbs) - 1]), "a submission ended with a suspended piece")
}

@(private = "file")
all_buffers :: proc(subs: []Submission) -> []gpu.Command_Buffer {
	if len(subs) == 0 {
		return nil
	}
	result := make([dynamic]gpu.Command_Buffer, subs[0].buffers.allocator)
	for s in subs {
		append(&result, ..s.buffers[:])
	}
	return result[:]
}

@(test)
async_compute_waits_across_queues :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f: Fixture
	setup(t, &f)
	defer teardown(&f)

	args := null.create_buffer({size = 256, usage = {.Storage, .Indirect}}, nil)
	defer null.destroy_buffer(args)

	g := begin(&f.platform, &f.cache)
	target := import_texture(&g, null.frame_target(), .Color)
	arguments := import_buffer(&g, args)
	field := create_texture(&g, {size = SIZE, format = .RGBA16_Float, label = "field"})

	p := add_compute_pass(&g, "clear", nothing, queue = .Compute)
	write(&g, p, arguments)
	p = add_compute_pass(&g, "cull", nothing, queue = .Compute)
	write(&g, p, arguments)
	write(&g, p, field)
	p = add_render_pass(&g, "draw", nothing)
	indirect_buffer(&g, p, arguments)
	read(&g, p, field)
	color(&g, p, target, .Clear)

	subs, ok := record(&g)
	testing.expect(t, ok)
	testing.expect_value(t, len(subs), 2)
	if len(subs) != 2 {
		return
	}
	testing.expect_value(t, subs[0].queue, gpu.Queue.Compute)
	testing.expect_value(t, len(subs[0].buffers), 2)
	testing.expect_value(t, subs[1].queue, gpu.Queue.Graphics)
	testing.expect_value(t, subs[1].wait_for, gpu.Queues{.Compute})

	compute := inspect(subs[0].buffers[:], f.platform.frame_allocator)
	// The two writes on the compute queue need a barrier between them, with compute stages only.
	testing.expect_value(t, len(compute.buffers), 1)
	if len(compute.buffers) == 1 {
		testing.expect_value(t, compute.buffers[0].sync_before, gpu.Syncs{.Compute_Shading})
		testing.expect_value(t, compute.buffers[0].access_after, gpu.Accesses{.Unordered_Access})
	}
	expect_transitions(t, compute.textures[:], {{gpu_texture(&g, field), .Undefined, .Unordered_Access}})

	// The wait orders the queues, so the graphics side changes only the texture's layout.
	graphics := inspect(subs[1].buffers[:], f.platform.frame_allocator)
	testing.expect_value(t, len(graphics.buffers), 0)
	expect_transitions(t, graphics.textures[:], {{gpu_texture(&g, field), .Unordered_Access, .Shader_Resource}})
	if len(graphics.textures) == 1 {
		testing.expect_value(t, graphics.textures[0].access_before, gpu.Accesses{})
	}

	for s in subs {
		testing.expect(t, null.submit(s.buffers[:], s.queue, s.wait_for))
	}
}
