package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import format "cinnabar:engine/asset/format"

// A hit pipeline that the test's ready proc says is still compiling.
@(private = "file")
COMPILING :: gpu.Pipeline {
	index      = 7,
	generation = 1,
}

@(private = "file")
test_ready :: proc(_: ^core.Platform_API, pipeline: gpu.Pipeline) -> bool {
	return pipeline != COMPILING
}

@(test)
hit_entries_map_each_submeshs_primitives_to_its_block_and_bin :: proc(t: ^testing.T) {
	pipelines := make([]Material_Pipeline, 4, context.temp_allocator)
	pipelines[0] = {
		hit = gpu.Pipeline{index = 1, generation = 1},
	}
	pipelines[1] = {
		blend = .Transparent,
		hit = gpu.Pipeline{index = 2, generation = 1},
	}
	pipelines[2] = {
		hit = COMPILING,
	}
	// A blob from before the hit pass has no hit pipeline.
	pipelines[3] = {}
	mesh := Resident_Mesh {
		submesh_count = 4,
	}
	mesh.submeshes[0] = {
		first_index = 0,
		index_count = 30,
	}
	mesh.submeshes[1] = {
		first_index = 30,
		index_count = 6,
	}
	mesh.submeshes[2] = {
		first_index = 36,
		index_count = 3,
	}
	mesh.submeshes[3] = {
		first_index = 39,
		index_count = 9,
	}
	items := []Cull_Item {
		{mesh = 5, submesh = 0, material = 16, bin = 0},
		// An impostor's item stands for the same submesh, and adds no record.
		{mesh = 5, submesh = 0, material = 16, bin = 0, flags = ITEM_IMPOSTOR},
		{mesh = 5, submesh = 1, material = 32, bin = 1},
		{mesh = 5, submesh = 2, material = 48, bin = 2},
		{mesh = 5, submesh = 3, material = 64, bin = 3},
	}
	table := Hit_Table {
		instances = make([]Hit_Instance, 8, context.temp_allocator),
		submeshes = make([dynamic]Hit_Submesh, context.temp_allocator),
	}
	// A slot before, so the records start past its.
	append(&table.submeshes, Hit_Submesh{})
	surfaces := add_hit_entries(&table, 3, &mesh, items, pipelines, test_ready, nil)
	testing.expect(t, surfaces, "the slot has opaque submeshes")
	testing.expect_value(
		t,
		table.instances[3],
		Hit_Instance{mesh = 5, first = 1, count = 4, flags = HIT_INSTANCE_TRANSLUCENT},
	)
	// Its instance is not opaque, so the hits' shadow rays can pass through its translucent submesh.
	testing.expect_value(
		t,
		hit_instance_flags(table.instances[3]),
		gpu.Accel_Instance_Flags{.Force_Non_Opaque},
	)
	testing.expect_value(
		t,
		table.submeshes[1],
		Hit_Submesh{first_primitive = 0, primitive_count = 10, block = 16, bin = 1},
	)
	testing.expect_value(
		t,
		table.submeshes[2],
		Hit_Submesh{first_primitive = 10, primitive_count = 2, block = 32, bin = HIT_TRANSLUCENT},
	)
	testing.expect_value(
		t,
		table.submeshes[3],
		Hit_Submesh{first_primitive = 12, primitive_count = 1, block = 48, bin = 0},
	)
	testing.expect_value(
		t,
		table.submeshes[4],
		Hit_Submesh{first_primitive = 13, primitive_count = 3, block = 64, bin = 0},
	)
	testing.expect(
		t,
		table.used[0] && table.used[1] && !table.used[2] && !table.used[3] && !table.used[4],
	)

	// A slot of transparent submeshes only has no surface for rays to shade.
	glass := Resident_Mesh {
		submesh_count = 1,
	}
	glass.submeshes[0] = {
		first_index = 0,
		index_count = 3,
	}
	testing.expect(
		t,
		!add_hit_entries(&table, 4, &glass, {{mesh = 6, bin = 1}}, pipelines, test_ready, nil),
	)
	testing.expect_value(
		t,
		table.instances[4],
		Hit_Instance{mesh = 6, first = 5, count = 1, flags = HIT_INSTANCE_TRANSLUCENT},
	)

	// A slot of opaque submeshes only is opaque, so the hardware commits its hits at once.
	wall := Resident_Mesh {
		submesh_count = 1,
	}
	wall.submeshes[0] = {
		first_index = 0,
		index_count = 3,
	}
	testing.expect(
		t,
		add_hit_entries(&table, 5, &wall, {{mesh = 7, bin = 0}}, pipelines, test_ready, nil),
	)
	testing.expect_value(t, table.instances[5].flags, 0)
	testing.expect_value(
		t,
		hit_instance_flags(table.instances[5]),
		gpu.Accel_Instance_Flags{.Force_Opaque},
	)
}

