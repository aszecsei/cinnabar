package render

import "core:math"
import "core:math/linalg"

// The shadow atlas's slots (see docs/rendering/lighting-and-shadows.md#shadows). A spot light's view and each of a point
// light's faces take a square slot whose side is a power of two from Shadow_Params.min_slot to max_slot, as large as the
// light's view shows on the screen. The atlas is a grid of the smallest slots, which a slot takes an aligned block of, as
// a quadtree's cell is: the cascades take the first cells, and the slots take the first free blocks in the quadtree's
// order. Each frame, atlas_place gives the lights their slots: a light keeps its slots while its size stays the same.

// The most units on a side of an atlas's grid: Shadow_Params.atlas / min_slot at every level.
ATLAS_GRID_SIDE :: 32
// The most views that the atlas holds, which the shadow maps' pass splits into its pieces.
ATLAS_MAX_VIEWS :: 128
// How far a light's coverage passes a size boundary, in powers of two, before its slot takes the next size: a light at
// 512 grows at 2^9.75 pixels and shrinks at 2^8.25.
SHADOW_SIZE_HYSTERESIS :: 0.25

// Atlas_Slot is a square of the atlas, in pixels: a size of 0 is no slot.
Atlas_Slot :: struct {
	x, y, size: i32,
}

// Atlas_Grid is which of the atlas's units, each of min_slot pixels on a side, are taken.
Atlas_Grid :: struct {
	unit: int,
	side: int,
	used: [ATLAS_GRID_SIDE * ATLAS_GRID_SIDE]bool,
}

// atlas_grid is an atlas with no slot taken but the first cascades' cells.
atlas_grid :: proc(p: Shadow_Params, cascades: int) -> (g: Atlas_Grid) {
	g.unit = p.min_slot
	g.side = min(p.atlas / p.min_slot, ATLAS_GRID_SIDE)
	for c in 0 ..< cascades {
		atlas_mark(&g, cascade_slot(p, c), true)
	}
	return
}

// cascade_slot is a cascade's cell: the cells run along the atlas's rows.
cascade_slot :: proc(p: Shadow_Params, c: int) -> Atlas_Slot {
	cells := p.atlas / p.cell
	return {i32((c % cells) * p.cell), i32((c / cells) * p.cell), i32(p.cell)}
}

// slot_viewport is a slot's rectangle of the atlas in pixels, and in UV.
slot_viewport :: proc(p: Shadow_Params, slot: Atlas_Slot) -> (pixels: [4]u32, rect: [4]f32) {
	pixels = {u32(slot.x), u32(slot.y), u32(slot.size), u32(slot.size)}
	atlas := f32(p.atlas)
	rect = {f32(slot.x) / atlas, f32(slot.y) / atlas, f32(slot.size) / atlas, f32(slot.size) / atlas}
	return
}

// atlas_mark takes or frees a slot's units.
atlas_mark :: proc(g: ^Atlas_Grid, slot: Atlas_Slot, used: bool) {
	x0, y0, n := int(slot.x) / g.unit, int(slot.y) / g.unit, int(slot.size) / g.unit
	for y in y0 ..< min(y0 + n, g.side) {
		for x in x0 ..< min(x0 + n, g.side) {
			g.used[y * ATLAS_GRID_SIDE + x] = used
		}
	}
}

// atlas_is_free says whether none of a slot's units are taken.
atlas_is_free :: proc(g: ^Atlas_Grid, slot: Atlas_Slot) -> bool {
	x0, y0, n := int(slot.x) / g.unit, int(slot.y) / g.unit, int(slot.size) / g.unit
	if x0 + n > g.side || y0 + n > g.side {
		return false
	}
	for y in y0 ..< y0 + n {
		for x in x0 ..< x0 + n {
			if g.used[y * ATLAS_GRID_SIDE + x] {
				return false
			}
		}
	}
	return true
}

