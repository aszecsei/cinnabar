package editor

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import "cinnabar:engine/debug"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"

// LIVE_BOX is a 1 m box as a mesh file: the cooker's template, with every edge sharp.
@(private = "file")
LIVE_BOX :: `mesh 1
v 0 0 0
v 1 0 0
v 1 0 1
v 0 0 1
v 0 1 0
v 1 1 0
v 1 1 1
v 0 1 1
f 0 0 1 2 3
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 4 7 6 5
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 0 4 5 1
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 2 6 7 3
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 3 7 4 0
map 0 0 1 0 -1 0 1 1 0 0 0
f 0 1 5 6 2
map 0 0 1 0 -1 0 1 1 0 0 0
e 0 1 sharp
e 1 2 sharp
e 2 3 sharp
e 3 0 sharp
e 4 5 sharp
e 5 6 sharp
e 6 7 sharp
e 7 4 sharp
e 0 4 sharp
e 1 5 sharp
e 2 6 sharp
e 3 7 sharp
`

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
	locked: [3]f32 `editor:"read color"`,
}

@(private = "file")
Fixture :: struct {
	t:        ^testing.T,
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
	init(&f.editor, &f.platform, nil)
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

// step polls once, with the given messages from the editor, and returns what the game sent, without the stats and the
// command list, which every poll here sends.
@(private = "file")
step :: proc(f: ^Fixture, connection: u64 = 1, incoming: ..link.Message) -> []link.Message {
	messages := make([dynamic]link.Message, context.temp_allocator)
	for m in step_all(f, connection, ..incoming) {
		#partial switch _ in m {
		case link.Game_Stats, link.Game_Commands:
		case:
			append(&messages, m)
		}
	}
	return messages[:]
}

