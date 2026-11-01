package render

import "core:mem"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// Skinned meshes (see docs/rendering/gpu-scene.md#skinned-meshes): a Mesh_Renderer whose mesh has a skin stream, and
// that the game gave a Skin_Pose this frame, draws posed. Each such entity has buffers of its own, a copy of its mesh's
// positions and attributes, which skin_meshes.hlsl writes each frame by the joint palette, one dispatch for every
// entity, before anything draws. The entity's Mesh_Record names its copies, so every pass that draws or traces a mesh
// reads the posed vertices as it reads any other, and a copy of the last frame's positions gives the velocities.

// SKIN_MESHES_SHADER poses the vertices (lib/engine/content/shaders/skin_meshes.hlsl), by its .meta file.
SKIN_MESHES_SHADER :: #load("../content/shaders/skin_meshes.hlsl.meta", string)
// Each group of the skinning pass has this many threads. Matches SKIN_GROUP_SIZE in skin_meshes.hlsl.
SKIN_GROUP_SIZE :: 64
// A dispatch has at most this many groups along x, under D3D12's limit of a dimension; each thread of a mesh with more
// vertices poses several.
SKIN_MAX_GROUPS :: 32768
// A joint of the palette is a 3x4 matrix of floats.
SKIN_JOINT_BYTES :: 48
// A job whose entity's buffers are new: it writes the posed positions as last frame's too, so a first pose has no
// velocity. Matches SKIN_RESET in skin_meshes.hlsl.
SKIN_RESET :: 1

// Skin_Pose is one skinned entity's pose this frame, already interpolated for presentation.
Skin_Pose :: struct {
	entity:  ecs.Entity,
	// Joint matrices, mesh-local bind pose -> mesh-local posed, as three rows of a 3x4 matrix each; index = the skin
	// stream's joint indices.
	palette: [][3][4]f32,
	// A conservative sphere about the posed mesh, in mesh-local space: xyz center, w radius. Culling takes it for every
	// submesh.
	sphere:  [4]f32,
}

// Skin_Job matches Skin_Job in skin_meshes.hlsl: one entity's job. The buffers are bindless indices: the mesh's rest
// positions, rest attributes and skin stream, and the entity's copies. first_joint is the job's first joint among the
// frame's palette, and attribute_words the mesh's attribute stride in words.
Skin_Job :: struct {
	rest_positions:  u32,
	rest_attributes: u32,
	skin:            u32,
	attribute_words: u32,
	positions:       u32,
	previous:        u32,
	attributes:      u32,
	vertex_count:    u32,
	first_joint:     u32,
	joint_count:     u32,
	flags:           u32,
	padding:         u32,
}

// Skin_Constants matches Skin_Constants in skin_meshes.hlsl. The jobs and the palette are in the upload ring, at these
// offsets of its buffer; stride is the threads of a row of groups, which each pose every stride-th vertex of a job.
Skin_Constants :: struct {
	jobs:           u32,
	jobs_offset:    u32,
	palette:        u32,
	palette_offset: u32,
	job_count:      u32,
	stride:         u32,
	padding:        [2]u32,
}

#assert(size_of(Skin_Job) == 48 && size_of(Skin_Constants) == 32 && size_of([3][4]f32) == SKIN_JOINT_BYTES)

// Skinned_Instance is a skinned entity's buffers, which last from frame to frame while its mesh does, in Skin_State by
// the entity's instance slot: the posed positions, last frame's, and the posed attributes. source is the rest
// positions that they were made for, so a mesh that streamed anew gives new ones.
Skinned_Instance :: struct {
	entity:           ecs.Entity,
	source:           gpu.Buffer,
	positions:        gpu.Buffer,
	previous:         gpu.Buffer,
	attributes:       gpu.Buffer,
	vertex_count:     u32,
	attribute_stride: u32,
	// The last frame that used them (Gpu_Scene.frame).
	frame:            u64,
	// With the ray scene, the entity's bottom-level structure over its positions, which each frame refits once
	// accel_built.
	accel:            gpu.Accel_Struct,
	accel_built:      bool,
}

// Skin_State is the skinning's state between frames, in Gpu_Scene.
Skin_State :: struct {
	pipeline:  Shader_Pipeline,
	instances: map[u32]Skinned_Instance,
}

// Skin_Refit is a skinned entity whose structure the ray scene builds this frame, by its instance slot, with its
// mesh's indices. update is whether an earlier frame built the structure, which this one then refits.
@(private)
Skin_Refit :: struct {
	slot:    u32,
	indices: gpu.Buffer,
	update:  bool,
}

// Skin_Build is the frame's skinned entities as build_scene collects them: the poses by entity, then a job for each
// entity that draws posed, with its instance slot, and the joints of all their palettes in one array.
@(private)
Skin_Build :: struct {
	poses:        map[ecs.Entity]^Skin_Pose,
	jobs:         [dynamic]Skin_Job,
	slots:        [dynamic]u32,
	palette:      [dynamic][3][4]f32,
	refits:       [dynamic]Skin_Refit,
	max_vertices: u32,
}

