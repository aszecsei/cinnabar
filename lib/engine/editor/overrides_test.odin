package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"

@(private = "file")
Lamp :: struct {
	brightness: f32,
	color:      [3]f32,
}

@(private = "file")
PROP :: 0xa1
@(private = "file")
CAM :: 0xc3
@(private = "file")
ARM :: 0xd4

// A prefab of one entity, which an override spawns.
@(private = "file")
CRATE :: `scene 2
entity 1000000000000001
name = "Crate"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

@(private = "file")
CRATE_GUID :: format.Guid {
	0  = 0x7e,
	15 = 2,
}

@(private = "file")
Fixture :: struct {
	platform:       core.Platform_API,
	frame:          virtual.Arena,
	world:          ecs.World,
	editor:         Editor,
	assets:         asset.Assets,
	views:          camera.Views,
	animation:      anim.State,
	dir:            string,
	out:            [dynamic]byte,
	despawned:      bool,
	lamp:           u64,
	// The scene's entities, after load.
	prop, cam, arm: ecs.Entity,
}

@(private = "file")
clock: f64

// setup loads a scene of a prop with a Lamp, an Animator and a child, the arm, and a camera, in Edit.
@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
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
	use_test_level(&f.platform)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	scene.register_components(&f.world.registry)
	render.register_components(&f.world.registry)
	anim.register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Lamp)
	f.lamp = u64(ecs.registry_find_type(&f.world.registry, Lamp).id)

	dir, err := os.make_directory_temp("", "editor_overrides_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	s, problems, parsed := format.scene_parse(CRATE, context.temp_allocator)
	testing.expectf(t, parsed, "problems: %v", problems)
	blob := format.scene_write(s, CRATE_GUID, 1, .Prefab, allocator = context.temp_allocator)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(CRATE_GUID, &buffer))
	testing.expect(t, os.write_entire_file(path, blob) == nil)

	// Without assets, init starts no UI, which needs the GPU. Spawns need them, so the editor gets them after.
	init(&f.editor, &f.platform, nil, views = &f.views, animation = &f.animation)
	f.editor.assets = &f.assets
	step(f)
	animator := u64(ecs.registry_find_type(&f.world.registry, anim.Animator).id)
	camera_id := u64(ecs.registry_find_type(&f.world.registry, render.Camera).id)
	step(
		f,
		1,
		link.Load_Scene {
			scenes = {
				{
					entities = {
						{
							id = PROP,
							name = "Prop",
							active = true,
							components = {
								{id = u64(ecs.TRANSFORM_ID), name = "Transform"},
								{
									id = f.lamp,
									name = "Lamp",
									fields = {{name = "brightness", value = value(1)}},
								},
								{id = animator, name = "Animator"},
							},
						},
						{
							id = ARM,
							name = "Arm",
							parent = PROP,
							active = true,
							components = {
								{id = u64(ecs.LOCAL_TRANSFORM_ID), name = "Local_Transform"},
							},
						},
						{
							id = CAM,
							name = "Cam",
							active = true,
							components = {
								{id = u64(ecs.TRANSFORM_ID), name = "Transform"},
								{id = camera_id, name = "Camera"},
							},
						},
					},
				},
			},
		},
	)
	f.prop = scene.find(f.editor.scenes, &f.world, 0, PROP)
	f.cam = scene.find(f.editor.scenes, &f.world, 0, CAM)
	f.arm = scene.find(f.editor.scenes, &f.world, 0, ARM)
	testing.expect(t, f.prop != 0 && f.cam != 0 && f.arm != 0)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.editor)
	anim.destroy(&f.animation)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// step polls once with the editor's messages, and returns what the game sent, without the stats, the command list
// and the actions.
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
	f.despawned = poll(&f.editor, &f.world, nil, connection, encoded[:], &f.out)
	messages := make([dynamic]link.Message, context.temp_allocator)
	for rest := f.out[:]; len(rest) > 0; {
		header, _ := link.read_header(rest)
		m, ok := link.decode_message(
			header.kind,
			rest[link.HEADER_SIZE:][:header.length],
			context.temp_allocator,
		)
		if ok {
			#partial switch _ in m {
			case link.Game_Stats, link.Game_Commands, link.Agent_Actions:
			case:
				append(&messages, m)
			}
		}
		rest = rest[link.HEADER_SIZE + int(header.length):]
	}
	return messages[:]
}

@(private = "file")
value :: proc(x: f64) -> link.Scene_Value {
	return {kind = .Number, count = 1, floats = {x, 0, 0, 0}}
}

@(private = "file")
at :: proc(id: u64) -> link.Override_Target {
	return {kind = .Scene_Entity, entity = id}
}

@(private = "file")
brightness :: proc(
	f: ^Fixture,
	v: f64,
	target := link.Override_Target{entity = PROP},
) -> link.Override_Field {
	return {
		target = target,
		component = f.lamp,
		field = format.scene_field_hash("brightness"),
		value = value(v),
	}
}

@(private = "file")
METER :: 16777216

@(private = "file")
pose_x :: proc(target: link.Override_Target, meters: i64) -> link.Override_Transform {
	return {target = target, position = {meters * METER, 0, 0}, rotation = {0, 0, 0, 1}, scale = 1}
}

@(private = "file")
lamp_of :: proc(f: ^Fixture, e: ecs.Entity = 0) -> f32 {
	return ecs.get(&f.world, f.prop if e == 0 else e, Lamp).brightness
}

@(private = "file")
x_of :: proc(f: ^Fixture, e: ecs.Entity) -> i64 {
	return ecs.get(&f.world, e, ecs.Transform).position.raw.x
}

// component_bytes copies an entity's component, to compare it whole.
@(private = "file")
component_bytes :: proc(f: ^Fixture, e: ecs.Entity, id: ecs.Component_Id) -> []u8 {
	info := ecs.registry_find(&f.world.registry, id)
	data := ecs.get_raw(&f.world, e, id)
	return slice.clone(([^]u8)(data)[:info.size], context.temp_allocator)
}

@(private = "file")
ended :: proc(messages: []link.Message) -> (link.Override_Ended, bool) {
	for m in messages {
		if v, is := m.(link.Override_Ended); is {
			return v, true
		}
	}
	return {}, false
}

// A field, a pose and a camera change the world. The editor still hears the document's values, with the held fields
// marked, and the entities that the override writes.
@(test)
an_override_writes_the_world_and_the_editor_hears_the_document :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, 1, link.Watch_Entity{entity = u64(f.prop)})
	messages := step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			fields = {brightness(f, 5)},
			transforms = {pose_x(at(PROP), 2)},
			cameras = {{view = 0, target = at(CAM), priority = 10}},
		},
	)
	testing.expect_value(t, lamp_of(f), 5)
	testing.expect_value(t, x_of(f, f.prop), 2 * METER)
	previous := ecs.get(&f.world, f.prop, ecs.Previous_Transform)
	if previous != nil {
		testing.expect_value(t, previous.position.raw.x, 2 * METER)
	}
	o := &f.editor.session.overrides.live[0]
	testing.expect(t, camera.is_pushed(&f.views, o.pushes[0].token))

	values, has_values := find_values(messages, f.prop)
	testing.expect(t, has_values)
	for c in values.components {
		if c.id == f.lamp {
			testing.expect_value(t, (^Lamp)(raw_data(c.data)).brightness, 1)
		}
		if c.id == u64(ecs.TRANSFORM_ID) {
			testing.expect_value(t, (^ecs.Transform)(raw_data(c.data)).position.raw.x, 0)
		}
	}
	held := values.held
	testing.expect(
		t,
		slice.contains(held, link.Held_Field{f.lamp, format.scene_field_hash("brightness")}),
	)
	testing.expect(
		t,
		slice.contains(
			held,
			link.Held_Field{u64(ecs.TRANSFORM_ID), format.scene_field_hash("position")},
		),
	)
	testing.expect(
		t,
		!slice.contains(held, link.Held_Field{f.lamp, format.scene_field_hash("color")}),
	)
	entities, has_entities := find_entities(messages)
	testing.expect(t, has_entities)
	testing.expect(t, slice.contains(entities.entities, u64(f.prop)))
	testing.expect(t, slice.contains(entities.entities, u64(f.cam)))
	_, refused := ended(messages)
	testing.expect(t, !refused)
}

@(private = "file")
find_values :: proc(messages: []link.Message, e: ecs.Entity) -> (link.Entity_Values, bool) {
	for m in messages {
		if v, is := m.(link.Entity_Values); is && v.entity == u64(e) {
			return v, true
		}
	}
	return {}, false
}

@(private = "file")
find_entities :: proc(messages: []link.Message) -> (link.Overridden_Entities, bool) {
	for m in messages {
		if v, is := m.(link.Overridden_Entities); is {
			return v, true
		}
	}
	return {}, false
}

// A release puts the world back exactly as the document has it, pops the camera and despawns what it spawned, in
// the same poll.
@(test)
a_release_puts_the_document_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	lamp_before := component_bytes(f, f.prop, ecs.Component_Id(f.lamp))
	pose_before := component_bytes(f, f.prop, ecs.TRANSFORM_ID)
	arm_before := component_bytes(f, f.arm, ecs.LOCAL_TRANSFORM_ID)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			spawns = {
				{
					key = 7,
					prefab = ([16]u8)(CRATE_GUID),
					position = {METER, 0, 0},
					rotation = {0, 0, 0, 1},
					scale = 1,
				},
			},
			fields = {brightness(f, 5)},
			transforms = {
				pose_x(at(PROP), 2),
				pose_x(at(ARM), 3),
				pose_x({kind = .Spawned, entity = 7}, 4),
			},
			cameras = {{view = 0, target = at(CAM), priority = 10}},
		},
	)
	o := f.editor.session.overrides.live[0]
	testing.expect_value(t, len(o.spawned), 1)
	crate := o.spawned[0].root
	testing.expect_value(t, x_of(f, crate), 4 * METER)
	testing.expect_value(t, ecs.get(&f.world, f.arm, ecs.Local_Transform).offset.x, 3)
	token := o.pushes[0].token

	messages := step(f, 1, link.Release_Override{override = 1})
	testing.expect(t, f.despawned)
	testing.expect(t, !ecs.is_alive(&f.world, crate))
	testing.expect(t, !camera.is_pushed(&f.views, token))
	testing.expect(
		t,
		mem.compare(component_bytes(f, f.prop, ecs.Component_Id(f.lamp)), lamp_before) == 0,
	)
	testing.expect(t, mem.compare(component_bytes(f, f.prop, ecs.TRANSFORM_ID), pose_before) == 0)
	testing.expect(
		t,
		mem.compare(component_bytes(f, f.arm, ecs.LOCAL_TRANSFORM_ID), arm_before) == 0,
	)
	testing.expect_value(t, len(f.editor.session.overrides.live), 0)
	_, told := ended(messages)
	testing.expect(t, !told)
	entities, has_entities := find_entities(messages)
	testing.expect(t, has_entities && len(entities.entities) == 0)
}

// An edit of a field that an override holds goes to the document's value, under the override, which shows the edit
// when it is released.
@(test)
an_edit_under_an_override_shows_after_the_release :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame{override = 1, fields = {brightness(f, 5)}},
	)
	step(
		f,
		1,
		link.Apply_Operations {
			operations = {
				{
					kind = .Set_Field,
					entity = PROP,
					component = f.lamp,
					fields = {{name = "brightness", value = value(3)}},
				},
			},
		},
	)
	testing.expect_value(t, lamp_of(f), 5)
	step(f, 1, link.Release_Override{override = 1})
	testing.expect_value(t, lamp_of(f), 3)
}

// The overrides are off the world between lift_overrides and lay_overrides, as the edit-mode behaviours run.
@(test)
lift_and_lay_take_the_overrides_off_and_put_them_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			fields = {brightness(f, 5)},
			transforms = {pose_x(at(PROP), 2)},
		},
	)
	testing.expect(t, lift_overrides(&f.editor, &f.world))
	testing.expect_value(t, lamp_of(f), 1)
	testing.expect_value(t, x_of(f, f.prop), 0)
	testing.expect(t, !lift_overrides(&f.editor, &f.world))
	testing.expect(t, lay_overrides(&f.editor, &f.world))
	testing.expect_value(t, lamp_of(f), 5)
	testing.expect_value(t, x_of(f, f.prop), 2 * METER)
	testing.expect(t, !lay_overrides(&f.editor, &f.world))
}

// Play ends every override with the document's world, and tells the editor. Stop then shows the document.
@(test)
play_ends_the_overrides :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			spawns = {
				{key = 7, prefab = ([16]u8)(CRATE_GUID), rotation = {0, 0, 0, 1}, scale = 1},
			},
			fields = {brightness(f, 5)},
		},
	)
	crate := f.editor.session.overrides.live[0].spawned[0].root
	messages := step(f, 1, link.Set_Mode{mode = .Play})
	end, told := ended(messages)
	testing.expect(t, told)
	testing.expect_value(t, end, link.Override_Ended{1, .Mode})
	testing.expect_value(t, lamp_of(f), 1)
	testing.expect(t, !ecs.is_alive(&f.world, crate))
	testing.expect(t, f.despawned)
	// A frame for it now is late, and is dropped.
	step(f, 1, link.Override_Frame{override = 1, fields = {brightness(f, 9)}})
	testing.expect_value(t, lamp_of(f), 1)
}

// An override begins only in Edit, with the editor's scene, and a late begin or frame is dropped.
@(test)
a_begin_outside_edit_or_late_is_refused :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, 1, link.Set_Mode{mode = .Play})
	end, told := ended(step(f, 1, link.Begin_Override{override = 1}))
	testing.expect(t, told)
	testing.expect_value(t, end, link.Override_Ended{1, .Not_Editing})

	step(f, 1, link.Set_Mode{mode = .Edit})
	// Without the editor's scene again, Edit does not mirror the document yet.
	end, told = ended(step(f, 1, link.Begin_Override{override = 2}))
	testing.expect_value(t, end, link.Override_Ended{2, .Not_Editing})

	step(
		f,
		1,
		link.Load_Scene{},
		link.Begin_Override{override = 3},
		link.Release_Override{override = 3},
	)
	step(
		f,
		1,
		link.Begin_Override{override = 3},
		link.Override_Frame{override = 3, fields = {brightness(f, 9)}},
	)
	testing.expect_value(t, len(f.editor.session.overrides.live), 0)
}

// Two overrides of one field: the later shows, and each release leaves the other's value or the document's.
@(test)
two_overrides_of_a_field_layer_in_their_order :: proc(t: ^testing.T) {
	for first_out in ([]bool{true, false}) {
		f := setup(t)
		defer teardown(f)
		step(
			f,
			1,
			link.Begin_Override{override = 1},
			link.Begin_Override{override = 2},
			link.Override_Frame{override = 1, fields = {brightness(f, 5)}},
			link.Override_Frame{override = 2, fields = {brightness(f, 7)}},
		)
		testing.expect_value(t, lamp_of(f), 7)
		if first_out {
			step(f, 1, link.Release_Override{override = 1})
			testing.expect_value(t, lamp_of(f), 7)
			step(f, 1, link.Release_Override{override = 2})
		} else {
			step(f, 1, link.Release_Override{override = 2})
			testing.expect_value(t, lamp_of(f), 5)
			step(f, 1, link.Release_Override{override = 1})
		}
		testing.expect_value(t, lamp_of(f), 1)
	}
}

// What a frame leaves out goes back to the document, and a camera that it keeps stays on its stack as it was.
@(test)
a_frame_replaces_the_last :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			fields = {brightness(f, 5)},
			cameras = {{view = 0, target = at(CAM), priority = 10}},
		},
	)
	token := f.editor.session.overrides.live[0].pushes[0].token
	step(
		f,
		1,
		link.Override_Frame{override = 1, cameras = {{view = 0, target = at(CAM), priority = 10}}},
	)
	testing.expect_value(t, lamp_of(f), 1)
	testing.expect_value(t, f.editor.session.overrides.live[0].pushes[0].token, token)
	testing.expect(t, camera.is_pushed(&f.views, token))
	step(f, 1, link.Override_Frame{override = 1})
	testing.expect(t, !camera.is_pushed(&f.views, token))
}

// A drive stays from frame to frame, and starts again when an edit replaces the Animator.
@(test)
an_animator_stays_driven_through_an_edit :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	clip := format.Guid {
		0 = 0xc1,
	}
	drive := link.Override_Animator {
		target  = at(PROP),
		samples = {{clip = ([16]u8)(clip), time = 0.5, weight = 1}, {}},
	}
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame{override = 1, animators = {drive}},
	)
	driven, is_driven := ecs.get(&f.world, f.prop, anim.Animator).driven.?
	testing.expect(t, is_driven)
	testing.expect_value(t, driven.samples[0].clip, clip)
	token := f.editor.session.overrides.live[0].animators[0].token

	drive.samples[0].time = 0.75
	step(f, 1, link.Override_Frame{override = 1, animators = {drive}})
	testing.expect_value(t, f.editor.session.overrides.live[0].animators[0].token, token)
	driven, is_driven = ecs.get(&f.world, f.prop, anim.Animator).driven.?
	testing.expect_value(t, driven.samples[0].time, 0.75)

	animator := u64(ecs.registry_find_type(&f.world.registry, anim.Animator).id)
	step(
		f,
		1,
		link.Apply_Operations {
			operations = {
				{
					kind = .Add_Component,
					entity = PROP,
					components = {{id = animator, name = "Animator"}},
				},
			},
		},
	)
	driven, is_driven = ecs.get(&f.world, f.prop, anim.Animator).driven.?
	testing.expect(t, is_driven)
	testing.expect_value(t, driven.samples[0].time, 0.75)

	step(f, 1, link.Release_Override{override = 1})
	_, is_driven = ecs.get(&f.world, f.prop, anim.Animator).driven.?
	testing.expect(t, !is_driven)
}

// The editor's scene replacing the world ends the overrides, and so does a code reload.
@(test)
a_load_and_a_reload_end_the_overrides :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame{override = 1, fields = {brightness(f, 5)}},
	)
	end, told := ended(step(f, 1, link.Load_Scene{}))
	testing.expect(t, told)
	testing.expect_value(t, end, link.Override_Ended{1, .Scene_Loaded})
	testing.expect_value(t, len(f.editor.session.overrides.live), 0)

	step(f, 1, link.Begin_Override{override = 2})
	testing.expect_value(t, len(f.editor.session.overrides.live), 1)
	end_overrides(&f.editor, &f.world, link.Override_End_Reason.Code_Reloaded)
	end, told = ended(step(f))
	testing.expect(t, told)
	testing.expect_value(t, end, link.Override_Ended{2, .Code_Reloaded})
}

// When the editor goes, its overrides end, and the world shows the document.
@(test)
a_closed_link_puts_the_document_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			spawns = {
				{key = 7, prefab = ([16]u8)(CRATE_GUID), rotation = {0, 0, 0, 1}, scale = 1},
			},
			fields = {brightness(f, 5)},
		},
	)
	crate := f.editor.session.overrides.live[0].spawned[0].root
	step(f, 0)
	testing.expect(t, f.despawned)
	testing.expect_value(t, lamp_of(f), 1)
	testing.expect(t, !ecs.is_alive(&f.world, crate))
}

// A write that the world cannot take is skipped, and the frame's other writes hold.
@(test)
a_write_that_does_not_fit_is_skipped :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(
		f,
		1,
		link.Begin_Override{override = 1},
		link.Override_Frame {
			override = 1,
			fields = {
				{
					target = at(PROP),
					component = f.lamp,
					field = format.scene_field_hash("missing"),
					value = value(2),
				},
				{
					target = at(PROP),
					component = f.lamp,
					field = format.scene_field_hash("brightness"),
					value = {kind = .Bool},
				},
				{
					target = at(0x99),
					component = f.lamp,
					field = format.scene_field_hash("brightness"),
					value = value(2),
				},
				brightness(f, 5),
			},
		},
	)
	testing.expect_value(t, len(f.editor.session.overrides.live[0].fields), 1)
	testing.expect_value(t, lamp_of(f), 5)
}
