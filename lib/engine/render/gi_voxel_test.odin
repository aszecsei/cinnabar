package render

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

@(private = "file")
meters :: proc(x, y, z: f64) -> ecs.World_Position {
	scale :: f64(1 << ecs.POSITION_FRACTION_BITS)
	return {raw = {i64(x * scale), i64(y * scale), i64(z * scale)}}
}

@(test)
a_voxel_box_follows_the_camera_in_steps :: proc(t: ^testing.T) {
	box: Voxel_Box
	// Voxels of an eighth of a meter, 64 across.
	testing.expect(t, place_voxel_box(&box, meters(0.05, 0, 0), -3, 64))
	testing.expect_value(t, box.anchor, [3]i64{-32, -32, -32})
	testing.expect(t, !box.voxelized)
	box.voxelized = true
	// Within VOXEL_SNAP voxels of its middle, it stays, and keeps its surfaces.
	testing.expect(t, !place_voxel_box(&box, meters(1, -1, 0.9), -3, 64))
	testing.expect(t, box.voxelized)
	// Past it, it moves to a multiple of VOXEL_SNAP, so it covers whole voxels of the next level, and holds no surfaces.
	testing.expect(t, place_voxel_box(&box, meters(1.2, 0, 0), -3, 64))
	testing.expect_value(t, box.anchor, [3]i64{-24, -32, -32})
	testing.expect(t, !box.voxelized)
	for axis in 0 ..< 3 {
		testing.expect_value(t, box.anchor[axis] % VOXEL_SNAP, 0)
	}
	// A negative position floors: -0.01 m is in cell -1.
	other: Voxel_Box
	place_voxel_box(&other, meters(-0.01, -0.01, -0.01), 0, 64)
	testing.expect_value(t, other.anchor, [3]i64{-40, -40, -40})
}

@(test)
a_voxel_box_moves_with_the_world_not_the_render_origin :: proc(t: ^testing.T) {
	// The box is of World_Position, which a rebase of the render origin leaves as it is, so the box and its first voxel
	// relative to the camera are the same.
	camera := meters(1000.3, 5.2, -2000.7)
	box: Voxel_Box
	place_voxel_box(&box, camera, -2, 64)
	min := split_window_min(box.anchor, camera, -2)
	size := f32(0.25)
	for axis in 0 ..< 3 {
		// The camera is near the box's middle.
		testing.expectf(t, -min[axis] >= (32 - VOXEL_SNAP - 1) * size && -min[axis] <= (32 + VOXEL_SNAP + 1) * size, "axis %d's first voxel is %v m away", axis, min[axis])
	}
	testing.expect_value(t, voxel_phase({-1, 64, 130}, 64), [3]i32{63, 0, 2})
}

@(test)
the_voxel_schedule_voxelizes_empty_levels_and_every_level_in_turn :: proc(t: ^testing.T) {
	boxes := [5]Voxel_Box{}
	turn: u32
	// Every level holds nothing at first.
	testing.expect_value(t, voxel_schedule(boxes[:], &turn), [VOXEL_MAX_LEVELS]bool{true, true, true, true, true, false, false, false})
	for &box in boxes {
		box.voxelized = true
	}
	// Then one level a frame, each within as many frames as there are levels.
	seen: [5]int
	for _ in 0 ..< len(boxes) {
		voxelize := voxel_schedule(boxes[:], &turn)
		count := 0
		for l in 0 ..< len(boxes) {
			if voxelize[l] {
				seen[l] += 1
				count += 1
			}
		}
		testing.expect_value(t, count, 1)
	}
	testing.expect_value(t, seen, [5]int{1, 1, 1, 1, 1})
	// A level whose box moved voxelizes at once, with the next in turn.
	boxes[3].voxelized = false
	voxelize := voxel_schedule(boxes[:], &turn)
	testing.expect(t, voxelize[3])
	count := 0
	for l in 0 ..< len(boxes) {
		count += int(voxelize[l])
	}
	testing.expect_value(t, count, 2)
}

