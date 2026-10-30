package render

import "base:runtime"
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

@(private = "file")
pending_count :: proc(schedule: ^Probe_Schedule, level: int) -> (count: int) {
	for word in schedule.pending[level] {
		count += card(transmute(bit_set[0 ..< 64;u64])word)
	}
	return
}

@(test)
probe_cells_floor_negative_positions :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_cell(meters(0.5, -0.5, 0), 0), [3]i64{0, -1, 0})
	testing.expect_value(t, probe_cell(meters(2.5, -2.5, -4), 1), [3]i64{1, -2, -2})
	testing.expect_value(t, probe_phase({-1, -16, 33}), [3]i32{31, 0, 1})
}

@(test)
a_level_follows_the_camera_and_resets_the_probes_it_moved_over :: proc(t: ^testing.T) {
	level: Gi_Probe_Level
	schedule: Probe_Schedule
	// The first placement resets every probe.
	delta := place_probe_level(&level, meters(0.5, 0.5, 0.5), 0)
	mark_moved_probes(&schedule, 0, probe_phase(level.min_cell), delta)
	testing.expect_value(t, level.min_cell, [3]i64{-16, -8, -16})
	testing.expect_value(t, pending_count(&schedule, 0), GI_PROBE_COUNT)
	schedule = {}

	// Within GI_PROBE_RECENTER probes of its middle, the box stays.
	delta = place_probe_level(&level, meters(2.5, -1.5, 0.5), 0)
	testing.expect_value(t, delta, [3]i64{})
	mark_moved_probes(&schedule, 0, probe_phase(level.min_cell), delta)
	testing.expect_value(t, pending_count(&schedule, 0), 0)

	// Three probes along x: the box follows, and only the slab that it moved over, 3 probes deep, resets.
	before := level.min_cell
	delta = place_probe_level(&level, meters(3.5, 0.5, 0.5), 0)
	testing.expect_value(t, delta, [3]i64{3, 0, 0})
	testing.expect_value(t, level.min_cell, before + {3, 0, 0})
	mark_moved_probes(&schedule, 0, probe_phase(level.min_cell), delta)
	testing.expect_value(t, pending_count(&schedule, 0), 3 * int(GI_PROBE_GRID.y * GI_PROBE_GRID.z))
	// They are the box's last three columns along x.
	phase := probe_phase(level.min_cell)
	for storage in u32(0) ..< GI_PROBE_COUNT {
		cell := probe_storage_cell(storage, phase)
		marked := schedule.pending[0][storage / 64] & (1 << (storage % 64)) != 0
		testing.expect_value(t, marked, cell.x >= i32(GI_PROBE_GRID.x) - 3)
	}

	// A teleport moves the box past itself, which resets the whole level.
	schedule = {}
	delta = place_probe_level(&level, meters(5000, 0.5, 0.5), 0)
	mark_moved_probes(&schedule, 0, probe_phase(level.min_cell), delta)
	testing.expect_value(t, pending_count(&schedule, 0), GI_PROBE_COUNT)
}

@(test)
a_render_origin_rebase_moves_no_probe :: proc(t: ^testing.T) {
	// The render origin moves to the camera's 1024 m cell when it rebases: the probes follow the camera's world
	// position, not the origin, so they keep their cells, and their places relative to the camera move by its motion.
	level: Gi_Probe_Level
	before_camera, after_camera := meters(1023.75, 3.25, -7.5), meters(1024.25, 3.25, -7.5)
	place_probe_level(&level, before_camera, 1)
	testing.expect(t, snap_origin(before_camera) != snap_origin(after_camera), "the camera's step crosses a rebase")
	cells := level.min_cell
	before := probe_level_min(level.min_cell, before_camera, 1)
	testing.expect_value(t, place_probe_level(&level, after_camera, 1), [3]i64{})
	testing.expect_value(t, level.min_cell, cells)
	after := probe_level_min(level.min_cell, after_camera, 1)
	testing.expect_value(t, after - before, [3]f32{-0.5, 0, 0})
	// The first probe is a whole number of 2 m cells from the world's origin, exactly.
	testing.expect_value(t, f64(before.x) + 1023.75, f64(cells.x * 2))
}

