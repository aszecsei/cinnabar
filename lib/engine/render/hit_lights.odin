package render

import "core:log"
import "core:math"
import "core:slice"

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The light grid of the hits' light (see docs/rendering/global-illumination.md#world-probes): the punctual lights by
// the cells of world space that their spheres touch, so a hit anywhere finds the lights that can reach it, and the hits'
// light picks one of them by resampled importance sampling (gi_light_sampling.hlsli). Each level is a window of
// LIGHT_GRID_WINDOW cells on each axis around the camera, of 2^(1 + level) meters, and a light is listed at the first
// level whose cells are at least as wide as its sphere, in each cell of that level that its sphere touches, at most 8.
// A light that no level's window holds, as one too large for the last level's cells, is in the global list, which
// every hit sees. So no light that can reach a hit is left out of its candidates, which would bias the estimate. The
// cells are keyed as the split cascades' probes are (split_key), and hashed into a linearly probed table.

LIGHT_GRID_LEVELS :: 6
// The most candidates that a hit weighs, whatever its level asks for. Match gi_light_sampling.hlsli.
MAX_HIT_CANDIDATES :: 16
// Each level's cells along each axis. Match gi_light_sampling.hlsli.
LIGHT_GRID_WINDOW :: 512
// The first level's cells are 2^LIGHT_GRID_SPACING meters.
LIGHT_GRID_SPACING :: 1
// A key's entry is at most this many steps from its hash. Match gi_light_sampling.hlsli.
LIGHT_GRID_PROBE_STEPS :: 32
// The table's entries: at least twice the cells, and at most this many.
MIN_LIGHT_GRID_ENTRIES :: 16
MAX_LIGHT_GRID_ENTRIES :: 65536
// A light's sphere is padded by this share of its level's cell, so float rounding in the shader cannot put a point in
// its sphere in a cell that does not list it.
LIGHT_GRID_PAD :: 1e-3

// Light_Grid_Header matches Light_Grid in gi_light_sampling.hlsli. levels' xyz are each level's first cell relative to
// the camera and w its cell's size. The offsets are in bytes from the header's.
Light_Grid_Header :: struct {
	levels:       [LIGHT_GRID_LEVELS][4]f32,
	table_mask:   u32,
	table_first:  u32,
	lists_first:  u32,
	global_first: u32,
	global_count: u32,
	padding:      [3]u32,
}

#assert(size_of(Light_Grid_Header) == 128)

// Light_Grid_Entry matches the table's entries in gi_light_sampling.hlsli: a cell's key, 0 for an empty entry, and its
// lights' place in the lists.
Light_Grid_Entry :: struct {
	key:   u32,
	first: u32,
	count: u32,
	_:     u32,
}

// Light_Grid is a frame's light grid, in frame memory: the header, the table and the lights' indices, which the global
// list ends.
Light_Grid :: struct {
	header: Light_Grid_Header,
	table:  []Light_Grid_Entry,
	lists:  []u32,
}

@(private = "file")
Grid_Pair :: struct {
	key:   u32,
	light: u32,
}

// light_grid_level_min is a level's first cell relative to the camera, in meters, from whole units, and that cell.
light_grid_level_min :: proc(camera: ecs.World_Position, level: int) -> [3]f32 {
	spacing := u32(LIGHT_GRID_SPACING + level)
	cell := probe_cell(camera, spacing) - LIGHT_GRID_WINDOW / 2
	return probe_level_min(cell, camera, spacing)
}

// build_light_grid lists the punctual lights of a frame's records by the cells that their spheres touch, around the
// camera. The records' positions are relative to the camera, and the indices are the records'.
build_light_grid :: proc(
	records: []Light_Record,
	camera: ecs.World_Position,
	allocator := context.allocator,
) -> (
	grid: Light_Grid,
) {
	pairs := make([dynamic]Grid_Pair, allocator)
	global := make([dynamic]u32, allocator)
	for level in 0 ..< LIGHT_GRID_LEVELS {
		min := light_grid_level_min(camera, level)
		grid.header.levels[level] = {
			min.x,
			min.y,
			min.z,
			f32(u32(1) << u32(LIGHT_GRID_SPACING + level)),
		}
	}
	for record, i in records {
		if record.type == .Directional ||
		   record.range <= 0 ||
		   max(record.color.r, record.color.g, record.color.b) <= 0 {
			continue
		}
		placed := false
		for level in 0 ..< LIGHT_GRID_LEVELS {
			l := grid.header.levels[level]
			size := l.w
			if size < 2 * record.range {
				continue
			}
			reach := record.range + size * LIGHT_GRID_PAD
			lo, hi: [3]i64
			inside := true
			for axis in 0 ..< 3 {
				lo[axis] = i64(math.floor((record.position[axis] - reach - l[axis]) / size))
				hi[axis] = i64(math.floor((record.position[axis] + reach - l[axis]) / size))
				inside &&= lo[axis] >= 0 && hi[axis] < LIGHT_GRID_WINDOW
			}
			if !inside {
				continue
			}
			for z in lo.z ..= hi.z {
				for y in lo.y ..= hi.y {
					for x in lo.x ..= hi.x {
						key := split_key(u32(level), {u32(x), u32(y), u32(z)})
						append(&pairs, Grid_Pair{key, u32(i)})
					}
				}
			}
			placed = true
			break
		}
		if !placed {
			append(&global, u32(i))
		}
	}
	slice.sort_by(pairs[:], proc(a, b: Grid_Pair) -> bool {
		return a.key < b.key || (a.key == b.key && a.light < b.light)
	})
	cells := 0
	for p, i in pairs {
		if i == 0 || p.key != pairs[i - 1].key {
			cells += 1
		}
	}
	size := max(next_power_of_two_u32(u32(2 * cells)), MIN_LIGHT_GRID_ENTRIES)
	for {
		table, ok := fill_light_grid_table(pairs[:], size, allocator)
		if ok {
			grid.table = table
			break
		}
		if size >= MAX_LIGHT_GRID_ENTRIES {
			// Too many cells for the table: every light is global, which is slower but leaves none out.
			log.warnf(
				"render: the light grid's %d cells do not fit its table; every light is global",
				cells,
			)
			clear(&pairs)
			clear(&global)
			for record, i in records {
				if record.type != .Directional && record.range > 0 {
					append(&global, u32(i))
				}
			}
			grid.table = make([]Light_Grid_Entry, MIN_LIGHT_GRID_ENTRIES, allocator)
			size = MIN_LIGHT_GRID_ENTRIES
			break
		}
		size *= 2
	}
	lists := make([]u32, len(pairs) + len(global), allocator)
	for p, i in pairs {
		lists[i] = p.light
	}
	copy(lists[len(pairs):], global[:])
	grid.lists = lists
	grid.header.table_mask = size - 1
	grid.header.table_first = size_of(Light_Grid_Header)
	grid.header.lists_first = grid.header.table_first + size * size_of(Light_Grid_Entry)
	grid.header.global_first = u32(len(pairs))
	grid.header.global_count = u32(len(global))
	return
}

