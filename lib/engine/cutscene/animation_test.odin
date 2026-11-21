package cutscene

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/anim"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

@(private = "file")
CLIPS_GUID :: format.Guid {
	0  = 0x74,
	15 = 1,
}
@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x74,
	15 = 2,
}
@(private = "file")
SKIN_GUID :: format.Guid {
	0  = 0x74,
	15 = 3,
}
// WALK is a clip of a second that moves Root 2 m along z, which the graph marks with a footstep at 0.5 s.
@(private = "file")
WALK_GUID :: format.Guid {
	0  = 0x74,
	15 = 4,
}
// WAVE is a clip of a second that lifts Root 1 m along y.
@(private = "file")
WAVE_GUID :: format.Guid {
	0  = 0x74,
	15 = 5,
}
// IDLE is a clip of a second that stands still.
@(private = "file")
IDLE_GUID :: format.Guid {
	0  = 0x74,
	15 = 6,
}
// GRAPH plays the idle, and has the walk among its clips, with its marker. Its root motion joint is Root.
@(private = "file")
GRAPH_GUID :: format.Guid {
	0  = 0x74,
	15 = 7,
}

@(private = "file")
Clip_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	animation: anim.State,
	cutscenes: State,
	// The entities that the cutscene's bindings 1, 2, ... name, by override.
	entities:  [dynamic]ecs.Entity,
}

// clip_setup makes a world with the engine's and the animation's components, the cutscenes' systems and then the
// animator's, as the game registers them, and the skin, the clips and the graph, run on one thread.
@(private = "file")
clip_setup :: proc(t: ^testing.T) -> ^Clip_Fixture {
	f := new(Clip_Fixture)
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
	anim.register_components(&f.world.registry)
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_animation_test_none"))
	init(&f.cutscenes, &f.world, &f.assets, nil, &f.animation)
	register(&f.cutscenes, &f.world)
	anim.register(&f.animation, &f.world, &f.assets)
	f.entities = make([dynamic]ecs.Entity)
	live :: proc(t: ^testing.T, f: ^Clip_Fixture, guid: format.Guid, data: []byte) {
		testing.expect(t, asset.set_live(&f.assets, guid, data))
	}
	live(
		t,
		f,
		SKIN_GUID,
		format.skin_write(
			{
				guid = SKIN_GUID,
				key = 1,
				joints = {
					{
						name = "Root",
						parent = -1,
						inverse_bind = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}},
						rotation = {0, 0, 0, 1},
						scale = 1,
						sphere = {0, 0, 0, 1},
					},
				},
			},
			context.temp_allocator,
		),
	)
	live(t, f, WALK_GUID, root_clip(WALK_GUID, 2, {0, 0, 2}))
	live(t, f, WAVE_GUID, root_clip(WAVE_GUID, 3, {0, 1, 0}))
	live(t, f, IDLE_GUID, root_clip(IDLE_GUID, 4, {}))
	live(t, f, GRAPH_GUID, graph_blob(5, "footstep"))
	return f
}

// graph_blob is the graph: the idle, which it plays, and the walk, whose marker at 0.5 s raises an event of a name.
@(private = "file")
graph_blob :: proc(key: u64, event: string) -> []byte {
	return format.animation_graph_write(
		{
			guid = GRAPH_GUID,
			key = key,
			root_motion = "Root",
			clips = {
				{name = "idle", clip = IDLE_GUID},
				{name = "walk", clip = WALK_GUID, markers = {{time = 0.5, event = 0}}},
			},
			events = {{name = event}},
			states = {
				{
					name = "idle",
					motion = .Clip,
					parameter = format.ANIMATION_GRAPH_NONE,
					points = {{clip = 0}},
					speed = 1,
					loop = true,
					enter_event = format.ANIMATION_GRAPH_NONE,
					exit_event = format.ANIMATION_GRAPH_NONE,
				},
			},
		},
		context.temp_allocator,
	)
}

// root_clip is a clip of a second that moves Root from the origin to an end, linearly.
@(private = "file")
root_clip :: proc(guid: format.Guid, key: u64, end: [3]f32) -> []byte {
	return format.animation_write(
		{
			guid = guid,
			key = key,
			skin = SKIN_GUID,
			joint_count = 1,
			duration = 1,
			channels = {
				{
					joint = 0,
					path = .Translation,
					interpolation = .Linear,
					first_key = 0,
					key_count = 2,
					first_value = 0,
				},
			},
			times = {0, 1},
			values = {0, 0, 0, end.x, end.y, end.z},
		},
		context.temp_allocator,
	)
}

