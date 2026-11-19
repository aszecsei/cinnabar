package camera

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	views:    Views,
	// With scripts: the runtime, the cameras that Test.camera gives, and what Test.report reported.
	scripts:  bool,
	runtime:  script.Runtime,
	cameras:  [4]ecs.Entity,
	reports:  [dynamic]f64,
}

// setup makes a world with the engine's and the renderer's components and no GPU. The fixture lives on the heap: the
// world is large, and the platform's address must not change after init.
@(private = "file")
setup :: proc(t: ^testing.T, scripts := false) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
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
	if scripts {
		f.scripts = true
		script.register_components(&f.world.registry)
		context.user_ptr = f
		testing.expect(
			t,
			script.init(&f.runtime, &f.platform, &f.world, nil, register_test_scripts),
		)
	}
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.views, nil)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
register_test_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.views, nil)
	script.define(r, "Test.camera", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		script.push_entity(L, f.cameras[int(luau.L_checknumber(L, 1)) - 1])
		return 1
	})
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
}

// spawn_camera makes a camera that is x meters along the x axis.
@(private = "file")
spawn_camera :: proc(f: ^Fixture, x: f64, fov: f32 = 0) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(
		&f.world,
		e,
		ecs.Transform{position = ecs.position_from_meters({x, 0, 0}), rotation = 1, scale = 1},
	)
	ecs.add(&f.world, e, render.Camera{vertical_fov = fov})
	return e
}

@(private = "file")
move :: proc(f: ^Fixture, e: ecs.Entity, x: f64) {
	ecs.get(&f.world, e, ecs.Transform).position = ecs.position_from_meters({x, 0, 0})
}

@(private = "file")
x_of :: proc(view: render.View) -> f32 {
	return ecs.position_sub(view.position, {})[0]
}

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-3
}

// expect_x checks the x of what the view shows now, and what advance shows for it.
@(private = "file")
expect_x :: proc(t: ^testing.T, f: ^Fixture, index: int, want: f32, loc := #caller_location) {
	got := x_of(view_of(&f.views, &f.world, index))
	testing.expectf(t, near(got, want), "view %d is at x %v, want %v", index, got, want, loc = loc)
}

@(private = "file")
step :: proc(f: ^Fixture, game: f32 = 0, real: f32 = 0) -> Frame_Views {
	frame := advance(&f.views, &f.world, {game, real})
	// The game draws each frame that advance gives.
	drawn(&f.views)
	return frame
}

@(test)
three_pushes_popped_out_of_order_show_the_right_camera :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b, c := spawn_camera(f, 1), spawn_camera(f, 2), spawn_camera(f, 3)
	ta, _ := push(&f.views, &f.world, 0, a, 1)
	tb, _ := push(&f.views, &f.world, 0, b, 3)
	tc, _ := push(&f.views, &f.world, 0, c, 2)

	frame := step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), b)
	testing.expect(t, near(x_of(frame.views[0].view), 2))

	// The highest one goes: the next highest shows.
	pop(&f.views, tb)
	frame = step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), c)
	testing.expect(t, near(x_of(frame.views[0].view), 3))

	// One that is not shown goes: nothing changes.
	pop(&f.views, ta)
	frame = step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), c)
	testing.expect(t, !frame.views[0].cut)

	// The last one goes: the world's first camera shows.
	pop(&f.views, tc)
	frame = step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), a)
	testing.expect(t, near(x_of(frame.views[0].view), 1))
	testing.expect(t, frame.views[0].cut)
}

@(test)
a_tie_shows_the_last_push :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 1), spawn_camera(f, 2)
	push(&f.views, &f.world, 0, a, 5)
	tb, _ := push(&f.views, &f.world, 0, b, 5)
	step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), b)

	pop(&f.views, tb)
	step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), a)
}

@(test)
a_blend_between_moving_cameras_reads_their_presented_poses :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 0), spawn_camera(f, 10)
	push(&f.views, &f.world, 0, a, 1)
	step(f)
	push(&f.views, &f.world, 0, b, 2, Blend{duration = 1})

	// The start: the blend has not moved yet, so the view is where the old camera is.
	frame := step(f)
	testing.expect(t, near(x_of(frame.views[0].view), 0))
	testing.expect(t, !frame.views[0].cut)

	// The middle: both cameras moved, and the blend is half way between where they are now.
	move(f, a, 4)
	move(f, b, 20)
	frame = step(f, 0.5, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 12))

	// The end: the blend is over, and the view is the new camera as it is.
	move(f, a, 1000)
	move(f, b, 30)
	frame = step(f, 0.5, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 30))
	_, settled := f.views.views[0].stack.shot.(Settled)
	testing.expect(t, settled)
}

