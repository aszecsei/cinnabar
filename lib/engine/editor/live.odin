package editor

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// Live meshes (see docs/editor/mesh-editing.md#live-meshes): the meshes that the editor edits, which the game draws from
// memory in place of their cooked blobs. A Live_Mesh gives the structured mesh, which the game keeps, bakes with
// format.mesh_bake as the cooker does, cuts into level-0 meshlets and streams through the renderer's residency as a
// blob; a Live_Mesh_Vertices replaces the positions and bakes again, which is a drag's step; a Release_Live_Mesh lets
// the asset's blob draw again. The table is the host's, so a code reload keeps it, and a new connection drops it.

// Live_Mesh is one live mesh: its structure as the editor last gave it, and of its bake what the overlay draws, in the
// host's heap.
@(private)
Live_Mesh :: struct {
	source:         format.Mesh_Source,
	// The baked vertices' positions, the triangles' indices into them, and the source face of each triangle.
	bake_positions: [][3]f32,
	bake_indices:   []u32,
	triangle_faces: []u32,
}

// handle_live_message handles a live mesh's messages, and reports whether the message was one.
@(private)
handle_live_message :: proc(e: ^Editor, message: link.Message) -> bool {
	#partial switch m in message {
	case link.Live_Mesh:
		guid := format.Guid(m.guid)
		source, ok := source_of_live(m, e.platform.heap_allocator)
		if !ok {
			buffer: [32]u8
			log.warnf("editor: the live mesh %s has a position count that is not a multiple of three", format.guid_format(guid, &buffer))
			return true
		}
		release_live_mesh(e, guid)
		e.live_meshes[guid] = {source = source}
		bake_live_mesh(e, guid)
	case link.Live_Mesh_Vertices:
		guid := format.Guid(m.guid)
		live, found := &e.live_meshes[guid]
		buffer: [32]u8
		if !found {
			log.warnf("editor: a drag step came for %s, which is not a live mesh", format.guid_format(guid, &buffer))
			return true
		}
		if len(m.positions) != len(live.source.vertices) * 3 {
			log.warnf("editor: a drag step for %s has %d positions, and the mesh has %d vertices", format.guid_format(guid, &buffer), len(m.positions) / 3, len(live.source.vertices))
			return true
		}
		for &v, i in live.source.vertices {
			v = {m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]}
		}
		bake_live_mesh(e, guid)
	case link.Mesh_Overlay:
		set_mesh_overlay(e, m)
	case link.Release_Live_Mesh:
		guid := format.Guid(m.guid)
		release_live_mesh(e, guid)
		if e.residency != nil {
			render.clear_live(e.residency, guid)
		}
	case:
		return false
	}
	return true
}

// release_live_meshes forgets every live mesh, and lets their assets draw, for a new editor or the end.
@(private)
release_live_meshes :: proc(e: ^Editor) {
	clear_mesh_overlay(e)
	for guid, &live in e.live_meshes {
		free_live(e, &live)
		if e.residency != nil {
			render.clear_live(e.residency, guid)
		}
	}
	clear(&e.live_meshes)
}

@(private = "file")
release_live_mesh :: proc(e: ^Editor, guid: format.Guid) {
	if live, found := &e.live_meshes[guid]; found {
		free_live(e, live)
		delete_key(&e.live_meshes, guid)
	}
}

@(private = "file")
free_live :: proc(e: ^Editor, live: ^Live_Mesh) {
	heap := e.platform.heap_allocator
	free_source(live.source, heap)
	delete(live.bake_positions, heap)
	delete(live.bake_indices, heap)
	delete(live.triangle_faces, heap)
	live^ = {}
}

// bake_live_mesh bakes a live mesh into a blob in frame memory and streams it. A face the bake refuses is logged at
// its index, as the cooker logs it at its line.
@(private = "file")
bake_live_mesh :: proc(e: ^Editor, guid: format.Guid) {
	live := &e.live_meshes[guid]
	blob, problems, bake := live_blob(guid, live.source, e.platform.frame_allocator)
	heap := e.platform.heap_allocator
	delete(live.bake_positions, heap)
	delete(live.bake_indices, heap)
	delete(live.triangle_faces, heap)
	live.bake_positions = make([][3]f32, len(bake.vertices), heap)
	for v, i in bake.vertices {
		live.bake_positions[i] = v.position
	}
	live.bake_indices = slice.clone(bake.indices, heap)
	live.triangle_faces = slice.clone(bake.triangle_faces, heap)
	buffer: [32]u8
	for p in problems {
		log.warnf("editor: the live mesh %s, face %d: %s", format.guid_format(guid, &buffer), p.line, p.message)
	}
	if blob == nil {
		log.warnf("editor: the live mesh %s has no faces that bake, so it draws nothing", format.guid_format(guid, &buffer))
	}
	if e.residency != nil && blob != nil {
		render.set_live(e.residency, guid, blob)
	}
}

