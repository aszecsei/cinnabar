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
an_orthographic_views_clusters_slice_its_depth_evenly :: proc(t: ^testing.T) {
	// A near plane at 0 has no exponential slices.
	for near in ([]f32{0, 2}) {
		projection := Orthographic{10, near, near + 64}
		for k in 0 ..< CLUSTER_SLICES {
			testing.expect_value(t, cluster_slice(near + f32(k) * 2 + 1, projection), k)
		}
		testing.expect_value(t, cluster_slice(near - 1, projection), 0)
		testing.expect_value(t, cluster_slice(near + 1000, projection), CLUSTER_SLICES - 1)
	}
}

@(test)
an_orthographic_views_cascades_split_evenly :: proc(t: ^testing.T) {
	splits := cascade_splits(0, 100, 0, 4)
	testing.expect_value(t, splits, [SHADOW_CASCADES]f32{25, 50, 75, 100})
	// Its corners are a box: as wide near as far.
	c := projection_constants(orthographic_view(1, 10, 0, 100), 2)
	testing.expect_value(t, view_corner(c, {1, 1}, 1), [3]f32{10, 5, 1})
	testing.expect_value(t, view_corner(c, {-1, 1}, 90), [3]f32{-10, 5, 90})
}

@(test)
clusters_slice_depth_exponentially :: proc(t: ^testing.T) {
	near: f32 = 0.1
	projection := Perspective{1, near}
	testing.expect_value(t, cluster_slice(near, projection), 0)
	// Each slice's start, near * (far / near)^(k / slices), is in slice k.
	for k in 0 ..< CLUSTER_SLICES {
		depth := near * math.pow(f32(CLUSTER_FAR) / near, (f32(k) + 0.5) / CLUSTER_SLICES)
		testing.expect_value(t, cluster_slice(depth, projection), k)
	}
	// Beyond CLUSTER_FAR, the last slice reaches on.
	testing.expect_value(t, cluster_slice(1e5, projection), CLUSTER_SLICES - 1)
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
	testing.expect(
		t,
		abs(even[0] - (0.1 + 39.9 / 4)) < 1e-3 && abs(even[SHADOW_CASCADES - 1] - 40) < 1e-3,
	)
	// Fewer cascades split the same reach, and the splits past them repeat the last, so no depth reaches past them.
	two := cascade_splits(0.1, 40, 1e-6, count = 2)
	testing.expect(t, abs(two[0] - (0.1 + 39.9 / 2)) < 1e-3)
	testing.expect_value(t, two[2], two[1])
	testing.expect_value(t, two[3], two[1])
}

@(test)
every_level_fits_its_shadow_views_in_its_atlas :: proc(t: ^testing.T) {
	for p, level in SHADOW_PARAMS {
		// The cascades take whole cells, then the slots fill the rest, from the largest to the smallest, as atlas_place
		// takes them: every unit past the cascades.
		viewports := make([dynamic][4]u32, context.temp_allocator)
		for c in 0 ..< p.cascades {
			pixels, _ := slot_viewport(p, cascade_slot(p, c))
			append(&viewports, pixels)
		}
		grid := atlas_grid(p, p.cascades)
		free := atlas_free_units(&grid)
		units := 0
		for size := p.max_slot; size >= p.min_slot; size /= 2 {
			for _ in 0 ..< 3 {
				slot, ok := atlas_take(&grid, size)
				if !ok {
					break
				}
				pixels, rect := slot_viewport(p, slot)
				testing.expectf(
					t,
					rect.x + rect.z <= 1 && rect.y + rect.w <= 1,
					"%v: slot %v is outside the atlas",
					level,
					slot,
				)
				append(&viewports, pixels)
				units += (size / p.min_slot) * (size / p.min_slot)
			}
		}
		for {
			slot, ok := atlas_take(&grid, p.min_slot)
			if !ok {
				break
			}
			pixels, _ := slot_viewport(p, slot)
			append(&viewports, pixels)
			units += 1
		}
		testing.expectf(t, units == free, "%v: the slots took %d of %d units", level, units, free)
		for a, i in viewports {
			testing.expectf(
				t,
				int(a.x + a.z) <= p.atlas && int(a.y + a.w) <= p.atlas,
				"%v: %v is outside the atlas",
				level,
				a,
			)
			for b in viewports[i + 1:] {
				apart :=
					a.x + a.z <= b.x || b.x + b.z <= a.x || a.y + a.w <= b.y || b.y + b.w <= a.y
				testing.expectf(t, apart, "%v: %v and %v overlap", level, a, b)
			}
		}
		testing.expect(t, p.cascades >= 1 && p.cascades <= SHADOW_CASCADES)
	}
}

