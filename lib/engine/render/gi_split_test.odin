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
import "cinnabar:engine/ecs"

@(private = "file")
meters :: proc(x, y, z: f64) -> ecs.World_Position {
	scale :: f64(1 << ecs.POSITION_FRACTION_BITS)
	return {raw = {i64(x * scale), i64(y * scale), i64(z * scale)}}
}

@(test)
split_keys_round_trip_and_are_never_empty :: proc(t: ^testing.T) {
	for level in u32(0) ..< MAX_SPLIT_LEVELS {
		for u in ([][3]u32{{0, 0, 0}, {511, 511, 511}, {3, 400, 17}}) {
			key := split_key(level, u)
			testing.expect(t, key != 0)
			testing.expect_value(t, (key >> 27) & 7, level)
			testing.expect_value(t, [3]u32{key & 511, (key >> 9) & 511, (key >> 18) & 511}, u)
		}
	}
	testing.expect(t, split_key(0, {1, 0, 0}) != split_key(0, {0, 1, 0}))
	testing.expect(t, split_key(0, {5, 5, 5}) != split_key(1, {5, 5, 5}))
	testing.expect_value(t, size_of(Split_Grid), 512)
}

@(test)
a_split_window_follows_the_camera_in_steps_of_whole_snaps :: proc(t: ^testing.T) {
	w: Split_Window
	// The first placement moves the window a whole window, which frees every probe of its level.
	delta := place_split_window(&w, meters(0.3, -0.3, 0), -2)
	testing.expect_value(t, delta, [3]i64{SPLIT_WINDOW, SPLIT_WINDOW, SPLIT_WINDOW})
	for axis in 0 ..< 3 {
		testing.expect_value(t, w.anchor[axis] % SPLIT_SNAP, 0)
	}
	// The camera's cell is in the window's middle, within a snap.
	cell := split_cell(meters(0.3, -0.3, 0), -2)
	testing.expect_value(t, cell, [3]i64{1, -2, 0})
	for axis in 0 ..< 3 {
		offset := cell[axis] - w.anchor[axis]
		testing.expectf(t, offset >= SPLIT_WINDOW / 2 && offset < SPLIT_WINDOW / 2 + SPLIT_SNAP, "axis %d: %d", axis, offset)
	}
	// Within a snap, the window stays; past it, it moves by whole snaps.
	testing.expect_value(t, place_split_window(&w, meters(0.6, -0.3, 0), -2), [3]i64{})
	delta = place_split_window(&w, meters(6.3, -0.3, 0), -2)
	testing.expect_value(t, delta, [3]i64{SPLIT_SNAP, 0, 0})
	// A teleport moves it past itself, which frees every probe.
	delta = place_split_window(&w, meters(5000, 0, 0), -2)
	testing.expect(t, delta.x >= SPLIT_WINDOW)
}

@(private = "file")
shift_cell :: proc(u: [3]i64, k: u32) -> [3]i64 {
	return {u.x >> k, u.y >> k, u.z >> k}
}

@(test)
a_moved_window_keeps_each_probe_where_it_is_or_frees_it :: proc(t: ^testing.T) {
	// A probe's key after any moves is its cell less the window's first cell, at each cascade, while it is inside.
	w: Split_Window
	exponent := i32(-2)
	camera := meters(0, 0, 0)
	place_split_window(&w, camera, exponent)
	probe := split_cell(meters(1.1, 0.4, -2.2), exponent)
	keys: [MAX_SPLIT_CASCADES]u32
	present: [MAX_SPLIT_CASCADES]bool
	for k in u32(0) ..< MAX_SPLIT_CASCADES {
		u := shift_cell(probe - w.anchor, k)
		keys[k], present[k] = split_key(0, {u32(u.x), u32(u.y), u32(u.z)}), true
	}
	for step in 0 ..< 200 {
		camera = meters(f64(step) * 0.37, f64(step % 7) * 0.5, -f64(step) * 0.21)
		delta := place_split_window(&w, camera, exponent)
		d := [3]i32{i32(delta.x), i32(delta.y), i32(delta.z)}
		for k in u32(0) ..< MAX_SPLIT_CASCADES {
			if !present[k] {
				continue
			}
			keys[k], present[k] = split_rekey(keys[k], k, d)
			u := shift_cell(probe - w.anchor, k)
			limit := i64(SPLIT_WINDOW >> k)
			inside := u.x >= 0 && u.y >= 0 && u.z >= 0 && u.x < limit && u.y < limit && u.z < limit
			testing.expect_value(t, present[k], inside)
			if present[k] {
				testing.expect_value(t, keys[k], split_key(0, {u32(u.x), u32(u.y), u32(u.z)}))
			}
		}
	}
}

