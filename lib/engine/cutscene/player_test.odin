package cutscene

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
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"
import "cinnabar:engine/ui"

// Dial is a component that the test's property track writes.
@(private = "file")
Dial :: struct {
	value: f32,
}

@(private = "file")
DIAL_ID :: ecs.Component_Id(9102)

@(private = "file")
INTRO_GUID :: format.Guid {
	0  = 0x74,
	15 = 1,
}

@(private = "file")
OUTRO_GUID :: format.Guid {
	0  = 0x74,
	15 = 2,
}

@(private = "file")
PROP_GUID :: format.Guid {
	0  = 0x74,
	15 = 3,
}

// A clip that no blob holds.
@(private = "file")
CLIP_GUID :: format.Guid {
	0  = 0x74,
	15 = 4,
}

// The scene that the possessed bindings name. The overrides give their entities, so no scene loads.
@(private = "file")
LEVEL_GUID :: format.Guid {
	0  = 0x74,
	15 = 5,
}

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
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

// Each test thread has its own count of level unloads, which level_generation gives.
@(private = "file", thread_local)
levels: u64

@(private = "file")
Player_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	cutscenes: State,
	dir:       string,
	// The input actions, whose contexts the players push theirs on.
	actions:   core.Input_Actions,
	// Two characters that the cutscenes possess, with their dials at 1 and 2.
	hero:      ecs.Entity,
	rival:     ecs.Entity,
	// The values of the event keys that fired, in order: the Late phase's, and the Fixed phase's.
	fired:     [dynamic]f32,
	fixed:     [dynamic]f32,
}

@(private = "file")
player_setup :: proc(t: ^testing.T) -> ^Player_Fixture {
	f := new(Player_Fixture)
	levels = 0
	f.fired = make([dynamic]f32)
	f.fixed = make([dynamic]f32)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		// The test runner's tracking allocator, so what a player leaves on the heap fails the test.
		heap_allocator = context.allocator,
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		file_size = core.file_size,
		time_seconds = proc() -> f64 {return 0},
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		level_generation = proc() -> u64 {return levels},
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
	script.register_components(&f.world.registry)
	physics.register_components(&f.world.registry)
	ui.register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Dial, DIAL_ID)
	temp, err := os.make_directory_temp("", "cutscene_player_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	prop, problems, parsed := format.scene_parse(PROP, context.temp_allocator)
	testing.expectf(t, parsed, "problems: %v", problems)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(PROP_GUID, &buffer))
	blob := format.scene_write(prop, PROP_GUID, 1, .Prefab, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, blob) == nil)
	init(&f.cutscenes, &f.world, &f.assets, &f.actions)
	register(&f.cutscenes, &f.world)
	register_kind(&f.cutscenes, .Property, {phase = .Fixed, evaluate = dial_track})
	register_kind(
		&f.cutscenes,
		.Presentation,
		{phase = .Late, evaluate = event_track, data = &f.fired},
	)
	// The event tracks, in the Fixed phase, record the number of each probe event.
	register_event_handler(
		&f.cutscenes,
		"probe",
		proc(data: rawptr, _: Player_Handle, _: string, args: []script.Event_Arg) {
			append((^[dynamic]f32)(data), f32(args[0].(f64)))
		},
		&f.fixed,
	)
	f.hero = ecs.spawn(&f.world)
	ecs.add(&f.world, f.hero, Dial{1})
	f.rival = ecs.spawn(&f.world)
	ecs.add(&f.world, f.rival, Dial{2})
	return f
}

@(private = "file")
player_teardown :: proc(f: ^Player_Fixture) {
	destroy(&f.cutscenes, &f.world)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	os.remove_all(f.dir)
	delete(f.dir)
	delete(f.fired)
	delete(f.fixed)
	free(f)
}

// dial_track is the test's property kind: the binding's dial, from each covering section's first key, blended by the
// sections' weights over the dial's own value.
@(private = "file")
dial_track :: proc(ctx: ^Track_Context) {
	entity, bound := track_entity(ctx)
	if !bound {
		return
	}
	b: Blend(f32)
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at, covers := sample_section(ctx, section, ctx.time)
		if !covers {
			continue
		}
		channel := format.cutscene_section_channels(ctx.data, ctx.blob, section)[0]
		blend_add(
			&b,
			format.cutscene_channel_keys(ctx.data, ctx.blob, channel)[0].value,
			at.weight,
		)
	}
	if own, ok := base(ctx, entity, DIAL_ID, offset_of(Dial, value), f32); ok {
		write(ctx, entity, DIAL_ID, offset_of(Dial, value), blend_value(b, own))
	}
}

// event_track is the test's Late events, on presentation tracks: each key is an event at its section's start plus its time,
// which records the key's value in the kind's list when it fires. The keys of a channel named "skipped", which stand_in
// names "amount", are marked to fire when skipped; a skip passes the others.
@(private = "file")
event_track :: proc(ctx: ^Track_Context) {
	fired := (^[dynamic]f32)(ctx.user)
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			if ctx.skipped &&
			   format.blob_string(ctx.data, channel.name) != format.CUTSCENE_LETTERBOX_AMOUNT {
				continue
			}
			for key in format.cutscene_channel_keys(ctx.data, ctx.blob, channel) {
				if fires(ctx, section.start + key.time) {
					append(fired, key.value)
				}
			}
		}
	}
}

@(private = "file")
possessed :: proc(id: u32, name: string) -> format.Cutscene_Binding_Contents {
	return {
		id = id,
		kind = .Possessed,
		name = name,
		parent = format.CUTSCENE_NONE,
		asset = LEVEL_GUID,
		entity = u64(id),
		rotation = {0, 0, 0, 1},
		scale = {1, 1, 1},
	}
}

@(private = "file")
key :: proc(value: f32, at: i32 = 0) -> []format.Cutscene_Channel_Contents {
	keys := make([]format.Cutscene_Key, 1, context.temp_allocator)
	keys[0] = {
		time  = at,
		value = value,
	}
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = "value",
		keys = keys,
	}
	return channels
}

// Cutscene is what the test's cutscenes vary: the dial track's binding and value, an event at the end in each phase,
// a spawned prop, and a clip.
@(private = "file")
Cutscene :: struct {
	guid:    format.Guid,
	key:     u64,
	length:  i32,
	clock:   format.Cutscene_Clock,
	// The dial track's binding, 0 for the hero and 1 for the rival, and the value that it writes.
	binding: u32,
	value:   f32,
	finish:  format.Cutscene_Finish,
	// An event at the end, with the value 9, on the Late and the Fixed phases.
	events:  bool,
	prop:    bool,
	// Where the prop spawns, in meters along x.
	prop_x:  f64,
	clip:    format.Guid,
	// What every binding suspends, and whether it keeps a body's velocity.
	suspend: format.Cutscene_Suspend_Set,
	keep:    bool,
	// The input context that the cutscene pushes, and the UI documents that it hides.
	input:   string,
	hide_ui: []format.Guid,
}

