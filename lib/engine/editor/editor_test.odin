package editor

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"

Mode :: enum u8 {
	Idle,
	Busy = 5,
}

Inner :: struct {
	amount: f32 `editor:"range=0,10"`,
	hidden: rawptr,
}

Tuned :: struct {
	mode:   Mode,
	inner:  Inner,
	secret: i32 `editor:"-"`,
	locked: [3]f32 `editor:"read"`,
}

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
	out:      [dynamic]byte,
}

// Each poll sees a clock one second later, so every interval has passed.
@(private = "file")
clock: f64

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		time_seconds = proc() -> f64 {
			clock += 1
			return clock
		},
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
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	scene.register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Tuned)
	init(&f.editor, &f.platform)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.editor)
	ecs.destroy(&f.world)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// step polls once, with the given messages from the editor, and returns what the game sent.
@(private = "file")
step :: proc(f: ^Fixture, connection: u64 = 1, incoming: ..link.Message) -> []link.Message {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		buf := make([dynamic]byte, context.temp_allocator)
		link.write_message(&buf, m)
		header, _ := link.read_header(buf[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = buf[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	poll(&f.editor, &f.world, nil, connection, encoded[:], &f.out)
	messages := make([dynamic]link.Message, context.temp_allocator)
	for rest := f.out[:]; len(rest) > 0; {
		header, _ := link.read_header(rest)
		m, ok := link.decode_message(header.kind, rest[link.HEADER_SIZE:][:header.length], context.temp_allocator)
		if ok {
			append(&messages, m)
		}
		rest = rest[link.HEADER_SIZE + int(header.length):]
	}
	return messages[:]
}

@(private = "file")
spawn :: proc(f: ^Fixture, tuned: Tuned) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, e, tuned)
	return e
}

@(test)
a_new_editor_gets_the_types_and_a_snapshot :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a := spawn(f, {})
	b := ecs.spawn(&f.world)
	ecs.add(&f.world, b, ecs.Parent{a})

	messages := step(f)

	testing.expect_value(t, len(messages), 2)
	types := messages[0].(link.Component_Types)
	testing.expect(t, len(types.types) == f.world.registry.count)
	snapshot := messages[1].(link.Entity_Snapshot)
	testing.expect_value(t, len(snapshot.entities), 2)
	for info in snapshot.entities {
		if ecs.Entity(info.entity) == b {
			testing.expect_value(t, ecs.Entity(info.parent), a)
			testing.expect(t, info.active)
		}
	}
}

@(test)
fields_are_flattened_tagged_and_hidden :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	types := step(f)[0].(link.Component_Types)

	tuned: link.Component_Type
	for c in types.types {
		if c.name == "Tuned" {
			tuned = c
		}
	}
	names := make([dynamic]string, context.temp_allocator)
	for field in tuned.fields {
		append(&names, field.name)
	}
	testing.expectf(t, slice.equal(names[:], []string{"mode", "inner.amount", "locked"}), "fields %v", names[:])
	mode, amount, locked := tuned.fields[0], tuned.fields[1], tuned.fields[2]
	testing.expect_value(t, mode.kind, link.Field_Kind.Enum)
	testing.expect_value(t, mode.enum_base, link.Field_Kind.U8)
	testing.expect_value(t, len(mode.enum_values), 2)
	testing.expect_value(t, mode.enum_values[1].value, i64(5))
	testing.expect_value(t, amount.offset, u32(offset_of(Tuned, inner) + offset_of(Inner, amount)))
	testing.expect(t, amount.has_range && amount.range_max == 10)
	testing.expect_value(t, locked.kind, link.Field_Kind.Vector3)
	testing.expect(t, locked.read_only)
}

@(test)
deltas_carry_only_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a := spawn(f, {})
	b := spawn(f, {})
	step(f)

	testing.expect_value(t, len(step(f)), 0)

	ecs.despawn(&f.world, a)
	ecs.add(&f.world, b, ecs.Disabled{})
	ecs.update_activity(&f.world)
	c := ecs.spawn(&f.world)
	delta := step(f)[0].(link.Entity_Delta)

	testing.expect(t, slice.equal(delta.destroyed, []u64{u64(a)}))
	testing.expect_value(t, len(delta.changed), 2)
	for info in delta.changed {
		switch ecs.Entity(info.entity) {
		case b:
			testing.expect(t, !info.active)
		case c:
			testing.expect_value(t, len(info.components), 0)
		case:
			testing.expectf(t, false, "%v did not change", info.entity)
		}
	}
}

