package render

import "core:slice"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
test_guid :: proc(n: u8) -> format.Guid {
	return {0 = n}
}

@(private = "file")
IDENTITY_ROWS :: [3][4]f32{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}

// test_levels are virtual shadow map levels from first on, with the ones before them drawing nothing, whose drawn pages
// are the squares about the origin, in meters from their centers, that radii give for each level. The levels' axes are
// the world's x and z, and their first page is at the origin's.
@(private = "file")
test_levels :: proc(first: int, radii: []f32) -> Surface_Levels {
	count := first + len(radii)
	table := make([]u32, VIRTUAL_TABLE_COUNTS + VIRTUAL_MAX_LEVELS, context.temp_allocator)
	planes := make([][6][4]f32, count, context.temp_allocator)
	fields := make([]u32, count, context.temp_allocator)
	for &entry in table[:VIRTUAL_TABLE_COUNTS] {
		entry = VIRTUAL_NO_PAGE
	}
	for level in 0 ..< count {
		page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
		planes[level][0] = {1, 0, 0, page * VIRTUAL_PAGES / 2}
		planes[level][3] = {0, 0, 1, page * VIRTUAL_PAGES / 2}
		fields[level] = u32(level)
		if level < first {
			continue
		}
		reach := i32(radii[level - first] / page) + 1
		low, high :=
			max(VIRTUAL_PAGES / 2 - reach, 0), min(VIRTUAL_PAGES / 2 + reach, VIRTUAL_PAGES - 1)
		for y in low ..= high {
			for x in low ..= high {
				table[virtual_table_slot(level, {i32(x), i32(y)})] = 1 | VIRTUAL_DRAW
				table[VIRTUAL_TABLE_COUNTS + level] += 1
			}
		}
	}
	return surface_levels(table, planes, fields, context.temp_allocator)
}

@(private = "file")
test_surface :: proc(camera: [3]f32, lod: f32) -> Surface_Record {
	return surface_record(
		{size = {4096, 4096}, cell = 2, height_range = {-2, 2}},
		IDENTITY_ROWS,
		camera,
		lod,
		0,
		0,
	)
}

// Four nested squares of drawn pages, the finest at level 7: a cut that is finest in the middle and coarser outward.
@(private = "file")
test_nested_levels :: proc() -> Surface_Levels {
	return test_levels(7, {100, 250, 500, 1000, 2500})
}

@(test)
the_shadow_walk_cut_does_not_follow_the_camera :: proc(t: ^testing.T) {
	levels := test_nested_levels()
	here := select_patches_shadow_reference(
		test_surface({-100, 3, 0}, 935),
		IDENTITY_ROWS,
		0,
		levels,
		context.temp_allocator,
	)
	there := select_patches_shadow_reference(
		test_surface({200, 50, -150}, 3000),
		IDENTITY_ROWS,
		0,
		levels,
		context.temp_allocator,
	)
	slice.sort(here)
	slice.sort(there)
	testing.expect(t, len(here) > 1, "the cut is one patch")
	testing.expect(t, slice.equal(here, there), "the cut follows the camera")
	// The camera's own cut does.
	camera_here := select_patches_reference(
		test_surface({-100, 3, 0}, 935),
		context.temp_allocator,
	)
	camera_there := select_patches_reference(
		test_surface({200, 50, -150}, 935),
		context.temp_allocator,
	)
	slice.sort(camera_here)
	slice.sort(camera_there)
	testing.expect(t, !slice.equal(camera_here, camera_there))
	// The drawn pages decide it: with the finest level's pages gone, the cut is coarser.
	coarse := select_patches_shadow_reference(
		test_surface({-100, 3, 0}, 935),
		IDENTITY_ROWS,
		0,
		test_levels(8, {250, 500, 1000, 2500}),
		context.temp_allocator,
	)
	testing.expect(
		t,
		len(coarse) < len(here),
		"the cut is as fine without the finest level's pages",
	)
}

@(test)
the_shadow_walk_covers_what_its_pages_reach_and_nothing_else :: proc(t: ^testing.T) {
	// Pages only about the origin, a fifth of the surface: no patch is beyond them, whatever its size.
	levels := test_levels(8, {250})
	s := test_surface({}, 935)
	patches := select_patches_reference_shadow_for_test(s, levels)
	testing.expect(t, len(patches) > 0)
	for p in patches {
		x, y, level := surface_patch_unpack(p)
		size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
		lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
		testing.expectf(
			t,
			surface_box_texel(levels, s, IDENTITY_ROWS, 0, lo + size * 0.5, size * 0.5) > 0,
			"patch %v reaches no page",
			[3]u32{x, y, level},
		)
	}
	// A surface beyond every drawn page draws no patch.
	far := IDENTITY_ROWS
	far[0][3] = 30000
	testing.expect_value(
		t,
		len(select_patches_shadow_reference(s, far, 0, levels, context.temp_allocator)),
		0,
	)
}

@(private = "file")
select_patches_reference_shadow_for_test :: proc(
	s: Surface_Record,
	levels: Surface_Levels,
) -> []u32 {
	return select_patches_shadow_reference(s, IDENTITY_ROWS, 0, levels, context.temp_allocator)
}

// leaf_level is the level of the patch that covers a point of the surface's plane, or -1 for none.
@(private = "file")
leaf_level :: proc(s: Surface_Record, patches: []u32, point: [2]f32) -> int {
	for p in patches {
		x, y, level := surface_patch_unpack(p)
		size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
		lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
		if point.x >= lo.x && point.y >= lo.y && point.x < lo.x + size && point.y < lo.y + size {
			return int(level)
		}
	}
	return -1
}

