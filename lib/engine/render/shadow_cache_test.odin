package render

import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
TEST_PARAMS :: Shadow_Params {
	atlas            = 4096,
	cell             = 1024,
	slot             = 512,
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
	return {slot = slot, old = Caster_Sphere{ecs.position_offset({}, from), 0.5}, new = Caster_Sphere{ecs.position_offset({}, to), 0.5}, report = report}
}

// plan runs atlas_cache_plan for a frame with the cache on and tracked, and complete inputs.
@(private = "file")
plan :: proc(
	cache: Maybe(Atlas_Cache),
	frame: u64,
	lights: []Atlas_Light,
	changes: []Caster_Change = nil,
	params := TEST_PARAMS,
	first_slot := 16,
	complete := true,
) -> (
	next: Atlas_Cache,
	plans: []Atlas_Plan,
	free_slot: int,
	stats: Atlas_Cache_Stats,
) {
	return atlas_cache_plan(cache, true, true, params, first_slot, frame, lights, changes, nil, complete, context.temp_allocator)
}

// A still light over still casters draws its cache in the first frame, and copies it in every frame after.
@(test)
a_still_light_draws_its_cache_once :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0}), point(2, {20, 2, 0})}
	cache, plans, free_slot, stats := plan(nil, 1, lights)
	testing.expect(t, plans[0].redraw && plans[1].redraw, "a new light did not draw")
	testing.expect_value(t, stats, Atlas_Cache_Stats{lights = 2, copied = 7, drawn = 7})
	testing.expect_value(t, plans[0].slots[0], 16)
	testing.expect_value(t, plans[1].slots, [6]int{17, 18, 19, 20, 21, 22})
	testing.expect_value(t, free_slot, 23)
	for frame in u64(2) ..< 10 {
		cache, plans, _, stats = plan(cache, frame, lights)
		testing.expect(t, !plans[0].redraw && !plans[1].redraw, "a still light drew again")
		testing.expect_value(t, stats, Atlas_Cache_Stats{lights = 2, copied = 7})
	}
}

// A change within a light's reach draws its cache again at once, wherever it came from or went to, and one outside
// does not.
@(test)
a_change_in_a_lights_reach_draws_it_again :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0}), spot(2, {100, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights)
	cache, plans, _, _ = plan(cache, 2, lights, {moved(0, {0, 0, 0}, {50, 0, 0})})
	testing.expect(t, plans[0].redraw && !plans[1].redraw, "a caster that left the first light's reach drew the wrong lights")
	cache, plans, _, _ = plan(cache, 3, lights, {moved(0, {50, 0, 0}, {98, 0, 0})})
	testing.expect(t, !plans[0].redraw && plans[1].redraw, "a caster that came into the second light's reach drew the wrong lights")
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
	reports := []Caster_Change{moved(1, {0, 0, 0}, {1, 0, 0}, true), moved(2, {100, 0, 0}, {101, 0, 0}, true), moved(3, {200, 0, 0}, {202, 0, 0}, true)}
	stats: Atlas_Cache_Stats
	cache, plans, _, stats = plan(cache, 3, lights, reports)
	testing.expect(t, plans[0].redraw && !plans[1].redraw && !plans[2].redraw, "the budget did not take the oldest light first")
	testing.expect_value(t, stats.refreshed, 1)
	cache, plans, _, stats = plan(cache, 4, lights)
	testing.expect(t, !plans[0].redraw && plans[1].redraw && !plans[2].redraw, "the pending reports did not wait their turn")
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
	// A new light takes the first free slot, which the point light left.
	d := spot(4, {150, 5, 0})
	cache, plans, _, _ = plan(cache, 3, {c, a, d})
	testing.expect(t, plans[2].redraw)
	testing.expect_value(t, plans[2].slots[0], slot_a + 1)
}

// A frame starts again, and every light draws, without a cache, when it missed a frame's changes, and when the
// parameters or the first slot changed.
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
	_, plans, _, _ = plan(first, 2, lights, first_slot = 0)
	testing.expect(t, plans[0].redraw, "another first slot kept the cache")
	_, plans, _, _ = atlas_cache_plan(first, true, false, TEST_PARAMS, 16, 2, lights, nil, nil, true, context.temp_allocator)
	testing.expect(t, plans[0].redraw, "an untracked frame kept the cache")
	_, plans, _, _ = atlas_cache_plan(first, false, true, TEST_PARAMS, 16, 2, lights, nil, nil, true, context.temp_allocator)
	testing.expect(t, plans[0].redraw, "the cache off kept the cache")
}

// A light that drew while the frame's inputs were not complete draws again in the first frame whose inputs are.
@(test)
a_provisional_light_draws_again_once_the_inputs_are_complete :: proc(t: ^testing.T) {
	lights := []Atlas_Light{spot(1, {0, 5, 0})}
	cache, plans, _, _ := plan(nil, 1, lights, complete = false)
	cache, plans, _, _ = plan(cache, 2, lights, complete = false)
	testing.expect(t, !plans[0].redraw, "a provisional light drew again while the inputs stayed incomplete")
	cache, plans, _, _ = plan(cache, 3, lights)
	testing.expect(t, plans[0].redraw, "a provisional light did not draw once the inputs were complete")
	cache, plans, _, _ = plan(cache, 4, lights)
	testing.expect(t, !plans[0].redraw)
}

// Every level's atlas fits the cache's slots.
@(test)
every_levels_atlas_fits_the_cache :: proc(t: ^testing.T) {
	for p in SHADOW_PARAMS {
		testing.expect(t, max_shadow_views(p) <= ATLAS_MAX_SLOTS)
		testing.expect(t, p.dynamic_distance > 0 && p.refresh_slots > 0)
	}
}