@(private = "file")
Light_Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	world:    ecs.World,
	renderer: ^Renderer,
	// Every frame draws a view, whose state a virtual shadow map's levels read.
	state:    View_State,
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
	view := View {
		rotation   = 1,
		projection = Perspective{1, 0.1},
	}
	f.frame = {
		renderer        = f.renderer,
		state           = &f.state,
		view            = view,
		size            = {64, 32},
		view_projection = view_projection(view, 2),
	}
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
spawn_light :: proc(
	w: ^ecs.World,
	position: [3]f32,
	rotation: quaternion128,
	light: $T,
) -> ecs.Entity {
	e := ecs.spawn(w)
	ecs.add(
		w,
		e,
		ecs.Transform {
			position = ecs.position_offset({}, position),
			rotation = rotation,
			scale = 1,
		},
	)
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
	spawn_light(
		w,
		{0, 2, 5},
		down,
		Spot_Light{intensity = 4, range = 6, outer_angle = 0.6, cast_shadows = true},
	)
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
	testing.expect(
		t,
		linalg.length(sun.direction - {0, -1, 0}) < 1e-5,
		"the sun shines along its +z",
	)
	// A field at 0 takes its default: white, and DEFAULT_LIGHT_RANGE.
	testing.expect_value(t, lf.records[3].color, [3]f32{1, 1, 1})
	testing.expect_value(t, lf.records[3].range, DEFAULT_LIGHT_RANGE)
	testing.expect_value(t, lf.records[4].type, Light_Type.Spot)

	// As resolve_settings gives them without volumes, at High, which has every cascade.
	frame.shadow_settings = {
		distance     = SHADOW_DISTANCE,
		split_lambda = SHADOW_SPLIT_LAMBDA,
		level        = .High,
	}
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
	testing.expect(
		t,
		sphere_in(spot[:], {0, -3, 5}, 0),
		"a point below the spot light, in range, is in its view",
	)
	testing.expect(
		t,
		!sphere_in(spot[:], {0, -5, 5}, 0),
		"a point below the spot light, past its range, is not",
	)
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

	// A virtual shadow map's levels take the cascades' place, as the first views, and no cells of the atlas, so the other
	// lights' slots start at the atlas's first.
	for &record in lf.records {
		record.shadow, record.mask = -1, -1
	}
	assign_shadow_views(frame, trace = false, virtual = true)
	sf = frame.shadows
	levels := SHADOW_PARAMS[.High].virtual_levels
	testing.expect_value(t, sf.virtual.count, levels)
	testing.expect_value(t, lf.records[0].shadow, 0)
	testing.expect(t, .Virtual_Shadow in lf.records[0].flags)
	testing.expect_value(t, lf.records[1].shadow, i32(levels))
	testing.expect(t, .Virtual_Shadow not_in lf.records[1].flags)
	testing.expect_value(t, lf.records[4].shadow, i32(levels + 6))
	testing.expect_value(t, len(sf.views), levels + 6 + 1)
	testing.expect_value(t, sf.cascade_splits, [4]f32{})
	testing.expect_value(t, sf.viewports[levels].xy, [2]u32{0, 0})
	for view in sf.views[:levels] {
		testing.expect_value(t, view.perspective, u32(0))
	}
	// Traced shadows still take the light first: it has a channel of the mask, and no levels.
	for &record in lf.records {
		record.shadow, record.mask = -1, -1
		record.flags -= {.Virtual_Shadow}
	}
	assign_shadow_views(frame, trace = true, virtual = true)
	testing.expect_value(t, lf.records[0].mask, 0)
	testing.expect(t, .Virtual_Shadow not_in lf.records[0].flags)
	testing.expect_value(t, frame.shadows.virtual.count, 0)

	// Without tracing, the light with the virtual shadow map or the cascades also takes the contact shadows, and no other.
	for virtual in ([]bool{true, false}) {
		for &record in lf.records {
			record.shadow, record.mask = -1, -1
			record.flags -= {.Virtual_Shadow, .Contact_Shadow}
		}
		assign_shadow_views(frame, trace = false, virtual = virtual, contact = true)
		testing.expect_value(t, frame.shadows.contact_light, 0)
		testing.expect_value(t, lf.records[0].shadow, 0)
		testing.expect(t, .Contact_Shadow in lf.records[0].flags)
		for record, i in lf.records[1:] {
			testing.expectf(
				t,
				.Contact_Shadow not_in record.flags,
				"light %d takes the contact shadows",
				i + 1,
			)
		}
	}
	// The mask's channel is the sun's shadow in a frame that traces, so it takes none.
	for &record in lf.records {
		record.shadow, record.mask = -1, -1
		record.flags -= {.Virtual_Shadow, .Contact_Shadow}
	}
	assign_shadow_views(frame, trace = true, contact = true)
	testing.expect_value(t, frame.shadows.contact_light, -1)
	for record, i in lf.records {
		testing.expectf(
			t,
			.Contact_Shadow not_in record.flags,
			"light %d takes the contact shadows",
			i,
		)
	}
}

