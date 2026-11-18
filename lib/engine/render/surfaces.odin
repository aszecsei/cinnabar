package render

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"

import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Patch surfaces (see docs/rendering/surfaces.md#surfaces): a Surface_Renderer's rectangle, drawn as a quadtree of grid
// patches that the GPU picks by their distance from the camera, with holes where its mask reads 0, and a material
// whose displacement gives the surface its shape: water, terrain. The surface is one draw item whose draws the GPU
// adds: select_patches.hlsl walks the quadtree, and cull_patches.hlsl tests each patch against each view and writes
// its draw into the item's bin. material_patch.hlsli builds the patches' vertices.

// A patch is SURFACE_PATCH_QUADS quads on a side, drawn as SURFACE_PATCH_VERTICES vertices without an index buffer.
// Match the defines in material_patch.hlsli, select_patches.hlsl and cull_patches.hlsl.
SURFACE_PATCH_QUADS :: 16
SURFACE_PATCH_VERTICES :: SURFACE_PATCH_QUADS * SURFACE_PATCH_QUADS * 6
// The quadtree's depth, so a surface spans at most 16 × 2^11 finest cells on a side.
MAX_SURFACE_LEVELS :: 12
// The patches that a surface may draw in a frame: the item reserves this many draws in its bin.
MAX_SURFACE_PATCHES :: 2048
MAX_SURFACES :: 16
// How many pixels a finest cell covers where its level gives way to the next: Quality.lod_error scales it, as it
// scales the meshlets' errors.
SURFACE_CELL_PIXELS :: 8
// The finest cell's size in meters when a Surface_Renderer leaves cell at 0.
DEFAULT_SURFACE_CELL :: format.DEFAULT_SURFACE_CELL
// select_patches.hlsl's group size.
SURFACE_GROUP_SIZE :: 256
// Where a level's morph to the next starts, as a share of its range.
SURFACE_MORPH_START :: 0.7

// The engine's patch shaders (lib/engine/content/shaders), by their .meta files.
SELECT_PATCHES_SHADER :: #load("../content/shaders/select_patches.hlsl.meta", string)
CULL_PATCHES_SHADER :: #load("../content/shaders/cull_patches.hlsl.meta", string)

// Surface_Record matches Surface_Record in material_patch.hlsli, select_patches.hlsl and cull_patches.hlsl: a surface
// as the frame draws it, in the upload ring. Lengths are in the surface's own space, whose x and z the rectangle
// spans about its origin. root_origin is the quadtree's corner, the rectangle's least corner, and root_size the root
// node's side, SURFACE_PATCH_QUADS finest cells times 2^(levels - 1), which covers the rectangle. range0 is level 0's
// range: a node of level L splits while it is nearer the camera than range0 × 2^(L - 1). camera_local is the camera
// in the surface's space. hole_mask is the mask's bindless index, or the white default's. item is the surface's
// Cull_Item, whose bin, material and flags the patches' draws take.
Surface_Record :: struct {
	size:         [2]f32,
	cell:         f32,
	levels:       u32,
	root_origin:  [2]f32,
	root_size:    f32,
	range0:       f32,
	camera_local: [3]f32,
	hole_mask:    u32,
	height_range: [2]f32,
	bound:        f32,
	item:         u32,
	padding:      [4]u32,
}

#assert(size_of(Surface_Record) == 80)

// surface_record is a surface's record for the frame: the quadtree over its rectangle, its level 0 range for the
// camera's level of detail (see lod_scale), and the camera in its space, from its instance's rows, which are relative
// to the render origin, as camera is.
surface_record :: proc(
	sr: Surface_Renderer,
	rows: [3][4]f32,
	camera: [3]f32,
	lod: f32,
	hole_mask: u32,
	bound: f32,
) -> Surface_Record {
	cell := sr.cell > 0 ? sr.cell : DEFAULT_SURFACE_CELL
	size := [2]f32{max(sr.size.x, cell), max(sr.size.y, cell)}
	patch := cell * SURFACE_PATCH_QUADS
	levels := int(math.ceil(math.log2(max(size.x, size.y) / patch))) + 1
	levels = clamp(levels, 1, MAX_SURFACE_LEVELS)
	m := matrix[3, 3]f32{
		rows[0].x, rows[0].y, rows[0].z,
		rows[1].x, rows[1].y, rows[1].z,
		rows[2].x, rows[2].y, rows[2].z,
	}
	offset := camera - [3]f32{rows[0].w, rows[1].w, rows[2].w}
	local := offset
	if abs(linalg.determinant(m)) > 1e-12 {
		local = linalg.inverse(m) * offset
	}
	// A cell gives way to the next level where it covers SURFACE_CELL_PIXELS pixels, but at least a patch away, and
	// near enough that every level's ring of patches fits the item's reserved draws.
	range_cap := patch * math.sqrt(f32(MAX_SURFACE_PATCHES) / (3 * f32(levels)))
	range0 := clamp(cell * lod / SURFACE_CELL_PIXELS, patch, range_cap)
	return {
		size = size,
		cell = cell,
		levels = u32(levels),
		root_origin = -size * 0.5,
		root_size = patch * f32(u32(1) << u32(levels - 1)),
		range0 = range0,
		camera_local = local,
		hole_mask = hole_mask,
		height_range = {
			min(sr.height_range.x, sr.height_range.y),
			max(sr.height_range.x, sr.height_range.y),
		},
		bound = bound,
	}
}

// A patch, as select_patches.hlsl packs it: its column, its row and its level. The virtual shadow map's walk also sets 4
// edge bits above them, one for each edge whose neighbour is coarser (see surface_patch_edges).
surface_patch_pack :: proc "contextless" (x, y, level: u32) -> u32 {
	return x | y << 12 | level << 24
}

surface_patch_unpack :: proc "contextless" (p: u32) -> (x, y, level: u32) {
	return p & 0xfff, (p >> 12) & 0xfff, (p >> 24) & 0xf
}

// SURFACE_EDGE_SHIFT is where a patch's edge bits start. Bit i is set when the neighbour across the edge is coarser: the
// -x, +x, -z and +z edges, as material_patch.hlsli snaps their vertices.
SURFACE_EDGE_SHIFT :: 28

surface_patch_edges :: proc "contextless" (p: u32) -> u32 {
	return p >> SURFACE_EDGE_SHIFT
}

// surface_patch_distance is the distance from the camera in the surface's space to a node's box: its square on the
// plane, and its height range, as select_patches.hlsl measures it.
surface_patch_distance :: proc(s: Surface_Record, x, y, level: u32) -> f32 {
	size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
	lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
	hi := lo + size
	nearest := [3]f32 {
		clamp(s.camera_local.x, lo.x, hi.x),
		clamp(s.camera_local.y, s.height_range.x, s.height_range.y),
		clamp(s.camera_local.z, lo.y, hi.y),
	}
	return linalg.length(s.camera_local - nearest)
}

// select_patches_reference is select_patches.hlsl's walk on the CPU, for the tests and for tools: the patches that
// the surface draws this frame, as the shader packs them. A node of level L splits while it is nearer the camera than
// range0 × 2^(L - 1), a node outside the rectangle is dropped, and a node that the reserved draws cannot hold draws as
// it is.
select_patches_reference :: proc(s: Surface_Record, allocator := context.allocator) -> []u32 {
	patches := make([dynamic]u32, allocator)
	queue := make([dynamic]u32, context.temp_allocator)
	next := make([dynamic]u32, context.temp_allocator)
	append(&queue, surface_patch_pack(0, 0, s.levels - 1))
	half := s.size * 0.5
	for level := int(s.levels) - 1; level >= 0; level -= 1 {
		clear(&next)
		for node in queue {
			x, y, _ := surface_patch_unpack(node)
			size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << u32(level))
			lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
			hi := lo + size
			if hi.x <= -half.x || hi.y <= -half.y || lo.x >= half.x || lo.y >= half.y {
				continue
			}
			split :=
				level > 0 &&
				surface_patch_distance(s, x, y, u32(level)) <
					s.range0 * f32(u32(1) << u32(level - 1))
			if split && len(next) + 4 > MAX_SURFACE_PATCHES {
				split = false
			}
			if split {
				append(
					&next,
					surface_patch_pack(2 * x, 2 * y, u32(level - 1)),
					surface_patch_pack(2 * x + 1, 2 * y, u32(level - 1)),
				)
				append(
					&next,
					surface_patch_pack(2 * x, 2 * y + 1, u32(level - 1)),
					surface_patch_pack(2 * x + 1, 2 * y + 1, u32(level - 1)),
				)
			} else if len(patches) < MAX_SURFACE_PATCHES {
				append(&patches, node)
			}
		}
		queue, next = next, queue
	}
	return patches[:]
}

