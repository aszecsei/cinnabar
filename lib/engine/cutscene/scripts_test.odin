package cutscene

import "base:runtime"
import "core:c"
import "core:math"
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
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

@(private = "file")
SCRIPTED_GUID :: format.Guid{0xe1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

// MS is a millisecond in ticks.
@(private = "file")
MS :: format.CUTSCENE_TICKS_PER_SECOND / 1000

@(private = "file")
Script_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	scenes:    scene.Scenes,
	runtime:   script.Runtime,
	cutscenes: State,
	reports:   [dynamic]f64,
	// The Director's entity, which plays the cutscene.
	director:  ecs.Entity,
}

@(private = "file", thread_local)
current_scripted: ^Script_Fixture

@(private = "file")
scripted_setup :: proc(t: ^testing.T) -> ^Script_Fixture {
	f := new(Script_Fixture)
	current_scripted = f
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
		level_generation = proc() -> u64 {return 0},
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
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_scripts_test_none"))
	scene.init_scenes(&f.scenes, &f.platform, &f.assets)
	testing.expect(
		t,
		script.init(&f.runtime, &f.platform, &f.world, &f.assets, proc(r: ^script.Runtime) {
				register_scripts(r, &current_scripted.cutscenes)
				script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
					append(&current_scripted.reports, luau.L_checknumber(L, 1))
					return 0
				})
				script.define(r, "Test.director", proc(L: ^luau.State) -> c.int {
					current_scripted.director = script.check_entity(L, 1)
					return 0
				})
				script.define(r, "Test.asset", proc(L: ^luau.State) -> c.int {
					script.push_asset(script.runtime_of(L), L, SCRIPTED_GUID)
					return 1
				})
			}),
	)
	init(&f.cutscenes, &f.world, &f.assets, scripts = &f.runtime)
	register(&f.cutscenes, &f.world)
	return f
}

@(private = "file")
scripted_teardown :: proc(f: ^Script_Fixture) {
	destroy(&f.cutscenes, &f.world)
	script.destroy(&f.runtime)
	scene.destroy_scenes(&f.scenes)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.reports)
	current_scripted = nil
	free(f)
}

// write_scripted sets the cutscene live: one second long on the real clock, with a required possessed binding, Hero,
// which suspends what suspend says, nothing by default. A transform track moves Hero from x = 0 to x = 10 m over the
// second, and an event track sends it on_wave at 500 ms and on_seen at 900 ms, which fires when skipped too. A skip
// fades for 100 ms.
@(private = "file")
write_scripted :: proc(
	t: ^testing.T,
	f: ^Script_Fixture,
	suspend: format.Cutscene_Suspend_Set = {},
) {
	hero := format.Cutscene_Binding_Contents {
		id       = 1,
		kind     = .Possessed,
		name     = "Hero",
		parent   = format.CUTSCENE_NONE,
		asset    = SCRIPTED_GUID,
		entity   = 1,
		rotation = {0, 0, 0, 1},
		scale    = {1, 1, 1},
		suspend  = suspend,
	}
	xs := make([]format.Cutscene_Key, 2, context.temp_allocator)
	xs[0] = {
		time   = 0,
		value  = 0,
		interp = .Linear,
	}
	xs[1] = {
		time   = 1000 * MS,
		value  = 10,
		interp = .Linear,
	}
	channels := make([]format.Cutscene_Channel_Contents, 1, context.temp_allocator)
	channels[0] = {
		name = "position_x",
		keys = xs,
	}
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	sections[0] = {
		id       = 1,
		start    = 0,
		end      = 1000 * MS,
		weight   = 1,
		channels = channels,
	}
	events := make([]format.Cutscene_Event_Contents, 2, context.temp_allocator)
	events[0] = {
		id    = 1,
		start = 500 * MS,
		end   = 500 * MS,
		name  = "wave",
	}
	events[1] = {
		id    = 2,
		start = 900 * MS,
		end   = 900 * MS,
		name  = "seen",
		flags = {.Fire_When_Skipped},
	}
	tracks := make([]format.Cutscene_Track_Contents, 2, context.temp_allocator)
	tracks[0] = {
		id       = 1,
		kind     = .Transform,
		name     = "Walk",
		binding  = 0,
		space    = .Absolute,
		sections = sections,
	}
	tracks[1] = {
		id      = 2,
		kind    = .Event,
		name    = "Events",
		binding = 0,
		events  = events,
	}
	bindings := make([]format.Cutscene_Binding_Contents, 1, context.temp_allocator)
	bindings[0] = hero
	blob := format.cutscene_write(
		{
			guid = SCRIPTED_GUID,
			key = 1,
			length = 1000 * MS,
			rate = 30,
			clock = .Real,
			range_end = 1000 * MS,
			skip = .Anywhere,
			skip_fade = 100 * MS,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/scripted.cutscene",
		},
		context.temp_allocator,
	)
	testing.expect(t, asset.set_live(&f.assets, SCRIPTED_GUID, blob))
}