@(private = "file")
write_cutscene :: proc(t: ^testing.T, f: ^Player_Fixture, c: Cutscene) {
	c := c
	if c.length == 0 {
		c.length = SECOND
	}
	if c.key == 0 {
		c.key = 1
	}
	bindings := make([dynamic]format.Cutscene_Binding_Contents, context.temp_allocator)
	append(&bindings, possessed(1, "Hero"), possessed(2, "Rival"))
	if c.prop {
		append(
			&bindings,
			format.Cutscene_Binding_Contents {
				id = 3,
				kind = .Spawned,
				name = "Prop",
				parent = format.CUTSCENE_NONE,
				asset = PROP_GUID,
				position = ecs.position_from_meters({c.prop_x, 0, 0}).raw,
				rotation = {0, 0, 0, 1},
				scale = {1, 1, 1},
			},
		)
	}
	for &b in bindings {
		b.suspend = c.suspend
		if c.keep {
			b.flags += {.Keep_Velocity}
		}
	}
	tracks := make([dynamic]format.Cutscene_Track_Contents, context.temp_allocator)
	dial := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	dial[0] = {
		id       = 1,
		start    = 0,
		end      = c.length,
		weight   = 1,
		channels = key(c.value),
	}
	append(
		&tracks,
		format.Cutscene_Track_Contents {
			id = 1,
			kind = .Property,
			component = u64(DIAL_ID),
			field = "value",
			name = "Dial",
			binding = c.binding,
			finish = c.finish,
			sections = dial,
		},
	)
	if c.events {
		events := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
		events[0] = {
			id       = 2,
			start    = 0,
			end      = c.length,
			weight   = 1,
			channels = key(9, c.length),
		}
		probe := make([]format.Cutscene_Event_Contents, 1, context.temp_allocator)
		probe[0] = {
			id     = 1,
			start  = c.length,
			end    = c.length,
			name   = "probe",
			values = slice.clone(
				[]format.Cutscene_Event_Value_Contents{{kind = .Number, number = 9}},
				context.temp_allocator,
			),
		}
		append(
			&tracks,
			format.Cutscene_Track_Contents {
				id = 2,
				kind = .Presentation,
				name = "Late events",
				binding = format.CUTSCENE_NONE,
				sections = stand_in(events),
			},
			format.Cutscene_Track_Contents {
				id = 3,
				kind = .Event,
				name = "Fixed events",
				binding = format.CUTSCENE_NONE,
				events = probe,
			},
		)
	}
	if c.clip != {} {
		clip := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
		clip[0] = {
			id     = 4,
			start  = 0,
			end    = c.length,
			weight = 1,
			asset  = c.clip,
			speed  = 1,
		}
		append(
			&tracks,
			format.Cutscene_Track_Contents {
				id = 4,
				kind = .Animation,
				name = "Clip",
				binding = 0,
				sections = clip,
			},
		)
	}
	blob := format.cutscene_write(
		{
			guid = c.guid,
			key = c.key,
			length = c.length,
			rate = 30,
			clock = c.clock,
			range_end = c.length,
			bindings = bindings[:],
			tracks = tracks[:],
			source_path = "game/cutscenes/player.cutscene",
			input_context = c.input,
			hide_ui = c.hide_ui,
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, c.guid, blob))
}

// cast_of is the overrides that give the possessed bindings the hero and the rival.
@(private = "file")
cast_of :: proc(f: ^Player_Fixture) -> []Binding_Override {
	overrides := make([]Binding_Override, 2, context.temp_allocator)
	overrides[0] = {Binding_Id(1), f.hero}
	overrides[1] = {"Rival", f.rival}
	return overrides
}

@(private = "file")
context_of :: proc(f: ^Player_Fixture) -> Player_Context {
	return {world = &f.world, dt = FRAME}
}

// FRAME is the real duration of a test frame.
@(private = "file")
FRAME :: time.Second / 60

// frame runs a frame as game_update does: the players' update, then the ticks of a 60th of a second and the Late
// stage.
@(private = "file")
frame :: proc(f: ^Player_Fixture) {
	update(&f.cutscenes, context_of(f))
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

@(private = "file")
dial :: proc(f: ^Player_Fixture, e: ecs.Entity) -> f32 {
	return ecs.get(&f.world, e, Dial).value
}

// prop_of is the spawned prop's root, while its player is live.
@(private = "file")
prop_of :: proc(f: ^Player_Fixture, h: Player_Handle) -> ecs.Entity {
	e, live := player_evaluation(&f.cutscenes, h)
	if !live {
		return 0
	}
	root, _ := binding_entity(&e.bindings, &f.world, 2)
	return root
}

// prefab_users is how many users hold the prop's prefab loaded.
@(private = "file")
prefab_users :: proc(f: ^Player_Fixture) -> u32 {
	h, loaded := asset.find(&f.assets, PROP_GUID)
	if !loaded {
		return 0
	}
	return f.assets.records[h.index].users
}

@(private = "file")
expect_status :: proc(
	t: ^testing.T,
	f: ^Player_Fixture,
	h: Player_Handle,
	want: Player_Status,
	loc := #caller_location,
) {
	testing.expect_value(t, status(&f.cutscenes, h), want, loc = loc)
}

// The diagram allows exactly these changes, and the commands and update walk each of them.
@(test)
each_allowed_change_is_walked_and_the_writer_refuses_the_rest :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := player_setup(t)
	defer player_teardown(f)
	walk :: [?][2]Player_Status {
		{.Gone, .Loading},
		{.Loading, .Ready},
		{.Loading, .Restored},
		{.Loading, .Failed},
		{.Ready, .Playing},
		{.Ready, .Skipping},
		{.Ready, .Finishing},
		{.Ready, .Failed},
		{.Playing, .Paused},
		{.Playing, .Skipping},
		{.Playing, .Finishing},
		{.Playing, .Failed},
		{.Paused, .Playing},
		{.Paused, .Skipping},
		{.Paused, .Finishing},
		{.Paused, .Failed},
		{.Skipping, .Playing},
		{.Skipping, .Finishing},
		{.Skipping, .Failed},
		{.Finishing, .Restored},
		{.Finishing, .Failed},
		{.Restored, .Gone},
		{.Failed, .Gone},
	}
	for from in Player_Status {
		for to in Player_Status {
			listed := false
			for change in walk {
				listed = listed || change == {from, to}
			}
			testing.expectf(t, allowed(from, to) == listed, "%v to %v", from, to)
		}
	}

	write_cutscene(t, f, {guid = INTRO_GUID, value = 7})
	seen := make(map[[2]Player_Status]bool, context.temp_allocator)
	last := make(map[Player_Handle]Player_Status, context.temp_allocator)
	record :: proc(
		f: ^Player_Fixture,
		seen: ^map[[2]Player_Status]bool,
		last: ^map[Player_Handle]Player_Status,
	) {
		for event in player_events(&f.cutscenes) {
			seen[{last[event.player], event.status}] = true
			last[event.player] = event.status
		}
		end_frame(&f.cutscenes)
	}
	w := &f.world
	s := &f.cutscenes
	desc := Play_Desc {
		cutscene  = INTRO_GUID,
		overrides = cast_of(f),
	}
	// Gone, Loading, Ready, Playing, Paused, Playing, Skipping, Finishing, Restored, Gone.
	h, _ := load(s, w, desc)
	update(s, context_of(f))
	testing.expect_value(t, start(s, w, h), Command_Result.Done)
	testing.expect_value(t, pause(s, w, h), Command_Result.Done)
	testing.expect_value(t, resume(s, w, h), Command_Result.Done)
	testing.expect_value(t, skip(s, w, h), Command_Result.Done)
	update(s, context_of(f))
	testing.expect_value(t, release(s, w, h), Command_Result.Done)
	record(f, &seen, &last)
	// Loading, Restored; and Loading, Failed.
	h, _ = load(s, w, desc)
	testing.expect_value(t, stop(s, w, h), Command_Result.Done)
	missing, _ := play(s, w, {cutscene = OUTRO_GUID})
	update(s, context_of(f))
	expect_status(t, f, missing, .Failed)
	record(f, &seen, &last)
	// Ready, Skipping; Ready, Finishing; Playing, Finishing; Paused, Skipping; Paused, Finishing.
	for path in ([?][]proc(_: ^State, _: ^ecs.World, _: Player_Handle) -> Command_Result{{skip}, {stop}, {start, stop}, {start, pause, skip}, {start, pause, stop}}) {
		h, _ = load(s, w, desc)
		update(s, context_of(f))
		for command in path {
			testing.expect_value(t, command(s, w, h), Command_Result.Done)
		}
		update(s, context_of(f))
		expect_status(t, f, h, .Restored)
		record(f, &seen, &last)
	}
	// Skipping goes back to Playing after a skip of a range, and each live state can fail: change_cutscene
	// walks these.
	for from in ([?]Player_Status{.Ready, .Playing, .Paused, .Skipping, .Finishing}) {
		h, _ = load(s, w, desc)
		update(s, context_of(f))
		p := &s.players[h.slot]
		slot := int(h.slot)
		switch from {
		case .Playing:
			change_cutscene(s, w, slot, moved(p, .Playing))
		case .Paused:
			change_cutscene(s, w, slot, moved(p, .Playing))
			change_cutscene(s, w, slot, moved(p, .Paused))
		case .Skipping:
			change_cutscene(s, w, slot, skipping(p, SECOND))
			change_cutscene(s, w, slot, moved(p, .Playing))
			change_cutscene(s, w, slot, skipping(p, SECOND))
		case .Finishing:
			change_cutscene(s, w, slot, moved(p, .Finishing))
		case .Gone, .Loading, .Ready, .Restored, .Failed:
		}
		changed, _ := change_cutscene(
			s,
			w,
			int(h.slot),
			Player_Failed{Asset_Failure{INTRO_GUID, .Missing}},
		)
		testing.expect(t, changed)
		testing.expect_value(t, release(s, w, h), Command_Result.Done)
		record(f, &seen, &last)
	}
	for change in walk {
		testing.expectf(
			t,
			seen[change],
			"the change from %v to %v was not walked",
			change[0],
			change[1],
		)
	}
	testing.expect_value(t, dial(f, f.hero), 1)

	// The writer refuses what the diagram does not allow, and the player stays as it was.
	h, _ = load(s, w, desc)
	testing.expect_value(t, pause(s, w, h), Command_Result.Refused)
	update(s, context_of(f))
	testing.expect_value(t, resume(s, w, h), Command_Result.Refused)
	testing.expect_value(t, release(s, w, h), Command_Result.Refused)
	changed, _ := change_cutscene(s, w, int(h.slot), Player_Loading{})
	testing.expect(t, !changed)
	changed, _ = change_cutscene(s, w, int(h.slot), Player_Restored{})
	testing.expect(t, !changed)
	changed, _ = change_cutscene(s, w, int(h.slot), nil)
	testing.expect(t, !changed)
	expect_status(t, f, h, .Ready)
	stop(s, w, h)
	update(s, context_of(f))
	expect_status(t, f, h, .Restored)
	testing.expect_value(t, start(s, w, h), Command_Result.Gone)
}

