package render

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// The pool hands out ranges first fit, and a freed range merges with the free ranges beside it, so the pool is whole
// again once every range is back.
@(test)
the_radiance_pool_reuses_freed_ranges :: proc(t: ^testing.T) {
	free := make([dynamic]Pool_Range, context.temp_allocator)
	append(&free, Pool_Range{0, 100})
	a, a_ok := pool_allocate(&free, 30)
	b, b_ok := pool_allocate(&free, 50)
	testing.expect(t, a_ok && b_ok)
	testing.expect_value(t, a, 0)
	testing.expect_value(t, b, 30)
	_, too_large := pool_allocate(&free, 21)
	testing.expect(t, !too_large)
	pool_free(&free, a, 30)
	c, c_ok := pool_allocate(&free, 20)
	testing.expect(t, c_ok)
	testing.expect_value(t, c, 0)
	pool_free(&free, b, 50)
	pool_free(&free, c, 20)
	testing.expect_value(t, len(free), 1)
	testing.expect_value(t, free[0], Pool_Range{0, 100})
}

@(private = "file")
probe_of :: proc(entity: u32, count: u32) -> Emitter_Probe {
	return {
		key = {ecs.Entity(entity), 0},
		signature = {pipeline = 3, first_primitive = 0, primitive_count = count},
	}
}

// A scan whose brightest point emits lists its submesh with a range of the pool; a scan that evaluated nothing changes
// nothing; dark scans unlist it after EMITTER_DARK_SCANS in a row, and a bright one between resets the count; a scan
// of an old signature changes nothing; a submesh that goes frees its range.
@(test)
a_submesh_is_listed_while_it_emits :: proc(t: ^testing.T) {
	e: Gi_Emitters
	defer delete(e.listed)
	defer delete(e.free)
	append(&e.free, Pool_Range{0, MAX_EMITTER_TRIANGLES})
	lamp := probe_of(1, 10)
	change_emitter(&e, Emitter_Scanned{lamp, nil})
	testing.expect_value(t, len(e.listed), 0)
	change_emitter(&e, Emitter_Scanned{lamp, f32(0)})
	testing.expect_value(t, len(e.listed), 0)
	change_emitter(&e, Emitter_Scanned{lamp, f32(2)})
	testing.expect_value(t, len(e.listed), 1)
	testing.expect_value(t, e.listed[lamp.key].base, 0)
	testing.expect_value(t, e.free[0], Pool_Range{10, MAX_EMITTER_TRIANGLES - 10})

	for _ in 0 ..< EMITTER_DARK_SCANS - 1 {
		change_emitter(&e, Emitter_Scanned{lamp, f32(0)})
	}
	change_emitter(&e, Emitter_Scanned{lamp, f32(1)})
	for _ in 0 ..< EMITTER_DARK_SCANS - 1 {
		change_emitter(&e, Emitter_Scanned{lamp, f32(0)})
	}
	testing.expect_value(t, len(e.listed), 1)
	old := lamp
	old.signature.pipeline = 7
	change_emitter(&e, Emitter_Scanned{old, f32(0)})
	testing.expect_value(t, len(e.listed), 1)
	change_emitter(&e, Emitter_Scanned{lamp, f32(0)})
	testing.expect_value(t, len(e.listed), 0)
	testing.expect_value(t, e.free[0], Pool_Range{0, MAX_EMITTER_TRIANGLES})

	// A submesh with more triangles than one may have is never listed.
	change_emitter(&e, Emitter_Scanned{probe_of(2, MAX_EMITTER_SUBMESH_TRIANGLES + 1), f32(5)})
	testing.expect_value(t, len(e.listed), 0)
	change_emitter(&e, Emitter_Scanned{lamp, f32(5)})
	change_emitter(&e, Emitter_Gone{lamp.key})
	testing.expect_value(t, len(e.listed), 0)
	testing.expect_value(t, e.free[0], Pool_Range{0, MAX_EMITTER_TRIANGLES})
}

// A scan's points that hit shading did not evaluate count for nothing, and the brightest of the rest is the
// submesh's.
@(test)
a_scan_takes_its_brightest_evaluated_point :: proc(t: ^testing.T) {
	testing.expect_value(t, emitter_luminance({-1, -1}), nil)
	l, ok := emitter_luminance({-1, 0.5, 2, -1, 0}).?
	testing.expect(t, ok && l == 2)
}