@(test)
every_probe_that_a_level_allocates_is_inside_its_window :: proc(t: ^testing.T) {
	// A pixel allocates a level's probes only where the level holds it, within 2 distance cells of the camera, and the
	// gather and the merge look a cell further; the window holds them all wherever the camera is in its snap.
	for params, level in GI_SPLIT_PARAMS {
		reach := i64(2 * params.distance + 2)
		testing.expectf(t, reach + SPLIT_SNAP < SPLIT_WINDOW / 2, "%v reaches %d cells", level, reach)
		testing.expect(t, params.levels <= MAX_SPLIT_LEVELS && params.cascades <= MAX_SPLIT_CASCADES)
		testing.expect(t, params.directions <= 8, "the first cascade's probe is one group of the merge")
		for l in 0 ..< i32(params.levels) {
			w: Split_Window
			for x in 0 ..< 40 {
				camera := meters(f64(x) * 1.37 - 20, 3.5, f64(x) * -0.61)
				place_split_window(&w, camera, params.voxel + l)
				cell := split_cell(camera, params.voxel + l)
				for axis in 0 ..< 3 {
					low, high := cell[axis] - reach - w.anchor[axis], cell[axis] + reach - w.anchor[axis]
					testing.expect(t, low >= 0 && high < SPLIT_WINDOW)
				}
			}
		}
	}
}

@(test)
a_render_origin_rebase_moves_no_split_probe :: proc(t: ^testing.T) {
	// The windows follow the camera's world position, not the render origin, which a rebase moves to the camera's
	// 1024 m cell. Across that cell's edge, a window's first cell relative to the camera is exact: it moves by the
	// camera's motion and the window's own, here a snap of 0.25 m cells.
	w: Split_Window
	before, after := meters(1023.75, 3.25, -7.5), meters(1024.25, 3.25, -7.5)
	place_split_window(&w, before, -2)
	min_before := split_window_min(w.anchor, before, -2)
	delta := place_split_window(&w, after, -2)
	testing.expect_value(t, delta, [3]i64{SPLIT_SNAP, 0, 0})
	min_after := split_window_min(w.anchor, after, -2)
	testing.expect_value(t, min_after.x - min_before.x, -0.5 + f32(delta.x) * 0.25)
	testing.expect_value(t, min_before.yz, min_after.yz)
}

@(test)
split_levels_blend_continuously :: proc(t: ^testing.T) {
	distance := f32(4)
	// Nearer than the first level's distance is the first level alone.
	level, blend := split_lod(0, distance, SPLIT_BAND)
	testing.expect_value(t, level, 0)
	testing.expect_value(t, blend, 0)
	// Each level blends into the next over the last half of its distances, so the weights meet at every boundary.
	previous := f32(0)
	previous_level := u32(0)
	for i in 0 ..< 400 {
		r := f32(i) * 0.25
		level, blend = split_lod(r, distance, SPLIT_BAND)
		// The next level's weight, counted from the first.
		weight := f32(level) + blend
		testing.expectf(t, weight >= previous - 1e-4 && weight - previous < 0.2, "at %f: %f after %f", r, weight, previous)
		testing.expect(t, level >= previous_level)
		previous, previous_level = weight, level
	}
	level, blend = split_lod(distance * 1.25, distance, SPLIT_BAND)
	testing.expect_value(t, level, 0)
	testing.expect_value(t, blend, 0)
	level, blend = split_lod(distance * 1.75, distance, SPLIT_BAND)
	testing.expect_value(t, level, 0)
	testing.expect(t, blend > 0 && blend < 1)
}