@(test)
a_soft_lights_views_have_a_guard_band :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	spawn_light(
		w,
		{1, 0, 3},
		1,
		Point_Light{intensity = 4, source_radius = 0.1, cast_shadows = true},
	)
	spawn_light(w, {-1, 0, 3}, 1, Point_Light{intensity = 1, cast_shadows = true})
	frame := &f.frame
	frame.lights = extract_lights(frame, w, nil)
	lf := frame.lights

	for level in ([]Quality_Level{.Low, .High, .Ultra}) {
		for &record in lf.records {
			record.shadow = -1
		}
		frame.shadow_settings = {
			distance     = SHADOW_DISTANCE,
			split_lambda = SHADOW_SPLIT_LAMBDA,
			level        = level,
		}
		assign_shadow_views(frame, trace = false)
		sf := frame.shadows
		p := SHADOW_PARAMS[level]
		// The camera is within both lights' reach, so their faces take the largest slots.
		size := int(sf.viewports[lf.records[0].shadow].z)
		hard_size := int(sf.viewports[lf.records[1].shadow].z)
		testing.expect_value(t, size, p.max_slot)
		guard := soft_guard(p, size)
		testing.expect_value(t, guard, level == .Low ? 0 : int(math.ceil(f32(size) / 32)) + 2)
		// The soft light's faces are wider than 90 degrees, by its guard of texels on each side; the hard light's are not.
		soft, hard := sf.views[lf.records[0].shadow], sf.views[lf.records[1].shadow]
		testing.expectf(
			t,
			abs(soft.texel - 2 / f32(size - 2 * guard)) < 1e-7,
			"%v: a soft face's texel is %v",
			level,
			soft.texel,
		)
		testing.expectf(
			t,
			abs(hard.texel - 2 / f32(hard_size)) < 1e-7,
			"%v: a hard face's texel is %v",
			level,
			hard.texel,
		)
		// A point 45 degrees off the +x face's axis is on its 90 degrees' edge, guard texels inside the slot's.
		m := sf.matrices[lf.records[0].shadow]
		clip := m * [4]f32{2, 1, 3, 1}
		edge := (1 - clip.y / clip.w) * 0.5 * f32(size)
		testing.expectf(
			t,
			abs(edge - f32(guard)) < 1e-2,
			"%v: the face's edge is %v texels in",
			level,
			edge,
		)
	}
}

