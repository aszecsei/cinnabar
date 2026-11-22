package cutscene

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import physics_host "cinnabar:core/physics/host"
import physics_jolt "cinnabar:core/physics/jolt"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"

// The scheduler is a singleton, and the test runner runs tests on several threads.
@(private = "file")
scheduler_lock: sync.Mutex

@(private = "file")
Lamp_Mode :: enum u8 {
	Off     = 0,
	Steady  = 2,
	Flicker = 5,
}

// Lamp is a component that the tests' property tracks write: a field of every kind that a property track animates, a
// volume's setting, and fields that cannot animate.
@(private = "file")
Lamp :: struct {
	brightness: f32,
	color:      [3]f32 `editor:"color"`,
	on:         bool,
	mode:       Lamp_Mode,
	count:      i16,
	size:       [2]f32,
	bulb:       format.Guid,
	glow:       struct {
		override: bool,
		value:    f32,
	},
	serial:     u32 `editor:"read"`,
	owner:      ecs.Entity,
	turn:       quaternion128,
}

@(private = "file")
LAMP_ID :: ecs.Component_Id(9101)

@(private = "file")
CUTSCENE_GUID :: format.Guid {
	0  = 0x72,
	15 = 1,
}

@(private = "file")
OTHER_GUID :: format.Guid {
	0  = 0x72,
	15 = 2,
}

// The scene that the test's possessed binding names. The override gives its entity, so no scene loads.
@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x72,
	15 = 3,
}

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

@(private = "file")
Eval_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	cutscenes: State,
	serial:    bool,
	lamp:      ecs.Entity,
	// The values of the event keys that fired, in order.
	fired:     [dynamic]f32,
	// The players of the evaluations that begin_evaluation added.
	players:   map[^Evaluation]Player_Handle,
}

// eval_setup makes a world with a Lamp, the cutscenes' systems and the test's kinds of track. serial runs every job on
// the calling thread; otherwise the scheduler has workers threads.
@(private = "file")
eval_setup :: proc(t: ^testing.T, serial := true, workers := 0) -> ^Eval_Fixture {
	sync.lock(&scheduler_lock)
	f := new(Eval_Fixture)
	f.serial = serial
	f.fired = make([dynamic]f32)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
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
	if serial {
		f.platform.jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		}
		f.platform.jobs_wait = proc(counter: ^jobs.Counter) {}
	} else {
		testing.expect(t, jobs.init(workers))
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Lamp, LAMP_ID)
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_evaluation_test_none"))
	init(&f.cutscenes, &f.world, &f.assets)
	register(&f.cutscenes, &f.world)
	register_kind(&f.cutscenes, .Property, {phase = .Fixed, evaluate = brightness_track})
	register_kind(&f.cutscenes, .Presentation, {phase = .Late, evaluate = event_track, data = f})
	register_kind(&f.cutscenes, .Transform, {phase = .Fixed, evaluate = position_track})
	f.lamp = ecs.spawn(&f.world)
	ecs.add(&f.world, f.lamp, Lamp{brightness = 5})
	pose := ecs.TRANSFORM_IDENTITY
	ecs.add(&f.world, f.lamp, pose)
	return f
}

@(private = "file")
eval_teardown :: proc(t: ^testing.T, f: ^Eval_Fixture) {
	destroy(&f.cutscenes, &f.world)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.fired)
	delete(f.players)
	serial := f.serial
	free(f)
	if !serial {
		testing.expect(t, jobs.drain_frame())
		jobs.shutdown()
	}
	sync.unlock(&scheduler_lock)
}

// sample is a channel's value at a time in its section, linear between its keys and held past them. The shared curve
// is #540's; the test needs only a line.
@(private = "file")
sample :: proc(keys: []format.Cutscene_Key, local: i32) -> f32 {
	if local <= keys[0].time {
		return keys[0].value
	}
	for i in 1 ..< len(keys) {
		if local <= keys[i].time {
			a, b := keys[i - 1], keys[i]
			x := f32(local - a.time) / f32(b.time - a.time)
			return a.value + (b.value - a.value) * x
		}
	}
	return keys[len(keys) - 1].value
}

// brightness_track is the test's property kind: the Lamp's brightness, from each section's first channel, blended by
// the sections' weights over the Lamp's own brightness.
@(private = "file")
brightness_track :: proc(ctx: ^Track_Context) {
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
		keys := format.cutscene_channel_keys(ctx.data, ctx.blob, channel)
		blend_add(&b, sample(keys, at.local), at.weight)
	}
	own, ok := base(ctx, entity, LAMP_ID, offset_of(Lamp, brightness), f32)
	if ok {
		write(ctx, entity, LAMP_ID, offset_of(Lamp, brightness), blend_value(b, own))
	}
}

// event_track is the test's event kind: each key of each section's channels is an event at the section's start plus
// the key's time, which records the key's value when it fires.
@(private = "file")
event_track :: proc(ctx: ^Track_Context) {
	f := (^Eval_Fixture)(ctx.user)
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		for channel in format.cutscene_section_channels(ctx.data, ctx.blob, section) {
			for key in format.cutscene_channel_keys(ctx.data, ctx.blob, channel) {
				if fires(ctx, section.start + key.time) {
					append(&f.fired, key.value)
				}
			}
		}
	}
}

// position_track is the test's transform kind: the binding's x in meters, from each covering section's first channel.
@(private = "file")
position_track :: proc(ctx: ^Track_Context) {
	entity, bound := track_entity(ctx)
	if !bound {
		return
	}
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at, covers := sample_section(ctx, section, ctx.time)
		if !covers {
			continue
		}
		channel := format.cutscene_section_channels(ctx.data, ctx.blob, section)[0]
		x := sample(format.cutscene_channel_keys(ctx.data, ctx.blob, channel), at.local)
		write(
			ctx,
			entity,
			ecs.TRANSFORM_ID,
			offset_of(ecs.Transform, position),
			ecs.position_from_meters({f64(x), 0, 0}),
		)
	}
}

