package ecs

import "core:testing"

// children_of is an entity's children, in the order that children_next gives them.
@(private = "file")
children_of :: proc(w: ^World, e: Entity) -> [dynamic]Entity {
	out := make([dynamic]Entity, context.temp_allocator)
	it := children_iter(w, e)
	for child in children_next(&it) {
		append(&out, child)
	}
	return out
}

@(private = "file")
expect_children :: proc(
	t: ^testing.T,
	w: ^World,
	e: Entity,
	want: []Entity,
	loc := #caller_location,
) {
	got := children_of(w, e)
	testing.expectf(t, slice_equal(got[:], want), "got %v, want %v", got[:], want, loc = loc)
}

@(private = "file")
slice_equal :: proc(a, b: []Entity) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
spawn_under :: proc(w: ^World, parent: Entity) -> Entity {
	e := spawn(w)
	add(w, e, Parent{parent})
	return e
}

@(test)
children_follow_parent_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	a := spawn(w)
	b := spawn(w)
	one := spawn_under(w, a)
	two := spawn_under(w, a)
	three := spawn_under(w, a)
	// The most recently parented first.
	expect_children(t, w, a, {three, two, one})
	expect_children(t, w, b, {})

	// Reparent from the middle of the list.
	add(w, two, Parent{b})
	expect_children(t, w, a, {three, one})
	expect_children(t, w, b, {two})

	// The same parent again moves the child to the front.
	add(w, one, Parent{a})
	expect_children(t, w, a, {one, three})

	remove(w, one, Parent)
	expect_children(t, w, a, {three})

	// A despawned child leaves its parent's list.
	testing.expect(t, despawn(w, three))
	expect_children(t, w, a, {})
	testing.expect(t, is_alive(w, a))
	expect_children(t, w, b, {two})
}

@(test)
despawning_a_parent_takes_only_its_subtree :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	root := spawn(w)
	child := spawn_under(w, root)
	grandchild := spawn_under(w, child)
	sibling := spawn_under(w, spawn(w))

	testing.expect(t, despawn(w, child))
	testing.expect(t, !is_alive(w, grandchild))
	testing.expect(t, is_alive(w, root))
	testing.expect(t, is_alive(w, sibling))
	expect_children(t, w, root, {})
	testing.expect_value(t, w.orphans, 0)
}

@(test)
a_reused_slot_starts_with_no_children :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	old := spawn(w)
	child := spawn_under(w, old)
	testing.expect(t, despawn(w, old))
	testing.expect(t, !is_alive(w, child))

	// The next spawns reuse the freed slots, the child's first.
	spawn(w)
	reused := spawn(w)
	testing.expect_value(t, entity_index(reused), entity_index(old))
	expect_children(t, w, reused, {})
	// The old handle has no children, though its slot is alive again.
	expect_children(t, w, old, {})
}

@(test)
a_stale_parent_makes_an_orphan :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	old := spawn(w)
	testing.expect(t, despawn(w, old))
	reused := spawn(w)
	testing.expect_value(t, entity_index(reused), entity_index(old))

	// A Parent with the old handle does not make a child of the entity in its slot.
	orphan := spawn_under(w, old)
	expect_children(t, w, reused, {})
	testing.expect(t, w.orphans != 0)
	// The next despawn takes the orphan, as apply does.
	testing.expect(t, despawn(w, spawn(w)))
	testing.expect(t, !is_alive(w, orphan))
	testing.expect(t, is_alive(w, reused))
	testing.expect_value(t, w.orphans, 0)
}

@(test)
apply_keeps_children_that_commands_move :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	root := spawn(w)
	other := spawn(w)
	moved := spawn_under(w, root)
	freed := spawn_under(w, root)
	lost := spawn_under(w, root)
	under_lost := spawn_under(w, lost)

	cb := commands(context.allocator)
	defer delete(cb.data)
	// The despawn comes first, but the subtree goes only at the end of apply.
	command_despawn(&cb, root)
	command_add(&cb, w, moved, Parent{other})
	command_remove(&cb, w, freed, Parent)
	apply(w, {cb})

	testing.expect(t, !is_alive(w, root))
	testing.expect(t, !is_alive(w, lost))
	testing.expect(t, !is_alive(w, under_lost))
	testing.expect(t, is_alive(w, moved))
	testing.expect(t, is_alive(w, freed))
	expect_children(t, w, other, {moved})
	testing.expect(t, !has(w, freed, Parent))
	testing.expect_value(t, w.orphans, 0)

	// A second apply on the same buffer reparents under a new entity it reserves.
	clear(&cb.data)
	late := reserve(w)
	command_add(&cb, w, moved, Parent{late})
	command_add(&cb, w, freed, Parent{late})
	apply(w, {cb})
	expect_children(t, w, late, {freed, moved})
	expect_children(t, w, other, {})
}

@(test)
despawning_a_cycle_ends :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	a := spawn(w)
	b := spawn_under(w, a)
	add(w, a, Parent{b})
	self := spawn(w)
	add(w, self, Parent{self})
	expect_children(t, w, self, {self})

	testing.expect(t, despawn(w, a))
	testing.expect(t, !is_alive(w, b))
	testing.expect(t, despawn(w, self))
	testing.expect_value(t, w.orphans, 0)
	testing.expect_value(t, entity_count(w), 0)
}

@(test)
despawn_all_leaves_no_lists :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	defer free_all(context.temp_allocator)
	w := &f.world

	root := spawn(w)
	spawn_under(w, spawn_under(w, root))
	// An orphan that no despawn took yet.
	stale := spawn(w)
	testing.expect(t, despawn(w, stale))
	spawn_under(w, stale)
	testing.expect(t, w.orphans != 0)

	despawn_all(w)
	testing.expect_value(t, w.orphans, 0)
	again := spawn(w)
	testing.expect_value(t, entity_index(again), 0)
	expect_children(t, w, again, {})
}