// atlas_free_units is how many units no slot takes.
atlas_free_units :: proc(g: ^Atlas_Grid) -> (n: int) {
	for y in 0 ..< g.side {
		for x in 0 ..< g.side {
			n += g.used[y * ATLAS_GRID_SIDE + x] ? 0 : 1
		}
	}
	return
}

// atlas_take takes the first free block of a size, in the quadtree's order: the Morton order of the blocks, so the slots
// fill a quadrant before the next. Slots taken from the largest to the smallest so always fit while their units do (see
// atlas_place).
atlas_take :: proc(g: ^Atlas_Grid, size: int) -> (slot: Atlas_Slot, ok: bool) {
	n := size / g.unit
	if n < 1 || n > g.side {
		return {}, false
	}
	blocks := g.side / n
	for i in 0 ..< blocks * blocks {
		bx, by := morton_x(u32(i)), morton_x(u32(i) >> 1)
		candidate := Atlas_Slot{i32(int(bx) * size), i32(int(by) * size), i32(size)}
		if atlas_is_free(g, candidate) {
			atlas_mark(g, candidate, true)
			return candidate, true
		}
	}
	return {}, false
}

// morton_x is the x of a Morton index: its even bits.
@(private = "file")
morton_x :: proc(i: u32) -> u32 {
	x := i & 0x55555555
	x = (x | (x >> 1)) & 0x33333333
	x = (x | (x >> 2)) & 0x0f0f0f0f
	x = (x | (x >> 4)) & 0x00ff00ff
	x = (x | (x >> 8)) & 0x0000ffff
	return x
}

// atlas_slot_size is a light's slot size, a power of two from min_slot to max_slot, for its coverage, the side in pixels
// that its view shows on the screen at. A light that had a size keeps it until its coverage is SHADOW_SIZE_HYSTERESIS
// past the boundary to the next, so a light near a boundary does not change size, and draw its cache again, every frame.
atlas_slot_size :: proc(coverage: f32, previous: int, p: Shadow_Params) -> int {
	low, high := f32(log2_int(p.min_slot)), f32(log2_int(p.max_slot))
	level := coverage > 0 ? clamp(math.log2(coverage), low, high) : low
	if previous >= p.min_slot && previous <= p.max_slot {
		if abs(level - f32(log2_int(previous))) < 0.5 + SHADOW_SIZE_HYSTERESIS {
			return previous
		}
	}
	return 1 << uint(math.round(level))
}

@(private = "file")
log2_int :: proc(n: int) -> (k: int) {
	for v := n; v > 1; v >>= 1 {
		k += 1
	}
	return
}

// atlas_light_coverage is the side in pixels that a light's view shows on the screen at: the view's width at the light's
// range, 2 * range * tan(fov / 2), but no wider than its sphere, over the camera's distance from the sphere, at a scale
// of pixels a meter at 1 m (see lod_scale). A camera within the sphere sees it at max_slot. In an orthographic view, a
// meter's pixels are the same at every distance, scale over near.
atlas_light_coverage :: proc(
	position: [3]f32,
	range, fov: f32,
	scale, near: f32,
	flat: bool,
	p: Shadow_Params,
) -> f32 {
	width := 2 * range * min(math.tan(fov * 0.5), 1)
	if flat {
		return width * scale / max(near, 1e-6)
	}
	distance := linalg.length(position) - range
	if distance <= 0 {
		return f32(p.max_slot)
	}
	return width * scale / max(distance, near, 1e-6)
}

// Atlas_Taker is one light that asks for slots of the atlas in atlas_place: its coverage, its views, and the slots that it
// held last frame, whose size is its previous size. A taker with no faces holds nothing.
Atlas_Taker :: struct {
	coverage: f32,
	faces:    int,
	held:     [6]Atlas_Slot,
}

