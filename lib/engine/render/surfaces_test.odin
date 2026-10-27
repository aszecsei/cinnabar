package render

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"

@(private = "file")
IDENTITY_ROWS :: [3][4]f32{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}

@(test)
surface_records_make_a_quadtree_over_the_rectangle :: proc(t: ^testing.T) {
	// 256 m of 1 m cells: 16 finest patches on a side, so five levels, whose root is the rectangle.
	s := surface_record(
		{size = {256, 256}, cell = 1, height_range = {1, -1}},
		IDENTITY_ROWS,
		{0, 2, 0},
		935,
		7,
		0.5,
	)
	testing.expect_value(t, s.levels, 5)
	testing.expect_value(t, s.root_size, 256)
	testing.expect_value(t, s.root_origin, [2]f32{-128, -128})
	testing.expect_value(t, s.height_range, [2]f32{-1, 1})
	testing.expect_value(t, s.hole_mask, 7)
	testing.expect_value(t, s.bound, 0.5)
	// Level 0 gives way where a cell covers SURFACE_CELL_PIXELS pixels.
	testing.expect(t, abs(s.range0 - 935.0 / SURFACE_CELL_PIXELS) < 0.01)
	testing.expect_value(t, s.camera_local, [3]f32{0, 2, 0})
	// A camera far away keeps level 0 at least a patch out, and a huge screen keeps it within what the draws can hold.
	testing.expect_value(
		t,
		surface_record({size = {256, 256}, cell = 1}, IDENTITY_ROWS, {}, 1, 0, 0).range0,
		16,
	)
	testing.expect(
		t,
		surface_record({size = {256, 256}, cell = 1}, IDENTITY_ROWS, {}, 1e9, 0, 0).range0 <
		16 * math.sqrt(f32(MAX_SURFACE_PATCHES) / 15) + 0.01,
	)
	// The camera in a turned and scaled surface's space.
	rows := [3][4]f32{{0, 0, 2, 10}, {0, 2, 0, 0}, {-2, 0, 0, 0}}
	turned := surface_record({size = {64, 64}, cell = 0}, rows, {10, 0, 4}, 935, 0, 0)
	testing.expect_value(t, turned.cell, DEFAULT_SURFACE_CELL)
	testing.expect(
		t,
		abs(turned.camera_local.x + 2) < 1e-5 &&
		abs(turned.camera_local.y) < 1e-5 &&
		abs(turned.camera_local.z) < 1e-5,
	)
}

@(test)
patch_selection_tiles_the_rectangle_and_coarsens_with_distance :: proc(t: ^testing.T) {
	// The camera over a corner, 2 m up.
	s := surface_record(
		{size = {256, 256}, cell = 1, height_range = {-1, 1}},
		IDENTITY_ROWS,
		{-128, 2, -128},
		935,
		0,
		0,
	)
	patches := select_patches_reference(s, context.temp_allocator)
	testing.expect(t, len(patches) > 16 && len(patches) < MAX_SURFACE_PATCHES)
	area: f64
	levels_seen: [MAX_SURFACE_LEVELS]int
	for p in patches {
		x, y, level := surface_patch_unpack(p)
		size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
		lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
		testing.expect(
			t,
			lo.x >= -128 && lo.y >= -128 && lo.x + size <= 128 && lo.y + size <= 128,
			"a patch is outside the rectangle",
		)
		area += f64(size) * f64(size)
		levels_seen[level] += 1
		// A patch of a coarser level is beyond the finer level's range.
		if level > 0 {
			testing.expect(
				t,
				surface_patch_distance(s, x, y, level) >= s.range0 * f32(u32(1) << (level - 1)),
				"a coarse patch is within the finer level's range",
			)
		}
	}
	// The patches cover the rectangle once.
	testing.expect_value(t, area, 256 * 256)
	testing.expect(
		t,
		levels_seen[0] > 0 && levels_seen[1] > 0,
		"the corner has fine patches and the far side coarse ones",
	)

	// From far above, the root alone draws.
	far := surface_record(
		{size = {256, 256}, cell = 1, height_range = {-1, 1}},
		IDENTITY_ROWS,
		{0, 10000, 0},
		935,
		0,
		0,
	)
	testing.expect_value(t, len(select_patches_reference(far, context.temp_allocator)), 1)

	// A rectangle that is not square drops the root's nodes beyond it.
	strip := surface_record(
		{size = {256, 32}, cell = 1, height_range = {-1, 1}},
		IDENTITY_ROWS,
		{0, 10000, 0},
		935,
		0,
		0,
	)
	strip_area: f64
	for p in select_patches_reference(strip, context.temp_allocator) {
		x, y, level := surface_patch_unpack(p)
		size := strip.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
		lo := strip.root_origin + [2]f32{f32(x), f32(y)} * size
		testing.expect(t, lo.y < 16 && lo.y + size > -16, "a patch is beyond the strip")
		strip_area += f64(size) * f64(size)
	}
	testing.expect(t, strip_area >= 256 * 32)
}