@(private = "file")
step_all :: proc(f: ^Fixture, connection: u64 = 1, incoming: ..link.Message) -> []link.Message {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		buf := make([dynamic]byte, context.temp_allocator)
		link.write_message(&buf, m)
		header, _ := link.read_header(buf[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = buf[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	poll(&f.editor, &f.world, nil, connection, encoded[:], &f.out, f)
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
	testing.expect(t, locked.read_only && locked.color)
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

@(test)
the_editor_sets_the_view_and_the_selection :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a := spawn(f, {})
	step(f)
	_, has_view := view(&f.editor)
	testing.expect(t, !has_view)

	camera := link.Editor_Camera {
		position     = {1 << 24, 0, -(2 << 24)},
		rotation     = {0, 0, 0, 1},
		vertical_fov = 1,
		near         = 0.05,
	}
	step(f, 1, camera, link.Set_Selection{entities = {u64(a)}})
	v, ok := view(&f.editor)
	testing.expect(t, ok)
	testing.expect_value(t, v.position.raw, [3]i64{1 << 24, 0, -(2 << 24)})
	testing.expect_value(t, v.near, 0.05)
	testing.expect_value(t, len(f.editor.viewport.selection), 1)

	// Another editor has its own camera and selection.
	step(f, 2)
	_, has_view = view(&f.editor)
	testing.expect(t, !has_view)
	testing.expect_value(t, len(f.editor.viewport.selection), 0)
}

@(test)
picks_read_their_entities_from_the_results :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	a := spawn(f, {})
	ecs.spawn(w)
	c := spawn(f, {})
	ecs.add(w, c, scene.Scene_Entity{id = 0x77})
	gone := ecs.spawn(w)
	ecs.despawn(w, gone)

	// The corner pixel shows c's third submesh.
	words := []u32{9, entity_id(c) | 2 << render.ID_ENTITY_BITS, transmute(u32)f32(0.5), 0, 0}
	for e in ([]ecs.Entity{c, a, gone}) {
		index := ecs.entity_index(e)
		words[4 + index / 32] |= 1 << (index % 32)
	}
	result := pick_result(w, {id = 3, width = 1, height = 1}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect_value(t, result.id, 3)
	// The dead entity's slot finds nothing, and the others come in slot order.
	testing.expect_value(t, len(result.hits), 2)
	testing.expect_value(t, result.hits[0].entity, u64(a))
	testing.expect_value(t, result.hits[1], link.Pick_Hit{entity = u64(c), scene_id = 0x77})
	// A depth of 0.5 is twice the near plane.
	testing.expect(t, abs(result.depth - 0.2) < 1e-6)
	testing.expect_value(t, result.submesh, 2)

	// On the view model's stencil bit, the depth is the view model's near plane's.
	words[3] = render.VIEW_MODEL_STENCIL
	model := pick_result(w, {id = 5, width = 1, height = 1}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect(t, abs(model.depth - 0.02) < 1e-6)

	rect := pick_result(w, {id = 4, width = 8, height = 8}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect_value(t, rect.depth, 0)
	testing.expect_value(t, rect.submesh, -1)

	// Nothing at the corner has no submesh.
	words[1] = 0
	empty := pick_result(w, {id = 6, width = 1, height = 1}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect_value(t, empty.submesh, -1)
}

@(test)
selected_parents_outline_their_children :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	parent := spawn(f, {})
	child := spawn(f, {})
	grandchild := spawn(f, {})
	other := spawn(f, {})
	ecs.add(w, child, ecs.Parent{parent})
	ecs.add(w, grandchild, ecs.Parent{child})

	bits := make([]u32, (ecs.slot_count(w) + 31) / 32, context.temp_allocator)
	with_descendants(w, {parent}, bits)
	is_set :: proc(bits: []u32, e: ecs.Entity) -> bool {
		i := ecs.entity_index(e)
		return bits[i / 32] & (1 << (i % 32)) != 0
	}
	testing.expect(t, is_set(bits, parent) && is_set(bits, child) && is_set(bits, grandchild))
	testing.expect(t, !is_set(bits, other))
	with_descendants(w, {child}, bits)
	testing.expect(t, !is_set(bits, parent) && is_set(bits, grandchild))
}

@(test)
gizmos_are_triangles_with_the_hot_part_highlighted :: proc(t: ^testing.T) {
	v := render.View {
		rotation     = 1,
		vertical_fov = 1,
		near         = 0.05,
	}
	hot := pack_color({GIZMO_HOT.r, GIZMO_HOT.g, GIZMO_HOT.b, 1})
	for kind in ([]link.Gizmo_Kind{.Translate, .Rotate, .Scale}) {
		vertices := make([dynamic]Gizmo_Vertex, context.temp_allocator)
		gizmo_vertices({kind = kind, position = {0, 0, 5 << 24}, rotation = {0, 0, 0, 1}, size = 1, hot = .Y}, v, &vertices)
		testing.expect(t, len(vertices) > 0 && len(vertices) % 3 == 0)
		highlighted := 0
		for vertex in vertices {
			highlighted += int(vertex.color == hot)
			// Everything is near the gizmo, 5 m ahead of the view.
			testing.expect(t, abs(vertex.position.z - 5) < 1.5)
		}
		testing.expectf(t, highlighted > 0, "%v has no highlighted part", kind)
	}
	none := make([dynamic]Gizmo_Vertex, context.temp_allocator)
	gizmo_vertices({}, v, &none)
	testing.expect_value(t, len(none), 0)
}

@(test)
hidden_entities_hide_their_descendants :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	parent := spawn(f, {})
	child := spawn(f, {})
	other := spawn(f, {})
	ecs.add(w, child, ecs.Parent{parent})

	step(f)
	testing.expect(t, editor_visible(f, other) && editor_visible(f, child))
	step(f, 1, link.Set_Hidden{entities = {u64(parent)}})
	testing.expect(t, !editor_visible(f, parent) && !editor_visible(f, child))
	testing.expect(t, editor_visible(f, other))
	// Without an editor, nothing is hidden.
	step(f, 0)
	testing.expect(t, editor_visible(f, child))
}

@(private = "file")
editor_visible :: proc(f: ^Fixture, entity: ecs.Entity) -> bool {
	return is_visible(visibility(&f.editor, &f.world), entity)
}

@(test)
the_editors_mode_decides_whether_the_world_runs :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	frame := 16 * time.Millisecond

	// Without an editor, the world runs.
	run, dt := simulation(&f.editor, w, frame)
	testing.expect(t, run && dt == frame)
	// A new editor starts in Edit, where it does not.
	step(f, 1)
	run, _ = simulation(&f.editor, w, frame)
	testing.expect(t, !run)

	step(f, 1, link.Set_Mode{mode = .Play})
	run, dt = simulation(&f.editor, w, frame)
	testing.expect(t, run && dt == frame)

	// Paused, each step runs one frame of one tick.
	step(f, 1, link.Set_Mode{mode = .Paused}, link.Step_Frame{}, link.Step_Frame{})
	for _ in 0 ..< 2 {
		run, dt = simulation(&f.editor, w, frame)
		testing.expect(t, run && dt == ecs.tick_length(w))
	}
	run, _ = simulation(&f.editor, w, frame)
	testing.expect(t, !run)

	// The editor's camera draws in Edit, and in Play only as the free camera.
	camera := link.Editor_Camera{rotation = {0, 0, 0, 1}, vertical_fov = 1, near = 0.05}
	step(f, 1, camera)
	_, ok := view(&f.editor)
	testing.expect(t, !ok)
	step(f, 1, link.Set_Mode{mode = .Play, free_camera = true})
	_, ok = view(&f.editor)
	testing.expect(t, ok)
	step(f, 1, link.Set_Mode{mode = .Edit})
	_, ok = view(&f.editor)
	testing.expect(t, ok)
}

@(test)
the_editors_overlays_and_the_debug_layer_draw_only_while_editing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	render.register_components(&w.registry)
	lamp := ecs.spawn(w)
	ecs.add(w, lamp, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, lamp, render.Point_Light{intensity = 1, range = 2})
	lines: debug.Draw
	debug.init(&lines, context.allocator)
	defer debug.destroy(&lines)

	// Without an editor, the game is not editing, and its debug layer shows.
	testing.expect(t, !editing(&f.editor) && debug_shown(&f.editor))
	// A new editor starts in Edit, where both show.
	step(f, 1, link.Viewport_Settings{helpers = .All})
	testing.expect(t, editing(&f.editor) && debug_shown(&f.editor))
	draw_helpers(&f.editor, w, &lines)
	testing.expect(t, len(debug.frame_lines(&lines)) > 0, "the helpers drew nothing in Edit")
	debug.end_frame(&lines)

	// Play and Paused show the game's frame alone, with or without the free camera.
	for mode in ([]link.Set_Mode{{mode = .Play}, {mode = .Play, free_camera = true}, {mode = .Paused}}) {
		step(f, 1, mode)
		testing.expectf(t, !editing(&f.editor) && !debug_shown(&f.editor), "overlays in %v", mode)
		draw_helpers(&f.editor, w, &lines)
		testing.expectf(t, len(debug.frame_lines(&lines)) == 0, "the helpers drew in %v", mode)
	}
	// Stop sets Edit, and they are back.
	step(f, 1, link.Set_Mode{mode = .Edit})
	testing.expect(t, editing(&f.editor) && debug_shown(&f.editor))
}

@(test)
game_commands_go_with_the_types_and_return_operations :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := spawn(f, {})
	ecs.add(&f.world, e, scene.Scene_Entity{id = 0x51})
	register_command(&f.editor, {
		id = "test.rename",
		label = "Rename",
		tab = "Test",
		group = "Names",
		edits = true,
		procedure = proc(ctx: ^Command_Context) {
			f := (^Fixture)(ctx.user)
			testing.expect_value(f.t, len(ctx.selection), 1)
			for entity in ctx.selection {
				append(&ctx.operations, link.Operation{kind = .Rename, entity = scene_id(ctx.world, entity), name = "Renamed"})
			}
			ctx.message = "renamed"
		},
	})
	f.t = t

	commands: link.Game_Commands
	stats: link.Game_Stats
	for m in step_all(f) {
		#partial switch v in m {
		case link.Game_Commands:
			commands = v
		case link.Game_Stats:
			stats = v
		}
	}
	testing.expect_value(t, len(commands.commands), 1)
	testing.expect_value(t, commands.commands[0].tab, "Test")
	testing.expect_value(t, stats.entities, 1)

	result: link.Game_Command_Result
	for m in step(f, 1, link.Set_Selection{entities = {u64(e)}}, link.Run_Game_Command{id = "test.rename"}) {
		if r, ok := m.(link.Game_Command_Result); ok {
			result = r
		}
	}
	testing.expect_value(t, result.message, "renamed")
	testing.expect_value(t, len(result.operations), 1)
	testing.expect_value(t, result.operations[0].entity, 0x51)
	// The game does not apply them itself: the editor sends them back.
	testing.expect_value(t, ecs.name_of(&f.world, e), "")

	// A code reload forgets the commands, whose procedures were the old DLL's.
	reload(&f.editor, &f.platform)
	testing.expect_value(t, len(f.editor.commands), 0)
}

