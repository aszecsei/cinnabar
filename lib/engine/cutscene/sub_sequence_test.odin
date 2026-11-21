package cutscene

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

// The cutscene's ticks in a world tick at 60 Hz.
@(private = "file")
TICK :: SECOND / 60

@(private = "file")
MASTER_GUID :: format.Guid {
	0  = 0x75,
	15 = 1,
}

@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x75,
	15 = 2,
}

// shot_guid is the GUID of the nth shot.
@(private = "file")
shot_guid :: proc(n: int) -> format.Guid {
	return {0 = 0x75, 14 = 1, 15 = u8(n)}
}

@(private = "file")
Sub_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	views:     camera.Views,
	cutscenes: State,
	// The entities that the master's bindings 1, 2, ... name, by override.
	entities:  [dynamic]ecs.Entity,
	// The names of the events that the native handlers got, in order.
	heard:     [dynamic]string,
}

// sub_setup makes a world with the engine's and the renderer's components, the cutscenes' own kinds of track, and the
// game's views, with a gameplay camera at the origin.
@(private = "file")
sub_setup :: proc(t: ^testing.T) -> ^Sub_Fixture {
	f := new(Sub_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
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
	render.register_components(&f.world.registry)
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_sub_sequence_test_none"))
	init(&f.cutscenes, &f.world, &f.assets, views = &f.views)
	register(&f.cutscenes, &f.world)
	f.entities = make([dynamic]ecs.Entity)
	f.heard = make([dynamic]string)
	gameplay := spawn_at(f, {0, 0, 0})
	ecs.add(&f.world, gameplay, render.Camera{vertical_fov = 1})
	camera.advance(&f.views, &f.world, {1.0 / 60, 1.0 / 60})
	camera.drawn(&f.views)
	return f
}

@(private = "file")
sub_teardown :: proc(f: ^Sub_Fixture) {
	destroy(&f.cutscenes, &f.world)
	camera.destroy(&f.views, nil)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.entities)
	for name in f.heard {
		delete(name)
	}
	delete(f.heard)
	free(f)
}

@(private = "file")
spawn_at :: proc(f: ^Sub_Fixture, position: [3]f64) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.Transform{ecs.position_from_meters(position), 1, 1}
	ecs.add(&f.world, e, pose)
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	return e
}

// bound spawns an entity at a position that the master's next binding names, with a Camera when asked.
@(private = "file")
bound :: proc(f: ^Sub_Fixture, position: [3]f64, is_camera := false) -> ecs.Entity {
	e := spawn_at(f, position)
	if is_camera {
		ecs.add(&f.world, e, render.Camera{})
	}
	append(&f.entities, e)
	return e
}

// listen registers a native handler for each name, which records the events' names in heard.
@(private = "file")
listen :: proc(f: ^Sub_Fixture, names: ..string) {
	for name in names {
		register_event_handler(
			&f.cutscenes,
			name,
			proc(data: rawptr, _: Player_Handle, name: string, _: []script.Event_Arg) {
				append((^[dynamic]string)(data), strings.clone(name))
			},
			&f.heard,
		)
	}
}

// bindings_of is count possessed bindings, 1 to count, each of entity n in a scene that is never loaded: a master's
// take overrides, and a shot's are mapped.
@(private = "file")
bindings_of :: proc(count: int) -> []format.Cutscene_Binding_Contents {
	names := [?]string{"A", "B", "C", "D", "E", "F"}
	bindings := make([]format.Cutscene_Binding_Contents, count, context.temp_allocator)
	for &b, i in bindings {
		b = {
			id       = u32(i + 1),
			kind     = .Possessed,
			name     = names[i],
			parent   = format.CUTSCENE_NONE,
			asset    = SCENE_GUID,
			entity   = u64(i + 1),
			rotation = {0, 0, 0, 1},
			scale    = {1, 1, 1},
		}
	}
	return bindings
}

// cutscene_blob is a cutscene of a length with count bindings and the tracks.
@(private = "file")
cutscene_blob :: proc(
	guid: format.Guid,
	length: i32,
	count: int,
	tracks: []format.Cutscene_Track_Contents,
	key: u64 = 1,
) -> []byte {
	return format.cutscene_write(
		{
			guid = guid,
			key = key,
			length = length,
			rate = 30,
			range_end = length,
			bindings = bindings_of(count),
			tracks = tracks,
			source_path = "game/cutscenes/sub.cutscene",
		},
		context.temp_allocator,
	)
}

