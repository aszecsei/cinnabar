package ecs

import "core:testing"

@(private)
child_of :: proc(w: ^World, parent: Entity) -> Entity {
	e := spawn(w)
	add(w, e, Transform{rotation = 1, scale = 1})
	add(w, e, Parent{parent})
	add(w, e, LOCAL_TRANSFORM_IDENTITY)
	return e
}

@(test)
deactivating_a_parent_deactivates_its_descendants :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	root := spawn(w)
	add(w, root, TRANSFORM_IDENTITY)
	child := child_of(w, root)
	grandchild := child_of(w, child)
	update_activity(w)

	testing.expect(t, set_active(w, root, false))
	testing.expect(t, !active_self(w, root))
	testing.expect(t, active_self(w, child))
	for e in ([]Entity{root, child, grandchild}) {
		testing.expect(t, !active_in_hierarchy(w, e))
	}

	// A child that was deactivated itself stays inactive when its parent comes back.
	testing.expect(t, set_active(w, child, false))
	testing.expect(t, set_active(w, root, true))
	testing.expect(t, active_in_hierarchy(w, root))
	testing.expect(t, !active_in_hierarchy(w, child))
	testing.expect(t, !active_in_hierarchy(w, grandchild))
	testing.expect(t, set_active(w, child, true))
	testing.expect(t, active_in_hierarchy(w, grandchild))
}

@(test)
queries_skip_inactive_entities_unless_they_name_inactive :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	a, b := spawn(w), spawn(w)
	add(w, a, Health{1})
	add(w, b, Health{2})
	set_active(w, b, false)

	healthy := query(w, {read(w, Health)})
	testing.expect_value(t, query_entity_count(w, healthy), 1)
	all := query(w, {read(w, Health), optional(read(w, Inactive))})
	testing.expect_value(t, query_entity_count(w, all), 2)

	found := make([dynamic]Entity, context.temp_allocator)
	collect(w, {type_component(w, Health)}, &found)
	testing.expect_value(t, len(found), 1)
	clear(&found)
	collect(w, {type_component(w, Health), INACTIVE_ID}, &found)
	testing.expect_value(t, len(found), 1)
	if len(found) == 1 {
		testing.expect_value(t, found[0], b)
	}
}

@(test)
the_log_records_watched_removals_and_activity :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	health := type_component(w, Health)
	watch(w, {health}, activity = true)
	a, b := spawn(w), spawn(w)
	add(w, a, Health{7})
	add(w, b, Health{8})
	set_active(w, a, false)
	remove(w, a, Health)
	despawn(w, b)

	entries := take_log(w, context.temp_allocator)
	testing.expect_value(t, len(entries), 3)
	if len(entries) == 3 {
		testing.expect_value(t, entries[0], Log_Entry{entity = a, kind = .Deactivated})
		testing.expect_value(t, entries[1], Log_Entry{entity = a, id = health, data = 7, kind = .Removed})
		testing.expect_value(t, entries[2], Log_Entry{entity = b, id = health, data = 8, kind = .Removed})
	}
	testing.expect_value(t, len(take_log(w, context.temp_allocator)), 0)
}

@(test)
apply_brings_activity_up_to_date :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	watch(w, {}, activity = true)
	root := spawn(w)
	add(w, root, TRANSFORM_IDENTITY)
	set_active(w, root, false)
	take_log(w, context.temp_allocator)

	// A child added under an inactive parent through commands becomes inactive at apply.
	cb := commands(context.temp_allocator)
	e := reserve(w)
	command_add(&cb, w, e, TRANSFORM_IDENTITY)
	command_add(&cb, w, e, LOCAL_TRANSFORM_IDENTITY)
	command_add(&cb, w, e, Parent{root})
	apply(w, {cb})
	testing.expect(t, !active_in_hierarchy(w, e))
	entries := take_log(w, context.temp_allocator)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect_value(t, entries[0], Log_Entry{entity = e, kind = .Deactivated})
	}
}

@(test)
nothing_is_logged_without_watch :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	e := spawn(w)
	add(w, e, Health{1})
	set_active(w, e, false)
	despawn(w, e)
	testing.expect_value(t, w.log_count, 0)
}