@(test)
previews_draw_when_what_they_show_changes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	assets: asset.Assets
	f.platform.file_modified = proc(path: string) -> i64 {return 0}
	asset.init(&assets, &f.platform, asset.loose_cache("missing"))
	f.editor.assets = &assets
	f.platform.gpu_preview_target = proc(id: int, size: [2]u32) -> (gpu.Preview_Target, bool) {
		return {texture = {index = 7, generation = 1}, prefix = "test.preview0.g0", size = size}, id == 0
	}
	f.platform.gpu_release_preview_target = proc(id: int) {}
	gold := [16]u8{0xf6, 0xd3, 0xde, 0x31, 0x90, 0xe2, 0xdf, 0xb9, 0x7d, 0x68, 0x34, 0xed, 0x51, 0x01, 0xc4, 0xc0}
	step(f, 1, link.Open_Preview{id = 0, material = gold}, link.Preview_Settings{id = 0, mesh = .Cube, pitch = 0.5, distance = 3, width = 128, height = 64})

	descs := previews(&f.editor)
	testing.expect_value(t, len(descs), 1)
	if len(descs) == 1 {
		testing.expect_value(t, descs[0].mesh, render.preview_mesh(.Cube))
		testing.expect_value(t, descs[0].size, [2]u32{128, 64})
		testing.expect_value(t, descs[0].distance, 3)
		testing.expect(t, descs[0].material == format.Guid(gold))
		testing.expect(t, descs[0].data == nil)
	}
	// Until a drawing is complete, the preview draws again; then it stops.
	descs = previews(&f.editor)
	testing.expect_value(t, len(descs), 1)
	descs[0].complete^ = true
	testing.expect_value(t, len(previews(&f.editor)), 0)
	// The editor hears of the target at the next poll.
	targets := 0
	for m in step(f) {
		if target, is_target := m.(link.Preview_Target); is_target {
			targets += 1
			testing.expect_value(t, target.prefix, "test.preview0.g0")
			testing.expect_value(t, target.width, 128)
		}
	}
	testing.expect_value(t, targets, 1)
	// A new camera draws it again, and a closed preview draws no more.
	step(f, 1, link.Preview_Settings{id = 0, mesh = .Cube, pitch = 0.2, distance = 3, width = 128, height = 64})
	testing.expect_value(t, len(previews(&f.editor)), 1)
	step(f, 1, link.Close_Preview{id = 0})
	testing.expect_value(t, len(previews(&f.editor)), 0)
}