@(test)
a_hit_splits_into_the_cascade_whose_interval_holds_it :: proc(t: ^testing.T) {
	for directions in ([]u32{4, 6, 8}) {
		first := split_interval(directions) * 0.25
		testing.expect(t, abs(split_interval(directions) - f32(directions) / math.sqrt(f32(4 * math.PI))) < 1e-6)
		testing.expect_value(t, split_hit_cascade(first * 0.01, first), 0)
		testing.expect_value(t, split_hit_cascade(first * 0.99, first), 0)
		for k in u32(1) ..< 6 {
			end := first * math.pow(4, f32(k))
			testing.expect_value(t, split_hit_cascade(end * 0.98, first), k)
			testing.expect_value(t, split_hit_cascade(end * 1.02, first), k + 1)
		}
	}
}

@(test)
the_split_layout_fits_its_buffers_and_dispatches :: proc(t: ^testing.T) {
	budget := [Quality_Level]int {
		.Low    = 32 << 20,
		.Medium = 64 << 20,
		.High   = 128 << 20,
		.Ultra  = 384 << 20,
	}
	for params, level in GI_SPLIT_PARAMS {
		l := split_layout(params)
		for k in 0 ..< params.cascades {
			c := l.cascades[k]
			testing.expect(t, c.entries >= 2 * c.slots && c.entries & (c.entries - 1) == 0)
			testing.expect_value(t, c.side, params.directions << k)
			// The merge's groups for a full cascade fit one dispatch's rows.
			groups := c.slots * c.chunks
			testing.expect(t, groups <= 65535 * 65535)
		}
		testing.expect_value(t, l.cascades[0].chunks, 1)
		testing.expect(t, u64(l.bins) * SPLIT_ACCUM_SIZE < 1 << 32)
		testing.expect(t, split_groups(max(l.bins, l.slots)).y <= 65535)
		bytes := split_bytes(params)
		testing.expectf(t, bytes <= budget[level], "%v takes %d MB", level, bytes >> 20)
	}
}

@(test)
each_pixel_of_a_tile_traces_in_turn :: proc(t: ^testing.T) {
	for tile in ([][2]u32{{1, 1}, {2, 1}, {2, 2}, {4, 4}}) {
		count := tile.x * tile.y
		seen := make([]bool, count, context.temp_allocator)
		for frame in u32(7) ..< 7 + count {
			r := split_rotation(frame, tile)
			testing.expect(t, r.x < tile.x && r.y < tile.y)
			seen[r.y * tile.x + r.x] = true
		}
		for s in seen {
			testing.expect(t, s)
		}
	}
	// Ultra's ray for each pixel at 4K is more than hit shading takes, so its tile widens.
	tile, tiles := split_tile({3840, 2160}, GI_SPLIT_PARAMS[.Ultra])
	testing.expect_value(t, tile, [2]u32{2, 1})
	testing.expect(t, tiles.x * tiles.y <= MAX_HIT_RAYS)
	tile, _ = split_tile({2560, 1440}, GI_SPLIT_PARAMS[.Ultra])
	testing.expect_value(t, tile, [2]u32{1, 1})
	free_all(context.temp_allocator)
}

@(test)
a_split_table_finds_every_key_within_its_probing :: proc(t: ^testing.T) {
	// The cells of a floor and a wall, as a level's probes are, at half the table's entries.
	l := split_layout(GI_SPLIT_PARAMS[.High])
	c := l.cascades[0]
	entries := make([]u32, c.entries, context.temp_allocator)
	inserted, longest := u32(0), 0
	outer: for z in u32(100) ..< 400 {
		for x in u32(100) ..< 400 {
			for y in ([]u32{256, 256 + (x + z) % 3}) {
				if inserted == c.slots {
					break outer
				}
				key := split_key(0, {x, y, z})
				at := split_hash(key) & (c.entries - 1)
				steps := 0
				for entries[at] != 0 && entries[at] != key {
					at = (at + 1) & (c.entries - 1)
					steps += 1
				}
				if entries[at] == 0 {
					entries[at] = key
					inserted += 1
				}
				longest = max(longest, steps)
			}
		}
	}
	testing.expect_value(t, inserted, c.slots)
	testing.expectf(t, longest < 32, "a key needs %d steps", longest)
	free_all(context.temp_allocator)
}

