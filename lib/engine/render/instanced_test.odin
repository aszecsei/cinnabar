package render

import "core:testing"

import format "cinnabar:engine/asset/format"

// A mesh's level buckets: each submesh's first meshlet of each bucket's level, at its last level past it, and each
// level's largest parent error and its parents' reach, F32_MAX past the mesh's last level.
@(test)
mesh_levels_bucket_each_submeshs_meshlets :: proc(t: ^testing.T) {
	meshlet :: proc(depth: u16, parent_error: f32, parent_center: [3]f32 = {}, parent_radius: f32 = 0) -> format.Meshlet {
		return {depth = depth, parent_error = parent_error, parent_center = parent_center, parent_radius = parent_radius}
	}
	meshlets := []format.Meshlet {
		// Submesh 0: two levels.
		meshlet(0, 0.5, {1, 0, 0}, 1),
		meshlet(0, 0.25, {0, 2, 0}, 1),
		meshlet(1, max(f32)),
		// Submesh 1: three levels.
		meshlet(0, 0.1),
		meshlet(1, 2, {0, 0, 0}, 4),
		meshlet(2, max(f32)),
	}
	m: Resident_Mesh
	m.submesh_count = 2
	m.submeshes[0] = {first_meshlet = 0, meshlet_count = 3}
	m.submeshes[1] = {first_meshlet = 3, meshlet_count = 3}
	mesh_levels(&m, meshlets)
	testing.expect_value(t, m.level_first[0][0], 0)
	testing.expect_value(t, m.level_first[0][1], 2)
	testing.expect_value(t, m.level_first[0][INSTANCE_LEVEL_BUCKETS - 1], 2)
	testing.expect_value(t, m.level_first[1][1], 1)
	testing.expect_value(t, m.level_first[1][2], 2)
	testing.expect_value(t, m.level_first[1][5], 2)
	testing.expect_value(t, m.levels[0], [2]f32{0.5, 3})
	testing.expect_value(t, m.levels[1], [2]f32{max(f32), 4})
	testing.expect_value(t, m.levels[2][0], max(f32))
	testing.expect_value(t, m.levels[3][0], max(f32))

	// A mesh deeper than the buckets: the last bucket starts at its level, and every level has its errors.
	deep := make([]format.Meshlet, 12, context.temp_allocator)
	for &c, depth in deep {
		c = meshlet(u16(depth), depth == 11 ? max(f32) : f32(depth + 1))
	}
	d: Resident_Mesh
	d.submesh_count = 1
	d.submeshes[0] = {first_meshlet = 0, meshlet_count = 12}
	mesh_levels(&d, deep)
	testing.expect_value(t, d.level_first[0][INSTANCE_LEVEL_BUCKETS - 1], INSTANCE_LEVEL_BUCKETS - 1)
	testing.expect_value(t, d.levels[INSTANCE_LEVEL_BUCKETS - 1][0], INSTANCE_LEVEL_BUCKETS)
}

// A slot keeps its cells while its set's count of cells holds, so their visibility bits carry over; a freed range is
// taken again by a set that fits in it, and merges with its neighbours, and a range at the end gives its cells back.
@(test)
instance_cells_are_kept_and_given_back :: proc(t: ^testing.T) {
	s := new(Gpu_Scene)
	defer free(s)
	s.cell_free = make([dynamic]Cell_Range)
	defer delete(s.cell_free)

	a, a_ok := scene_cells(s, 0, 10)
	b, _ := scene_cells(s, 1, 5)
	c, _ := scene_cells(s, 2, 7)
	testing.expect(t, a_ok)
	testing.expect_value(t, a, Cell_Range{0, 10})
	testing.expect_value(t, b, Cell_Range{10, 5})
	testing.expect_value(t, c, Cell_Range{15, 7})
	again, _ := scene_cells(s, 0, 10)
	testing.expect_value(t, again, a)

	// Slot 0's set grows: it moves to the end, and its old cells are free.
	grown, _ := scene_cells(s, 0, 12)
	testing.expect_value(t, grown, Cell_Range{22, 12})
	testing.expect_value(t, len(s.cell_free), 1)
	fits, _ := scene_cells(s, 3, 4)
	testing.expect_value(t, fits, Cell_Range{0, 4})

	// Freeing slot 1 merges its cells with the free ones before them.
	free_cells(s, 1)
	testing.expect_value(t, len(s.cell_free), 1)
	testing.expect_value(t, s.cell_free[0], Cell_Range{4, 11})

	// The last range gives its cells back to the end, and with them the free range before it.
	free_cells(s, 2)
	testing.expect_value(t, s.cell_high, 34)
	free_cells(s, 0)
	testing.expect_value(t, s.cell_high, 4)
	testing.expect_value(t, len(s.cell_free), 0)
	free_cells(s, 3)
	testing.expect_value(t, s.cell_high, 0)
}
