package render

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import core "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
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

// frame runs a frame of the captures' turns, whose inputs are complete or not: it gives the probes their slots, plans
// the capture, and records the faces as drawn. It gives the probe that captured.
@(private = "file")
frame :: proc(
	rp: ^Reflection_Probes,
	candidates: []Reflection_Probe_Candidate,
	faces: u32,
	complete := true,
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
	slot, first, count, ok = plan_reflection_probe_capture(rp, faces, complete)
	if ok {
		e = rp.slots[slot].entity
		advance_reflection_probe_capture(rp, count, complete)
	}
	return
}

// cube_of is a probe's cube, nil without a slot or a capture.
@(private = "file")
cube_of :: proc(rp: ^Reflection_Probes, e: ecs.Entity) -> Maybe(Reflection_Probe_Cube) {
	slot := probe_slot_of(rp, e)
	return slot >= 0 ? rp.slots[slot].cube : nil
}

@(private = "file")
cubes_are_apart :: proc(t: ^testing.T, rp: ^Reflection_Probes) {
	for &a, i in rp.slots[:rp.params.probes] {
		x, has_x := a.cube.?
		if !a.used || !has_x {
			continue
		}
		testing.expect(t, x.index != rp.spare, "a slot holds the spare cube")
		for &b in rp.slots[i + 1:rp.params.probes] {
			y, has_y := b.cube.?
			testing.expect(t, !b.used || !has_y || x.index != y.index, "two slots hold one cube")
		}
	}
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
		testing.expect(t, cube_of(rp, want) != nil)
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
	testing.expect_value(t, (cube_of(rp, change.entity).?).key, moved[2].key)
	// Back to the Realtime probe, which has waited longest.
	e, _, _, _ = frame(rp, moved, faces)
	testing.expect_value(t, e, realtime.entity)
	cubes_are_apart(t, rp)

	// A probe that is gone mid-capture ends the capture, and its cube frees for another.
	rp.capture = nil
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
	testing.expect(t, cube_of(rp, fresh.entity) != nil)
	cubes_are_apart(t, rp)
}

// A forced probe takes the next capture, before an On_Load probe without a cube, and ends a capture in flight that is
// not forced, which starts over once the forced ones are done. A forced capture draws its six faces in a frame at a
// budget of one, and capturing every probe takes them one a frame, the nearest first.
@(test)
a_forced_capture_goes_first_and_takes_one_frame :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	rp := &r.reflection_probes
	rp.params = REFLECTION_PARAMS[.Probes][.Low]
	rp.params.probes = 3
	rp.spare = 3
	faces := u32(1)
	near := probe_candidate(0, 0, 1, .On_Load)
	far := probe_candidate(1, 0, 9, .On_Load)
	all := []Reflection_Probe_Candidate{near, far}
	// The near probe captures by the budget, a face a frame.
	for k in u32(0) ..< 6 {
		e, first, count, _ := frame(rp, all, faces)
		testing.expect_value(t, e, near.entity)
		testing.expect(t, first == k && count == 1)
	}
	// The far one starts; forcing the near one ends it, and the near one draws its six faces in a frame.
	e, _, _, _ := frame(rp, all, faces)
	testing.expect_value(t, e, far.entity)
	testing.expect(t, capture_reflection_probe(r, near.entity))
	first, count: u32
	e, first, count, _ = frame(rp, all, faces)
	testing.expect_value(t, e, near.entity)
	testing.expect(t, first == 0 && count == 6)
	testing.expect(t, !rp.slots[probe_slot_of(rp, near.entity)].forced)
	// The far one starts over.
	e, first, count, _ = frame(rp, all, faces)
	testing.expect_value(t, e, far.entity)
	testing.expect(t, first == 0 && count == 1)
	cubes_are_apart(t, rp)

	// Capture all: one probe a frame. The far one's capture in flight starts over, forced, so it draws all six faces
	// after the force; then the near one.
	testing.expect_value(t, capture_reflection_probes(r), 2)
	e, first, count, _ = frame(rp, all, faces)
	testing.expect_value(t, e, far.entity)
	testing.expect(t, first == 0 && count == 6)
	testing.expect(t, cube_of(rp, far.entity) != nil)
	e, first, count, _ = frame(rp, all, faces)
	testing.expect_value(t, e, near.entity)
	testing.expect(t, first == 0 && count == 6)
	cubes_are_apart(t, rp)
	// Both On_Load probes have their cubes, so nothing captures.
	_, _, _, ok := frame(rp, all, faces)
	testing.expect(t, !ok)
	// A forced capture that its probe's change starts over stays forced.
	testing.expect(t, capture_reflection_probe(r, far.entity))
	slot, _, _, _ := plan_reflection_probe_capture(rp, faces, true)
	testing.expect_value(t, rp.slots[slot].entity, far.entity)
	rp.slots[slot].key.probe.intensity = 3
	_, first, count, _ = plan_reflection_probe_capture(rp, faces, true)
	testing.expect(t, first == 0 && count == 6)

	// Forcing the probe whose capture is in flight starts it over, so no face that it drew before the force counts.
	rp.capture = nil
	rp.slots[slot].forced = false
	all[1].key.probe.update = .Realtime
	e, first, count, _ = frame(rp, all, faces)
	testing.expect(t, e == far.entity && first == 0 && count == 1)
	testing.expect(t, capture_reflection_probe(r, far.entity))
	testing.expect_value(t, (rp.capture.?).faces, 0)
	e, first, count, _ = frame(rp, all, faces)
	testing.expect(t, e == far.entity && first == 0 && count == 6)
}

