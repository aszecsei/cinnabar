package cutscene

import "base:runtime"
import "core:c"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

@(private = "file")
EVENTS_GUID :: format.Guid{0xe0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

// GLOBAL is the binding of a track whose events go to every behaviour.
@(private = "file")
GLOBAL :: format.CUTSCENE_NONE

// MS is a millisecond in ticks.
@(private = "file")
MS :: format.CUTSCENE_TICKS_PER_SECOND / 1000

@(private = "file")
Event_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	runtime:   script.Runtime,
	cutscenes: State,
	// The names of the events that the native handlers got, in order.
	heard:     [dynamic]string,
	// What the scripts reported.
	reports:   [dynamic]f64,
}

@(private = "file", thread_local)
current_events: ^Event_Fixture

@(private = "file")
event_setup :: proc(t: ^testing.T) -> ^Event_Fixture {
	f := new(Event_Fixture)
	current_events = f
	f.heard = make([dynamic]string)
	f.reports = make([dynamic]f64)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
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
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
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
	script.register_components(&f.world.registry)
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_event_test_none"))
	testing.expect(
		t,
		script.init(&f.runtime, &f.platform, &f.world, &f.assets, proc(r: ^script.Runtime) {
				script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
					append(&current_events.reports, luau.L_checknumber(L, 1))
					return 0
				})
			}),
	)
	init(&f.cutscenes, &f.world, &f.assets, scripts = &f.runtime)
	register(&f.cutscenes, &f.world)
	return f
}

@(private = "file")
event_teardown :: proc(f: ^Event_Fixture) {
	destroy(&f.cutscenes, &f.world)
	script.destroy(&f.runtime)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	for name in f.heard {
		delete(name)
	}
	delete(f.heard)
	delete(f.reports)
	current_events = nil
	free(f)
}