// The binding of every test cutscene: the lamp, which an override gives.
@(private = "file")
LAMP_BINDING :: format.Cutscene_Binding_Contents {
	id       = 1,
	kind     = .Possessed,
	name     = "Lamp",
	parent   = format.CUTSCENE_NONE,
	asset    = SCENE_GUID,
	entity   = 1,
	rotation = {0, 0, 0, 1},
	scale    = {1, 1, 1},
}

@(private = "file")
flat :: proc(value: f32) -> []format.Cutscene_Key {
	keys := make([]format.Cutscene_Key, 1, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = value,
		interp = .Linear,
	}
	return keys
}

@(private = "file")
ramp :: proc(from, to: f32, duration: i32) -> []format.Cutscene_Key {
	keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = from,
		interp = .Linear,
	}
	keys[1] = {
		time   = duration,
		value  = to,
		interp = .Linear,
	}
	return keys
}

@(private = "file")
channel :: proc(keys: []format.Cutscene_Key) -> []format.Cutscene_Channel_Contents {
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = "value",
		keys = keys,
	}
	return channels
}

@(private = "file")
cutscene_blob :: proc(
	tracks: []format.Cutscene_Track_Contents,
	length: i32 = 4 * SECOND,
	clock := format.Cutscene_Clock.Game,
	guid := CUTSCENE_GUID,
	key: u64 = 1,
) -> []byte {
	bindings := []format.Cutscene_Binding_Contents{LAMP_BINDING}
	return format.cutscene_write(
		{
			guid = guid,
			key = key,
			length = length,
			rate = 30,
			clock = clock,
			range_end = length,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/test.cutscene",
		},
		context.temp_allocator,
	)
}

// begin_evaluation loads a blob as a live asset, and evaluates it with the lamp as its binding. When added is true, a
// player plays it, so the systems advance and evaluate it. Otherwise it is an evaluation of its own, which the test
// evaluates.
@(private = "file")
begin_evaluation :: proc(
	t: ^testing.T,
	f: ^Eval_Fixture,
	blob: []byte,
	added := true,
	guid := CUTSCENE_GUID,
) -> ^Evaluation {
	testing.expect(t, asset.set_live(&f.assets, guid, blob))
	overrides := []Binding_Override{{binding = Binding_Id(1), entity = f.lamp}}
	if added {
		player, ok := play(&f.cutscenes, &f.world, {cutscene = guid, overrides = overrides})
		testing.expect(t, ok)
		update(&f.cutscenes, {world = &f.world})
		testing.expect_value(t, status(&f.cutscenes, player), Player_Status.Playing)
		e, playing := player_evaluation(&f.cutscenes, player)
		testing.expect(t, playing)
		f.players[e] = player
		return e
	}
	h, loaded := asset.find(&f.assets, guid)
	testing.expect(t, loaded)
	e := new(Evaluation)
	data, view, ok := blob_of(f, h)
	testing.expect(t, ok)
	init_evaluation(e, &f.world, h, data, view)
	failure := resolve_bindings(
		&e.bindings,
		{world = &f.world, assets = &f.assets, data = data, blob = view},
		overrides,
	)
	testing.expect(t, failure == nil)
	return e
}

// end_evaluation stops the player of an evaluation that begin_evaluation added and frees it, or destroys an evaluation
// of its own.
@(private = "file")
end_evaluation :: proc(f: ^Eval_Fixture, e: ^Evaluation) {
	if player, added := f.players[e]; added {
		stop(&f.cutscenes, &f.world, player)
		update(&f.cutscenes, {world = &f.world})
		release(&f.cutscenes, &f.world, player)
		delete_key(&f.players, e)
		return
	}
	destroy_evaluation(e, &f.world)
	free(e)
}

@(private = "file")
blob_of :: proc(
	f: ^Eval_Fixture,
	h: asset.Handle,
) -> (
	data: []byte,
	blob: ^format.Cutscene_Blob,
	ok: bool,
) {
	data = asset.data(&f.assets, h) or_return
	blob = format.cutscene_view(data) or_return
	return data, blob, true
}

// at seeks an evaluation to a time and evaluates both phases there, as a scrub does.
@(private = "file")
at :: proc(f: ^Eval_Fixture, e: ^Evaluation, time: i32) {
	data, blob, _ := blob_of(f, e.cutscene)
	seek(&f.cutscenes, e, &f.world, data, blob, time)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Fixed)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Late)
}

// tick runs one fixed tick as the frame code does.
@(private = "file")
tick :: proc(f: ^Eval_Fixture) {
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	free_all(f.platform.frame_allocator)
}

@(private = "file")
brightness :: proc(f: ^Eval_Fixture) -> f32 {
	return ecs.get(&f.world, f.lamp, Lamp).brightness
}

// Two overlapping sections with eases, weights below 1, a pre-roll and a post-roll, over the lamp's own brightness.
@(private = "file")
blended_tracks :: proc(
	finish := format.Cutscene_Finish.Restore,
) -> []format.Cutscene_Track_Contents {
	sections := make([]format.Cutscene_Section_Contents, 2, context.temp_allocator)
	sections[0] = {
		id       = 1,
		start    = SECOND / 2,
		end      = 2 * SECOND,
		ease_in  = SECOND / 4,
		ease_out = SECOND / 2,
		weight   = 0.8,
		pre_roll = SECOND / 4,
		channels = channel(ramp(10, 30, 3 * SECOND / 2)),
	}
	sections[1] = {
		id        = 2,
		start     = 3 * SECOND / 2,
		end       = 3 * SECOND,
		ease_in   = SECOND / 2,
		weight    = 0.6,
		post_roll = SECOND / 2,
		channels  = channel(ramp(-4, 8, 3 * SECOND / 2)),
	}
	tracks := make([]format.Cutscene_Track_Contents, 1, context.temp_allocator)
	tracks[0] = {
		id        = 1,
		kind      = .Property,
		component = u64(LAMP_ID),
		field     = "brightness",
		name      = "Brightness",
		binding   = 0,
		finish    = finish,
		sections  = sections,
	}
	return tracks
}

