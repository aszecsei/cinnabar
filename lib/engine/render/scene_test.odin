package render

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
inside :: proc(planes: [5][4]f32, p: [3]f32, radius: f32) -> bool {
	for plane in planes {
		if linalg.dot(plane.xyz, p) + plane.w < -radius {
			return false
		}
	}
	return true
}

@(test)
frustum_planes_keep_what_the_view_sees :: proc(t: ^testing.T) {
	view := View {
		rotation   = 1,
		projection = Perspective{math.PI / 2, 0.1},
	}
	planes := frustum_planes(view_projection(view, 1))
	// Ahead, however far, is inside: the far plane is at infinity.
	testing.expect(t, inside(planes, {0, 0, 5}, 0))
	testing.expect(t, inside(planes, {0, 0, 1e6}, 0))
	// Behind the camera, nearer than the near plane, and beyond a side are outside.
	testing.expect(t, !inside(planes, {0, 0, -1}, 0.5))
	testing.expect(t, !inside(planes, {0, 0, 0.05}, 0))
	testing.expect(t, !inside(planes, {10, 0, 5}, 1))
	testing.expect(t, !inside(planes, {0, -10, 5}, 1))
	// A sphere that reaches into the view across a side is inside.
	testing.expect(t, inside(planes, {6, 0, 5}, 1))
}

@(test)
the_render_origin_snaps_to_cells :: proc(t: ^testing.T) {
	cell := i64(1) << ORIGIN_CELL_BITS
	p := ecs.World_Position{raw = {cell * 3 + 5, -5, cell * 2 - 1}}
	// Negative positions snap down to their cell's corner, as positive ones do.
	testing.expect_value(t, snap_origin(p).raw, [3]i64{cell * 3, -cell, cell})
	testing.expect_value(t, ORIGIN_CELL, 1024)
}

@(test)
dirty_slots_are_the_set_bits :: proc(t: ^testing.T) {
	slots :: proc(dirty: []u32, high: u32, full := false) -> []u32 {
		bits: [MAX_INSTANCES / 64]u64
		for slot in dirty {
			bits[slot / 64] |= 1 << (slot % 64)
		}
		return dirty_slots(&bits, high, full, context.temp_allocator)
	}
	testing.expect_value(t, len(slots({}, 100)), 0)
	testing.expect_value(t, len(slots({}, 0, full = true)), 0)

	// Every slot below high, whatever is dirty.
	full := slots({5}, 100, full = true)
	testing.expect_value(t, len(full), 100)
	for slot, i in full {
		testing.expect_value(t, slot, u32(i))
	}

	// Scattered slots, in order, across the words of the bits and at their edges, and none from high on.
	apart := slots({500, 3, 63, 64, 127, 999, 1000}, 1000)
	testing.expect(t, slice.equal(apart, []u32{3, 63, 64, 127, 500, 999}))

	// However many and however far apart, each dirty slot and no other.
	many := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< u32(1000) {
		append(&many, i * 16 + 7)
	}
	testing.expect(t, slice.equal(slots(many[:], MAX_INSTANCES), many[:]))
	testing.expect_value(t, len(slots({MAX_INSTANCES - 1}, MAX_INSTANCES)), 1)
}

// A skinned entity's item has a bin of its own after its material's, which draws with vertex pulling, as a mesh
// particles' does: its posed vertices are not the mesh's that the mesh shader path reads.
@(test)
skinned_items_have_bins_of_their_own :: proc(t: ^testing.T) {
	items := []Cull_Item{{bin = 0, flags = ITEM_SKINNED}, {bin = 0, flags = ITEM_MESH_PATH}, {bin = 0, flags = ITEM_SKINNED}, {bin = 0}}
	sorting := make([]Sort_Item, len(items), context.temp_allocator)
	for item, i in items {
		sorting[i] = {item = item}
	}
	pipelines, groups := sort_bins(sorting, items, context.temp_allocator)
	testing.expect_value(t, len(pipelines), 2)
	testing.expect_value(t, groups[.Opaque], [2]int{0, 2})
	skinned := bin_skinned(items, len(pipelines), context.temp_allocator)
	testing.expect_value(t, skinned[0], false)
	testing.expect_value(t, skinned[1], true)
	// The static items keep the first bin, the skinned items share the second, and each keeps its flags.
	testing.expect_value(t, items[0].bin, 0)
	testing.expect_value(t, items[1].bin, 0)
	testing.expect_value(t, items[2].bin, 1)
	testing.expect_value(t, items[3].bin, 1)
	testing.expect_value(t, items[2].flags & ITEM_SKINNED, ITEM_SKINNED)
}
