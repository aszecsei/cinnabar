package editor

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

@(private = "file")
METER :: 16777216

@(private = "file")
Bulb :: struct {
	brightness: f32,
}

@(private = "file")
HERO :: 0xb1

@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x5c,
	15 = 1,
}

@(private = "file")
CUTSCENE_GUID :: format.Guid {
	0  = 0x5c,
	15 = 2,
}

@(private = "file")
PROP_GUID :: format.Guid {
	0  = 0x5c,
	15 = 3,
}

// A prefab of one entity, which the cutscene spawns.
@(private = "file")
PROP :: `scene 2
entity 1000000000000001
name = "Prop"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

@(private = "file")
Fixture :: struct {
	platform:  core.Platform_API,
	frame:     virtual.Arena,
	world:     ecs.World,
	editor:    Editor,
	assets:    asset.Assets,
	cutscenes: cutscene.State,
	dir:       string,
	out:       [dynamic]byte,
	despawned: bool,
	bulb:      u64,
	// The scene's hero, after load, which the cutscene possesses.
	hero:      ecs.Entity,
}

@(private = "file")
clock: f64

// setup cooks a prefab and a cutscene of length 2 s into a loose cache, and loads a scene with the hero at 1 m, with a
// Bulb of brightness 1, in Edit. The cutscene moves the hero from 0 m to 10 m over its first second, ramps the Bulb from
// 0 to 4, and spawns the prop.
@(private = "file")
setup :: proc(t: ^testing.T, to: f32 = 10) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
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
	ecs.register_component(&f.world.registry, Bulb)
	f.bulb = u64(ecs.registry_find_type(&f.world.registry, Bulb).id)

	dir, err := os.make_directory_temp("", "editor_cutscene_preview_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	s, problems, parsed := format.scene_parse(PROP, context.temp_allocator)
	testing.expectf(t, parsed, "problems: %v", problems)
	write_blob(
		t,
		f,
		PROP_GUID,
		format.scene_write(s, PROP_GUID, 1, .Prefab, allocator = context.temp_allocator),
	)
	write_blob(t, f, CUTSCENE_GUID, cutscene_blob(f, to))
	cutscene.init(&f.cutscenes, &f.world, &f.assets)
	cutscene.register(&f.cutscenes, &f.world)

	init(&f.editor, &f.platform, nil, cutscenes = &f.cutscenes)
	f.editor.assets = &f.assets
	step(f)
	step(
		f,
		link.Load_Scene {
			scenes = {
				{
					guid = transmute([16]u8)SCENE_GUID,
					entities = {
						{
							id = HERO,
							name = "Hero",
							active = true,
							components = {
								{
									id = u64(ecs.TRANSFORM_ID),
									name = "Transform",
									fields = {
										{
											name = "position",
											value = {
												kind = .Number,
												count = 3,
												integer = 0b111,
												ints = {METER, 0, 0, 0},
											},
										},
									},
								},
								{
									id = f.bulb,
									name = "Bulb",
									fields = {{name = "brightness", value = number(1)}},
								},
							},
						},
					},
				},
			},
		},
	)
	f.hero = scene.find(f.editor.scenes, &f.world, 0, HERO)
	testing.expect(t, f.hero != 0)
	testing.expect_value(t, x_of(f, f.hero), METER)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	end_overrides(&f.editor, &f.world, nil)
	destroy(&f.editor)
	cutscene.destroy(&f.cutscenes, &f.world)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	delete(f.out)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, blob: []byte, area := "") {
	buffer: [32]u8
	if area != "" {
		os.make_directory(fmt.tprintf("%s/%s", f.dir, area))
	}
	path := fmt.tprintf(
		"%s/%s%s%s.blob",
		f.dir,
		area,
		"/" if area != "" else "",
		format.guid_format(guid, &buffer),
	)
	testing.expect(t, os.write_entire_file(path, blob) == nil)
}

// cutscene_blob moves the hero from 0 m to `to` m over the first second, ramps its Bulb from 0 to 4, and spawns the
// prop at 3 m.
@(private = "file")
cutscene_blob :: proc(f: ^Fixture, to: f32, key: u64 = 1, hero: u64 = HERO) -> []byte {
	ramp :: proc(name: string, from, to: f32) -> []format.Cutscene_Channel_Contents {
		keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
		keys[0] = {
			time   = 0,
			value  = from,
			interp = .Linear,
		}
		keys[1] = {
			time   = SECOND,
			value  = to,
			interp = .Linear,
		}
		channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
		channels[0] = {
			name = name,
			keys = keys,
		}
		return channels
	}
	section :: proc(
		channels: []format.Cutscene_Channel_Contents,
	) -> []format.Cutscene_Section_Contents {
		sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
		sections[0] = {
			id       = 1,
			start    = 0,
			end      = 2 * SECOND,
			weight   = 1,
			channels = channels,
		}
		return sections
	}
	bindings := make([]format.Cutscene_Binding_Contents, 2, context.temp_allocator)
	bindings[0] = {
		id       = 1,
		kind     = .Possessed,
		name     = "Hero",
		parent   = format.CUTSCENE_NONE,
		asset    = SCENE_GUID,
		entity   = hero,
		rotation = {0, 0, 0, 1},
		scale    = {1, 1, 1},
		// What a player would suspend on the hero, which the preview does not.
		suspend  = ~format.Cutscene_Suspend_Set{},
	}
	bindings[1] = {
		id       = 2,
		kind     = .Spawned,
		name     = "Prop",
		parent   = format.CUTSCENE_NONE,
		asset    = PROP_GUID,
		position = {3 * METER, 0, 0},
		rotation = {0, 0, 0, 1},
		scale    = {1, 1, 1},
	}
	tracks := make([]format.Cutscene_Track_Contents, 3, context.temp_allocator)
	tracks[0] = {
		id       = 1,
		kind     = .Transform,
		name     = "Walk",
		binding  = 0,
		// A player keeps what this track wrote when it finishes. The preview gives the document back all the same.
		finish   = .Keep,
		space    = .Absolute,
		sections = section(ramp("position_x", 0, to)),
	}
	tracks[1] = {
		id        = 2,
		kind      = .Property,
		name      = "Glow",
		binding   = 0,
		component = f.bulb,
		field     = "brightness",
		sections  = section(ramp("value", 0, 4)),
	}
	beat := make([]format.Cutscene_Event_Contents, 1, context.temp_allocator)
	beat[0] = {
		id    = 1,
		start = SECOND / 2,
		end   = SECOND / 2,
		name  = "beat",
	}
	tracks[2] = {
		id      = 3,
		kind    = .Event,
		name    = "Beats",
		binding = format.CUTSCENE_NONE,
		events  = beat,
	}
	guids := make([]format.Guid, 1, context.temp_allocator)
	guids[0] = PROP_GUID
	return format.cutscene_write(
		{
			guid = CUTSCENE_GUID,
			key = key,
			length = 2 * SECOND,
			rate = 30,
			range_end = 2 * SECOND,
			bindings = bindings,
			tracks = tracks,
			guids = guids,
			source_path = "game/cutscenes/walk.cutscene",
		},
		context.temp_allocator,
	)
}

// step polls once with the editor's messages, and returns what the game sent, without the stats, the command list
// and the actions.
@(private = "file")
step :: proc(f: ^Fixture, incoming: ..link.Message) -> []link.Message {
	encoded := make([dynamic]core.Editor_Message, context.temp_allocator)
	for m in incoming {
		buf := make([dynamic]byte, context.temp_allocator)
		link.write_message(&buf, m)
		header, _ := link.read_header(buf[:])
		append(&encoded, core.Editor_Message{kind = header.kind, payload = buf[link.HEADER_SIZE:]})
	}
	clear(&f.out)
	f.despawned = poll(&f.editor, &f.world, nil, 1, encoded[:], &f.out)
	ecs.update_transforms(&f.world)
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
	free_all(f.platform.frame_allocator)
	return messages[:]
}

// frame runs the game's part of a frame in Edit: the preview's clock and evaluation.
@(private = "file")
frame :: proc(f: ^Fixture, dt: time.Duration) {
	changed, despawned := update_cutscene_preview(&f.editor, &f.world, nil, dt)
	if changed {
		ecs.update_transforms(&f.world)
	}
	f.despawned ||= despawned
	free_all(f.platform.frame_allocator)
}

@(private = "file")
number :: proc(x: f64) -> link.Scene_Value {
	return {kind = .Number, count = 1, floats = {x, 0, 0, 0}}
}

@(private = "file")
x_of :: proc(f: ^Fixture, e: ecs.Entity) -> i64 {
	return ecs.get(&f.world, e, ecs.Transform).position.raw.x
}

@(private = "file")
bulb_of :: proc(f: ^Fixture) -> f32 {
	return ecs.get(&f.world, f.hero, Bulb).brightness
}

@(private = "file")
open :: proc(ticket: u64, tick: i32 = 0, unsaved := false) -> link.Cutscene_Preview_Open {
	return {
		ticket = ticket,
		cutscene = transmute([16]u8)CUTSCENE_GUID,
		unsaved = unsaved,
		tick = tick,
	}
}

@(private = "file")
find_message :: proc(messages: []link.Message, $T: typeid) -> (T, bool) {
	for m in messages {
		if v, is := m.(T); is {
			return v, true
		}
	}
	return {}, false
}

@(private = "file")
spawned_prop :: proc(f: ^Fixture) -> ecs.Entity {
	p, open := &f.editor.session.cutscene_previews.open.?
	if !open {
		return 0
	}
	roots := cutscene.spawned_roots(&p.live, &f.world, context.temp_allocator)
	return roots[0] if len(roots) > 0 else 0
}

// The preview binds the scene's hero and spawns the prop, and the world shows the cutscene at each time that the
// editor sends, as an evaluation at that time does. What the game sends the editor is the document's. Close gives the
// document back, and the prop goes.
@(test)
a_preview_shows_the_cutscene_at_each_time_and_close_gives_the_document_back :: proc(
	t: ^testing.T,
) {
	f := setup(t)
	defer teardown(f)
	opened, told := find_message(step(f, open(1, SECOND / 2)), link.Cutscene_Preview_Opened)
	testing.expect(t, told)
	testing.expect_value(t, opened, link.Cutscene_Preview_Opened{1, SECOND / 2, 0, 2 * SECOND})
	testing.expect_value(t, x_of(f, f.hero), 5 * METER)
	testing.expect_value(t, bulb_of(f), 2)
	prop := spawned_prop(f)
	testing.expect(t, prop != 0 && ecs.is_alive(&f.world, prop))
	testing.expect_value(t, x_of(f, prop), 3 * METER)
	testing.expect(t, ecs.active_in_hierarchy(&f.world, prop))
	// The preview holds nothing on the hero: no system is suspended in Edit.
	testing.expect(t, !ecs.has(&f.world, f.hero, ecs.Suspended))

	// The editor hears which entities the preview writes once they change.
	entities, marked := find_message(step(f), link.Overridden_Entities)
	testing.expect(t, marked)
	testing.expect(t, slice.contains(entities.entities, u64(f.hero)))
	testing.expect(t, slice.contains(entities.entities, u64(prop)))

	for tick in ([]i32{SECOND / 4, SECOND, 0, 3 * SECOND / 2, SECOND / 10}) {
		step(f, link.Cutscene_Preview_Time{ticket = 1, tick = tick})
		want := i64(f64(min(tick, SECOND)) / SECOND * 10 * METER)
		testing.expectf(
			t,
			abs(x_of(f, f.hero) - want) <= 1,
			"at %d: x %d, want %d",
			tick,
			x_of(f, f.hero),
			want,
		)
	}

	// The editor hears the document's values, with the fields that the preview holds, and what the world shows, with
	// the preview's ticket and time.
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = SECOND / 2})
	messages := step(f, link.Watch_Entity{entity = u64(f.hero)})
	values, sent := find_message(messages, link.Entity_Values)
	if !sent {
		values, sent = find_message(step(f), link.Entity_Values)
	}
	testing.expect(t, sent)
	// What the world shows is taken before a poll, so it comes from the poll after the watch.
	if len(values.shown) == 0 {
		values, sent = find_message(step(f), link.Entity_Values)
		testing.expect(t, sent)
	}
	testing.expect(
		t,
		slice.contains(
			values.held,
			link.Held_Field{u64(ecs.TRANSFORM_ID), format.scene_field_hash("position")},
		),
	)
	testing.expect(
		t,
		slice.contains(
			values.held,
			link.Held_Field{f.bulb, format.scene_field_hash("brightness")},
		),
	)
	document_x, shown_x: Maybe(i64)
	for c in values.components {
		if c.id == u64(ecs.TRANSFORM_ID) {
			document_x = (^ecs.Transform)(raw_data(c.data)).position.raw.x
		}
	}
	for c in values.shown {
		if c.id == u64(ecs.TRANSFORM_ID) {
			shown_x = (^ecs.Transform)(raw_data(c.data)).position.raw.x
		}
	}
	testing.expect_value(t, document_x, METER)
	sx, has_shown := shown_x.?
	testing.expectf(t, has_shown && abs(sx - 5 * METER) <= 1, "shown x %v", shown_x)
	testing.expect_value(
		t,
		values.shown_preview,
		link.Shown_Preview{ticket = 1, tick = SECOND / 2},
	)

	messages = step(f, link.Cutscene_Preview_Close{ticket = 1})
	_, answered := find_message(messages, link.Cutscene_Preview_Ended)
	testing.expect(t, !answered)
	testing.expect_value(t, x_of(f, f.hero), METER)
	testing.expect_value(t, bulb_of(f), 1)
	testing.expect(t, !ecs.is_alive(&f.world, prop))
	testing.expect(t, f.despawned)
}

// The editor's ticket only goes up: an Open with an older ticket is late, and a message for another ticket is dropped.
// A newer Open ends the preview before it.
@(test)
a_late_ticket_does_nothing_and_a_newer_open_takes_the_preview :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, open(2, SECOND / 2))
	messages := step(f, open(1, SECOND))
	_, answered := find_message(messages, link.Cutscene_Preview_Opened)
	testing.expect(t, !answered)
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = 0})
	step(f, link.Cutscene_Preview_Close{ticket = 1})
	testing.expect_value(t, x_of(f, f.hero), 5 * METER)

	first := spawned_prop(f)
	opened, told := find_message(step(f, open(3, SECOND)), link.Cutscene_Preview_Opened)
	testing.expect(t, told)
	testing.expect_value(t, opened.ticket, 3)
	testing.expect_value(t, x_of(f, f.hero), 10 * METER)
	testing.expect(t, !ecs.is_alive(&f.world, first))
	testing.expect(t, ecs.is_alive(&f.world, spawned_prop(f)))
}

// An edit of a field that the preview holds goes to the document's value, under the preview, and shows once it closes.
@(test)
an_edit_under_the_preview_shows_after_it_closes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, open(1, SECOND / 2))
	testing.expect_value(t, bulb_of(f), 2)
	step(
		f,
		link.Apply_Operations {
			operations = {
				{
					kind = .Set_Field,
					entity = HERO,
					component = f.bulb,
					fields = {{name = "brightness", value = number(7)}},
				},
			},
		},
	)
	testing.expect_value(t, bulb_of(f), 2)
	step(f, link.Cutscene_Preview_Close{ticket = 1})
	testing.expect_value(t, bulb_of(f), 7)
}

// Play, a Load_Scene and a code reload end the preview, and the editor learns why. A preview cannot open outside Edit.
@(test)
the_mode_and_a_load_end_the_preview :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, open(1, SECOND / 2))
	prop := spawned_prop(f)
	ended, told := find_message(step(f, link.Set_Mode{mode = .Play}), link.Cutscene_Preview_Ended)
	testing.expect(t, told)
	testing.expect_value(t, ended, link.Cutscene_Preview_Ended{1, .Mode})
	testing.expect_value(t, x_of(f, f.hero), METER)
	testing.expect(t, !ecs.is_alive(&f.world, prop))
	ended, told = find_message(step(f, open(2)), link.Cutscene_Preview_Ended)
	testing.expect(t, told)
	testing.expect_value(t, ended, link.Cutscene_Preview_Ended{2, .Not_Editing})

	step(f, link.Set_Mode{mode = .Edit})
	step(
		f,
		link.Load_Scene {
			scenes = {
				{
					guid = transmute([16]u8)SCENE_GUID,
					entities = {
						{
							id = HERO,
							name = "Hero",
							active = true,
							components = {{id = u64(ecs.TRANSFORM_ID), name = "Transform"}},
						},
					},
				},
			},
		},
	)
	f.hero = scene.find(f.editor.scenes, &f.world, 0, HERO)
	step(f, open(3, SECOND))
	testing.expect_value(t, x_of(f, f.hero), 10 * METER)
	ended, told = find_message(step(f, link.Load_Scene{}), link.Cutscene_Preview_Ended)
	testing.expect(t, told)
	testing.expect_value(t, ended, link.Cutscene_Preview_Ended{3, .Scene_Loaded})

	step(
		f,
		link.Load_Scene {
			scenes = {
				{
					guid = transmute([16]u8)SCENE_GUID,
					entities = {
						{
							id = HERO,
							name = "Hero",
							active = true,
							components = {{id = u64(ecs.TRANSFORM_ID), name = "Transform"}},
						},
					},
				},
			},
		},
	)
	f.hero = scene.find(f.editor.scenes, &f.world, 0, HERO)
	step(f, open(4, SECOND))
	end_overrides(&f.editor, &f.world, link.Override_End_Reason.Code_Reloaded)
	ended, told = find_message(step(f), link.Cutscene_Preview_Ended)
	testing.expect(t, told)
	testing.expect_value(t, ended, link.Cutscene_Preview_Ended{4, .Code_Reloaded})
	testing.expect_value(t, x_of(f, f.hero), 0)
}

// Play moves the preview on the game's clock, in every frame, and the editor hears the time in each poll. At the range's
// end it stops, once with playing false. A Time pauses it.
@(test)
play_moves_on_the_games_clock_and_stops_at_the_end :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	step(f, open(1))
	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = 0, rate = 1})
	frame(f, time.Second / 4)
	testing.expect_value(t, x_of(f, f.hero), i64(2.5 * METER))
	tick, told := find_message(step(f), link.Cutscene_Preview_Tick)
	testing.expect(t, told)
	testing.expect_value(t, tick, link.Cutscene_Preview_Tick{1, SECOND / 4, true})
	testing.expect_value(t, x_of(f, f.hero), i64(2.5 * METER))

	// Twice as fast, it plays to the end and stops.
	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = SECOND / 2, rate = 2})
	frame(f, time.Second / 4)
	testing.expect_value(t, x_of(f, f.hero), 10 * METER)
	frame(f, time.Second)
	tick, told = find_message(step(f), link.Cutscene_Preview_Tick)
	testing.expect(t, told)
	testing.expect_value(t, tick, link.Cutscene_Preview_Tick{1, 2 * SECOND, false})
	frame(f, time.Second)
	_, told = find_message(step(f), link.Cutscene_Preview_Tick)
	testing.expect(t, !told)

	// A loop goes back to its start; backward play stops at the range's start.
	step(
		f,
		link.Cutscene_Preview_Play {
			ticket = 1,
			tick = SECOND / 2,
			rate = 1,
			looping = true,
			loop_start = 0,
			loop_end = SECOND,
		},
	)
	frame(f, time.Second * 3 / 4)
	testing.expect_value(t, x_of(f, f.hero), i64(2.5 * METER))
	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = SECOND / 2, rate = -1})
	frame(f, time.Second / 4)
	testing.expect_value(t, x_of(f, f.hero), i64(2.5 * METER))
	frame(f, time.Second)
	tick, told = find_message(step(f), link.Cutscene_Preview_Tick)
	testing.expect_value(t, tick, link.Cutscene_Preview_Tick{1, 0, false})

	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = 0, rate = 1})
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = SECOND / 10})
	frame(f, time.Second)
	testing.expect_value(t, x_of(f, f.hero), METER)
	_, told = find_message(step(f), link.Cutscene_Preview_Tick)
	testing.expect(t, !told)
}

@(private = "file", thread_local)
beats: int

// The settings silence a track, which then writes nothing, so its field shows the document's value under the preview,
// and the others play on. With events, the event track's events go out while the preview plays, and never while it is
// scrubbed. Settings with another ticket do nothing.
@(test)
settings_silence_tracks_turn_grains_off_and_send_events_while_playing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	beats = 0
	cutscene.register_event_handler(
		&f.cutscenes,
		"beat",
		proc(_: rawptr, _: cutscene.Player_Handle, _: string, _: []script.Event_Arg) {
			beats += 1
		},
	)
	step(f, open(1, SECOND / 2))
	testing.expect_value(t, bulb_of(f), 2)

	step(f, link.Cutscene_Preview_Settings{ticket = 1, scrub_sound = true, silent = {2}})
	testing.expect_value(t, bulb_of(f), 1)
	testing.expect_value(t, x_of(f, f.hero), 5 * METER)
	step(f, link.Cutscene_Preview_Settings{ticket = 0, scrub_sound = false})
	testing.expect_value(t, bulb_of(f), 1)
	p := &f.editor.session.cutscene_previews.open.?
	testing.expect(t, !p.live.evaluation.no_grains)

	step(f, link.Cutscene_Preview_Settings{ticket = 1, scrub_sound = false})
	testing.expect_value(t, bulb_of(f), 2)
	testing.expect(t, p.live.evaluation.no_grains)

	// Without events, a play over the beat sends nothing.
	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = 0, rate = 1})
	frame(f, time.Second)
	testing.expect_value(t, beats, 0)

	// With them, it sends the beat once; a scrub over it sends nothing.
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = 0})
	step(f, link.Cutscene_Preview_Settings{ticket = 1, scrub_sound = true, events = true})
	step(f, link.Cutscene_Preview_Play{ticket = 1, tick = 0, rate = 1})
	frame(f, time.Second / 4)
	testing.expect_value(t, beats, 0)
	frame(f, time.Second / 2)
	testing.expect_value(t, beats, 1)
	step(f)
	frame(f, 0)
	testing.expect_value(t, beats, 1)
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = 0})
	step(f, link.Cutscene_Preview_Time{ticket = 1, tick = SECOND})
	frame(f, 0)
	testing.expect_value(t, beats, 1)
}

// With unsaved, the preview plays the cook daemon's blob from the preview area, and a newer one there replaces it at the
// same time. Close ends the live blob, and the cooked one loads again.
@(test)
a_new_unsaved_blob_replaces_the_old_at_the_same_time :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	write_blob(t, f, CUTSCENE_GUID, cutscene_blob(f, 20, key = 2), "preview")
	step(f, open(1, SECOND / 2, unsaved = true))
	testing.expect_value(t, x_of(f, f.hero), 10 * METER)

	write_blob(t, f, CUTSCENE_GUID, cutscene_blob(f, 40, key = 3), "preview")
	// The file's time may not have moved within the test, so the preview is told it saw an older one.
	(&f.editor.session.cutscene_previews.open.?).modified = 1
	frame(f, 0)
	testing.expect_value(t, x_of(f, f.hero), 20 * METER)

	step(f, link.Cutscene_Preview_Close{ticket = 1})
	testing.expect_value(t, x_of(f, f.hero), METER)
	step(f, open(2, SECOND / 2))
	testing.expect_value(t, x_of(f, f.hero), 5 * METER)
}

// A newer unsaved blob whose required binding the scene does not have ends the preview, in the frame, while its writes
// are on the world. The document comes back all the same, the kept track's too, and the editor learns why.
@(test)
a_blob_whose_binding_does_not_resolve_ends_the_preview_and_gives_the_document_back :: proc(
	t: ^testing.T,
) {
	f := setup(t)
	defer teardown(f)
	write_blob(t, f, CUTSCENE_GUID, cutscene_blob(f, 10, key = 2), "preview")
	step(f, open(1, SECOND / 2, unsaved = true))
	testing.expect_value(t, x_of(f, f.hero), 5 * METER)
	prop := spawned_prop(f)

	write_blob(t, f, CUTSCENE_GUID, cutscene_blob(f, 10, key = 3, hero = HERO + 1), "preview")
	(&f.editor.session.cutscene_previews.open.?).modified = 1
	context.logger = testlog.expected_errors()
	frame(f, 0)
	testing.expect_value(t, x_of(f, f.hero), METER)
	testing.expect_value(t, bulb_of(f), 1)
	testing.expect(t, !ecs.is_alive(&f.world, prop))
	_, open := f.editor.session.cutscene_previews.open.?
	testing.expect(t, !open)
	ended, told := find_message(step(f), link.Cutscene_Preview_Ended)
	testing.expect(t, told)
	testing.expect_value(t, ended, link.Cutscene_Preview_Ended{1, .Failed})
	testing.expect_value(t, x_of(f, f.hero), METER)
}