// A cutscene with two possessed characters and a spawned prop plays to its end, and is Restored: the dials are as
// they were, the prop is gone, the cutscene's assets are unloaded, and the events at the end fired once in each phase.
@(test)
a_cutscene_played_to_the_end_is_restored_and_the_world_is_as_it_was :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, events = true, prop = true})
	h, ok := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	testing.expect(t, ok)
	expect_status(t, f, h, .Loading)
	frame(f)
	expect_status(t, f, h, .Playing)
	prop := prop_of(f, h)
	testing.expect(t, prop != 0)
	testing.expect(
		t,
		!ecs.has(&f.world, prop, ecs.Loading),
		"the prop shows while the cutscene plays",
	)
	// The player holds the prefab, and so does the instance that spawn_prefab made.
	testing.expect_value(t, prefab_users(f), 2)
	testing.expect_value(t, dial(f, f.hero), 7)
	testing.expect_value(t, dial(f, f.rival), 2)

	for _ in 0 ..< 70 {
		if status(&f.cutscenes, h) != .Playing {
			break
		}
		frame(f)
	}
	expect_status(t, f, h, .Restored)
	testing.expect_value(t, dial(f, f.hero), 1)
	testing.expect_value(t, dial(f, f.rival), 2)
	testing.expect(t, !ecs.is_alive(&f.world, prop), "the prop is gone")
	testing.expect_value(t, prefab_users(f), 1)
	testing.expect_value(t, len(f.fired), 1)
	testing.expect_value(t, len(f.fixed), 1)
}

// On the real clock, a cutscene can reach its end with no Late stage, as while the game is paused. Its last update
// fires the events at the end that no phase has fired, once.
@(test)
the_events_at_the_end_fire_once_when_no_stage_reaches_the_end :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, clock = .Real, value = 7, events = true})
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	update(&f.cutscenes, context_of(f))
	advance_real(&f.cutscenes, &f.world, 2 * time.Second)
	t_now, _ := player_time(&f.cutscenes, h)
	testing.expect_value(t, t_now, SECOND)
	testing.expect_value(t, len(f.fixed), 1)
	testing.expect_value(t, len(f.fired), 0)
	update(&f.cutscenes, context_of(f))
	expect_status(t, f, h, .Restored)
	testing.expect_value(t, len(f.fixed), 1)
	testing.expect_value(t, len(f.fired), 1)
	testing.expect_value(t, dial(f, f.hero), 1)
}

// A cutscene whose clip does not load fails in Loading with the clip as the reason, and leaves nothing: no spawned
// prop, no dial changed, and its assets unloaded.
@(test)
a_missing_clip_fails_in_loading_and_leaves_nothing :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, prop = true, clip = CLIP_GUID})
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	expect_status(t, f, h, .Failed)
	failure, failed := player_failure(&f.cutscenes, h)
	testing.expect(t, failed)
	testing.expect_value(t, failure.(Asset_Failure), Asset_Failure{CLIP_GUID, .Reference_Missing})
	testing.expect_value(t, dial(f, f.hero), 1)
	_, prefab_loaded := asset.find(&f.assets, PROP_GUID)
	testing.expect(t, !prefab_loaded, "the prefab is unloaded")
	props := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {ecs.TRANSFORM_ID}, &props)
	testing.expect_value(t, len(props), 0)

	// A required binding that resolves to nothing fails too, with the binding as the reason.
	write_cutscene(t, f, {guid = OUTRO_GUID, value = 7, prop = true})
	unbound, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)[:1]})
	scenes: scene.Scenes
	scene.init_scenes(&scenes, &f.platform, &f.assets)
	defer scene.destroy_scenes(&scenes)
	update(&f.cutscenes, {world = &f.world, scenes = &scenes})
	failure, failed = player_failure(&f.cutscenes, unbound)
	testing.expect(t, failed)
	testing.expect_value(
		t,
		failure.(Binding_Failure),
		Binding_Failure{index = 1, reason = .Missing},
	)
	ecs.collect(&f.world, {ecs.TRANSFORM_ID}, &props)
	testing.expect_value(t, len(props), 0)
}