// The editor's helpers take the boxes from the probe and the entity's scale, as the records do: 0 is the default, the
// projection box defaults to the influence box, and the fade is no more than the smallest half size.
@(test)
the_boxes_come_from_the_probe_and_the_scale :: proc(t: ^testing.T) {
	extent, projection := reflection_probe_extents({extent = {2, 0, 1}}, {2, -1, 3})
	testing.expect_value(t, extent, [3]f32{4, DEFAULT_PROBE_EXTENT, 3})
	testing.expect_value(t, projection, extent)
	_, projection = reflection_probe_extents({projection_extent = {1, 0, 2}}, {2, 1, 1})
	testing.expect_value(t, projection, [3]f32{2, DEFAULT_PROBE_EXTENT, 2})
	testing.expect_value(t, reflection_probe_blend({blend_distance = 10}, {4, 2, 3}), 2)
	testing.expect_value(t, reflection_probe_blend({blend_distance = -1}, {4, 2, 3}), 0)
}

// A capture whose inputs were not complete is provisional. Its probe does not capture again while the frames' inputs
// stay incomplete; once a frame's are complete, it captures again after the probes with no cube and before an On_Change
// probe whose key changed. A capture that one incomplete frame drew a share of is provisional too.
@(test)
a_provisional_capture_takes_its_turn_once_the_inputs_are_complete :: proc(t: ^testing.T) {
	rp := new(Reflection_Probes)
	defer free(rp)
	rp.params = REFLECTION_PARAMS[.Probes][.Medium]
	rp.params.probes = 4
	rp.spare = 4
	faces := u32(2)
	near := probe_candidate(0, 0, 1, .On_Load)
	far := probe_candidate(1, 0, 10, .On_Load)
	change := probe_candidate(2, 0, 0.5, .On_Change)
	captures :: proc(
		t: ^testing.T,
		rp: ^Reflection_Probes,
		candidates: []Reflection_Probe_Candidate,
		faces: u32,
		want: ecs.Entity,
		complete: bool,
		loc := #caller_location,
	) {
		for k in u32(0) ..< 3 {
			e, first, _, ok := frame(rp, candidates, faces, complete)
			testing.expect(t, ok, loc = loc)
			testing.expect_value(t, e, want, loc = loc)
			testing.expect_value(t, first, k * faces, loc = loc)
		}
		cube, captured := cube_of(rp, want).?
		testing.expect(t, captured, loc = loc)
		testing.expect_value(t, cube.complete, complete, loc = loc)
	}
	idle :: proc(
		t: ^testing.T,
		rp: ^Reflection_Probes,
		candidates: []Reflection_Probe_Candidate,
		faces: u32,
		complete: bool,
		loc := #caller_location,
	) {
		e, _, _, ok := frame(rp, candidates, faces, complete)
		testing.expectf(t, !ok, "%v captured", e, loc = loc)
	}
	all := []Reflection_Probe_Candidate{near, far, change}

	// While the level streams in, the On_Load probes capture, and their captures are provisional.
	captures(t, rp, all, faces, near.entity, false)
	captures(t, rp, all, faces, far.entity, false)
	// Once the inputs are complete, the probe with no cube still comes first.
	captures(t, rp, all, faces, change.entity, true)
	// While the inputs are not complete, the provisional probes wait.
	for _ in 0 ..< 3 {
		idle(t, rp, all, faces, false)
	}

	// The On_Change probe moves. With complete inputs, the provisional probes come first, the nearest first, then the
	// probe that moved.
	moved := []Reflection_Probe_Candidate{near, far, change}
	moved[2].key.position = ecs.position_offset({}, {0, 2, 0})
	captures(t, rp, moved, faces, near.entity, true)
	captures(t, rp, moved, faces, far.entity, true)
	captures(t, rp, moved, faces, change.entity, true)
	// Every capture is complete, so none captures again: a probe whose inputs are complete captures once.
	idle(t, rp, moved, faces, true)
	idle(t, rp, moved, faces, false)
	cubes_are_apart(t, rp)

	// One incomplete frame of three makes the capture provisional, and it waits for a complete frame to capture again.
	moved[2].key.position = ecs.position_offset({}, {0, 3, 0})
	for complete in ([]bool{true, false, true}) {
		e, _, _, _ := frame(rp, moved, faces, complete)
		testing.expect_value(t, e, change.entity)
	}
	testing.expect(t, !(cube_of(rp, change.entity).?).complete)
	idle(t, rp, moved, faces, false)
	captures(t, rp, moved, faces, change.entity, true)
	idle(t, rp, moved, faces, true)
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
			key = {
				position = ecs.position_offset({}, {f32(i), 0, 0}),
				rotation = 1,
				scale = scale,
				probe = {priority = priority, extent = extent},
			},
		}
		if cube >= 0 {
			rp.slots[i].cube = Reflection_Probe_Cube {
				index = cube,
			}
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
	// The transient textures that the faces drew into, and the textures that they took.
	transient: int,
	taken:     int,
	stats:     Reflection_Probe_Stats,
	frame:     Reflection_Probe_Frame,
	// With the global illumination or the ambient occlusion: the faces' constants' gi, the voxel cones' radiance
	// textures that each face's gather reads, the faces' own ambient occlusion's depth passes, and whether each face's
	// forward pass reads the faces' indirect light.
	face_gi:   [dynamic]u32,
	gi_reads:  [dynamic]int,
	face_ao:   int,
	lit_reads: [dynamic]bool,
}