// walk is a transform track that moves binding 0 along x, from 0 to a distance over a time.
@(private = "file")
walk :: proc(id: u32, distance: f32, length: i32) -> format.Cutscene_Track_Contents {
	keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = 0,
		interp = .Linear,
	}
	keys[1] = {
		time   = length,
		value  = distance,
		interp = .Linear,
	}
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = "position_x",
		keys = keys,
	}
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id       = 900 + id,
		start    = 0,
		end      = length,
		weight   = 1,
		channels = channels,
	}
	return {
		id = id,
		kind = .Transform,
		name = "Walk",
		binding = 0,
		finish = .Restore,
		sections = sections,
	}
}

// shows is a camera cut track with one section that shows binding 0 over a time.
@(private = "file")
shows :: proc(id: u32, length: i32) -> format.Cutscene_Track_Contents {
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id     = 800 + id,
		start  = 0,
		end    = length,
		weight = 1,
		camera = 0,
	}
	return {
		id = id,
		kind = .Camera_Cut,
		name = "Cuts",
		binding = format.CUTSCENE_NONE,
		sections = sections,
	}
}

// trigger is an event track of one trigger at a time, which fires when skipped when asked.
@(private = "file")
trigger :: proc(
	id: u32,
	at: i32,
	name: string,
	when_skipped := false,
) -> format.Cutscene_Track_Contents {
	events := make([]format.Cutscene_Event_Contents, 1, context.temp_allocator)
	events[0] = {
		id    = 700 + id,
		start = at,
		end   = at,
		name  = name,
		flags = {.Fire_When_Skipped} if when_skipped else {},
	}
	return {
		id = id,
		kind = .Event,
		name = "Events",
		binding = format.CUTSCENE_NONE,
		events = events,
	}
}

// Play is a sub-sequence section: the shot that it plays over a time of the master, and what it maps of the shot's
// binding 1 to.
@(private = "file")
Play :: struct {
	shot:       format.Guid,
	start, end: i32,
	// The master's binding, by its index, that the shot's binding 1 is, or none.
	binding:    Maybe(u32),
	offset:     i32,
	trim_end:   i32,
	scale:      f32,
	loop:       bool,
}

// sub_sequence is a sub-sequence track of the sections.
@(private = "file")
sub_sequence :: proc(id: u32, plays: ..Play) -> format.Cutscene_Track_Contents {
	sections := make([]format.Cutscene_Section_Contents, len(plays), context.temp_allocator)
	for p, i in plays {
		maps: []format.Cutscene_Binding_Map_Contents
		if parent, mapped := p.binding.?; mapped {
			maps = make([]format.Cutscene_Binding_Map_Contents, 1, context.temp_allocator)
			maps[0] = {
				child  = 1,
				parent = parent,
			}
		}
		sections[i] = {
			id       = 100 * id + u32(i),
			start    = p.start,
			end      = p.end,
			weight   = 1,
			asset    = p.shot,
			offset   = p.offset,
			trim_end = p.trim_end,
			speed    = p.scale if p.scale > 0 else 1,
			flags    = {.Loop} if p.loop else {},
			bindings = maps,
		}
	}
	return {
		id = id,
		kind = .Sub_Sequence,
		name = "Shots",
		binding = format.CUTSCENE_NONE,
		sections = sections,
	}
}

@(private = "file")
overrides_of :: proc(f: ^Sub_Fixture) -> []Binding_Override {
	out := make([]Binding_Override, len(f.entities), context.temp_allocator)
	for e, i in f.entities {
		out[i] = {Binding_Id(i + 1), e}
	}
	return out
}

// play_master plays the master, after the shots, and runs the update that loads it.
@(private = "file")
play_master :: proc(
	t: ^testing.T,
	f: ^Sub_Fixture,
	master: []byte,
	shots: ..[]byte,
) -> Player_Handle {
	for shot in shots {
		header, _ := format.blob_header(shot)
		testing.expect(t, asset.set_live(&f.assets, header.guid, shot))
	}
	testing.expect(t, asset.set_live(&f.assets, MASTER_GUID, master))
	h, ok := play(&f.cutscenes, &f.world, {cutscene = MASTER_GUID, overrides = overrides_of(f)})
	testing.expect(t, ok)
	update(&f.cutscenes, {world = &f.world})
	return h
}

// tick runs one fixed tick, the Late stage and the frame's player update, as the frame code does, and then the views.
@(private = "file")
tick :: proc(f: ^Sub_Fixture) -> camera.Frame_Views {
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	send_events(&f.cutscenes)
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
	shown := camera.advance(&f.views, &f.world, {1.0 / 60, 1.0 / 60})
	camera.drawn(&f.views)
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
	return shown
}