// fill_light_grid_table puts each cell of the sorted pairs into a table of size entries, and is false when a key would
// be more than LIGHT_GRID_PROBE_STEPS from its hash.
@(private = "file")
fill_light_grid_table :: proc(
	pairs: []Grid_Pair,
	size: u32,
	allocator := context.allocator,
) -> (
	table: []Light_Grid_Entry,
	ok: bool,
) {
	table = make([]Light_Grid_Entry, size, allocator)
	mask := size - 1
	for i := 0; i < len(pairs); {
		key := pairs[i].key
		first := i
		for i < len(pairs) && pairs[i].key == key {
			i += 1
		}
		at := split_hash(key) & mask
		placed := false
		for _ in 0 ..< LIGHT_GRID_PROBE_STEPS {
			if table[at].key == 0 {
				table[at] = {
					key   = key,
					first = u32(first),
					count = u32(i - first),
				}
				placed = true
				break
			}
			at = (at + 1) & mask
		}
		if !placed {
			delete(table, allocator)
			return nil, false
		}
	}
	return table, true
}

// light_grid_find is the entry of a cell's key, or nil when the table has none: the shader's lookup.
light_grid_find :: proc(grid: Light_Grid, key: u32) -> ^Light_Grid_Entry {
	mask := grid.header.table_mask
	at := split_hash(key) & mask
	for _ in 0 ..< LIGHT_GRID_PROBE_STEPS {
		entry := &grid.table[at]
		if entry.key == key {
			return entry
		}
		if entry.key == 0 {
			return nil
		}
		at = (at + 1) & mask
	}
	return nil
}

// light_grid_lights are the lights that a point relative to the camera sees: those of its cell at each level whose
// window holds it, then the global list, as the shader finds them.
light_grid_lights :: proc(grid: Light_Grid, p: [3]f32, allocator := context.allocator) -> []u32 {
	found := make([dynamic]u32, allocator)
	for level in 0 ..< LIGHT_GRID_LEVELS {
		l := grid.header.levels[level]
		u: [3]i64
		inside := true
		for axis in 0 ..< 3 {
			u[axis] = i64(math.floor((p[axis] - l[axis]) / l.w))
			inside &&= u[axis] >= 0 && u[axis] < LIGHT_GRID_WINDOW
		}
		if !inside {
			continue
		}
		if entry := light_grid_find(grid, split_key(u32(level), {u32(u.x), u32(u.y), u32(u.z)}));
		   entry != nil {
			append(&found, ..grid.lists[entry.first:][:entry.count])
		}
	}
	g := grid.header
	append(&found, ..grid.lists[g.global_first:][:g.global_count])
	return found[:]
}

// light_grid_upload is the frame's light grid in the upload ring, made at its first request in the frame, or false
// when the upload fails.
@(private)
light_grid_upload :: proc(f: ^Frame) -> (gpu.Upload, bool) {
	lf := f.lights
	if lf.grid_made {
		return lf.grid, lf.grid.data != nil
	}
	lf.grid_made = true
	allocator := f.renderer.platform.frame_allocator
	grid := build_light_grid(lf.records[:], f.view.position, allocator)
	size := int(grid.header.lists_first) + len(grid.lists) * 4
	upload, ok := f.renderer.platform.gpu_upload(size, 16)
	if !ok {
		return {}, false
	}
	(^Light_Grid_Header)(raw_data(upload.data))^ = grid.header
	copy(
		upload.data[grid.header.table_first:],
		([^]byte)(raw_data(grid.table))[:len(grid.table) * size_of(Light_Grid_Entry)],
	)
	copy(
		upload.data[grid.header.lists_first:],
		([^]byte)(raw_data(grid.lists))[:len(grid.lists) * 4],
	)
	lf.grid = upload
	return upload, true
}

@(private = "file")
next_power_of_two_u32 :: proc(n: u32) -> u32 {
	p := u32(1)
	for p < n {
		p <<= 1
	}
	return p
}
