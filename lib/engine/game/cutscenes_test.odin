package game

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"

@(private = "file")
GAME_CLOCK_GUID :: format.Guid {
	0  = 0x73,
	15 = 1,
}

@(private = "file")
REAL_CLOCK_GUID :: format.Guid {
	0  = 0x73,
	15 = 2,
}

@(private = "file")
Clocks_Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	g:        ^Game,
	on_game:  cutscene.Evaluation,
	on_real:  cutscene.Evaluation,
}

@(private = "file")
setup_clocks :: proc(t: ^testing.T) -> ^Clocks_Fixture {
	f := new(Clocks_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
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
	g := new(Game)
	f.g = g
	g.platform = &f.platform
	testing.expect(t, ecs.init(&g.world, g.platform))
	ecs.register_engine_components(&g.world.registry)
	asset.init(&g.assets, g.platform, asset.loose_cache("game_cutscenes_test_none"))
	cutscene.init(&g.cutscenes, &g.world, &g.assets)
	cutscene.register(&g.cutscenes, &g.world)
	start :: proc(
		t: ^testing.T,
		g: ^Game,
		e: ^cutscene.Evaluation,
		guid: format.Guid,
		clock: format.Cutscene_Clock,
	) {
		blob := format.cutscene_write(
			{
				guid = guid,
				key = 1,
				length = 60 * format.CUTSCENE_TICKS_PER_SECOND,
				rate = 30,
				clock = clock,
				range_end = 60 * format.CUTSCENE_TICKS_PER_SECOND,
				source_path = "game/cutscenes/clock.cutscene",
			},
			context.temp_allocator,
		)
		testing.expect(t, asset.set_live(&g.assets, guid, blob))
		h, _ := asset.find(&g.assets, guid)
		data, _ := asset.data(&g.assets, h)
		view, ok := format.cutscene_view(data)
		testing.expect(t, ok)
		cutscene.init_evaluation(e, &g.world, h, data, view)
		cutscene.add_evaluation(&g.cutscenes, e)
	}
	start(t, g, &f.on_game, GAME_CLOCK_GUID, .Game)
	start(t, g, &f.on_real, REAL_CLOCK_GUID, .Real)
	return f
}

@(private = "file")
teardown_clocks :: proc(f: ^Clocks_Fixture) {
	g := f.g
	cutscene.destroy_evaluation(&f.on_game, &g.world)
	cutscene.destroy_evaluation(&f.on_real, &g.world)
	cutscene.destroy(&g.cutscenes)
	asset.destroy(&g.assets)
	ecs.destroy(&g.world)
	free(g)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// frames runs n frames of a 60th of a second as game_update steps the cutscenes: the real clock by the frame's
// duration, and the game's clock by the ticks of the world's step, which the pause and the time scale set.
@(private = "file")
frames :: proc(f: ^Clocks_Fixture, n: int) {
	g := f.g
	for _ in 0 ..< n {
		dt := time.Second / 60
		step := world_step(g, dt, true)
		cutscene.advance_real(&g.cutscenes, &g.world, dt)
		ticks := ecs.begin_ticks(&g.world, step)
		for ecs.next_tick(&ticks) {
			ecs.run_tick_systems(&ticks, g)
		}
		ecs.run_stage(&g.world, .Late, step, g)
		free_all(f.platform.frame_allocator)
	}
}

// A cutscene on the game's clock follows the time scale and stops while the game is paused. One on the real clock
// plays on at the frames' pace through both.
@(test)
cutscene_clocks_follow_the_games_scale_and_pause :: proc(t: ^testing.T) {
	f := setup_clocks(t)
	defer teardown_clocks(f)
	SECOND :: format.CUTSCENE_TICKS_PER_SECOND
	// The game's clock moves by whole ticks of the world, so it can be a tick of 1/60 s behind the frames. The real clock
	// moves by the frames, which are a few nanoseconds short of a 60th of a second.
	TICK :: SECOND / 60
	near :: proc(
		t: ^testing.T,
		got, want: i32,
		what: string,
		slack: i32 = 2,
		loc := #caller_location,
	) {
		testing.expectf(
			t,
			got <= want && want - got <= slack,
			"%s: %d, not %d",
			what,
			got,
			want,
			loc = loc,
		)
	}

	frames(f, 60)
	near(t, f.on_game.time, SECOND, "a second at a scale of 1, on the game's clock", TICK + 2)
	near(t, f.on_real.time, SECOND, "and on the real clock")

	set_time_scale(f.g, 0.5)
	frames(f, 60)
	near(t, f.on_game.time, 3 * SECOND / 2, "half a second at a scale of 0.5", TICK + 2)
	near(t, f.on_real.time, 2 * SECOND, "a whole second on the real clock")

	before := f.on_game.time
	f.g.paused = true
	frames(f, 60)
	testing.expect_value(t, f.on_game.time, before)
	near(t, f.on_real.time, 3 * SECOND, "a whole second on the real clock")

	f.g.paused = false
	set_time_scale(f.g, 2)
	frames(f, 60)
	near(t, f.on_game.time, 7 * SECOND / 2, "two seconds at a scale of 2", TICK + 2)
	near(t, f.on_real.time, 4 * SECOND, "a whole second on the real clock")
}