// The guard band is the filter's reach in each slot's size, so a smaller slot's band is narrower.
@(test)
a_guard_band_follows_its_slots_size :: proc(t: ^testing.T) {
	p := SHADOW_PARAMS[.High]
	testing.expect_value(t, soft_guard(p, 512), 18)
	testing.expect_value(t, soft_guard(p, 128), 6)
	testing.expect_value(t, soft_guard(SHADOW_PARAMS[.Low], 512), 0)
}

// A spot light near the camera takes a larger slot than the same light far away, as large as it shows.
@(test)
a_near_spot_light_takes_a_larger_slot :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	down := linalg.quaternion_angle_axis_f32(math.PI / 2, {1, 0, 0})
	spot := Spot_Light{intensity = 4, range = 6, outer_angle = 0.6, cast_shadows = true}
	spawn_light(w, {0, 2, 10}, down, spot)
	spawn_light(w, {0, 2, 60}, down, spot)
	frame := &f.frame
	frame.size = {1920, 1080}
	frame.lights = extract_lights(frame, w, nil)
	lf := frame.lights
	frame.shadow_settings = {
		distance     = SHADOW_DISTANCE,
		split_lambda = SHADOW_SPLIT_LAMBDA,
		level        = .High,
	}
	assign_shadow_views(frame, trace = false)
	sf := frame.shadows
	near, far := -1, -1
	for record, i in lf.records {
		testing.expect(t, record.shadow >= 0)
		if record.position.z < 30 {
			near = i
		} else {
			far = i
		}
	}
	near_size := sf.viewports[lf.records[near].shadow].z
	far_size := sf.viewports[lf.records[far].shadow].z
	testing.expectf(t, near_size > far_size, "near %d, far %d", near_size, far_size)
	testing.expect_value(t, int(far_size), SHADOW_PARAMS[.High].min_slot)
	// A still camera gives every light the same slot.
	viewports := make([][4]u32, len(sf.viewports), context.temp_allocator)
	copy(viewports, sf.viewports[:])
	for &record in lf.records {
		record.shadow = -1
	}
	assign_shadow_views(frame, trace = false)
	testing.expect_value(t, len(frame.shadows.viewports), len(viewports))
	for v, i in viewports {
		testing.expect_value(t, frame.shadows.viewports[i], v)
	}
}

// At High, with the cascades, many far point lights fit the atlas in small slots, more than the 8 of fixed slots, and
// 8 near ones still fit in slots that halve until they do.
@(test)
the_atlas_fits_many_far_point_lights :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	down := linalg.quaternion_angle_axis_f32(math.PI / 2, {1, 0, 0})
	spawn_light(w, {}, down, Directional_Light{intensity = 3, cast_shadows = true})
	for i in 0 ..< 16 {
		spawn_light(
			w,
			{f32(i % 4) * 4 - 6, f32(i / 4) * 4 - 6, 50},
			1,
			Point_Light{intensity = 4, range = 3, cast_shadows = true},
		)
	}
	frame := &f.frame
	frame.size = {1920, 1080}
	frame.shadow_settings = {
		distance     = SHADOW_DISTANCE,
		split_lambda = SHADOW_SPLIT_LAMBDA,
		level        = .High,
	}
	frame.lights = extract_lights(frame, w, nil)
	assign_shadow_views(frame, trace = false)
	lit := 0
	for record in frame.lights.records {
		if record.type == .Point && record.shadow >= 0 {
			lit += 1
		}
	}
	testing.expect_value(t, lit, 16)
	testing.expect_value(t, len(frame.shadows.views), SHADOW_CASCADES + 16 * 6)
	expect_viewports_apart(t, frame.shadows.viewports[:])
}