// Evaluating at random times in a random order gives, at each time, what one evaluation of that time from the start
// gives: the value is a function of the time, whatever the track wrote before.
@(test)
evaluating_a_time_gives_the_same_world_whatever_came_before :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	blob := cutscene_blob(blended_tracks())

	// Times on frames, between frames, and on every edge of the sections and their eases and rolls.
	times := make([dynamic]i32, context.temp_allocator)
	for edge in ([]i32{0, SECOND / 4, SECOND / 2, 3 * SECOND / 4, SECOND, 3 * SECOND / 2, 2 * SECOND, 5 * SECOND / 2, 3 * SECOND, 7 * SECOND / 2, 4 * SECOND}) {
		append(&times, edge, max(edge - 1, 0), min(edge + 1, 4 * SECOND))
	}
	seed := u64(0x9e3779b97f4a7c15)
	next :: proc(seed: ^u64) -> u64 {
		seed^ ~= seed^ << 13
		seed^ ~= seed^ >> 7
		seed^ ~= seed^ << 17
		return seed^
	}
	for _ in 0 ..< 200 {
		append(&times, i32(next(&seed) % u64(4 * SECOND + 1)))
	}

	// Each time once, from a fresh evaluation.
	once := make(map[i32]f32, context.temp_allocator)
	for time in times {
		e := begin_evaluation(t, f, blob, added = false)
		at(f, e, time)
		once[time] = brightness(f)
		data, view, _ := blob_of(f, e.cutscene)
		restore(&f.cutscenes, e, &f.world, data, view)
		testing.expect_value(t, brightness(f), 5)
		end_evaluation(f, e)
	}

	// Every time, in a shuffled order, from one evaluation.
	for i := len(times) - 1; i > 0; i -= 1 {
		j := int(next(&seed) % u64(i + 1))
		times[i], times[j] = times[j], times[i]
	}
	e := begin_evaluation(t, f, blob, added = false)
	defer end_evaluation(f, e)
	for time in times {
		at(f, e, time)
		testing.expectf(
			t,
			brightness(f) == once[time],
			"at %d the brightness is %v, and %v from the start",
			time,
			brightness(f),
			once[time],
		)
	}
}

// A scrub over an event key does not fire it. Playing through it fires it once, and the first evaluation fires a key at
// the range's start.
@(test)
a_scrub_skips_an_event_and_playing_through_fires_it_once :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	keys := make([]format.Cutscene_Key, 2, context.temp_allocator)
	keys[0] = {
		time   = 0,
		value  = 1,
		interp = .Constant,
	}
	keys[1] = {
		time   = SECOND / 2,
		value  = 2,
		interp = .Constant,
	}
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(keys)},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Presentation,
			name = "Events",
			binding = format.CUTSCENE_NONE,
			sections = stand_in(sections),
		},
	}
	blob := cutscene_blob(tracks, length = SECOND)

	scrubbed := begin_evaluation(t, f, blob, added = false)
	at(f, scrubbed, SECOND / 4)
	at(f, scrubbed, 3 * SECOND / 4)
	at(f, scrubbed, SECOND / 4)
	at(f, scrubbed, SECOND)
	testing.expectf(t, len(f.fired) == 0, "a scrub fires %v", f.fired[:])
	end_evaluation(f, scrubbed)

	played := begin_evaluation(t, f, blob)
	defer end_evaluation(f, played)
	for _ in 0 ..< 90 {
		tick(f)
	}
	testing.expect_value(t, played.time, SECOND)
	testing.expectf(
		t,
		len(f.fired) == 2 && f.fired[0] == 1 && f.fired[1] == 2,
		"playing through fires each key once: %v",
		f.fired[:],
	)
}

// Two sections that cross with eases blend on the ease curve, and a track gives the field back to its own value as its
// weight falls.
@(test)
sections_blend_on_the_ease_curve :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{
			id = 1,
			start = 0,
			end = 2 * SECOND,
			ease_out = SECOND,
			weight = 1,
			channels = channel(flat(10)),
		},
		{
			id = 2,
			start = SECOND,
			end = 3 * SECOND,
			ease_in = SECOND,
			ease_out = SECOND,
			weight = 1,
			channels = channel(flat(20)),
		},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	for step in 0 ..= 30 {
		time := i32(step) * SECOND / 10
		at(f, e, time)
		want: f32
		switch {
		case time < SECOND:
			want = 10
		case time <= 2 * SECOND:
			// The first eases out as the second eases in. Their weights sum to 1.
			want = 10 + 10 * ease(f64(time - SECOND) / f64(SECOND))
		case:
			// The second eases out over the lamp's own 5, and the field is 5 again at the end.
			w := ease(f64(3 * SECOND - time) / f64(SECOND))
			want = 5 * (1 - w) + 20 * w
		}
		testing.expectf(
			t,
			abs(brightness(f) - want) < 1e-4,
			"at %d the brightness is %v, not %v",
			time,
			brightness(f),
			want,
		)
	}
	testing.expect_value(t, ease(0.5), 0.5)
	testing.expect_value(t, ease(0.25), 0.15625)
}

// A section's pre-roll holds its first value before its start, and its post-roll its last after its end. Past them the
// field has its own value.
@(test)
rolls_hold_a_sections_first_and_last_values :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{
			id = 1,
			start = SECOND,
			end = 2 * SECOND,
			weight = 1,
			pre_roll = SECOND / 2,
			post_roll = SECOND / 2,
			channels = channel(ramp(10, 20, SECOND)),
		},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	cases := [?][2]f32 {
		{0.25, 5},
		{0.5, 10},
		{0.75, 10},
		{1.5, 15},
		{2, 20},
		{2.4, 20},
		{2.5, 5},
		{4, 5},
	}
	for c in cases {
		at(f, e, i32(c[0] * SECOND))
		testing.expectf(t, brightness(f) == c[1], "at %vs: %v, not %v", c[0], brightness(f), c[1])
	}
}

