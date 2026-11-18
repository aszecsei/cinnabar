package render

import "core:testing"

import "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// test_tracking is a tracking with nothing seen yet, on the heap: its slots are large.
@(private = "file")
test_tracking :: proc() -> ^Caster_Tracking {
	t := new(Caster_Tracking)
	t.changes = make([dynamic]Caster_Change)
	return t
}

@(private = "file")
free_tracking :: proc(t: ^Caster_Tracking) {
	delete(t.changes)
	free(t)
}

// box is a slot's bounds this frame: a cube of half a side about a point relative to the render origin.
@(private = "file")
box :: proc(center: [3]f32, half: f32 = 0.5, signature: u64 = 1) -> Caster_Bounds {
	return {low = center - half, high = center + half, signature = signature, casts = true}
}

// A caster that appears is a change at once. A still one changes nothing, frame after frame.
@(test)
a_still_caster_changes_once_when_it_appears :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	bounds := []Caster_Bounds{box({1, 0, 0})}
	track_casters(tr, bounds, {}, 1)
	testing.expect_value(t, len(tr.changes), 1)
	_, had := tr.changes[0].old.?
	new, has := tr.changes[0].new.?
	testing.expect(t, !had && has, "an appearing caster had an old place, or no new one")
	testing.expect_value(t, new.center, ecs.position_offset({}, {1, 0, 0}))
	for frame in u64(2) ..< 40 {
		track_casters(tr, bounds, {}, frame)
		testing.expectf(t, len(tr.changes) == 0, "frame %d: a still caster changed", frame)
	}
	testing.expect(t, !tr.slots[0].volatile)
}

// A caster that moves is a change from where the caches took it to where it is, and it turns dynamic: while it keeps
// moving, it only reports, every SHADOW_FAR_REFRESH frames. Once it has stood still for SHADOW_STILL_FRAMES, it turns
// static again, which is a change too.
@(test)
a_moving_caster_turns_dynamic_and_reports :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	track_casters(tr, {box({0, 0, 0})}, {}, 1)
	frame := u64(2)
	caster_moved(tr, 0, frame)
	track_casters(tr, {box({1, 0, 0})}, {}, frame)
	testing.expect_value(t, len(tr.changes), 1)
	old, _ := tr.changes[0].old.?
	testing.expect_value(t, old.center, ecs.World_Position{})
	testing.expect(
		t,
		!tr.changes[0].report && tr.slots[0].volatile,
		"the moving caster's change was a report, or it is not dynamic",
	)
	reports := 0
	for x in 2 ..= 33 {
		frame += 1
		caster_moved(tr, 0, frame)
		track_casters(tr, {box({f32(x), 0, 0})}, {}, frame)
		for c in tr.changes {
			testing.expect(t, c.report, "a dynamic caster's move was not a report")
			reports += 1
		}
	}
	testing.expect_value(t, reports, 32 / SHADOW_FAR_REFRESH)
	// It stops: it reports while it is still dynamic, then turns static once, where it stands.
	stopped := frame
	changes := 0
	for frame < stopped + SHADOW_STILL_FRAMES + 5 {
		frame += 1
		track_casters(tr, {box({33, 0, 0})}, {}, frame)
		for c in tr.changes {
			if !c.report {
				changes += 1
				new, _ := c.new.?
				testing.expect_value(t, new.center, ecs.position_offset({}, {33, 0, 0}))
				testing.expect_value(t, frame, stopped + SHADOW_STILL_FRAMES)
			}
		}
	}
	testing.expect_value(t, changes, 1)
	testing.expect(t, !tr.slots[0].volatile)
}

// A rebase moves the render origin, and the bounds relative to it, but not the caster: its sphere stays, and nothing
// changes.
@(test)
a_rebase_changes_no_caster :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	track_casters(tr, {box({1, 0, 0})}, {}, 1)
	before := tr.slots[0].sphere
	origin := ecs.position_offset({}, {1024, 0, 0})
	track_casters(tr, {box({1 - 1024, 0, 0})}, origin, 2)
	testing.expect_value(t, len(tr.changes), 0)
	testing.expect_value(t, tr.slots[0].sphere, before)
}