// hit_blob is an opaque material blob whose variants are fake bytecode, with the hit pass's when hit.
@(private = "file")
hit_blob :: proc(hit: bool, blend := format.Material_Blend.Opaque) -> []byte {
	code := []byte{1}
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		append(
			&variants,
			format.Material_Variant_Entry{0, pass, .Vertex, code},
			format.Material_Variant_Entry{0, pass, .Pixel, code},
		)
	}
	if hit {
		append(&variants, format.Material_Variant_Entry{0, .Hit, .Compute, code})
	}
	contents := format.Material_Contents {
		blend       = blend,
		block       = make([]byte, 16, context.temp_allocator),
		variants    = variants[:],
		source_path = "test.material",
	}
	return format.material_write(contents, context.temp_allocator)
}

@(test)
a_material_has_a_hit_pipeline_only_with_ray_query :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		gpu_create_graphics_pipeline = null.create_graphics_pipeline,
		gpu_update_graphics_pipeline = null.update_graphics_pipeline,
		gpu_create_compute_pipeline  = null.create_compute_pipeline,
		gpu_update_compute_pipeline  = null.update_compute_pipeline,
		gpu_destroy_pipeline         = null.destroy_pipeline,
		gpu_create_sampler           = null.create_sampler,
		gpu_destroy_sampler          = null.destroy_sampler,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	for c in ([]struct {
			ray_query: bool,
			hit:       bool,
			expected:  bool,
		}{{false, true, false}, {true, false, false}, {true, true, true}}) {
		r.caps.ray_query = c.ray_query
		data := hit_blob(c.hit)
		blob, _ := format.material_view(data)
		p: Material_Pipeline
		make_pipelines(r, &p, data, blob, 0)
		testing.expectf(
			t,
			(p.hit != {}) == c.expected,
			"ray query %v, hit code %v: hit pipeline %v",
			c.ray_query,
			c.hit,
			p.hit,
		)
		testing.expect(t, p.pipelines[.Hit] == {} && p.pipelines[.Forward] != {})
		// Updating a pipeline keeps its hit pipeline.
		make_pipelines(r, &p, data, blob, 0)
		testing.expect(t, (p.hit != {}) == c.expected)
		material_pipeline_destroy(&p, &platform)
	}
}

// What a frame of the ray scene did: how many meshes' structures it built, sized and compacted, and whether it refit the
// skinned entity's structure or built it.
@(private = "file")
Accel_Frame :: struct {
	builds:      int,
	sized:       int,
	compactions: int,
	refit:       bool,
	executed:    bool,
}