// A section that ends at the range's end covers the end, so the last evaluation of a cutscene sees its last value.
@(test)
a_section_that_ends_with_the_cutscene_covers_its_end :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(ramp(0, 9, SECOND))},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks, length = SECOND), added = false)
	defer end_evaluation(f, e)
	at(f, e, SECOND)
	testing.expect_value(t, brightness(f), 9)
}

// At the end, a track set to restore puts its field back, and one set to keep leaves its field as the cutscene left it.
// Fields that no track wrote are not touched.
@(test)
restore_puts_back_what_restore_tracks_wrote_and_leaves_what_keep_tracks_wrote :: proc(
	t: ^testing.T,
) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(flat(40))},
	}
	moves := []format.Cutscene_Section_Contents {
		{id = 2, start = 0, end = SECOND, weight = 1, channels = channel(flat(7))},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			component = u64(LAMP_ID),
			field = "brightness",
			name = "Brightness",
			binding = 0,
			finish = .Restore,
			sections = sections,
		},
		{id = 2, kind = .Transform, name = "Move", binding = 0, finish = .Keep, sections = moves},
	}
	ecs.get_write(&f.world, f.lamp, Lamp).color = {1, 2, 3}
	e := begin_evaluation(t, f, cutscene_blob(tracks, length = SECOND))
	defer end_evaluation(f, e)
	for _ in 0 ..< 70 {
		tick(f)
	}
	testing.expect_value(t, brightness(f), 40)
	x := ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Transform).position).x
	testing.expect_value(t, x, 7)

	data, blob, _ := blob_of(f, e.cutscene)
	restore(&f.cutscenes, e, &f.world, data, blob)
	testing.expect_value(t, brightness(f), 5)
	x = ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Transform).position).x
	testing.expect_value(t, x, 7)
	testing.expect_value(t, ecs.get(&f.world, f.lamp, Lamp).color, [3]f32{1, 2, 3})
	testing.expect_value(t, len(e.snapshot.saved), 0)
}

// A write saves the field once, before the first write, and counts as a change of the component.
@(test)
a_write_saves_the_field_once_and_marks_the_component_changed :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(ramp(10, 20, SECOND))},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks, length = SECOND), added = false)
	defer end_evaluation(f, e)
	q := ecs.query(&f.world, {ecs.changed(ecs.read(&f.world, Lamp))})
	since := ecs.take_version(&f.world)
	at(f, e, SECOND / 2)
	it := ecs.query_iter(&f.world, q, since = since)
	_, changed := ecs.query_next(&it)
	testing.expect(t, changed, "the write is a change")
	at(f, e, SECOND)
	testing.expect_value(t, len(e.snapshot.saved), 1)
	testing.expect_value(t, (^f32)(&e.snapshot.saved[0].bytes)^, 5)
}

// The game's clock advances by each tick's exact length, and the real clock by the frame's duration. Both convert to
// ticks without drift.
@(test)
the_clocks_convert_to_ticks_without_drift :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	e := begin_evaluation(t, f, cutscene_blob(nil, length = 3600 * SECOND), added = false)
	defer end_evaluation(f, e)
	data, blob, _ := blob_of(f, e.cutscene)
	// 7 ms is 420 ticks. 1/144 s is not a whole number of nanoseconds or of ticks.
	for _ in 0 ..< 1000 {
		advance(e, blob, 7 * time.Millisecond)
	}
	testing.expect_value(t, e.time, 420000)
	seek(&f.cutscenes, e, &f.world, data, blob, 0)
	clock := ecs.Clock {
		tick_rate = 144,
	}
	for n in 0 ..< u64(144 * 60) {
		advance(e, blob, ecs.tick_start(&clock, n + 1) - ecs.tick_start(&clock, n))
	}
	testing.expect_value(t, e.time, 60 * SECOND)
}

// A reload evaluates the new blob at the current time. The fields of a track that it removed go back, and it fires no
// event.
@(test)
a_reload_keeps_the_time_and_restores_what_removed_tracks_wrote :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = 2 * SECOND, weight = 1, channels = channel(flat(40))},
	}
	moves := []format.Cutscene_Section_Contents {
		{id = 2, start = 0, end = 2 * SECOND, weight = 1, channels = channel(flat(7))},
	}
	event_keys := make([]format.Cutscene_Key, 1, context.temp_allocator)
	event_keys[0] = {
		time   = 0,
		value  = 3,
		interp = .Constant,
	}
	events := []format.Cutscene_Section_Contents {
		{id = 3, start = 0, end = 2 * SECOND, weight = 1, channels = channel(event_keys)},
	}
	both := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
		{id = 2, kind = .Transform, name = "Move", binding = 0, sections = moves},
	}
	e := begin_evaluation(t, f, cutscene_blob(both, length = 2 * SECOND))
	defer end_evaluation(f, e)
	for _ in 0 ..< 30 {
		tick(f)
	}
	time_before := e.time
	testing.expect_value(t, brightness(f), 40)

	// The new blob drops the brightness and adds an event at 0, which the reload must not fire.
	only_move := []format.Cutscene_Track_Contents {
		{id = 2, kind = .Transform, name = "Move", binding = 0, sections = moves},
		{
			id = 3,
			kind = .Presentation,
			name = "Events",
			binding = format.CUTSCENE_NONE,
			sections = stand_in(events),
		},
	}
	testing.expect(
		t,
		asset.set_live(
			&f.assets,
			CUTSCENE_GUID,
			cutscene_blob(only_move, length = 2 * SECOND, key = 2),
		),
	)
	tick(f)
	testing.expect(t, e.time > time_before, "the time goes on from where it was")
	testing.expect_value(t, brightness(f), 5)
	x := ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Transform).position).x
	testing.expect_value(t, x, 7)
	testing.expectf(t, len(f.fired) == 0, "the reload fires %v", f.fired[:])
	testing.expect_value(t, len(e.snapshot.saved), 1)
}