@(private = "file")
x_of :: proc(f: ^Sub_Fixture, e: ecs.Entity) -> f64 {
	return ecs.position_to_meters(ecs.get(&f.world, e, ecs.Transform).position).x
}

@(private = "file")
view_x :: proc(shown: camera.Frame_Views) -> f64 {
	return f64(ecs.position_sub(shown.views[0].view.position, {})[0])
}

// The one mapping of a parent's time to a child's: an offset (the section starts at 1 s), a trim of [0.1 s, 0.5 s) of
// the child, a scale of 2 and a loop, and the same without the loop, which holds at the trim's end. The event ranges
// that cross a wrap split into a segment for each loop.
@(test)
a_parents_time_maps_to_its_childs_through_the_offset_trim_scale_and_loop :: proc(t: ^testing.T) {
	section := format.Cutscene_Section {
		start  = SECOND,
		end    = 3 * SECOND,
		offset = 6000,
		speed  = 2,
		flags  = {.Loop},
	}
	trim := Trim{6000, 30000}
	Case :: struct {
		t:     i64,
		child: i64,
		loops: i64,
	}
	looped := [?]Case {
		{0, 6000, 0},
		{SECOND, 6000, 0},
		{SECOND + 6000, 18000, 0},
		{SECOND + 11999, 29998, 0},
		{SECOND + 12000, 6000, 1},
		{SECOND + 15000, 12000, 1},
		{SECOND + 24000, 6000, 2},
		// 2 s of the section are 4 s of the child: five loops of 0.4 s, and the end shows the trim's end.
		{3 * SECOND, 30000, 9},
		{4 * SECOND, 30000, 9},
	}
	for c in looped {
		child, loops := child_time(section, trim, c.t)
		testing.expectf(
			t,
			child == c.child && loops == c.loops,
			"%d: %d after %d loops",
			c.t,
			child,
			loops,
		)
	}
	section.flags = {}
	held := [?]Case{{SECOND + 6000, 18000, 0}, {SECOND + 12000, 30000, 0}, {2 * SECOND, 30000, 0}}
	for c in held {
		child, loops := child_time(section, trim, c.t)
		testing.expectf(
			t,
			child == c.child && loops == c.loops,
			"held %d: %d after %d loops",
			c.t,
			child,
			loops,
		)
	}

	section.flags = {.Loop}
	across := child_range(section, trim, SECOND + 6000, SECOND + 15000)
	testing.expect_value(t, across.count, 2)
	testing.expect_value(t, across.segments[0], [2]i64{18000, 30000})
	testing.expect_value(t, across.segments[1], [2]i64{5999, 12000})
	entering := child_range(section, trim, SECOND - 1000, SECOND + 1000)
	testing.expect_value(t, entering.count, 1)
	testing.expect_value(t, entering.segments[0], [2]i64{5999, 8000})
	testing.expect_value(t, child_range(section, trim, 0, SECOND - 1).count, 0)
	testing.expect_value(t, child_range(section, trim, 3 * SECOND, 4 * SECOND).count, 0)
	testing.expect_value(t, child_range(section, trim, SECOND + 5, SECOND + 5).count, 0)

	// A trim past the child's range is clamped into it, and a trim's end of 0 is the range's end.
	child_blob := format.Cutscene_Blob {
		range_start = 3000,
		range_end   = 20000,
	}
	testing.expect_value(
		t,
		trim_of({offset = 1000, trim_end = 50000}, &child_blob),
		Trim{3000, 20000},
	)
	testing.expect_value(t, trim_of({offset = 6000}, &child_blob), Trim{6000, 20000})
}