// atlas_place is the one place that gives the atlas's slots, to takers in their order of importance, with a grid whose
// cascades are taken. Each takes its size (see atlas_slot_size). While the sizes' units pass the free ones, the largest
// size halves, the least important first among equals; with every size at min_slot, the least important taker is left
// out and has no slots. Then a taker whose size stays the same keeps its slots, one that shrinks takes the corner of its
// own, and the others take free blocks, from the largest. If one of them finds none, as when the kept slots leave the
// free units apart, every taker takes its slots again from an empty atlas, from the largest: the sizes fit then, since
// each is a power of two and no larger than a cell. moved says that a taker's slots are not those that it held, so
// with the cache it draws them again.
atlas_place :: proc(
	g: ^Atlas_Grid,
	p: Shadow_Params,
	takers: []Atlas_Taker,
	allocator := context.allocator,
) -> (
	slots: [][6]Atlas_Slot,
	moved: []bool,
) {
	slots = make([][6]Atlas_Slot, len(takers), allocator)
	moved = make([]bool, len(takers), allocator)
	sizes := make([]int, len(takers), context.temp_allocator)
	units := proc(size, unit: int) -> int {
		return (size / unit) * (size / unit)
	}
	need := 0
	for taker, i in takers {
		if taker.faces == 0 {
			continue
		}
		sizes[i] = atlas_slot_size(taker.coverage, int(taker.held[0].size), p)
		need += taker.faces * units(sizes[i], g.unit)
	}
	free := atlas_free_units(g)
	for need > free {
		largest := -1
		for size, i in sizes {
			if size > p.min_slot && (largest < 0 || size >= sizes[largest]) {
				largest = i
			}
		}
		if largest >= 0 {
			need -= takers[largest].faces * (units(sizes[largest], g.unit) - units(sizes[largest] / 2, g.unit))
			sizes[largest] /= 2
			continue
		}
		last := -1
		for size, i in sizes {
			if size > 0 {
				last = i
			}
		}
		if last < 0 {
			break
		}
		need -= takers[last].faces * units(sizes[last], g.unit)
		sizes[last] = 0
	}
	// The takers that keep their slots or a corner of them, then the others from the largest.
	before := g^
	others := make([dynamic]int, 0, len(takers), context.temp_allocator)
	for taker, i in takers {
		held := int(taker.held[0].size)
		if sizes[i] == 0 {
			moved[i] = true
			continue
		}
		if held == 0 || sizes[i] > held {
			moved[i] = true
			append(&others, i)
			continue
		}
		for face in 0 ..< taker.faces {
			slots[i][face] = {taker.held[face].x, taker.held[face].y, i32(sizes[i])}
			atlas_mark(g, slots[i][face], true)
		}
		moved[i] = sizes[i] != held
	}
	by_size :: proc(order: []int, sizes: []int) {
		// Insertion sort, stable, so equal sizes keep their order.
		for i in 1 ..< len(order) {
			for j := i; j > 0 && sizes[order[j]] > sizes[order[j - 1]]; j -= 1 {
				order[j], order[j - 1] = order[j - 1], order[j]
			}
		}
	}
	by_size(others[:], sizes)
	if take_all(g, takers, sizes, others[:], slots) {
		return
	}
	// Every taker again, from an empty atlas.
	g^ = before
	all := make([]int, len(takers), context.temp_allocator)
	for &k, i in all {
		k = i
	}
	by_size(all, sizes)
	for i in all {
		slots[i] = {}
		moved[i] = true
	}
	take_all(g, takers, sizes, all, slots)
	return
}

// take_all takes the slots of takers in an order, and says whether every one found its slots: one that does not keeps
// none.
@(private = "file")
take_all :: proc(
	g: ^Atlas_Grid,
	takers: []Atlas_Taker,
	sizes: []int,
	order: []int,
	slots: [][6]Atlas_Slot,
) -> bool {
	all := true
	for i in order {
		if sizes[i] == 0 {
			continue
		}
		for face in 0 ..< takers[i].faces {
			slot, ok := atlas_take(g, sizes[i])
			if !ok {
				for taken in slots[i][:face] {
					atlas_mark(g, taken, false)
				}
				slots[i] = {}
				all = false
				break
			}
			slots[i][face] = slot
		}
	}
	return all
}