// Surface_Levels are the virtual shadow map's levels as the surfaces' shadow walk reads them: the page table, each
// level's culling planes and page fields (see virtual_page_fields), and a flag for each tile of SURFACE_TILE_PAGES pages
// on a side of each level that has a page that the frame draws (see surface_levels), which a box over many pages tests in
// place of its pages.
Surface_Levels :: struct {
	table:  []u32,
	planes: [][6][4]f32,
	fields: []u32,
	tiles:  []bool,
}

// A tile of pages, as select_patches.hlsl sets them in its group's memory.
SURFACE_TILE_PAGES :: 8
SURFACE_TILES_WIDE :: VIRTUAL_PAGES / SURFACE_TILE_PAGES

// surface_levels is the levels of a frame, with their tiles of drawn pages.
surface_levels :: proc(
	table: []u32,
	planes: [][6][4]f32,
	fields: []u32,
	allocator := context.allocator,
) -> Surface_Levels {
	levels := Surface_Levels {
		table  = table,
		planes = planes,
		fields = fields,
		tiles  = make([]bool, len(planes) * SURFACE_TILES_WIDE * SURFACE_TILES_WIDE, allocator),
	}
	for level in 0 ..< len(planes) {
		origin := [2]i32{i32((fields[level] >> 18) & 0x7f), i32((fields[level] >> 25) & 0x7f)}
		for tile in 0 ..< SURFACE_TILES_WIDE * SURFACE_TILES_WIDE {
			low :=
				[2]i32{i32(tile % SURFACE_TILES_WIDE), i32(tile / SURFACE_TILES_WIDE)} *
				SURFACE_TILE_PAGES
			for y in 0 ..< i32(SURFACE_TILE_PAGES) {
				for x in 0 ..< i32(SURFACE_TILE_PAGES) {
					if virtual_entry_draws(
						table[virtual_table_slot(level, origin + low + {x, y})],
					) {
						levels.tiles[level * SURFACE_TILES_WIDE * SURFACE_TILES_WIDE + tile] = true
					}
				}
			}
		}
	}
	return levels
}