// After Restored, every command through the handle does nothing and reports that the cutscene is gone. Once the
// handle is released, its slot goes to another player, which the old handle does not reach.
@(test)
a_call_through_a_stale_handle_does_nothing :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7})
	w := &f.world
	s := &f.cutscenes
	old, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	stop(s, w, old)
	frame(f)
	expect_status(t, f, old, .Restored)
	testing.expect_value(t, start(s, w, old), Command_Result.Gone)
	testing.expect_value(t, pause(s, w, old), Command_Result.Gone)
	testing.expect_value(t, resume(s, w, old), Command_Result.Gone)
	testing.expect_value(t, stop(s, w, old), Command_Result.Gone)
	testing.expect_value(t, skip(s, w, old), Command_Result.Gone)
	testing.expect_value(t, set_time(s, w, old, SECOND / 2), Command_Result.Gone)
	expect_status(t, f, old, .Restored)
	testing.expect_value(t, release(s, w, old), Command_Result.Done)
	expect_status(t, f, old, .Gone)
	testing.expect_value(t, release(s, w, old), Command_Result.Gone)

	fresh, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	testing.expect_value(t, fresh.slot, old.slot)
	testing.expect(t, fresh.generation != old.generation)
	frame(f)
	testing.expect_value(t, stop(s, w, old), Command_Result.Gone)
	testing.expect_value(t, pause(s, w, old), Command_Result.Gone)
	expect_status(t, f, fresh, .Playing)
	testing.expect_value(t, status(s, {}), Player_Status.Gone)
	testing.expect_value(t, dial(f, f.hero), 7)
}

// Two players that write one dial: the later start wins at one priority, and the higher priority wins over a later
// start. Whichever ends first, the other writes the dial on, and the dial returns to its first value at the end.
@(test)
two_players_that_write_one_field_follow_priority_and_give_it_back :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, length = 4 * SECOND, value = 10})
	write_cutscene(t, f, {guid = OUTRO_GUID, length = 4 * SECOND, value = 20})
	w := &f.world
	s := &f.cutscenes
	for first_ends in ([?]bool{true, false}) {
		a, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
		b, _ := play(s, w, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
		frame(f)
		testing.expect_value(t, dial(f, f.hero), 20)
		ending, staying, left := a, b, f32(20)
		if !first_ends {
			ending, staying, left = b, a, 10
		}
		stop(s, w, ending)
		frame(f)
		expect_status(t, f, ending, .Restored)
		testing.expect_value(t, dial(f, f.hero), left)
		stop(s, w, staying)
		frame(f)
		testing.expect_value(t, dial(f, f.hero), 1)
		release(s, w, a)
		release(s, w, b)
	}

	high, _ := play(s, w, {cutscene = INTRO_GUID, priority = 1, overrides = cast_of(f)})
	low, _ := play(s, w, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
	frame(f)
	testing.expect_value(t, dial(f, f.hero), 10)
	stop(s, w, high)
	frame(f)
	testing.expect_value(t, dial(f, f.hero), 20)
	stop(s, w, low)
	frame(f)
	testing.expect_value(t, dial(f, f.hero), 1)
}

// A soft restart during Playing restores and frees every player: the dials are back, the prop and the cutscene's
// assets are gone, and every handle is stale.
@(test)
a_reset_during_play_leaks_nothing :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, length = 4 * SECOND, value = 7, prop = true})
	write_cutscene(t, f, {guid = OUTRO_GUID, length = 4 * SECOND, binding = 1, value = 8})
	w := &f.world
	s := &f.cutscenes
	for _ in 0 ..< 2 {
		a, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
		b, _ := play(s, w, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
		loading, _ := load(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
		for _ in 0 ..< 5 {
			frame(f)
		}
		_ = loading
		prop := prop_of(f, a)
		testing.expect(t, ecs.is_alive(w, prop))
		users := prefab_users(f)
		testing.expect_value(t, dial(f, f.rival), 8)
		// What game_shutdown does before a soft restart.
		despawned := reset(s, w)
		testing.expect_value(t, despawned, 2)
		testing.expect_value(t, dial(f, f.hero), 1)
		testing.expect_value(t, dial(f, f.rival), 2)
		testing.expect(t, !ecs.is_alive(w, prop))
		testing.expect_value(t, prefab_users(f), users - 2)
		for &p in s.players {
			testing.expect(t, p.state == nil)
		}
		expect_status(t, f, a, .Gone)
		expect_status(t, f, b, .Gone)
		end_frame(s)
	}
}

// A reload that moves the spawned prop resolves the bindings again: the prop spawns again where the new blob says, and
// shows, and the player plays on.
@(test)
a_reload_that_changes_the_bindings_resolves_them_again :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, length = 4 * SECOND, value = 7, prop = true})
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	before := prop_of(f, h)
	testing.expect(t, before != 0)

	write_cutscene(
		t,
		f,
		{guid = INTRO_GUID, key = 2, length = 4 * SECOND, value = 7, prop = true, prop_x = 3},
	)
	frame(f)
	expect_status(t, f, h, .Playing)
	after := prop_of(f, h)
	testing.expect(t, !ecs.is_alive(&f.world, before), "the old prop is gone")
	testing.expect(t, after != 0 && after != before)
	testing.expect(t, !ecs.has(&f.world, after, ecs.Loading), "the new prop shows")
	x := ecs.position_to_meters(ecs.get(&f.world, after, ecs.Transform).position).x
	testing.expectf(t, abs(x - 3) < 1e-6, "the new prop is at %v", x)
	testing.expect_value(t, dial(f, f.hero), 7)

	// A reload that only changes a track keeps the prop.
	write_cutscene(
		t,
		f,
		{guid = INTRO_GUID, key = 3, length = 4 * SECOND, value = 8, prop = true, prop_x = 3},
	)
	frame(f)
	testing.expect_value(t, prop_of(f, h), after)
	testing.expect_value(t, dial(f, f.hero), 8)
}

// A player with a track set to keep and one with a track set to restore write one dial. Whichever ends first, the dial
// has its first value when both have ended, as one track that wrote it is set to restore.
@(test)
a_restore_track_wins_over_a_keep_track_in_either_order :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, length = 4 * SECOND, value = 10, finish = .Keep})
	write_cutscene(t, f, {guid = OUTRO_GUID, length = 4 * SECOND, value = 20})
	w := &f.world
	s := &f.cutscenes
	for keep_ends_first in ([?]bool{true, false}) {
		keep, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
		restore, _ := play(s, w, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
		frame(f)
		testing.expect_value(t, dial(f, f.hero), 20)
		first, second := restore, keep
		if keep_ends_first {
			first, second = keep, restore
		}
		stop(s, w, first)
		frame(f)
		stop(s, w, second)
		frame(f)
		testing.expectf(
			t,
			dial(f, f.hero) == 1,
			"keep ends first: %v: the dial is %v",
			keep_ends_first,
			dial(f, f.hero),
		)
		release(s, w, keep)
		release(s, w, restore)
	}
}

// A scene load unloads the level: every entity is gone, and new ones take their places. The next update frees every
// player. The restore writes nothing to the new entities, and the release of the gone prop does nothing. A player
// made after the unload, before that update, belongs to the new level and plays on.
@(test)
a_new_level_frees_the_players_of_the_old_one :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, length = 4 * SECOND, value = 7, prop = true})
	w := &f.world
	s := &f.cutscenes
	old, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	for _ in 0 ..< 3 {
		frame(f)
	}
	prop := prop_of(f, old)
	users := prefab_users(f)

	ecs.despawn_all(w)
	levels += 1
	f.hero = ecs.spawn(w)
	ecs.add(w, f.hero, Dial{4})
	f.rival = ecs.spawn(w)
	ecs.add(w, f.rival, Dial{5})
	fresh, _ := play(s, w, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	expect_status(t, f, old, .Gone)
	testing.expect_value(t, prefab_users(f), users - 1)
	testing.expect_value(t, update(s, context_of(f)), 0)
	expect_status(t, f, fresh, .Playing)
	testing.expect(t, !ecs.is_alive(w, prop))
	testing.expect_value(t, dial(f, f.rival), 5)
	stop(s, w, fresh)
	frame(f)
	testing.expect_value(t, dial(f, f.hero), 4)
}