// DIRECTOR defines Hero, which reports the cutscene's events on it, and Director, which plays the cutscene in its start
// with the options that the global OPTIONS gives, waits for it, and does what the events that the test sends it say.
// The reports: a state's number (0 for nil), 100s for a wait's end, 300s for the lifecycle events, 400 for on_wave.
@(private = "file")
DIRECTOR :: `
local STATES = { loading = 1, ready = 2, playing = 3, paused = 4, skipping = 5, finishing = 6, restored = 7, failed = 8 }
local function report_state(c)
	local state = c:state()
	Test.report(if state == nil then 0 else STATES[state])
end

local Hero = Behaviour.define("Hero")
function Hero:on_wave() Test.report(400) end
function Hero:on_seen() Test.report(450) end
function Hero:on_cutscene_started(c) Test.report(301) end
function Hero:on_cutscene_finished(c, skipped) Test.report(if skipped then 313 else 312) end
function Hero:on_cutscene_failed(c, reason) Test.report(322) end

local Director = Behaviour.define("Director", { bind = Field.boolean(true), wait_ready = Field.boolean(false) })
function Director:start()
	Test.director(self.entity)
	local options = { wait_ready = self.wait_ready }
	if self.bind then
		self.hero = World.spawn()
		self.hero:add(Hero)
		options.bindings = { Hero = self.hero }
	end
	self.c = Cutscene.play(Test.asset(), options)
	report_state(self.c)
	self:start_coroutine(function()
		local skipped = wait_cutscene(self.c)
		Test.report(if skipped then 101 else 100)
	end)
end
function Director:on_check() report_state(self.c) end
function Director:on_time() Test.report(math.round(self.c:time() * 1000)) end
function Director:on_play() self.c:play() end
function Director:on_pause() self.c:pause() end
function Director:on_resume() self.c:resume() end
function Director:on_skip() Test.report(if self.c:skip() then 1 else 0) end
function Director:on_stop()
	self.c:stop()
	report_state(self.c)
end
function Director:on_bound()
	Test.report(if self.c:binding("Hero") == self.hero then 1 else 0)
end
function Director:on_stale()
	self.c:play()
	self.c:pause()
	self.c:resume()
	self.c:stop()
	local nothing = not self.c:skip() and self.c:time() == nil and self.c:length() == nil
		and self.c:binding("Hero") == nil and self.c:error() == nil and self.c:state() == nil
	Test.report(if nothing then 1 else 0)
end
function Director:on_cutscene_started(c) Test.report(if c == self.c then 300 else -1) end
function Director:on_cutscene_finished(c, skipped)
	Test.report(if c ~= self.c then -1 elseif skipped then 311 else 310)
end
function Director:on_cutscene_failed(c, reason)
	Test.report(if c == self.c and reason == self.c:error() and reason == "binding_missing" then 320 else -1)
end
`

// direct runs DIRECTOR and then the source, which adds a Director, and the Director's start, which plays the cutscene.
@(private = "file")
direct :: proc(t: ^testing.T, f: ^Script_Fixture, director: string) {
	source := strings.concatenate({DIRECTOR, director}, context.temp_allocator)
	_, ok := script.spawn_source(&f.runtime, "=scripts_test", source)
	testing.expect(t, ok)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect(t, f.director != 0)
}