@(test)
the_voxel_levels_fit_their_budgets :: proc(t: ^testing.T) {
	// The levels' textures, in MiB, at most.
	budgets := [Quality_Level]int {
		.Low    = 32,
		.Medium = 112,
		.High   = 256,
		.Ultra  = 320,
	}
	for params, level in GI_VOXEL_PARAMS {
		testing.expectf(t, voxel_bytes(params) <= budgets[level] << 20, "%v takes %d MiB", level, voxel_bytes(params) >> 20)
		testing.expect(t, params.levels <= VOXEL_MAX_LEVELS && params.cones <= VOXEL_MAX_CONES)
		// A box covers whole voxels of the next level, so the filter's halves are whole.
		testing.expect_value(t, params.res % (2 * VOXEL_SNAP), 0)
	}
}

@(test)
the_diffuse_cones_weigh_the_hemisphere_by_the_cosine :: proc(t: ^testing.T) {
	for count in ([]u32{4, 6, 9}) {
		cones, aperture := voxel_cones(count)
		total: f32
		mean: [3]f32
		n := 0
		for cone in cones {
			if cone.w == 0 {
				continue
			}
			n += 1
			total += cone.w
			mean += cone.xyz * cone.w
			testing.expect(t, abs(linalg.length(cone.xyz) - 1) < 1e-4)
			// Each cone's weight is its cosine, over every cone's.
			testing.expect(t, cone.z > 0)
		}
		testing.expect_value(t, u32(n), count)
		testing.expectf(t, abs(total - 1) < 1e-4, "%d cones weigh %v", count, total)
		// Their mean leans along the normal only.
		testing.expectf(t, abs(mean.x) < 1e-4 && abs(mean.y) < 1e-4, "%d cones lean %v", count, mean)
		testing.expect(t, aperture > 0.3 && aperture < 0.6)
	}
}

@(test)
a_voxel_view_maps_its_box_to_the_clip_space :: proc(t: ^testing.T) {
	min := [3]f32{-4, -2, 1}
	extent := f32(8)
	for axis in 0 ..< 3 {
		m := voxel_view_projection(min, extent, axis)
		lo := m * [4]f32{min.x, min.y, min.z, 1}
		hi := m * [4]f32{min.x + extent, min.y + extent, min.z + extent, 1}
		testing.expectf(t, lo == {-1, -1, 0, 1}, "axis %d maps the first corner to %v", axis, lo)
		testing.expectf(t, hi == {1, 1, 1, 1}, "axis %d maps the last corner to %v", axis, hi)
		// The depth is along the axis.
		step: [3]f32
		step[axis] = extent / 2
		mid := m * [4]f32{min.x + step.x, min.y + step.y, min.z + step.z, 1}
		testing.expect_value(t, mid.z, 0.5)
	}
	planes := voxel_box_planes(min, extent)
	inside := [3]f32{0, 2, 5}
	for plane in planes {
		testing.expect(t, linalg.dot(plane.xyz, inside) + plane.w > 0)
	}
	testing.expect(t, linalg.dot(planes[1].xyz, [3]f32{5, 2, 5}) + planes[1].w < 0)
	_ = math.PI
}

