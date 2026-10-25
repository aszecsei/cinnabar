package editor

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
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

	words := []u32{9, entity_id(c), transmute(u32)f32(0.5), 0, 0}
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

	// On the view model's stencil bit, the depth is the view model's near plane's.
	words[3] = render.VIEW_MODEL_STENCIL
	model := pick_result(w, {id = 5, width = 1, height = 1}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect(t, abs(model.depth - 0.02) < 1e-6)

	rect := pick_result(w, {id = 4, width = 8, height = 8}, words, 0.1, 0.01, context.temp_allocator)
	testing.expect_value(t, rect.depth, 0)
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