// A loaded player keeps its spawned prop hidden in Ready, and start shows it at once.
@(test)
start_shows_the_spawned_entities_of_a_ready_player :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, prop = true})
	h, _ := load(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	update(&f.cutscenes, context_of(f))
	expect_status(t, f, h, .Ready)
	prop := prop_of(f, h)
	testing.expect(t, ecs.has(&f.world, prop, ecs.Loading), "the prop is hidden in Ready")
	testing.expect_value(t, dial(f, f.hero), 1)
	testing.expect_value(t, start(&f.cutscenes, &f.world, h), Command_Result.Done)
	testing.expect(
		t,
		!ecs.has(&f.world, prop, ecs.Loading),
		"the prop shows once the player starts",
	)
}

// suspended_count is how many holders suspend a system on an entity.
@(private = "file")
suspended_count :: proc(f: ^Player_Fixture, e: ecs.Entity, system: ecs.Suspend) -> u16 {
	s := ecs.get(&f.world, e, ecs.Suspended)
	return s.counts[system] if s != nil else 0
}

// A binding suspends what the cutscene says on its entity from the moment that it resolves, in Loading. Two players
// that possess one entity both hold it, and it is free only when both have ended.
@(test)
two_players_both_release_an_entity_before_it_runs_again :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, suspend = {.Behaviours, .AI}})
	write_cutscene(t, f, {guid = OUTRO_GUID, value = 8, suspend = {.AI, .Navigation}})
	first, _ := load(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	expect_status(t, f, first, .Ready)
	testing.expect_value(t, suspended_count(f, f.hero, .Behaviours), 1)
	testing.expect_value(t, suspended_count(f, f.hero, .AI), 1)
	testing.expect_value(t, suspended_count(f, f.rival, .AI), 1)
	testing.expect_value(t, suspended_count(f, f.hero, .Physics), 0)

	second, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
	frame(f)
	expect_status(t, f, second, .Playing)
	testing.expect_value(t, suspended_count(f, f.hero, .AI), 2)
	testing.expect_value(t, suspended_count(f, f.hero, .Navigation), 1)

	stop(&f.cutscenes, &f.world, first)
	frame(f)
	expect_status(t, f, first, .Restored)
	testing.expect_value(t, suspended_count(f, f.hero, .Behaviours), 0)
	testing.expect(
		t,
		ecs.suspended(&f.world, f.hero, .AI),
		"the second player still holds the hero",
	)
	stop(&f.cutscenes, &f.world, second)
	frame(f)
	expect_status(t, f, second, .Restored)
	testing.expect(t, !ecs.has(&f.world, f.hero, ecs.Suspended), "the hero is free")
	testing.expect(t, !ecs.has(&f.world, f.rival, ecs.Suspended), "the rival is free")
}

// A player that fails in Loading, at its second binding after its first suspended the hero, resumes the hero. A reset,
// as a soft restart or a new level does, resumes what a live player held.
@(test)
a_failed_player_resumes_what_it_suspended :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := player_setup(t)
	defer player_teardown(f)
	scenes: scene.Scenes
	scene.init_scenes(&scenes, &f.platform, &f.assets)
	defer scene.destroy_scenes(&scenes)
	every := format.CUTSCENE_SUSPEND_ALL
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, suspend = every})
	// Only the hero is given, so the rival, the second binding, is missing.
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)[:1]})
	update(&f.cutscenes, {world = &f.world, scenes = &scenes})
	expect_status(t, f, h, .Failed)
	failure, _ := player_failure(&f.cutscenes, h)
	testing.expect_value(
		t,
		failure.(Binding_Failure),
		Binding_Failure{index = 1, reason = .Missing},
	)
	testing.expect(t, !ecs.has(&f.world, f.hero, ecs.Suspended), "the hero is free")

	write_cutscene(t, f, {guid = OUTRO_GUID, value = 7, suspend = every})
	live, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
	update(&f.cutscenes, {world = &f.world, scenes = &scenes})
	expect_status(t, f, live, .Playing)
	testing.expect(t, ecs.suspended(&f.world, f.hero, .Behaviours))
	reset(&f.cutscenes, &f.world)
	testing.expect(t, !ecs.has(&f.world, f.hero, ecs.Suspended), "a reset frees the hero")
	testing.expect(t, !ecs.has(&f.world, f.rival, ecs.Suspended), "and the rival")
}

// A spawned binding starts suspended, while it is hidden in Ready, so its behaviours do not start when it shows. It
// goes with the player.
@(test)
a_spawned_binding_starts_suspended :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, prop = true, suspend = {.Behaviours}})
	h, _ := load(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	prop := prop_of(f, h)
	testing.expect(t, ecs.has(&f.world, prop, ecs.Loading), "the prop is hidden in Ready")
	testing.expect(t, ecs.suspended(&f.world, prop, .Behaviours))
	start(&f.cutscenes, &f.world, h)
	testing.expect(t, !ecs.has(&f.world, prop, ecs.Loading))
	testing.expect(t, ecs.suspended(&f.world, prop, .Behaviours), "it shows suspended")
	stop(&f.cutscenes, &f.world, h)
	frame(f)
	testing.expect(t, !ecs.is_alive(&f.world, prop))
}

// A dynamic body that a binding suspended is at rest when the player ends, unless the binding keeps its velocity.
@(test)
a_resumed_body_is_at_rest_unless_its_binding_keeps_its_velocity :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	for e in ([?]ecs.Entity{f.hero, f.rival}) {
		ecs.add(&f.world, e, physics.Rigid_Body{motion = .Dynamic})
		ecs.add(
			&f.world,
			e,
			physics.Physics_Body{linear_velocity = {3, 0, 0}, angular_velocity = {0, 1, 0}},
		)
	}
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, suspend = {.Physics}})
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	testing.expect(t, ecs.suspended(&f.world, f.hero, .Physics))
	stop(&f.cutscenes, &f.world, h)
	frame(f)
	pb := ecs.get(&f.world, f.hero, physics.Physics_Body)
	testing.expect_value(t, pb.linear_velocity, [3]f32{})
	testing.expect_value(t, pb.angular_velocity, [3]f32{})

	ecs.get(&f.world, f.rival, physics.Physics_Body).linear_velocity = {3, 0, 0}
	write_cutscene(t, f, {guid = OUTRO_GUID, value = 7, suspend = {.Physics}, keep = true})
	kept, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
	frame(f)
	stop(&f.cutscenes, &f.world, kept)
	frame(f)
	testing.expect_value(
		t,
		ecs.get(&f.world, f.rival, physics.Physics_Body).linear_velocity,
		[3]f32{3, 0, 0},
	)

	// With a player that keeps and one that does not on one body, the body keeps its velocity whichever ends first.
	for keeper_first in ([?]bool{true, false}) {
		ecs.get(&f.world, f.hero, physics.Physics_Body).linear_velocity = {3, 0, 0}
		at_rest, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
		keeper, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
		frame(f)
		stop(&f.cutscenes, &f.world, keeper if keeper_first else at_rest)
		frame(f)
		stop(&f.cutscenes, &f.world, at_rest if keeper_first else keeper)
		frame(f)
		testing.expect(t, !ecs.suspended(&f.world, f.hero, .Physics))
		testing.expect_value(
			t,
			ecs.get(&f.world, f.hero, physics.Physics_Body).linear_velocity,
			[3]f32{3, 0, 0},
		)
	}
}

