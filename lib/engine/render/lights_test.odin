package render

import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

@(test)
clusters_slice_depth_exponentially :: proc(t: ^testing.T) {
	near: f32 = 0.1
	testing.expect_value(t, cluster_slice(near, near), 0)
	// Each slice's start, near * (far / near)^(k / slices), is in slice k.
	for k in 0 ..< CLUSTER_SLICES {
		depth := near * math.pow(f32(CLUSTER_FAR) / near, (f32(k) + 0.5) / CLUSTER_SLICES)
		testing.expect_value(t, cluster_slice(depth, near), k)
	}
	// Beyond CLUSTER_FAR, the last slice reaches on.
	testing.expect_value(t, cluster_slice(1e5, near), CLUSTER_SLICES - 1)
	columns, rows := cluster_grid({1920, 1080})
	testing.expect_value(t, columns, 30)
	testing.expect_value(t, rows, 17)
}

@(test)
cascades_split_between_even_and_exponential :: proc(t: ^testing.T) {
	splits := cascade_splits(0.1)
	for i in 1 ..< SHADOW_CASCADES {
		testing.expect(t, splits[i] > splits[i - 1])
	}
	testing.expect(t, abs(splits[SHADOW_CASCADES - 1] - SHADOW_DISTANCE) < 1e-3)
	// The first cascade is nearer than an even split's, so near shadows get more texels.
	testing.expect(t, splits[0] < SHADOW_DISTANCE / SHADOW_CASCADES)
	// A volume's Shadows set the reach and the split: evenly, the cascades are a quarter each.
	even := cascade_splits(0.1, 40, 1e-6)
	testing.expect(t, abs(even[0] - (0.1 + 39.9 / 4)) < 1e-3 && abs(even[SHADOW_CASCADES - 1] - 40) < 1e-3)
}

@(private = "file")
Light_Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	renderer: ^Renderer,
	frame:    Frame,
}

@(private = "file")
light_setup :: proc(t: ^testing.T) -> ^Light_Fixture {
	f := new(Light_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	testing.expect(t, jobs.init(2))
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.arena),
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
		// The shadow views' upload, which the test does not read.
		gpu_upload = proc(size, align: int) -> (gpu.Upload, bool) {
			return {data = make([]byte, size, context.temp_allocator)}, true
		},
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	f.renderer = new(Renderer)
	f.renderer.platform = &f.platform
	lights_register(&f.renderer.lights, &f.world)
	view := View{rotation = 1, vertical_fov = 1, near = 0.1}
	f.frame = {renderer = f.renderer, view = view, size = {64, 32}, view_projection = view_projection(view, 2)}
	return f
}

@(private = "file")
light_teardown :: proc(f: ^Light_Fixture) {
	free(f.renderer)
	ecs.destroy(&f.world)
	jobs.shutdown()
	virtual.arena_destroy(&f.arena)
	free(f)
}

@(private = "file")
spawn_light :: proc(w: ^ecs.World, position: [3]f32, rotation: quaternion128, light: $T) -> ecs.Entity {
	e := ecs.spawn(w)
	ecs.add(w, e, ecs.Transform{position = ecs.position_offset({}, position), rotation = rotation, scale = 1})
	ecs.add(w, e, light)
	return e
}

@(test)
lights_take_their_shadows_in_order :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	down := linalg.quaternion_angle_axis_f32(math.PI / 2, {1, 0, 0})
	spawn_light(w, {}, down, Directional_Light{intensity = 3, cast_shadows = true})
	spawn_light(w, {0, 2, 5}, down, Spot_Light{intensity = 4, range = 6, outer_angle = 0.6, cast_shadows = true})
	// The near point light brings more light to the view than the spot light, so it takes its shadow first.
	spawn_light(w, {1, 0, 3}, 1, Point_Light{intensity = 4, cast_shadows = true})
	// Behind the camera and out of its reach, it lights nothing in view, so it gets no shadow.
	spawn_light(w, {0, 0, -50}, 1, Point_Light{intensity = 4, range = 5, cast_shadows = true})
	spawn_light(w, {0, 0, 4}, 1, Point_Light{intensity = 1})
	hidden := spawn_light(w, {0, 0, 4}, 1, Point_Light{intensity = 1})
	hidden_bits := make([]u32, ecs.entity_index(hidden) / 32 + 1, context.temp_allocator)
	hidden_bits[ecs.entity_index(hidden) / 32] |= 1 << (ecs.entity_index(hidden) % 32)

	frame := &f.frame
	frame.lights = extract_lights(frame, w, hidden_bits)
	lf := frame.lights
	testing.expect_value(t, len(lf.records), 5)
	testing.expect_value(t, lf.directional_count, 1)
	// The directional lights, then the point lights, then the spot lights.
	sun := lf.records[0]
	testing.expect_value(t, sun.type, Light_Type.Directional)
	testing.expect(t, linalg.length(sun.direction - {0, -1, 0}) < 1e-5, "the sun shines along its +z")
	// A field at 0 takes its default: white, and DEFAULT_LIGHT_RANGE.
	testing.expect_value(t, lf.records[3].color, [3]f32{1, 1, 1})
	testing.expect_value(t, lf.records[3].range, DEFAULT_LIGHT_RANGE)
	testing.expect_value(t, lf.records[4].type, Light_Type.Spot)

	// As resolve_settings gives them without volumes.
	frame.shadow_settings = {SHADOW_DISTANCE, SHADOW_SPLIT_LAMBDA}
	assign_shadow_views(frame, trace = false)
	sf := frame.shadows
	testing.expect_value(t, lf.records[0].shadow, 0)
	// The cascades, then the point light's six faces, then the spot light's view.
	testing.expect_value(t, lf.records[1].shadow, SHADOW_CASCADES)
	testing.expect_value(t, lf.records[4].shadow, SHADOW_CASCADES + 6)
	testing.expect_value(t, lf.records[2].shadow, -1)
	testing.expect_value(t, lf.records[3].shadow, -1)
	testing.expect_value(t, len(sf.views), SHADOW_CASCADES + 6 + 1)
	testing.expect_value(t, sf.cascade_splits, cascade_splits(0.1))
	// A cascade culls nothing toward the light; the spot light's view culls beyond its range.
	testing.expect_value(t, sf.planes[0][4], [4]f32{0, 0, 0, 1})
	spot := sf.planes[SHADOW_CASCADES + 6]
	testing.expect(t, sphere_in(spot[:], {0, -3, 5}, 0), "a point below the spot light, in range, is in its view")
	testing.expect(t, !sphere_in(spot[:], {0, -5, 5}, 0), "a point below the spot light, past its range, is not")
	testing.expect(t, !sphere_in(spot[:], {0, 3, 5}, 0), "a point above the spot light is not")
	// The views' rectangles of the atlas do not overlap.
	for a, i in sf.viewports {
		for b in sf.viewports[i + 1:] {
			apart := a.x + a.z <= b.x || b.x + b.z <= a.x || a.y + a.w <= b.y || b.y + b.w <= a.y
			testing.expectf(t, apart, "%v and %v overlap", a, b)
		}
	}

	// With traced shadows, the casters take the mask's channels in the same order, and no maps.
	for &record in lf.records {
		record.shadow, record.mask = -1, -1
	}
	assign_shadow_views(frame, trace = true)
	testing.expect_value(t, lf.records[0].mask, 0)
	testing.expect_value(t, lf.records[1].mask, 1)
	testing.expect_value(t, lf.records[4].mask, 2)
	testing.expect_value(t, lf.records[2].mask, -1)
	testing.expect_value(t, frame.shadows.mask_count, 3)
	testing.expect_value(t, len(frame.shadows.views), 0)
}

