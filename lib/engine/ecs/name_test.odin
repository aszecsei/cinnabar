package ecs

import "core:strings"
import "core:testing"

import "cinnabar:core/testlog"

@(test)
default_names_have_their_ids :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	for text, name in DEFAULT_NAMES {
		testing.expect_value(t, intern(w, text), Name{id = u32(name)})
	}
	testing.expect_value(t, intern(w, "None"), NAME_NONE)
	testing.expect_value(t, intern(w, ""), NAME_NONE)
	testing.expect_value(t, name_text(w, NAME_NONE), "None")

	// A reload keeps every id, defaults and others.
	door := intern(w, "Door")
	reload(w, &f.platform)
	testing.expect_value(t, intern(w, "None"), NAME_NONE)
	testing.expect_value(t, intern(w, "Door"), door)
	testing.expect_value(t, name_text(w, door), "Door")
}

@(test)
names_split_a_number_suffix :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	mesh := intern(w, "StaticMesh_212")
	testing.expect_value(t, name_base(w, mesh), "StaticMesh")
	testing.expect_value(t, mesh.number, u32(213))
	testing.expect_value(t, intern(w, "StaticMesh_0").number, u32(1))
	testing.expect_value(t, intern(w, "StaticMesh_7").id, mesh.id)
	testing.expect_value(t, intern(w, "StaticMesh"), Name{id = mesh.id})

	// These stay whole: a leading zero, no digits, no base, and a number past u32.
	for text in ([]string{"Door_01", "Door_", "_7", "Door7", "Door_4294967295", "Door_99999999999"}) {
		n := intern(w, text)
		testing.expect_value(t, n.number, u32(0))
		testing.expect_value(t, name_base(w, n), text)
	}
	for text in ([]string{"StaticMesh_212", "StaticMesh_0", "Door_4294967294", "a_b_3", "Door"}) {
		testing.expect_value(t, name_text(w, intern(w, text)), text)
	}
	testing.expect_value(t, intern(w, "Door_4294967294").number, max(u32))
}

@(test)
names_intern_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	door := intern(w, "Door")
	count := w.names.count
	testing.expect_value(t, intern(w, "Door"), door)
	testing.expect(t, intern(w, "Gate") != door)
	testing.expect_value(t, w.names.count, count + 1)

	_, found := lookup(w, "Window")
	testing.expect(t, !found)
	testing.expect_value(t, w.names.count, count + 1)

	// A long name is cut at a character boundary: "é" is two bytes, and the cut would split the last.
	long := strings.repeat("é", MAX_NAME_LENGTH, context.temp_allocator)
	text := name_text(w, intern(w, long))
	testing.expect_value(t, len(text), MAX_NAME_LENGTH - 1)
	testing.expect(t, strings.has_prefix(long, text))
}

@(test)
find_follows_spawns_renames_and_despawns :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	testing.expect_value(t, find(w, "Door"), Entity(0))
	first, second := spawn(w), spawn(w)
	add(w, second, intern(w, "Door"))
	add(w, first, intern(w, "Door"))
	// The one named first, not the lower handle.
	testing.expect_value(t, find(w, "Door"), second)
	all: [dynamic]Entity
	defer delete(all)
	find_all(w, "Door", &all)
	testing.expect_value(t, len(all), 2)
	testing.expect_value(t, all[0], second)
	testing.expect_value(t, all[1], first)

	// A rename moves the entity in the index.
	add(w, second, intern(w, "Gate"))
	testing.expect_value(t, find(w, "Door"), first)
	testing.expect_value(t, find(w, "Gate"), second)

	// A component added later moves the entity to another archetype, which the index does not care about.
	add(w, first, Health{3})
	testing.expect_value(t, find(w, "Door"), first)

	remove(w, first, Name)
	testing.expect_value(t, find(w, "Door"), Entity(0))

	despawn(w, second)
	testing.expect_value(t, find(w, "Gate"), Entity(0))

	// A slot that a despawn freed has no stale link.
	reused := spawn(w)
	testing.expect_value(t, entity_index(reused), entity_index(second))
	add(w, reused, intern(w, "Lamp"))
	testing.expect_value(t, find(w, "Lamp"), reused)
	testing.expect_value(t, find(w, "Gate"), Entity(0))

	// NAME_NONE is not indexed.
	add(w, reused, NAME_NONE)
	testing.expect_value(t, find(w, "None"), Entity(0))
	testing.expect_value(t, find(w, "Lamp"), Entity(0))
	testing.expect_value(t, name_of(w, reused), "")
}

@(test)
find_tells_suffixes_apart :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	one, two := spawn(w), spawn(w)
	add(w, one, intern(w, "Door_1"))
	add(w, two, intern(w, "Door_2"))
	testing.expect_value(t, find(w, "Door_1"), one)
	testing.expect_value(t, find(w, "Door_2"), two)
	testing.expect_value(t, find(w, "Door"), Entity(0))
	testing.expect_value(t, find(w, "Door_3"), Entity(0))
	testing.expect_value(t, name_of(w, two), "Door_2")
}

@(test)
find_follows_descendants_and_commands :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	parent, child := spawn(w), spawn(w)
	add(w, child, Parent{parent})
	add(w, child, intern(w, "Hinge"))
	despawn(w, parent)
	testing.expect_value(t, find(w, "Hinge"), Entity(0))

	cb := commands(context.allocator)
	defer delete(cb.data)
	spawned := reserve(w)
	command_add(&cb, w, spawned, intern(w, "Spoke"))
	testing.expect_value(t, find(w, "Spoke"), Entity(0))
	apply(w, {cb})
	testing.expect_value(t, find(w, "Spoke"), spawned)

	clear(&cb.data)
	command_add(&cb, w, spawned, intern(w, "Wheel"))
	apply(w, {cb})
	testing.expect_value(t, find(w, "Spoke"), Entity(0))
	testing.expect_value(t, find(w, "Wheel"), spawned)

	clear(&cb.data)
	command_despawn(&cb, spawned)
	apply(w, {cb})
	testing.expect_value(t, find(w, "Wheel"), Entity(0))

	// Raw bytes with an id that the world never interned become None.
	context.logger = testlog.expected_errors()
	e := spawn(w)
	bad := Name {
		id = 1 << 30,
	}
	add(w, e, bad)
	testing.expect_value(t, get(w, e, Name)^, NAME_NONE)
}

@(test)
find_skips_inactive_entities :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	hidden, shown := spawn(w), spawn(w)
	add(w, hidden, intern(w, "Door"))
	add(w, shown, intern(w, "Door"))
	set_active(w, hidden, false)
	testing.expect_value(t, find(w, "Door"), shown)
	set_active(w, shown, false)
	testing.expect_value(t, find(w, "Door"), Entity(0))
	set_active(w, hidden, true)
	testing.expect_value(t, find(w, "Door"), hidden)
}

@(test)
despawn_all_empties_the_index :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world

	for _ in 0 ..< 3 {
		add(w, spawn(w), intern(w, "Crate"))
	}
	despawn_all(w)
	testing.expect_value(t, find(w, "Crate"), Entity(0))
	e := spawn(w)
	add(w, e, intern(w, "Crate"))
	all: [dynamic]Entity
	defer delete(all)
	find_all(w, "Crate", &all)
	testing.expect_value(t, len(all), 1)
	testing.expect_value(t, all[0], e)
}