// listen registers a native handler for each name, which records the events' names in heard.
@(private = "file")
listen :: proc(f: ^Event_Fixture, names: ..string) {
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

// expect_heard checks the names that the handlers got since the last check, in order.
@(private = "file")
expect_heard :: proc(t: ^testing.T, f: ^Event_Fixture, want: ..string, loc := #caller_location) {
	testing.expectf(
		t,
		slice.equal(f.heard[:], want),
		"heard %v, want %v",
		f.heard[:],
		want,
		loc = loc,
	)
	for name in f.heard {
		delete(name)
	}
	clear(&f.heard)
}

@(private = "file")
trigger :: proc(
	id: u32,
	at: i32,
	name: string,
	flags: format.Cutscene_Event_Flags = {},
	values: []format.Cutscene_Event_Value_Contents = nil,
) -> format.Cutscene_Event_Contents {
	return {id = id, start = at, end = at, name = name, flags = flags, values = values}
}

@(private = "file")
span :: proc(
	id: u32,
	start, end: i32,
	name: string,
	flags: format.Cutscene_Event_Flags = {},
) -> format.Cutscene_Event_Contents {
	return {id = id, start = start, end = end, name = name, flags = flags + {.Range}}
}

// events_track is an event track of a binding's index, or global with CUTSCENE_NONE, with its events in start order.
@(private = "file")
events_track :: proc(
	id: u32,
	binding: u32,
	events: ..format.Cutscene_Event_Contents,
) -> format.Cutscene_Track_Contents {
	list := slice.clone(events, context.temp_allocator)
	slice.stable_sort_by(list, proc(a, b: format.Cutscene_Event_Contents) -> bool {
		return a.start < b.start
	})
	return {id = id, kind = .Event, name = "Events", binding = binding, events = list}
}

// write_events sets the cutscene's blob live: one second long, on the real clock, so each step moves its time exactly.
@(private = "file")
write_events :: proc(
	t: ^testing.T,
	f: ^Event_Fixture,
	tracks: []format.Cutscene_Track_Contents,
	range_end: i32 = 1000 * MS,
	key: u64 = 1,
	bindings: []format.Cutscene_Binding_Contents = nil,
	guids: []format.Guid = nil,
	clock := format.Cutscene_Clock.Real,
	skip_ranges: []format.Cutscene_Skip_Range = nil,
) {
	blob := format.cutscene_write(
		{
			guid = EVENTS_GUID,
			key = key,
			length = 1000 * MS,
			rate = 30,
			clock = clock,
			range_end = range_end,
			skip = .Ranges if skip_ranges != nil else .Anywhere,
			skip_ranges = skip_ranges,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/events.cutscene",
			guids = guids,
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, EVENTS_GUID, blob))
}

@(private = "file")
play_events :: proc(
	t: ^testing.T,
	f: ^Event_Fixture,
	overrides: []Binding_Override = nil,
) -> Player_Handle {
	h, ok := play(&f.cutscenes, &f.world, {cutscene = EVENTS_GUID, overrides = overrides})
	testing.expect(t, ok)
	return h
}

// step runs a frame as the game does for a cutscene on the real clock: the players' update, then the move of the
// playing cutscenes by ms milliseconds, which evaluates their Fixed tracks.
@(private = "file")
step :: proc(f: ^Event_Fixture, ms: int) {
	dt := time.Duration(ms) * time.Millisecond
	update(&f.cutscenes, {world = &f.world, dt = dt})
	advance_real(&f.cutscenes, &f.world, dt)
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

// tick_frame runs a frame as the game does for a cutscene on the game's clock: the players' update, then a tick of a
// 60th of a second, after which the cutscene's events go to the scripts and script.fixed_events delivers them.
@(private = "file")
tick_frame :: proc(f: ^Event_Fixture) {
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		send_events(&f.cutscenes)
		script.fixed_events(&f.runtime)
	}
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

// A frame that crosses many keys sends them all, once, in time order, and at one time in track order, so a long hitch
// does not drop events.
@(test)
a_hitch_sends_every_key_that_it_crosses_in_time_and_track_order :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "k1", "k2", "k3", "k4", "k5")
	tracks := []format.Cutscene_Track_Contents {
		events_track(
			1,
			GLOBAL,
			trigger(1, 100 * MS, "k1"),
			trigger(3, 300 * MS, "k3"),
			trigger(5, 450 * MS, "k5"),
		),
		events_track(2, GLOBAL, trigger(2, 200 * MS, "k2"), trigger(4, 300 * MS, "k4")),
	}
	write_events(t, f, tracks)
	play_events(t, f)
	step(f, 50)
	expect_heard(t, f)
	step(f, 50)
	expect_heard(t, f, "k1")
	// A hitch of 400 ms crosses four keys on two tracks. At 300 ms, the first track's key goes first.
	step(f, 400)
	expect_heard(t, f, "k2", "k3", "k4", "k5")
	step(f, 50)
	step(f, 50)
	expect_heard(t, f)
}

// A seek backwards sends nothing, and playing forward again sends the keys again.
@(test)
a_seek_backwards_sends_nothing_and_playing_on_sends_the_keys_again :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "a", "b")
	write_events(
		t,
		f,
		{events_track(1, GLOBAL, trigger(1, 100 * MS, "a"), trigger(2, 200 * MS, "b"))},
	)
	h := play_events(t, f)
	for _ in 0 ..< 5 {
		step(f, 50)
	}
	expect_heard(t, f, "a", "b")
	testing.expect_value(t, set_time(&f.cutscenes, &f.world, h, 50 * MS), Command_Result.Done)
	step(f, 0)
	expect_heard(t, f)
	for _ in 0 ..< 4 {
		step(f, 50)
	}
	expect_heard(t, f, "a", "b")
}