@(test)
watched_values_go_out_when_they_change :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := spawn(f, {mode = .Busy})
	step(f)

	values := step(f, 1, link.Watch_Entity{u64(e)})[0].(link.Entity_Values)
	testing.expect_value(t, ecs.Entity(values.entity), e)
	tuned_id := ecs.registry_find_type(&f.world.registry, Tuned).id
	for c in values.components {
		if ecs.Component_Id(c.id) == tuned_id {
			testing.expect_value(t, (^Tuned)(raw_data(c.data)).mode, Mode.Busy)
		}
	}

	testing.expect_value(t, len(step(f)), 0)
	ecs.get(&f.world, e, Tuned).inner.amount = 3
	testing.expect_value(t, len(step(f)), 1)

	step(f, 1, link.Unwatch_Entity{u64(e)})
	ecs.get(&f.world, e, Tuned).inner.amount = 4
	testing.expect_value(t, len(step(f)), 0)
}

@(test)
another_connection_starts_over :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := spawn(f, {})
	step(f, 1, link.Watch_Entity{u64(e)})

	testing.expect_value(t, len(step(f, 0)), 0)
	messages := step(f, 2)

	testing.expect_value(t, len(messages), 2)
	_, is_snapshot := messages[1].(link.Entity_Snapshot)
	testing.expect(t, is_snapshot)
}

@(test)
a_scene_from_the_editor_replaces_the_world :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	old := spawn(f, {})
	step(f, 1, link.Watch_Entity{u64(old)})

	position := link.Scene_Value {
		kind    = .Number,
		count   = 3,
		integer = 0b111,
		ints    = {16777216, 0, 0, 0},
	}
	load := link.Load_Scene {
		entities = {
			{id = 0xa1, name = "Door", active = true, components = {{id = u64(ecs.TRANSFORM_ID), name = "Transform", fields = {{name = "position", value = position}}}}},
			{id = 0xb2, name = "Hinge", parent = 0xa1, active = true},
		},
	}
	messages := step(f, 1, load)

	testing.expect_value(t, len(messages), 2)
	problems := messages[0].(link.Edit_Problems)
	testing.expect(t, problems.snapshot && len(problems.problems) == 0)
	snapshot := messages[1].(link.Entity_Snapshot)
	testing.expect_value(t, len(snapshot.entities), 2)
	door: ecs.Entity
	for info in snapshot.entities {
		if info.scene_id == 0xa1 {
			door = ecs.Entity(info.entity)
			testing.expect_value(t, info.name, "Door")
		}
	}
	testing.expect(t, door != 0 && !ecs.is_alive(&f.world, old))
	testing.expect_value(t, ecs.get(&f.world, door, ecs.Transform).position.raw.x, 16777216)
	for info in snapshot.entities {
		if info.scene_id == 0xb2 {
			testing.expect_value(t, info.name, "Hinge")
			testing.expect_value(t, ecs.Entity(info.parent), door)
		}
	}
	// The old entity was watched, and its watch went with it.
	testing.expect_value(t, len(f.editor.watched), 0)
}

@(private = "file")
number :: proc(values: ..f64) -> link.Scene_Value {
	v := link.Scene_Value {
		kind  = .Number,
		count = u8(len(values)),
	}
	for x, i in values {
		v.floats[i] = x
		if x == f64(i64(x)) {
			v.ints[i] = i64(x)
			v.integer |= 1 << u8(i)
		}
	}
	return v
}

@(private = "file")
DOOR :: 0xa1
@(private = "file")
HINGE :: 0xb2

// load_door loads a door with a Tuned component and a hinge, and returns the entities that they became.
@(private = "file")
load_door :: proc(f: ^Fixture) -> (door, hinge: ecs.Entity) {
	tuned := u64(ecs.registry_find_type(&f.world.registry, Tuned).id)
	step(f)
	step(f, 1, link.Load_Scene{entities = {{id = DOOR, name = "Door", active = true, components = {{id = tuned, name = "Tuned"}}}, {id = HINGE, active = true}}})
	return find_scene_entity(&f.editor, &f.world, DOOR), find_scene_entity(&f.editor, &f.world, HINGE)
}