@(test)
the_shadow_walk_balances_its_tree_and_marks_the_coarser_edges :: proc(t: ^testing.T) {
	levels := test_nested_levels()
	s := test_surface({}, 935)
	patches := select_patches_reference_shadow_for_test(s, levels)
	seen: [MAX_SURFACE_LEVELS]int
	marked := 0
	area: f64
	for p in patches {
		x, y, level := surface_patch_unpack(p)
		size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
		lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
		area += f64(size) * f64(size)
		seen[level] += 1
		edges := surface_patch_edges(p)
		middle := lo + size * 0.5
		reach := size * 0.5 + 0.01
		for direction, i in ([4][2]f32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
			point := middle + direction * reach
			if abs(point.x) >= 2048 || abs(point.y) >= 2048 {
				testing.expectf(
					t,
					edges & (1 << u32(i)) == 0,
					"patch %v marks an edge on the rectangle's border",
					[3]u32{x, y, level},
				)
				continue
			}
			beside := leaf_level(s, patches, point)
			testing.expectf(t, beside >= 0, "patch %v has no neighbour %d", [3]u32{x, y, level}, i)
			testing.expectf(
				t,
				abs(beside - int(level)) <= 1,
				"patch %v of level %d is beside level %d",
				[2]u32{x, y},
				level,
				beside,
			)
			coarser := beside > int(level)
			testing.expectf(
				t,
				coarser == (edges & (1 << u32(i)) != 0),
				"patch %v of level %d: edge %d has a neighbour of level %d, and bits %b",
				[2]u32{x, y},
				level,
				i,
				beside,
				edges,
			)
			marked += coarser ? 1 : 0
		}
	}
	// They tile the rectangle, over at least three levels, and some edges are coarser than their neighbours.
	testing.expect_value(t, area, 4096 * 4096)
	levels_used := 0
	for n in seen {
		levels_used += n > 0 ? 1 : 0
	}
	testing.expect(t, levels_used >= 3, "the cut has fewer than three levels")
	testing.expect(t, marked > 0, "no edge is marked")
}

@(test)
a_surfaces_edit_is_a_caster_change :: proc(t: ^testing.T) {
	sr := Surface_Renderer {
		size         = {64, 64},
		material     = test_guid(1),
		height_range = {0, 10},
		cell         = 1,
		height_map   = test_guid(2),
		hole_mask    = test_guid(3),
		layer_map    = test_guid(4),
		cast_shadows = true,
	}
	base := surface_signature(sr, {1, 1, 1}, true)
	testing.expect_value(t, surface_signature(sr, {1, 1, 1}, true), base)
	// A map's new version, any of them.
	testing.expect(t, surface_signature(sr, {2, 1, 1}, true) != base)
	testing.expect(t, surface_signature(sr, {1, 2, 1}, true) != base)
	testing.expect(t, surface_signature(sr, {1, 1, 2}, true) != base)
	// The hole mask streaming in.
	testing.expect(t, surface_signature(sr, {1, 1, 1}, false) != base)
	// A field of the component.
	edited := sr
	edited.cell = 2
	testing.expect(t, surface_signature(edited, {1, 1, 1}, true) != base)
	edited = sr
	edited.height_range = {0, 12}
	testing.expect(t, surface_signature(edited, {1, 1, 1}, true) != base)
	edited = sr
	edited.material = test_guid(9)
	testing.expect(t, surface_signature(edited, {1, 1, 1}, true) != base)
	edited = sr
	edited.cast_shadows = false
	testing.expect(t, surface_signature(edited, {1, 1, 1}, true) != base)

	// The tracking sees it as the surface item's list, with nothing else of the item changed.
	tracking := new(Caster_Tracking)
	tracking.changes = make([dynamic]Caster_Change)
	defer {
		delete(tracking.changes)
		free(tracking)
	}
	records := []Instance_Record{{rows = IDENTITY_ROWS}}
	pipelines := make([]Material_Pipeline, 1, context.temp_allocator)
	item := Cull_Item {
		flags  = ITEM_SURFACE | ITEM_CASTS_SHADOWS,
		count  = SURFACE_PATCH_VERTICES,
		sphere = {0, 5, 0, 50},
		list   = base,
	}
	track :: proc(
		tracking: ^Caster_Tracking,
		records: []Instance_Record,
		pipelines: []Material_Pipeline,
		item: Cull_Item,
		frame: u64,
	) {
		bounds := caster_bounds(
			records,
			[]Cull_Item{item},
			pipelines,
			nil,
			nil,
			1,
			context.temp_allocator,
		)
		track_casters(tracking, bounds, {}, frame)
	}
	track(tracking, records, pipelines, item, 1)
	testing.expect_value(t, len(tracking.changes), 1)
	for frame in u64(2) ..< 6 {
		track(tracking, records, pipelines, item, frame)
		testing.expectf(t, len(tracking.changes) == 0, "frame %d: a still surface changed", frame)
	}
	item.list = surface_signature(sr, {1, 2, 1}, true)
	track(tracking, records, pipelines, item, 6)
	testing.expect_value(t, len(tracking.changes), 1)
	old, had := tracking.changes[0].old.?
	new, has := tracking.changes[0].new.?
	testing.expect(t, had && has, "an edit is not a change from a place to a place")
	testing.expect_value(t, old, new)
}