// The input context and the hidden documents belong to a playing cutscene, not a Ready one. start pushes the context,
// which blocks the gameplay action for every player and lets the skip action through, and hides the HUD, active or
// not. The end gives both back. Each of two cutscenes gives back only its own.
@(test)
a_playing_cutscene_blocks_gameplay_input_and_hides_the_hud :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	MOVE, SKIP :: 0, 1
	_, err := core.input_contexts_define(&f.actions.contexts, "cutscene", .Only, {SKIP})
	testing.expect_value(t, err, core.Input_Context_Error.None)
	HUD :: format.Guid {
		0  = 0x74,
		15 = 9,
	}
	MENU :: format.Guid {
		0  = 0x74,
		15 = 10,
	}
	hud := ecs.spawn(&f.world)
	ecs.add(&f.world, hud, ui.Ui_Document{document = HUD, visible = true})
	menu := ecs.spawn(&f.world)
	ecs.add(&f.world, menu, ui.Ui_Document{document = MENU, visible = true})
	second_hud := ecs.spawn(&f.world)
	ecs.add(&f.world, second_hud, ui.Ui_Document{document = HUD, visible = true})
	ecs.set_active(&f.world, second_hud, false)
	hidden := []format.Guid{HUD}
	write_cutscene(t, f, {guid = INTRO_GUID, value = 7, input = "cutscene", hide_ui = hidden})
	h, _ := load(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	expect_status(t, f, h, .Ready)
	testing.expect(
		t,
		core.input_contexts_allows(&f.actions.contexts, 0, MOVE),
		"a Ready cutscene blocks nothing",
	)
	testing.expect(t, !ecs.suspended(&f.world, hud, .Ui))

	start(&f.cutscenes, &f.world, h)
	testing.expect(
		t,
		!core.input_contexts_allows(&f.actions.contexts, 0, MOVE),
		"gameplay reads nothing",
	)
	testing.expect(
		t,
		!core.input_contexts_allows(&f.actions.contexts, 3, MOVE),
		"for every player",
	)
	testing.expect(
		t,
		core.input_contexts_allows(&f.actions.contexts, 0, SKIP),
		"the skip still reads",
	)
	testing.expect(t, ecs.suspended(&f.world, hud, .Ui))
	testing.expect(t, ecs.suspended(&f.world, second_hud, .Ui), "an inactive HUD is hidden too")
	testing.expect(t, !ecs.suspended(&f.world, menu, .Ui))

	write_cutscene(t, f, {guid = OUTRO_GUID, value = 7, input = "cutscene", hide_ui = hidden})
	other, _ := play(&f.cutscenes, &f.world, {cutscene = OUTRO_GUID, overrides = cast_of(f)})
	frame(f)
	testing.expect_value(t, f.actions.contexts.push_count, 2)
	testing.expect_value(t, suspended_count(f, hud, .Ui), 2)
	stop(&f.cutscenes, &f.world, h)
	frame(f)
	testing.expect_value(t, f.actions.contexts.push_count, 1)
	testing.expect(
		t,
		!core.input_contexts_allows(&f.actions.contexts, 0, MOVE),
		"the second still blocks",
	)
	testing.expect_value(t, suspended_count(f, hud, .Ui), 1)
	stop(&f.cutscenes, &f.world, other)
	frame(f)
	testing.expect_value(t, f.actions.contexts.push_count, 0)
	testing.expect(t, core.input_contexts_allows(&f.actions.contexts, 0, MOVE))
	testing.expect(t, !ecs.has(&f.world, hud, ecs.Suspended))
	testing.expect(t, !ecs.has(&f.world, second_hud, ecs.Suspended))

	// A context that the game did not define is not pushed, with a warning.
	write_cutscene(t, f, {guid = INTRO_GUID, key = 2, value = 7, input = "cinematic"})
	missing, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	expect_status(t, f, missing, .Playing)
	testing.expect_value(t, f.actions.contexts.push_count, 0)
}

// write_skippable writes a cutscene of 2 s for the skip's tests: the hero's dial at 3 in its first second and at 7 in
// its second, kept at the end; Late events at 0.25 s (1), 0.5 s (2), 1.5 s (3) and the end (9), of which 2 and 9 fire
// when skipped; and its skip policy and fade.
@(private = "file")
write_skippable :: proc(
	t: ^testing.T,
	f: ^Player_Fixture,
	guid: format.Guid,
	policy: format.Cutscene_Skip,
	ranges: []format.Cutscene_Skip_Range = nil,
	fade: i32 = 0,
) {
	length := i32(2 * SECOND)
	dial := make([]format.Cutscene_Section_Contents, 2, context.temp_allocator)
	dial[0] = {
		id       = 1,
		start    = 0,
		end      = SECOND,
		weight   = 1,
		channels = key(3),
	}
	dial[1] = {
		id       = 2,
		start    = SECOND,
		end      = length,
		weight   = 1,
		channels = key(7),
	}
	plain := make([]format.Cutscene_Key, 2, context.temp_allocator)
	plain[0] = {
		time  = SECOND / 4,
		value = 1,
	}
	plain[1] = {
		time  = 3 * SECOND / 2,
		value = 3,
	}
	marked := make([]format.Cutscene_Key, 2, context.temp_allocator)
	marked[0] = {
		time  = SECOND / 2,
		value = 2,
	}
	marked[1] = {
		time  = length,
		value = 9,
	}
	channels := make([]format.Cutscene_Channel_Contents, 2, context.temp_allocator)
	channels[0] = {
		name = "value",
		keys = plain,
	}
	channels[1] = {
		name = "skipped",
		keys = marked,
	}
	events := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	events[0] = {
		id       = 3,
		start    = 0,
		end      = length,
		weight   = 1,
		channels = channels,
	}
	tracks := make([]format.Cutscene_Track_Contents, 2, context.temp_allocator)
	tracks[0] = {
		id        = 1,
		kind      = .Property,
		component = u64(DIAL_ID),
		field     = "value",
		name      = "Dial",
		binding   = 0,
		finish    = .Keep,
		sections  = dial,
	}
	tracks[1] = {
		id       = 2,
		kind     = .Presentation,
		name     = "Events",
		binding  = format.CUTSCENE_NONE,
		sections = stand_in(events),
	}
	bindings := make([]format.Cutscene_Binding_Contents, 1, context.temp_allocator)
	bindings[0] = possessed(1, "Hero")
	blob := format.cutscene_write(
		{
			guid = guid,
			key = 1,
			length = length,
			rate = 30,
			range_end = length,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/skippable.cutscene",
			skip = policy,
			skip_ranges = ranges,
			skip_fade = fade,
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, guid, blob))
}

// hero_of is the override that gives the skip tests' one binding the hero.
@(private = "file")
hero_of :: proc(f: ^Player_Fixture) -> []Binding_Override {
	overrides := make([]Binding_Override, 1, context.temp_allocator)
	overrides[0] = {Binding_Id(1), f.hero}
	return overrides
}

// frames_while runs frames while the player is in a state, at most n of them.
@(private = "file")
frames_while :: proc(f: ^Player_Fixture, h: Player_Handle, state: Player_Status, n := 400) {
	for _ in 0 ..< n {
		if status(&f.cutscenes, h) != state {
			return
		}
		frame(f)
	}
}