@(test)
area_lights_record_their_shapes :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	// Turned a quarter about y: +x goes to -z, +y stays, and +z goes to +x.
	turn := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	spawn_light(w, {0, 0, 4}, turn, Quad_Light{intensity = 2, width = 2, height = 1, range = 5, two_sided = true, cast_shadows = true})
	spawn_light(w, {1, 0, 4}, 1, Disk_Light{intensity = 1, height = 3})
	spawn_light(w, {-1, 0, 4}, 1, Line_Light{intensity = 1, length = 4, radius = 0.25})
	hidden := spawn_light(w, {0, 0, 4}, 1, Quad_Light{intensity = 1})
	hidden_bits := make([]u32, ecs.entity_index(hidden) / 32 + 1, context.temp_allocator)
	hidden_bits[ecs.entity_index(hidden) / 32] |= 1 << (ecs.entity_index(hidden) % 32)

	frame := &f.frame
	frame.lights = extract_lights(frame, w, hidden_bits)
	lf := frame.lights
	testing.expect_value(t, len(lf.records), 3)
	near :: proc(a, b: [3]f32) -> bool {
		return linalg.length(a - b) < 1e-5
	}

	quad := lf.records[0]
	testing.expect_value(t, quad.type, Light_Type.Quad)
	testing.expect(t, near(quad.position, {0, 0, 4}), "an area light's position is its middle")
	testing.expect(t, near(quad.direction, {1, 0, 0}), "a quad shines along its +z")
	testing.expect(t, near(quad.extent, {0, 0, -1}), "a quad's extent is its half width along its +x")
	testing.expect_value(t, quad.extent_y, 0.5)
	testing.expect(t, near(linalg.cross(quad.direction, linalg.normalize(quad.extent)), {0, 1, 0}), "a quad's height is along its +y")
	testing.expect_value(t, quad.flags, bit_set[Light_Flag;u32]{.Two_Sided})
	// The range reaches past the corners, so the clusters' spheres hold the whole quad.
	testing.expect(t, abs(quad.range - (5 + math.sqrt(f32(1.25)))) < 1e-5)
	testing.expect_value(t, quad.color, [3]f32{2, 2, 2})

	disk := lf.records[1]
	testing.expect_value(t, disk.type, Light_Type.Disk)
	// A width of 0 takes DEFAULT_AREA_SIZE; the radii differ, so it is an ellipse.
	testing.expect(t, abs(linalg.length(disk.extent) - f32(DEFAULT_AREA_SIZE) / 2) < 1e-5)
	testing.expect_value(t, disk.extent_y, 1.5)
	testing.expect_value(t, disk.range, DEFAULT_LIGHT_RANGE + 1.5)
	testing.expect_value(t, disk.flags, bit_set[Light_Flag;u32]{})

	line := lf.records[2]
	testing.expect_value(t, line.type, Light_Type.Line)
	testing.expect(t, near(line.extent, {2, 0, 0}), "a line's extent is its half length along its +x")
	testing.expect_value(t, line.extent_y, 0.25)
	testing.expect_value(t, line.range, DEFAULT_LIGHT_RANGE + 2.25)

	// An area light casts its shadows from its middle, as a point light does: a cube of six views.
	assign_shadow_views(frame, trace = false)
	testing.expect_value(t, lf.records[0].shadow, 0)
	testing.expect_value(t, len(frame.shadows.views), 6)
	testing.expect_value(t, lf.records[1].shadow, -1)
}

@(private = "file")
sphere_in :: proc(planes: [][4]f32, center: [3]f32, radius: f32) -> bool {
	for p in planes {
		if linalg.dot(p.xyz, center) + p.w < -radius {
			return false
		}
	}
	return true
}