@(test)
the_voxel_cones_run_without_ray_queries_and_pass_validation :: proc(t: ^testing.T) {
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
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	code := []byte{1}
	gi := &r.gi
	voxel := &gi.voxel
	for p in ([]^Shader_Pipeline{&gi.trace, &gi.merge, &gi.gather, &gi.lit, &voxel.clear, &voxel.inject, &voxel.filter, &voxel.gather}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	defer gi_destroy(gi, &platform)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	run_frame :: proc(t: ^testing.T, r: ^Renderer, cache: ^Texture_Cache, settings: Gi_Settings, camera: ecs.World_Position, view := Debug_View.Lit) -> (passes: map[string]int) {
		platform := r.platform
		g := begin(platform, cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, state = &r.view, graph = &g, size = {64, 32}, view = {position = camera}, debug_view = view}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = .RG16_Float, label = "normals"})
		f.velocity = create_texture(&g, {size = f.size, format = .RG16_Float, label = "velocity"})
		f.roughness = create_texture(&g, {size = f.size, format = ROUGHNESS_FORMAT, label = "roughness"})
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		color(&g, prepass, f.normals, .Clear)
		color(&g, prepass, f.velocity, .Clear)
		color(&g, prepass, f.roughness, .Clear)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		begin_gi(f, settings, {})
		testing.expect(t, f.gi != nil && f.gi.voxel != nil)
		if f.gi == nil || f.gi.voxel == nil {
			return
		}
		// Each level that voxelizes has a view along each axis.
		voxelizing := 0
		for l in 0 ..< int(f.gi.voxel.params.levels) {
			voxelizing += int(f.gi.voxel.voxelize[l])
		}
		testing.expect_value(t, len(f.gi.voxel.views), 3 * voxelizing)
		add_gi_passes(f)
		p := add_compute_pass(&g, "forward", proc(_: ^Pass_Context) {}, nil)
		read(&g, p, f.gi_diffuse)
		read(&g, p, f.gi_specular)
		keep_pass(&g, p)
		testing.expect_value(t, f.gi.probe_view != 0, view == .Gi_Probes)
		if f.gi.probe_view != 0 {
			p = add_compute_pass(&g, "debug view", proc(_: ^Pass_Context) {}, nil)
			read(&g, p, f.gi.probe_view)
			keep_pass(&g, p)
		}
		passes = make(map[string]int, platform.frame_allocator)
		for node in g.passes {
			passes[node.name] += 1
			if node.name == "gi voxel inject" || node.name == "gi voxel filter" || node.name == "gi voxel gather" {
				testing.expectf(t, node.queue == .Compute, "%s is on the %v queue", node.name, node.queue)
			}
		}
		testing.expect(t, execute(&g), "the frame did not execute")
		return
	}

	settings := Gi_Settings{technique = .Voxel_Cones, level = .Low}
	levels := int(GI_VOXEL_PARAMS[.Low].levels)
	for frame in 0 ..< 3 {
		passes := run_frame(t, r, &cache, settings, meters(10.5, 2, -3))
		testing.expect_value(t, passes["gi voxel gather"], 1)
		testing.expect_value(t, passes["gi voxel inject"], levels)
		testing.expect_value(t, passes["gi voxel filter"], levels - 1)
		// Every level empties first, then one a frame in turn. The frame has no draws, so none draws, and no cascade runs.
		testing.expect_value(t, passes["gi voxel clear"], frame == 0 ? levels : 1)
		testing.expect_value(t, passes["gi voxelize"], 0)
		testing.expect_value(t, passes["gi trace"], 0)
		free_all(platform.frame_allocator)
	}
	testing.expect(t, r.view.gi.voxel.running)
	testing.expect_value(t, r.view.gi.voxel.params, GI_VOXEL_PARAMS[.Low])
	// A level that voxelized without draws holds no surfaces, and is up to date.
	testing.expect(t, r.view.gi.voxel.boxes[0].voxelized)

	// With the Gi_Probes debug view, the gather draws the voxels too.
	passes := run_frame(t, r, &cache, settings, meters(16, 2, -3), .Gi_Probes)
	testing.expect_value(t, passes["gi voxel gather"], 1)
	free_all(platform.frame_allocator)

	// Another level makes its own storage.
	settings.level = .High
	passes = run_frame(t, r, &cache, settings, meters(0, 0, 0))
	testing.expect_value(t, passes["gi voxel inject"], int(GI_VOXEL_PARAMS[.High].levels))
	testing.expect_value(t, r.view.gi.voxel.params, GI_VOXEL_PARAMS[.High])
	free_all(platform.frame_allocator)
}
