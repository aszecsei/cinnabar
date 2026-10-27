package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core/gpu"
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
DEFAULT_SURFACE_CELL :: 1
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

// A patch, as select_patches.hlsl packs it: its column, its row and its level.
surface_patch_pack :: proc "contextless" (x, y, level: u32) -> u32 {
	return x | y << 12 | level << 24
}

surface_patch_unpack :: proc "contextless" (p: u32) -> (x, y, level: u32) {
	return p & 0xfff, (p >> 12) & 0xfff, p >> 24
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
	if sr.hole_mask != {} {
		if texture, ready := resident_texture(&r.residency, sr.hole_mask); ready {
			hole = gpu.read_index(texture.texture)
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
			mesh = u32(len(surfaces)),
			first = 0,
			count = SURFACE_PATCH_VERTICES,
			material = use.block,
			bin = u32(use.pipeline),
			flags = flags,
			submesh = 0,
			sphere = {
				0,
				(record.height_range.x + record.height_range.y) * 0.5,
				0,
				linalg.length(extent),
			},
			bound = pipeline.displacement_bound,
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
		{MAX_SURFACE_PATCHES / CULL_GROUP_SIZE, u32(len(sf.surfaces)), u32(sf.view_count)},
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
@(private)
add_cull_patches_pass :: proc(f: ^Frame) -> (p: Pass, added: bool) {
	sf := f.scene_frame
	g := f.graph
	if len(sf.surfaces) == 0 {
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