@(private = "file")
clip_teardown :: proc(f: ^Clip_Fixture) {
	destroy(&f.cutscenes, &f.world)
	anim.destroy(&f.animation)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.entities)
	free(f)
}

// character spawns an entity at a pose that plays the graph, and gives it the next binding.
@(private = "file")
character :: proc(
	f: ^Clip_Fixture,
	position: [3]f64 = {},
	rotation: quaternion128 = 1,
) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.Transform{ecs.position_from_meters(position), rotation, 1}
	ecs.add(&f.world, e, pose)
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	a := anim.DEFAULT_ANIMATOR
	a.graph = GRAPH_GUID
	ecs.add(&f.world, e, a)
	append(&f.entities, e)
	return e
}

@(private = "file")
Clip :: struct {
	id:          u32,
	start:       i32,
	end:         i32,
	clip:        format.Guid,
	offset:      i32,
	speed:       f32,
	ease_in:     i32,
	ease_out:    i32,
	weight:      f32,
	flags:       format.Cutscene_Section_Flags,
	root_motion: format.Cutscene_Root_Motion,
}

// clips_blob is a cutscene with one animation track on the first binding, and a possessed binding for each of the
// fixture's entities.
@(private = "file")
clips_blob :: proc(
	f: ^Clip_Fixture,
	clips: []Clip,
	length: i32,
	finish := format.Cutscene_Finish.Restore,
	key: u64 = 1,
	tracks := true,
	clock := format.Cutscene_Clock.Game,
) -> []byte {
	names := [?]string{"A", "B", "C", "D"}
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
	sections := make([]format.Cutscene_Section_Contents, len(clips), context.temp_allocator)
	for c, i in clips {
		sections[i] = {
			id          = c.id,
			start       = c.start,
			end         = c.end,
			ease_in     = c.ease_in,
			ease_out    = c.ease_out,
			weight      = c.weight,
			asset       = c.clip,
			offset      = c.offset,
			speed       = c.speed,
			flags       = c.flags,
			root_motion = c.root_motion,
		}
	}
	track := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Animation,
			name = "Acts",
			binding = 0,
			finish = finish,
			sections = sections,
		},
	}
	return format.cutscene_write(
		{
			guid = CLIPS_GUID,
			key = key,
			length = length,
			rate = 30,
			clock = clock,
			range_end = length,
			bindings = bindings,
			tracks = track if tracks else nil,
			source_path = "game/cutscenes/clips.cutscene",
		},
		context.temp_allocator,
	)
}

@(private = "file")
overrides_of :: proc(f: ^Clip_Fixture) -> []Binding_Override {
	out := make([]Binding_Override, len(f.entities), context.temp_allocator)
	for e, i in f.entities {
		out[i] = {Binding_Id(i + 1), e}
	}
	return out
}

// scrub_of evaluates a blob outside a player, as the editor's scrub does.
@(private = "file")
scrub_of :: proc(t: ^testing.T, f: ^Clip_Fixture, blob: []byte) -> ^Evaluation {
	testing.expect(t, asset.set_live(&f.assets, CLIPS_GUID, blob))
	h, loaded := asset.find(&f.assets, CLIPS_GUID)
	testing.expect(t, loaded)
	data, _ := asset.data(&f.assets, h)
	view, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	e := new(Evaluation)
	init_evaluation(e, &f.world, h, data, view)
	failure := resolve_bindings(
		&e.bindings,
		{world = &f.world, assets = &f.assets, data = data, blob = view},
		overrides_of(f),
	)
	testing.expect(t, failure == nil)
	return e
}

@(private = "file")
end_scrub :: proc(f: ^Clip_Fixture, e: ^Evaluation) {
	destroy_evaluation(e, &f.world)
	free(e)
}

// scrub_to starts a frame, as the frame code does before the ticks, and seeks an evaluation to a time and evaluates it
// there.
@(private = "file")
scrub_to :: proc(f: ^Clip_Fixture, e: ^Evaluation, t: i32) {
	free_all(f.platform.frame_allocator)
	anim.prepare(&f.animation, &f.world)
	data, blob, _ := cutscene_data(&f.cutscenes, e)
	seek(&f.cutscenes, e, &f.world, data, blob, t)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Fixed)
}