// surface_rect_draws is whether pages from low to high of a level, by their places in its valid rectangle, have a page
// that the frame draws: its pages, when the rectangle spans fewer than VIRTUAL_CULL_PAGES on each side, and its tiles of
// pages when it spans more. A rectangle inside another that is tested by tiles is tested by tiles too, so a box inside a
// box never reaches a finer level. Matches shadow_rect_draws in select_patches.hlsl.
surface_rect_draws :: proc(levels: Surface_Levels, level: int, low, high: [2]i32) -> bool {
	origin := [2]i32 {
		i32((levels.fields[level] >> 18) & 0x7f),
		i32((levels.fields[level] >> 25) & 0x7f),
	}
	first := [2]i32{max(low.x, 0), max(low.y, 0)}
	last := [2]i32{min(high.x, VIRTUAL_PAGES - 1), min(high.y, VIRTUAL_PAGES - 1)}
	if first.x > last.x || first.y > last.y {
		return false
	}
	if last.x - first.x >= VIRTUAL_CULL_PAGES || last.y - first.y >= VIRTUAL_CULL_PAGES {
		per_level := SURFACE_TILES_WIDE * SURFACE_TILES_WIDE
		for ty in first.y / SURFACE_TILE_PAGES ..= last.y / SURFACE_TILE_PAGES {
			for tx in first.x / SURFACE_TILE_PAGES ..= last.x / SURFACE_TILE_PAGES {
				if levels.tiles[level * per_level + int(ty) * SURFACE_TILES_WIDE + int(tx)] {
					return true
				}
			}
		}
		return false
	}
	for y in first.y ..= last.y {
		for x in first.x ..= last.x {
			if virtual_entry_draws(levels.table[virtual_table_slot(level, origin + {x, y})]) {
				return true
			}
		}
	}
	return false
}

