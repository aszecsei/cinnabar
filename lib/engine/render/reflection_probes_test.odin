package render

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"

import core "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// cube_direction_of matches cube_direction in sky_directions.hlsli: the direction of a point of a cube's face, with x
// and y from -1 to 1 and y down the face.
@(private = "file")
cube_direction_of :: proc(face: u32, p: [2]f32) -> [3]f32 {
	switch face {
	case 0:
		return {1, -p.y, -p.x}
	case 1:
		return {-1, -p.y, p.x}
	case 2:
		return {p.x, 1, p.y}
	case 3:
		return {p.x, -1, -p.y}
	case 4:
		return {p.x, -p.y, 1}
	}
	return {-p.x, -p.y, -1}
}

// Each face's view puts the point that the cube's texel looks along at that texel's place on the screen, so a face
// drawn into the source cube's layer lines up with what the cube samples. The views are square and 90°, and look from
// the probe.
@(test)
the_capture_faces_line_up_with_the_cube :: proc(t: ^testing.T) {
	center := [3]f32{3, -2, 5}
	for face in u32(0) ..< 6 {
		m := reflection_probe_face_projection(center, face)
		for p in ([][2]f32{{0, 0}, {0.5, -0.25}, {-0.9, 0.9}, {0.99, 0.99}}) {
			d := linalg.normalize(cube_direction_of(face, p))
			point := center + d * 7
			clip := m * [4]f32{point.x, point.y, point.z, 1}
			ndc := clip.xy / clip.w
			// The screen's y is down, as a cube face's is.
			testing.expectf(
				t,
				abs(ndc.x - p.x) < 1e-4 && abs(-ndc.y - p.y) < 1e-4,
				"face %v at %v: %v",
				face,
				p,
				ndc,
			)
			// Reversed depth: nearer is greater, and the near plane is at 1.
			testing.expect(t, clip.z / clip.w > 0 && clip.z / clip.w < 1)
		}
		axes := REFLECTION_PROBE_FACES
		right, up, forward := axes[face][0], axes[face][1], axes[face][2]
		testing.expectf(
			t,
			linalg.cross(right, up) == forward,
			"face %v: right × up is not forward",
			face,
		)
	}
}

@(private = "file")
probe_candidate :: proc(
	index: u32,
	priority: i32,
	distance: f32,
	update := Reflection_Probe_Update.On_Load,
) -> Reflection_Probe_Candidate {
	return {
		entity = ecs.Entity(index + 1),
		key = {
			position = ecs.position_offset({}, {distance, 0, 0}),
			rotation = 1,
			scale = 1,
			probe = {priority = priority, update = update},
		},
		distance2 = distance * distance,
	}
}

@(private = "file")
probe_slot_of :: proc(rp: ^Reflection_Probes, e: ecs.Entity) -> int {
	for &s, i in rp.slots[:rp.params.probes] {
		if s.used && s.entity == e {
			return i
		}
	}
	return -1
}

// The ranked probes take the slots: the highest priority, then the nearest. A probe past the slots keeps its own until
// a ranked probe needs it, and a probe that is gone gives its slot up.
@(test)
the_slots_go_to_the_highest_priority_then_the_nearest :: proc(t: ^testing.T) {
	rp := new(Reflection_Probes)
	defer free(rp)
	rp.params.probes = 2
	rp.frame = 1
	near_low := probe_candidate(0, 0, 1)
	far_high := probe_candidate(1, 5, 50)
	middle := probe_candidate(2, 0, 10)
	candidates := []Reflection_Probe_Candidate{near_low, far_high, middle}
	rank_reflection_probes(candidates)
	testing.expect_value(t, candidates[0].entity, far_high.entity)
	testing.expect_value(t, candidates[1].entity, near_low.entity)
	assign_reflection_probe_slots(rp, candidates, 2)
	testing.expect(
		t,
		probe_slot_of(rp, far_high.entity) >= 0 && probe_slot_of(rp, near_low.entity) >= 0,
	)
	testing.expect_value(t, probe_slot_of(rp, middle.entity), -1)

	// The middle probe comes nearer than the near one: it takes the near one's slot.
	rp.frame = 2
	middle.distance2 = 0.25
	candidates = {near_low, far_high, middle}
	rank_reflection_probes(candidates)
	assign_reflection_probe_slots(rp, candidates, 2)
	testing.expect(t, probe_slot_of(rp, middle.entity) >= 0)
	testing.expect_value(t, probe_slot_of(rp, near_low.entity), -1)

	// The high one is gone: its slot frees, and the near one takes it again.
	rp.frame = 3
	candidates = {near_low, middle}
	rank_reflection_probes(candidates)
	assign_reflection_probe_slots(rp, candidates, 2)
	testing.expect(
		t,
		probe_slot_of(rp, near_low.entity) >= 0 && probe_slot_of(rp, middle.entity) >= 0,
	)
	testing.expect_value(t, probe_slot_of(rp, far_high.entity), -1)
}