@(test)
surface_items_reserve_their_patches_in_their_bins :: proc(t: ^testing.T) {
	items := []Cull_Item{{bin = 0}, {bin = 1, flags = ITEM_SURFACE}, {bin = 0}}
	counts, offsets, per_view := bin_sizes(items, 2, context.temp_allocator)
	testing.expect_value(t, counts[0], 2)
	testing.expect_value(t, counts[1], MAX_SURFACE_PATCHES)
	testing.expect_value(t, offsets[1], 2)
	testing.expect_value(t, per_view, 2 + MAX_SURFACE_PATCHES)
}

@(test)
surface_passes_select_and_cull_patches_into_the_bins :: proc(t: ^testing.T) {
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
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	code := []byte{1}
	r.scene.select_pipeline.pipeline = platform.gpu_create_compute_pipeline(
		{compute = code, label = "select"},
	)
	r.scene.cull_patches_pipeline.pipeline = platform.gpu_create_compute_pipeline(
		{compute = code, label = "cull patches"},
	)
	defer platform.gpu_destroy_pipeline(r.scene.select_pipeline.pipeline)
	defer platform.gpu_destroy_pipeline(r.scene.cull_patches_pipeline.pipeline)
	r.scene.patches = platform.gpu_create_buffer(
		{size = MAX_SURFACES * MAX_SURFACE_PATCHES * 4, usage = {.Storage}, label = "patches"},
		nil,
	)
	r.scene.patch_counts = platform.gpu_create_buffer(
		{size = MAX_SURFACES * 4, usage = {.Storage}, label = "patch counts"},
		nil,
	)
	buffers := []gpu.Buffer {
		platform.gpu_create_buffer(
			{size = 1024, usage = {.Storage, .Indirect}, label = "arguments"},
			nil,
		),
		platform.gpu_create_buffer(
			{size = 256, usage = {.Storage, .Indirect}, label = "counts"},
			nil,
		),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil),
		r.scene.patches,
		r.scene.patch_counts,
	}
	defer for b in buffers {
		platform.gpu_destroy_buffer(b)
	}
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	g := begin(&platform, &cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {
		renderer = r,
		graph    = &g,
		size     = {64, 32},
	}
	sf := new(Scene_Frame, platform.frame_allocator)
	f.scene_frame = sf
	sf.items = make([]Cull_Item, 1, platform.frame_allocator)
	sf.items[0].flags = ITEM_SURFACE
	sf.surfaces = make([]Surface_Record, 1, platform.frame_allocator)
	sf.view_count = 1
	sf.cull_constants, _ = platform.gpu_upload(size_of(Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
	sf.arguments, sf.counts = import_buffer(&g, buffers[0]), import_buffer(&g, buffers[1])
	sf.draws, sf.instances = import_buffer(&g, buffers[2]), import_buffer(&g, buffers[3])
	before, before_added := add_select_patches_pass(f)
	after, after_added := add_cull_patches_pass(f)
	testing.expect(t, before_added && after_added)
	keep_pass(&g, before)
	keep_pass(&g, after)
	// The null backend checks the dispatches' pipelines, and the barriers between the selection's writes and the
	// culling's reads.
	testing.expect(t, execute(&g), "the surface passes did not execute")
}
