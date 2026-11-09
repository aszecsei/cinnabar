package editor

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/volume"

@(private = "file")
Helper_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	editor:   Editor,
	lines:    debug.Draw,
}

@(private = "file")
helper_setup :: proc(t: ^testing.T) -> ^Helper_Fixture {
	f := new(Helper_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
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
	volume.register_components(&f.world.registry)
	render.register_components(&f.world.registry)
	init(&f.editor, &f.platform, nil)
	debug.init(&f.lines, runtime.heap_allocator())
	// Linked, as an editor's first poll makes it, with a scene view open, whose settings choose the helpers.
	f.editor.session.connection = 1
	f.editor.session.view.viewports[0].open = Viewport_Open {
		kind = .Scene,
		size = {64, 64},
	}
	return f
}

@(private = "file")
helper_teardown :: proc(f: ^Helper_Fixture) {
	debug.destroy(&f.lines)
	destroy(&f.editor)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
spawn_with :: proc(f: ^Helper_Fixture, component: $T) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.TRANSFORM_IDENTITY)
	ecs.add(&f.world, e, component)
	return e
}

// line_count draws the helpers and counts their lines.
@(private = "file")
line_count :: proc(f: ^Helper_Fixture) -> int {
	debug.end_frame(&f.lines)
	draw_helpers(&f.editor, &f.world, &f.lines)
	return len(debug.frame_lines(&f.lines))
}

@(test)
helpers_draw_the_shapes_of_the_selection_or_of_everything :: proc(t: ^testing.T) {
	when !debug.DEBUG_DRAW {
		return
	}
	f := helper_setup(t)
	defer helper_teardown(f)
	spot := spawn_with(f, render.Spot_Light{intensity = 1, inner_angle = 0.2})
	quad := spawn_with(f, render.Quad_Light{intensity = 1})
	box := spawn_with(f, volume.Volume{shape = .Box, blend_distance = 1})
	spawn_with(f, volume.Volume{shape = .Global})

	// Without a selection, the default draws nothing; with None, nothing draws even for the selection.
	testing.expect_value(t, line_count(f), 0)
	f.editor.session.view.viewports[0].settings.helpers = .Selected
	append(&f.editor.session.view.selection, quad)
	// A quad's four edges and its normal's arrow.
	quad_lines := line_count(f)
	testing.expect(t, quad_lines > 4)

	clear(&f.editor.session.view.selection)
	append(&f.editor.session.view.selection, box)
	// A box of 12 edges, and its blend's.
	testing.expect_value(t, line_count(f), 24)

	// All: the spot light's cones, the quad and the box too. The global volume has no shape.
	f.editor.session.view.viewports[0].settings.helpers = .All
	all := line_count(f)
	testing.expect(t, all > 24 + quad_lines)
	// A hidden entity has none.
	append(&f.editor.session.view.hidden, spot)
	testing.expect(t, line_count(f) < all)
	f.editor.session.view.viewports[0].settings.helpers = link.Helper_Mode.None
	testing.expect_value(t, line_count(f), 0)
}

// The shapes are the frame's debug lines, so the open scene view with the lowest number chooses them for all: a closed
// view, the Game view and a higher number choose nothing.
@(test)
the_helpers_take_the_mode_of_the_lowest_open_scene_view :: proc(t: ^testing.T) {
	when !debug.DEBUG_DRAW {
		return
	}
	f := helper_setup(t)
	defer helper_teardown(f)
	spawn_with(f, render.Quad_Light{intensity = 1})
	viewports := &f.editor.session.view.viewports
	// Viewport 0 is open as a scene view with no helpers, viewport 1 is the Game view, and 2 and 3 are scene views.
	viewports[0].settings.helpers = .None
	viewports[1].open = Viewport_Open {
		kind = .Game,
	}
	viewports[1].settings.helpers = .All
	viewports[2].open = Viewport_Open {
		kind = .Scene,
	}
	viewports[2].settings.helpers = .All
	viewports[3].open = Viewport_Open {
		kind = .Scene,
	}
	viewports[3].settings.helpers = .Selected
	testing.expect_value(t, line_count(f), 0)

	// Without viewport 0, the next scene view chooses; the Game view never does.
	viewports[0].open = nil
	all := line_count(f)
	testing.expect(t, all > 0)
	viewports[2].open = nil
	testing.expect_value(t, line_count(f), 0)
	// The viewport is open only as a Game view, or none: no shapes.
	viewports[3].open = nil
	testing.expect_value(t, line_count(f), 0)
	// A viewport that is closed keeps its settings, which an open one takes again.
	viewports[2].open = Viewport_Open {
		kind = .Scene,
	}
	testing.expect_value(t, line_count(f), all)
}