// A master of three shots, each a cutscene with its own camera cut track that shows its own camera binding, which the
// master maps to a camera of its own. The master has no cut track, so each shot's cuts show while its section does, and
// the frame cuts where one shot gives way to the next. Where the master has a cut section of its own, it wins.
@(test)
a_master_of_three_shots_cuts_to_each_shots_camera :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	for x in ([?]f64{1, 2, 3, 4}) {
		bound(f, {x, 0, 0}, is_camera = true)
	}
	shot_length := i32(30 * TICK)
	shots := [3][]byte{}
	for &shot, i in shots {
		shot = cutscene_blob(shot_guid(i + 1), shot_length, 1, {shows(1, shot_length)})
	}
	length := 3 * shot_length
	master := cutscene_blob(
		MASTER_GUID,
		length,
		4,
		{
			sub_sequence(
				1,
				{shot = shot_guid(1), start = 0, end = shot_length, binding = 0},
				{shot = shot_guid(2), start = shot_length, end = 2 * shot_length, binding = 1},
				{shot = shot_guid(3), start = 2 * shot_length, end = length, binding = 2},
			),
		},
	)
	h := play_master(t, f, master, ..shots[:])
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	for k in 1 ..= 89 {
		shown := tick(f)
		want: f64 = 1 if k < 30 else 2 if k < 60 else 3
		cut := k == 1 || k == 30 || k == 60
		testing.expectf(
			t,
			abs(view_x(shown) - want) < 1e-4,
			"frame %d shows x %v",
			k,
			view_x(shown),
		)
		testing.expectf(t, shown.views[0].cut == cut, "frame %d: cut %v", k, shown.views[0].cut)
	}
	tick(f)
	tick(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, abs(view_x(tick(f))) < 1e-4, "gameplay shows again")

	// The master's own cut section over the second shot wins over the shot's.
	own := cutscene_blob(
		MASTER_GUID,
		length,
		4,
		{
			sub_sequence(
				1,
				{shot = shot_guid(1), start = 0, end = shot_length, binding = 0},
				{shot = shot_guid(2), start = shot_length, end = 2 * shot_length, binding = 1},
				{shot = shot_guid(3), start = 2 * shot_length, end = length, binding = 2},
			),
			{
				id = 2,
				kind = .Camera_Cut,
				name = "Master cuts",
				binding = format.CUTSCENE_NONE,
				sections = {
					{id = 20, start = shot_length, end = 2 * shot_length, weight = 1, camera = 3},
				},
			},
		},
		key = 2,
	)
	release(&f.cutscenes, &f.world, h)
	h = play_master(t, f, own, ..shots[:])
	for k in 1 ..= 89 {
		shown := tick(f)
		want: f64 = 1 if k < 30 else 4 if k < 60 else 3
		testing.expectf(
			t,
			abs(view_x(shown) - want) < 1e-4,
			"own cut: frame %d shows x %v",
			k,
			view_x(shown),
		)
	}
}

// One shot, which walks its binding 1 along x by 3 m, plays twice in the master, the first time mapped to A and the
// second to B. Each shot moves only its own actor, and an actor whose shot is over has its own place again.
@(test)
one_shot_plays_twice_with_other_bindings :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	a, b := bound(f, {0, 0, 0}), bound(f, {10, 0, 0})
	shot_length := i32(30 * TICK)
	shot := cutscene_blob(shot_guid(1), shot_length, 1, {walk(1, 3, shot_length)})
	master := cutscene_blob(
		MASTER_GUID,
		2 * shot_length,
		2,
		{
			sub_sequence(
				1,
				{shot = shot_guid(1), start = 0, end = shot_length, binding = 0},
				{shot = shot_guid(1), start = shot_length, end = 2 * shot_length, binding = 1},
			),
		},
	)
	h := play_master(t, f, master, shot)
	live := player_evaluation(&f.cutscenes, h) or_else nil
	testing.expect(t, live != nil && len(live.children) == 2, "a child for each section")
	if live != nil && len(live.children) == 2 {
		testing.expect(
			t,
			live.children[0].scope != live.children[1].scope,
			"each section is a scope",
		)
	}
	for _ in 1 ..= 15 {
		tick(f)
	}
	testing.expectf(t, abs(x_of(f, a) - 1.5) < 1e-4, "A walks in the first shot: %v", x_of(f, a))
	testing.expectf(t, abs(x_of(f, b) - 10) < 1e-4, "B stays: %v", x_of(f, b))
	for _ in 16 ..= 45 {
		tick(f)
	}
	testing.expectf(t, abs(x_of(f, a)) < 1e-4, "A is back at its place: %v", x_of(f, a))
	testing.expectf(t, abs(x_of(f, b) - 11.5) < 1e-4, "B walks in the second shot: %v", x_of(f, b))
	for _ in 46 ..= 62 {
		tick(f)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expectf(t, abs(x_of(f, b) - 10) < 1e-4, "the end restores B: %v", x_of(f, b))
}