// A frame's plan lists the listed submeshes that its hit table has, in the table's order, marks each of their records
// in hit_emitters and no other, refreshes a new submesh's triangles first, scans the submeshes that hit shading
// evaluates, and unlists a submesh that the table no longer has as it was listed.
@(test)
a_frame_plans_its_emitters_from_its_hit_table :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	e: Gi_Emitters
	defer delete(e.listed)
	defer delete(e.free)
	append(&e.free, Pool_Range{0, MAX_EMITTER_TRIANGLES})
	lamp := ecs.Entity(4)
	wall := ecs.Entity(5)
	glass := ecs.Entity(6)
	instances := []Hit_Instance {
		{},
		{mesh = 2, first = 0, count = 2},
		{mesh = 3, first = 2, count = 2},
	}
	submeshes := []Hit_Submesh {
		{first_primitive = 0, primitive_count = 12},
		{first_primitive = 12, primitive_count = 6},
		{first_primitive = 0, primitive_count = 40},
		{first_primitive = 40, primitive_count = 2},
	}
	keys := []Hit_Entry_Key {
		{entity = wall, submesh = 0, pipeline = 1, shaded = true},
		{entity = lamp, submesh = 1, pipeline = 2, shaded = true, two_sided = true},
		{entity = lamp, submesh = 0, pipeline = 1, shaded = true},
		{entity = glass, submesh = 1, pipeline = 9},
	}
	change_emitter(
		&e,
		Emitter_Scanned {
			{
				key = {lamp, 1},
				signature = {pipeline = 2, first_primitive = 12, primitive_count = 6},
				two_sided = true,
			},
			f32(3),
		},
	)
	plan := plan_gi_emitters(&e, instances, submeshes, keys, true, 0, allocator)
	testing.expect_value(t, len(plan.submeshes), 1)
	testing.expect_value(
		t,
		plan.submeshes[0],
		Emitter_Submesh {
			slot = 1,
			mesh = 2,
			first_primitive = 12,
			primitive_count = 6,
			first_triangle = 0,
			radiance_base = 0,
			flags = EMITTER_TWO_SIDED,
		},
	)
	testing.expect_value(t, plan.triangles, 6)
	testing.expect_value(t, len(plan.hit_emitters), 4)
	testing.expect(
		t,
		plan.hit_emitters[0] == ~u32(0) &&
		plan.hit_emitters[1] == 0 &&
		plan.hit_emitters[2] == ~u32(0) &&
		plan.hit_emitters[3] == ~u32(0),
	)
	// The scan reads the three records that hit shading evaluates, not the glass.
	testing.expect_value(t, plan.scan.count, 3)
	testing.expect_value(t, plan.discovery, 3 * EMITTER_DISCOVERY_SAMPLES)
	for job in plan.jobs[:plan.discovery] {
		testing.expect(t, job.target & EMITTER_DISCOVERY != 0)
		testing.expect(t, job.slot == 1 || job.slot == 2)
	}
	// The new submesh's six triangles come first in the refresh, each to its cell.
	refresh := plan.jobs[plan.discovery:]
	for k in 0 ..< 6 {
		testing.expect_value(t, refresh[k], Emitter_Job{1, 12 + u32(k), u32(k), refresh[k].seed})
	}
	testing.expect_value(t, len(plan.fills), 1)
	testing.expect_value(t, plan.fills[0].filled, 6)

	// The lamp's submesh takes another material: it is unlisted, and its range freed.
	keys[1].pipeline = 8
	plan = plan_gi_emitters(&e, instances, submeshes, keys, false, 1, allocator)
	testing.expect_value(t, len(plan.submeshes), 0)
	testing.expect_value(t, len(e.listed), 0)
	testing.expect_value(t, e.free[0], Pool_Range{0, MAX_EMITTER_TRIANGLES})
	testing.expect_value(t, len(plan.jobs), 0)
}

// Hit_Mirror_Light and Hit_Mirror_Triangle are the lights of the estimator's mirror: point lights, and emissive
// triangles with a radiance.
@(private = "file")
Hit_Mirror_Light :: struct {
	position: [3]f32,
	range:    f32,
	color:    [3]f32,
}

@(private = "file")
Hit_Mirror_Triangle :: struct {
	p0, e1, e2: [3]f32,
	radiance:   [3]f32,
	two_sided:  bool,
}

@(private = "file")
mirror_luminance :: proc(c: [3]f32) -> f32 {
	return linalg.dot(c, [3]f32{0.2126, 0.7152, 0.0722})
}