// surface_scale is the largest scale of an instance's axes.
surface_scale :: proc(rows: [3][4]f32) -> f32 {
	return max(
		linalg.length([3]f32{rows[0].x, rows[1].x, rows[2].x}),
		linalg.length([3]f32{rows[0].y, rows[1].y, rows[2].y}),
		linalg.length([3]f32{rows[0].z, rows[1].z, rows[2].z}),
	)
}

// surface_box_texel is the texel in meters of the finest level whose drawn pages a box of the surface reaches, or 0 when
// it reaches none: the box over a square of the surface's plane, from its center, and between the surface's heights,
// grown by the displacement bound, as the levels' own axes see it. rows are the surface's instance, relative to the
// camera. A coarser level's texel is larger, so the finest holds every level's. The box's extent along a level's axes is
// exact, so a box inside another reaches no finer level than it does, which keeps the walk's tree balanced. Matches
// shadow_box_texel in select_patches.hlsl.
surface_box_texel :: proc(
	levels: Surface_Levels,
	s: Surface_Record,
	rows: [3][4]f32,
	bound: f32,
	center: [2]f32,
	half_size: f32,
) -> f32 {
	local := [3]f32{center.x, (s.height_range.x + s.height_range.y) * 0.5, center.y}
	extent := [3]f32{half_size, (s.height_range.y - s.height_range.x) * 0.5, half_size}
	world: [3]f32
	axes: [3][3]f32
	for row, k in rows {
		world[k] = row.x * local.x + row.y * local.y + row.z * local.z + row.w
		axes[0][k], axes[1][k], axes[2][k] = row.x, row.y, row.z
	}
	for level in 0 ..< len(levels.planes) {
		planes := levels.planes[level]
		n0, n1 := planes[0].xyz, planes[3].xyz
		page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
		at :=
			[2]f32{linalg.dot(n0, world) + planes[0].w, linalg.dot(n1, world) + planes[3].w} / page
		along: [2]f32
		for axis, k in axes {
			along.x += abs(linalg.dot(n0, axis)) * extent[k]
			along.y += abs(linalg.dot(n1, axis)) * extent[k]
		}
		reach := (along + bound) / page + 1.0 / VIRTUAL_PAGE_TEXELS
		fields := levels.fields[level]
		first := [2]i32{i32((fields >> 4) & 0x7f), i32((fields >> 11) & 0x7f)}
		low := first + [2]i32{i32(math.floor(at.x - reach.x)), i32(math.floor(at.y - reach.y))}
		high := first + [2]i32{i32(math.floor(at.x + reach.x)), i32(math.floor(at.y + reach.y))}
		if surface_rect_draws(levels, level, low, high) {
			return f32(virtual_level_texel(level))
		}
	}
	return 0
}

// surface_shadow_splits is whether a node splits in the virtual shadow map's walk: its child's cell, in the world, covers
// more than SURFACE_CELL_PIXELS texels of the finest level that the node's box, grown by its size on each side, reaches.
// A node that reaches no page does not split. The grown box keeps the tree 2:1 balanced: a leaf that does not split
// grows a box that holds the grown box of any finer node beside it, so no node beside it splits twice. Matches
// shadow_splits in select_patches.hlsl.
surface_shadow_splits :: proc(
	s: Surface_Record,
	rows: [3][4]f32,
	bound: f32,
	levels: Surface_Levels,
	x, y, level: u32,
) -> bool {
	if level == 0 {
		return false
	}
	size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << level)
	center := s.root_origin + ([2]f32{f32(x), f32(y)} + 0.5) * size
	texel := surface_box_texel(levels, s, rows, bound, center, size * 1.5)
	child := s.cell * f32(u32(1) << (level - 1)) * surface_scale(rows)
	return texel > 0 && child > SURFACE_CELL_PIXELS * texel
}