// A shot of 0.2 s with a trigger at 0.1 s loops for 1 s of the master at a scale of 2: its trigger fires in each of its
// ten loops, in order with the master's own, and a hitch of 0.5 s that wraps several loops fires each of them once.
@(test)
a_looping_shot_fires_its_events_in_each_loop :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	listen(f, "beat", "half")
	shot := cutscene_blob(shot_guid(1), SECOND / 5, 0, {trigger(1, SECOND / 10, "beat")})
	master := cutscene_blob(
		MASTER_GUID,
		SECOND,
		0,
		{
			sub_sequence(
				1,
				{shot = shot_guid(1), start = 0, end = SECOND, scale = 2, loop = true},
			),
			trigger(2, SECOND / 2, "half"),
		},
	)
	h := play_master(t, f, master, shot)
	for _ in 1 ..= 61 {
		tick(f)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	want := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 10 {
		append(&want, "beat")
		if i == 4 {
			append(&want, "half")
		}
	}
	testing.expectf(t, slice.equal(f.heard[:], want[:]), "heard %v", f.heard[:])
}

// A skip of the master to its end sends the shots' events that fire when skipped, in time order with the master's own,
// and none of the others.
@(test)
a_skip_sends_the_shots_events_that_fire_when_skipped_in_order :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	listen(f, "first", "second", "quiet", "own")
	half := i32(SECOND / 2)
	first := cutscene_blob(
		shot_guid(1),
		half,
		0,
		{trigger(1, half / 2, "first", when_skipped = true), trigger(2, half / 4, "quiet")},
	)
	second := cutscene_blob(
		shot_guid(2),
		half,
		0,
		{trigger(1, half / 2, "second", when_skipped = true)},
	)
	master := cutscene_blob(
		MASTER_GUID,
		SECOND,
		0,
		{
			trigger(9, half, "own", when_skipped = true),
			sub_sequence(
				1,
				{shot = shot_guid(1), start = 0, end = half},
				{shot = shot_guid(2), start = half, end = SECOND},
			),
		},
	)
	h := play_master(t, f, master, first, second)
	tick(f)
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	for _ in 1 ..= 3 {
		tick(f)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expectf(
		t,
		slice.equal(f.heard[:], []string{"first", "own", "second"}),
		"heard %v",
		f.heard[:],
	)
}

// A shot cooked again while the master plays it: the master shows the new shot at its next tick, at the same time,
// without loading again, and keeps its actor.
@(test)
a_shot_cooked_again_while_the_master_plays_shows_at_once :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	a := bound(f, {0, 0, 0})
	length := i32(60 * TICK)
	shot := cutscene_blob(shot_guid(1), length, 1, {walk(1, 6, length)})
	master := cutscene_blob(
		MASTER_GUID,
		length,
		1,
		{sub_sequence(1, {shot = shot_guid(1), start = 0, end = length, binding = 0})},
	)
	h := play_master(t, f, master, shot)
	for _ in 1 ..= 20 {
		tick(f)
	}
	testing.expectf(t, abs(x_of(f, a) - 2) < 1e-3, "the shot walks A: %v", x_of(f, a))
	children := len((player_evaluation(&f.cutscenes, h) or_else nil).children)

	edited := cutscene_blob(shot_guid(1), length, 1, {walk(1, 12, length)}, key = 2)
	testing.expect(t, asset.set_live(&f.assets, shot_guid(1), edited))
	tick(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	testing.expectf(
		t,
		abs(x_of(f, a) - 4.2) < 1e-3,
		"the new shot walks A twice as far: %v",
		x_of(f, a),
	)
	testing.expect_value(
		t,
		len((player_evaluation(&f.cutscenes, h) or_else nil).children),
		children,
	)
}

// Blobs whose sub-sequences reach each other, which the cook refuses, fail the player as it loads, and change nothing.
@(test)
sub_sequences_that_reach_each_other_fail_the_player :: proc(t: ^testing.T) {
	f := sub_setup(t)
	defer sub_teardown(f)
	a := bound(f, {0, 0, 0})
	one := cutscene_blob(
		shot_guid(1),
		SECOND,
		1,
		{walk(1, 3, SECOND), sub_sequence(2, {shot = shot_guid(2), start = 0, end = SECOND})},
	)
	two := cutscene_blob(
		shot_guid(2),
		SECOND,
		0,
		{sub_sequence(1, {shot = shot_guid(1), start = 0, end = SECOND})},
	)
	master := cutscene_blob(
		MASTER_GUID,
		SECOND,
		1,
		{sub_sequence(1, {shot = shot_guid(1), start = 0, end = SECOND, binding = 0})},
	)
	context.logger = testlog.expected_errors()
	h := play_master(t, f, master, one, two)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Failed)
	failure, _ := player_failure(&f.cutscenes, h)
	testing.expect_value(t, failure.(Asset_Failure), Asset_Failure{shot_guid(1), .Bad_Nesting})
	tick(f)
	testing.expect_value(t, x_of(f, a), 0)
}