// play_blob plays a blob through a player, which is Playing after it.
@(private = "file")
play_blob :: proc(t: ^testing.T, f: ^Clip_Fixture, blob: []byte) -> Player_Handle {
	testing.expect(t, asset.set_live(&f.assets, CLIPS_GUID, blob))
	h, ok := play(&f.cutscenes, &f.world, {cutscene = CLIPS_GUID, overrides = overrides_of(f)})
	testing.expect(t, ok)
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	return h
}

// tick runs a frame of one fixed tick and the frame's player update, as the frame code does: the graphs load before
// the tick, and the frame's events start empty.
@(private = "file")
tick :: proc(f: ^Clip_Fixture) {
	free_all(f.platform.frame_allocator)
	anim.prepare(&f.animation, &f.world)
	anim.begin_frame(&f.animation)
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
}

// root_of is the presented pose's root joint of an entity: its palette's only matrix.
@(private = "file")
root_of :: proc(f: ^Clip_Fixture, e: ecs.Entity) -> (root: [3][4]f32, found: bool) {
	for pose in anim.present(&f.animation, &f.world, f.platform.frame_allocator) {
		if pose.entity == e && len(pose.palette) == 1 {
			return pose.palette[0], true
		}
	}
	return
}

@(private = "file")
same_root :: proc(a, b: [3][4]f32) -> bool {
	for row in 0 ..< 3 {
		for column in 0 ..< 4 {
			if abs(a[row][column] - b[row][column]) > 1e-5 {
				return false
			}
		}
	}
	return true
}

@(private = "file")
footsteps :: proc(f: ^Clip_Fixture, e: ecs.Entity) -> (n: int) {
	for event in anim.frame_events(&f.animation) {
		if event.entity == e && event.name == "footstep" {
			n += 1
		}
	}
	return
}

// OVERLAP is three sections over 1.5 s: the walk from 0.25 s into it, looping, easing out from 0.5 s to 1 s; the
// wave at twice its speed, holding, easing in from 0.5 s to 1 s; and a light walk from 0.5 s, which the driver's two
// samples leave out while the others weigh more.
@(private = "file")
OVERLAP :: [?]Clip {
	{
		id = 1,
		start = 0,
		end = SECOND,
		clip = WALK_GUID,
		offset = SECOND / 4,
		speed = 1,
		ease_out = SECOND / 2,
		weight = 1,
		flags = {.Loop},
	},
	{
		id = 2,
		start = SECOND / 2,
		end = SECOND * 3 / 2,
		clip = WAVE_GUID,
		speed = 2,
		ease_in = SECOND / 2,
		weight = 1,
	},
	{id = 3, start = SECOND / 2, end = SECOND * 3 / 2, clip = WALK_GUID, speed = 1, weight = 0.1},
}

// expected_samples is what the driver should get at a time, worked out from the sections' terms: each clip at offset
// + (t - start) × speed seconds, wrapped or held, by its weight and its eases, the two heaviest.
@(private = "file")
expected_samples :: proc(clips: []Clip, t: i32) -> [anim.MAX_DRIVEN]anim.Driven_Sample {
	all := make([dynamic]anim.Driven_Sample, context.temp_allocator)
	for c in clips {
		if t < c.start || t > c.end || (t == c.end && c.end != SECOND * 3 / 2) {
			continue
		}
		local := t - c.start
		weight := c.weight
		if c.ease_in > 0 {
			weight *= ease(f64(local) / f64(c.ease_in))
		}
		if c.ease_out > 0 {
			weight *= ease(f64(c.end - t) / f64(c.ease_out))
		}
		if weight <= 0 {
			continue
		}
		seconds := (f64(c.offset) + f64(local) * f64(c.speed)) / SECOND
		seconds = math.mod(seconds, 1) if .Loop in c.flags else min(seconds, 1)
		append(&all, anim.Driven_Sample{clip = c.clip, time = f32(seconds), weight = weight})
	}
	out: [anim.MAX_DRIVEN]anim.Driven_Sample
	for &slot in out {
		heaviest := -1
		for s, i in all {
			if s.weight > 0 && (heaviest < 0 || s.weight > all[heaviest].weight) {
				heaviest = i
			}
		}
		if heaviest >= 0 {
			slot = all[heaviest]
			all[heaviest].weight = 0
		}
	}
	return out
}