@(test)
a_blend_that_starts_during_a_blend_starts_from_the_blended_pose :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b, c := spawn_camera(f, 0), spawn_camera(f, 10), spawn_camera(f, 100)
	push(&f.views, &f.world, 0, a, 1)
	step(f)
	push(&f.views, &f.world, 0, b, 2, Blend{duration = 1})
	step(f)
	frame := step(f, 0.5, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 5))

	push(&f.views, &f.world, 0, c, 3, Blend{duration = 1})
	frame = step(f)
	testing.expect(t, near(x_of(frame.views[0].view), 5))

	// The first blend's cameras no longer count: the second starts from the pose that was shown, which is frozen.
	move(f, a, 1000)
	move(f, b, 2000)
	frame = step(f, 0.5, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 52.5))
	frame = step(f, 0.5, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 100))
}

@(test)
a_blend_out_runs_when_the_chosen_entry_goes_and_a_blend_in_when_it_is_outranked :: proc(
	t: ^testing.T,
) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 0), spawn_camera(f, 10)
	push(&f.views, &f.world, 0, a, 1)
	step(f)
	// b blends in over 1 s, and out over 4 s.
	tb, _ := push(&f.views, &f.world, 0, b, 2, Blend{duration = 1}, Blend{duration = 4})
	step(f)
	step(f, 1, 0)
	expect_x(t, f, 0, 10)

	// It goes: the view leaves b over b's blend out, 4 s, so a second in it is a quarter of the way.
	pop(&f.views, tb)
	step(f)
	frame := step(f, 1, 0)
	testing.expect(t, near(x_of(frame.views[0].view), 7.5))
}

@(test)
a_pop_through_a_stale_token_does_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 1), spawn_camera(f, 2)
	old, _ := push(&f.views, &f.world, 0, a, 1)
	pop(&f.views, old)
	testing.expect(t, !is_pushed(&f.views, old))
	pop(&f.views, old)

	// The slot is used again, and the old token does not reach the entry that has it now.
	fresh, ok := push(&f.views, &f.world, 0, b, 1)
	testing.expect(t, ok)
	testing.expect_value(t, fresh.slot, old.slot)
	testing.expect(t, fresh.generation != old.generation)
	pop(&f.views, old)
	testing.expect(t, is_pushed(&f.views, fresh))
	step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), b)

	// Neither does the zero token, or a claim's token that is taken for a push's.
	pop(&f.views, {})
	claim_token, claimed_ok := claim(&f.views, &f.world, a)
	testing.expect(t, claimed_ok)
	pop(&f.views, Camera_Token(claim_token))
	testing.expect(t, is_claimed(&f.views, claim_token))
	release(&f.views, Claim_Token(fresh))
	testing.expect(t, is_pushed(&f.views, fresh))
	release(&f.views, claim_token)
	testing.expect(t, !is_claimed(&f.views, claim_token))
}

@(test)
a_despawned_camera_ends_its_entry_and_the_pusher_learns :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 1), spawn_camera(f, 2)
	owner := ecs.spawn(&f.world)
	push(&f.views, &f.world, 0, a, 1)
	token, _ := push(&f.views, &f.world, 0, b, 2, CUT, CUT, owner)
	step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), b)

	ecs.despawn(&f.world, b)
	frame := step(f)
	testing.expect(t, !is_pushed(&f.views, token))
	testing.expect_value(t, chosen_camera(&f.views, 0), a)
	testing.expect(t, near(x_of(frame.views[0].view), 1))
	list := ended(&f.views)
	testing.expect_value(t, len(list), 1)
	if len(list) == 1 {
		testing.expect_value(t, list[0].token, token)
		testing.expect_value(t, list[0].owner, owner)
		testing.expect_value(t, list[0].reason, Ended_Reason.Despawned)
		testing.expect_value(t, list[0].stack, Stack_Index(0))
	}

	// The next frame has nothing new to report.
	step(f)
	testing.expect_value(t, len(ended(&f.views)), 0)
}

