package render

import "core:mem"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Meshlet selection (see docs/rendering/gpu-scene.md#mesh-shader-path): before the draws are culled,
// select_meshlets.hlsl walks the trees over each level's groups of meshlets of each ITEM_HIERARCHY item, one group of
// threads an item, from the camera. A node whose error does not show has no meshlet below it that the camera draws, so
// the walk stops there, and a leaf whose error shows gives its group's meshlets. Those meshlets are a list in
// Meshlet_Select.selected, and the item's range of it is in Meshlet_Select.selections. cull_draws.hlsl gives the
// item's mesh draws that range, with DRAW_SELECTED, so its amplification shaders test those meshlets in place of all
// of its submesh's. Every view but the view model's takes the camera's level of detail, so one walk serves them all.

// SELECT_MESHLETS_SHADER is the walk (lib/engine/content/shaders/select_meshlets.hlsl), by its .meta file.
SELECT_MESHLETS_SHADER :: #load("../content/shaders/select_meshlets.hlsl.meta", string)
// The list of picked meshlets holds this many, 4 MB. An item whose meshlets it cannot hold tests all of them, as an
// item without a hierarchy does. Matches MAX_SELECTED_MESHLETS in select_meshlets.hlsl.
MAX_SELECTED_MESHLETS :: 1 << 20
// A dispatch row has this many of the walk's groups, under D3D12's limit of a dimension.
MESHLET_SELECT_ROW :: 32768

// Meshlet_Select is the selection's state between frames, in Gpu_Scene. selections has a counter of the list's
// meshlets in its first word, then a (first, count) pair for each item from its eighth byte; a count of
// SELECTION_NONE is an item that tests all of its meshlets.
Meshlet_Select :: struct {
	pipeline:   Shader_Pipeline,
	selections: gpu.Buffer,
	capacity:   int,
	selected:   gpu.Buffer,
}

// SELECTION_NONE matches SELECTION_NONE in select_meshlets.hlsl and cull_draws.hlsl.
SELECTION_NONE :: ~u32(0)

// Meshlet_Select_Frame is one frame's selection, in Scene_Frame: the ITEM_HIERARCHY items, by their index, and the
// graph's buffers, 0 when nothing walks.
@(private)
Meshlet_Select_Frame :: struct {
	items:      []u32,
	upload:     gpu.Upload,
	constants:  gpu.Upload,
	selections: Buffer,
	selected:   Buffer,
}

// Meshlet_Select_Constants matches Meshlet_Select_Constants in select_meshlets.hlsl. The items to walk, the draw
// items and the mesh records are in the upload ring, at these offsets of its buffer. camera, lod_scale and lod_near are
// the camera's, as in Cull_Constants.
@(private)
Meshlet_Select_Constants :: struct {
	camera:            [4]f32,
	lod_scale:         f32,
	lod_near:          f32,
	walk_count:        u32,
	walks:             u32,
	walks_offset:      u32,
	items:             u32,
	items_offset:      u32,
	meshes:            u32,
	meshes_offset:     u32,
	instances:         u32,
	selections:        u32,
	selected:          u32,
	stats:             u32,
	padding:           [3]u32,
}

#assert(size_of(Meshlet_Select_Constants) == 80)

meshlet_select_init :: proc(m: ^Meshlet_Select, platform: ^core.Platform_API) {
	m.pipeline = shader_pipeline(SELECT_MESHLETS_SHADER)
	m.selected = platform.gpu_create_buffer({size = MAX_SELECTED_MESHLETS * 4, usage = {.Storage}, label = "selected meshlets"}, nil)
}

meshlet_select_destroy :: proc(m: ^Meshlet_Select, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(m.selections)
	platform.gpu_destroy_buffer(m.selected)
	destroy_shader_pipeline(&m.pipeline, platform)
}

// meshlet_select_items lists the ITEM_HIERARCHY items, once the bins have ordered them, and grows the selections to
// the frame's items. Without the hierarchy (Feature.Meshlet_Hierarchy in Frame_Desc.disable), or before the walk's
// pipeline is ready, it takes the flag from each, so each tests all of its meshlets.
@(private)
meshlet_select_items :: proc(r: ^Renderer, items: []Cull_Item, disabled: bool, allocator: mem.Allocator) -> []u32 {
	m := &r.scene.meshlet_select
	walks := !disabled && m.pipeline.pipeline != {} && m.selected != {}
	if walks && (len(items) > m.capacity || m.selections == {}) {
		r.platform.gpu_destroy_buffer(m.selections)
		m.capacity = max(len(items), m.capacity * 2, 256)
		m.selections = r.platform.gpu_create_buffer({size = u32(8 + m.capacity * 8), usage = {.Storage}, label = "meshlet selections"}, nil)
		if m.selections == {} {
			m.capacity = 0
			walks = false
		}
	}
	list := make([dynamic]u32, allocator)
	for &item, i in items {
		if item.flags & ITEM_HIERARCHY == 0 {
			continue
		}
		if walks {
			append(&list, u32(i))
		} else {
			item.flags &~= ITEM_HIERARCHY
		}
	}
	return list[:]
}

// meshlet_select_constants imports the selection's buffers and uploads the walk's constants, for a frame with
// ITEM_HIERARCHY items. It is false only when the upload ring is full.
@(private)
meshlet_select_constants :: proc(f: ^Frame, cull: Cull_Constants) -> bool {
	sf := f.scene_frame
	ms := &sf.meshlet_select
	m := &f.renderer.scene.meshlet_select
	if len(ms.items) == 0 {
		return true
	}
	platform := f.renderer.platform
	ok: bool
	ms.upload, ok = upload_bytes(platform, slice.to_bytes(ms.items))
	if !ok {
		return false
	}
	constants := Meshlet_Select_Constants {
		camera        = cull.camera,
		lod_scale     = cull.lod_scale,
		lod_near      = cull.lod_near,
		walk_count    = u32(len(ms.items)),
		walks         = gpu.read_index(ms.upload.buffer),
		walks_offset  = ms.upload.offset,
		items         = cull.items,
		items_offset  = cull.items_offset,
		meshes        = gpu.read_index(sf.mesh_upload.buffer),
		meshes_offset = sf.mesh_upload.offset,
		instances     = cull.instances,
		selections    = gpu.write_index(m.selections),
		selected      = gpu.write_index(m.selected),
		stats         = cull.stats,
	}
	ms.constants, ok = upload_bytes(platform, mem.ptr_to_bytes(&constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return false
	}
	g := f.graph
	ms.selections = import_buffer(g, m.selections)
	ms.selected = import_buffer(g, m.selected)
	return true
}

// add_meshlet_select_pass adds the walk after the scene's update, which zeroes the list's counter, and before the draw
// culling. It adds nothing when nothing walks.
@(private)
add_meshlet_select_pass :: proc(f: ^Frame) {
	sf := f.scene_frame
	if len(sf.meshlet_select.items) == 0 {
		return
	}
	g := f.graph
	p := add_compute_pass(g, "select meshlets", select_meshlets, f)
	read(g, p, sf.instances)
	write(g, p, sf.meshlet_select.selections)
	write(g, p, sf.meshlet_select.selected)
	if sf.stats != 0 {
		write(g, p, sf.stats)
	}
}

@(private = "file")
select_meshlets :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	ms := &f.scene_frame.meshlet_select
	pipeline := f.renderer.scene.meshlet_select.pipeline.pipeline
	if len(ms.items) == 0 || pipeline == {} {
		return
	}
	count := u32(len(ms.items))
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, ms.constants)
	gpu.cmd_dispatch(ctx.cb, {min(count, MESHLET_SELECT_ROW), (count + MESHLET_SELECT_ROW - 1) / MESHLET_SELECT_ROW, 1})
}