// The captures take turns by a budget of faces a frame: the On_Load probes first, the nearest first, then the others
// that have no cube, then an On_Change probe that moved, and the Realtime ones in turn. A finished capture takes the
// spare cube, and no two slots ever hold the same cube.
@(test)
the_captures_take_turns_within_the_budget :: proc(t: ^testing.T) {
	rp := new(Reflection_Probes)
	defer free(rp)
	rp.params = REFLECTION_PARAMS[.Probes][.Medium]
	rp.params.probes = 4
	rp.spare = 4
	faces := u32(2)
	load_far := probe_candidate(0, 0, 20, .On_Load)
	load_near := probe_candidate(1, 0, 5, .On_Load)
	change := probe_candidate(2, 0, 1, .On_Change)
	realtime := probe_candidate(3, 0, 2, .Realtime)
	frame :: proc(
		rp: ^Reflection_Probes,
		candidates: []Reflection_Probe_Candidate,
		faces: u32,
	) -> (
		e: ecs.Entity,
		first, count: u32,
		ok: bool,
	) {
		rp.frame += 1
		cs := make([]Reflection_Probe_Candidate, len(candidates), context.temp_allocator)
		copy(cs, candidates)
		rank_reflection_probes(cs)
		assign_reflection_probe_slots(rp, cs, int(rp.params.probes))
		slot: int
		slot, first, count, ok = plan_reflection_probe_capture(rp, faces)
		if ok {
			e = rp.slots[slot].entity
			advance_reflection_probe_capture(rp, count)
		}
		return
	}
	cubes_are_apart :: proc(t: ^testing.T, rp: ^Reflection_Probes) {
		for &a, i in rp.slots[:rp.params.probes] {
			testing.expect(t, !a.used || a.cube != rp.spare, "a slot holds the spare cube")
			for &b in rp.slots[i + 1:rp.params.probes] {
				testing.expect(
					t,
					!a.used || !b.used || a.cube < 0 || a.cube != b.cube,
					"two slots hold one cube",
				)
			}
		}
	}
	all := []Reflection_Probe_Candidate{load_far, load_near, change, realtime}
	order := []ecs.Entity{load_near.entity, load_far.entity, change.entity, realtime.entity}
	for want in order {
		for k in u32(0) ..< 3 {
			e, first, count, ok := frame(rp, all, faces)
			testing.expect(t, ok)
			testing.expect_value(t, e, want)
			testing.expect_value(t, first, k * faces)
			testing.expect_value(t, count, faces)
		}
		cubes_are_apart(t, rp)
		testing.expect(t, rp.slots[probe_slot_of(rp, want)].cube >= 0)
	}
	// Every probe has a cube: only the Realtime one captures again, over and over.
	for _ in 0 ..< 6 {
		e, _, _, ok := frame(rp, all, faces)
		testing.expect(t, ok)
		testing.expect_value(t, e, realtime.entity)
	}
	cubes_are_apart(t, rp)

	// The On_Change probe moves: it captures again, and moving during its capture starts it over.
	moved := all
	moved[2].key.position = ecs.position_offset({}, {1, 1, 0})
	e, first, _, _ := frame(rp, moved, faces)
	testing.expect_value(t, e, change.entity)
	testing.expect_value(t, first, 0)
	moved[2].key.probe.intensity = 2
	e, first, _, _ = frame(rp, moved, faces)
	testing.expect_value(t, e, change.entity)
	testing.expect_value(t, first, 0)
	for _ in 0 ..< 2 {
		frame(rp, moved, faces)
	}
	testing.expect_value(t, rp.slots[probe_slot_of(rp, change.entity)].captured, moved[2].key)
	// Back to the Realtime probe, which has waited longest.
	e, _, _, _ = frame(rp, moved, faces)
	testing.expect_value(t, e, realtime.entity)
	cubes_are_apart(t, rp)

	// A probe that is gone mid-capture ends the capture, and its cube frees for another.
	rp.capture = {}
	without := []Reflection_Probe_Candidate{moved[0], moved[1], moved[2]}
	frame(rp, without, faces)
	testing.expect_value(t, probe_slot_of(rp, realtime.entity), -1)
	cubes_are_apart(t, rp)
	// A budget of 6 captures a probe in a frame.
	fresh := probe_candidate(9, 0, 3, .On_Load)
	count: u32
	e, first, count, _ = frame(
		rp,
		[]Reflection_Probe_Candidate{moved[0], moved[1], moved[2], fresh},
		6,
	)
	testing.expect_value(t, e, fresh.entity)
	testing.expect(t, first == 0 && count == 6)
	testing.expect(t, rp.slots[probe_slot_of(rp, fresh.entity)].cube >= 0)
	cubes_are_apart(t, rp)
}