@(test)
a_game_clock_blend_stops_while_paused_and_a_real_one_does_not :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	set_layout(&f.views, nil, Preset.Side_By_Side)
	a, b := spawn_camera(f, 0), spawn_camera(f, 10)
	for view in 0 ..< 2 {
		push(&f.views, &f.world, view, a, 1)
	}
	step(f)
	push(&f.views, &f.world, 0, b, 2, Blend{duration = 1, clock = .Game})
	push(&f.views, &f.world, 1, b, 2, Blend{duration = 1, clock = .Real})
	step(f)

	// Paused: game time does not go, real time does.
	step(f, 0, 0.5)
	expect_x(t, f, 0, 0)
	expect_x(t, f, 1, 5)
	step(f, 0, 0.5)
	expect_x(t, f, 0, 0)
	expect_x(t, f, 1, 10)

	step(f, 0.5, 0)
	expect_x(t, f, 0, 5)
}

@(test)
with_no_entries_a_view_shows_the_first_camera :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	// No camera at all: the default view.
	frame := step(f)
	testing.expect_value(t, frame.count, 1)
	perspective, is_perspective := frame.views[0].view.projection.(render.Perspective)
	testing.expect(t, is_perspective)
	testing.expect_value(t, perspective.vertical_fov, f32(render.DEFAULT_VERTICAL_FOV))
	testing.expect_value(t, chosen_camera(&f.views, 0), ecs.Entity(0))

	// A scene's camera shows with no push, and keeps showing while it lives.
	a := spawn_camera(f, 7, 1.2)
	frame = step(f)
	testing.expect(t, near(x_of(frame.views[0].view), 7))
	testing.expect_value(t, frame.views[0].rect, FULL)
	testing.expect(t, !frame.views[0].cut)
	spawn_camera(f, 9)
	step(f)
	testing.expect_value(t, chosen_camera(&f.views, 0), a)

	positions: [dynamic]ecs.World_Position
	defer delete(positions)
	append_positions(&f.views, &f.world, &positions)
	testing.expect_value(t, len(positions), 1)
}

@(test)
a_claim_shows_one_full_view_and_its_release_gives_the_layout_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	set_layout(&f.views, nil, Preset.Side_By_Side)
	a, b, c := spawn_camera(f, 1), spawn_camera(f, 2), spawn_camera(f, 3)
	push(&f.views, &f.world, 0, a, 1)
	push(&f.views, &f.world, 1, b, 1)

	// The first frame is not a cut.
	frame := step(f)
	testing.expect_value(t, frame.count, 2)
	testing.expect(t, !frame.views[0].cut && !frame.views[1].cut)
	testing.expect_value(t, frame.views[1].rect, Rect{{0.5, 0}, {1, 1}})

	token, _ := claim(&f.views, &f.world, c)
	frame = step(f)
	testing.expect_value(t, frame.count, 1)
	testing.expect_value(t, frame.views[0].rect, FULL)
	testing.expect(t, near(x_of(frame.views[0].view), 3))
	testing.expect(t, frame.views[0].cut)
	testing.expect(t, frame.claimed && claimed(&f.views))
	expect_x(t, f, 0, 3)
	testing.expect_value(t, chosen_camera(&f.views, 0), c)
	testing.expect_value(t, chosen_camera(&f.views, 1), b)

	frame = step(f)
	testing.expect(t, !frame.views[0].cut)

	release(&f.views, token)
	frame = step(f)
	testing.expect_value(t, frame.count, 2)
	testing.expect(t, frame.views[0].cut && frame.views[1].cut)
	testing.expect(t, near(x_of(frame.views[0].view), 1))
	testing.expect(t, near(x_of(frame.views[1].view), 2))
	testing.expect(t, !claimed(&f.views))

	frame = step(f)
	testing.expect(t, !frame.views[0].cut && !frame.views[1].cut)
}

