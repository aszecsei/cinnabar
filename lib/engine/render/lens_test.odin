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
	ecs.add(
		w,
		e,
		ecs.Transform{position = ecs.position_offset({}, position), rotation = 1, scale = 1},
	)
	return e
}

// A lens gives the field of view 2 × atan(sensor_height / (2 × focal_length)), in the view, through camera_vertical_fov
// and in Camera.vertical_fov, which the "cinematic lens" system writes.
@(test)
the_vertical_fov_is_twice_the_atan_of_half_the_sensor_over_the_focal_length :: proc(
	t: ^testing.T,
) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {})
	ecs.add(w, e, Camera{vertical_fov = 1})
	ecs.add(w, e, Cinematic_Camera{})
	Lens_Case :: struct {
		focal, sensor: f32,
	}
	for c in ([]Lens_Case{{18, 24}, {35, 24}, {50, 18.66}, {85, 24}, {200, 13.365}}) {
		ecs.get(w, e, Cinematic_Camera)^ = {
			focal_length  = c.focal,
			sensor_height = c.sensor,
		}
		want := 2 * math.atan(c.sensor / (2 * c.focal))
		testing.expectf(
			t,
			abs(cinematic_vertical_fov(ecs.get(w, e, Cinematic_Camera)^) - want) < 1e-6,
			"%v",
			c,
		)
		testing.expectf(t, abs(camera_vertical_fov(w, e) - want) < 1e-6, "%v", c)
		view, ok := camera_view(w, e)
		testing.expect(t, ok)
		testing.expectf(t, abs(view.projection.(Perspective).vertical_fov - want) < 1e-6, "%v", c)
		set_cinematic_fov(w)
		testing.expectf(t, abs(ecs.get(w, e, Camera).vertical_fov - want) < 1e-6, "%v", c)
	}

	// Zeros take a 35 mm lens on a full-frame sensor.
	ecs.get(w, e, Cinematic_Camera)^ = {}
	testing.expect_value(
		t,
		camera_vertical_fov(w, e),
		2 * math.atan(f32(DEFAULT_SENSOR_HEIGHT) / (2 * DEFAULT_FOCAL_LENGTH)),
	)

	// Without a Cinematic_Camera, the Camera's own field of view stands, and the system leaves it.
	ecs.remove(w, e, Cinematic_Camera)
	ecs.get(w, e, Camera).vertical_fov = 1
	set_cinematic_fov(w)
	testing.expect_value(t, ecs.get(w, e, Camera).vertical_fov, 1)
	view, _ := camera_view(w, e)
	testing.expect_value(t, view.projection.(Perspective).vertical_fov, 1)
	testing.expect_value(t, view.lens, Lens{})

	// The lens's focal length is the field of view's on the sensor again.
	ecs.add(w, e, Cinematic_Camera{focal_length = 85, sensor_height = 24, aperture = 2})
	view, _ = camera_view(w, e)
	testing.expect(t, abs(lens_focal_length(view) - 85) < 1e-3)
}

@(test)
a_camera_without_an_aperture_has_no_lens :: proc(t: ^testing.T) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {})
	ecs.add(w, e, Camera{})
	ecs.add(w, e, Cinematic_Camera{focal_length = 50, focus_distance = 3})
	view, _ := camera_view(w, e)
	testing.expect_value(t, view.lens, Lens{})
	testing.expect_value(t, lens_focal_length(view), 0)

	ecs.get(w, e, Cinematic_Camera).aperture = 2.8
	view, _ = camera_view(w, e)
	testing.expect_value(
		t,
		view.lens,
		Lens{sensor_height = DEFAULT_SENSOR_HEIGHT, aperture = 2.8, focus_distance = 3},
	)
	ecs.get(w, e, Cinematic_Camera).focus_distance = 0
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens.focus_distance, DEFAULT_FOCUS_DISTANCE)

	// An orthographic camera has no lens.
	ecs.get(w, e, Camera).projection = .Orthographic
	view, _ = camera_view(w, e)
	testing.expect_value(t, view.lens, Lens{})
}

@(test)
a_focus_entity_sets_the_focus_by_its_distance_along_the_axis :: proc(t: ^testing.T) {
	f: Lens_Fixture
	w := lens_setup(t, &f)
	defer lens_teardown(&f)
	e := spawn_at(w, {0, 0, 1})
	target := spawn_at(w, {3, 0, 5})
	ecs.add(w, e, Camera{})
	ecs.add(w, e, Cinematic_Camera{aperture = 2, focus_distance = 7, focus = target})
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

// The circle of confusion is 0 on the focus plane, grows with the distance from it, negative in front and positive
// behind, toward the lens's opening at infinity, and grows with the opening and the focal length.
@(test)
the_circle_of_confusion_grows_with_the_distance_from_the_focus :: proc(t: ^testing.T) {
	view := perspective_view(1, 2 * math.atan(f32(24) / (2 * 50)), 0.05)
	view.lens = {
		sensor_height  = 24,
		aperture       = 2,
		focus_distance = 5,
	}
	lens, ok := dof_lens(view, 1080, 1)
	testing.expect(t, ok)
	testing.expect_value(t, circle_of_confusion(lens, 5), 0)
	near_1, near_2 := circle_of_confusion(lens, 4), circle_of_confusion(lens, 2)
	far_1, far_2 := circle_of_confusion(lens, 7), circle_of_confusion(lens, 50)
	testing.expect(t, near_2 < near_1 && near_1 < 0)
	testing.expect(t, far_2 > far_1 && far_1 > 0)
	// At infinity the circle is the opening's image on the sensor: A × f / (s - f) of 24 mm, over 1080 pixels.
	f := f32(0.05)
	want := f / 2 * f / (5 - f) / 0.024 * 1080
	testing.expect(t, abs(circle_of_confusion(lens, 1e9) - want) < 1e-2)

	// A wider opening and a scale blur more.
	view.lens.aperture = 1
	wide, _ := dof_lens(view, 1080, 1)
	testing.expect(t, abs(circle_of_confusion(wide, 50) - 2 * far_2) < 1e-3)
	scaled, _ := dof_lens(view, 1080, 0.5)
	testing.expect(t, abs(circle_of_confusion(scaled, 50) - far_2) < 1e-3)

	// A focus at the lens, or behind the camera, stays in front of the lens, so the circle stays finite.
	for focus in ([]f32{0.05, -3}) {
		view.lens.focus_distance = focus
		clamped, _ := dof_lens(view, 1080, 1)
		testing.expect(t, clamped.focus >= 2 * f)
		c := circle_of_confusion(clamped, 10)
		testing.expectf(t, c > 0 && c < 1e6, "focus %v gives %v", focus, c)
	}

	// No aperture, or an orthographic view, has none.
	view.lens.aperture = 0
	_, ok = dof_lens(view, 1080, 1)
	testing.expect(t, !ok)
	_, ok = dof_lens(orthographic_view(1, 10, 0.1, 100), 1080, 1)
	testing.expect(t, !ok)
}