// The records are of the probes with a cube, highest priority first, then the smallest box, then by slot, so ties keep
// their order; a probe without its first capture has none. A box at 0 takes its default, scaled by the pose, and the
// projection box is 0 without box projection.
@(test)
the_records_are_in_priority_order :: proc(t: ^testing.T) {
	rp := new(Reflection_Probes)
	defer free(rp)
	rp.params.probes = 5
	slot :: proc(
		rp: ^Reflection_Probes,
		i: int,
		cube: i32,
		priority: i32,
		extent: [3]f32,
		scale: [3]f32 = 1,
	) {
		rp.slots[i] = {
			used = true,
			entity = ecs.Entity(i + 1),
			cube = cube,
			key = {
				position = ecs.position_offset({}, {f32(i), 0, 0}),
				rotation = 1,
				scale = scale,
				probe = {priority = priority, extent = extent},
			},
		}
	}
	slot(rp, 0, 3, 0, {4, 4, 4})
	slot(rp, 1, 0, 0, {4, 4, 4})
	slot(rp, 2, 1, 2, {10, 10, 10})
	slot(rp, 3, -1, 9, {1, 1, 1})
	slot(rp, 4, 2, 0, {1, 1, 1})
	records := reflection_probe_records(rp, {}, context.temp_allocator)
	testing.expect_value(t, len(records), 4)
	cubes := [4]u32{1, 2, 3, 0}
	for record, k in records {
		testing.expect_value(t, record.cube, cubes[k])
	}
	testing.expect_value(t, records[0].center, [3]f32{2, 0, 0})
	testing.expect_value(t, records[0].intensity, 1)

	// Defaults and scale.
	rp.slots[0].key.probe = {
		box_projection    = true,
		projection_extent = {0, 3, 0},
		blend_distance    = 100,
		intensity         = 2,
	}
	rp.slots[0].key.scale = {2, 1, -1}
	extent, projection := reflection_probe_boxes(rp.slots[0].key)
	testing.expect_value(
		t,
		extent,
		[3]f32{2 * DEFAULT_PROBE_EXTENT, DEFAULT_PROBE_EXTENT, DEFAULT_PROBE_EXTENT},
	)
	testing.expect_value(t, projection, [3]f32{2 * DEFAULT_PROBE_EXTENT, 3, DEFAULT_PROBE_EXTENT})
	records = reflection_probe_records(rp, {}, context.temp_allocator)
	for record in records {
		if record.cube == 3 {
			testing.expect_value(t, record.projection, projection)
			testing.expect_value(t, record.blend, f32(DEFAULT_PROBE_EXTENT))
			testing.expect_value(t, record.intensity, 2)
		} else {
			testing.expect_value(t, record.projection, [3]f32{})
		}
	}
}

