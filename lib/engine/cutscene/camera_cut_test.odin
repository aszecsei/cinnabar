package cutscene

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
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

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

// The cutscene's ticks in a world tick at 60 Hz.
@(private = "file")
TICK :: SECOND / 60

@(private = "file")
SHOTS_GUID :: format.Guid {
	0  = 0x74,
	15 = 1,
}

@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x74,
	15 = 2,
}

@(private = "file")
Cut_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	views:     camera.Views,
	cutscenes: State,
	// The entities that the cutscene's bindings 1, 2, ... name, by override.
	entities:  [dynamic]ecs.Entity,
	// The camera that gameplay shows, which no binding names.
	gameplay:  ecs.Entity,
}

// cut_setup makes a world with the engine's and the renderer's components, the cutscenes' own kinds of track, and the
// game's views, with a gameplay camera at the origin that shows before the cutscene.
@(private = "file")
cut_setup :: proc(t: ^testing.T) -> ^Cut_Fixture {
	f := new(Cut_Fixture)
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
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_camera_cut_test_none"))
	init(&f.cutscenes, &f.world, &f.assets, views = &f.views)
	register(&f.cutscenes, &f.world)
	f.entities = make([dynamic]ecs.Entity)
	f.gameplay = spawn_at(f, {0, 0, 0})
	ecs.add(&f.world, f.gameplay, render.Camera{vertical_fov = 1})
	frame(f)
	return f
}

@(private = "file")
cut_teardown :: proc(f: ^Cut_Fixture) {
	destroy(&f.cutscenes, &f.world)
	camera.destroy(&f.views, nil)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.entities)
	free(f)
}

@(private = "file")
spawn_at :: proc(f: ^Cut_Fixture, position: [3]f64) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.Transform{ecs.position_from_meters(position), 1, 1}
	ecs.add(&f.world, e, pose)
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	return e
}

// bound spawns an entity at a position that the next binding names.
@(private = "file")
bound :: proc(f: ^Cut_Fixture, position: [3]f64) -> ecs.Entity {
	e := spawn_at(f, position)
	append(&f.entities, e)
	return e
}

// shot_camera spawns a camera that the next binding names.
@(private = "file")
shot_camera :: proc(f: ^Cut_Fixture, position: [3]f64) -> ecs.Entity {
	e := bound(f, position)
	ecs.add(&f.world, e, render.Camera{})
	return e
}

// shot is a camera cut section of a binding's index from a time to a time, in ticks.
@(private = "file")
shot :: proc(id: u32, start, end: i32, camera_index: u32) -> format.Cutscene_Section_Contents {
	return {id = id, start = start, end = end, weight = 1, camera = camera_index}
}

@(private = "file")
cuts :: proc(sections: ..format.Cutscene_Section_Contents) -> format.Cutscene_Track_Contents {
	copied := make([]format.Cutscene_Section_Contents, len(sections), context.temp_allocator)
	copy(copied, sections)
	return {
		id = 90,
		kind = .Camera_Cut,
		name = "Cuts",
		binding = format.CUTSCENE_NONE,
		sections = copied,
	}
}

// walk is a transform track that moves a binding along x, from 0 to a distance over a time.
@(private = "file")
walk :: proc(id: u32, binding: u32, distance: f32, length: i32) -> format.Cutscene_Track_Contents {
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
		binding = binding,
		finish = .Restore,
		sections = sections,
	}
}

// shots_blob is a cutscene of a length whose bindings are possessed entities, one for each of the fixture's entities.
@(private = "file")
shots_blob :: proc(
	f: ^Cut_Fixture,
	tracks: []format.Cutscene_Track_Contents,
	length: i32,
	constraints: []format.Cutscene_Constraint_Contents = nil,
	constrained: u32 = 0,
	key: u64 = 1,
	guid := SHOTS_GUID,
) -> []byte {
	names := [?]string{"A", "B", "C", "D", "E"}
	bindings := make([]format.Cutscene_Binding_Contents, len(f.entities), context.temp_allocator)
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
	if len(constraints) > 0 {
		bindings[constrained].constraints = constraints
	}
	return format.cutscene_write(
		{
			guid = guid,
			key = key,
			length = length,
			rate = 30,
			range_end = length,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/shots.cutscene",
		},
		context.temp_allocator,
	)
}

