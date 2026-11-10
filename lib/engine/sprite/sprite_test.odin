package sprite

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The scheduler is a singleton, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
SHEET :: "51515151515151515151515151515151"

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	cache:    string,
	assets:   asset.Assets,
	sprites:  State,
	// With scripts: the runtime, the entity that Test.entity gives, and what Test.report reported.
	scripts:  bool,
	runtime:  script.Runtime,
	entity:   ecs.Entity,
	reports:  [dynamic]string,
}

@(private = "file")
guid :: proc(text: string) -> format.Guid {
	g, _ := format.guid_parse(text)
	return g
}

// setup makes a world with the render components and the animate sprites system, and a cache with a sheet of three
// frames: a walk of two frames a second that loops over the first two, and a jump over all three that does not.
@(private = "file")
setup :: proc(t: ^testing.T, scripts := false) -> ^Fixture {
	sync.lock(&lock)
	testing.expect(t, jobs.init())
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
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
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	render.register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "sprite_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	register(&f.sprites, &f.world, &f.assets)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]string)
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts))
	}
	blob := format.sprite_sheet_write(
		{
			guid = guid(SHEET),
			key = 1,
			atlas = {0 = 1},
			atlas_size = {48, 16},
			pixels_per_unit = 16,
			frames = {{name = "a", rect = {0, 0, 16, 16}}, {name = "b", rect = {16, 0, 16, 16}}, {name = "c", rect = {32, 0, 16, 16}}},
			animations = {{name = "walk", frames = {0, 1}, rate = 2, loop = true}, {name = "jump", frames = {0, 1, 2}, rate = 2}},
			source_path = "game/hero.sprite_sheet",
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.cache, SHEET), blob) == nil)
	return f
}

// register_test_scripts defines the Sprites library, Test.entity, and Test.report, which keeps its arguments.
@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.sprites)
	script.define(r, "Test.entity", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).entity)
		return 1
	})
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		report := ""
		for i in 1 ..= luau.gettop(L) {
			report = fmt.tprintf("%s%s%s", report, i > 1 ? " " : "", string(cstring(luau.L_tolstring(L, i, nil))))
			luau.pop(L, 1)
		}
		append(&f.reports, fmt.aprint(report))
		return 0
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		for report in f.reports {
			delete(report)
		}
		delete(f.reports)
	}
	destroy(&f.sprites)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
	testing.expect(t, jobs.drain_frame())
	jobs.shutdown()
	sync.unlock(&lock)
}

@(private = "file")
spawn :: proc(f: ^Fixture, sheet: format.Guid) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{rotation = 1, scale = 1})
	sprite := render.DEFAULT_SPRITE_RENDERER
	sprite.sheet = sheet
	ecs.add(&f.world, e, sprite)
	return e
}

// shown is the name of the frame that a sprite shows.
@(private = "file")
shown :: proc(t: ^testing.T, f: ^Fixture, e: ecs.Entity) -> string {
	sprite := ecs.get(&f.world, e, render.Sprite_Renderer)
	data, blob, ok := render.sprite_sheet_blob(&f.sprites.sheets, &f.assets, sprite.sheet)
	testing.expect(t, ok)
	frame, has_frame := render.sprite_frame(data, blob, sprite^)
	testing.expect(t, has_frame)
	return string(format.blob_bytes(data, frame.name))
}