// A caster whose items change what they draw is a change at once, and so is one that stops casting, from where it was.
@(test)
a_caster_that_changes_or_leaves_is_a_change :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	track_casters(tr, {box({0, 0, 0}), box({5, 0, 0})}, {}, 1)
	track_casters(tr, {box({0, 0, 0}, signature = 2), box({5, 0, 0})}, {}, 2)
	testing.expect_value(t, len(tr.changes), 1)
	testing.expect_value(t, tr.changes[0].slot, 0)
	track_casters(tr, {box({0, 0, 0}, signature = 2), {}}, {}, 3)
	testing.expect_value(t, len(tr.changes), 1)
	testing.expect_value(t, tr.changes[0].slot, 1)
	old, had := tr.changes[0].old.?
	_, has := tr.changes[0].new.?
	testing.expect(t, had && !has, "a caster that left kept a new place")
	testing.expect_value(t, old.center, ecs.position_offset({}, {5, 0, 0}))
	testing.expect(t, !tr.slots[1].casts)
}

// A caster whose items change their shape by themselves is dynamic from the start, and reports even where it stands.
@(test)
an_inherent_caster_is_dynamic_and_reports_in_place :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	b := box({0, 0, 0})
	b.inherent = true
	reports := 0
	for frame in u64(1) ..= 16 {
		track_casters(tr, {b}, {}, frame)
		for c in tr.changes {
			reports += int(c.report)
		}
	}
	testing.expect(t, tr.slots[0].volatile)
	testing.expect_value(t, reports, 16 / SHADOW_FAR_REFRESH)
}

// A view draws a dynamic caster live within its distance, one without bounds at any distance, and never a static one.
// Its caches leave out the reports of what it draws live, and take a caster that turns live or baked as a change.
@(test)
a_view_draws_its_near_dynamic_casters_live :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	near, far, still, particles :=
		box({10, 0, 0}), box({500, 0, 0}), box({20, 0, 0}), box({900, 0, 0})
	near.inherent, far.inherent, particles.inherent, particles.unbounded = true, true, true, true
	bounds := []Caster_Bounds{near, far, still, particles}
	// At a frame where every slot reports.
	track_casters(tr, bounds, {}, 1)
	track_casters(tr, bounds, {}, SHADOW_FAR_REFRESH * 4)
	live := live_slots(tr, 4, {}, 100)
	testing.expect(
		t,
		slot_live(&live, 0) && !slot_live(&live, 1) && !slot_live(&live, 2) && slot_live(&live, 3),
	)
	previous := live
	changes := view_caster_changes(tr, &live, &previous, context.temp_allocator)
	for c in changes {
		testing.expectf(
			t,
			c.slot == 1,
			"the view took slot %d's report, which it draws live",
			c.slot,
		)
	}
	// The far caster comes within the distance: the caches drop it where they hold it.
	previous = live
	live = live_slots(tr, 4, ecs.position_offset({}, {450, 0, 0}), 100)
	testing.expect(t, slot_live(&live, 1))
	changes = view_caster_changes(tr, &live, &previous, context.temp_allocator)
	flips := 0
	for c in changes {
		if !c.report {
			flips += 1
		}
	}
	// The near caster turned baked, and the far one live.
	testing.expect_value(t, flips, 2)
}

// A still caster whose sphere moves from where the caches took it is a change, from there to where it is. Jitter below
// the epsilon is not.
@(test)
a_still_casters_sphere_change_is_a_change :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	track_casters(tr, {box({1, 0, 0})}, {}, 1)
	track_casters(tr, {box({1.0001, 0, 0})}, {}, 2)
	testing.expect_value(t, len(tr.changes), 0)
	track_casters(tr, {box({1, 0, 0}, half = 1.5)}, {}, 3)
	testing.expect_value(t, len(tr.changes), 1)
	old, _ := tr.changes[0].old.?
	new, _ := tr.changes[0].new.?
	testing.expect(
		t,
		new.radius > old.radius && !tr.changes[0].report,
		"the change did not grow the sphere",
	)
	track_casters(tr, {box({1, 0, 0}, half = 1.5)}, {}, 4)
	testing.expect_value(t, len(tr.changes), 0)
	// An instance set's slot leaves it to its cells.
	b := box({5, 0, 0})
	b.cells = true
	track_casters(tr, {box({1, 0, 0}, half = 1.5), b}, {}, 5)
	b.high += 1
	track_casters(tr, {box({1, 0, 0}, half = 1.5), b}, {}, 6)
	testing.expect_value(t, len(tr.changes), 0)
	testing.expect_value(t, tr.slots[1].reported, tr.slots[1].sphere)
}