@(private = "file")
mirror_point_light :: proc(l: Hit_Mirror_Light, p, n: [3]f32) -> [3]f32 {
	d := l.position - p
	d2 := max(linalg.dot(d, d), 1e-4)
	window := clamp(1 - d2 * d2 / (l.range * l.range * l.range * l.range), 0, 1)
	cosine := clamp(linalg.dot(n, d / math.sqrt(d2)), 0, 1)
	return l.color * (window * window / d2 * cosine)
}

@(private = "file")
mirror_triangle_light :: proc(tri: Hit_Mirror_Triangle, y, p, n: [3]f32) -> [3]f32 {
	to := y - p
	d2 := max(linalg.dot(to, to), 1e-4)
	dir := to / math.sqrt(d2)
	front := linalg.normalize(linalg.cross(tri.e1, tri.e2))
	face := linalg.dot(front, -dir)
	cosine := tri.two_sided ? abs(face) : max(face, 0)
	return tri.radiance * (clamp(linalg.dot(n, dir), 0, 1) * cosine / d2)
}

// mirror_estimate is pick_hit_light's estimate without the shadow, as gi_light_sampling.hlsli weighs its streams: each
// point light once when they are no more than their candidates, or drawn uniformly, and a quarter of the candidates
// triangles by their power, then a point uniformly over the triangle.
@(private = "file")
mirror_estimate :: proc(
	lights: []Hit_Mirror_Light,
	triangles: []Hit_Mirror_Triangle,
	m: int,
	p, n: [3]f32,
	r: ^rand.Generator,
) -> [3]f32 {
	if len(lights) == 0 && len(triangles) == 0 {
		return 0
	}
	me := len(triangles) == 0 ? 0 : max(m / 4, 1)
	mp := len(lights) == 0 ? 0 : max(m - me, 1)
	every := len(lights) <= mp
	share := every ? f32(1) : f32(len(lights)) / f32(mp)
	sum, target: f32
	chosen: [3]f32
	for i in 0 ..< (every ? len(lights) : mp) {
		k := every ? i : int(rand.uint32(r^) % u32(len(lights)))
		lit := mirror_point_light(lights[k], p, n)
		w := mirror_luminance(lit) * share
		if w <= 0 {
			continue
		}
		sum += w
		if rand.float32(r^) * sum < w {
			chosen, target = lit, mirror_luminance(lit)
		}
	}
	powers := make([]f32, len(triangles), context.temp_allocator)
	total: f32
	for tri, i in triangles {
		area := 0.5 * linalg.length(linalg.cross(tri.e1, tri.e2))
		powers[i] = emitter_power(tri.radiance, area, tri.two_sided)
		total += powers[i]
	}
	for _ in 0 ..< me {
		u := rand.float32(r^) * total
		k := 0
		for k < len(triangles) - 1 && u >= powers[k] {
			u -= powers[k]
			k += 1
		}
		tri := triangles[k]
		chance := powers[k] / total
		s := math.sqrt(rand.float32(r^))
		u2 := rand.float32(r^)
		y := tri.p0 + tri.e1 * (s * (1 - u2)) + tri.e2 * (s * u2)
		lit := mirror_triangle_light(tri, y, p, n)
		area := 0.5 * linalg.length(linalg.cross(tri.e1, tri.e2))
		w := mirror_luminance(lit) * area / (f32(me) * chance)
		if w <= 0 {
			continue
		}
		sum += w
		if rand.float32(r^) * sum < w {
			chosen, target = lit, mirror_luminance(lit)
		}
	}
	return target > 0 ? chosen * (sum / target) : 0
}

// mirror_exact is the light that the estimate is of: every point light's, and each triangle's integrated over a fine
// grid of its points.
@(private = "file")
mirror_exact :: proc(
	lights: []Hit_Mirror_Light,
	triangles: []Hit_Mirror_Triangle,
	p, n: [3]f32,
) -> (
	sum: [3]f32,
) {
	for l in lights {
		sum += mirror_point_light(l, p, n)
	}
	steps :: 200
	for tri in triangles {
		area := 0.5 * linalg.length(linalg.cross(tri.e1, tri.e2))
		cells := 0
		cell_sum: [3]f32
		for i in 0 ..< steps {
			for j in 0 ..< steps - i {
				a := (f32(i) + 1.0 / 3) / steps
				b := (f32(j) + 1.0 / 3) / steps
				cell_sum += mirror_triangle_light(tri, tri.p0 + tri.e1 * a + tri.e2 * b, p, n)
				cells += 1
			}
		}
		sum += cell_sum * (area / f32(cells))
	}
	return
}