// What a track writes in the cutscene's Fixed system, the same tick's propagation sees, and presentation interpolates
// toward it from the last tick's pose.
@(test)
a_written_transform_is_seen_in_the_same_tick :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	child := ecs.spawn(&f.world)
	ecs.add(&f.world, child, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, child, ecs.Local_Transform{offset = {0, 1, 0}, rotation = 1, scale = 1})
	ecs.add(&f.world, child, ecs.Parent{f.lamp})
	ecs.add(&f.world, f.lamp, ecs.Previous_Transform(ecs.TRANSFORM_IDENTITY))
	moves := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(ramp(0, 6, SECOND))},
	}
	tracks := []format.Cutscene_Track_Contents {
		{id = 1, kind = .Transform, name = "Move", binding = 0, sections = moves},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks, length = SECOND))
	defer end_evaluation(f, e)
	tick(f)
	after_one := e.time
	tick(f)
	// A tick is 1/60 s, about 1000 ticks of the cutscene's time, and the ramp moves 6 m a second.
	meters :: proc(time: i32) -> f64 {
		return 6 * f64(time) / f64(SECOND)
	}
	testing.expect(
		t,
		abs(f64(e.time) - 2000) <= 1,
		"two ticks are 2000 ticks of the cutscene's time",
	)
	x := ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Transform).position).x
	testing.expectf(t, abs(x - meters(e.time)) < 1e-6, "the tick's write is in Transform: %v", x)
	previous :=
		ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Previous_Transform).position).x
	testing.expectf(
		t,
		abs(previous - meters(after_one)) < 1e-6,
		"presentation starts from the last tick's pose: %v",
		previous,
	)
	child_x := ecs.position_to_meters(ecs.get(&f.world, child, ecs.Transform).position).x
	testing.expectf(
		t,
		abs(child_x - x) < 1e-6,
		"the tick's propagation moved the child: %v",
		child_x,
	)
}

// The same play gives the same values on one job and with eight workers.
@(test)
evaluation_is_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T, serial: bool) -> [60]f32 {
		f := eval_setup(t, serial = serial, workers = 0 if serial else 8)
		defer eval_teardown(t, f)
		e := begin_evaluation(t, f, cutscene_blob(blended_tracks()))
		defer end_evaluation(f, e)
		values: [60]f32
		for &v in values {
			for _ in 0 ..< 4 {
				tick(f)
			}
			v = brightness(f)
		}
		return values
	}
	one := run(t, true)
	many := run(t, false)
	testing.expect_value(t, one, many)
	testing.expect(t, !math.is_nan(one[59]))
}

// What a track writes in the cutscene's Fixed system, the same tick's physics steps with: a kinematic body that the
// cutscene moves is where the cutscene put it when the tick's step ends.
@(test)
the_same_ticks_physics_sees_a_written_transform :: proc(t: ^testing.T) {
	f := eval_setup(t, serial = false)
	defer eval_teardown(t, f)
	host := physics_host.table()
	api := physics_jolt.load(&host)
	physics_host.bind(api)
	f.platform.physics = api^
	world_physics: physics.State
	testing.expect(t, physics.init(&world_physics, &f.platform, assets = &f.assets))
	defer {
		physics.destroy(&world_physics)
		testing.expect_value(t, f.platform.physics.world_destroy_all(), 0)
	}
	physics.register_components(&f.world.registry)
	physics.register(&world_physics, &f.world)
	body := physics.DEFAULT_RIGID_BODY
	body.motion = .Kinematic
	ecs.add(&f.world, f.lamp, body)
	ecs.add(&f.world, f.lamp, physics.DEFAULT_COLLIDER)

	moves := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(flat(3))},
	}
	tracks := []format.Cutscene_Track_Contents {
		{id = 1, kind = .Transform, name = "Move", binding = 0, sections = moves},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks, length = SECOND))
	defer end_evaluation(f, e)

	// One tick as the frame code runs it: the Fixed systems, the propagation, then the physics step.
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	physics.begin_frame(&world_physics)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
		physics.tick(&world_physics, &f.world)
		ecs.update_transforms(&f.world)
	}
	down := [3]f32{0, -1, 0}
	hit, ok := physics.raycast(
		&world_physics,
		&f.world,
		ecs.position_from_meters({3, 10, 0}),
		down,
		20,
	)
	testing.expect(t, ok && hit.entity == f.lamp, "the body is where the cutscene put it")
	_, missed := physics.raycast(
		&world_physics,
		&f.world,
		ecs.position_from_meters({0, 10, 0}),
		down,
		20,
	)
	testing.expect(t, !missed, "and not where it was")
	x := ecs.position_to_meters(ecs.get(&f.world, f.lamp, ecs.Transform).position).x
	testing.expect_value(t, x, 3)
	free_all(f.platform.frame_allocator)
}

// Where a track writes a whole field and another writes a part of it, the restore gives back the value from before the
// first write, whichever was saved last.
@(test)
a_restore_of_overlapping_fields_gives_back_the_first_value :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Whole",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
		},
		{
			id = 2,
			kind = .Property,
			name = "Part",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
		},
	}
	ecs.get_write(&f.world, f.lamp, Lamp).color = {1, 2, 3}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	data, blob, _ := blob_of(f, e.cutscene)
	tracks_of := format.cutscene_tracks(data, blob)
	ctx := Track_Context {
		world      = &f.world,
		evaluation = e,
		data       = data,
		blob       = blob,
		track      = tracks_of[0],
	}
	testing.expect(t, write(&ctx, f.lamp, LAMP_ID, offset_of(Lamp, color), [3]f32{7, 8, 9}))
	ctx.track = tracks_of[1]
	testing.expect(t, write(&ctx, f.lamp, LAMP_ID, offset_of(Lamp, color), f32(4)))
	testing.expect_value(t, ecs.get(&f.world, f.lamp, Lamp).color, [3]f32{4, 8, 9})
	restore(&f.cutscenes, e, &f.world, data, blob)
	testing.expect_value(t, ecs.get(&f.world, f.lamp, Lamp).color, [3]f32{1, 2, 3})
}