@(test)
a_change_of_layout_is_a_cut :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	spawn_camera(f, 1)
	frame := step(f)
	testing.expect(t, !frame.views[0].cut)
	set_layout(&f.views, nil, Preset.Over_Under)
	frame = step(f)
	testing.expect_value(t, frame.count, 2)
	testing.expect(t, frame.views[0].cut && frame.views[1].cut)

	// A custom layout's count is 1 to MAX_VIEWS.
	set_layout(&f.views, nil, Custom{rects = {0 = FULL}, count = 0})
	testing.expect_value(t, view_count(&f.views), 1)
	set_layout(&f.views, nil, Custom{count = 200})
	testing.expect_value(t, view_count(&f.views), MAX_VIEWS)
}

@(test)
a_push_that_cannot_work_fails :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a := spawn_camera(f, 1)
	plain := ecs.spawn(&f.world)
	_, ok := push(&f.views, &f.world, MAX_VIEWS, a, 1)
	testing.expect(t, !ok)
	_, ok = push(&f.views, &f.world, -1, a, 1)
	testing.expect(t, !ok)
	_, ok = push(&f.views, &f.world, 0, plain, 1)
	testing.expect(t, !ok)
	_, ok = push(&f.views, &f.world, 0, 0, 1)
	testing.expect(t, !ok)
}

@(test)
every_views_camera_has_a_position_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	set_layout(&f.views, nil, Preset.Side_By_Side)
	a, b, c := spawn_camera(f, 1), spawn_camera(f, 2), spawn_camera(f, 3)
	push(&f.views, &f.world, 0, a, 1)
	push(&f.views, &f.world, 1, b, 1)
	step(f)
	positions: [dynamic]ecs.World_Position
	defer delete(positions)
	// The third view shows the fallback, which is a's, and is not counted twice.
	append_positions(&f.views, &f.world, &positions)
	testing.expect_value(t, len(positions), 2)

	claim(&f.views, &f.world, c)
	step(f)
	clear(&positions)
	append_positions(&f.views, &f.world, &positions)
	testing.expect_value(t, len(positions), 3)
}

@(test)
pixel_rects_of_the_presets_tile_the_window :: proc(t: ^testing.T) {
	sizes := [?][2]u32{{1, 1}, {7, 5}, {1001, 667}, {1920, 1080}, {3, 9}}
	for preset in Preset {
		rects, count := preset_rects(preset)
		for size in sizes {
			covered := make([]u8, int(size.x * size.y), context.temp_allocator)
			for rect in rects[:count] {
				origin, extent := pixel_rect(rect, size)
				for y in origin.y ..< origin.y + extent.y {
					for x in origin.x ..< origin.x + extent.x {
						covered[int(y * size.x + x)] += 1
					}
				}
			}
			exactly_once := true
			for n in covered {
				exactly_once &&= n == 1
			}
			testing.expectf(t, exactly_once, "%v tiles %v exactly once", preset, size)
		}
	}
	rects, count := preset_rects(.Grid_4)
	testing.expect_value(t, count, 4)
	origin, extent := pixel_rect(rects[3], {7, 5})
	testing.expect_value(t, origin, [2]u32{4, 3})
	testing.expect_value(t, extent, [2]u32{3, 2})
}

@(test)
blend_views_blends_the_lens_with_the_pose :: proc(t: ^testing.T) {
	a := render.View {
		position        = ecs.position_from_meters({0, 0, 0}),
		rotation        = 1,
		projection      = render.Perspective{1, 0.1},
		view_model_fov  = 0.5,
		view_model_near = 0,
	}
	b := render.View {
		position        = ecs.position_from_meters({10, 0, 0}),
		rotation        = quaternion(
			w = math.cos(f32(math.PI) / 4),
			x = 0,
			y = math.sin(f32(math.PI) / 4),
			z = 0,
		),
		projection      = render.Perspective{2, 0.3},
		view_model_fov  = 0.9,
		view_model_near = 0,
	}
	mid := blend_views(a, b, 0.5)
	p := mid.projection.(render.Perspective)
	testing.expect(t, near(p.vertical_fov, 1.5))
	testing.expect(t, near(p.near, 0.2))
	testing.expect(t, near(mid.view_model_fov, 0.7))
	testing.expect_value(t, mid.view_model_near, f32(0))
	testing.expect(t, near(x_of(mid), 5))
	// A rotation of 90 degrees about y, half way: 45 degrees.
	want := linalg.quaternion_angle_axis_f32(math.PI / 4, {0, 1, 0})
	testing.expect(t, abs(linalg.dot(mid.rotation, want)) > 0.9999)

	// The ends are the views themselves.
	testing.expect_value(t, blend_views(a, b, 0), a)
	testing.expect_value(t, blend_views(a, b, 1), b)

	// A view model's 0 is the view's own, so it blends from that and not through 0.
	a.view_model_fov = 0
	mid = blend_views(a, b, 0.5)
	testing.expect(t, near(mid.view_model_fov, 0.95))
}

