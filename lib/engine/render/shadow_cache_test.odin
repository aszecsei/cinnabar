package render

import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
TEST_PARAMS :: Shadow_Params {
	atlas            = 4096,
	cell             = 1024,
	min_slot         = 256,
	max_slot         = 1024,
	cascades         = 4,
	dynamic_distance = 100,
	refresh_slots    = 1,
}

@(private = "file")
spot :: proc(entity: ecs.Entity, at: [3]f32, range: f32 = 10, distance: f32 = 5) -> Atlas_Light {
	return {
		entity = entity,
		position = ecs.position_offset({}, at),
		direction = {0, -1, 0},
		fov = 1,
		range = range,
		faces = 1,
		distance = distance,
		coverage = 512,
	}
}

@(private = "file")
point :: proc(entity: ecs.Entity, at: [3]f32, range: f32 = 10) -> Atlas_Light {
	l := spot(entity, at, range)
	l.direction, l.faces = {}, 6
	return l
}

@(private = "file")
moved :: proc(slot: u32, from, to: [3]f32, report := false) -> Caster_Change {
	return {
		slot = slot,
		old = Caster_Sphere{ecs.position_offset({}, from), 0.5},
		new = Caster_Sphere{ecs.position_offset({}, to), 0.5},
		report = report,
	}
}

// plan runs atlas_cache_plan for a frame with the cache on and tracked, and complete inputs.
@(private = "file")
plan :: proc(
	cache: Maybe(Atlas_Cache),
	frame: u64,
	lights: []Atlas_Light,
	changes: []Caster_Change = nil,
	params := TEST_PARAMS,
	cascades := 4,
	complete := true,
	probe := false,
) -> (
	next: Atlas_Cache,
	plans: []Atlas_Plan,
	probe_slot: Atlas_Slot,
	stats: Atlas_Cache_Stats,
) {
	return atlas_cache_plan(
		cache,
		true,
		true,
		params,
		cascades,
		frame,
		lights,
		changes,
		nil,
		complete,
		probe,
		context.temp_allocator,
	)
}

// expect_apart checks that the plans' slots and the cascades' cells do not overlap, and that each is in the atlas.
@(private = "file")
expect_apart :: proc(
	t: ^testing.T,
	plans: []Atlas_Plan,
	lights: []Atlas_Light,
	params := TEST_PARAMS,
	cascades := 4,
	loc := #caller_location,
) {
	slots := make([dynamic]Atlas_Slot, context.temp_allocator)
	for c in 0 ..< cascades {
		append(&slots, cascade_slot(params, c))
	}
	for plan, i in plans {
		for face in 0 ..< lights[i].faces {
			if plan.slots[face].size > 0 {
				append(&slots, plan.slots[face])
			}
		}
	}
	for a, i in slots {
		testing.expectf(
			t,
			int(a.x + a.size) <= params.atlas && int(a.y + a.size) <= params.atlas,
			"%v is outside the atlas",
			a,
			loc = loc,
		)
		for b in slots[i + 1:] {
			testing.expectf(t, !slots_overlap(a, b), "%v and %v overlap", a, b, loc = loc)
		}
	}
}

slots_overlap :: proc(a, b: Atlas_Slot) -> bool {
	return a.x < b.x + b.size && b.x < a.x + a.size && a.y < b.y + b.size && b.y < a.y + a.size
}

// A still light over still casters draws its cache in the first frame, and copies it in every frame after.
@(test)
a_still_light_draws_its_cache_once :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0}), point(2, {20, 2, 0})}
	cache, plans, _, stats := plan(nil, 1, lights)
	testing.expect(t, plans[0].redraw && plans[1].redraw, "a new light did not draw")
	testing.expect_value(t, stats, Atlas_Cache_Stats{lights = 2, copied = 7, drawn = 7})
	for face in 0 ..< 6 {
		testing.expect_value(t, plans[1].slots[face].size, 512)
	}
	expect_apart(t, plans, lights)
	first := plans
	for frame in u64(2) ..< 10 {
		cache, plans, _, stats = plan(cache, frame, lights)
		testing.expect(t, !plans[0].redraw && !plans[1].redraw, "a still light drew again")
		testing.expect_value(t, stats, Atlas_Cache_Stats{lights = 2, copied = 7})
		testing.expect_value(t, plans[0].slots, first[0].slots)
		testing.expect_value(t, plans[1].slots, first[1].slots)
	}
}