// A reload that lands while nothing evaluates still counts: a restore with the new blob puts back what the removed
// track wrote, as an evaluation of it would have.
@(test)
a_restore_follows_a_reload_that_no_evaluation_saw :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = channel(flat(40))},
	}
	brightness_only := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			component = u64(LAMP_ID),
			field = "brightness",
			name = "Brightness",
			binding = 0,
			finish = .Keep,
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(brightness_only), added = false)
	defer end_evaluation(f, e)
	at(f, e, SECOND / 2)
	testing.expect_value(t, brightness(f), 40)
	testing.expect(t, asset.set_live(&f.assets, CUTSCENE_GUID, cutscene_blob(nil, key = 2)))
	data, blob, _ := blob_of(f, e.cutscene)
	restore(&f.cutscenes, e, &f.world, data, blob)
	testing.expect_value(t, brightness(f), 5)
}

// property_setup is eval_setup with the engine's property kind in place of the test's.
@(private = "file")
property_setup :: proc(t: ^testing.T) -> ^Eval_Fixture {
	f := eval_setup(t)
	register_kind(&f.cutscenes, .Property, {phase = .Fixed, evaluate = property_track})
	return f
}

// property is a property track of the lamp's field, with its sections.
@(private = "file")
property :: proc(
	id: u32,
	field: string,
	sections: []format.Cutscene_Section_Contents,
	finish := format.Cutscene_Finish.Restore,
	component := LAMP_ID,
) -> format.Cutscene_Track_Contents {
	return {
		id = id,
		kind = .Property,
		name = field,
		binding = 0,
		component = u64(component),
		field = field,
		finish = finish,
		sections = sections,
	}
}

@(private = "file")
named :: proc(name: string, keys: []format.Cutscene_Key) -> format.Cutscene_Channel_Contents {
	return {name = name, keys = keys}
}

@(private = "file")
lamp :: proc(f: ^Eval_Fixture) -> Lamp {
	return ecs.get(&f.world, f.lamp, Lamp)^
}

// A property track keys the lamp's brightness on a curve and its on bool in steps. A seek back and forth gives the
// exact value at each time, whatever came before.
@(test)
a_property_track_seeks_to_the_exact_values :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	brightness_keys := []format.Cutscene_Key {
		{time = 0, value = 0, interp = .Linear},
		{time = 2 * SECOND, value = 10, interp = .Auto},
		{time = 3 * SECOND, value = 4, interp = .Auto},
	}
	on_keys := []format.Cutscene_Key {
		{time = 0, value = 0, interp = .Constant},
		{time = SECOND, value = 1, interp = .Linear},
		{time = 3 * SECOND, value = 0, interp = .Constant},
	}
	tracks := []format.Cutscene_Track_Contents {
		property(
			1,
			"brightness",
			{
				{
					id = 1,
					start = 0,
					end = 4 * SECOND,
					weight = 1,
					channels = {named("value", brightness_keys)},
				},
			},
		),
		property(
			2,
			"on",
			{
				{
					id = 2,
					start = 0,
					end = 4 * SECOND,
					weight = 1,
					channels = {named("value", on_keys)},
				},
			},
		),
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	times := []i32{SECOND, 3 * SECOND, SECOND / 2, 2 * SECOND + SECOND / 3, 0, 4 * SECOND, SECOND}
	for time in times {
		at(f, e, time)
		testing.expectf(
			t,
			lamp(f).brightness == curve_value(brightness_keys, time),
			"the brightness at %d: %v",
			time,
			lamp(f).brightness,
		)
		testing.expectf(t, lamp(f).on == (time >= SECOND && time < 3 * SECOND), "on at %d", time)
	}
	at(f, e, SECOND)
	testing.expect_value(t, lamp(f).brightness, 5)
	at(f, e, 2 * SECOND)
	testing.expect_value(t, lamp(f).brightness, 10)
}

// When the cutscene finishes, a track set to restore puts its field back, and a track set to keep leaves the last
// value.
@(test)
a_property_track_restores_or_keeps_its_field_when_the_cutscene_finishes :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	ecs.get_write(&f.world, f.lamp, Lamp).count = 3
	tracks := []format.Cutscene_Track_Contents {
		property(
			1,
			"brightness",
			{{id = 1, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(40))}}},
			finish = .Restore,
		),
		property(
			2,
			"count",
			{{id = 2, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(9))}}},
			finish = .Keep,
		),
	}
	testing.expect(
		t,
		asset.set_live(&f.assets, CUTSCENE_GUID, cutscene_blob(tracks, length = SECOND)),
	)
	overrides := []Binding_Override{{binding = Binding_Id(1), entity = f.lamp}}
	player, ok := play(&f.cutscenes, &f.world, {cutscene = CUTSCENE_GUID, overrides = overrides})
	testing.expect(t, ok)
	defer release(&f.cutscenes, &f.world, player)
	update(&f.cutscenes, {world = &f.world})
	tick(f)
	testing.expect_value(t, lamp(f).brightness, 40)
	testing.expect_value(t, lamp(f).count, 9)
	for _ in 0 ..< 70 {
		tick(f)
	}
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, status(&f.cutscenes, player), Player_Status.Restored)
	testing.expect_value(t, lamp(f).brightness, 5)
	testing.expect_value(t, lamp(f).count, 9)
}