@(private = "file")
overrides_of :: proc(f: ^Cut_Fixture) -> []Binding_Override {
	out := make([]Binding_Override, len(f.entities), context.temp_allocator)
	for e, i in f.entities {
		out[i] = {Binding_Id(i + 1), e}
	}
	return out
}

@(private = "file")
play_blob :: proc(
	t: ^testing.T,
	f: ^Cut_Fixture,
	blob: []byte,
	priority: i32 = 0,
	guid := SHOTS_GUID,
) -> Player_Handle {
	testing.expect(t, asset.set_live(&f.assets, guid, blob))
	h, ok := play(
		&f.cutscenes,
		&f.world,
		{cutscene = guid, overrides = overrides_of(f), priority = priority},
	)
	testing.expect(t, ok)
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	return h
}

// tick runs one fixed tick, the Late stage and the frame's player update, as the frame code does, and then the views.
@(private = "file")
tick :: proc(f: ^Cut_Fixture) -> camera.Frame_Views {
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
	shown := frame(f)
	free_all(f.platform.frame_allocator)
	return shown
}

// frame advances the views by a frame of 1/60 s on both clocks, and draws it.
@(private = "file")
frame :: proc(f: ^Cut_Fixture) -> camera.Frame_Views {
	shown := camera.advance(&f.views, &f.world, {1.0 / 60, 1.0 / 60})
	camera.drawn(&f.views)
	return shown
}

@(private = "file")
x_of :: proc(view: render.View) -> f32 {
	return ecs.position_sub(view.position, {})[0]
}

@(private = "file")
teleported :: proc(f: ^Cut_Fixture, e: ecs.Entity) -> bool {
	return(
		ecs.Transform(ecs.get(&f.world, e, ecs.Previous_Transform)^) ==
		ecs.get(&f.world, e, ecs.Transform)^ \
	)
}

// Three sections back to back: the views show each one's camera from the frame whose tick reaches its start, and that
// frame is a cut, which starts the renderer's histories again and teleports the transform tracks. The end gives the
// gameplay camera back with a cut.
@(test)
three_sections_cut_on_their_exact_frames :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	a, b, c := shot_camera(f, {1, 0, 0}), shot_camera(f, {2, 0, 0}), shot_camera(f, {3, 0, 0})
	mover := bound(f, {0, 0, 5})
	length := i32(90 * TICK)
	tracks := []format.Cutscene_Track_Contents {
		walk(1, 3, 9, length),
		cuts(
			shot(1, 0, 30 * TICK, 0),
			shot(2, 30 * TICK, 60 * TICK, 1),
			shot(3, 60 * TICK, length, 2),
		),
	}
	h := play_blob(t, f, shots_blob(f, tracks, length))
	_, _, _ = a, b, c
	for k in 1 ..= 89 {
		shown := tick(f)
		want: f32 = 1 if k < 30 else 2 if k < 60 else 3
		cut := k == 1 || k == 30 || k == 60
		testing.expectf(
			t,
			abs(x_of(shown.views[0].view) - want) < 1e-4,
			"frame %d shows x %v",
			k,
			x_of(shown.views[0].view),
		)
		testing.expectf(t, shown.views[0].cut == cut, "frame %d: cut %v", k, shown.views[0].cut)
		testing.expectf(
			t,
			teleported(f, mover) == cut,
			"frame %d: the walk teleports %v",
			k,
			teleported(f, mover),
		)
	}
	shown := tick(f)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	testing.expect(t, abs(x_of(shown.views[0].view)) < 1e-4)
	testing.expect(t, shown.views[0].cut)
	testing.expect(t, !camera.claimed(&f.views))
}