// run_accel_frame builds a frame's ray scene over the residency's mesh and the skinned entity in slot 0, and executes
// it with submit.
@(private = "file")
run_accel_frame :: proc(
	r: ^Renderer,
	cache: ^Texture_Cache,
	indices: gpu.Buffer,
	submit: proc(
		buffers: []gpu.Command_Buffer,
		queue := gpu.Queue.Graphics,
		wait_for := gpu.Queues{},
	) -> bool,
) -> (
	run: Accel_Frame,
) {
	platform := r.platform
	platform.gpu_submit = submit
	g := begin(platform, cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {
		renderer = r,
		state    = &r.view,
		graph    = &g,
		size     = {64, 32},
	}
	sf := new(Scene_Frame, platform.frame_allocator)
	f.scene_frame = sf
	sf.items = make([]Cull_Item, 1, platform.frame_allocator)
	sf.skin.refits = make([]Skin_Refit, 1, platform.frame_allocator)
	sf.skin.refits[0] = {
		slot    = 0,
		indices = indices,
	}
	sf.accel_instances, _ = platform.gpu_upload(2 * size_of(gpu.Accel_Instance), 16)
	sf.accel_count = 2
	if request_ray_scene(f) {
		add_ray_scene_passes(f)
		run.builds, run.refit = len(f.ray_scene.builds), sf.skin.refits[0].update
		run.sized, run.compactions = len(f.ray_scene.sized), len(f.ray_scene.compactions)
	}
	run.executed = execute(&g)
	free_all(platform.frame_allocator)
	return
}

// A frame that does not execute builds no structure, so the next frame builds the mesh's again, and builds the skinned
// entity's instead of refitting one that was never built.
@(test)
a_failed_frame_builds_the_accels_again :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator      = virtual.arena_allocator(&arena),
		heap_allocator       = runtime.heap_allocator(),
		jobs_run             = jobs.run,
		jobs_wait            = jobs.wait,
		gpu_submit           = null.submit,
		gpu_upload           = null.upload,
		gpu_create_buffer    = null.create_buffer,
		gpu_destroy_buffer   = null.destroy_buffer,
		gpu_create_accel     = null.create_accel,
		gpu_destroy_accel    = null.destroy_accel,
		gpu_destroy_texture  = null.destroy_texture,
		gpu_destroy_pipeline = null.destroy_pipeline,
		gpu_create_sampler   = null.create_sampler,
		gpu_destroy_sampler  = null.destroy_sampler,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	r.residency.platform = &platform
	positions := platform.gpu_create_buffer(
		{size = 36, usage = {.Storage}, label = "positions"},
		nil,
	)
	indices := platform.gpu_create_buffer({size = 12, usage = {.Index}, label = "indices"}, nil)
	posed := platform.gpu_create_buffer(
		{size = 36, usage = {.Storage}, label = "posed positions"},
		nil,
	)
	defer for b in ([]gpu.Buffer{positions, indices, posed}) {
		platform.gpu_destroy_buffer(b)
	}
	// A ready mesh, whose structure the first request makes, and a skinned entity of it.
	r.residency.count = 1
	e := &r.residency.entries[0]
	e.kind, e.ready, e.current = .Mesh, true, Resident_Mesh{}
	mesh := &e.current.(Resident_Mesh)
	mesh.positions, mesh.indices, mesh.vertex_count, mesh.index_count, mesh.index_format =
		positions, indices, 3, 3, .U32
	r.scene.skins.instances = make(map[u32]Skinned_Instance, platform.heap_allocator)
	defer delete(r.scene.skins.instances)
	r.scene.skins.instances[0] = {
		positions    = posed,
		vertex_count = 3,
	}
	skin_accel(&r.scene.skins, &platform, 0, mesh)
	skin := &r.scene.skins.instances[0]
	defer platform.gpu_destroy_accel(skin.accel)
	defer platform.gpu_destroy_accel(mesh.accel)
	defer ray_scene_destroy(&r.ray_scene, &platform)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	// The first frame fails: nothing counts as built.
	run := run_accel_frame(r, &cache, indices, fail_submit)
	testing.expect(t, !run.executed, "the frame executed with a submit that fails")
	testing.expect(t, mesh.accel != {} && skin.accel != {})
	testing.expect_value(t, run.builds, 1)
	testing.expect(t, !run.refit, "the first frame refit a structure that was never built")
	_, unbuilt := mesh.accel_state.(Accel_Unbuilt)
	testing.expect(t, unbuilt && !skin.accel_built, "the failed frame's structures count as built")

	// The next builds both again, and the null backend validates the builds.
	run = run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(t, run.executed, "the frame did not execute")
	testing.expect_value(t, run.builds, 1)
	testing.expect(
		t,
		!run.refit,
		"the frame after a failed one refit a structure that was never built",
	)
	_, built := mesh.accel_state.(Accel_Built)
	testing.expect(t, built && skin.accel_built)

	// Then the mesh's is done, and the skinned entity's refits.
	run = run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(t, run.executed, "the frame did not execute")
	testing.expect_value(t, run.builds, 0)
	testing.expect(t, run.refit, "a built structure did not refit")
}