// Each channel keys one of a vector's numbers. Absolute sections blend over the field's own value, and an additive
// section adds to the result. A number that no channel keys keeps its own value.
@(test)
a_vector_blends_by_channel_and_additive_sections_add :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	ecs.get_write(&f.world, f.lamp, Lamp).color = {0.25, 0.5, 0.75}
	ecs.get_write(&f.world, f.lamp, Lamp).size = {1, 1}
	tracks := []format.Cutscene_Track_Contents {
		property(
			1,
			"color",
			{
				{
					id = 1,
					start = 0,
					end = 2 * SECOND,
					weight = 0.5,
					channels = {named("r", flat(1))},
				},
				{
					id = 2,
					start = SECOND,
					end = 2 * SECOND,
					weight = 1,
					flags = {.Additive},
					channels = {named("g", flat(0.25))},
				},
			},
		),
		property(
			2,
			"size",
			{{id = 3, start = 0, end = 2 * SECOND, weight = 1, channels = {named("y", flat(3))}}},
		),
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	at(f, e, SECOND / 2)
	testing.expect_value(t, lamp(f).color, [3]f32{0.625, 0.5, 0.75})
	testing.expect_value(t, lamp(f).size, [2]f32{1, 3})
	at(f, e, SECOND)
	testing.expect_value(t, lamp(f).color, [3]f32{0.625, 0.75, 0.75})
	// Past the sections, the field is its own value again.
	at(f, e, 3 * SECOND)
	testing.expect_value(t, lamp(f).color, [3]f32{0.25, 0.5, 0.75})
	testing.expect_value(t, lamp(f).size, [2]f32{1, 1})
}

// Stepped fields take the value of the section with the most weight, or keep their own while the sections' weights
// leave it more. An asset field takes the GUID that its key names.
@(test)
stepped_fields_take_the_heaviest_value :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	ecs.get_write(&f.world, f.lamp, Lamp).mode = .Steady
	bulb_a := format.Guid {
		0  = 0xb1,
		15 = 1,
	}
	bulb_b := format.Guid {
		0  = 0xb1,
		15 = 2,
	}
	steady := []format.Cutscene_Key{{time = 0, value = 0, interp = .Constant}}
	flicker := []format.Cutscene_Key{{time = 0, value = 5, interp = .Constant}}
	swap := []format.Cutscene_Key {
		{time = 0, value = 1, interp = .Constant},
		{time = SECOND, value = 0, interp = .Constant},
	}
	tracks := []format.Cutscene_Track_Contents {
		// The first section eases out over [1, 3) s as the second eases in over [1, 3) s.
		property(
			1,
			"mode",
			{
				{
					id = 1,
					start = 0,
					end = 3 * SECOND,
					ease_out = 2 * SECOND,
					weight = 1,
					channels = {named("value", steady)},
				},
				{
					id = 2,
					start = SECOND,
					end = 4 * SECOND,
					ease_in = 2 * SECOND,
					weight = 1,
					channels = {named("value", flicker)},
				},
			},
		),
		property(
			2,
			"count",
			{
				{
					id = 3,
					start = 0,
					end = 4 * SECOND,
					weight = 1,
					channels = {named("value", flat(2))},
				},
				{
					id = 4,
					start = 0,
					end = 4 * SECOND,
					weight = 1,
					flags = {.Additive},
					channels = {named("value", flat(5))},
				},
			},
		),
		property(
			4,
			"on",
			{
				{
					id = 6,
					start = 0,
					end = 4 * SECOND,
					ease_in = 2 * SECOND,
					weight = 1,
					channels = {named("value", flat(1))},
				},
			},
		),
		property(
			3,
			"bulb",
			{
				{
					id = 5,
					start = 0,
					end = 2 * SECOND,
					weight = 1,
					channels = {{name = "value", flags = {.Guids}, keys = swap}},
				},
			},
		),
	}
	blob := format.cutscene_write(
		{
			guid = CUTSCENE_GUID,
			key = 1,
			length = 4 * SECOND,
			rate = 30,
			range_end = 4 * SECOND,
			bindings = {LAMP_BINDING},
			tracks = tracks,
			source_path = "game/cutscenes/test.cutscene",
			guids = {bulb_a, bulb_b},
		},
		context.temp_allocator,
	)
	e := begin_evaluation(t, f, blob, added = false)
	defer end_evaluation(f, e)
	at(f, e, SECOND / 2)
	testing.expect_value(t, lamp(f).mode, Lamp_Mode.Off)
	testing.expect_value(t, lamp(f).count, 7)
	testing.expect_value(t, lamp(f).bulb, bulb_b)
	at(f, e, SECOND + SECOND / 2)
	testing.expect_value(t, lamp(f).mode, Lamp_Mode.Off)
	testing.expect_value(t, lamp(f).bulb, bulb_a)
	// At 2 s the two eases are halfway, and the later section wins the tie.
	at(f, e, 2 * SECOND)
	testing.expect_value(t, lamp(f).mode, Lamp_Mode.Flicker)
	at(f, e, 2 * SECOND + SECOND / 2)
	testing.expect_value(t, lamp(f).mode, Lamp_Mode.Flicker)
	testing.expect_value(t, lamp(f).bulb, format.Guid{})
	// Early in the cross, the first section still has the most weight.
	at(f, e, SECOND + SECOND / 4)
	testing.expect_value(t, lamp(f).mode, Lamp_Mode.Off)
	// Alone and easing in, a section wins once its weight passes what it leaves to the field's own value.
	at(f, e, SECOND / 2)
	testing.expect(t, !lamp(f).on)
	at(f, e, SECOND + SECOND / 2)
	testing.expect(t, lamp(f).on)
}