@(test)
blend_views_takes_the_second_projection_when_the_kinds_differ :: proc(t: ^testing.T) {
	a := render.perspective_view(1, 1, 0.1)
	b := render.orthographic_view(1, 8, 0.2, 50)
	mid := blend_views(a, b, 0.25)
	testing.expect_value(t, mid.projection, render.Projection(render.Orthographic{8, 0.2, 50}))
	mid = blend_views(b, a, 0.75)
	testing.expect_value(t, mid.projection, render.Projection(render.Perspective{1, 0.1}))

	c := render.orthographic_view(1, 4, 0.0, 10)
	both := blend_views(b, c, 0.5).projection.(render.Orthographic)
	testing.expect(t, near(both.height, 6) && near(both.near, 0.1) && near(both.far, 30))
}

@(test)
curves_start_at_0_and_end_at_1 :: proc(t: ^testing.T) {
	for curve in Curve {
		testing.expect_value(t, ease(curve, 0), f32(0))
		testing.expect_value(t, ease(curve, 1), f32(1))
		testing.expect_value(t, ease(curve, -3), f32(0))
		testing.expect_value(t, ease(curve, 3), f32(1))
	}
	testing.expect(t, ease(.Ease_In, 0.5) < 0.5)
	testing.expect(t, ease(.Ease_Out, 0.5) > 0.5)
	testing.expect_value(t, ease(.Smooth, 0.5), f32(0.5))
}

@(test)
a_script_pushes_pops_and_claims_through_tokens :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(f)
	for i in 0 ..< 3 {
		f.cameras[i] = spawn_camera(f, f64(i + 1))
	}
	f.cameras[3] = ecs.spawn(&f.world)
	context.user_ptr = f
	run :: proc(t: ^testing.T, f: ^Fixture, source: string, loc := #caller_location) {
		_, ok := script.spawn_source(&f.runtime, "=camera_test", source)
		testing.expect(t, ok, "the script runs", loc = loc)
	}

	run(
		t,
		f,
		`
local function report(value: boolean) Test.report(if value then 1 else 0) end
local a = Views.push(1, Test.camera(1), 1)
local b = Views.push(1, Test.camera(2), 5, { duration = 1, curve = "smooth", clock = "real", out = 0.5 })
report(Views.is_pushed(a) and Views.is_pushed(b))
Views.pop(a)
report(Views.is_pushed(a))
report(Views.is_pushed(b))
Views.pop(a)
Test.report(Views.count())
Views.set_layout("side_by_side")
Test.report(Views.count())

report(not pcall(Views.push, 1, Test.camera(4), 1))
report(not pcall(Views.push, 0, Test.camera(1), 1))
report(not pcall(Views.push, 6, Test.camera(1), 1))
report(not pcall(Views.push, 1, Test.camera(1), 1, { duration = 1, curve = "bouncy" }))
report(not pcall(Views.set_layout, "triple"))

local claim = Views.claim(Test.camera(3), 2)
report(Views.is_claimed(claim))
report(Views.is_pushed(claim))
Views.release(claim)
report(Views.is_claimed(claim))
`,
	)
	expect_reports(t, f, {1, 0, 1, 1, 2, 1, 1, 1, 1, 1, 1, 0, 0})

	// The camera that b chose shows, after a frame.
	step(f)
	run(
		t,
		f,
		`
Test.report(if Views.camera(1) == Test.camera(2) then 1 else 0)
Test.report(if Views.camera(2) == Test.camera(1) then 1 else 0)
`,
	)
	expect_reports(t, f, {1, 1})
}