// A probe reaches a cluster's box in view space where the box around its turned influence box overlaps it.
@(test)
probes_bin_into_the_boxes_that_they_reach :: proc(t: ^testing.T) {
	right, up, forward := [3]f32{1, 0, 0}, [3]f32{0, 1, 0}, [3]f32{0, 0, 1}
	record := Reflection_Probe_Record {
		center = {0, 0, 10},
		axes   = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}},
		extent = {1, 1, 1},
	}
	testing.expect(
		t,
		probe_reaches_box(record, {}, right, up, forward, {-0.5, -0.5, 9}, {0.5, 0.5, 9.5}),
	)
	testing.expect(
		t,
		probe_reaches_box(record, {}, right, up, forward, {0.9, 0.9, 10.9}, {2, 2, 12}),
	)
	testing.expect(t, !probe_reaches_box(record, {}, right, up, forward, {1.1, -1, 9}, {2, 1, 11}))
	testing.expect(
		t,
		!probe_reaches_box(record, {}, right, up, forward, {-1, -1, 11.5}, {1, 1, 20}),
	)
	// Turned 45° about y, its corners reach farther along x.
	s := math.sqrt(f32(0.5))
	record.axes = {{s, 0, -s, 0}, {0, 1, 0, 0}, {s, 0, s, 0}}
	testing.expect(
		t,
		probe_reaches_box(record, {}, right, up, forward, {1.2, -1, 9.9}, {2, 1, 10.1}),
	)
	// From another eye, as a capture's face sees it: the box is relative to that eye.
	record.axes = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	testing.expect(
		t,
		probe_reaches_box(
			record,
			{0, 0, 10},
			right,
			up,
			forward,
			{-0.5, -0.5, -0.5},
			{0.5, 0.5, 0.5},
		),
	)
	testing.expect(
		t,
		!probe_reaches_box(
			record,
			{0, 0, 20},
			right,
			up,
			forward,
			{-0.5, -0.5, -0.5},
			{0.5, 0.5, 0.5},
		),
	)
}

// What one frame of the probes did: their stats and their live passes.
@(private = "file")
Probe_Run :: struct {
	passes:    map[string]int,
	// The transient textures that the faces drew into.
	transient: int,
	stats:     Reflection_Probe_Stats,
	frame:     Reflection_Probe_Frame,
}

@(private = "file")
run_probe_frame :: proc(
	t: ^testing.T,
	r: ^Renderer,
	cache: ^Texture_Cache,
	w: ^ecs.World,
	settings: Reflection_Settings,
) -> (
	run: Probe_Run,
) {
	platform := r.platform
	// The last frame's memory, which its run held, goes.
	free_all(platform.frame_allocator)
	g := begin(platform, cache)
	f := new(Frame, platform.frame_allocator)
	view := View {
		rotation     = 1,
		vertical_fov = 1,
		near         = 0.1,
	}
	f^ = {
		renderer        = r,
		graph           = &g,
		view            = view,
		size            = {64, 32},
		view_projection = view_projection(view, 2),
	}
	f.lights = new(Light_Frame, platform.frame_allocator)
	f.lights.records = make([dynamic]Light_Record, platform.frame_allocator)
	f.lights.casts = make([dynamic]bool, platform.frame_allocator)
	append(
		&f.lights.records,
		Light_Record{type = .Directional, direction = {0, -1, 0}, shadow = -1, mask = -1},
	)
	append(&f.lights.casts, true)
	append(
		&f.lights.records,
		Light_Record{type = .Point, position = {0, 1, 0}, range = 5, shadow = -1, mask = -1},
	)
	append(&f.lights.casts, false)
	f.lights.directional_count = 1
	f.shadows = new(Shadow_Frame, platform.frame_allocator)
	f.shadows.params = SHADOW_PARAMS[.High]
	f.shadows.views = make([dynamic]Shadow_View, platform.frame_allocator)
	f.shadows.matrices = make([dynamic]matrix[4, 4]f32, platform.frame_allocator)
	f.shadows.planes = make([dynamic][6][4]f32, platform.frame_allocator)
	f.shadows.eyes = make([dynamic][4]f32, platform.frame_allocator)
	f.shadows.viewports = make([dynamic][4]u32, platform.frame_allocator)
	begin_reflection_probes(f, w, nil, settings, DEFAULT_AMBIENT)
	if pf := f.reflection_probes; pf != nil && pf.capturing {
		add_reflection_probe_shadow(f, f.shadows, 0, max_shadow_views(f.shadows.params))
	}
	upload_reflection_probe_lights(f)
	add_reflection_probe_passes(f)
	p := add_compute_pass(&g, "forward", proc(_: ^Pass_Context) {}, nil)
	declare_reflection_probe_reads(f, p)
	if f.reflection_probes != nil {
		read(&g, p, f.reflection_probes.cubes)
	}
	keep_pass(&g, p)
	if f.reflection_probes != nil {
		run.frame = f.reflection_probes^
	}
	run.stats = reflection_probe_stats(r)
	for node in g.textures {
		if !node.imported && strings.has_prefix(node.desc.label, "reflection probe") {
			run.transient += 1
		}
	}
	testing.expect(t, execute(&g), "the frame did not execute")
	run.passes = make(map[string]int, platform.frame_allocator)
	for node in g.passes {
		if node.live {
			run.passes[node.name] += 1
		}
	}
	return
}