// A muted cut track cuts nothing, so the transform tracks do not teleport at its sections' starts, and nor does a
// section that blends in from gameplay.
@(test)
transform_tracks_teleport_on_a_cut_and_not_on_a_blend :: proc(t: ^testing.T) {
	for muted in ([2]bool{false, true}) {
		f := cut_setup(t)
		shot_camera(f, {1, 0, 0})
		mover := bound(f, {0, 0, 5})
		length := i32(60 * TICK)
		blending := shot(1, 15 * TICK, 30 * TICK, 0)
		blending.blend_in = 5 * TICK
		track := cuts(blending, shot(2, 30 * TICK, length, 0))
		if muted {
			track.flags = {.Muted}
		}
		play_blob(t, f, shots_blob(f, {walk(1, 1, 6, length), track}, length))
		for k in 1 ..= 40 {
			tick(f)
			want := k == 1 || (k == 30 && !muted)
			testing.expectf(t, teleported(f, mover) == want, "muted %v, frame %d", muted, k)
		}
		cut_teardown(f)
	}
}

// The first section blends in from the gameplay camera, and the last blends out to it at its end: at each blend's
// middle the views show the middle of the poses and of the fields of view. A camera that goes as its claim leaves,
// as a spawned camera does when its player ends, leaves the blend from where it was.
@(test)
a_blend_in_and_out_of_gameplay_shows_the_middle_pose :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	s := shot_camera(f, {10, 0, 0})
	ecs.add(&f.world, s, render.Cinematic_Camera{focal_length = 50, sensor_height = 24})
	lens_fov := 2 * math.atan(f32(24) / 100)
	length := i32(180 * TICK)
	section := shot(1, 0, 120 * TICK, 0)
	section.blend_in, section.blend_out = 60 * TICK, 60 * TICK
	play_blob(t, f, shots_blob(f, {cuts(section)}, length))
	fov_of :: proc(view: render.View) -> f32 {
		return view.projection.(render.Perspective).vertical_fov
	}
	shown: camera.Frame_Views
	for _ in 1 ..= 30 {
		shown = tick(f)
		testing.expect(t, !shown.views[0].cut)
	}
	testing.expectf(
		t,
		abs(x_of(shown.views[0].view) - 5) < 1e-3,
		"halfway in at x %v",
		x_of(shown.views[0].view),
	)
	testing.expect(t, abs(fov_of(shown.views[0].view) - (1 + lens_fov) / 2) < 1e-3)
	for _ in 31 ..= 119 {
		shown = tick(f)
	}
	testing.expect(t, abs(x_of(shown.views[0].view) - 10) < 1e-4)
	for _ in 120 ..= 149 {
		shown = tick(f)
		testing.expect(t, !shown.views[0].cut)
	}
	testing.expectf(
		t,
		abs(x_of(shown.views[0].view) - 5) < 1e-3,
		"halfway out at x %v",
		x_of(shown.views[0].view),
	)
	testing.expect(t, abs(fov_of(shown.views[0].view) - (1 + lens_fov) / 2) < 1e-3)

	// A cutscene that ends in its shot blends out from it, though the camera goes as the player gives the world back.
	g := cut_setup(t)
	defer cut_teardown(g)
	gone := shot_camera(g, {10, 0, 0})
	ending := shot(1, 0, 60 * TICK, 0)
	ending.blend_out = 60 * TICK
	h := play_blob(t, g, shots_blob(g, {cuts(ending)}, 60 * TICK))
	for _ in 1 ..= 59 {
		tick(g)
	}
	// The last tick, as tick does it, with the camera despawned between the player's end and the views.
	clock := &g.world.clock
	it := ecs.begin_ticks(&g.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, g)
	}
	ecs.run_stage(&g.world, .Late, ecs.tick_length(&g.world), g)
	update(&g.cutscenes, {world = &g.world, dt = time.Second / 60})
	testing.expect_value(t, status(&g.cutscenes, h), Player_Status.Restored)
	ecs.despawn(&g.world, gone)
	shown = frame(g)
	testing.expect(t, !shown.views[0].cut)
	for _ in 1 ..= 29 {
		shown = frame(g)
	}
	testing.expectf(
		t,
		abs(x_of(shown.views[0].view) - 5) < 1e-3,
		"halfway out at x %v",
		x_of(shown.views[0].view),
	)
}