@(test)
a_sprite_plays_an_animation_by_name :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	e := spawn(f, guid(SHEET))
	sprite := ecs.get_write(&f.world, e, render.Sprite_Renderer)
	sprite.frame = 2
	testing.expect_value(t, shown(t, f, e), "c")
	testing.expect_value(t, animation_name(&f.sprites, sprite^), "")
	testing.expect(t, finished(&f.sprites, sprite^))

	testing.expect_value(t, play(&f.sprites, sprite, "walk"), Found.Ok)
	testing.expect_value(t, animation_name(&f.sprites, sprite^), "walk")
	testing.expect_value(t, shown(t, f, e), "a")
	// The system moves it on by the frame's time: half a second a frame, and around again.
	ecs.run_stage(&f.world, .Update, 600 * time.Millisecond, f)
	testing.expect(t, abs(sprite.time - 0.6) < 1e-6)
	testing.expect_value(t, shown(t, f, e), "b")
	ecs.run_stage(&f.world, .Update, 500 * time.Millisecond, f)
	testing.expect_value(t, shown(t, f, e), "a")
	testing.expect(t, !finished(&f.sprites, sprite^))
	// To play what plays already goes on, and a restart starts it again.
	testing.expect_value(t, play(&f.sprites, sprite, "walk"), Found.Ok)
	testing.expect(t, sprite.time > 1)
	testing.expect_value(t, play(&f.sprites, sprite, "walk", restart = true), Found.Ok)
	testing.expect_value(t, sprite.time, 0)
	// At half speed, it takes twice as long, and a stopped sprite holds its frame.
	sprite.speed = 0.5
	ecs.run_stage(&f.world, .Update, 1200 * time.Millisecond, f)
	testing.expect_value(t, shown(t, f, e), "b")
	stop(sprite)
	ecs.run_stage(&f.world, .Update, 10000 * time.Millisecond, f)
	testing.expect_value(t, shown(t, f, e), "b")

	// The jump does not loop: it ends on its last frame.
	sprite.speed = 1
	testing.expect_value(t, play(&f.sprites, sprite, "jump"), Found.Ok)
	testing.expect_value(t, sprite.time, 0)
	ecs.run_stage(&f.world, .Update, 5000 * time.Millisecond, f)
	testing.expect_value(t, shown(t, f, e), "c")
	testing.expect(t, finished(&f.sprites, sprite^))

	// A frame by name takes the animation's place.
	testing.expect_value(t, set_frame(&f.sprites, sprite, "b"), Found.Ok)
	testing.expect_value(t, sprite.animation, 0)
	testing.expect_value(t, shown(t, f, e), "b")
	// A name that the sheet does not have changes nothing, and a sprite without a sheet has nothing to look in.
	testing.expect_value(t, play(&f.sprites, sprite, "run"), Found.No_Name)
	testing.expect_value(t, set_frame(&f.sprites, sprite, "z"), Found.No_Name)
	testing.expect_value(t, shown(t, f, e), "b")
	lost := spawn(f, {})
	testing.expect_value(t, play(&f.sprites, ecs.get_write(&f.world, lost, render.Sprite_Renderer), "walk"), Found.No_Sheet)
}

@(test)
a_script_plays_a_sprites_animations_by_name :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	f.entity = spawn(f, guid(SHEET))
	context.user_ptr = f
	_, ok := script.spawn_source(&f.runtime, "=sprites", `
local e = Test.entity()
Test.report("before", Sprites.animation(e), Sprites.finished(e))
Sprites.play(e, "jump")
Test.report("playing", Sprites.animation(e), Sprites.finished(e))
Test.report("unknown", (pcall(Sprites.play, e, "run")))
Sprites.stop(e)
Sprites.set_frame(e, "c")
Test.report("frame", Sprites.animation(e))
Test.report("no frame", (pcall(Sprites.set_frame, e, "z")))
Sprites.play(e, "walk", true)
`)
	testing.expect(t, ok)
	wanted := []string{"before nil true", "playing jump false", "unknown false", "frame nil", "no frame false"}
	testing.expect_value(t, len(f.reports), len(wanted))
	for report, i in f.reports {
		if i < len(wanted) {
			testing.expect_value(t, report, wanted[i])
		}
	}
	sprite := ecs.get(&f.world, f.entity, render.Sprite_Renderer)
	testing.expect_value(t, animation_name(&f.sprites, sprite^), "walk")
	testing.expect(t, sprite.playing)
}