// A change within a light's reach draws its cache again at once, wherever it came from or went to, and one outside
// does not.
@(test)
a_change_in_a_lights_reach_draws_it_again :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0}), spot(2, {100, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights)
	cache, plans, _, _ = plan(cache, 2, lights, {moved(0, {0, 0, 0}, {50, 0, 0})})
	testing.expect(
		t,
		plans[0].redraw && !plans[1].redraw,
		"a caster that left the first light's reach drew the wrong lights",
	)
	cache, plans, _, _ = plan(cache, 3, lights, {moved(0, {50, 0, 0}, {98, 0, 0})})
	testing.expect(
		t,
		!plans[0].redraw && plans[1].redraw,
		"a caster that came into the second light's reach drew the wrong lights",
	)
	cache, plans, _, _ = plan(cache, 4, lights, {moved(0, {200, 0, 0}, {300, 0, 0})})
	testing.expect(t, !plans[0].redraw && !plans[1].redraw, "a caster out of reach drew a light")
}

// A light that moves, turns or widens draws again, and so does one whose distance from the camera drifted by
// SHADOW_LOD_DRIFT since it drew: from there, the drift starts again.
@(test)
a_light_that_changes_or_drifts_draws_again :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	first, plans, _, _ := plan(nil, 1, lights)
	moved_light := []Atlas_Light{spot(1, {0, 5.01, 0})}
	_, plans, _, _ = plan(first, 2, moved_light)
	testing.expect(t, plans[0].redraw, "a moved light kept its cache")
	turned := []Atlas_Light{spot(1, {0, 5, 0})}
	turned[0].direction = {0, -1, 0.01}
	_, plans, _, _ = plan(first, 2, turned)
	testing.expect(t, plans[0].redraw, "a turned light kept its cache")
	wider := []Atlas_Light{spot(1, {0, 5, 0}, range = 12)}
	_, plans, _, _ = plan(first, 2, wider)
	testing.expect(t, plans[0].redraw, "a wider light kept its cache")
	// Within the drift, from a distance of 5: kept. Past it: drawn again, and the next frames measure from there.
	near := []Atlas_Light{spot(1, {0, 5, 0}, distance = 6.5)}
	cache: Atlas_Cache
	cache, plans, _, _ = plan(first, 2, near)
	testing.expect(t, !plans[0].redraw, "a small drift drew the light again")
	drifted := []Atlas_Light{spot(1, {0, 5, 0}, distance = 7.5)}
	cache, plans, _, _ = plan(cache, 3, drifted)
	testing.expect(t, plans[0].redraw, "a drift of more than the factor kept the cache")
	cache, plans, _, _ = plan(cache, 4, drifted)
	testing.expect(t, !plans[0].redraw)
}

// A report of a dynamic caster in a light's reach waits for the budget, and the lights that drew longest ago draw first.
@(test)
reports_draw_on_the_budget_the_oldest_first :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0}), spot(2, {100, 5, 0}), spot(3, {200, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights)
	// The third light draws again at frame 2, so it is the newest.
	cache, plans, _, _ = plan(cache, 2, lights, {moved(0, {200, 0, 0}, {201, 0, 0})})
	testing.expect(t, plans[2].redraw)
	reports := []Caster_Change {
		moved(1, {0, 0, 0}, {1, 0, 0}, true),
		moved(2, {100, 0, 0}, {101, 0, 0}, true),
		moved(3, {200, 0, 0}, {202, 0, 0}, true),
	}
	stats: Atlas_Cache_Stats
	cache, plans, _, stats = plan(cache, 3, lights, reports)
	testing.expect(
		t,
		plans[0].redraw && !plans[1].redraw && !plans[2].redraw,
		"the budget did not take the oldest light first",
	)
	testing.expect_value(t, stats.refreshed, 1)
	cache, plans, _, stats = plan(cache, 4, lights)
	testing.expect(
		t,
		!plans[0].redraw && plans[1].redraw && !plans[2].redraw,
		"the pending reports did not wait their turn",
	)
	cache, plans, _, _ = plan(cache, 5, lights)
	testing.expect(t, plans[2].redraw)
	cache, plans, _, stats = plan(cache, 6, lights)
	testing.expect_value(t, stats.drawn, 0)
	// A point light's six slots pass the budget of one, and still draw.
	cube := []Atlas_Light{point(4, {0, 5, 0})}
	cache, _, _, _ = plan(nil, 1, cube)
	cache, plans, _, stats = plan(cache, 2, cube, {moved(1, {0, 0, 0}, {1, 0, 0}, true)})
	testing.expect(t, plans[0].redraw, "a report waits forever for a light larger than the budget")
	testing.expect_value(t, stats.refreshed, 6)
}