// frame runs a frame as the game does for a cutscene on the real clock: the players' update, the move of the playing
// cutscenes by ms milliseconds, and the script phase, which delivers the events and runs the coroutines.
@(private = "file")
frame :: proc(f: ^Script_Fixture, ms: int) {
	dt := time.Duration(ms) * time.Millisecond
	update(&f.cutscenes, {world = &f.world, scenes = &f.scenes, scripts = &f.runtime, dt = dt})
	advance_real(&f.cutscenes, &f.world, dt)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

// tell sends the Director an event, and runs a script phase that delivers it, and the end of the frame, which sends
// the events that its commands queued, for the next script phase.
@(private = "file")
tell :: proc(f: ^Script_Fixture, name: string) {
	script.send(&f.runtime, f.director, name)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	end_frame(&f.cutscenes)
	free_all(f.platform.frame_allocator)
}

// expect_reports checks the reports since the last check. The reports of one script phase come in the order of the
// instances, so the test sorts them when sorted is set.
@(private = "file")
expect_reports :: proc(
	t: ^testing.T,
	f: ^Script_Fixture,
	want: []f64,
	sorted := false,
	loc := #caller_location,
) {
	got := slice.clone(f.reports[:], context.temp_allocator)
	expected := slice.clone(want, context.temp_allocator)
	if sorted {
		slice.sort(got)
		slice.sort(expected)
	}
	testing.expectf(t, slice.equal(got, expected), "reports %v, want %v", got, expected, loc = loc)
	clear(&f.reports)
}

// hero_x is the Hero binding's x, in meters.
@(private = "file")
hero_x :: proc(f: ^Script_Fixture) -> f64 {
	e, ok := player_evaluation(&f.cutscenes, find_player(f))
	if !ok {
		return math.nan_f64()
	}
	entity, alive := binding_entity(&e.bindings, &f.world, 0)
	if !alive {
		return math.nan_f64()
	}
	return f64(ecs.get(&f.world, entity, ecs.Transform).position.raw.x) / (1 << 24)
}

// find_player is the handle of the one player in the state.
@(private = "file")
find_player :: proc(f: ^Script_Fixture) -> Player_Handle {
	for p, slot in f.cutscenes.players {
		if p.state != nil {
			return {u16(slot), p.generation}
		}
	}
	return {}
}

// A script plays a cutscene that waits in Ready, plays, pauses, resumes and skips it, and reads each state on the
// way. Its coroutine's wait_cutscene ends at Restored with skipped true. The entity that the script gave for the
// binding moves, gets the event key as on_wave, and gets the lifecycle events with the Director.
@(test)
a_script_plays_a_cutscene_reads_each_state_and_waits_for_its_skip :: proc(t: ^testing.T) {
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f)
	direct(t, f, `World.spawn():add(Director, { wait_ready = true })`)
	expect_reports(t, f, {1})

	frame(f, 0)
	tell(f, "check")
	expect_reports(t, f, {2})
	tell(f, "bound")
	expect_reports(t, f, {1})

	// The start's events go out at the end of the frame, so the next script phase delivers them.
	tell(f, "play")
	expect_reports(t, f, {})
	tell(f, "check")
	expect_reports(t, f, {3, 300, 301}, sorted = true)

	frame(f, 300)
	tell(f, "pause")
	tell(f, "check")
	tell(f, "time")
	expect_reports(t, f, {4, 300})
	testing.expectf(t, abs(hero_x(f) - 3) < 1e-3, "the hero walks to x = 3 m: %v", hero_x(f))

	tell(f, "resume")
	frame(f, 300)
	expect_reports(t, f, {400})
	tell(f, "check")
	expect_reports(t, f, {3})

	tell(f, "skip")
	tell(f, "check")
	expect_reports(t, f, {1, 5})
	// The fade out ends, the player jumps to the end and gives the world back, and the wait ends. The key that fires
	// when skipped comes before the end of the cutscene.
	frame(f, 100)
	seen, finished := -1, -1
	for report, i in f.reports {
		if report == 450 {
			seen = i
		} else if report == 313 {
			finished = i
		}
	}
	testing.expectf(
		t,
		seen >= 0 && seen < finished,
		"on_seen comes before on_cutscene_finished: %v",
		f.reports[:],
	)
	expect_reports(t, f, {101, 311, 313, 450}, sorted = true)
	tell(f, "check")
	expect_reports(t, f, {7})
}

