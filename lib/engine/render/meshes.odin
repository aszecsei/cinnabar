package render

import "core:mem"

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// MESH_SHADER is the engine's mesh shader (lib/engine/content/shaders/mesh.hlsl), by its .meta file. A game makes its
// pipeline with shader_pipeline and the formats of the pass that draws meshes: an HDR color target, and the editor's
// entity IDs as a second.
MESH_SHADER :: #load("../content/shaders/mesh.hlsl.meta", string)

// Mesh_Instance matches Instance in mesh.hlsl.
Mesh_Instance :: struct {
	rows:    [3][4]f32,
	// The entity's value in the editor's ID buffer, which the game sets (see editor.entity_id).
	id:      u32,
	padding: [3]u32,
}

// Mesh_Push matches Push in mesh.hlsl.
Mesh_Push :: struct {
	view_projection:  matrix[4, 4]f32,
	positions:        u32,
	attributes:       u32,
	attribute_stride: u32,
	instances:        u32,
	instance_offset:  u32,
	instance:         u32,
}

#assert(size_of(Mesh_Push) <= 128)

// Mesh_Draw is one Mesh_Renderer whose mesh is resident: its entity, its instance, and the mesh.
Mesh_Draw :: struct {
	entity:   ecs.Entity,
	instance: u32,
	mesh:     ^Resident_Mesh,
}

// mesh_extractor selects the entities with a Mesh_Renderer. It is a registration: create it again in on_reload.
mesh_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Mesh_Renderer)})
}

// extract_meshes writes the instance of each Mesh_Renderer, relative to origin, into the upload ring, and gives a draw
// for each one whose mesh is resident. The first call for a mesh starts streaming it, so it draws in a later frame.
// The draws and the instances are in frame memory; a game sets each instance's id, and leaves out the draws that it
// hides, before it records them.
extract_meshes :: proc(w: ^ecs.World, r: ^Residency, ex: Extractor, origin: ecs.World_Position) -> (instances: gpu.Upload, draws: []Mesh_Draw) {
	count := extract_count(w, ex)
	ok: bool
	instances, ok = r.platform.gpu_upload(max(count, 1) * size_of(Mesh_Instance), 16)
	if !ok || count == 0 {
		return
	}
	mem.zero_slice(instances.data)
	chunks := extract(w, ex, origin, instances.data, size_of(Mesh_Instance))
	result := make([dynamic]Mesh_Draw, 0, count, w.platform.frame_allocator)
	for c in chunks {
		entities := ecs.entities(c.view)
		for renderer, i in ecs.column(c.view, EXTRACT_TERMS, Mesh_Renderer) {
			if mesh, ready := resident_mesh(r, renderer.mesh); ready {
				append(&result, Mesh_Draw{entities[i], u32(c.first + i), mesh})
			}
		}
	}
	return instances, result[:]
}

// mesh_instances is the instance records of extract_meshes, for the game to set their ids.
mesh_instances :: proc(instances: gpu.Upload) -> []Mesh_Instance {
	return ([^]Mesh_Instance)(raw_data(instances.data))[:len(instances.data) / size_of(Mesh_Instance)]
}

// draw_meshes records the draws in a render pass, each submesh as an indexed draw with the engine's mesh shader.
draw_meshes :: proc(cb: ^gpu.Command_Buffer, pipeline: gpu.Pipeline, view_projection: matrix[4, 4]f32, instances: gpu.Upload, draws: []Mesh_Draw) {
	if len(draws) == 0 {
		return
	}
	gpu.cmd_set_pipeline(cb, pipeline)
	for d in draws {
		m := d.mesh
		push := Mesh_Push {
			view_projection  = view_projection,
			positions        = gpu.read_index(m.positions),
			attributes       = gpu.read_index(m.attributes),
			attribute_stride = m.attribute_stride,
			instances        = gpu.read_index(instances.buffer),
			instance_offset  = instances.offset,
			instance         = d.instance,
		}
		gpu.cmd_push_constants(cb, &push)
		gpu.cmd_set_index_buffer(cb, m.indices, m.index_format)
		for s in m.submeshes[:m.submesh_count] {
			gpu.cmd_draw_indexed(cb, s.index_count, first_index = s.first_index)
		}
	}
}