// The platform of a test's probe frames, over the null backend, which streams assets too.
@(private = "file")
probe_platform :: proc(arena: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator = virtual.arena_allocator(arena),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
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
		gpu_stream_buffer = null.stream_buffer,
		gpu_stream_texture = null.stream_texture,
		gpu_transfer_done = null.transfer_done,
		gpu_create_sampler = null.create_sampler,
		gpu_destroy_sampler = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline = null.destroy_pipeline,
	}
}

@(private = "file")
run_probe_frame :: proc(
	t: ^testing.T,
	r: ^Renderer,
	cache: ^Texture_Cache,
	w: ^ecs.World,
	settings: Reflection_Settings,
	scene: []gpu.Buffer = nil,
	gi: Maybe(Gi_Settings) = nil,
	ao := false,
	camera := ecs.World_Position{},
) -> (
	run: Probe_Run,
) {
	platform := r.platform
	// The last frame's memory, which its run held, goes.
	free_all(platform.frame_allocator)
	g := begin(platform, cache)
	f := new(Frame, platform.frame_allocator)
	view := View {
		position   = camera,
		rotation   = 1,
		projection = Perspective{1, 0.1},
	}
	f^ = {
		renderer        = r, state = &r.view,
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
	// With a scene, the frame has an item to draw, though its views draw none of it. scene is its draws' five buffers:
	// the arguments, the mesh arguments, the counts, the draws and the instances.
	if scene != nil {
		sf := new(Scene_Frame, platform.frame_allocator)
		sf.items = make([]Cull_Item, 1, platform.frame_allocator)
		sf.arguments, sf.mesh_arguments = import_buffer(&g, scene[0]), import_buffer(&g, scene[1])
		sf.counts, sf.draws, sf.instances =
			import_buffer(&g, scene[2]), import_buffer(&g, scene[3]), import_buffer(&g, scene[4])
		f.scene_frame = sf
	}
	begin_reflection_probes(f, w, nil, settings, DEFAULT_AMBIENT)
	if pf := f.reflection_probes; pf != nil && pf.capturing {
		add_reflection_probe_shadow(f, f.shadows, 0, max_shadow_views(f.shadows.params))
	}
	upload_reflection_probe_lights(f)
	// The camera's prepass, ambient occlusion and global illumination, and the scene's constants: the camera's, then the
	// faces', which the probe passes give their indirect light.
	_, has_gi := gi.?
	if has_gi || ao {
		f.post = new(Post_Frame, platform.frame_allocator)
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = NORMAL_FORMAT, label = "normals"})
		f.velocity = create_texture(&g, {size = f.size, format = VELOCITY_FORMAT, label = "velocity"})
		f.roughness = create_texture(&g, {size = f.size, format = ROUGHNESS_FORMAT, label = "roughness"})
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		color(&g, prepass, f.normals, .Clear)
		color(&g, prepass, f.velocity, .Clear)
		color(&g, prepass, f.roughness, .Clear)
		if f.scene_frame == nil {
			f.scene_frame = new(Scene_Frame, platform.frame_allocator)
		}
		sf := f.scene_frame
		sf.view_constants = make([]gpu.Upload, 7, platform.frame_allocator)
		for &c in sf.view_constants {
			c, _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
			(^Frame_Constants)(raw_data(c.data))^ = {}
		}
		if pf := f.reflection_probes; pf != nil {
			pf.first_view = 1
		}
		if ao {
			add_ao_passes(f, {technique = .Gtao, level = .Low})
		}
		if settings, ok := gi.?; ok {
			begin_gi(f, settings, {})
			add_gi_passes(f)
		}
	}
	add_reflection_probe_passes(f)
	run.face_gi = make([dynamic]u32, platform.frame_allocator)
	run.gi_reads = make([dynamic]int, platform.frame_allocator)
	run.lit_reads = make([dynamic]bool, platform.frame_allocator)
	if pf := f.reflection_probes; pf != nil && pf.capturing && f.scene_frame != nil && f.scene_frame.view_constants != nil {
		for k in 0 ..< int(pf.face_count) {
			c := (^Frame_Constants)(raw_data(f.scene_frame.view_constants[pf.first_view + k].data))
			append(&run.face_gi, c.gi)
		}
		radiance := make(map[u32]bool, platform.frame_allocator)
		if gf := f.gi; gf != nil && gf.voxel != nil {
			for l in 0 ..< int(gf.voxel.params.levels) {
				radiance[u32(gf.voxel.textures[l][.Radiance] - 1)] = true
			}
		}
		// Each face's own light, which its forward pass reads.
		lit: [6]map[u32]bool
		for k in 0 ..< int(pf.face_count) {
			lit[k] = make(map[u32]bool, platform.frame_allocator)
			switch light in pf.face_light[pf.first_face + u32(k)] {
			case Reflection_Probe_Voxel_Light:
				lit[k][u32(light.diffuse - 1)], lit[k][u32(light.specular - 1)] = true, true
			case Reflection_Probe_Occlusion:
				lit[k][u32(light.texture - 1)] = true
			}
		}
		for node in g.passes {
			switch node.name {
			case "reflection probe gi":
				reads := 0
				for use in node.uses {
					reads += int(!use.buffer && use.reads && radiance[use.index])
				}
				append(&run.gi_reads, reads)
			case "reflection probe face":
				reads := false
				for use in node.uses {
					reads ||= !use.buffer && use.reads && lit[len(run.lit_reads)][use.index]
				}
				append(&run.lit_reads, reads)
			case "reflection probe ao depth":
				testing.expect_value(t, node.queue, gpu.Queue.Graphics)
				run.face_ao += 1
			}
		}
	}
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
	testing.expect(t, execute(&g), "the frame did not execute")
	taken := make(map[gpu.Texture]bool, platform.frame_allocator)
	for node in g.textures {
		if !node.imported && strings.has_prefix(node.desc.label, "reflection probe") {
			run.transient += 1
			taken[node.texture] = true
		}
	}
	run.taken = len(taken)
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
	platform := probe_platform(&arena)
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
		// The frame that finishes the capture shows it, with the cube that it prefilters.
		testing.expect_value(t, len(run.frame.records), k == 2 ? 1 : 0)
		if k == 2 {
			testing.expect_value(t, run.frame.records[0].cube, run.frame.target)
		}
	}
	testing.expect(t, rp.slots[0].cube != nil)

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

	// A capture that the editor asks for draws all six faces in one frame, whatever Medium's budget, and that frame
	// shows it: the record takes the new cube, which the probe keeps, at the host's time.
	platform.time_seconds = proc() -> f64 {return 42}
	defer platform.time_seconds = nil
	old := (rp.slots[0].cube.?).index
	testing.expect(t, capture_reflection_probe(r, probe))
	testing.expect(t, reflection_probe_state(r, probe).forced)
	run = run_probe_frame(t, r, &cache, w, medium)
	testing.expect(t, run.frame.capturing && run.frame.finish)
	testing.expect(t, run.frame.first_face == 0 && run.frame.face_count == 6)
	testing.expect_value(t, run.passes["reflection probe copy"], 6)
	testing.expect_value(t, run.passes["reflection probe prefilter"], 1)
	testing.expect_value(t, len(run.frame.records), 1)
	testing.expect_value(t, run.frame.records[0].cube, run.frame.target)
	testing.expect(t, run.frame.target != u32(old))
	state := reflection_probe_state(r, probe)
	cube := state.cube.?
	testing.expect(t, state.slot && !state.forced && !state.capturing)
	testing.expect_value(t, u32(cube.index), run.frame.target)
	testing.expect_value(t, cube.time, 42)
	testing.expect_value(t, rp.spare, old)
	run = run_probe_frame(t, r, &cache, w, medium)
	testing.expect(t, !run.frame.capturing)
	// The probes' cubes are the reflections' memory, with Probes.
	testing.expect_value(t, reflection_memory(r), reflection_probe_memory(rp.params))
	// An entity without a probe has no slot, so it cannot be captured.
	testing.expect(t, !capture_reflection_probe(r, ecs.spawn(w)))
	testing.expect_value(t, reflection_probe_state(r, ecs.spawn(w)), Reflection_Probe_State{})

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
	// Each face has its own six targets, and the graph gives each face the textures of the one before it, so the six
	// take no more of the graph's cache than one does.
	testing.expect_value(t, run.transient, 36)
	testing.expect_value(t, run.taken, 6)
	run = run_probe_frame(t, r, &cache, w, {technique = .Off, off = true})
	testing.expect(t, !rp.made && rp.cubes.texture == {})
	testing.expect_value(t, run.stats, Reflection_Probe_Stats{})
}

