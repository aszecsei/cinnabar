package world

import "core:testing"

@(test)
commands_apply_in_order :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	existing := spawn(w)
	add(w, existing, Health{1})

	first, second := commands(context.allocator), commands(context.allocator)
	defer delete(first.data)
	defer delete(second.data)

	spawned := reserve(w)
	command_add(&first, w, spawned, Health{5})
	command_add(&first, w, spawned, Player{})
	command_add(&first, w, existing, Velocity{{1, 2, 3}})
	command_remove(&first, w, existing, Health)
	// Later buffers see the effects of earlier ones.
	command_add(&second, w, spawned, Health{6})
	command_add_raw(&second, existing, component_id("world.Health"), nil)

	testing.expect(t, !is_alive(w, spawned))
	apply(w, {first, second})

	testing.expect(t, is_alive(w, spawned))
	testing.expect_value(t, get(w, spawned, Health).value, 6)
	testing.expect(t, has(w, spawned, Player))
	testing.expect_value(t, get(w, existing, Velocity).value, [3]f32{1, 2, 3})
	testing.expect_value(t, get(w, existing, Health).value, 0)
}

@(test)
commands_for_dead_entities_do_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	e := spawn(w)
	cb := commands(context.allocator)
	defer delete(cb.data)
	command_despawn(&cb, e)
	command_add(&cb, w, e, Health{1})
	command_despawn(&cb, e)
	apply(w, {cb})
	testing.expect(t, !is_alive(w, e))
	testing.expect_value(t, archetype(w, EMPTY_ARCHETYPE).count, 0)
}