// Skin_Frame is one frame's skinning in Scene_Frame, once build_scene has uploaded its jobs: the instance slot of each,
// its three buffers in the graph (positions, previous positions, attributes) once the pass is added, and the
// structures to refit. It is empty without a skinned entity.
@(private)
Skin_Frame :: struct {
	jobs:      int,
	groups:    u32,
	constants: gpu.Upload,
	slots:     []u32,
	buffers:   [][3]Buffer,
	refits:    []Skin_Refit,
}

skin_init :: proc(s: ^Skin_State, platform: ^core.Platform_API) {
	s.pipeline = shader_pipeline(SKIN_MESHES_SHADER)
	s.instances = make(map[u32]Skinned_Instance, platform.heap_allocator)
}

skin_destroy :: proc(s: ^Skin_State, platform: ^core.Platform_API) {
	for _, &instance in s.instances {
		destroy_skinned_instance(&instance, platform)
	}
	delete(s.instances)
	destroy_shader_pipeline(&s.pipeline, platform)
}

@(private = "file")
destroy_skinned_instance :: proc(i: ^Skinned_Instance, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(i.positions)
	platform.gpu_destroy_buffer(i.previous)
	platform.gpu_destroy_buffer(i.attributes)
	if i.accel != {} {
		platform.gpu_destroy_accel(i.accel)
	}
	i^ = {}
}

// skin_instance gives the buffers of the entity in an instance slot for a frame, made for its mesh, or made again when
// the mesh's rest positions, vertex count or attribute stride are not the ones that they were made for. reset is
// whether their contents are not last frame's: new buffers, or the entity, or the frame before, is not the one that
// wrote them. ok is false when the buffers cannot be made, and the entity then draws at rest.
skin_instance :: proc(
	s: ^Skin_State,
	platform: ^core.Platform_API,
	frame: u64,
	slot: u32,
	entity: ecs.Entity,
	source: gpu.Buffer,
	vertex_count, attribute_stride: u32,
) -> (instance: Skinned_Instance, reset, ok: bool) {
	found, has := s.instances[slot]
	if has && found.source == source && found.vertex_count == vertex_count && found.attribute_stride == attribute_stride {
		reset = found.entity != entity || found.frame + 1 != frame
		found.entity, found.frame = entity, frame
		s.instances[slot] = found
		return found, reset, true
	}
	if has {
		destroy_skinned_instance(&found, platform)
		delete_key(&s.instances, slot)
	}
	instance = {
		entity           = entity,
		source           = source,
		positions        = platform.gpu_create_buffer({size = vertex_count * 12, usage = {.Storage}, label = "skinned positions"}, nil),
		previous         = platform.gpu_create_buffer({size = vertex_count * 12, usage = {.Storage}, label = "skinned previous positions"}, nil),
		attributes       = platform.gpu_create_buffer({size = vertex_count * attribute_stride, usage = {.Storage}, label = "skinned attributes"}, nil),
		vertex_count     = vertex_count,
		attribute_stride = attribute_stride,
		frame            = frame,
	}
	if instance.positions == {} || instance.previous == {} || instance.attributes == {} {
		destroy_skinned_instance(&instance, platform)
		return {}, false, false
	}
	s.instances[slot] = instance
	return instance, true, true
}

// skin_accel makes a skinned entity's bottom-level structure over its positions and its mesh's indices, once the ray
// scene is in use and the mesh has triangles. The structure refits, so each frame's pose moves it.
@(private)
skin_accel :: proc(s: ^Skin_State, platform: ^core.Platform_API, slot: u32, mesh: ^Resident_Mesh) {
	instance := &s.instances[slot]
	if instance.accel != {} || mesh.index_count == 0 || mesh.index_count % 3 != 0 {
		return
	}
	geometry := gpu.Accel_Geometry {
		vertices      = instance.positions,
		vertex_stride = 12,
		vertex_count  = instance.vertex_count,
		vertex_format = .RGB32_Float,
		indices       = mesh.indices,
		index_count   = mesh.index_count,
		index_format  = mesh.index_format,
		opaque        = true,
	}
	instance.accel = platform.gpu_create_accel({kind = .Bottom, flags = {.Allow_Update}, geometries = {geometry}, label = "skinned mesh"})
	instance.accel_built = false
}

// sweep_skins destroys the buffers of the entities that the frame did not use, so an entity that leaves the scene, or
// hides, gives its buffers back. The backend releases them when the frames in flight are done with them.
@(private)
sweep_skins :: proc(s: ^Skin_State, platform: ^core.Platform_API, frame: u64) {
	unused := make([dynamic]u32, context.temp_allocator)
	for slot, instance in s.instances {
		if instance.frame != frame {
			append(&unused, slot)
		}
	}
	for slot in unused {
		instance := s.instances[slot]
		destroy_skinned_instance(&instance, platform)
		delete_key(&s.instances, slot)
	}
}