// A reflection probe draws its influence box, the fade inside it with a blend, and its projection box with box
// projection.
@(test)
a_reflection_probe_draws_its_boxes :: proc(t: ^testing.T) {
	when !debug.DEBUG_DRAW {
		return
	}
	f := helper_setup(t)
	defer helper_teardown(f)
	probe := spawn_with(f, render.Reflection_Probe{extent = {2, 1, 3}})
	f.editor.session.view.viewports[0].settings.helpers = .All
	testing.expect_value(t, line_count(f), 12)
	ecs.get(&f.world, probe, render.Reflection_Probe).blend_distance = 0.5
	testing.expect_value(t, line_count(f), 24)
	ecs.get(&f.world, probe, render.Reflection_Probe).box_projection = true
	// Not selected, the three boxes are grey; with Selected, only the selection has them.
	testing.expect_value(t, line_count(f), 36)
	f.editor.session.view.viewports[0].settings.helpers = .Selected
	testing.expect_value(t, line_count(f), 0)
	append(&f.editor.session.view.selection, probe)
	testing.expect_value(t, line_count(f), 36)
}

@(test)
icons_mark_lights_volumes_and_cameras :: proc(t: ^testing.T) {
	f := helper_setup(t)
	defer helper_teardown(f)
	lamp := spawn_with(f, render.Point_Light{color = {1, 0.5, 0}, intensity = 1})
	sun := spawn_with(f, render.Directional_Light{intensity = 1})
	spawn_with(f, volume.Volume{})
	spawn_with(f, render.Camera{})
	// A plain entity has no icon.
	plain := ecs.spawn(&f.world)
	ecs.add(&f.world, plain, ecs.TRANSFORM_IDENTITY)

	icons := icon_instances(&f.world, {}, context.temp_allocator)
	testing.expect_value(t, len(icons), 4)
	testing.expect_value(t, icons[0].entity, lamp)
	testing.expect_value(t, icons[0].kind, Icon_Kind.Point_Light)
	testing.expect_value(t, icons[0].color, [3]f32{1, 0.5, 0})
	// A color of 0 is white.
	testing.expect_value(t, icons[1].color, [3]f32{1, 1, 1})

	append(&f.editor.session.view.hidden, sun)
	icons = icon_instances(&f.world, visibility(&f.editor, &f.world), context.temp_allocator)
	testing.expect_value(t, len(icons), 3)
	for icon in icons {
		testing.expect(t, icon.entity != sun)
	}

	// A reflection probe's icon has its cube, once captured, and none before or without a renderer.
	probe := spawn_with(f, render.Reflection_Probe{})
	icons = icon_instances(&f.world, {}, context.temp_allocator)
	testing.expect_value(t, icons[len(icons) - 1].kind, Icon_Kind.Reflection_Probe)
	testing.expect_value(t, icons[len(icons) - 1].cube, -1)
	renderer := new(render.Renderer)
	defer free(renderer)
	renderer.reflection_probes.params.probes = 1
	renderer.reflection_probes.slots[0] = {used = true, entity = probe}
	icons = icon_instances(&f.world, {}, context.temp_allocator, renderer)
	testing.expect_value(t, icons[len(icons) - 1].cube, -1)
	renderer.reflection_probes.slots[0].cube = render.Reflection_Probe_Cube{index = 1}
	icons = icon_instances(&f.world, {}, context.temp_allocator, renderer)
	testing.expect_value(t, icons[len(icons) - 1].entity, probe)
	testing.expect_value(t, icons[len(icons) - 1].cube, 1)
}

@(test)
a_pick_covers_the_scenes_pixels_under_it :: proc(t: ^testing.T) {
	frame := Viewport_Frame{size = {640, 360}, output_size = {1280, 720}}
	// A click at a pixel picks the scene's pixel under it.
	testing.expect_value(t, scale_pick({id = 3, x = 101, y = 51, width = 1, height = 1}, frame), link.Pick_Request{id = 3, x = 50, y = 25, width = 1, height = 1})
	// A box covers every scene pixel that it touches.
	testing.expect_value(t, scale_pick({x = 101, y = 50, width = 4, height = 2}, frame), link.Pick_Request{x = 50, y = 25, width = 3, height = 1})
	// At the frame's size, the pick is as it was.
	same := Viewport_Frame{size = {1280, 720}, output_size = {1280, 720}}
	testing.expect_value(t, scale_pick({x = 7, y = 9, width = 1, height = 1}, same), link.Pick_Request{x = 7, y = 9, width = 1, height = 1})
}