// A seek or a scrub back cuts to the section at the new time, a pause does not cut, a skip cuts back to gameplay unless
// the last section blends out on a skip, and a stop cuts back.
@(test)
a_seek_cuts_a_pause_holds_and_a_skip_or_stop_gives_the_view_back :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	shot_camera(f, {1, 0, 0})
	shot_camera(f, {2, 0, 0})
	length := i32(60 * TICK)
	last := shot(2, 30 * TICK, length, 1)
	last.blend_out = 60 * TICK
	blob := shots_blob(f, {cuts(shot(1, 0, 30 * TICK, 0), last)}, length)
	h := play_blob(t, f, blob)
	for _ in 1 ..= 40 {
		tick(f)
	}
	testing.expect_value(t, set_time(&f.cutscenes, &f.world, h, 10 * TICK), Command_Result.Done)
	shown := tick(f)
	testing.expect(t, shown.views[0].cut)
	testing.expect(t, abs(x_of(shown.views[0].view) - 1) < 1e-4)
	// A seek inside the same section cuts too.
	set_time(&f.cutscenes, &f.world, h, 12 * TICK)
	shown = tick(f)
	testing.expect(t, shown.views[0].cut)

	testing.expect_value(t, pause(&f.cutscenes, &f.world, h), Command_Result.Done)
	for _ in 1 ..= 5 {
		shown = tick(f)
		testing.expect(t, !shown.views[0].cut)
		testing.expect(t, abs(x_of(shown.views[0].view) - 1) < 1e-4)
	}
	resume(&f.cutscenes, &f.world, h)

	// The same blob again, a reload: the track claims the same shot again, with a cut.
	testing.expect(
		t,
		asset.set_live(
			&f.assets,
			SHOTS_GUID,
			shots_blob(f, {cuts(shot(1, 0, 30 * TICK, 0), last)}, length, key = 2),
		),
	)
	shown = tick(f)
	testing.expect(t, shown.views[0].cut)
	testing.expect(t, abs(x_of(shown.views[0].view) - 1) < 1e-4)

	// A stop cuts back to gameplay from a shot that would blend out at its end.
	set_time(&f.cutscenes, &f.world, h, 40 * TICK)
	tick(f)
	testing.expect_value(t, stop(&f.cutscenes, &f.world, h), Command_Result.Done)
	update(&f.cutscenes, {world = &f.world})
	shown = frame(f)
	testing.expect(t, shown.views[0].cut)
	testing.expect(t, abs(x_of(shown.views[0].view)) < 1e-4)

	// A skip to the end cuts back, and one with the last section marked to blend out on a skip blends, from whichever
	// shot shows.
	Skip_Case :: struct {
		marked: bool,
		frames: int,
		// The x of the camera that shows at the skip.
		from:   f32,
	}
	for c, i in ([]Skip_Case{{false, 40, 2}, {true, 40, 2}, {true, 10, 1}}) {
		marked := c.marked
		marked_last := last
		if marked {
			marked_last.flags = {.Blend_On_Skip}
		}
		p := play_blob(
			t,
			f,
			shots_blob(f, {cuts(shot(1, 0, 30 * TICK, 0), marked_last)}, length, key = u64(3 + i)),
		)
		for _ in 1 ..= c.frames {
			tick(f)
		}
		testing.expect_value(t, skip(&f.cutscenes, &f.world, p), Command_Result.Done)
		update(&f.cutscenes, {world = &f.world})
		testing.expect_value(t, status(&f.cutscenes, p), Player_Status.Restored)
		shown = frame(f)
		testing.expectf(
			t,
			shown.views[0].cut == !marked,
			"marked %v: cut %v",
			marked,
			shown.views[0].cut,
		)
		want: f32 = c.from * (1 - 1.0 / 60) if marked else 0
		testing.expectf(
			t,
			abs(x_of(shown.views[0].view) - want) < 1e-3,
			"marked %v: x %v",
			marked,
			x_of(shown.views[0].view),
		)
		for _ in 1 ..= 60 {
			frame(f)
		}
		release(&f.cutscenes, &f.world, p)
	}
}