@(test)
the_viewports_settings_reach_the_frame_while_an_editor_is_linked :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	step(f)
	testing.expect_value(t, render_overrides(&f.editor), Render_Overrides{})
	step(f, 1, link.Viewport_Settings{debug_view = .Normals, no_bloom = true, no_shadows = true, exposure_offset = -1.5})
	o := render_overrides(&f.editor)
	testing.expect_value(t, o.debug_view, render.Debug_View.Normals)
	testing.expect_value(t, o.disable, render.Features{.Bloom, .Shadows})
	testing.expect_value(t, o.exposure_offset, -1.5)
	// Without an editor, the frame is the game's own.
	step(f, 0)
	testing.expect_value(t, render_overrides(&f.editor), Render_Overrides{})
}

@(test)
the_viewports_quality_replaces_the_games_where_it_chooses :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	// A Renderer is too large for the stack.
	renderer := new(render.Renderer)
	defer free(renderer)
	renderer.caps = {upscalers = {.Fsr}}
	renderer.quality = render.preset_quality(.High, renderer.caps)
	renderer.quality.aa, renderer.quality.render_scale = .Smaa, 0.75

	step(f)
	_, ok := viewport_quality(&f.editor, renderer)
	testing.expect(t, !ok, "the viewport keeps the game's quality")
	// A preset sets the features, and the anti-aliasing and the render scale stay the game's.
	step(f, 1, link.Viewport_Settings{quality_preset = .Low})
	q: render.Quality
	q, ok = viewport_quality(&f.editor, renderer)
	testing.expect(t, ok)
	testing.expect_value(t, q.shadows.level, render.Quality_Level.Low)
	testing.expect_value(t, q.aa, render.Aa_Technique.Smaa)
	testing.expect_value(t, q.render_scale, 0.75)
	step(f, 1, link.Viewport_Settings{anti_aliasing = .Fsr, render_scale = 0.5})
	q, ok = viewport_quality(&f.editor, renderer)
	testing.expect(t, ok)
	testing.expect_value(t, q.shadows.level, render.Quality_Level.High)
	testing.expect_value(t, q.aa, render.Aa_Technique.Fsr)
	testing.expect_value(t, q.render_scale, 0.5)
	// The device limits it: without FSR, temporal AA.
	renderer.caps = {}
	q, _ = viewport_quality(&f.editor, renderer)
	testing.expect_value(t, q.aa, render.Aa_Technique.Taa)
	step(f, 0)
	_, ok = viewport_quality(&f.editor, renderer)
	testing.expect(t, !ok, "without an editor, the game's quality")
}
// A fake GPU for the live meshes' residency, whose transfers are done at once.
@(private = "file")
live_buffers: int