// surface_shadow_edges are a node's edge bits (see SURFACE_EDGE_SHIFT): the neighbour across an edge is coarser when it
// is a leaf of the next level, which the node's parent's neighbour is when it does not split. Matches shadow_edges in
// select_patches.hlsl.
surface_shadow_edges :: proc(
	s: Surface_Record,
	rows: [3][4]f32,
	bound: f32,
	levels: Surface_Levels,
	x, y, level: u32,
) -> (
	edges: u32,
) {
	if level + 1 >= s.levels {
		return 0
	}
	grid := i32(1) << (s.levels - 1 - level)
	half := s.size * 0.5
	for direction, i in ([4][2]i32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
		n := [2]i32{i32(x), i32(y)} + direction
		if n.x < 0 || n.y < 0 || n.x >= grid || n.y >= grid {
			continue
		}
		parent := n / 2
		own := [2]i32{i32(x) / 2, i32(y) / 2}
		if parent == own {
			continue
		}
		size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << (level + 1))
		lo := s.root_origin + [2]f32{f32(parent.x), f32(parent.y)} * size
		hi := lo + size
		if hi.x <= -half.x || hi.y <= -half.y || lo.x >= half.x || lo.y >= half.y {
			continue
		}
		if !surface_shadow_splits(
			s,
			rows,
			bound,
			levels,
			u32(parent.x),
			u32(parent.y),
			level + 1,
		) {
			edges |= 1 << u32(i)
		}
	}
	return
}

// select_patches_shadow_reference is the virtual shadow map's walk (select_patches.hlsl with shadow_levels) on the CPU,
// for the tests: the patches that its levels draw, with their edge bits. A node that reaches no drawn page is dropped.
// Nothing here depends on the camera. rows are the surface's instance, relative to the camera, and bound the item's
// displacement bound.
select_patches_shadow_reference :: proc(
	s: Surface_Record,
	rows: [3][4]f32,
	bound: f32,
	levels: Surface_Levels,
	allocator := context.allocator,
) -> []u32 {
	patches := make([dynamic]u32, allocator)
	queue := make([dynamic]u32, context.temp_allocator)
	next := make([dynamic]u32, context.temp_allocator)
	append(&queue, surface_patch_pack(0, 0, s.levels - 1))
	half := s.size * 0.5
	for level := int(s.levels) - 1; level >= 0; level -= 1 {
		clear(&next)
		for node in queue {
			x, y, _ := surface_patch_unpack(node)
			size := s.cell * SURFACE_PATCH_QUADS * f32(u32(1) << u32(level))
			lo := s.root_origin + [2]f32{f32(x), f32(y)} * size
			hi := lo + size
			if hi.x <= -half.x || hi.y <= -half.y || lo.x >= half.x || lo.y >= half.y {
				continue
			}
			if surface_box_texel(levels, s, rows, bound, (lo + hi) * 0.5, size * 0.5) == 0 {
				continue
			}
			split := surface_shadow_splits(s, rows, bound, levels, x, y, u32(level))
			if split && len(next) + 4 > MAX_SURFACE_PATCHES {
				split = false
			}
			if split {
				append(
					&next,
					surface_patch_pack(2 * x, 2 * y, u32(level - 1)),
					surface_patch_pack(2 * x + 1, 2 * y, u32(level - 1)),
				)
				append(
					&next,
					surface_patch_pack(2 * x, 2 * y + 1, u32(level - 1)),
					surface_patch_pack(2 * x + 1, 2 * y + 1, u32(level - 1)),
				)
			} else if len(patches) < MAX_SURFACE_PATCHES {
				edges := surface_shadow_edges(s, rows, bound, levels, x, y, u32(level))
				append(&patches, node | edges << SURFACE_EDGE_SHIFT)
			}
		}
		queue, next = next, queue
	}
	return patches[:]
}

// Surface_Signature is what a surface's shadow depends on that its sphere and its bin do not show: its fields, and the
// versions of its maps, which change when the editor paints them or a recook writes them.
@(private = "file")
Surface_Signature :: struct {
	size:         [2]f32,
	height_range: [2]f32,
	cell:         f32,
	versions:     [3]u32,
	material:     format.Guid,
	hole_mask:    format.Guid,
	hole_ready:   bool,
	cast_shadows: bool,
}