// A reload that mutes the cut track gives the views back at once, though the track no longer evaluates.
@(test)
a_reload_that_mutes_the_cut_track_gives_the_view_back :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	shot_camera(f, {1, 0, 0})
	length := i32(60 * TICK)
	play_blob(t, f, shots_blob(f, {cuts(shot(1, 0, length, 0))}, length))
	shown := tick(f)
	testing.expect(t, abs(x_of(shown.views[0].view) - 1) < 1e-4)
	muted := cuts(shot(1, 0, length, 0))
	muted.flags = {.Muted}
	testing.expect(
		t,
		asset.set_live(&f.assets, SHOTS_GUID, shots_blob(f, {muted}, length, key = 2)),
	)
	shown = tick(f)
	testing.expect(t, !camera.claimed(&f.views))
	testing.expect(t, shown.views[0].cut)
	testing.expect(t, abs(x_of(shown.views[0].view)) < 1e-4)
}

// A property track on the Cinematic_Camera racks its focus, and the view's lens follows it.
@(test)
a_rack_focus_reaches_the_views_lens :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	k := shot_camera(f, {0, 0, 0})
	ecs.add(&f.world, k, render.Cinematic_Camera{aperture = 2, focus_distance = 6})
	length := i32(60 * TICK)
	keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = 6,
		interp = .Linear,
	}
	keys[1] = {
		time   = length,
		value  = 1.5,
		interp = .Linear,
	}
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = "value",
		keys = keys,
	}
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id       = 70,
		start    = 0,
		end      = length,
		weight   = 1,
		channels = channels,
	}
	rack := format.Cutscene_Track_Contents {
		id        = 7,
		kind      = .Property,
		name      = "Rack focus",
		binding   = 0,
		component = u64(render.CINEMATIC_CAMERA_ID),
		field     = "focus_distance",
		sections  = sections,
	}
	play_blob(t, f, shots_blob(f, {rack, cuts(shot(1, 0, length, 0))}, length))
	shown: camera.Frame_Views
	for _ in 1 ..= 30 {
		shown = tick(f)
	}
	testing.expectf(
		t,
		abs(shown.views[0].view.lens.focus_distance - 3.75) < 1e-3,
		"the focus is at %v",
		shown.views[0].view.lens.focus_distance,
	)
}

// Of two players' cut tracks, the higher priority's shows.
@(test)
the_higher_priority_players_cut_shows :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	shot_camera(f, {1, 0, 0})
	shot_camera(f, {2, 0, 0})
	length := i32(60 * TICK)
	play_blob(t, f, shots_blob(f, {cuts(shot(1, 0, length, 1))}, length), priority = 5)
	other := format.Guid {
		0  = 0x74,
		15 = 3,
	}
	play_blob(
		t,
		f,
		shots_blob(f, {cuts(shot(1, 0, length, 0))}, length, guid = other),
		guid = other,
	)
	shown := tick(f)
	testing.expect(t, abs(x_of(shown.views[0].view) - 2) < 1e-4)
}

// A section whose camera binding is not a camera shows nothing, and the view stays gameplay's.
@(test)
a_binding_that_is_not_a_camera_is_not_claimed :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := cut_setup(t)
	defer cut_teardown(f)
	bound(f, {1, 0, 0})
	length := i32(60 * TICK)
	play_blob(t, f, shots_blob(f, {cuts(shot(1, 0, length, 0))}, length))
	for _ in 1 ..= 3 {
		shown := tick(f)
		testing.expect(t, abs(x_of(shown.views[0].view)) < 1e-4)
	}
	testing.expect(t, !camera.claimed(&f.views))
}

// rotation_at plays a cutscene to a time through a player and gives a camera's rotation there, then stops the player.
@(private = "file")
rotation_at :: proc(
	t: ^testing.T,
	f: ^Cut_Fixture,
	blob: []byte,
	e: ecs.Entity,
	frames: int,
) -> quaternion128 {
	h := play_blob(t, f, blob)
	for _ in 1 ..= frames {
		tick(f)
	}
	rotation := ecs.get(&f.world, e, ecs.Transform).rotation
	stop(&f.cutscenes, &f.world, h)
	update(&f.cutscenes, {world = &f.world})
	release(&f.cutscenes, &f.world, h)
	return rotation
}