// A built mesh's structure is sized, then compacted, and the mesh's instances use the compacted one from the frame
// after the compaction executed. A frame that fails leaves each step to the next frame. A mesh whose compacted size is
// 0 keeps its structure, and a skinned entity's structure, which refits, is never compacted.
@(test)
a_built_mesh_accel_is_compacted :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator      = virtual.arena_allocator(&arena),
		heap_allocator       = runtime.heap_allocator(),
		jobs_run             = jobs.run,
		jobs_wait            = jobs.wait,
		gpu_submit           = null.submit,
		gpu_upload           = null.upload,
		gpu_create_buffer    = null.create_buffer,
		gpu_destroy_buffer   = null.destroy_buffer,
		gpu_read_buffer      = null.read_buffer,
		gpu_create_accel     = null.create_accel,
		gpu_destroy_accel    = null.destroy_accel,
		gpu_destroy_texture  = null.destroy_texture,
		gpu_destroy_pipeline = null.destroy_pipeline,
		gpu_create_sampler   = null.create_sampler,
		gpu_destroy_sampler  = null.destroy_sampler,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	r.residency.platform = &platform
	positions := platform.gpu_create_buffer(
		{size = 36, usage = {.Storage}, label = "positions"},
		nil,
	)
	indices := platform.gpu_create_buffer({size = 12, usage = {.Index}, label = "indices"}, nil)
	posed := platform.gpu_create_buffer(
		{size = 36, usage = {.Storage}, label = "posed positions"},
		nil,
	)
	defer for b in ([]gpu.Buffer{positions, indices, posed}) {
		platform.gpu_destroy_buffer(b)
	}
	// Two ready meshes of one triangle, and a skinned entity of the first.
	r.residency.count = 2
	for &e in r.residency.entries[:2] {
		e.kind, e.ready, e.current = .Mesh, true, Resident_Mesh{}
		m := &e.current.(Resident_Mesh)
		m.positions, m.indices, m.vertex_count, m.index_count, m.index_format =
			positions, indices, 3, 3, .U32
	}
	mesh, kept :=
		&r.residency.entries[0].current.(Resident_Mesh),
		&r.residency.entries[1].current.(Resident_Mesh)
	r.scene.skins.instances = make(map[u32]Skinned_Instance, platform.heap_allocator)
	defer delete(r.scene.skins.instances)
	r.scene.skins.instances[0] = {
		positions    = posed,
		vertex_count = 3,
	}
	skin_accel(&r.scene.skins, &platform, 0, mesh)
	skin := &r.scene.skins.instances[0]
	defer platform.gpu_destroy_accel(skin.accel)
	defer change_mesh_accel(&r.residency, kept, Accel_Destroyed{})
	defer change_mesh_accel(&r.residency, mesh, Accel_Destroyed{})
	defer ray_scene_destroy(&r.ray_scene, &platform)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	// The first frame builds the structures, and the next writes their compacted sizes. A failed frame copies none.
	run := run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(t, run.executed && run.builds == 2 && run.sized == 0)
	run = run_accel_frame(r, &cache, indices, fail_submit)
	testing.expect_value(t, run.sized, 2)
	_, built := mesh.accel_state.(Accel_Built)
	testing.expect(t, built, "a failed frame's sizes were taken")
	testing.expect(t, r.ray_scene.compaction.copied == {}, "a failed frame copied into a slot")
	run = run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(t, run.executed && run.sized == 2 && run.compactions == 0)
	sizing, is_sizing := mesh.accel_state.(Accel_Sizing)
	_, kept_sizing := kept.accel_state.(Accel_Sizing)
	testing.expect(t, is_sizing && kept_sizing, "the meshes do not wait for their sizes")
	testing.expect(t, sizing.slot in r.ray_scene.compaction.copied)

	// The null backend writes no sizes, so the test writes the first mesh's. The next frame makes its compaction's
	// destination and copies into it, but fails, so the mesh keeps its structure and the next frame copies again.
	data, ready := null.read_buffer(r.ray_scene.compaction.readbacks[sizing.slot])
	testing.expect(t, ready)
	([^]u64)(raw_data(data))[sizing.index] = 32
	original := mesh.accel
	run = run_accel_frame(r, &cache, indices, fail_submit)
	testing.expect_value(t, run.compactions, 1)
	compacting, is_compacting := mesh.accel_state.(Accel_Compacting)
	testing.expect(
		t,
		is_compacting && mesh.accel == original,
		"a failed frame swapped the structures",
	)
	_, kept_compacted := kept.accel_state.(Accel_Compacted)
	testing.expect(
		t,
		kept_compacted && kept.accel != {},
		"a mesh with a compacted size of 0 lost its structure",
	)
	testing.expect(
		t,
		sizing.slot not_in r.ray_scene.compaction.copied,
		"a slot that was read stays copied",
	)

	// The next frame executes: the mesh's instances use the compacted structure, and the built one goes.
	run = run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(t, run.executed && run.compactions == 1)
	_, compacted := mesh.accel_state.(Accel_Compacted)
	testing.expect(t, compacted && mesh.accel == compacting.compacted)
	// The compacted structure, the kept one, the skinned entity's and the scene's.
	stats := null.stats()
	testing.expect_value(t, stats.accels, 4)
	testing.expect_value(t, stats.bottom_accel_memory, 32 + 2 * null.ACCEL_TRIANGLE_BYTES)
	testing.expect_value(t, stats.bottom_accel_memory_uncompacted, 3 * null.ACCEL_TRIANGLE_BYTES)

	// Then there is nothing left to do, and the skinned entity's structure refits as it did.
	run = run_accel_frame(r, &cache, indices, null.submit)
	testing.expect(
		t,
		run.executed && run.builds == 0 && run.sized == 0 && run.compactions == 0 && run.refit,
	)
}