// A skip sends the keys marked to fire when skipped, and the ranges crossed whole that are marked, in order, and the
// end of the range that is open at the skip. The other keys and ranges send nothing.
@(test)
a_skip_sends_only_what_fires_when_skipped_and_the_ends_of_open_ranges :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "r_begin", "r_end", "a", "b", "q_begin", "q_end", "m_begin", "m_end", "c")
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				span(1, 50 * MS, 600 * MS, "r"),
				trigger(2, 200 * MS, "a", {.Fire_When_Skipped}),
				trigger(3, 300 * MS, "b"),
				span(4, 200 * MS, 300 * MS, "q"),
				span(5, 250 * MS, 350 * MS, "m", {.Fire_When_Skipped}),
				trigger(6, 400 * MS, "c", {.Fire_When_Skipped}),
			),
		},
	)
	h := play_events(t, f)
	step(f, 100)
	expect_heard(t, f, "r_begin")
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	step(f, 0)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	expect_heard(t, f, "a", "m_begin", "m_end", "c", "r_end")
}

// Ranges send their begins and ends in playback, and a range that is still open at the end sends its end when the
// cutscene finishes, or when it stops.
@(test)
ranges_begin_and_end_in_playback_and_end_when_the_cutscene_finishes :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "p_begin", "p_end", "q_begin", "q_end")
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				span(1, 100 * MS, 200 * MS, "p"),
				span(2, 500 * MS, 1000 * MS, "q"),
			),
		},
		range_end = 800 * MS,
	)
	h := play_events(t, f)
	step(f, 100)
	expect_heard(t, f, "p_begin")
	step(f, 100)
	expect_heard(t, f, "p_end")
	for status(&f.cutscenes, h) == .Playing {
		step(f, 100)
	}
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	expect_heard(t, f, "q_begin", "q_end")

	// A stop is a finish too.
	h = play_events(t, f)
	step(f, 150)
	expect_heard(t, f, "p_begin")
	testing.expect_value(t, stop(&f.cutscenes, &f.world, h), Command_Result.Done)
	// The stop queues the end, and the next update delivers it.
	step(f, 0)
	expect_heard(t, f, "p_end")
}

// A forward seek sends the keys marked to fire on seek, the begin of the range that it lands in and the end of the one
// that it leaves, and a range that it crosses whole only when it is marked.
@(test)
a_forward_seek_sends_what_fires_on_seek_and_the_ranges_that_it_enters_and_leaves :: proc(
	t: ^testing.T,
) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "s", "n", "r_begin", "r_end", "w_begin", "w_end", "x_begin", "x_end")
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				trigger(1, 100 * MS, "s", {.Fire_On_Seek}),
				trigger(2, 200 * MS, "n"),
				span(3, 300 * MS, 500 * MS, "r"),
				span(4, 550 * MS, 600 * MS, "w", {.Fire_On_Seek}),
				span(5, 620 * MS, 650 * MS, "x"),
			),
		},
	)
	h := play_events(t, f)
	step(f, 0)
	set_time(&f.cutscenes, &f.world, h, 400 * MS)
	step(f, 0)
	expect_heard(t, f, "s", "r_begin")
	// Two seeks before one evaluation are one move.
	set_time(&f.cutscenes, &f.world, h, 900 * MS)
	set_time(&f.cutscenes, &f.world, h, 700 * MS)
	step(f, 0)
	expect_heard(t, f, "r_end", "w_begin", "w_end")
}

// Only an evaluation that plays sends events: a scrub and a preview send none, and playing again sends the begin of
// the range that the time is in.
@(test)
a_scrub_and_a_preview_send_no_events :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "a", "r_begin", "r_end")
	write_events(
		t,
		f,
		{events_track(1, GLOBAL, trigger(1, 100 * MS, "a"), span(2, 50 * MS, 500 * MS, "r"))},
	)
	h := play_events(t, f)
	step(f, 0)
	e, live := player_evaluation(&f.cutscenes, h)
	testing.expect(t, live)
	set_audition(e, &f.world, .Scrub)
	step(f, 200)
	expect_heard(t, f)
	set_audition(e, &f.world, .Play)
	step(f, 100)
	expect_heard(t, f, "r_begin")
	// The change of audition forgets the open range without sending its end.
	set_audition(e, &f.world, .Preview)
	step(f, 300)
	expect_heard(t, f)
}

