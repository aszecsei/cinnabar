package render

import "core:math"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"

@(private = "file")
Lens_Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	world:    ^ecs.World,
}

@(private = "file")
lens_setup :: proc(t: ^testing.T, f: ^Lens_Fixture) -> ^ecs.World {
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	f.platform = core.Platform_API {
		frame_allocator = virtual.arena_allocator(&f.arena),
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
	f.world = new(ecs.World)
	testing.expect(t, ecs.init(f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	return f.world
}

@(private = "file")
lens_teardown :: proc(f: ^Lens_Fixture) {
	ecs.destroy(f.world)
	free(f.world)
	virtual.arena_destroy(&f.arena)
}

@(private = "file")
spawn_at :: proc(w: ^ecs.World, position: [3]f32) -> ecs.Entity {
	e := ecs.spawn(w)
	ecs.add(w, e, ecs.Transform{position = ecs.position_offset({}, position), rotation = 1, scale = 1})
	return e
}

@(test)
a_focal_length_and_a_sensor_give_the_field_of_view :: proc(t: ^testing.T) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {})
	ecs.add(w, e, Camera{vertical_fov = 1, focal_length = 35, sensor_height = 15.6})
	view, ok := camera_view(w, e)
	testing.expect(t, ok)
	want := 2 * math.atan(f32(15.6) / (2 * 35))
	testing.expect_value(t, view.projection.(Perspective).vertical_fov, want)

	// A focal length alone is on a full-frame sensor, and without one vertical_fov stands.
	ecs.get(w, e, Camera)^ = {vertical_fov = 1, focal_length = 50}
	view, _ = camera_view(w, e)
	testing.expect_value(
		t,
		view.projection.(Perspective).vertical_fov,
		2 * math.atan(f32(DEFAULT_SENSOR_HEIGHT) / (2 * 50)),
	)
	ecs.get(w, e, Camera)^ = {vertical_fov = 1}
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.projection.(Perspective).vertical_fov, 1)

	// The lens's focal length is the field of view's on the sensor again.
	ecs.get(w, e, Camera)^ = {focal_length = 85, sensor_height = 24, aperture = 2}
	view, _ = camera_view(w, e)
	testing.expect(t, abs(lens_focal_length(view) - 85) < 1e-3)
}

@(test)
a_camera_without_an_aperture_has_no_lens :: proc(t: ^testing.T) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {})
	ecs.add(w, e, Camera{focal_length = 50, focus_distance = 3})
	view, _ := camera_view(w, e)
	testing.expect_value(t, view.lens, Lens{})
	testing.expect_value(t, lens_focal_length(view), 0)

	ecs.get(w, e, Camera).aperture = 2.8
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens, Lens{sensor_height = DEFAULT_SENSOR_HEIGHT, aperture = 2.8, focus_distance = 3})
	ecs.get(w, e, Camera).focus_distance = 0
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens.focus_distance, DEFAULT_FOCUS_DISTANCE)
}

@(test)
a_focus_entity_sets_the_focus_by_its_distance_along_the_axis :: proc(t: ^testing.T) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {0, 0, 1})
	target := spawn_at(w, {3, 0, 5})
	ecs.add(w, e, Camera{aperture = 2, focus_distance = 7, focus = target})
	view, _ := camera_view(w, e)
	// The camera looks down +z: 4 m ahead, whatever the target's x.
	testing.expect_value(t, view.lens.focus_distance, 4)

	// A target behind the camera gives a distance that is not ahead; the circle of confusion clamps it (see
	// circle_of_confusion). A dead target gives focus_distance back.
	ecs.get(w, target, ecs.Transform).position = ecs.position_offset({}, {0, 0, -2})
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens.focus_distance, -3)
	ecs.despawn(w, target)
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens.focus_distance, 7)
}
