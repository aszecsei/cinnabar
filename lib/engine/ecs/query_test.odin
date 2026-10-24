package ecs

import "core:testing"

@(test)
query_matches_terms :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	// Created before the archetypes exist, so it is matched as they are created.
	q := query(w, {write(w, Health), optional(read(w, Velocity)), without(w, Player)})
	testing.expect(t, q != 0)

	moving := spawn(w)
	add(w, moving, Health{1})
	add(w, moving, Velocity{{2, 0, 0}})
	still := spawn(w)
	add(w, still, Health{10})
	player := spawn(w)
	add(w, player, Health{100})
	add(w, player, Player{})
	spawn(w)

	health_sum: i32
	speed_sum: f32
	it := query_iter(w, q)
	for view in query_next(&it) {
		health := column(view, 0, Health)
		velocity := column(view, 1, Velocity)
		for i in 0 ..< view.count {
			health_sum += health[i].value
			if velocity != nil {
				speed_sum += velocity[i].value.x
			}
		}
	}
	testing.expect_value(t, health_sum, 11)
	testing.expect_value(t, speed_sum, 2)
	testing.expect_value(t, query_entity_count(w, q), 2)
}

@(test)
query_writes_reach_components :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	add(w, e, Health{1})
	q := query(w, {write(w, Health)})
	it := query_iter(w, q)
	for view in query_next(&it) {
		for &h, i in column(view, 0, Health) {
			testing.expect_value(t, entities(view)[i], e)
			h.value = 7
		}
	}
	testing.expect_value(t, get(w, e, Health).value, 7)
}

@(test)
query_ranges_cover_every_chunk_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	// Two archetypes with several chunks each.
	for i in 0 ..< 6000 {
		e := spawn(w)
		add(w, e, Health{1})
		if i % 2 == 0 {
			add(w, e, Velocity{})
		}
	}
	q := query(w, {read(w, Health)})
	chunks := query_chunk_count(w, q)
	testing.expect(t, chunks > 4)

	total := 0
	BATCH :: 3
	for first := 0; first < chunks; first += BATCH {
		it := query_iter(w, q, first, BATCH)
		for view in query_next(&it) {
			total += len(column(view, 0, Health))
		}
	}
	testing.expect_value(t, total, 6000)
}

@(test)
reload_clears_queries :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	add(w, e, Health{3})
	query(w, {read(w, Velocity)})
	reload(w, &f.platform)
	register_components(&w.registry)
	q := query(w, {read(w, Health)})
	testing.expect_value(t, q, Query(1))
	testing.expect_value(t, query_entity_count(w, q), 1)
	testing.expect_value(t, get(w, e, Health).value, 3)
}