// A volume's setting takes its override while a section covers the time, and its own flag otherwise.
@(test)
a_property_track_overrides_a_volume_setting_while_it_plays :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	tracks := []format.Cutscene_Track_Contents {
		property(
			1,
			"glow",
			{{id = 1, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(2))}}},
		),
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	at(f, e, SECOND / 2)
	testing.expect_value(t, lamp(f).glow.value, 2)
	testing.expect(t, lamp(f).glow.override)
	at(f, e, 2 * SECOND)
	testing.expect_value(t, lamp(f).glow.value, 0)
	testing.expect(t, !lamp(f).glow.override)
}

@(private = "file")
Error_Count :: struct {
	errors: int,
}

// count_errors is a logger that counts the errors that the code under test logs.
@(private = "file")
count_errors :: proc(heard: ^Error_Count) -> runtime.Logger {
	return {
		procedure = proc(
			data: rawptr,
			level: runtime.Logger_Level,
			text: string,
			options: runtime.Logger_Options,
			location := #caller_location,
		) {
			if level >= .Error {
				(^Error_Count)(data).errors += 1
			}
		},
		data = heard,
		lowest_level = .Debug,
	}
}

// A track whose field cannot animate, or whose channels or keys do not suit its field, does nothing. The player logs
// each once, however many times it evaluates.
@(test)
a_property_track_that_cannot_animate_its_field_logs_once_and_does_nothing :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	value := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(1))}},
	}
	tracks := []format.Cutscene_Track_Contents {
		property(1, "serial", value),
		property(2, "owner", value),
		property(3, "turn", value),
		property(4, "nothing", value),
		property(5, "brightness", value, component = ecs.Component_Id(424242)),
		property(
			6,
			"color",
			{{id = 2, start = 0, end = SECOND, weight = 1, channels = {named("w", flat(1))}}},
		),
		property(
			7,
			"on",
			{
				{
					id = 3,
					start = 0,
					end = SECOND,
					weight = 1,
					channels = {named("value", flat(0.5))},
				},
			},
		),
		property(
			8,
			"mode",
			{{id = 4, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(1))}}},
		),
		property(
			9,
			"on",
			{
				{
					id = 5,
					start = 0,
					end = SECOND,
					weight = 1,
					flags = {.Additive},
					channels = {named("value", flat(1))},
				},
			},
		),
		property(
			10,
			"count",
			{
				{
					id = 6,
					start = 0,
					end = SECOND,
					weight = 1,
					channels = {named("value", flat(1.5))},
				},
			},
		),
		property(11, "bulb", value),
	}
	ecs.get_write(&f.world, f.lamp, Lamp).serial = 77
	before := lamp(f)
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	heard: Error_Count
	{
		context.logger = count_errors(&heard)
		at(f, e, SECOND / 2)
		at(f, e, SECOND / 4)
		at(f, e, 0)
	}
	testing.expect_value(t, heard.errors, len(tracks))
	testing.expect_value(t, lamp(f), before)
	testing.expect_value(t, len(e.snapshot.saved), 0)
	for track in tracks {
		target, resolved := e.targets[{0, track.id}]
		testing.expectf(t, resolved, "the track %d is resolved", track.id)
		_, has_field := target.field.?
		testing.expectf(t, !has_field, "the track %d has no field", track.id)
	}
}

// A hot reload resolves the tracks again, so a track that now names another field writes that one.
@(test)
a_reload_resolves_a_property_track_again :: proc(t: ^testing.T) {
	f := property_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{id = 1, start = 0, end = SECOND, weight = 1, channels = {named("value", flat(40))}},
	}
	e := begin_evaluation(
		t,
		f,
		cutscene_blob({property(1, "brightness", sections, finish = .Keep)}),
		added = false,
	)
	defer end_evaluation(f, e)
	at(f, e, SECOND / 2)
	testing.expect_value(t, lamp(f).brightness, 40)
	testing.expect(
		t,
		asset.set_live(
			&f.assets,
			CUTSCENE_GUID,
			cutscene_blob({property(1, "count", sections, finish = .Keep)}, key = 2),
		),
	)
	at(f, e, SECOND / 2)
	testing.expect_value(t, lamp(f).count, 40)
	testing.expect_value(t, lamp(f).brightness, 40)
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

// lift puts back what the tracks wrote and forgets it, as the editor's preview does while the editor reads or edits the
// document. The next evaluation writes over the world again, and its base is the world's value then, so an edit made
// while it was lifted is what a restore puts back.
@(test)
lift_puts_the_fields_back_and_the_next_evaluation_writes_over_an_edit :: proc(t: ^testing.T) {
	f := eval_setup(t)
	defer eval_teardown(t, f)
	sections := []format.Cutscene_Section_Contents {
		{
			id = 1,
			start = 0,
			end = 2 * SECOND,
			weight = 1,
			channels = channel(ramp(0, 8, 2 * SECOND)),
		},
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Property,
			name = "Brightness",
			binding = 0,
			component = u64(LAMP_ID),
			field = "brightness",
			sections = sections,
		},
	}
	e := begin_evaluation(t, f, cutscene_blob(tracks), added = false)
	defer end_evaluation(f, e)
	own := brightness(f)
	at(f, e, SECOND)
	testing.expect_value(t, brightness(f), 4)
	testing.expect_value(t, len(saved_fields(e, context.temp_allocator)), 1)

	testing.expect(t, lift(&f.cutscenes, e, &f.world))
	testing.expect_value(t, brightness(f), own)
	testing.expect_value(t, len(saved_fields(e, context.temp_allocator)), 0)
	testing.expect(t, !lift(&f.cutscenes, e, &f.world))

	// An edit while it is lifted, and the same time evaluated again, as a lay does.
	ecs.get_write(&f.world, f.lamp, Lamp).brightness = 9
	data, blob, _ := blob_of(f, e.cutscene)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Fixed)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Late)
	testing.expect_value(t, brightness(f), 4)
	restore(&f.cutscenes, e, &f.world, data, blob)
	testing.expect_value(t, brightness(f), 9)
}