@(test)
operations_edit_the_world :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	door, hinge := load_door(f)
	tuned := u64(ecs.registry_find_type(&f.world.registry, Tuned).id)

	ops := []link.Operation {
		{kind = .Rename, entity = DOOR, name = "Front Door"},
		{kind = .Set_Parent, entity = HINGE, parent = DOOR},
		{kind = .Set_Active, entity = DOOR, active = false},
		{kind = .Set_Field, entity = DOOR, component = tuned, fields = {{name = "inner.amount", value = number(2.5)}}},
		{kind = .Set_Field, entity = DOOR, component = tuned, fields = {{name = "mode", value = {kind = .Name, text = "Busy"}}}},
		{kind = .Add_Component, entity = HINGE, components = {{id = u64(ecs.TRANSFORM_ID), name = "Transform", fields = {{name = "scale", value = number(1, 2, 3)}}}}},
		{kind = .Create_Entity, created = {{id = 0xc3, name = "Knob", parent = DOOR, active = true}}},
	}
	messages := step(f, 1, link.Apply_Operations{operations = ops})

	for m in messages {
		_, refused := m.(link.Edit_Problems)
		testing.expectf(t, !refused, "refused: %v", m)
	}
	testing.expect_value(t, ecs.name_of(&f.world, door), "Front Door")
	testing.expect_value(t, ecs.get(&f.world, hinge, ecs.Parent).entity, door)
	testing.expect(t, ecs.has(&f.world, door, ecs.Disabled) && ecs.has(&f.world, hinge, ecs.Inactive))
	testing.expect_value(t, ecs.get(&f.world, door, Tuned).inner.amount, 2.5)
	testing.expect_value(t, ecs.get(&f.world, door, Tuned).mode, Mode.Busy)
	testing.expect_value(t, ecs.get(&f.world, hinge, ecs.Transform).scale, [3]f32{1, 2, 3})
	knob := find_scene_entity(&f.editor, &f.world, 0xc3)
	testing.expect(t, knob != 0)
	testing.expect_value(t, ecs.get(&f.world, knob, ecs.Parent).entity, door)

	undo := []link.Operation {
		{kind = .Reset_Field, entity = DOOR, component = tuned, fields = {{name = "inner.amount"}}},
		{kind = .Remove_Component, entity = HINGE, component = u64(ecs.TRANSFORM_ID)},
		{kind = .Set_Active, entity = DOOR, active = true},
		{kind = .Set_Parent, entity = HINGE},
		{kind = .Destroy_Entity, entity = 0xc3},
	}
	step(f, 1, link.Apply_Operations{operations = undo})

	testing.expect_value(t, ecs.get(&f.world, door, Tuned).inner.amount, 0)
	testing.expect(t, !ecs.has(&f.world, hinge, ecs.Transform) && !ecs.has(&f.world, hinge, ecs.Parent))
	testing.expect(t, !ecs.has(&f.world, door, ecs.Inactive))
	testing.expect(t, !ecs.is_alive(&f.world, knob))
}

@(test)
operations_that_the_game_cannot_apply_come_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	load_door(f)
	tuned := u64(ecs.registry_find_type(&f.world.registry, Tuned).id)

	ops := []link.Operation {
		{kind = .Set_Field, entity = DOOR, component = tuned, fields = {{name = "removed", value = number(1)}}},
		{kind = .Set_Field, entity = DOOR, component = tuned, fields = {{name = "mode", value = number(1.5)}}},
		{kind = .Rename, entity = 0x99, name = "Ghost"},
		{kind = .Remove_Component, entity = DOOR, component = u64(scene.SCENE_ENTITY_ID)},
	}
	messages := step(f, 1, link.Apply_Operations{operations = ops})

	problems: link.Edit_Problems
	for m in messages {
		if p, ok := m.(link.Edit_Problems); ok {
			problems = p
		}
	}
	testing.expect(t, !problems.snapshot)
	testing.expect_value(t, len(problems.problems), 4)
	entities := [4]u64{DOOR, DOOR, 0x99, DOOR}
	for p, i in problems.problems {
		testing.expect_value(t, p.entity, entities[i])
	}
}

@(test)
the_games_own_scene_is_found_by_scene_id :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, scene.Scene_Entity{0x51})
	step(f)

	step(f, 1, link.Apply_Operations{operations = {{kind = .Rename, entity = 0x51, name = "Found"}}})

	testing.expect_value(t, ecs.name_of(&f.world, e), "Found")
}