@(test)
live_meshes_bake_and_draw_in_place_of_their_assets :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	live_buffers = 0
	// Letting go of a live mesh loads its asset, which reads a file.
	f.platform.file_read = core.file_read
	f.platform.file_modified = core.file_modified
	f.platform.asset_allocator = runtime.heap_allocator()
	f.platform.gpu_create_buffer = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
		live_buffers += 1
		return transmute(gpu.Buffer)[2]u32{u32(live_buffers), 1}
	}
	f.platform.gpu_destroy_buffer = proc(buffer: gpu.Buffer) {
		if buffer != {} {
			live_buffers -= 1
		}
	}
	f.platform.gpu_stream_buffer = proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {return 1}
	f.platform.gpu_transfer_done = proc(transfer: gpu.Transfer) -> bool {return true}
	assets: asset.Assets
	asset.init(&assets, &f.platform, asset.loose_cache("missing"))
	defer asset.destroy(&assets)
	residency := new(render.Residency)
	defer free(residency)
	render.residency_init(residency, &f.platform, &assets)
	defer render.residency_destroy(residency)
	f.editor.residency = residency
	// The residency goes before the editor does.
	defer f.editor.residency = nil

	box, _, parsed := format.mesh_text_parse(LIVE_BOX, context.temp_allocator)
	testing.expect(t, parsed)
	guid := format.guid_parse("3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d") or_else {}

	// A Live_Mesh bakes as the cooker does and streams in place of the asset, which is not even cooked.
	step(f, 1, live_message(guid, box, context.temp_allocator))
	testing.expect(t, render.is_live(residency, guid))
	testing.expect_value(t, len(f.editor.live_meshes), 1)
	render.residency_update(residency)
	mesh, ready := render.resident_mesh(residency, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 24)
	testing.expect_value(t, mesh.index_count, 36)
	testing.expect_value(t, mesh.index_format, gpu.Index_Format.U16)
	testing.expect_value(t, mesh.submesh_count, 1)
	testing.expect_value(t, mesh.submeshes[0].meshlet_count, 1)
	testing.expect_value(t, mesh.bounds.max, [3]f32{1, 1, 1})
	testing.expect_value(t, live_buffers, 6)

	// A drag's step moves the vertices, and the mesh bakes again where they are.
	positions := make([]f32, 24, context.temp_allocator)
	for v, i in box.vertices {
		positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] = v.x * 2, v.y * 2, v.z * 2
	}
	step(f, 1, link.Live_Mesh_Vertices{guid = ([16]u8)(guid), positions = positions})
	render.residency_update(residency)
	mesh, _ = render.resident_mesh(residency, guid)
	testing.expect_value(t, mesh.bounds.max, [3]f32{2, 2, 2})
	testing.expect_value(t, live_buffers, 6)
	// A step of the wrong count is refused.
	context.logger = log.nil_logger()
	step(f, 1, link.Live_Mesh_Vertices{guid = ([16]u8)(guid), positions = positions[:6]})
	render.residency_update(residency)
	mesh, _ = render.resident_mesh(residency, guid)
	testing.expect_value(t, mesh.bounds.max, [3]f32{2, 2, 2})

	// Letting go leaves the asset, which is not cooked, so nothing draws.
	step(f, 1, link.Release_Live_Mesh{guid = ([16]u8)(guid)})
	testing.expect(t, !render.is_live(residency, guid))
	testing.expect_value(t, len(f.editor.live_meshes), 0)
	render.residency_update(residency)
	_, ready = render.resident_mesh(residency, guid)
	testing.expect(t, !ready)

	// A new editor's connection drops what the old one sent.
	step(f, 1, live_message(guid, box, context.temp_allocator))
	testing.expect(t, render.is_live(residency, guid))
	step(f, 2)
	testing.expect(t, !render.is_live(residency, guid))
	testing.expect_value(t, len(f.editor.live_meshes), 0)
}