// surface_map_versions are the versions of a surface's height map, hole mask and layer map, 0 for a map that is not
// loaded: set_live and a recook give each a new one (see asset.set_live).
@(private)
surface_map_versions :: proc(assets: ^asset.Assets, sr: Surface_Renderer) -> (versions: [3]u32) {
	if assets == nil {
		return
	}
	for guid, i in ([3]format.Guid{sr.height_map, sr.hole_mask, sr.layer_map}) {
		if guid == {} {
			continue
		}
		if h, loaded := asset.find(assets, guid); loaded {
			versions[i] = asset.version(assets, h)
		}
	}
	return
}

// surface_signature is a hash of what a surface's shadow depends on that its sphere and its bin do not show: it is the
// surface item's list, which the caster tracking's signature takes (see caster_bounds), so an edit of the maps or of a
// field drops the pages under the surface in both shadow caches. hole_ready is whether its hole mask is resident.
@(private)
surface_signature :: proc(sr: Surface_Renderer, versions: [3]u32, hole_ready: bool) -> u32 {
	fields: Surface_Signature
	fields.size, fields.height_range, fields.cell = sr.size, sr.height_range, sr.cell
	fields.versions = versions
	fields.material, fields.hole_mask = sr.material, sr.hole_mask
	fields.hole_ready, fields.cast_shadows = hole_ready, sr.cast_shadows
	return hash.fnv32a(mem.ptr_to_bytes(&fields))
}

// bin_sizes gives each bin's draws, which a surface's item reserves MAX_SURFACE_PATCHES of, each bin's first draw,
// and the draws of one view, which the frame's draw buffers hold for every view.
@(private)
bin_sizes :: proc(
	items: []Cull_Item,
	bins: int,
	allocator := context.allocator,
) -> (
	counts, offsets: []u32,
	per_view: int,
) {
	counts = make([]u32, max(bins, 1), allocator)
	offsets = make([]u32, max(bins, 1), allocator)
	for item in items {
		counts[item.bin] += item.flags & ITEM_SURFACE != 0 ? MAX_SURFACE_PATCHES : 1
	}
	for b in 1 ..< bins {
		offsets[b] = offsets[b - 1] + counts[b - 1]
	}
	for c in counts {
		per_view += int(c)
	}
	return
}

// surface_extractor selects the entities with a Surface_Renderer.
@(private)
surface_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Surface_Renderer)})
}

// use_surface_material gives a patches material as the frame draws it: the surface's, or the engine's default surface
// material (lib/engine/content/materials/default_surface.material) when the surface has none or its material draws
// meshes or cannot draw. It fails only when the default cannot draw either.
@(private)
use_surface_material :: proc(
	r: ^Renderer,
	table: ^Material_Table,
	guid: format.Guid,
) -> (
	use: Material_Use,
	ok: bool,
) {
	wanted := guid if guid != {} else r.materials.default_surface_guid
	use, ok = use_material(r, table, wanted)
	if ok &&
	   !r.materials.pipelines[use.pipeline].patches &&
	   wanted != r.materials.default_surface_guid {
		use, ok = use_material(r, table, r.materials.default_surface_guid)
	}
	if ok && !r.materials.pipelines[use.pipeline].patches {
		return {}, false
	}
	return
}

