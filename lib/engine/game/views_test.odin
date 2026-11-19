package game

import "core:mem/virtual"
import "core:testing"

import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// Views_Fixture is a sublevel_game with a world that has the renderer's components, and no renderer.
@(private = "file")
Views_Fixture :: struct {
	arena: virtual.Arena,
	g:     ^Game,
}

@(private = "file")
setup_views :: proc(t: ^testing.T, f: ^Views_Fixture) -> ^Game {
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	g := sublevel_game(&f.arena)
	f.g = g
	g.platform.memory_reserve = proc(size: int) -> rawptr {
		data, err := virtual.reserve(uint(size))
		return err == nil ? raw_data(data) : nil
	}
	g.platform.memory_commit = proc(ptr: rawptr, size: int) -> bool {
		return virtual.commit(ptr, uint(size)) == nil
	}
	g.platform.memory_release = proc(ptr: rawptr, size: int) {
		virtual.release(ptr, uint(size))
	}
	testing.expect(t, ecs.init(&g.world, g.platform))
	ecs.register_engine_components(&g.world.registry)
	render.register_components(&g.world.registry)
	return g
}

@(private = "file")
teardown_views :: proc(f: ^Views_Fixture) {
	ecs.destroy(&f.g.world)
	free_sublevel_game(f.g)
	virtual.arena_destroy(&f.arena)
}

@(private = "file")
spawn_camera :: proc(g: ^Game, x: f32) -> ecs.Entity {
	e := ecs.spawn(&g.world)
	ecs.add(&g.world, e, ecs.Transform{position = ecs.position_offset({}, {x, 0, 0}), rotation = 1, scale = 1})
	ecs.add(&g.world, e, render.Camera{})
	return e
}

// A scene with one Camera and no pushes describes its frame as a game with one camera always did: the camera's view at
// the window's size, with no rect, no cut and no extra views.
@(test)
one_camera_and_no_pushes_describe_the_frame_as_before :: proc(t: ^testing.T) {
	f: Views_Fixture
	g := setup_views(t, &f)
	defer teardown_views(&f)
	cam := spawn_camera(g, 4)
	shown := camera.advance(&g.views, &g.world, {})
	desc := describe_frame(g, {640, 360}, shown, nil, {})
	want, _ := render.camera_view(&g.world, cam)
	testing.expect_value(t, desc.view, want)
	testing.expect_value(t, desc.size, [2]u32{640, 360})
	testing.expect_value(t, desc.rect, Maybe(render.Target_Rect)(nil))
	testing.expect(t, !desc.cut)
	testing.expect_value(t, len(desc.extra_views), 0)
	testing.expect_value(t, camera_view(g), want)
}

// Two views side by side describe the own view in the left half of the window and an extra view in the right half, with
// the game's hooks and the second view's state.
@(test)
two_views_describe_an_own_view_and_an_extra_in_rects :: proc(t: ^testing.T) {
	f: Views_Fixture
	g := setup_views(t, &f)
	defer teardown_views(&f)
	left, right := spawn_camera(g, 0), spawn_camera(g, 100)
	camera.set_layout(&g.views, nil, camera.Preset.Side_By_Side)
	_, pushed_left := camera.push(&g.views, &g.world, 0, left, 1)
	_, pushed_right := camera.push(&g.views, &g.world, 1, right, 1)
	testing.expect(t, pushed_left && pushed_right)
	// The second view's state, made as the renderer would, without one.
	g.views.views[1].state = render.View_State{}
	shown := camera.advance(&g.views, &g.world, {})
	desc := describe_frame(g, {640, 360}, shown, nil, {})
	left_view, _ := render.camera_view(&g.world, left)
	right_view, _ := render.camera_view(&g.world, right)
	testing.expect_value(t, desc.view, left_view)
	testing.expect_value(t, desc.size, [2]u32{320, 360})
	testing.expect_value(
		t,
		desc.rect,
		Maybe(render.Target_Rect)(render.Target_Rect{target_size = {640, 360}}),
	)
	if !testing.expect_value(t, len(desc.extra_views), 1) {
		return
	}
	extra := desc.extra_views[0]
	testing.expect_value(t, extra.view, right_view)
	testing.expect_value(t, extra.size, [2]u32{320, 360})
	testing.expect_value(
		t,
		extra.rect,
		Maybe(render.Target_Rect)(render.Target_Rect{target_size = {640, 360}, origin = {320, 0}}),
	)
	testing.expect(t, extra.state == &g.views.views[1].state.?)
	testing.expect(t, extra.hooks.ui == desc.hooks.ui && extra.hooks.data == rawptr(g))
	testing.expect_value(t, extra.target, desc.target)
}

// The streaming's sources are every game view's camera, shown or not, and the claim's.
@(test)
stream_sources_hold_every_views_camera :: proc(t: ^testing.T) {
	f: Views_Fixture
	g := setup_views(t, &f)
	defer teardown_views(&f)
	a, b, overview := spawn_camera(g, 0), spawn_camera(g, 100), spawn_camera(g, 500)
	camera.set_layout(&g.views, nil, camera.Preset.Side_By_Side)
	camera.push(&g.views, &g.world, 0, a, 1)
	camera.push(&g.views, &g.world, 1, b, 1)
	camera.claim(&g.views, &g.world, overview)
	camera.advance(&g.views, &g.world, {})
	sources := make([dynamic]ecs.World_Position, g.platform.frame_allocator)
	camera.append_positions(&g.views, &g.world, &sources)
	xs: [3]bool
	for p in sources {
		x := ecs.position_sub(p, {}).x
		switch x {
		case 0:
			xs[0] = true
		case 100:
			xs[1] = true
		case 500:
			xs[2] = true
		}
	}
	testing.expect_value(t, xs, [3]bool{true, true, true})
}