// A frame captures its budget of faces: each face's clusters, prepass, forward pass and copy, then with the last face
// the source's mips and the prefilter. The capture has its own shadow view, its lights have no mask and the directional
// one takes that view. A frame with nothing to capture adds no passes, and Off frees the cubes.
@(test)
a_capture_draws_its_faces_in_the_graph :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		heap_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
		gpu_frame_target = null.frame_target,
		gpu_submit = null.submit,
		gpu_upload = null.upload,
		gpu_create_texture = null.create_texture,
		gpu_create_texture_view = null.create_texture_view,
		gpu_destroy_texture = null.destroy_texture,
		gpu_create_buffer = null.create_buffer,
		gpu_destroy_buffer = null.destroy_buffer,
		gpu_create_sampler = null.create_sampler,
		gpu_destroy_sampler = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline = null.destroy_pipeline,
	}
	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	register_components(&w.registry)
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	reflection_probes_init(&r.reflection_probes, r, w)
	defer reflection_probes_destroy(&r.reflection_probes, r)
	rp := &r.reflection_probes
	for p in ([]^Shader_Pipeline{&rp.face, &rp.downsample, &r.sky.cube.prefilter, &r.lights.pipeline}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test"})
	}
	defer destroy_shader_pipeline(&r.sky.cube.prefilter, &platform)
	defer destroy_shader_pipeline(&r.lights.pipeline, &platform)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	probe := ecs.spawn(w)
	ecs.add(
		w,
		probe,
		ecs.Transform{position = ecs.position_offset({}, {0, 1.5, 0}), rotation = 1, scale = 1},
	)
	ecs.add(w, probe, Reflection_Probe{extent = {3, 1.5, 4}, box_projection = true})
	medium := Reflection_Settings {
		technique = .Probes,
		level     = .Medium,
	}

	// Medium captures two faces a frame, so three frames capture the probe.
	for k in u32(0) ..< 3 {
		run := run_probe_frame(t, r, &cache, w, medium)
		testing.expect(t, run.frame.capturing)
		testing.expect_value(t, run.frame.first_face, 2 * k)
		testing.expect_value(t, run.passes["reflection probe prepass"], 2)
		testing.expect_value(t, run.passes["reflection probe face"], 2)
		testing.expect_value(t, run.passes["reflection probe copy"], 2)
		testing.expect_value(t, run.passes["reflection probe face clusters"], 1)
		// The source's mips after mip 0, a pass each.
		testing.expect_value(
			t,
			run.passes["reflection probe downsample"],
			k == 2 ? int(sky_cube_mips(128)) - 1 : 0,
		)
		testing.expect_value(t, run.passes["reflection probe prefilter"], k == 2 ? 1 : 0)
		testing.expect_value(
			t,
			run.stats,
			Reflection_Probe_Stats{probes = 1, slots = 0, capacity = 32, faces = 2},
		)
		testing.expect_value(t, run.frame.shadow_view, 0)
		testing.expect_value(t, len(run.frame.records), 0)
	}
	testing.expect(t, rp.slots[0].cube >= 0)

	// The probe has its cube: its record goes out, and On_Load never captures again.
	run := run_probe_frame(t, r, &cache, w, medium)
	testing.expect(t, !run.frame.capturing)
	testing.expect_value(t, len(run.frame.records), 1)
	testing.expect_value(
		t,
		run.stats,
		Reflection_Probe_Stats{probes = 1, slots = 1, capacity = 32, faces = 0},
	)
	testing.expect_value(t, run.passes["reflection probe prepass"], 0)
	testing.expect_value(t, run.frame.records[0].center, [3]f32{0, 1.5, 0})
	testing.expect_value(t, run.frame.records[0].projection, [3]f32{3, 1.5, 4})

	// The screen-space reflections keep the probes at the same level, with the probes' parameters, which fill in where
	// the rays find nothing: the cube stays.
	run = run_probe_frame(t, r, &cache, w, {technique = .Screen, level = .Medium})
	testing.expect(t, !run.frame.capturing)
	testing.expect_value(t, len(run.frame.records), 1)
	testing.expect_value(t, rp.params, REFLECTION_PARAMS[.Probes][.Medium])

	// A level of another size starts over, and Off frees the cubes.
	run = run_probe_frame(t, r, &cache, w, {technique = .Probes, level = .Ultra})
	testing.expect(t, run.frame.capturing && run.frame.finish)
	testing.expect_value(t, run.passes["reflection probe copy"], 6)
	// The six faces share one set of targets, so they fit the graph's cache.
	testing.expect_value(t, run.transient, 6)
	run = run_probe_frame(t, r, &cache, w, {technique = .Off, off = true})
	testing.expect(t, !rp.made && rp.cubes.texture == {})
	testing.expect_value(t, run.stats, Reflection_Probe_Stats{})
}