// A stop shows Finishing at once, and the next update gives the world back: the wait and on_cutscene_finished say that
// it was not skipped.
@(test)
a_stopped_cutscene_is_finishing_and_then_finished_without_a_skip :: proc(t: ^testing.T) {
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f)
	direct(t, f, `World.spawn():add(Director)`)
	frame(f, 100)
	expect_reports(t, f, {1, 300, 301}, sorted = true)

	tell(f, "stop")
	expect_reports(t, f, {6})
	frame(f, 0)
	expect_reports(t, f, {100, 310, 312}, sorted = true)
	tell(f, "check")
	expect_reports(t, f, {7})
}

// A cutscene whose required binding has no entity fails: its caller gets on_cutscene_failed with the reason that
// :error() gives, and the wait ends with false.
@(test)
a_cutscene_without_its_binding_fails_with_its_reason :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f)
	direct(t, f, `World.spawn():add(Director, { bind = false })`)
	expect_reports(t, f, {1})
	frame(f, 0)
	expect_reports(t, f, {100, 320}, sorted = true)
	tell(f, "check")
	expect_reports(t, f, {8})
}

// A reset frees the player, so the script's handle is stale: its commands do nothing, its readers give nil, and the
// wait that was on it ends.
@(test)
a_stale_handle_does_nothing_and_its_wait_ends :: proc(t: ^testing.T) {
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f)
	direct(t, f, `World.spawn():add(Director)`)
	frame(f, 100)
	expect_reports(t, f, {1, 300, 301}, sorted = true)

	reset(&f.cutscenes, &f.world)
	send_events(&f.cutscenes)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	expect_reports(t, f, {100, 310, 312}, sorted = true)
	tell(f, "stale")
	tell(f, "check")
	expect_reports(t, f, {1, 0})
	testing.expect_value(t, find_player(f), Player_Handle{})
}

// start seeks a cutscene that waits in Ready, and a wrong option raises an error and plays nothing.
@(test)
play_starts_where_it_is_told_and_refuses_a_wrong_option :: proc(t: ^testing.T) {
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f)
	_, ok := script.spawn_source(
		&f.runtime,
		"=scripts_test_start",
		`
local Starter = Behaviour.define("Starter")
function Starter:start()
	Test.director(self.entity)
	self.hero = World.spawn()
	self.c = Cutscene.play(Test.asset(), { bindings = { Hero = self.hero }, start = 0.25, wait_ready = true, priority = 2 })
	Test.report(if pcall(Cutscene.play, Test.asset(), { nope = 1 }) then 0 else 1)
	Test.report(if pcall(Cutscene.play, Test.asset(), { start = "soon" }) then 0 else 1)
	Test.report(if pcall(Cutscene.play, Test.asset(), { bindings = { Hero = 3 } }) then 0 else 1)
	Test.report(if pcall(Cutscene.play, nil) then 0 else 1)
end
function Starter:on_time()
	Test.report(math.round(self.c:time() * 1000))
	Test.report(self.c:length())
	Test.report(if tostring(self.c):sub(1, 9) == "Cutscene(" then 1 else 0)
end
World.spawn():add(Starter)
`,
	)
	testing.expect(t, ok)
	script.run_phase(&f.runtime, 16 * time.Millisecond, {})
	expect_reports(t, f, {1, 1, 1, 1})
	testing.expect_value(t, len(f.cutscenes.events), 1)
	frame(f, 0)
	tell(f, "time")
	expect_reports(t, f, {250, 1, 1})
	testing.expect_value(t, f.cutscenes.players[find_player(f).slot].priority, 2)
}

// A binding that suspends its entity's behaviours holds them from Loading, so they miss on_cutscene_started. The player
// resumes them as it gives the world back, before the script phase that delivers on_cutscene_finished, so they get it.
@(test)
suspended_behaviours_miss_the_start_and_get_the_end :: proc(t: ^testing.T) {
	f := scripted_setup(t)
	defer scripted_teardown(f)
	write_scripted(t, f, {.Behaviours})
	direct(t, f, `World.spawn():add(Director)`)
	expect_reports(t, f, {1})
	frame(f, 100)
	expect_reports(t, f, {300})
	tell(f, "stop")
	expect_reports(t, f, {6})
	frame(f, 0)
	expect_reports(t, f, {100, 310, 312}, sorted = true)
}