// At High, with the cascades, 8 point lights around the camera, within their reach, still fit: each would take 1024,
// and their slots halve until they do.
@(test)
the_atlas_fits_near_point_lights_in_halved_slots :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	down := linalg.quaternion_angle_axis_f32(math.PI / 2, {1, 0, 0})
	spawn_light(w, {}, down, Directional_Light{intensity = 3, cast_shadows = true})
	for i in 0 ..< 8 {
		spawn_light(w, {f32(i) - 4, 0, 3}, 1, Point_Light{intensity = 4, cast_shadows = true})
	}
	frame := &f.frame
	frame.size = {1920, 1080}
	frame.shadow_settings = {
		distance     = SHADOW_DISTANCE,
		split_lambda = SHADOW_SPLIT_LAMBDA,
		level        = .High,
	}
	frame.lights = extract_lights(frame, w, nil)
	assign_shadow_views(frame, trace = false)
	lit := 0
	for record in frame.lights.records {
		if record.type == .Point && record.shadow >= 0 {
			lit += 1
			// 8 cubes at 1024 need 48 cells of the 12 past the cascades; at 512 they fill those 12.
			testing.expect_value(t, frame.shadows.viewports[record.shadow].z, 512)
		}
	}
	testing.expect_value(t, lit, 8)
	expect_viewports_apart(t, frame.shadows.viewports[:])
}

@(private = "file")
expect_viewports_apart :: proc(t: ^testing.T, viewports: [][4]u32, loc := #caller_location) {
	for a, i in viewports {
		for b in viewports[i + 1:] {
			apart := a.x + a.z <= b.x || b.x + b.z <= a.x || a.y + a.w <= b.y || b.y + b.w <= a.y
			testing.expectf(t, apart, "%v and %v overlap", a, b, loc = loc)
		}
	}
}

// A pass's pieces share its views: consecutive, every view once, at most MAX_PASS_PIECES pieces.
@(test)
the_pieces_share_the_views :: proc(t: ^testing.T) {
	for count in ([]int{1, 7, 64, 100, ATLAS_MAX_VIEWS}) {
		pieces := min(count, MAX_PASS_PIECES)
		next := 0
		for piece in 0 ..< pieces {
			first, last := piece_views(piece, pieces, count)
			testing.expect_value(t, first, next)
			testing.expect(t, last > first)
			next = last
		}
		testing.expect_value(t, next, count)
	}
}

@(test)
traced_soft_lights_take_soft_channels_whose_history_follows_them :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	sun := spawn_light(w, {}, 1, Directional_Light{intensity = 1, cast_shadows = true})
	soft := spawn_light(
		w,
		{1, 0, 3},
		1,
		Point_Light{intensity = 4, source_radius = 0.1, cast_shadows = true},
	)
	quad := spawn_light(w, {-1, 0, 3}, 1, Quad_Light{intensity = 2, cast_shadows = true})
	frame := &f.frame
	frame.lights = extract_lights(frame, w, nil)
	lf := frame.lights
	testing.expect_value(t, lf.entities[0], sun)
	frame.shadow_settings = {
		distance     = SHADOW_DISTANCE,
		split_lambda = SHADOW_SPLIT_LAMBDA,
		level        = .High,
	}
	assign_shadow_views(frame, trace = true)
	sf := frame.shadows
	// The sun has no size, so its channel is hard; the point light and the quad light have sizes.
	testing.expect_value(t, sf.mask_count, 3)
	testing.expect_value(t, sf.mask_soft, u32(0b110))
	testing.expect_value(t, lf.entities[sf.mask_lights[1]], soft)
	testing.expect_value(t, lf.entities[sf.mask_lights[2]], quad)

	// A channel takes the history of last frame's channel that held its light, and starts again otherwise.
	previous := Mask_History {
		lights = {quad, soft, {}, {}},
	}
	current := Mask_History {
		lights = {soft, {}, quad, sun},
	}
	testing.expect_value(
		t,
		mask_history_channels(previous, current),
		[4]u32{1, max(u32), 0, max(u32)},
	)
	testing.expect_value(
		t,
		mask_history_channels({}, current),
		[4]u32{max(u32), max(u32), max(u32), max(u32)},
	)
}