// A light keeps its slots while it keeps its shadow, whichever lights come and go around it, and a light that comes takes
// the free ones.
@(test)
lights_keep_their_slots_as_others_come_and_go :: proc(t: ^testing.T) {
	a, b, c := spot(1, {0, 5, 0}), point(2, {50, 5, 0}), spot(3, {100, 5, 0})
	cache, plans, _, _ := plan(nil, 1, {a, b, c})
	slot_a, slot_c := plans[0].slots[0], plans[2].slots[0]
	// The point light leaves, and the order changes: the others keep their slots and their caches.
	cache, plans, _, _ = plan(cache, 2, {c, a})
	testing.expect_value(t, plans[0].slots[0], slot_c)
	testing.expect_value(t, plans[1].slots[0], slot_a)
	testing.expect(t, !plans[0].redraw && !plans[1].redraw)
	// A new light takes a free slot, as those that the point light left, and the others keep theirs.
	d := spot(4, {150, 5, 0})
	cache, plans, _, _ = plan(cache, 3, {c, a, d})
	testing.expect(t, plans[2].redraw && !plans[0].redraw && !plans[1].redraw)
	testing.expect_value(t, plans[0].slots[0], slot_c)
	testing.expect_value(t, plans[1].slots[0], slot_a)
	expect_apart(t, plans, {c, a, d})
}

// A frame starts again, and every light draws, without a cache, when it missed a frame's changes, and when the
// parameters or the cascades changed.
@(test)
the_cache_starts_again_when_it_is_not_known_to_be_right :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	first, plans, _, _ := plan(nil, 1, lights)
	_, plans, _, _ = plan(first, 3, lights)
	testing.expect(t, plans[0].redraw, "a frame that missed a frame's changes kept the cache")
	ultra := TEST_PARAMS
	ultra.atlas = 8192
	_, plans, _, _ = plan(first, 2, lights, params = ultra)
	testing.expect(t, plans[0].redraw, "other parameters kept the cache")
	_, plans, _, _ = plan(first, 2, lights, cascades = 0)
	testing.expect(t, plans[0].redraw, "other cascades kept the cache")
	_, plans, _, _ = atlas_cache_plan(
		first,
		true,
		false,
		TEST_PARAMS,
		4,
		2,
		lights,
		nil,
		nil,
		true,
		allocator = context.temp_allocator,
	)
	testing.expect(t, plans[0].redraw, "an untracked frame kept the cache")
	_, plans, _, _ = atlas_cache_plan(
		first,
		false,
		true,
		TEST_PARAMS,
		4,
		2,
		lights,
		nil,
		nil,
		true,
		allocator = context.temp_allocator,
	)
	testing.expect(t, plans[0].redraw, "the cache off kept the cache")
}

// A light that drew while the frame's inputs were not complete draws again in the first frame whose inputs are.
@(test)
a_provisional_light_draws_again_once_the_inputs_are_complete :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights, complete = false)
	cache, plans, _, _ = plan(cache, 2, lights, complete = false)
	testing.expect(
		t,
		!plans[0].redraw,
		"a provisional light drew again while the inputs stayed incomplete",
	)
	cache, plans, _, _ = plan(cache, 3, lights)
	testing.expect(
		t,
		plans[0].redraw,
		"a provisional light did not draw once the inputs were complete",
	)
	cache, plans, _, _ = plan(cache, 4, lights)
	testing.expect(t, !plans[0].redraw)
}

// A light whose size changes takes new slots and draws them: one that shrinks takes the corner of its own slot, and one
// that grows a free slot of its new size. A light near a size's boundary keeps its size.
@(test)
a_light_whose_size_changes_draws_again :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights)
	old := plans[0].slots[0]
	testing.expect_value(t, old.size, 512)
	// Within the hysteresis of 512, the light keeps its slot.
	lights[0].coverage = 700
	cache, plans, _, _ = plan(cache, 2, lights)
	testing.expect(t, !plans[0].redraw, "a light near a boundary drew again")
	testing.expect_value(t, plans[0].slots[0], old)
	lights[0].coverage = 380
	cache, plans, _, _ = plan(cache, 3, lights)
	testing.expect(t, !plans[0].redraw, "a light near a boundary drew again")
	// Past it, the light shrinks into its own corner, and draws.
	lights[0].coverage = 256
	cache, plans, _, _ = plan(cache, 4, lights)
	testing.expect(t, plans[0].redraw, "a light whose size changed kept its cache")
	testing.expect_value(t, plans[0].slots[0], Atlas_Slot{old.x, old.y, 256})
	cache, plans, _, _ = plan(cache, 5, lights)
	testing.expect(t, !plans[0].redraw)
	// And grows into a free slot.
	lights[0].coverage = 1024
	cache, plans, _, _ = plan(cache, 6, lights)
	testing.expect(t, plans[0].redraw)
	testing.expect_value(t, plans[0].slots[0].size, 1024)
	expect_apart(t, plans, lights)
}

