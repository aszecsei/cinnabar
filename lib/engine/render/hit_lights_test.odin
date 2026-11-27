package render

import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
at_meters :: proc(x, y, z: f64) -> ecs.World_Position {
	scale :: f64(1 << ecs.POSITION_FRACTION_BITS)
	return {raw = {i64(x * scale), i64(y * scale), i64(z * scale)}}
}

// sixty_four_lights are a room of 64 punctual lights around the camera: most small, some on the cells' edges of their
// levels, some large, and one larger than the last level's cells, which only the global list holds.
@(private = "file")
sixty_four_lights :: proc(allocator := context.allocator) -> []Light_Record {
	records := make([dynamic]Light_Record, allocator)
	append(&records, Light_Record{type = .Directional, color = {1, 1, 1}, direction = {0, -1, 0}})
	for i in 0 ..< 64 {
		a := f32(i) * 2.399963
		radius := 3 + f32(i % 8) * 4
		record := Light_Record {
			position = {radius * math.cos(a), f32(i % 5) - 2, radius * math.sin(a)},
			range    = 0.5 + f32(i % 7) * 1.5,
			color    = {1, 0.8, 0.6},
			type     = i % 3 == 0 ? .Spot : .Point,
		}
		switch i {
		case 10:
			// On a cell's edge of the first level, whose cells are 2 m.
			record.position = {2, 0.001, -2}
			record.range = 1
		case 20:
			record.range = 20
		case 30:
			// Too large for every level's cells: the global list holds it.
			record.range = 100
		case 40:
			record.position = {-4.0001, 3.9999, 0}
			record.range = 0.999
		}
		append(&records, record)
	}
	return records[:]
}

// In a room of 64 punctual lights, a point in any light's sphere finds that light among its candidates, at every
// distance from the light's middle out to its range, and each light is listed once there: so the hits' light can pick
// any of them, and its weight's PDF counts it once.
@(test)
a_point_in_a_lights_sphere_finds_it_in_the_light_grid :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	for camera in ([]ecs.World_Position{at_meters(0, 0, 0), at_meters(-1234.75, 17.5, 98765.125)}) {
		records := sixty_four_lights(allocator)
		grid := build_light_grid(records, camera, allocator)
		testing.expect_value(t, grid.header.global_count, 1)
		directions := [][3]f32 {
			{1, 0, 0},
			{-1, 0, 0},
			{0, 1, 0},
			{0, -1, 0},
			{0, 0, 1},
			{0, 0, -1},
			linalg.normalize([3]f32{1, 1, 1}),
			linalg.normalize([3]f32{-1, 1, -1}),
		}
		for record, i in records {
			if record.type == .Directional {
				continue
			}
			for d in directions {
				for share in ([]f32{0, 0.5, 0.999}) {
					p := record.position + d * record.range * share
					found := light_grid_lights(grid, p, allocator)
					count := 0
					for index in found {
						if index == u32(i) {
							count += 1
						}
					}
					testing.expectf(
						t,
						count == 1,
						"light %d is a candidate %d times at %v",
						i,
						count,
						p,
					)
				}
			}
		}
	}
}

// Every cell's key is found within the table's probing, so the shader's lookup, which gives up after
// LIGHT_GRID_PROBE_STEPS, misses none.
@(test)
the_light_grids_table_finds_every_cell :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	records := make([]Light_Record, MAX_LIGHTS, allocator)
	for &record, i in records {
		record = {
			position = {f32(i % 32) * 1.7 - 27, f32(i / 32 % 4), f32(i / 128) * 1.9 - 7},
			range    = 0.9,
			color    = {1, 1, 1},
			type     = .Point,
		}
	}
	grid := build_light_grid(records, at_meters(0, 0, 0), allocator)
	testing.expect_value(t, grid.header.global_count, 0)
	cells := 0
	for entry in grid.table {
		if entry.key == 0 {
			continue
		}
		cells += 1
		testing.expect(t, light_grid_find(grid, entry.key) != nil)
	}
	testing.expect(t, cells > 0)
	testing.expect(t, int(grid.header.table_mask + 1) >= 2 * cells)
}

// A directional light, a black one and one of no range are never candidates: the directional lights have their own
// loop, and the others light nothing.
@(test)
the_light_grid_lists_only_lights_that_reach :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	records := []Light_Record {
		{type = .Directional, color = {1, 1, 1}},
		{type = .Point, position = {1, 0, 0}, range = 2, color = {0, 0, 0}},
		{type = .Point, position = {1, 0, 0}, range = 0, color = {1, 1, 1}},
		{type = .Point, position = {1, 0, 0}, range = 2, color = {1, 1, 1}},
	}
	grid := build_light_grid(records, at_meters(0, 0, 0), allocator)
	testing.expect_value(t, len(grid.lists), 8)
	for index in grid.lists {
		testing.expect_value(t, index, 3)
	}
	testing.expect_value(t, len(light_grid_lights(grid, {1, 0, 0}, allocator)), 1)
	testing.expect_value(t, len(light_grid_lights(grid, {100, 0, 0}, allocator)), 0)
}

// The hits' light weighs more lights at each level, as the world probes' and the traced reflections' levels say.
@(test)
each_level_weighs_its_candidates :: proc(t: ^testing.T) {
	expected := [Quality_Level]u32 {
		.Low    = 4,
		.Medium = 8,
		.High   = 16,
		.Ultra  = 16,
	}
	for level in Quality_Level {
		testing.expect_value(t, GI_PROBE_PARAMS[level].candidates, expected[level])
		testing.expect_value(t, REFLECTION_PARAMS[.Ray_Traced][level].candidates, expected[level])
		testing.expect(t, expected[level] <= MAX_HIT_CANDIDATES)
	}
}