// live_blob bakes a mesh and builds its meshlets into a mesh blob, as the cooker's blob of the same file would be
// without meshoptimizer's reordering and levels of detail, in allocator at the alignment the runtime loads blobs at.
// It is nil for a mesh with no faces that bake. The problems are the bake's, with each face's index as its line, and
// the bake itself is in temporary memory, for the overlay.
live_blob :: proc(guid: format.Guid, source: format.Mesh_Source, allocator: runtime.Allocator) -> (blob: []byte, problems: []format.Mesh_Problem, bake: format.Mesh_Bake) {
	bake = format.mesh_bake(source, context.temp_allocator)
	problems = make([]format.Mesh_Problem, len(bake.problems), allocator)
	copy(problems, bake.problems)
	if len(bake.indices) == 0 {
		return nil, problems, bake
	}
	vertex_count := len(bake.vertices)
	flags: format.Mesh_Flags
	if vertex_count > 65535 {
		flags += {.Index32}
	}
	stride := int(format.mesh_attribute_stride(flags))
	positions := make([][3]f32, vertex_count, context.temp_allocator)
	attributes := make([]byte, vertex_count * stride, context.temp_allocator)
	for v, i in bake.vertices {
		positions[i] = v.position
		(^format.Mesh_Attributes)(&attributes[i * stride])^ = {
			normal  = format.mesh_encode_normal(v.normal),
			tangent = format.mesh_encode_tangent(v.tangent),
			uv0     = v.uv,
		}
	}
	index_bytes: []byte
	if .Index32 in flags {
		index_bytes = mem.slice_to_bytes(bake.indices)
	} else {
		narrow := make([]u16, len(bake.indices), context.temp_allocator)
		for index, i in bake.indices {
			narrow[i] = u16(index)
		}
		index_bytes = mem.slice_to_bytes(narrow)
	}
	meshlets := make([dynamic]format.Meshlet, context.temp_allocator)
	meshlet_vertices := make([dynamic]u32, context.temp_allocator)
	meshlet_triangles := make([dynamic]u32, context.temp_allocator)
	submeshes := make([]format.Submesh_Entry, len(bake.submeshes), context.temp_allocator)
	for s, i in bake.submeshes {
		first_meshlet := len(meshlets)
		count := render.build_simple_meshlets(positions, bake.indices[s.first_index:][:s.index_count], &meshlets, &meshlet_vertices, &meshlet_triangles)
		submeshes[i] = {
			first_index   = s.first_index,
			index_count   = s.index_count,
			first_meshlet = u32(first_meshlet),
			meshlet_count = u32(count),
			bounds        = s.bounds,
		}
	}
	contents := format.Mesh_Contents {
		guid              = guid,
		flags             = flags,
		vertex_count      = u32(vertex_count),
		index_count       = u32(len(bake.indices)),
		bounds            = bake.bounds,
		submeshes         = submeshes,
		positions         = mem.slice_to_bytes(positions),
		attributes        = attributes,
		indices           = index_bytes,
		meshlets          = meshlets[:],
		meshlet_vertices  = mem.slice_to_bytes(meshlet_vertices[:]),
		meshlet_triangles = mem.slice_to_bytes(meshlet_triangles[:]),
		name              = "live",
	}
	written := format.mesh_write(contents, context.temp_allocator)
	aligned, err := mem.alloc_bytes(len(written), format.BLOB_ALIGN, allocator)
	if err != nil {
		return nil, problems, bake
	}
	copy(aligned, written)
	return aligned, problems, bake
}

// source_of_live is a Live_Mesh as the format has it, in allocator. It fails when the positions are not triples.
@(private = "file")
source_of_live :: proc(m: link.Live_Mesh, allocator: runtime.Allocator) -> (source: format.Mesh_Source, ok: bool) {
	if len(m.positions) % 3 != 0 {
		return
	}
	for material in m.materials {
		if material.slot < format.MESH_MAX_SLOTS {
			source.materials[material.slot] = format.Guid(material.guid)
		}
	}
	source.vertices = make([][3]f32, len(m.positions) / 3, allocator)
	for &v, i in source.vertices {
		v = {m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]}
	}
	source.faces = make([]format.Mesh_Face, len(m.faces), allocator)
	for f, i in m.faces {
		corners := make([]u32, len(f.corners), allocator)
		copy(corners, f.corners)
		source.faces[i] = {
			slot = f.slot,
			corners = corners,
			mapping = {
				u_axis   = f.mapping.u_axis,
				v_axis   = f.mapping.v_axis,
				scale    = f.mapping.scale,
				shift    = f.mapping.shift,
				rotation = f.mapping.rotation,
			},
			// The face's index stands for its line in the messages about it.
			line = i,
		}
	}
	source.sharp = make([]format.Mesh_Edge, len(m.sharp), allocator)
	for s, i in m.sharp {
		source.sharp[i] = {s.a, s.b}
	}
	return source, true
}

@(private = "file")
free_source :: proc(source: format.Mesh_Source, allocator: runtime.Allocator) {
	delete(source.vertices, allocator)
	for f in source.faces {
		delete(f.corners, allocator)
	}
	delete(source.faces, allocator)
	delete(source.sharp, allocator)
}

// live_message is a mesh as a Live_Mesh message, in allocator: what the editor sends, for tests and tools.
live_message :: proc(guid: format.Guid, source: format.Mesh_Source, allocator: runtime.Allocator) -> link.Live_Mesh {
	materials := make([dynamic]link.Live_Material, allocator)
	for material, slot in source.materials {
		if material != {} {
			append(&materials, link.Live_Material{slot = u32(slot), guid = ([16]u8)(material)})
		}
	}
	positions := make([]f32, len(source.vertices) * 3, allocator)
	for v, i in source.vertices {
		positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] = v.x, v.y, v.z
	}
	faces := make([]link.Live_Face, len(source.faces), allocator)
	for f, i in source.faces {
		faces[i] = {
			slot = f.slot,
			corners = f.corners,
			mapping = {
				u_axis   = f.mapping.u_axis,
				v_axis   = f.mapping.v_axis,
				scale    = f.mapping.scale,
				shift    = f.mapping.shift,
				rotation = f.mapping.rotation,
			},
		}
	}
	sharp := make([]link.Live_Edge, len(source.sharp), allocator)
	for s, i in source.sharp {
		sharp[i] = {s.a, s.b}
	}
	return {guid = ([16]u8)(guid), materials = materials[:], positions = positions, faces = faces, sharp = sharp}
}

#assert(format.MESH_MAX_SLOTS == render.MAX_MATERIAL_SLOTS)