// A capture's indirect light (see docs/rendering/lighting-and-shadows.md#reflection-probes). With the voxel cones, each
// face gathers them at its own pixels, between its prepass and its forward pass: the gather reads every level's light,
// the forward pass reads what it gave, and the faces' constants take it as their GI. A probe outside every level takes
// the light that a capture takes without them, and reads no voxels. With the screen cascades, which a face cannot read,
// each face takes the ambient occlusion of its own depth, on the graphics queue, and with the voxel cones it does not.
@(test)
a_capture_takes_the_voxel_cones_or_its_own_ambient_occlusion :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := probe_platform(&arena)
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
	gi := &r.gi
	pipelines := []^Shader_Pipeline {
		&rp.face,
		&rp.downsample,
		&r.sky.cube.prefilter,
		&r.lights.pipeline,
		&gi.trace,
		&gi.merge,
		&gi.gather,
		&gi.lit,
		&gi.voxel.clear,
		&gi.voxel.inject,
		&gi.voxel.filter,
		&gi.voxel.gather,
		&r.ao.depth,
		&r.ao.searches[.Gtao],
		&r.ao.denoise,
	}
	for p in pipelines {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test"})
	}
	defer destroy_shader_pipeline(&r.sky.cube.prefilter, &platform)
	defer destroy_shader_pipeline(&r.lights.pipeline, &platform)
	defer gi_destroy(gi, &platform)
	defer for p in ([]^Shader_Pipeline{&r.ao.depth, &r.ao.searches[.Gtao], &r.ao.denoise}) {
		destroy_shader_pipeline(p, &platform)
	}
	r.blue_noise.texture = platform.gpu_create_texture(
		{
			size = {BLUE_NOISE_SIZE, BLUE_NOISE_SIZE},
			layers = BLUE_NOISE_SLICES,
			format = .RGBA8_Unorm,
			usage = {.Sampled, .Storage},
			label = "noise",
		},
		nil,
	)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	probe := ecs.spawn(w)
	ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {0, 1.5, 0}), rotation = 1, scale = 1})
	ecs.add(w, probe, Reflection_Probe{extent = {3, 1.5, 4}})
	ultra := Reflection_Settings {
		technique = .Probes,
		level     = .Ultra,
	}
	voxel_cones := Gi_Settings {
		technique = .Voxel_Cones,
		level     = .Low,
	}
	levels := int(GI_VOXEL_PARAMS[.Low].levels)

	// The camera is at the probe: Ultra captures its six faces in a frame, each with the voxel cones.
	run := run_probe_frame(t, r, &cache, w, ultra, gi = voxel_cones, ao = true)
	testing.expect(t, run.frame.capturing && run.frame.face_count == 6)
	testing.expect_value(t, run.passes["reflection probe gi"], 6)
	testing.expect_value(t, len(run.gi_reads), 6)
	for reads in run.gi_reads {
		testing.expect_value(t, reads, levels)
	}
	testing.expect_value(t, len(run.lit_reads), 6)
	for reads in run.lit_reads {
		testing.expect(t, reads, "a face's forward pass does not read its gather")
	}
	testing.expect_value(t, len(run.face_gi), 6)
	for gi in run.face_gi {
		testing.expect_value(t, gi, 1)
	}
	testing.expect_value(t, run.face_ao, 0)
	for face in run.frame.face_light {
		_, voxel_light := face.(Reflection_Probe_Voxel_Light)
		testing.expect(t, voxel_light)
	}

	// From 10 km away, the probe is outside every level: its faces read no voxels, and take the ambient light.
	far := ecs.position_offset({}, {10000, 0, 0})
	testing.expect(t, capture_reflection_probe(r, probe))
	run = run_probe_frame(t, r, &cache, w, ultra, gi = voxel_cones, camera = far)
	testing.expect(t, run.frame.capturing && run.frame.face_count == 6)
	testing.expect_value(t, run.passes["reflection probe gi"], 0)
	testing.expect_value(t, len(run.gi_reads), 0)
	for gi in run.face_gi {
		testing.expect_value(t, gi, 0)
	}
	testing.expect(t, run.frame.face_light == {})

	// With the screen cascades, each face takes the ambient occlusion of its own depth, which its forward pass reads.
	testing.expect(t, capture_reflection_probe(r, probe))
	run = run_probe_frame(t, r, &cache, w, ultra, gi = Gi_Settings{technique = .Screen_Cascades, level = .Low}, ao = true)
	testing.expect(t, run.frame.capturing && run.frame.face_count == 6)
	testing.expect_value(t, run.passes["reflection probe gi"], 0)
	testing.expect_value(t, run.face_ao, 6)
	for face in run.frame.face_light {
		_, occlusion := face.(Reflection_Probe_Occlusion)
		testing.expect(t, occlusion)
	}
	for reads in run.lit_reads {
		testing.expect(t, reads, "a face's forward pass does not read its ambient occlusion")
	}
	for gi in run.face_gi {
		testing.expect_value(t, gi, 0)
	}

	// Without the camera's ambient occlusion, the faces have none either.
	testing.expect(t, capture_reflection_probe(r, probe))
	run = run_probe_frame(t, r, &cache, w, ultra, gi = Gi_Settings{technique = .Screen_Cascades, level = .Low})
	testing.expect_value(t, run.face_ao, 0)
	testing.expect(t, run.frame.face_light == {})
}