// A skip leaves the world as playing to the end does: the dial that a keep track wrote has its last value, and the
// events are those of the whole cutscene but for the ones that are not marked to fire when skipped. The fade out holds
// the world while it covers more of the frame, and a second skip does nothing.
@(test)
a_skipped_cutscene_leaves_the_world_as_playing_it_to_the_end :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	s := &f.cutscenes
	w := &f.world
	write_skippable(t, f, INTRO_GUID, .Anywhere, fade = SECOND / 10)
	played, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	frames_while(f, played, .Loading)
	frames_while(f, played, .Playing)
	expect_status(t, f, played, .Restored)
	testing.expect_value(t, dial(f, f.hero), 7)
	testing.expect_value(t, len(f.fired), 4)
	if len(f.fired) == 4 {
		testing.expect_value(t, f.fired[0], 1)
		testing.expect_value(t, f.fired[1], 2)
		testing.expect_value(t, f.fired[2], 3)
		testing.expect_value(t, f.fired[3], 9)
	}

	clear(&f.fired)
	ecs.get(w, f.hero, Dial).value = 1
	skipped, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	frame(f)
	expect_status(t, f, skipped, .Playing)
	testing.expect(t, can_skip(s, skipped))
	testing.expect_value(t, skip(s, w, skipped), Command_Result.Done)
	testing.expect_value(t, skip(s, w, skipped), Command_Result.Done)
	expect_status(t, f, skipped, .Skipping)
	testing.expect_value(t, skip_fade(s, skipped), 0)
	fade: f32
	for _ in 0 ..< 20 {
		frame(f)
		if status(s, skipped) != .Skipping {
			break
		}
		now := skip_fade(s, skipped)
		testing.expectf(t, now > fade, "the fade out grows: %v after %v", now, fade)
		fade = now
		testing.expect_value(t, dial(f, f.hero), 3)
		testing.expect_value(t, len(f.fired), 0)
	}
	testing.expect(t, fade > 0.5, "the fade ran over several frames")
	expect_status(t, f, skipped, .Restored)
	testing.expect_value(t, dial(f, f.hero), 7)
	testing.expect_value(t, len(f.fired), 2)
	if len(f.fired) == 2 {
		testing.expect_value(t, f.fired[0], 2)
		testing.expect_value(t, f.fired[1], 9)
	}
}

// A skip in a skip range goes to the range's end, fades in there, and plays on: the events after the range fire as
// they play. A time after the range cannot be skipped.
@(test)
a_skip_of_a_range_plays_on_after_it :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	s := &f.cutscenes
	w := &f.world
	ranges := []format.Cutscene_Skip_Range{{0, SECOND}}
	write_skippable(t, f, INTRO_GUID, .Ranges, ranges, fade = SECOND / 20)
	h, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	frame(f)
	testing.expect_value(t, skip(s, w, h), Command_Result.Done)
	// The fade in starts covered at the range's end, and uncovers the frame a frame at a time.
	fade_in := make([dynamic]f32, context.temp_allocator)
	for _ in 0 ..< 20 {
		frame(f)
		if status(s, h) != .Skipping {
			break
		}
		if now, _ := player_time(s, h); now == SECOND {
			testing.expect_value(t, dial(f, f.hero), 7)
			append(&fade_in, skip_fade(s, h))
		}
	}
	testing.expectf(t, len(fade_in) >= 2, "the player fades in at the range's end: %v", fade_in)
	if len(fade_in) >= 2 {
		testing.expect_value(t, fade_in[0], 1)
		testing.expect(t, fade_in[len(fade_in) - 1] < fade_in[0], "the fade in uncovers the frame")
	}
	expect_status(t, f, h, .Playing)
	now, _ := player_time(s, h)
	testing.expect(t, now > SECOND && now < 2 * SECOND, "play goes on after the range")
	testing.expect_value(t, len(f.fired), 1)
	if len(f.fired) == 1 {
		testing.expect_value(t, f.fired[0], 2)
	}
	testing.expect(t, !can_skip(s, h))
	testing.expect_value(t, skip(s, w, h), Command_Result.Not_Skippable)
	expect_status(t, f, h, .Playing)

	frames_while(f, h, .Playing)
	expect_status(t, f, h, .Restored)
	testing.expect_value(t, len(f.fired), 3)
	if len(f.fired) == 3 {
		testing.expect_value(t, f.fired[1], 3)
		testing.expect_value(t, f.fired[2], 9)
	}
}

// A cutscene that cannot be skipped, and a time outside every skip range, take no skip: the player plays on. A skip
// while such a cutscene loads leaves it to do what it was asked.
@(test)
a_part_that_cannot_be_skipped_is_not_skipped :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	s := &f.cutscenes
	w := &f.world
	write_skippable(t, f, INTRO_GUID, .None)
	h, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	frame(f)
	testing.expect(t, !can_skip(s, h))
	testing.expect_value(t, skip(s, w, h), Command_Result.Not_Skippable)
	before, _ := player_time(s, h)
	frame(f)
	expect_status(t, f, h, .Playing)
	after, _ := player_time(s, h)
	testing.expect(t, after > before, "it plays on")
	stop(s, w, h)
	frame(f)

	ranges := []format.Cutscene_Skip_Range{{SECOND, 2 * SECOND}}
	write_skippable(t, f, OUTRO_GUID, .Ranges, ranges)
	ranged, _ := play(s, w, {cutscene = OUTRO_GUID, overrides = hero_of(f)})
	frame(f)
	testing.expect_value(t, skip(s, w, ranged), Command_Result.Not_Skippable)
	frame(f)
	expect_status(t, f, ranged, .Playing)
	testing.expect_value(t, dial(f, f.hero), 3)
	stop(s, w, ranged)
	frame(f)

	loading, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	testing.expect_value(t, skip(s, w, loading), Command_Result.Done)
	frame(f)
	expect_status(t, f, loading, .Playing)
	testing.expect_value(t, len(f.fired), 0)
}

// The skip action skips only when it is held for the hold time from a press. A shorter hold skips nothing, a key that
// was already down begins no hold, and one hold skips once.
@(test)
holding_the_skip_action_for_less_than_the_hold_time_skips_nothing :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	s := &f.cutscenes
	w := &f.world
	_, defined := core.input_actions_define(&f.actions, "skip", {{.Key, u8(core.Key.Escape)}})
	testing.expect(t, defined)
	set_skip_input(s, "", 100 * time.Millisecond)
	write_skippable(t, f, INTRO_GUID, .Anywhere)
	h, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	frame(f)
	input: core.Input
	input.down, input.pressed = {.Escape}, {.Escape}
	for _ in 0 ..< 5 {
		update_skip(s, w, &input, FRAME)
		input.pressed = {}
		frame(f)
	}
	progress := skip_progress(s)
	testing.expectf(t, progress > 0.7 && progress < 1, "the hold is most of the way: %v", progress)
	expect_status(t, f, h, .Playing)
	input.down, input.released = {}, {.Escape}
	update_skip(s, w, &input, FRAME)
	testing.expect_value(t, skip_progress(s), 0)
	frame(f)
	expect_status(t, f, h, .Playing)

	// A key that is down with no press begins no hold.
	input.down, input.released = {.Escape}, {}
	for _ in 0 ..< 10 {
		update_skip(s, w, &input, FRAME)
	}
	testing.expect_value(t, skip_progress(s), 0)
	expect_status(t, f, h, .Playing)

	input.down = {}
	update_skip(s, w, &input, FRAME)
	input.down, input.pressed = {.Escape}, {.Escape}
	for _ in 0 ..< 10 {
		update_skip(s, w, &input, FRAME)
		input.pressed = {}
		if status(s, h) == .Skipping {
			break
		}
	}
	expect_status(t, f, h, .Skipping)
	testing.expect_value(t, skip_progress(s), 1)
	frame(f)
	expect_status(t, f, h, .Restored)
	testing.expect_value(t, dial(f, f.hero), 7)
}