// A capture face's constants: its own projection, clusters and lights, a linear color without screen-space light, fog
// or probes, and every depth in the probe's own shadow view, at the camera's level of detail.
@(test)
a_capture_face_has_its_own_constants :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	f := new(Frame)
	defer free(f)
	pf := new(Reflection_Probe_Frame)
	defer free(pf)
	f.renderer = r
	f.reflection_probes = pf
	f.lod_error = 1
	pf^ = {
		params     = REFLECTION_PARAMS[.Probes][.High],
		capturing  = true,
		center     = {1, 2, 3},
		first_face = 2,
		face_count = 3,
		first_view = 7,
	}
	_, before := reflection_probe_view(f, 6)
	face, ok := reflection_probe_view(f, 8)
	_, after := reflection_probe_view(f, 10)
	testing.expect(t, !before && ok && !after)
	testing.expect_value(t, face, 3)
	c := Frame_Constants {
		gi                     = 1,
		fog                    = 1,
		debug_view             = 3,
		reflection_probe_count = 4,
		cascade_splits         = {1, 2, 3, 4},
		lod_scale              = 9,
	}
	view: Cull_View
	reflection_probe_view_constants(f, &c, &view, face)
	m := reflection_probe_face_projection(pf.center, face)
	testing.expect_value(t, c.view_projection, m)
	testing.expect_value(t, c.cluster_view_projection, m)
	testing.expect(
		t,
		c.gi == 0 && c.fog == 0 && c.debug_view == 0 && c.reflection_probe_count == 0,
	)
	testing.expect_value(t, c.capture, 1)
	testing.expect_value(t, c.screen_size, [2]f32{128, 128})
	testing.expect_value(t, c.cull_eye, [4]f32{1, 2, 3, 1})
	testing.expect_value(t, c.cascade_splits[0], math.F32_MAX)
	testing.expect_value(t, c.lod_scale, 9)
	testing.expect_value(t, view.flags, 0)
	testing.expect_value(t, view.planes, frustum_planes_6(m))
}

// Each level's cubes, with the spare and the source, and the memory that the docs give.
@(test)
the_probe_levels_fit_their_memory :: proc(t: ^testing.T) {
	for level in Quality_Level {
		p := REFLECTION_PARAMS[.Probes][level]
		testing.expect(t, p.probes > 0 && p.probes <= MAX_REFLECTION_PROBES)
		testing.expect(t, p.faces >= 1 && p.faces <= 6)
		testing.expect(t, p.rough_start < p.rough_end)
		testing.expect(t, gpu.format_size(p.format) == 4)
	}
	testing.expect_value(
		t,
		reflection_probe_memory(REFLECTION_PARAMS[.Probes][.Low]),
		u64(6 * (64 * 64 + 32 * 32 + 16 * 16 + 8 * 8 + 4 * 4) * 4 * 18),
	)
	testing.expect(t, reflection_probe_memory(REFLECTION_PARAMS[.Probes][.Ultra]) < 140 << 20)
}