// skin_build starts the frame's skinned entities: a lookup of the poses by entity.
@(private)
skin_build :: proc(poses: []Skin_Pose, allocator: mem.Allocator) -> Skin_Build {
	b := Skin_Build {
		poses   = make(map[ecs.Entity]^Skin_Pose, len(poses), allocator),
		jobs    = make([dynamic]Skin_Job, allocator),
		slots   = make([dynamic]u32, allocator),
		palette = make([dynamic][3][4]f32, allocator),
		refits  = make([dynamic]Skin_Refit, allocator),
	}
	for &pose in poses {
		b.poses[pose.entity] = &pose
	}
	return b
}

// skin_add adds an entity's job and joints, for the buffers that skin_instance gave.
@(private)
skin_add :: proc(b: ^Skin_Build, mesh: ^Resident_Mesh, instance: Skinned_Instance, slot: u32, pose: ^Skin_Pose, reset: bool) {
	append(&b.jobs, Skin_Job {
		rest_positions  = gpu.read_index(mesh.positions),
		rest_attributes = gpu.read_index(mesh.attributes),
		skin            = gpu.read_index(mesh.skin),
		attribute_words = mesh.attribute_stride / 4,
		positions       = gpu.write_index(instance.positions),
		previous        = gpu.write_index(instance.previous),
		attributes      = gpu.write_index(instance.attributes),
		vertex_count    = mesh.vertex_count,
		first_joint     = u32(len(b.palette)),
		joint_count     = u32(len(pose.palette)),
		flags           = reset ? SKIN_RESET : 0,
	})
	append(&b.slots, slot)
	append(&b.palette, ..pose.palette)
	b.max_vertices = max(b.max_vertices, mesh.vertex_count)
}

// skin_upload uploads the frame's jobs and palette and the pass's constants into the upload ring. It is false only
// when the ring is full.
@(private)
skin_upload :: proc(f: ^Frame, b: ^Skin_Build) -> bool {
	sf := f.scene_frame
	if len(b.jobs) == 0 {
		return true
	}
	platform := f.renderer.platform
	jobs, jobs_ok := upload_bytes(platform, slice.to_bytes(b.jobs[:]))
	palette, palette_ok := upload_bytes(platform, slice.to_bytes(b.palette[:]))
	if !(jobs_ok && palette_ok) {
		return false
	}
	groups := min((b.max_vertices + SKIN_GROUP_SIZE - 1) / SKIN_GROUP_SIZE, SKIN_MAX_GROUPS)
	constants := Skin_Constants {
		jobs           = gpu.read_index(jobs.buffer),
		jobs_offset    = jobs.offset,
		palette        = gpu.read_index(palette.buffer),
		palette_offset = palette.offset,
		job_count      = u32(len(b.jobs)),
		stride         = groups * SKIN_GROUP_SIZE,
	}
	ok: bool
	sf.skin.constants, ok = upload_bytes(platform, mem.ptr_to_bytes(&constants), gpu.PASS_CONSTANTS_ALIGN)
	sf.skin.jobs, sf.skin.groups, sf.skin.slots, sf.skin.refits = len(b.jobs), max(groups, 1), b.slots[:], b.refits[:]
	return ok
}

// add_skinning_pass adds the pass that poses the frame's skinned entities, before the scene's update and so before
// every pass that draws, casts shadows or traces. It declares the writes of each entity's three buffers.
@(private)
add_skinning_pass :: proc(f: ^Frame) {
	sf := f.scene_frame
	if sf.skin.jobs == 0 {
		return
	}
	g := f.graph
	sf.skin.buffers = make([][3]Buffer, len(sf.skin.slots), f.renderer.platform.frame_allocator)
	p := add_compute_pass(g, "skin meshes", pose_meshes, f)
	for slot, i in sf.skin.slots {
		instance := f.renderer.scene.skins.instances[slot]
		sf.skin.buffers[i] = {import_buffer(g, instance.positions), import_buffer(g, instance.previous), import_buffer(g, instance.attributes)}
		for buffer in sf.skin.buffers[i] {
			write(g, p, buffer)
		}
	}
}

// declare_skinned_reads declares that a pass reads the posed vertices of the frame's skinned entities, as it reads any
// mesh's, after the skinning pass wrote them.
@(private)
declare_skinned_reads :: proc(f: ^Frame, p: Pass) {
	sf := f.scene_frame
	if sf == nil {
		return
	}
	for buffers in sf.skin.buffers {
		for buffer in buffers {
			read(f.graph, p, buffer)
		}
	}
}

@(private = "file")
pose_meshes :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.skins.pipeline.pipeline
	if sf.skin.jobs == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.skin.constants)
	gpu.cmd_dispatch(ctx.cb, {sf.skin.groups, u32(sf.skin.jobs), 1})
}