// scrub_rotation evaluates a blob outside a player at a time, as the editor's scrub does, and gives a camera's rotation.
@(private = "file")
scrub_rotation :: proc(
	t: ^testing.T,
	f: ^Cut_Fixture,
	blob: []byte,
	e: ecs.Entity,
	at: i32,
) -> quaternion128 {
	testing.expect(t, asset.set_live(&f.assets, SHOTS_GUID, blob))
	h, _ := asset.find(&f.assets, SHOTS_GUID)
	data, _ := asset.data(&f.assets, h)
	view, _ := format.cutscene_view(data)
	ev: Evaluation
	init_evaluation(&ev, &f.world, h, data, view)
	failure := resolve_bindings(
		&ev.bindings,
		{world = &f.world, assets = &f.assets, data = data, blob = view},
		overrides_of(f),
	)
	testing.expect(t, failure == nil)
	seek(&f.cutscenes, &ev, &f.world, data, view, at)
	evaluate(&f.cutscenes, &ev, &f.world, data, view, .Fixed)
	rotation := ecs.get(&f.world, e, ecs.Transform).rotation
	restore(&f.cutscenes, &ev, &f.world, data, view)
	destroy_evaluation(&ev, &f.world)
	free_all(f.platform.frame_allocator)
	return rotation
}

// A look at a target that a transform track moves, with a damping, gives the same rotation in playback, after a seek
// in the player, and in a scrub outside it: what the formula says, from the camera's own rotation toward the target.
@(test)
a_look_at_gives_the_same_rotation_in_a_seek_as_in_playback :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	k := shot_camera(f, {0, 0, 0})
	bound(f, {0, 0, 10})
	length := i32(120 * TICK)
	section := shot(1, 0, length, 0)
	looks := make([]format.Cutscene_Constraint_Contents, 1, context.temp_allocator)
	looks[0] = {
		kind    = .Look_At,
		target  = 1,
		offset  = {0, 1, 0},
		damping = 30 * TICK,
	}
	section.constraints = looks
	blob := shots_blob(f, {walk(1, 1, 10, length), cuts(section)}, length)

	played := rotation_at(t, f, blob, k, 60)
	testing.expect(
		t,
		ecs.get(&f.world, k, ecs.Transform).rotation == 1,
		"restore puts the camera back",
	)
	scrubbed := scrub_rotation(t, f, blob, k, 60 * TICK)
	testing.expect(t, abs(linalg.dot(played, scrubbed)) > 1 - 1e-6)

	// At 1 s the target is at x 5, and the look's weight is 1 − e^(−1 / 0.5).
	facing, _ := look_rotation({5, 1, 10})
	weight := f32(1 - math.exp(f64(-2)))
	want := linalg.quaternion_slerp_f32(1, facing, weight)
	testing.expectf(
		t,
		abs(linalg.dot(played, want)) > 1 - 1e-5,
		"played %v, want %v",
		played,
		want,
	)

	// A seek back in the player and forward again gives it too.
	h := play_blob(t, f, blob)
	for _ in 1 ..= 90 {
		tick(f)
	}
	set_time(&f.cutscenes, &f.world, h, 10 * TICK)
	tick(f)
	set_time(&f.cutscenes, &f.world, h, 59 * TICK)
	tick(f)
	sought := ecs.get(&f.world, k, ecs.Transform).rotation
	testing.expect(t, abs(linalg.dot(sought, played)) > 1 - 1e-6)
}