// Two sections overlap, and a third that weighs less is left out where three cover the time: the presented pose at each
// time is the pose that the driver gives for the same clips, times and weights, on another entity.
@(test)
overlapping_clip_sections_pose_as_the_driver_does :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	actor := character(f)
	reference := character(f)
	clips := OVERLAP
	scrub := scrub_of(t, f, clips_blob(f, clips[:], SECOND * 3 / 2))
	defer end_scrub(f, scrub)
	token, ok := anim.begin_drive(&f.animation, &f.world, reference, hold = true)
	testing.expect(t, ok)
	for at in ([]i32{0, SECOND / 4, SECOND * 3 / 4, SECOND * 5 / 6, SECOND * 5 / 4, SECOND * 3 / 2}) {
		scrub_to(f, scrub, at)
		samples := expected_samples(clips[:], at)
		for &s in samples {
			s.root_motion = .In_Pose
		}
		anim.drive(&f.world, token, samples[:])
		got, has_got := root_of(f, actor)
		want, has_want := root_of(f, reference)
		testing.expect(t, has_got && has_want)
		testing.expectf(t, same_root(got, want), "at %d: posed %v, the driver %v", at, got, want)
	}
}

// A player plays the overlap tick by tick. Seeks backwards and forwards to the times that it reached give the same
// poses.
@(test)
a_seek_gives_the_pose_that_playback_gives :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	actor := character(f)
	clips := OVERLAP
	blob := clips_blob(f, clips[:], SECOND * 3 / 2)
	Seen :: struct {
		at:   i32,
		root: [3][4]f32,
	}
	seen := make([dynamic]Seen, context.temp_allocator)
	h := play_blob(t, f, blob)
	for i := 0; status(&f.cutscenes, h) == .Playing; i += 1 {
		tick(f)
		at, playing := player_time(&f.cutscenes, h)
		if playing && i % 7 == 0 {
			root, found := root_of(f, actor)
			testing.expect(t, found)
			append(&seen, Seen{at, root})
		}
	}
	testing.expect(t, len(seen) > 8)
	scrub := scrub_of(t, f, blob)
	defer end_scrub(f, scrub)
	#reverse for s in seen {
		scrub_to(f, scrub, s.at)
		root, _ := root_of(f, actor)
		testing.expectf(t, same_root(root, s.root), "back to %d: %v, not %v", s.at, root, s.root)
	}
	for s, i in seen {
		if i % 2 == 0 {
			scrub_to(f, scrub, s.at)
			root, _ := root_of(f, actor)
			testing.expectf(t, same_root(root, s.root), "on to %d: %v, not %v", s.at, root, s.root)
		}
	}
}

// A looping walk that applies its root motion moves a turned entity along its own forward, about 2 m a second less
// what its eases slow it, and plays in place. A seek to a time that playback reached places the entity exactly where
// playback did, and restore puts it back.
@(test)
a_seek_places_an_applied_root_motion_where_playback_reaches :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	turned := script.quaternion_euler({0, 90, 0})
	actor := character(f, {1, 0, 1}, turned)
	before := ecs.get(&f.world, actor, ecs.Transform)^
	clips := []Clip {
		{
			id = 1,
			start = 0,
			end = SECOND * 5 / 2,
			clip = WALK_GUID,
			speed = 1,
			ease_in = SECOND / 4,
			ease_out = SECOND / 4,
			weight = 1,
			flags = {.Loop},
			root_motion = .Apply,
		},
	}
	blob := clips_blob(f, clips, SECOND * 5 / 2)
	Seen :: struct {
		at:   i32,
		pose: ecs.Transform,
	}
	seen := make([dynamic]Seen, context.temp_allocator)
	h := play_blob(t, f, blob)
	last: ecs.Transform
	for status(&f.cutscenes, h) == .Playing {
		tick(f)
		if at, playing := player_time(&f.cutscenes, h); playing {
			last = ecs.get(&f.world, actor, ecs.Transform)^
			append(&seen, Seen{at, last})
			root, _ := root_of(f, actor)
			testing.expectf(
				t,
				abs(root[2][3]) < 1e-5,
				"at %d the root moves in the mesh: %v",
				at,
				root,
			)
		}
	}
	moved := ecs.position_to_meters(last.position) - ecs.position_to_meters(before.position)
	testing.expectf(t, moved.x > 4.4 && moved.x < 4.6, "moved %v", moved)
	testing.expectf(t, abs(moved.y) < 1e-6 && abs(moved.z) < 1e-4, "moved %v", moved)
	testing.expect_value(t, ecs.get(&f.world, actor, ecs.Transform)^, before)
	scrub := scrub_of(t, f, blob)
	defer end_scrub(f, scrub)
	for i := len(seen) - 1; i >= 0; i -= 5 {
		scrub_to(f, scrub, seen[i].at)
		pose := ecs.get(&f.world, actor, ecs.Transform)^
		testing.expectf(
			t,
			pose == seen[i].pose,
			"at %d: %v, not %v",
			seen[i].at,
			pose,
			seen[i].pose,
		)
		testing.expect_value(
			t,
			ecs.Transform(ecs.get(&f.world, actor, ecs.Previous_Transform)^),
			pose,
		)
	}
}