// A cutscene that fails sends no more events, not even the end of an open range.
@(test)
a_failed_cutscene_sends_no_more_events :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "r_begin", "r_end")
	tracks := []format.Cutscene_Track_Contents {
		events_track(1, GLOBAL, span(1, 50 * MS, 900 * MS, "r")),
	}
	write_events(t, f, tracks)
	h := play_events(t, f)
	step(f, 100)
	expect_heard(t, f, "r_begin")
	// A blob that does not check fails the player.
	context.logger = testlog.expected_errors()
	write_events(t, f, tracks, range_end = 1000 * MS + 1, key = 2)
	step(f, 100)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Failed)
	expect_heard(t, f)
}

// A reload that moves an open range keeps its begin and end paired: the range sends its end once the time is out of
// it, and its begin and end again where it now is.
@(test)
a_reload_that_moves_a_range_keeps_its_begin_and_end_paired :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "r_begin", "r_end")
	write_events(t, f, {events_track(1, GLOBAL, span(1, 100 * MS, 300 * MS, "r"))})
	play_events(t, f)
	step(f, 200)
	expect_heard(t, f, "r_begin")
	write_events(t, f, {events_track(1, GLOBAL, span(1, 500 * MS, 700 * MS, "r"))}, key = 2)
	step(f, 50)
	step(f, 50)
	expect_heard(t, f, "r_end")
	for _ in 0 ..< 6 {
		step(f, 100)
	}
	expect_heard(t, f, "r_begin", "r_end")
}

// An event of a bound track reaches the binding's behaviours with a value of each kind, and an event of a global track
// reaches every behaviour with its handler.
@(test)
events_reach_behaviours_with_a_value_of_each_kind :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	_, ok := script.spawn_source(
		&f.runtime,
		"=catcher",
		`
local Catcher = Behaviour.define("Catcher")
function Catcher:on_door_open(n, b, s, v)
	Test.report(n)
	Test.report(if b then 1 else 0)
	Test.report(if s == "red" then 1 else 0)
	Test.report(v.y)
end
function Catcher:on_gate_seen(e, p, a)
	Test.report(if e == self.entity then 1 else 0)
	Test.report((p - WorldPosition.origin).y)
	Test.report(if a.guid == "e0010203040506070809" .. "0a0b0c0d0e0f" then 1 else 0)
end
function Catcher:on_shout(n)
	Test.report(100 + n)
end
World.spawn():add(Catcher)
`,
	)
	testing.expect(t, ok)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {script.BEHAVIOURS_ID}, &found)
	if !testing.expect_value(t, len(found), 1) {
		return
	}
	raw, _ := format.world_raw_from_meters(2)
	gate := format.Cutscene_Binding_Contents {
		id       = 1,
		kind     = .Possessed,
		name     = "Gate",
		parent   = format.CUTSCENE_NONE,
		asset    = EVENTS_GUID,
		entity   = 1,
		rotation = {0, 0, 0, 1},
		scale    = {1, 1, 1},
	}
	door_values := []format.Cutscene_Event_Value_Contents {
		{kind = .Number, number = 2.5},
		{kind = .Bool, index = 1},
		{kind = .String, text = "red"},
		{kind = .Vector, vector = {0, 1, 0}},
	}
	seen_values := []format.Cutscene_Event_Value_Contents {
		{kind = .Entity, index = 0},
		{kind = .Position, position = {0, raw, 0}},
		{kind = .Asset, index = 0},
	}
	write_events(
		t,
		f,
		{
			events_track(
				1,
				0,
				trigger(1, 100 * MS, "door_open", values = door_values),
				trigger(2, 200 * MS, "gate_seen", values = seen_values),
			),
			events_track(
				2,
				GLOBAL,
				trigger(3, 300 * MS, "shout", values = {{kind = .Number, number = 1}}),
			),
		},
		bindings = {gate},
		guids = {EVENTS_GUID},
	)
	play_events(t, f, {{Binding_Id(1), found[0]}})
	for _ in 0 ..< 4 {
		step(f, 100)
	}
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expectf(
		t,
		slice.equal(f.reports[:], []f64{2.5, 1, 1, 1, 1, 2, 1, 101}),
		"reports %v",
		f.reports[:],
	)
}