// The hits' estimate is the light of every light in expectation, with the punctual lights and the emissive triangles
// mixed, with only one kind, with lights listed once or drawn, and with a one-sided triangle seen from behind, which
// gives nothing.
@(test)
the_hits_estimate_is_unbiased :: proc(t: ^testing.T) {
	r := rand.create(7)
	gen := rand.default_random_generator(&r)
	lights := []Hit_Mirror_Light {
		{position = {1, 1, 0}, range = 4, color = {1, 0.5, 0.2}},
		{position = {-1, 2, 1}, range = 6, color = {0.2, 0.4, 1}},
		{position = {0, 1.5, -2}, range = 5, color = {0.6, 0.6, 0.6}},
		{position = {3, 0.5, 0}, range = 4, color = {2, 2, 0.5}},
		{position = {-2, 0.8, -1}, range = 3, color = {0.3, 1, 0.3}},
		{position = {0.5, 3, 0.5}, range = 8, color = {1, 1, 1}},
	}
	lamp := Hit_Mirror_Triangle {
		p0       = {-0.5, 2, -0.5},
		e1       = {1, 0, 0},
		e2       = {0, 0, 1},
		radiance = {4, 3, 2},
	}
	// cross(e1, e2) is -y: it faces the floor below it.
	sign := Hit_Mirror_Triangle {
		p0        = {2, 0.5, -1},
		e1        = {0, 1, 0},
		e2        = {0, 0, 2},
		radiance  = {0.5, 2, 4},
		two_sided = true,
	}
	// It faces up, away from the point below it.
	behind := Hit_Mirror_Triangle {
		p0       = {-0.5, 1, -0.5},
		e1       = {0, 0, 1},
		e2       = {1, 0, 0},
		radiance = {9, 9, 9},
	}
	p := [3]f32{0, 0, 0}
	n := [3]f32{0, 1, 0}
	cases := []struct {
		name:      string,
		lights:    []Hit_Mirror_Light,
		triangles: []Hit_Mirror_Triangle,
		m:         int,
	} {
		{"mixed, drawn", lights, {lamp, sign}, 4},
		{"mixed, listed once", lights[:2], {lamp, sign}, 8},
		{"punctual only", lights, nil, 4},
		{"triangles only", nil, {lamp, sign}, 4},
		{"from behind", nil, {behind}, 4},
		{"empty cell", nil, nil, 4},
	}
	for c in cases {
		exact := mirror_exact(c.lights, c.triangles, p, n)
		runs :: 40000
		mean: [3]f32
		for _ in 0 ..< runs {
			mean += mirror_estimate(c.lights, c.triangles, c.m, p, n, &gen) / runs
		}
		for k in 0 ..< 3 {
			testing.expectf(
				t,
				abs(mean[k] - exact[k]) <= 0.02 * abs(exact[k]) + 1e-5,
				"%s: %v, not %v",
				c.name,
				mean,
				exact,
			)
		}
		free_all(context.temp_allocator)
	}
}