@(test)
a_live_blob_is_the_cookers_mesh_without_its_levels :: proc(t: ^testing.T) {
	box, _, parsed := format.mesh_text_parse(LIVE_BOX, context.temp_allocator)
	testing.expect(t, parsed)
	guid := format.guid_parse("3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d") or_else {}
	blob, problems, _ := live_blob(guid, box, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	view, ok := format.mesh_view(blob)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, view.header.guid, guid)
	testing.expect_value(t, view.vertex_count, 24)
	testing.expect_value(t, view.index_count, 36)
	testing.expect_value(t, view.flags, format.Mesh_Flags{})
	submeshes := format.mesh_submeshes(blob, view)
	testing.expect_value(t, len(submeshes), 1)
	meshlets := format.mesh_meshlets(blob, view)
	testing.expect_value(t, len(meshlets), 1)
	testing.expect(t, meshlets[0].depth == 0 && meshlets[0].error == 0 && meshlets[0].cone_cutoff == 127)
	testing.expect_value(t, view.bounds.center, [3]f32{0.5, 0.5, 0.5})

	// A mesh with no faces that bake gives no blob, with the faces' problems.
	bad := box
	bad.faces = {{slot = 0, corners = {0, 1, 1}, mapping = box.faces[0].mapping, line = 0}}
	blob, problems, _ = live_blob(guid, bad, context.temp_allocator)
	testing.expect(t, blob == nil)
	testing.expect_value(t, len(problems), 1)
}

@(test)
the_mesh_overlay_draws_edges_vertices_fills_and_the_grid :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	box, _, parsed := format.mesh_text_parse(LIVE_BOX, context.temp_allocator)
	testing.expect(t, parsed)
	guid := format.guid_parse("3b7f2c9e4d1a4f6b8c0d2e4f6a8b0c1d") or_else {}
	entity := ecs.spawn(&f.world)
	ecs.add(&f.world, entity, ecs.TRANSFORM_IDENTITY)
	view := render.View {
		position     = {{0, 0, -5 * (1 << 24)}},
		rotation     = 1,
		vertical_fov = 1,
		near         = 0.05,
	}
	count :: proc(f: ^Fixture, view: render.View) -> int {
		vertices := make([dynamic]Gizmo_Vertex, context.temp_allocator)
		mesh_overlay_vertices(&f.editor, &f.world, view, 900, &vertices)
		return len(vertices)
	}

	// Without a live mesh, or with an inactive overlay, nothing draws.
	overlay := link.Mesh_Overlay {
		active  = true,
		element = .Edges,
		meshes  = {{guid = ([16]u8)(guid), entity = u64(entity), hovered_vertex = -1, hovered_face = -1}},
	}
	step(f, 1, overlay)
	testing.expect_value(t, count(f, view), 0)
	step(f, 1, live_message(guid, box, context.temp_allocator))
	// The box's twelve edges, each a ribbon of two triangles.
	edges := count(f, view)
	testing.expect_value(t, edges, 12 * 6)
	// In the vertices kind, eight squares of two triangles more.
	overlay.element = .Vertices
	step(f, 1, overlay)
	testing.expect_value(t, count(f, view), edges + 8 * 6)
	// In the faces kind, a selected face fills with its two triangles, and a hovered one too.
	overlay.element = .Faces
	overlay.meshes[0].selected_faces = {1}
	overlay.meshes[0].hovered_face = 2
	step(f, 1, overlay)
	testing.expect_value(t, count(f, view), edges + 2 * 3 + 2 * 3)
	// The grid is 81 lines each way, and two marks are two squares.
	overlay.grid, overlay.grid_size = true, 0.25
	overlay.meshes[0].marks = {0, 0, 0, 1, 1, 1}
	step(f, 1, overlay)
	testing.expect_value(t, count(f, view), edges + 12 + 81 * 2 * 6 + 2 * 6)
	// Off again, and gone with a new connection.
	step(f, 1, link.Mesh_Overlay{})
	testing.expect_value(t, count(f, view), 0)
	step(f, 1, overlay)
	testing.expect(t, f.editor.mesh_overlay.active)
	step(f, 2)
	testing.expect(t, !f.editor.mesh_overlay.active)
}