// An On_Load probe that captures while a mesh streams keeps a provisional capture. It does not capture again while
// the mesh streams, captures again once the mesh is resident, and then never again.
@(test)
an_on_load_probe_captures_again_once_the_level_streams_in :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := probe_platform(&arena)
	dir, err := os.make_directory_temp("", "reflection_probes_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	guid := format.guid_parse("5f0a7c1e9b2d4e6f8a1b3c5d7e9f0a2b") or_else {}
	write_mesh(t, dir, guid, 3, time.now())
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)

	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	register_components(&w.registry)
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	residency_init(&r.residency, &platform, &assets)
	defer residency_destroy(&r.residency)
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
	scene: [5]gpu.Buffer
	for &b in scene {
		b = platform.gpu_create_buffer({size = 256, usage = {.Storage, .Indirect}, label = "scene"}, nil)
	}
	defer for b in scene {
		platform.gpu_destroy_buffer(b)
	}

	probe := ecs.spawn(w)
	ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {0, 1.5, 0}), rotation = 1, scale = 1})
	ecs.add(w, probe, Reflection_Probe{extent = {3, 1.5, 4}})
	medium := Reflection_Settings {
		technique = .Probes,
		level     = .Medium,
	}
	// Medium captures two faces a frame, so three frames capture the probe.
	capture :: proc(
		t: ^testing.T,
		r: ^Renderer,
		cache: ^Texture_Cache,
		w: ^ecs.World,
		settings: Reflection_Settings,
		scene: []gpu.Buffer,
		loc := #caller_location,
	) {
		for k in u32(0) ..< 3 {
			run := run_probe_frame(t, r, cache, w, settings, scene)
			testing.expect(t, run.frame.capturing, loc = loc)
			testing.expect_value(t, run.frame.first_face, 2 * k, loc = loc)
		}
	}

	// The level's mesh streams, so the capture is provisional.
	_, ready := resident_mesh(&r.residency, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, resident_streaming(&r.residency), 1)
	capture(t, r, &cache, w, medium, scene[:])
	cube, captured := rp.slots[0].cube.?
	testing.expect(t, captured && !cube.complete)
	// The frames look its cube up, and it waits while the mesh streams.
	for _ in 0 ..< 2 {
		run := run_probe_frame(t, r, &cache, w, medium, scene[:])
		testing.expect(t, !run.frame.capturing)
		testing.expect_value(t, len(run.frame.records), 1)
	}

	// The mesh lands: the probe captures again, and its capture is complete.
	residency_update(&r.residency)
	_, ready = resident_mesh(&r.residency, guid)
	testing.expect(t, ready)
	testing.expect_value(t, resident_streaming(&r.residency), 0)
	capture(t, r, &cache, w, medium, scene[:])
	cube, captured = rp.slots[0].cube.?
	testing.expect(t, captured && cube.complete)
	for _ in 0 ..< 2 {
		run := run_probe_frame(t, r, &cache, w, medium, scene[:])
		testing.expect(t, !run.frame.capturing)
	}
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