@(private = "file")
fail_upload :: proc(size, align: int) -> (gpu.Upload, bool) {
	return {}, false
}

@(test)
hit_shading_bins_the_hits_and_dispatches_each_bin_indirectly :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator             = virtual.arena_allocator(&arena),
		heap_allocator              = runtime.heap_allocator(),
		jobs_run                    = jobs.run,
		jobs_wait                   = jobs.wait,
		gpu_frame_target            = null.frame_target,
		gpu_submit                  = null.submit,
		gpu_upload                  = null.upload,
		gpu_create_texture          = null.create_texture,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_buffer           = null.create_buffer,
		gpu_destroy_buffer          = null.destroy_buffer,
		gpu_create_accel            = null.create_accel,
		gpu_destroy_accel           = null.destroy_accel,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	code := []byte{1}
	r.ray_scene.bin_pipeline.pipeline = platform.gpu_create_compute_pipeline(
		{compute = code, label = "test bins"},
	)
	r.ray_scene.fallback.pipeline = platform.gpu_create_compute_pipeline(
		{compute = code, label = "test fallback"},
	)
	r.materials.pipelines[0].hit = platform.gpu_create_compute_pipeline(
		{compute = code, label = "test hit"},
	)
	r.materials.pipeline_count = 1
	r.ray_scene.accel = platform.gpu_create_accel(
		{kind = .Top, max_instances = 4, label = "test scene"},
	)
	defer ray_scene_destroy(&r.ray_scene, &platform)
	defer material_pipeline_destroy(&r.materials.pipelines[0], &platform)

	rays: u32 = 1000
	buffers := []gpu.Buffer {
		platform.gpu_create_buffer(
			{size = rays * size_of(Hit_Record), usage = {.Storage}, label = "hits"},
			nil,
		),
		platform.gpu_create_buffer(
			{size = rays * size_of(Hit_Surface), usage = {.Storage}, label = "surfaces"},
			nil,
		),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil),
	}
	defer for b in buffers {
		platform.gpu_destroy_buffer(b)
	}
	for queue in ([]gpu.Queue{.Graphics, .Compute}) {
		cache: Texture_Cache
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(
			size_of(Frame_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		sf.instances = import_buffer(&g, buffers[2])
		sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance), 16)
		sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh), 16)
		sf.hit_instance_count = 1
		sf.hit_bins = {0, 1}

		// Without a request, the frame has no ray scene to shade hits of.
		hits, surfaces := import_buffer(&g, buffers[0]), import_buffer(&g, buffers[1])
		batch := Hit_Batch {
			hits     = hits,
			surfaces = surfaces,
			count    = rays,
		}
		testing.expect(t, reserve_hit_shading(f, rays) == nil)
		testing.expect(t, request_ray_scene(f))
		// The structure as add_ray_scene_passes imports it, without the residency's meshes to build.
		f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)

		// A turn whose uploads fail takes no batch, so a client that has none adds no pass that reads the surfaces.
		platform.gpu_upload = fail_upload
		testing.expect(
			t,
			reserve_hit_shading(f, rays) == nil,
			"a turn was reserved without its uploads",
		)
		testing.expect_value(t, f.ray_scene.batches, 0)
		platform.gpu_upload = null.upload

		reservation, reserved := reserve_hit_shading(f, rays).?
		testing.expect(t, reserved, "no turn was reserved")
		testing.expect_value(t, f.ray_scene.batches, 1)
		// The client's trace writes the hits, and a pass after reads the surfaces.
		p := add_compute_pass(&g, "trace", proc(_: ^Pass_Context) {}, nil, queue = queue)
		read_accel(&g, p, ray_scene_accel(f))
		write(&g, p, hits)
		shaded := add_hit_shading(f, reservation, batch, queue)
		testing.expect(t, shaded.surfaces == surfaces && shaded.count == rays)
		p = add_compute_pass(&g, "light", proc(_: ^Pass_Context) {}, nil, queue = queue)
		read(&g, p, surfaces)
		write(&g, p, hits)
		// The null backend checks the barriers between the phases, and that each indirect dispatch has a compute
		// pipeline bound and its arguments in the buffer.
		testing.expectf(t, execute(&g), "hit shading on the %v queue did not execute", queue)
		cache_destroy(&cache, &platform)
		free_all(platform.frame_allocator)
	}
	testing.expect(t, r.ray_scene.scratch[0].capacity >= int(rays))
}