// The emitters' passes run on the compute queue and pass validation: a frame with no listed submesh scans and shades
// its jobs, a frame with one builds and scans its triangles too, and the frame's hit shading has room for the world
// probes', the split cascades' and the traced reflections' batches beside the emitters'.
@(test)
the_emitters_run_on_the_compute_queue_and_pass_validation :: proc(t: ^testing.T) {
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
		gpu_read_buffer             = null.read_buffer,
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
	probes := &r.gi.probes
	for p in ([]^Shader_Pipeline{&r.ray_scene.bin_pipeline, &r.ray_scene.fallback, &probes.reset, &probes.trace, &probes.light, &probes.screen, &probes.update, &r.gi.emitters.pipeline}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	r.ray_scene.accel = platform.gpu_create_accel(
		{kind = .Top, max_instances = 4, label = "test scene"},
	)
	defer ray_scene_destroy(&r.ray_scene, &platform)
	defer gi_probes_destroy(probes, &platform)
	defer gi_emitters_destroy(&r.gi.emitters, &platform)
	instances := platform.gpu_create_buffer(
		{size = 1024, usage = {.Storage}, label = "instances"},
		nil,
	)
	defer platform.gpu_destroy_buffer(instances)

	lamp := ecs.Entity(4)
	hit_instances := []Hit_Instance{{}, {mesh = 0, first = 0, count = 1}}
	hit_submeshes := []Hit_Submesh{{first_primitive = 0, primitive_count = 12, bin = 1}}
	keys := []Hit_Entry_Key{{entity = lamp, submesh = 0, pipeline = 0, shaded = true}}
	for frame in 0 ..< 3 {
		cache: Texture_Cache
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		f.gi = new(Gi_Frame, platform.frame_allocator)
		f.gi.settings = {
			technique = .Split_Cascades,
			level     = .Low,
		}
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(
			size_of(Frame_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		sf.instances = import_buffer(&g, instances)
		sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance) * len(hit_instances), 16)
		copy(sf.hit_instances.data, slice.to_bytes(hit_instances))
		sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh) * len(hit_submeshes), 16)
		copy(sf.hit_submeshes.data, slice.to_bytes(hit_submeshes))
		sf.hit_instance_count = len(hit_instances)
		sf.hit_bins = {0, 1}
		sf.hit_keys = keys
		testing.expect(t, request_ray_scene(f))
		f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)
		if frame == 1 {
			// The scan found the lamp bright.
			change_emitter(
				&r.gi.emitters,
				Emitter_Scanned{{key = {lamp, 0}, signature = {0, 0, 12}}, f32(4)},
			)
		}
		ef := add_gi_emitter_passes(f)
		testing.expectf(t, ef != nil, "frame %d: no emitters", frame)
		if ef == nil {
			break
		}
		testing.expect(t, ef.job_count > 0)
		testing.expect_value(t, ef.triangles, frame == 0 ? 0 : 12)
		testing.expect(t, int(f.ray_scene.batches) + 3 <= MAX_HIT_BATCHES)
		p := add_compute_pass(&g, "hit light", proc(_: ^Pass_Context) {}, nil, queue = .Compute)
		read(&g, p, ef.samples)
		read(&g, p, ef.pool)
		keep_pass(&g, p)
		testing.expectf(t, execute(&g), "frame %d did not execute", frame)
		cache_destroy(&cache, &platform)
		free_all(platform.frame_allocator)
	}
	testing.expect_value(t, len(r.gi.emitters.listed), 1)
}

// Each translucent record whose hit pass is ready takes a range of the pool, which the transmittance's refresh reads
// in turn and hit_transmitters gives the shadow rays; a record that goes, or changes its material, frees its range.
@(test)
a_translucent_submesh_keeps_its_transmittance_in_the_pool :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	e: Gi_Emitters
	defer delete(e.listed)
	defer delete(e.transmitters)
	defer delete(e.free)
	append(&e.free, Pool_Range{0, MAX_EMITTER_TRIANGLES})
	window := ecs.Entity(7)
	instances := []Hit_Instance{{}, {mesh = 1, first = 0, count = 2}}
	submeshes := []Hit_Submesh {
		{first_primitive = 0, primitive_count = 10},
		{first_primitive = 10, primitive_count = 4, bin = HIT_TRANSLUCENT | 3},
	}
	keys := []Hit_Entry_Key {
		{entity = window, submesh = 0, pipeline = 1, shaded = true},
		{entity = window, submesh = 1, pipeline = 2, translucent = true},
	}
	plan := plan_gi_emitters(&e, instances, submeshes, keys, false, 0, allocator)
	testing.expect_value(t, len(e.transmitters), 1)
	testing.expect_value(t, plan.hit_transmitters[0], ~u32(0))
	testing.expect_value(t, plan.hit_transmitters[1], 0)
	testing.expect_value(t, len(plan.jobs), 4)
	for job, k in plan.jobs {
		testing.expect_value(t, job, Emitter_Job{1, 10 + u32(k), u32(k), job.seed})
	}
	testing.expect_value(t, plan.next_transmit, 0)
	testing.expect_value(t, e.free[0], Pool_Range{4, MAX_EMITTER_TRIANGLES - 4})

	// The same record keeps its range from frame to frame.
	plan = plan_gi_emitters(&e, instances, submeshes, keys, false, 1, allocator)
	testing.expect_value(t, plan.hit_transmitters[1], 0)

	// Another material frees it, and the record takes a new one.
	keys[1].pipeline = 5
	plan = plan_gi_emitters(&e, instances, submeshes, keys, false, 2, allocator)
	testing.expect_value(t, len(e.transmitters), 1)
	testing.expect_value(t, plan.hit_transmitters[1], 0)

	// A record whose hit pass is not ready has none, and its range is free again.
	keys[1].translucent = false
	plan = plan_gi_emitters(&e, instances, submeshes, keys, false, 3, allocator)
	testing.expect_value(t, len(e.transmitters), 0)
	testing.expect_value(t, plan.hit_transmitters[1], ~u32(0))
	testing.expect_value(t, len(plan.jobs), 0)
	testing.expect_value(t, e.free[0], Pool_Range{0, MAX_EMITTER_TRIANGLES})
}