// A pipeline that was made again, and a mesh that swapped in, change their items' signature, so their slots are a
// change, where their bounds and counts are the same.
@(test)
a_pipeline_generation_and_a_mesh_generation_are_changes :: proc(t: ^testing.T) {
	tr := test_tracking()
	defer free_tracking(tr)
	records := make([]Instance_Record, 1, context.temp_allocator)
	records[0].rows = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	pipelines := make([]Material_Pipeline, 1, context.temp_allocator)
	items := []Cull_Item{{instance = 0, flags = ITEM_CASTS_SHADOWS, sphere = {0, 0, 0, 0.5}}}
	generations := []u32{1}
	frame := u64(1)
	step :: proc(
		tr: ^Caster_Tracking,
		records: []Instance_Record,
		items: []Cull_Item,
		pipelines: []Material_Pipeline,
		generations: []u32,
		frame: ^u64,
	) -> int {
		bounds := caster_bounds(
			records,
			items,
			pipelines,
			nil,
			generations,
			1,
			context.temp_allocator,
		)
		track_casters(tr, bounds, {}, frame^)
		frame^ += 1
		return len(tr.changes)
	}
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 1)
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 0)
	pipelines[0].generation += 1
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 1)
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 0)
	generations[0] += 1
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 1)
	testing.expect_value(t, step(tr, records, items, pipelines, generations, &frame), 0)
}

// A newer version of an instance set that changes one cell changes that cell's sphere only, at the rows of each slot
// that draws the set, and not the slot's own sphere.
@(test)
a_new_set_version_changes_only_its_changed_cells :: proc(t: ^testing.T) {
	make_set :: proc(nudge: bool) -> []byte {
		instances := make([]format.Instance, format.INSTANCE_CELL_SIZE * 2, context.temp_allocator)
		for &i, k in instances {
			i = format.instance_pack(
				{position = {f32(k), 0, 0}, rotation = 1, scale = {1, 1, 1}},
				u32(k),
			)
		}
		if nudge {
			instances[format.INSTANCE_CELL_SIZE + 3].position.y = 4
		}
		contents := format.instance_cells(instances, context.temp_allocator)
		return format.instance_set_write(contents, context.temp_allocator)
	}
	before, after := make_set(false), make_set(true)
	b0, _ := format.instance_set_view(before)
	b1, _ := format.instance_set_view(after)
	set0 := Resident_Instance_Set {
		cells_cpu = set_cells(before, b0, context.temp_allocator),
	}
	set1 := Resident_Instance_Set {
		cells_cpu = set_cells(after, b1, context.temp_allocator),
	}
	guid := format.Guid {
		0 = 1,
	}
	changed := make([dynamic]Changed_Set_Cell, context.temp_allocator)
	diff_set_cells(&changed, guid, &set0, &set1)
	testing.expect_value(t, len(changed), 2)
	_, had_old := changed[0].old.?
	_, had_new := changed[0].new.?
	testing.expect(t, had_new != had_old, "a changed cell was not an added or a removed one")

	tr := test_tracking()
	defer free_tracking(tr)
	records := make([]Instance_Record, 1, context.temp_allocator)
	records[0].rows = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 10}}
	tr.slots[0].casts = true
	sets := []Instance_Set_Record{{slot = 0, flags = SET_CASTS_SHADOWS, sphere = {0, 0, 0, 1}}}
	bounds := []Set_Bounds{{guid = guid}}
	add_cell_changes(tr, changed[:], sets, bounds, records, {})
	testing.expect_value(t, len(tr.changes), 2)
	for c in tr.changes {
		sphere, ok := c.old.?
		if !ok {
			sphere, ok = c.new.?
		}
		testing.expect(t, ok, "a cell's change had no sphere")
		// Cell 1's spheres only: its instances are past the first cell's.
		center := ecs.position_sub(sphere.center, {})
		testing.expect(
			t,
			center.x > f32(format.INSTANCE_CELL_SIZE) - 1 && center.z == 10,
			"a change was not at the changed cell, at the slot's rows",
		)
	}
	// Another set's change draws nothing.
	clear(&tr.changes)
	add_cell_changes(tr, changed[:], sets, []Set_Bounds{{guid = {0 = 2}}}, records, {})
	testing.expect_value(t, len(tr.changes), 0)
}

@(test)
a_sphere_meets_a_lights_reach :: proc(t: ^testing.T) {
	s := Caster_Sphere{ecs.position_offset({}, {10, 0, 0}), 1}
	testing.expect(t, sphere_meets(s, {}, 9.5))
	testing.expect(t, !sphere_meets(s, {}, 8.5))
}