// A looping walk of 2 s passes its marker at 0.5 s and 1.5 s: playback raises each once. A seek over a marker, a scrub
// back over one and a skip over one raise none, and playing on after the scrub back raises it again.
@(test)
markers_fire_once_in_playback_and_not_on_a_seek_a_scrub_back_or_a_skip :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	actor := character(f)
	clips := []Clip {
		{
			id = 1,
			start = 0,
			end = SECOND * 2,
			clip = WALK_GUID,
			speed = 1,
			weight = 1,
			flags = {.Loop},
		},
	}
	blob := clips_blob(f, clips, SECOND * 2)
	h := play_blob(t, f, blob)
	heard := 0
	for status(&f.cutscenes, h) == .Playing {
		tick(f)
		heard += footsteps(f, actor)
	}
	testing.expect_value(t, heard, 2)

	h = play_blob(t, f, blob)
	run_to :: proc(f: ^Clip_Fixture, h: Player_Handle, until: i32) -> (heard: int) {
		for {
			at, _ := player_time(&f.cutscenes, h)
			if at >= until {
				return
			}
			tick(f)
			heard += footsteps(f, f.entities[0])
		}
	}
	testing.expect_value(t, run_to(f, h, SECOND / 5), 0)
	testing.expect_value(t, set_time(&f.cutscenes, &f.world, h, SECOND), Command_Result.Done)
	testing.expect_value(t, run_to(f, h, SECOND * 7 / 5), 0)
	testing.expect_value(
		t,
		set_time(&f.cutscenes, &f.world, h, SECOND * 3 / 10),
		Command_Result.Done,
	)
	testing.expect_value(t, run_to(f, h, SECOND * 3 / 5), 1)
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	tick(f)
	testing.expect_value(t, footsteps(f, actor), 0)
}

// The graph's own time: the idle state's clip's.
@(private = "file")
graph_time :: proc(f: ^Clip_Fixture, e: ecs.Entity) -> f32 {
	return ecs.get(&f.world, e, anim.Animator).time
}

// A section from 0.5 s to 1 s drives the Animator. With restore, the graph's time stops while the track holds it, and
// after Restored it goes on from where it stopped. With keep, the graph plays on under the clips. Either way the
// Animator is the graph's again after the cutscene.
@(test)
the_gameplay_graph_resumes_after_restore :: proc(t: ^testing.T) {
	for finish in format.Cutscene_Finish {
		f := clip_setup(t)
		actor := character(f)
		clips := []Clip {
			{id = 1, start = SECOND / 2, end = SECOND, clip = WAVE_GUID, speed = 1, weight = 1},
		}
		h := play_blob(t, f, clips_blob(f, clips, SECOND * 3 / 2, finish))
		held_at: Maybe(f32)
		for status(&f.cutscenes, h) == .Playing {
			was := graph_time(f, actor)
			tick(f)
			if status(&f.cutscenes, h) != .Playing {
				break
			}
			driven := ecs.get(&f.world, actor, anim.Animator).driven != nil
			if !driven {
				testing.expectf(
					t,
					graph_time(f, actor) != was,
					"%v: the graph stands before the clip",
					finish,
				)
				continue
			}
			if _, seen := held_at.?; !seen {
				held_at = graph_time(f, actor)
			}
			switch finish {
			case .Restore:
				testing.expectf(
					t,
					graph_time(f, actor) == held_at.?,
					"%v: the graph moves while held",
					finish,
				)
			case .Keep:
				testing.expectf(
					t,
					graph_time(f, actor) != was,
					"%v: the graph stands under the clip",
					finish,
				)
			}
		}
		testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
		testing.expectf(t, held_at != nil, "%v: the track never drove the Animator", finish)
		testing.expect(t, ecs.get(&f.world, actor, anim.Animator).driven == nil)
		was := graph_time(f, actor)
		tick(f)
		step := graph_time(f, actor) - was
		testing.expectf(
			t,
			abs(step - 1.0 / f32(f.world.clock.tick_rate)) < 1e-4,
			"%v: the graph went on by %v",
			finish,
			step,
		)
		clip_teardown(f)
	}
}