@(test)
area_lights_record_their_shapes :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	// Turned a quarter about y: +x goes to -z, +y stays, and +z goes to +x.
	turn := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	spawn_light(
		w,
		{0, 0, 4},
		turn,
		Quad_Light {
			intensity = 2,
			width = 2,
			height = 1,
			range = 5,
			two_sided = true,
			cast_shadows = true,
		},
	)
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
	testing.expect(
		t,
		near(quad.extent, {0, 0, -1}),
		"a quad's extent is its half width along its +x",
	)
	testing.expect_value(t, quad.extent_y, 0.5)
	testing.expect(
		t,
		near(linalg.cross(quad.direction, linalg.normalize(quad.extent)), {0, 1, 0}),
		"a quad's height is along its +y",
	)
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
	testing.expect(
		t,
		near(line.extent, {2, 0, 0}),
		"a line's extent is its half length along its +x",
	)
	testing.expect_value(t, line.extent_y, 0.25)
	testing.expect_value(t, line.range, DEFAULT_LIGHT_RANGE + 2.25)

	// An area light casts its shadows from its middle, as a point light does: a cube of six views.
	assign_shadow_views(frame, trace = false)
	testing.expect_value(t, lf.records[0].shadow, 0)
	testing.expect_value(t, len(frame.shadows.views), 6)
	testing.expect_value(t, lf.records[1].shadow, -1)
}

@(test)
lights_record_their_sizes :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	f := light_setup(t)
	defer light_teardown(f)
	w := &f.world

	spawn_light(w, {}, 1, Directional_Light{intensity = 1, angular_diameter = DEFAULT_SUN_DISC})
	spawn_light(w, {0, 0, 4}, 1, Point_Light{intensity = 1, source_radius = 0.1})
	spawn_light(w, {0, 0, 4}, 1, Point_Light{intensity = 1})
	spawn_light(w, {0, 0, 4}, 1, Spot_Light{intensity = 1, source_radius = 0.2})
	spawn_light(w, {0, 0, 4}, 1, Quad_Light{intensity = 1, width = 2, height = 1})
	spawn_light(w, {0, 0, 4}, 1, Disk_Light{intensity = 1, width = 2, height = 4})
	spawn_light(w, {0, 0, 4}, 1, Line_Light{intensity = 1, length = 3, radius = 0.1})

	frame := &f.frame
	frame.lights = extract_lights(frame, w, nil)
	lf := frame.lights
	testing.expect_value(t, len(lf.records), 7)
	close :: proc(a, b: f32) -> bool {
		return abs(a - b) < 1e-6
	}
	// The sun's disk is about 4.6 mm wide 1 m away.
	testing.expect(
		t,
		close(light_size(lf.records[0]), math.tan(math.to_radians(f32(DEFAULT_SUN_DISC)) / 2)),
	)
	// The point lights come before the spot lights.
	testing.expect(t, close(light_size(lf.records[1]), 0.1))
	testing.expect_value(t, light_size(lf.records[2]), 0)
	testing.expect(t, close(light_size(lf.records[3]), 0.2))
	// An area light's size is the radius of a disk with its area: a 2 m by 1 m quad's is sqrt(2 / pi).
	testing.expect(t, close(light_size(lf.records[4]), math.sqrt(2 / f32(math.PI))))
	testing.expect(t, close(light_size(lf.records[5]), math.sqrt(f32(2))))
	testing.expect(t, close(light_size(lf.records[6]), 1.5))
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