// A camera that a section constrains and a later section shows without its constraint is at its own pose in the later
// section, in playback as in a scrub: the constraint's last write does not stay. A follow keeps its offset in its
// target's space, over a transform track of the camera, whose rotation stays.
@(test)
a_reused_camera_and_a_follow_are_the_same_in_a_seek_as_in_playback :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	k := shot_camera(f, {0, 0, 0})
	other := shot_camera(f, {5, 0, 0})
	bound(f, {0, 0, 10})
	_ = other
	length := i32(90 * TICK)
	first := shot(1, 0, 30 * TICK, 0)
	looks := make([]format.Cutscene_Constraint_Contents, 1, context.temp_allocator)
	looks[0] = {
		kind   = .Look_At,
		target = 2,
	}
	first.constraints = looks
	blob := shots_blob(
		f,
		{
			walk(1, 2, 6, length),
			cuts(first, shot(2, 30 * TICK, 60 * TICK, 1), shot(3, 60 * TICK, length, 0)),
		},
		length,
	)
	played := rotation_at(t, f, blob, k, 75)
	testing.expect(t, abs(linalg.dot(played, quaternion128(1))) > 1 - 1e-6)
	testing.expect(
		t,
		abs(linalg.dot(scrub_rotation(t, f, blob, k, 75 * TICK), quaternion128(1))) > 1 - 1e-6,
	)
	in_first := rotation_at(t, f, blob, k, 25)
	testing.expect(t, abs(linalg.dot(in_first, quaternion128(1))) < 0.999)

	// A follow, from the camera's binding, keeps the camera 2 m behind and 1 m over the walking target.
	follows := make([]format.Cutscene_Constraint_Contents, 1, context.temp_allocator)
	follows[0] = {
		kind   = .Follow,
		target = 2,
		offset = {0, 1, -2},
	}
	turn := make([]format.Cutscene_Key, 1, context.temp_allocator)
	turn[0] = {
		time   = 0,
		value  = 30,
		interp = .Constant,
	}
	turns := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	turns[0] = {
		name = "rotation_y",
		keys = turn,
	}
	turning := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	turning[0] = {
		id       = 950,
		start    = 0,
		end      = length,
		weight   = 1,
		channels = turns,
	}
	follow_blob := shots_blob(
		f,
		{
			walk(1, 2, 6, length),
			{id = 2, kind = .Transform, name = "Turn", binding = 0, sections = turning},
			cuts(shot(1, 0, length, 0)),
		},
		length,
		follows,
		0,
	)
	h := play_blob(t, f, follow_blob)
	for _ in 1 ..= 45 {
		tick(f)
	}
	pose := ecs.get(&f.world, k, ecs.Transform)^
	testing.expectf(
		t,
		linalg.length(ecs.position_sub(pose.position, ecs.position_from_meters({3, 1, 8}))) < 1e-3,
		"the camera follows to %v",
		ecs.position_to_meters(pose.position),
	)
	testing.expect(
		t,
		abs(linalg.dot(pose.rotation, linalg.quaternion_angle_axis_f32(math.PI / 6, {0, 1, 0}))) >
		1 - 1e-5,
	)
	stop(&f.cutscenes, &f.world, h)
	update(&f.cutscenes, {world = &f.world})
}

// A focus constraint points the camera's lens at its target while it applies, and restore puts the lens's own focus
// back.
@(test)
a_focus_constraint_sets_the_focus_and_restore_puts_it_back :: proc(t: ^testing.T) {
	f := cut_setup(t)
	defer cut_teardown(f)
	k := shot_camera(f, {0, 0, 0})
	ecs.add(&f.world, k, render.Cinematic_Camera{aperture = 2})
	target := bound(f, {0, 0, 4})
	length := i32(60 * TICK)
	section := shot(1, 0, 30 * TICK, 0)
	focus := make([]format.Cutscene_Constraint_Contents, 1, context.temp_allocator)
	focus[0] = {
		kind   = .Focus,
		target = 1,
	}
	section.constraints = focus
	h := play_blob(t, f, shots_blob(f, {cuts(section)}, length))
	shown := tick(f)
	testing.expect_value(t, ecs.get(&f.world, k, render.Cinematic_Camera).focus, target)
	testing.expect(t, abs(shown.views[0].view.lens.focus_distance - 4) < 1e-4)
	for _ in 2 ..= 31 {
		tick(f)
	}
	testing.expect_value(t, ecs.get(&f.world, k, render.Cinematic_Camera).focus, 0)
	set_time(&f.cutscenes, &f.world, h, 5 * TICK)
	tick(f)
	testing.expect_value(t, ecs.get(&f.world, k, render.Cinematic_Camera).focus, target)
	stop(&f.cutscenes, &f.world, h)
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, ecs.get(&f.world, k, render.Cinematic_Camera).focus, 0)
}