// add_surface adds a surface's item, which reserves its patches' draws in its material's bin, and its record. The
// item's sphere is its rectangle's and its height range's, in the surface's space, which culling scales by its
// instance and grows by the material's displacement bound. Its record's item is set once the bins are sorted.
@(private)
add_surface :: proc(
	r: ^Renderer,
	table: ^Material_Table,
	items: ^[dynamic]Cull_Item,
	surfaces: ^[dynamic]Surface_Record,
	sr: Surface_Renderer,
	slot: u32,
	rows: [3][4]f32,
	camera: [3]f32,
	lod: f32,
) {
	use, ok := use_surface_material(r, table, sr.material)
	if !ok {
		return
	}
	pipeline := &r.materials.pipelines[use.pipeline]
	flags: u32 = ITEM_SURFACE
	if sr.cast_shadows && pipeline.cast_shadows {
		flags |= ITEM_CASTS_SHADOWS
	}
	hole := gpu.read_index(r.materials.defaults[.White])
	hole_ready := false
	if sr.hole_mask != {} {
		if texture, ready := resident_texture(&r.residency, sr.hole_mask); ready {
			hole, hole_ready = gpu.read_index(texture.texture), true
		} else {
			table.waiting = true
		}
	}
	record := surface_record(sr, rows, camera, lod, hole, pipeline.displacement_bound)
	extent := [3]f32 {
		record.size.x * 0.5,
		(record.height_range.y - record.height_range.x) * 0.5,
		record.size.y * 0.5,
	}
	append(
		items,
		Cull_Item {
			instance = slot,
			mesh     = u32(len(surfaces)),
			first    = 0,
			count    = SURFACE_PATCH_VERTICES,
			material = use.block,
			bin      = u32(use.pipeline),
			flags    = flags,
			submesh  = 0,
			sphere   = {
				0,
				(record.height_range.x + record.height_range.y) * 0.5,
				0,
				linalg.length(extent),
			},
			bound    = pipeline.displacement_bound,
			// What the surface's shadow depends on that nothing else of the item shows: the caster tracking's signature
			// takes it, so an edit of the maps or of a field changes the caster (see surface_signature).
			list     = surface_signature(
				sr,
				surface_map_versions(r.residency.assets, sr),
				hole_ready,
			),
		},
	)
	append(surfaces, record)
}

// preview_surface is the surface that a material preview draws a patches material on: one patch, a meter across, at
// the mesh's place, at level 0 and without a morph.
@(private)
preview_surface :: proc(r: ^Renderer, bound: f32) -> Surface_Record {
	return {
		size = {1, 1},
		cell = 1.0 / SURFACE_PATCH_QUADS,
		levels = 1,
		root_origin = {-0.5, -0.5},
		root_size = 1,
		range0 = 1e9,
		camera_local = {0, 1, 0},
		hole_mask = gpu.read_index(r.materials.defaults[.White]),
		bound = bound,
	}
}

@(private = "file")
select_patches :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.select_pipeline.pipeline
	if len(sf.surfaces) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.cull_constants)
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.surfaces)), 1, 1})
}

@(private = "file")
select_shadow_patches :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.select_pipeline.pipeline
	if len(sf.surfaces) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.shadow_select)
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.surfaces)), 1, 1})
}

// surface_levels_count is how many levels the frame's virtual shadow map has, 0 without it.
@(private = "file")
surface_levels_count :: proc(f: ^Frame) -> int {
	return f.shadows.virtual.count if f.shadows != nil else 0
}

// The camera's views take a dispatch of the patch culling, which skips the virtual shadow map's levels, and the levels
// take one of their own once their page table is written, with the constants that tell which patches they read.
@(private = "file")
cull_patches :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.cull_patches_pipeline.pipeline
	if len(sf.surfaces) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.cull_constants)
	gpu.cmd_dispatch(
		ctx.cb,
		{
			MAX_SURFACE_PATCHES / CULL_GROUP_SIZE,
			u32(len(sf.surfaces)),
			u32(sf.view_count - surface_levels_count(f)),
		},
	)
}

@(private = "file")
cull_virtual_patches :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.cull_patches_pipeline.pipeline
	if len(sf.surfaces) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.virtual_cull)
	gpu.cmd_dispatch(
		ctx.cb,
		{
			MAX_SURFACE_PATCHES / CULL_GROUP_SIZE,
			u32(len(sf.surfaces)),
			u32(surface_levels_count(f)),
		},
	)
}

// add_select_patches_pass imports the patches' buffers and adds the selection, which walks each surface's quadtree,
// after the scene's update and before the draw culling. It adds nothing without surfaces.
@(private)
add_select_patches_pass :: proc(f: ^Frame) -> (p: Pass, added: bool) {
	sf := f.scene_frame
	g := f.graph
	s := &f.renderer.scene
	sf.patches = import_buffer(g, s.patches)
	sf.patch_counts = import_buffer(g, s.patch_counts)
	if len(sf.surfaces) == 0 {
		return
	}
	p = add_compute_pass(g, "select patches", select_patches, f)
	write(g, p, sf.patches)
	write(g, p, sf.patch_counts)
	return p, true
}