@(test)
the_split_cascades_run_on_the_compute_queue_and_pass_validation :: proc(t: ^testing.T) {
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
	gi := &r.gi
	split := &gi.split
	pipelines := []^Shader_Pipeline {
		&r.ray_scene.bin_pipeline,
		&r.ray_scene.fallback,
		&gi.trace,
		&gi.merge,
		&gi.gather,
		&gi.lit,
		&gi.probes.reset,
		&gi.probes.trace,
		&gi.probes.light,
		&gi.probes.screen,
		&gi.probes.update,
		&split.table,
		&split.trace,
		&split.deposit,
		&split.merge,
		&split.gather,
	}
	for p in pipelines {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	r.ray_scene.accel = platform.gpu_create_accel({kind = .Top, max_instances = 4, label = "test scene"})
	defer ray_scene_destroy(&r.ray_scene, &platform)
	defer gi_destroy(gi, &platform)
	instances := platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil)
	defer platform.gpu_destroy_buffer(instances)
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	run_frame :: proc(t: ^testing.T, r: ^Renderer, cache: ^Texture_Cache, instances, exposure: gpu.Buffer, settings: Gi_Settings, camera: ecs.World_Position) -> (passes: map[string]int) {
		platform := r.platform
		g := begin(platform, cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}, view = {position = camera}}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = .RG16_Float, label = "normals"})
		f.velocity = create_texture(&g, {size = f.size, format = .RG16_Float, label = "velocity"})
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		color(&g, prepass, f.normals, .Clear)
		color(&g, prepass, f.velocity, .Clear)
		f.exposure = import_buffer(&g, exposure)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		sf.instances = import_buffer(&g, instances)
		sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance), 16)
		sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh), 16)
		sf.hit_instance_count = 1
		sf.hit_bins = {0}
		begin_gi(f, settings, {})
		testing.expect(t, f.gi != nil)
		if f.gi == nil {
			return
		}
		f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)
		add_gi_world_probes(f)
		add_gi_passes(f)
		// The forward pass reads the light on the graphics queue.
		p := add_compute_pass(&g, "forward", proc(_: ^Pass_Context) {}, nil)
		read(&g, p, f.gi_diffuse)
		read(&g, p, f.gi_specular)
		keep_pass(&g, p)
		passes = make(map[string]int, platform.frame_allocator)
		for node in g.passes {
			passes[node.name] += 1
		}
		testing.expect(t, execute(&g), "the frame did not execute")
		return
	}

	settings := Gi_Settings{technique = .Split_Cascades, level = .Low}
	for frame in 0 ..< 3 {
		camera := meters(10.5 + 3 * f64(frame), 2, -3)
		passes := run_frame(t, r, &cache, instances, exposure, settings, camera)
		testing.expectf(t, passes["gi split gather"] == 1, "frame %d did not run the split cascades", frame)
		// New storage is cleared once.
		testing.expect_value(t, passes["gi split clear"], frame == 0 ? 1 : 0)
		testing.expect_value(t, passes["gi split merge"], int(GI_SPLIT_PARAMS[.Low].cascades))
		testing.expect_value(t, passes["gi split light"], 1)
		testing.expect_value(t, passes["gi trace"], 0)
		free_all(platform.frame_allocator)
	}
	testing.expect_value(t, split.params, GI_SPLIT_PARAMS[.Low])

	// Another level makes its own storage, which is cleared.
	settings.level = .High
	passes := run_frame(t, r, &cache, instances, exposure, settings, meters(0, 0, 0))
	testing.expect_value(t, passes["gi split gather"], 1)
	testing.expect_value(t, passes["gi split clear"], 1)
	testing.expect_value(t, split.params, GI_SPLIT_PARAMS[.High])
	free_all(platform.frame_allocator)

	// Without the split's pipelines, the frame takes the screen cascades.
	destroy_shader_pipeline(&split.gather, &platform)
	passes = run_frame(t, r, &cache, instances, exposure, settings, meters(0, 0, 0))
	testing.expect_value(t, passes["gi split gather"], 0)
	testing.expect_value(t, passes["gi trace"], 1)
	free_all(platform.frame_allocator)
}