// A skip while the cutscene loads ends it once it is loaded: in the same update, it goes from Ready to Skipping and on
// to Restored, and never plays. The events marked to fire when skipped fire.
@(test)
a_skip_while_loading_ends_the_cutscene_once_loaded_without_playing :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	s := &f.cutscenes
	w := &f.world
	write_skippable(t, f, INTRO_GUID, .Anywhere)
	h, _ := play(s, w, {cutscene = INTRO_GUID, overrides = hero_of(f)})
	testing.expect_value(t, skip(s, w, h), Command_Result.Done)
	expect_status(t, f, h, .Loading)
	update(s, context_of(f))
	expect_status(t, f, h, .Restored)
	want := []Player_Status{.Loading, .Ready, .Skipping, .Finishing, .Restored}
	events := player_events(s)
	testing.expect_value(t, len(events), len(want))
	for e, i in events {
		if i < len(want) {
			testing.expect_value(t, e.status, want[i])
		}
	}
	testing.expect_value(t, dial(f, f.hero), 7)
	testing.expect_value(t, len(f.fired), 2)
}

// A shot that spawns the prop plays in the second half of a master, which maps the shot's hero and rival to its own.
// The prop spawns as the master loads, hidden, shows from the frame after its section begins, and goes with the master.
// The shot's dial track writes the hero only while its section covers the time.
@(test)
a_shots_spawned_entity_shows_while_its_section_covers_the_time :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	write_cutscene(t, f, {guid = OUTRO_GUID, length = SECOND / 2, value = 7, prop = true})
	master := format.cutscene_write(
		{
			guid = INTRO_GUID,
			key = 1,
			length = SECOND,
			rate = 30,
			range_end = SECOND,
			bindings = {possessed(1, "Hero"), possessed(2, "Rival")},
			tracks = {
				{
					id = 1,
					kind = .Sub_Sequence,
					name = "Prop shot",
					binding = format.CUTSCENE_NONE,
					sections = {
						{
							id = 1,
							start = SECOND / 2,
							end = SECOND,
							weight = 1,
							asset = OUTRO_GUID,
							speed = 1,
							bindings = {{child = 1, parent = 0}, {child = 2, parent = 1}},
						},
					},
				},
			},
			source_path = "game/cutscenes/master.cutscene",
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, INTRO_GUID, master))
	before := dial(f, f.hero)
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	e, live := player_evaluation(&f.cutscenes, h)
	testing.expect(t, live && len(e.children) == 1)
	if !live || len(e.children) != 1 {
		return
	}
	prop, spawned := binding_entity(&e.children[0].bindings, &f.world, 2)
	testing.expect(t, spawned, "the shot's prop spawns as the master loads")
	for {
		at, _ := player_time(&f.cutscenes, h)
		if at >= SECOND / 2 {
			break
		}
		testing.expectf(t, ecs.has(&f.world, prop, ecs.Loading), "the prop is hidden at %d", at)
		testing.expect_value(t, dial(f, f.hero), before)
		frame(f)
	}
	frame(f)
	testing.expect(t, !ecs.has(&f.world, prop, ecs.Loading), "the prop shows in its section")
	testing.expect_value(t, dial(f, f.hero), 7)
	testing.expect_value(t, dial(f, f.rival), 2)
	for status(&f.cutscenes, h) == .Playing {
		frame(f)
	}
	frame(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, !ecs.is_alive(&f.world, prop), "the prop goes with the master")
	testing.expect_value(t, dial(f, f.hero), before)
}

// A shot's prop spawns under the shot's binding that the master maps to its own spawned prop. The master's prop shows
// as the master plays, and the shot's prop, under it, stays hidden until the shot's section begins.
@(test)
a_shots_entity_under_a_mapped_spawned_binding_shows_only_in_its_section :: proc(t: ^testing.T) {
	f := player_setup(t)
	defer player_teardown(f)
	prop :: proc(id: u32, parent: u32) -> format.Cutscene_Binding_Contents {
		return {
			id = id,
			kind = .Spawned,
			name = "Prop" if id == 3 else "Lantern",
			parent = parent,
			asset = PROP_GUID,
			rotation = {0, 0, 0, 1},
			scale = {1, 1, 1},
		}
	}
	shot := format.cutscene_write(
		{
			guid = OUTRO_GUID,
			key = 1,
			length = SECOND / 2,
			rate = 30,
			range_end = SECOND / 2,
			bindings = {prop(3, format.CUTSCENE_NONE), prop(4, 0)},
			source_path = "game/cutscenes/shot.cutscene",
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, OUTRO_GUID, shot))
	master := format.cutscene_write(
		{
			guid = INTRO_GUID,
			key = 1,
			length = SECOND,
			rate = 30,
			range_end = SECOND,
			bindings = {
				possessed(1, "Hero"),
				possessed(2, "Rival"),
				prop(3, format.CUTSCENE_NONE),
			},
			tracks = {
				{
					id = 1,
					kind = .Sub_Sequence,
					name = "Lantern shot",
					binding = format.CUTSCENE_NONE,
					sections = {
						{
							id = 1,
							start = SECOND / 2,
							end = SECOND,
							weight = 1,
							asset = OUTRO_GUID,
							speed = 1,
							bindings = {{child = 3, parent = 2}},
						},
					},
				},
			},
			source_path = "game/cutscenes/master.cutscene",
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, INTRO_GUID, master))
	h, _ := play(&f.cutscenes, &f.world, {cutscene = INTRO_GUID, overrides = cast_of(f)})
	frame(f)
	e, live := player_evaluation(&f.cutscenes, h)
	testing.expect(t, live && len(e.children) == 1)
	if !live || len(e.children) != 1 {
		return
	}
	own := prop_of(f, h)
	lantern, spawned := binding_entity(&e.children[0].bindings, &f.world, 1)
	testing.expect(t, own != 0 && spawned)
	testing.expect_value(t, ecs.get(&f.world, lantern, ecs.Parent).entity, own)
	frame(f)
	testing.expect(t, !ecs.has(&f.world, own, ecs.Loading), "the master's prop shows")
	testing.expect(
		t,
		ecs.has(&f.world, lantern, ecs.Loading),
		"the shot's lantern waits for its section",
	)
	for {
		at, _ := player_time(&f.cutscenes, h)
		if at > SECOND / 2 {
			break
		}
		frame(f)
	}
	frame(f)
	testing.expect(t, !ecs.has(&f.world, lantern, ecs.Loading), "the lantern shows in its section")
}

// stand_in makes sections the stand-in event kind's, which the tests register over the presentation kind: letterbox
// sections, whose channels the blob takes, with each "value" channel as "aspect" and each "skipped" one as "amount".
@(private = "file")
stand_in :: proc(
	sections: []format.Cutscene_Section_Contents,
) -> []format.Cutscene_Section_Contents {
	result := make([]format.Cutscene_Section_Contents, len(sections), context.temp_allocator)
	for s, i in sections {
		result[i] = s
		result[i].presentation = {
			kind = .Letterbox,
		}
		channels := make(
			[]format.Cutscene_Channel_Contents,
			len(s.channels),
			context.temp_allocator,
		)
		for c, j in s.channels {
			channels[j] = c
			switch c.name {
			case "value":
				channels[j].name = format.CUTSCENE_LETTERBOX_ASPECT
			case "skipped":
				channels[j].name = format.CUTSCENE_LETTERBOX_AMOUNT
			}
		}
		result[i].channels = channels
	}
	return result
}