@(test)
the_schedule_updates_reset_probes_first_then_every_probe_in_turn :: proc(t: ^testing.T) {
	schedule: Probe_Schedule
	schedule.pending[1][2] = 1 << 5 | 1 << 9
	jobs := probe_jobs(&schedule, 2, 100, context.temp_allocator)
	testing.expect_value(t, len(jobs), 100)
	testing.expect_value(t, jobs[0], 1 << 24 | 2 * 64 + 5)
	testing.expect_value(t, jobs[1], 1 << 24 | 2 * 64 + 9)
	testing.expect_value(t, pending_count(&schedule, 1), 0)
	// The rest is each level's share in turn.
	testing.expect_value(t, jobs[2], 0)
	testing.expect_value(t, jobs[2 + 49], 1 << 24)

	// Within GI_PROBE_COUNT / share frames, every probe of every level is updated.
	schedule = {}
	seen := make([]bool, 2 * GI_PROBE_COUNT, context.temp_allocator)
	budget := 4096
	for _ in 0 ..< 2 * GI_PROBE_COUNT / budget {
		for job in probe_jobs(&schedule, 2, budget, context.temp_allocator) {
			seen[int(job >> 24) * GI_PROBE_COUNT + int(job & 0xffffff)] = true
		}
	}
	for s in seen {
		testing.expect(t, s)
	}
}

@(test)
the_rays_rotation_is_a_rotation :: proc(t: ^testing.T) {
	for frame in u32(0) ..< 16 {
		rows := probe_rotation(frame)
		for i in 0 ..< 3 {
			for j in 0 ..< 3 {
				d := rows[i].x * rows[j].x + rows[i].y * rows[j].y + rows[i].z * rows[j].z
				testing.expectf(t, abs(d - (i == j ? 1 : 0)) < 1e-5, "frame %d: rows %d and %d: %f", frame, i, j, d)
			}
		}
	}
}

@(test)
the_probes_update_on_the_compute_queue_and_pass_validation :: proc(t: ^testing.T) {
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
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	code := []byte{1}
	probes := &r.gi.probes
	for p in ([]^Shader_Pipeline{&r.ray_scene.bin_pipeline, &r.ray_scene.fallback, &probes.reset, &probes.trace, &probes.light, &probes.screen, &probes.update}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	r.ray_scene.accel = platform.gpu_create_accel({kind = .Top, max_instances = 4, label = "test scene"})
	defer ray_scene_destroy(&r.ray_scene, &platform)
	defer gi_probes_destroy(probes, &platform)
	instances := platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil)
	defer platform.gpu_destroy_buffer(instances)
	lit_texture := platform.gpu_create_texture({size = {32, 16}, format = GI_FORMAT, usage = {.Sampled, .Storage}, label = "lit"}, nil)
	defer platform.gpu_destroy_texture(lit_texture)

	settings := Gi_Settings {
		technique = .World_Probes,
		level     = .Low,
	}
	camera := meters(10.5, 2, -3)
	for frame in 0 ..< 3 {
		cache: Texture_Cache
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}, view = {position = camera}}
		f.lights = new(Light_Frame, platform.frame_allocator)
		// The prepass's depth, which the hits' light reads.
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		// Last frame's lit scene, as the history cache keeps it.
		lit := History{previous = import_texture(&g, lit_texture, .Storage), valid = frame > 0}
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		sf.instances = import_buffer(&g, instances)
		sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance), 16)
		sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh), 16)
		sf.hit_instance_count = 1
		sf.hit_bins = {0}
		testing.expect(t, request_ray_scene(f))
		f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)
		pf := add_gi_probe_passes(f, settings, lit)
		testing.expectf(t, pf != nil, "frame %d: no probes", frame)
		if pf == nil {
			break
		}
		params := GI_PROBE_PARAMS[.Low]
		testing.expect_value(t, len(pf.jobs), int(params.budget))
		// The first frame resets every probe, which then update finest level first.
		if frame == 0 {
			testing.expect_value(t, pf.grid.levels[0].delta, [4]i32{32, 16, 32, 0})
			testing.expect_value(t, pf.jobs[0] >> 24, 0)
		}
		// A pass on the graphics queue reads them, as the cascades do.
		p := add_compute_pass(&g, "cascades", proc(_: ^Pass_Context) {}, nil)
		read(&g, p, pf.radiance)
		read(&g, p, pf.irradiance)
		read(&g, p, pf.states)
		keep_pass(&g, p)
		testing.expectf(t, execute(&g), "frame %d did not execute", frame)
		cache_destroy(&cache, &platform)
		free_all(platform.frame_allocator)
		camera = meters(10.5 + 4 * f64(frame + 1), 2, -3)
	}

	// Without their pipelines, the probes wait, and their levels stay where they were.
	before := probes.levels
	destroy_shader_pipeline(&probes.update, &platform)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	g := begin(&platform, &cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {renderer = r, graph = &g, size = {64, 32}, view = {position = meters(500, 0, 0)}}
	testing.expect(t, add_gi_probe_passes(f, settings, {}) == nil)
	testing.expect_value(t, probes.levels, before)
}