// add_cull_patches_pass adds the patch culling, which writes the patches' draws into the bins, after the draw culling.
// It leaves the virtual shadow map's levels to add_shadow_cull_patches_pass.
@(private)
add_cull_patches_pass :: proc(f: ^Frame) -> (p: Pass, added: bool) {
	sf := f.scene_frame
	g := f.graph
	if len(sf.surfaces) == 0 || sf.view_count == surface_levels_count(f) {
		return
	}
	p = add_compute_pass(g, "cull patches", cull_patches, f)
	read(g, p, sf.instances)
	read(g, p, sf.patches)
	read(g, p, sf.patch_counts)
	write(g, p, sf.arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
	return p, true
}

// surface_shadow_constants makes the virtual shadow map's patch walk's constants, from the camera's, and points the
// levels' constants at what it writes. It says whether the levels take the walk; without it they take the camera's
// patches. The levels are the views from FIRST_SHADOW_VIEW in the culling views.
@(private)
surface_shadow_constants :: proc(
	f: ^Frame,
	cull: Cull_Constants,
	levels: ^Cull_Constants,
) -> bool {
	sf := f.scene_frame
	s := &f.renderer.scene
	count := surface_levels_count(f)
	if len(sf.surfaces) == 0 ||
	   count == 0 ||
	   s.shadow_patches == {} ||
	   s.shadow_patch_counts == {} {
		return false
	}
	walk := cull
	walk.view_first, walk.view_skip, walk.shadow_levels = FIRST_SHADOW_VIEW, 0, u32(count)
	walk.patches, walk.patch_counts =
		gpu.write_index(s.shadow_patches), gpu.write_index(s.shadow_patch_counts)
	ok: bool
	sf.shadow_select, ok = f.renderer.platform.gpu_upload(
		size_of(Cull_Constants),
		gpu.PASS_CONSTANTS_ALIGN,
	)
	if !ok {
		return false
	}
	(^Cull_Constants)(raw_data(sf.shadow_select.data))^ = walk
	levels.patches_read, levels.patch_counts_read =
		gpu.read_index(s.shadow_patches), gpu.read_index(s.shadow_patch_counts)
	levels.shadow_levels = u32(count)
	sf.shadow_patches = import_buffer(f.graph, s.shadow_patches)
	sf.shadow_counts = import_buffer(f.graph, s.shadow_patch_counts)
	return true
}

// add_shadow_select_patches_pass adds the virtual shadow map's patch walk, once the page table is written and before its
// levels cull. It adds nothing when the levels take the camera's patches.
@(private)
add_shadow_select_patches_pass :: proc(f: ^Frame, table: Buffer) {
	sf := f.scene_frame
	if sf.shadow_patches == 0 {
		return
	}
	g := f.graph
	p := add_compute_pass(g, "select shadow patches", select_shadow_patches, f)
	read(g, p, sf.instances)
	read(g, p, table)
	write(g, p, sf.shadow_patches)
	write(g, p, sf.shadow_counts)
}

// add_shadow_cull_patches_pass adds the virtual shadow map's levels' patch culling, which writes their patches' draws
// into the bins, after their draw culling: the walk's patches, or the camera's without it.
@(private)
add_shadow_cull_patches_pass :: proc(f: ^Frame) {
	sf := f.scene_frame
	if len(sf.surfaces) == 0 || surface_levels_count(f) == 0 {
		return
	}
	g := f.graph
	p := add_compute_pass(g, "cull virtual shadow patches", cull_virtual_patches, f)
	read(g, p, sf.instances)
	if sf.shadow_patches != 0 {
		read(g, p, sf.shadow_patches)
		read(g, p, sf.shadow_counts)
	} else {
		read(g, p, sf.patches)
		read(g, p, sf.patch_counts)
	}
	write(g, p, sf.arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
}