// A native handler that stops its own player in the middle of the events: the events queued after it are still
// delivered, and the ends of the open ranges follow them, so each end still follows its begin.
@(test)
a_handler_that_stops_its_player_still_ends_each_range_after_its_begin :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "alarm_begin", "alarm_end", "b_begin", "b_end", "c")
	register_event_handler(
		&f.cutscenes,
		"door_open",
		proc(data: rawptr, player: Player_Handle, name: string, _: []script.Event_Arg) {
			f := (^Event_Fixture)(data)
			append(&f.heard, strings.clone(name))
			stop(&f.cutscenes, &f.world, player)
		},
		f,
	)
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				span(1, 50 * MS, 900 * MS, "alarm"),
				trigger(2, 100 * MS, "door_open"),
				span(3, 150 * MS, 900 * MS, "b"),
				trigger(4, 200 * MS, "c"),
			),
		},
	)
	h := play_events(t, f)
	step(f, 50)
	expect_heard(t, f, "alarm_begin")
	step(f, 200)
	expect_heard(t, f, "door_open", "b_begin", "c", "alarm_end", "b_end")
	step(f, 0)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
	expect_heard(t, f)
}

// On the game's clock, the event track evaluates in the cutscene fixed system, and its events reach the behaviours in
// the same tick, through script.fixed_events, with no script phase.
@(test)
on_the_game_clock_events_reach_behaviours_in_their_tick :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	_, ok := script.spawn_source(
		&f.runtime,
		"=listener",
		`
local Listener = Behaviour.define("Listener")
function Listener:on_shout(n)
	Test.report(n)
end
World.spawn():add(Listener)
`,
	)
	testing.expect(t, ok)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				trigger(1, 0, "shout", values = {{kind = .Number, number = 1}}),
				trigger(2, 50 * MS, "shout", values = {{kind = .Number, number = 2}}),
			),
		},
		clock = .Game,
	)
	play_events(t, f)
	tick_frame(f)
	testing.expectf(t, slice.equal(f.reports[:], []f64{1}), "reports %v", f.reports[:])
	for _ in 0 ..< 3 {
		tick_frame(f)
	}
	testing.expectf(t, slice.equal(f.reports[:], []f64{1, 2}), "reports %v", f.reports[:])
}

// A skip to the end of a skip range that lands in a range sends its begin, marked or not, and play goes on with the
// range open. A range that the skip crosses whole sends nothing.
@(test)
a_skip_that_lands_in_a_range_sends_its_begin :: proc(t: ^testing.T) {
	f := event_setup(t)
	defer event_teardown(f)
	listen(f, "r_begin", "r_end", "q_begin", "q_end")
	write_events(
		t,
		f,
		{
			events_track(
				1,
				GLOBAL,
				span(1, 300 * MS, 600 * MS, "r"),
				span(2, 150 * MS, 250 * MS, "q"),
			),
		},
		skip_ranges = {{0, 400 * MS}},
	)
	h := play_events(t, f)
	step(f, 100)
	testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
	step(f, 0)
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	expect_heard(t, f, "r_begin")
	for _ in 0 ..< 3 {
		step(f, 100)
	}
	expect_heard(t, f, "r_end")
}