// Another driver takes the Animator: the track takes it back at its next evaluation. A reload that removes the track
// gives the Animator back to its graph.
@(test)
a_track_takes_its_animator_back_and_a_reload_gives_it_up :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	actor := character(f)
	clips := []Clip{{id = 1, start = 0, end = SECOND, clip = WAVE_GUID, speed = 1, weight = 1}}
	scrub := scrub_of(t, f, clips_blob(f, clips, SECOND))
	defer end_scrub(f, scrub)
	scrub_to(f, scrub, SECOND / 2)
	theirs, ok := anim.begin_drive(&f.animation, &f.world, actor)
	testing.expect(t, ok)
	scrub_to(f, scrub, SECOND / 2)
	testing.expect(t, !anim.is_driving(&f.world, theirs))
	testing.expect(t, anim.is_driving(&f.world, scrub.drives[actor]))
	testing.expect(
		t,
		asset.set_live(
			&f.assets,
			CLIPS_GUID,
			clips_blob(f, clips, SECOND, key = 2, tracks = false),
		),
	)
	scrub_to(f, scrub, SECOND / 2)
	testing.expect(t, ecs.get(&f.world, actor, anim.Animator).driven == nil)
	testing.expect_value(t, len(scrub.drives), 0)
}

// A cutscene on the real clock raises a marker in a frame that runs no tick. The graph changes before the next tick,
// so its event 0 has another name: the marker still reaches the tick's events as the graph of its own frame named it.
@(test)
a_marker_raised_in_a_frame_without_a_tick_keeps_its_name :: proc(t: ^testing.T) {
	f := clip_setup(t)
	defer clip_teardown(f)
	actor := character(f)
	clips := []Clip {
		{
			id = 1,
			start = 0,
			end = SECOND * 2,
			clip = WALK_GUID,
			speed = 1,
			weight = 1,
			flags = {.Loop},
		},
	}
	play_blob(t, f, clips_blob(f, clips, SECOND * 2, clock = .Real))
	free_all(f.platform.frame_allocator)
	anim.prepare(&f.animation, &f.world)
	advance_real(&f.cutscenes, &f.world, 600 * time.Millisecond)
	anim.end_frame(&f.animation)
	testing.expect(t, asset.set_live(&f.assets, GRAPH_GUID, graph_blob(6, "bark")))
	tick(f)
	testing.expect_value(t, footsteps(f, actor), 1)
	for event in anim.frame_events(&f.animation) {
		testing.expectf(t, event.name != "bark", "the marker took the new graph's name")
	}
}

// A marker in a section's last tick, where the tick's end is past the section, and a marker at the offset of a section
// whose ease in weighs nothing at its start, each fire once in playback.
@(test)
markers_at_a_sections_edges_fire :: proc(t: ^testing.T) {
	cases := [?]Clip {
		// The marker at 0.5 s of the clip is at 29500 of the section, the last tick's (29000, 30000].
		{
			id = 1,
			start = 0,
			end = SECOND / 2,
			clip = WALK_GUID,
			offset = 500,
			speed = 1,
			weight = 1,
		},
		// The marker is at the offset, at the section's start, where its ease in weighs 0.
		{
			id = 1,
			start = SECOND / 6,
			end = SECOND * 2 / 3,
			clip = WALK_GUID,
			offset = SECOND / 2,
			speed = 1,
			ease_in = SECOND / 6,
			weight = 1,
		},
	}
	for c in cases {
		f := clip_setup(t)
		actor := character(f)
		clips := []Clip{c}
		h := play_blob(t, f, clips_blob(f, clips, SECOND))
		heard := 0
		for status(&f.cutscenes, h) == .Playing {
			tick(f)
			heard += footsteps(f, actor)
		}
		testing.expectf(t, heard == 1, "a section from %d heard %d footsteps", c.start, heard)
		clip_teardown(f)
	}
}