@(private = "file")
expect_reports :: proc(t: ^testing.T, f: ^Fixture, want: []f64, loc := #caller_location) {
	same := len(f.reports) == len(want)
	for value, i in want {
		same = same && i < len(f.reports) && f.reports[i] == value
	}
	testing.expectf(t, same, "reports %v, want %v", f.reports[:], want, loc = loc)
	clear(&f.reports)
}

// A claim blends in from what the first view shows, a pushed camera rather than the world's first, and its release
// blends back to it full screen; the layout comes back when the blend out ends.
@(test)
a_claim_blends_in_from_the_first_view_and_its_release_blends_back :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	spawn_camera(f, 0)
	a, b, c := spawn_camera(f, 10), spawn_camera(f, 20), spawn_camera(f, 30)
	set_layout(&f.views, nil, Preset.Side_By_Side)
	push(&f.views, &f.world, 0, a, 1)
	push(&f.views, &f.world, 1, b, 1)
	step(f)

	blend := Blend {
		duration = 1,
		clock    = .Real,
	}
	token, _ := claim(&f.views, &f.world, c, 0, blend, blend)
	frame := step(f, 0, 0.5)
	testing.expect_value(t, frame.count, 1)
	testing.expectf(
		t,
		near(x_of(frame.views[0].view), 20),
		"halfway in is at x %v",
		x_of(frame.views[0].view),
	)
	frame = step(f, 0, 0.5)
	testing.expect(t, near(x_of(frame.views[0].view), 30))

	release(&f.views, token)
	frame = step(f, 0, 0.5)
	// Still one full view, halfway back to the first view's camera.
	testing.expect_value(t, frame.count, 1)
	testing.expect(t, !frame.views[0].cut)
	testing.expectf(
		t,
		near(x_of(frame.views[0].view), 20),
		"halfway out is at x %v",
		x_of(frame.views[0].view),
	)
	frame = step(f, 0, 0.5)
	// The blend ended: the layout is back, with a cut for the change of rects.
	testing.expect_value(t, frame.count, 2)
	testing.expect(t, frame.views[0].cut && frame.views[1].cut)
	testing.expect(t, near(x_of(frame.views[0].view), 10))
	testing.expect(t, near(x_of(frame.views[1].view), 20))
}

// A cut stays pending until a frame that carries it is drawn: a frame that is not drawn, as with a minimized window,
// passes it on to the next.
@(test)
a_cut_waits_for_a_drawn_frame :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b := spawn_camera(f, 1), spawn_camera(f, 2)
	push(&f.views, &f.world, 0, a, 1)
	step(f)
	push(&f.views, &f.world, 0, b, 2)
	// Not drawn.
	frame := advance(&f.views, &f.world, {})
	testing.expect(t, frame.views[0].cut)
	frame = advance(&f.views, &f.world, {})
	testing.expect(t, frame.views[0].cut)
	drawn(&f.views)
	frame = step(f)
	testing.expect(t, !frame.views[0].cut)
}

// A new world, as the editor's scene replaces the game's, starts the views again: one view, no pushes or claims, the
// old tokens stale, and a cut in the first frame. The same count of replacements changes nothing.
@(test)
a_new_world_starts_the_views_again :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	a, b, c := spawn_camera(f, 1), spawn_camera(f, 2), spawn_camera(f, 3)
	set_layout(&f.views, nil, Preset.Side_By_Side)
	pushed, _ := push(&f.views, &f.world, 0, b, 1)
	claimed_token, _ := claim(&f.views, &f.world, c, 0, {duration = 5}, {duration = 5})
	step(f, 1)
	follow_world(&f.views, nil, 0)
	testing.expect(t, claimed(&f.views))
	follow_world(&f.views, nil, 1)
	testing.expect(
		t,
		!claimed(&f.views) && !is_pushed(&f.views, pushed) && !is_claimed(&f.views, claimed_token),
	)
	testing.expect_value(t, view_count(&f.views), 1)
	frame := step(f)
	testing.expect_value(t, frame.count, 1)
	testing.expect(t, frame.views[0].cut)
	testing.expect(t, near(x_of(frame.views[0].view), x_of(view_of(&f.views, &f.world, 0))))
	testing.expect_value(t, chosen_camera(&f.views, 0), a)
	frame = step(f)
	testing.expect(t, !frame.views[0].cut)
	follow_world(&f.views, nil, 1)
	testing.expect(t, !step(f).views[0].cut)
}