// When the sizes do not fit, the largest halve, the least important first among equals, and the least important light
// is left out only when every size is the smallest. A still frame with a full atlas keeps every slot and draws nothing.
@(test)
a_full_atlas_halves_the_largest_before_it_drops_a_light :: proc(t: ^testing.T) {
	// 12 cells of 1024 are free past the cascades: 192 units of 256.
	lights := make([]Atlas_Light, 4, context.temp_allocator)
	for &light, i in lights {
		light = point(ecs.Entity(i + 1), {f32(i) * 30, 5, 0})
		light.coverage = 4096
	}
	// 4 cubes at 1024 need 24 cells: the last three halve, which leaves one cube at 1024 and three at 512.
	cache, plans, _, _ := plan(nil, 1, lights)
	for p, i in plans {
		testing.expectf(t, p.slots[0].size > 0, "light %d was left out", i)
	}
	testing.expect_value(t, plans[0].slots[0].size, 1024)
	testing.expect_value(t, plans[3].slots[0].size, 512)
	expect_apart(t, plans, lights)
	for frame in u64(2) ..< 6 {
		again: []Atlas_Plan
		stats: Atlas_Cache_Stats
		cache, again, _, stats = plan(cache, frame, lights)
		testing.expect_value(t, stats.drawn, 0)
		for p, i in again {
			testing.expect_value(t, p.slots, plans[i].slots)
		}
	}
	// 40 cubes need 240 units even at 256: the last 8 are left out.
	many := make([]Atlas_Light, 40, context.temp_allocator)
	for &light, i in many {
		light = point(ecs.Entity(i + 1), {f32(i) * 30, 5, 0})
	}
	_, plans, _, _ = plan(nil, 1, many)
	for p, i in plans {
		testing.expectf(t, (p.slots[0].size > 0) == (i < 32), "light %d: %v", i, p.slots[0])
	}
	expect_apart(t, plans, many)
}

// When the kept slots leave no free block for a light, every light takes its slots again from an empty atlas, and draws.
@(test)
kept_slots_that_leave_no_room_repack :: proc(t: ^testing.T) {
	params := TEST_PARAMS
	params.atlas = 1024
	// Four lights fill the four quadrants, then shrink into their corners, which leaves no free 512.
	lights := make([]Atlas_Light, 5, context.temp_allocator)
	for &light, i in lights {
		light = spot(ecs.Entity(i + 1), {f32(i) * 30, 5, 0})
	}
	cache, plans, _, _ := plan(nil, 1, lights[:4], params = params, cascades = 0)
	expect_apart(t, plans, lights[:4], params, 0)
	for &light in lights[:4] {
		light.coverage = 256
	}
	cache, plans, _, _ = plan(cache, 2, lights[:4], params = params, cascades = 0)
	for p in plans {
		testing.expect(t, p.redraw)
	}
	cache, plans, _, _ = plan(cache, 3, lights, params = params, cascades = 0)
	for p, i in plans {
		testing.expectf(t, p.redraw, "light %d kept its slot through a repack", i)
		testing.expectf(t, p.slots[0].size > 0, "light %d was left out", i)
	}
	testing.expect_value(t, plans[4].slots[0].size, 512)
	expect_apart(t, plans, lights, params, 0)
}

// A reflection probe's capture takes a slot after the lights, half the largest, which the cache does not keep.
@(test)
a_capture_takes_a_slot_after_the_lights :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	cache, plans, probe, _ := plan(nil, 1, lights, probe = true)
	testing.expect_value(t, probe.size, 512)
	testing.expect(t, !slots_overlap(probe, plans[0].slots[0]))
	testing.expect_value(t, cache.count, 1)
	_, plans, probe, _ = plan(cache, 2, lights)
	testing.expect(t, !plans[0].redraw)
	testing.expect_value(t, probe.size, 0)
}

// Every level's slots are powers of two that fit its grid and its cells.
@(test)
every_levels_slots_fit_its_atlas :: proc(t: ^testing.T) {
	power :: proc(n: int) -> bool {
		return n > 0 && n & (n - 1) == 0
	}
	for p, level in SHADOW_PARAMS {
		testing.expectf(t, power(p.min_slot) && power(p.max_slot), "%v", level)
		testing.expectf(t, p.min_slot <= p.max_slot && p.max_slot <= p.cell, "%v", level)
		testing.expectf(t, p.atlas / p.min_slot <= ATLAS_GRID_SIDE, "%v", level)
		testing.expect(t, p.dynamic_distance > 0 && p.refresh_slots > 0)
	}
}
