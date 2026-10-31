package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// The ray scene (see docs/rendering/ray-scene.md#ray-scene): the GPU scene's top-level acceleration structure, which
// any feature that traces requests, and hit shading, which evaluates the materials at a client's ray hits. The first
// request makes the structure and has every mesh make its own. Each frame that requests it builds the meshes' that
// became ready, then the scene's from the frame's instances, before the prepass, so every pass after can trace it.

// The instance mask bits of the scene's structure. Match ray_scene.hlsli. The shadow rays see the instances whose
// Mesh_Renderer casts shadows, and hit shading those with an opaque or masked submesh.
RAY_MASK_SHADOWS :: 0x01
RAY_MASK_SURFACES :: 0x02
// The threads of each group of the binning and of each hit shader. Matches HIT_GROUP_SIZE in ray_scene.hlsli.
HIT_GROUP_SIZE :: 64
// Bin 0 is the fallback's, and each material pipeline's hit pass has the bin after its index. Matches MAX_HIT_BINS in
// ray_scene.hlsli.
MAX_HIT_BINS :: MAX_MATERIAL_PIPELINES + 1
#assert(MAX_HIT_BINS == 257)
// A frame shades at most this many clients' hits.
MAX_HIT_BATCHES :: 4
// A batch has at most this many rays: the binning and each bin's shading dispatch a group for each HIT_GROUP_SIZE
// rays, and a dispatch has at most 65535 groups along x.
MAX_HIT_RAYS :: 65535 * HIT_GROUP_SIZE
// A Hit_Submesh's bin has this for a transparent or additive material's submesh, which the fallback shades.
HIT_TRANSLUCENT :: 1 << 24
HIT_BIN_MASK :: HIT_TRANSLUCENT - 1

// HIT_BIN_SHADER bins a client's hits by their materials (lib/engine/content/shaders/hit_bin.hlsl), and
// HIT_DEFAULT_SHADER shades the fallback bin (hit_default.hlsl).
HIT_BIN_SHADER :: #load("../content/shaders/hit_bin.hlsl.meta", string)
HIT_DEFAULT_SHADER :: #load("../content/shaders/hit_default.hlsl.meta", string)

// Hit_Record matches Hit_Record in ray_scene.hlsli: one ray's hit, which a client writes with trace_hit.
Hit_Record :: struct {
	instance:     u32,
	primitive:    u32,
	barycentrics: u32,
	direction:    u32,
	t:            f32,
	cone_width:   f32,
	bin:          u32,
	entry:        u32,
}

// Hit_Surface matches Hit_Surface in ray_scene.hlsli: the surface at one ray's hit, which hit shading writes.
Hit_Surface :: struct {
	position:             [3]f32,
	normal:               u32,
	geometric:            u32,
	albedo:               u32,
	emission_rg:          u32,
	emission_b_roughness: u32,
}

#assert(size_of(Hit_Record) == 32 && size_of(Hit_Surface) == 32)

// Hit_Instance and Hit_Submesh match their HLSL structs in ray_scene.hlsli: the frame's hit table. A slot's record
// names its mesh record and the records of its submeshes; a submesh's has its primitives, its material's block, and its
// bin with HIT_TRANSLUCENT.
Hit_Instance :: struct {
	mesh:  u32,
	first: u32,
	count: u32,
	flags: u32,
}

Hit_Submesh :: struct {
	first_primitive: u32,
	primitive_count: u32,
	block:           u32,
	bin:             u32,
}

// Hit_Push matches Hit_Push in ray_scene.hlsli: what each bin's dispatch pushes.
Hit_Push :: struct {
	bin:                  u32,
	hits:                 u32,
	order:                u32,
	bins:                 u32,
	surfaces:             u32,
	hit_instances:        u32,
	hit_instances_offset: u32,
	hit_submeshes:        u32,
	hit_submeshes_offset: u32,
}

#assert(size_of(Hit_Push) <= 128)

// Hit_Bin_Constants matches Hit_Bin_Constants in hit_bin.hlsl.
@(private = "file")
Hit_Bin_Constants :: struct {
	phase:                u32,
	ray_count:            u32,
	hits:                 u32,
	order:                u32,
	bins:                 u32,
	arguments:            u32,
	hit_instances:        u32,
	hit_instances_offset: u32,
	hit_submeshes:        u32,
	hit_submeshes_offset: u32,
	instance_count:       u32,
	padding:              u32,
}

@(private = "file")
HIT_PHASES :: [4]string{"clear hit bins", "count hit bins", "place hit bins", "scatter hit bins"}

// Ray_Scene is the ray scene's state between frames, in the Renderer.
Ray_Scene :: struct {
	// Made on the first request, and kept when no feature traces, so tracing again does not make every mesh's again.
	accel:        gpu.Accel_Struct,
	bin_pipeline: Shader_Pipeline,
	fallback:     Shader_Pipeline,
	// The buffers of each of a frame's hit batches.
	scratch:      [MAX_HIT_BATCHES]Hit_Scratch,
}

// Hit_Scratch is one batch's buffers: the rays in bin order, each bin's count, offset and cursor, and each bin's
// dispatch arguments.
@(private)
Hit_Scratch :: struct {
	capacity:  int,
	order:     gpu.Buffer,
	bins:      gpu.Buffer,
	arguments: gpu.Buffer,
}

// Ray_Scene_Frame is one frame's ray scene, in frame memory, made by the frame's first request.
Ray_Scene_Frame :: struct {
	// 0 until add_ray_scene_passes adds the build.
	accel:   Accel,
	// The meshes whose acceleration structures this frame builds.
	builds:  []^Resident_Mesh,
	batches: int,
}

// Hit_Batch is a client's rays: hits holds a Hit_Record for each of count rays, which the client writes before, and
// add_hit_shading writes a Hit_Surface for each ray that hit into surfaces.
Hit_Batch :: struct {
	hits:     Buffer,
	surfaces: Buffer,
	count:    u32,
}

// Hit_Table is the frame's hit table as build_scene makes it: a record for each slot up to the scene's highest, and
// the submeshes' records. used is whether any submesh is in each bin.
@(private)
Hit_Table :: struct {
	instances: []Hit_Instance,
	submeshes: [dynamic]Hit_Submesh,
	used:      [MAX_HIT_BINS]bool,
}

@(private = "file")
Hit_Shading :: struct {
	frame:     ^Frame,
	batch:     Hit_Batch,
	order:     Buffer,
	bins:      Buffer,
	arguments: Buffer,
	constants: [len(HIT_PHASES)]gpu.Upload,
	phase:     int,
}

ray_scene_init :: proc(s: ^Ray_Scene) {
	s.bin_pipeline = shader_pipeline(HIT_BIN_SHADER)
	s.fallback = shader_pipeline(HIT_DEFAULT_SHADER)
}

ray_scene_destroy :: proc(s: ^Ray_Scene, platform: ^core.Platform_API) {
	platform.gpu_destroy_accel(s.accel)
	destroy_shader_pipeline(&s.bin_pipeline, platform)
	destroy_shader_pipeline(&s.fallback, platform)
	for scratch in s.scratch {
		platform.gpu_destroy_buffer(scratch.order)
		platform.gpu_destroy_buffer(scratch.bins)
		platform.gpu_destroy_buffer(scratch.arguments)
	}
}

// sync_ray_scene_pipelines creates the binning's and the fallback's pipelines, with Ray_Query only.
@(private)
sync_ray_scene_pipelines :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	sync_compute_pipeline(&r.ray_scene.bin_pipeline, r.platform, r.residency.assets, {label = "hit bins"}, force)
	sync_compute_pipeline(&r.ray_scene.fallback, r.platform, r.residency.assets, {label = "hit fallback"}, force)
}

// request_ray_scene asks for the scene's acceleration structure this frame, which it makes on the first request. It is
// false without Ray_Query. Requests come before add_ray_scene_passes.
@(private)
request_ray_scene :: proc(f: ^Frame) -> bool {
	r := f.renderer
	if !r.caps.ray_query {
		return false
	}
	if r.ray_scene.accel == {} {
		r.ray_scene.accel = r.platform.gpu_create_accel({kind = .Top, max_instances = MAX_INSTANCES, label = "gpu scene"})
		residency_enable_accels(&r.residency)
	}
	if f.ray_scene == nil {
		f.ray_scene = new(Ray_Scene_Frame, r.platform.frame_allocator)
	}
	return true
}

// ray_scene_accel is the frame's structure for a pass to read, or 0 when nothing requested it.
@(private)
ray_scene_accel :: proc(f: ^Frame) -> Accel {
	return f.ray_scene != nil ? f.ray_scene.accel : 0
}

// add_ray_scene_passes builds the acceleration structures of the meshes that became ready, then the scene's from this
// frame's instances, when a feature requested it.
@(private)
add_ray_scene_passes :: proc(f: ^Frame) {
	rf := f.ray_scene
	if rf == nil {
		return
	}
	r := f.renderer
	g := f.graph
	rf.accel = import_accel(g, r.ray_scene.accel)
	rf.builds = unbuilt_accels(&r.residency)
	blases := make([]Accel, len(rf.builds), r.platform.frame_allocator)
	if len(rf.builds) > 0 {
		p := add_compute_pass(g, "build mesh accels", proc(ctx: ^Pass_Context) {
			for m in (^Frame)(ctx.data).ray_scene.builds {
				gpu.cmd_build_accel(ctx.cb, m.accel)
			}
		}, f)
		for m, i in rf.builds {
			build_input(g, p, import_buffer(g, m.positions))
			build_input(g, p, import_buffer(g, m.indices))
			blases[i] = import_accel(g, m.accel)
			build_accel(g, p, blases[i])
			m.accel_built = true
		}
	}
	p := add_compute_pass(g, "build scene accel", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		instances := f.scene_frame.accel_instances
		gpu.cmd_build_top_accel(ctx.cb, gpu_accel(ctx.graph, f.ray_scene.accel), instances.buffer, instances.offset, u32(f.scene_frame.accel_count))
	}, f)
	for blas in blases {
		build_input(g, p, blas)
	}
	build_accel(g, p, rf.accel)
}

// add_hit_entries adds a slot's records to the hit table: the slot's, and one for each of its items but impostors, with
// the bin of its material's hit pipeline. A transparent or additive material's submesh, and one whose pipeline has no
// hit pass ready, take the fallback's bin. It gives whether the slot has a surface that hit shading evaluates.
@(private)
add_hit_entries :: proc(
	table: ^Hit_Table,
	slot: u32,
	mesh: ^Resident_Mesh,
	items: []Cull_Item,
	pipelines: []Material_Pipeline,
	ready: proc(platform: ^core.Platform_API, pipeline: gpu.Pipeline) -> bool,
	platform: ^core.Platform_API,
) -> (surfaces: bool) {
	first := u32(len(table.submeshes))
	mesh_index: u32
	for item in items {
		if item.flags & ITEM_IMPOSTOR != 0 || int(item.submesh) >= int(mesh.submesh_count) {
			continue
		}
		mesh_index = item.mesh
		submesh := mesh.submeshes[item.submesh]
		pipeline := &pipelines[item.bin]
		bin: u32
		switch {
		case material_group(pipeline) != .Opaque:
			bin = HIT_TRANSLUCENT
		case pipeline.hit != {} && ready(platform, pipeline.hit):
			bin = item.bin + 1
			surfaces = true
		case:
			surfaces = true
		}
		table.used[bin & HIT_BIN_MASK] = true
		append(&table.submeshes, Hit_Submesh{first_primitive = submesh.first_index / 3, primitive_count = submesh.index_count / 3, block = item.material, bin = bin})
	}
	table.instances[slot] = {mesh = mesh_index, first = first, count = u32(len(table.submeshes)) - first}
	return
}

// hit_pipeline_ready is whether a material's hit pipeline has compiled.
@(private)
hit_pipeline_ready :: proc(platform: ^core.Platform_API, pipeline: gpu.Pipeline) -> bool {
	return platform.gpu_pipeline_ready == nil || platform.gpu_pipeline_ready(pipeline)
}

// hit_shading_ready is whether add_hit_shading can shade another batch this frame: the frame has a ray scene and a hit
// table, draw items, so the GPU scene's instances are written, the camera's frame constants, the binning's and the
// fallback's pipelines, and room for a batch.
hit_shading_ready :: proc(f: ^Frame) -> bool {
	r := f.renderer
	rf := f.ray_scene
	sf := f.scene_frame
	if rf == nil || rf.accel == 0 || sf.hit_instance_count == 0 || sf.instances == 0 || len(sf.view_constants) == 0 || rf.batches == MAX_HIT_BATCHES {
		return false
	}
	return pipeline_ready(r.platform, &r.ray_scene.bin_pipeline) && pipeline_ready(r.platform, &r.ray_scene.fallback)
}

// add_hit_shading evaluates the materials at a client's hits, after the client's pass that writes them: it bins the
// hits by their materials, then dispatches each bin's material on its rays, indirectly by the bin's count. It is false,
// and adds nothing, when hit_shading_ready is not, or the batch has no rays or more than MAX_HIT_RAYS.
add_hit_shading :: proc(f: ^Frame, batch: Hit_Batch, queue := gpu.Queue.Graphics) -> bool {
	r := f.renderer
	rf := f.ray_scene
	sf := f.scene_frame
	platform := r.platform
	if !hit_shading_ready(f) || batch.count == 0 || batch.count > MAX_HIT_RAYS {
		return false
	}
	scratch := ensure_hit_scratch(r, rf.batches, int(batch.count))
	rf.batches += 1
	g := f.graph
	data := new(Hit_Shading, platform.frame_allocator)
	data^ = {
		frame     = f,
		batch     = batch,
		order     = import_buffer(g, scratch.order),
		bins      = import_buffer(g, scratch.bins),
		arguments = import_buffer(g, scratch.arguments),
	}
	constants := Hit_Bin_Constants {
		ray_count            = batch.count,
		hits                 = gpu.write_index(gpu_buffer(g, batch.hits)),
		order                = gpu.write_index(scratch.order),
		bins                 = gpu.write_index(scratch.bins),
		arguments            = gpu.write_index(scratch.arguments),
		hit_instances        = gpu.read_index(sf.hit_instances.buffer),
		hit_instances_offset = sf.hit_instances.offset,
		hit_submeshes        = gpu.read_index(sf.hit_submeshes.buffer),
		hit_submeshes_offset = sf.hit_submeshes.offset,
		instance_count       = u32(sf.hit_instance_count),
	}
	for &upload, phase in data.constants {
		constants.phase = u32(phase)
		ok: bool
		upload, ok = platform.gpu_upload(size_of(Hit_Bin_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			return false
		}
		(^Hit_Bin_Constants)(raw_data(upload.data))^ = constants
	}
	for name, phase in HIT_PHASES {
		step := new_clone(data^, platform.frame_allocator)
		step.phase = phase
		p := add_compute_pass(g, name, run_hit_phase, step, queue = queue)
		write(g, p, data.bins)
		switch phase {
		case 1:
			write(g, p, batch.hits)
		case 2:
			write(g, p, data.arguments)
		case 3:
			// The binning binds the hits for writing in each phase that reads them.
			write(g, p, batch.hits)
			write(g, p, data.order)
		}
	}
	p := add_compute_pass(g, "hit shading", run_hit_shading, data, queue = queue)
	read(g, p, batch.hits)
	read(g, p, data.order)
	read(g, p, data.bins)
	indirect_buffer(g, p, data.arguments)
	read(g, p, sf.instances)
	write(g, p, batch.surfaces)
	return true
}

// ensure_hit_scratch grows a batch's buffers to hold count rays.
@(private = "file")
ensure_hit_scratch :: proc(r: ^Renderer, batch, count: int) -> ^Hit_Scratch {
	s := &r.ray_scene.scratch[batch]
	platform := r.platform
	if s.bins == {} {
		s.bins = platform.gpu_create_buffer({size = 3 * MAX_HIT_BINS * 4, usage = {.Storage}, label = "hit bins"}, nil)
		s.arguments = platform.gpu_create_buffer({size = MAX_HIT_BINS * size_of(gpu.Dispatch_Indirect_Args), usage = {.Storage, .Indirect}, label = "hit arguments"}, nil)
	}
	if count > s.capacity || s.order == {} {
		platform.gpu_destroy_buffer(s.order)
		s.capacity = max(count, s.capacity * 2, 4096)
		s.order = platform.gpu_create_buffer({size = u32(s.capacity * 4), usage = {.Storage}, label = "hit order"}, nil)
	}
	return s
}

// run_hit_phase dispatches a phase of the binning: a thread for each bin, one thread, or a thread for each ray.
@(private = "file")
run_hit_phase :: proc(ctx: ^Pass_Context) {
	data := (^Hit_Shading)(ctx.data)
	pipeline := data.frame.renderer.ray_scene.bin_pipeline.pipeline
	groups: u32
	switch data.phase {
	case 0:
		groups = (MAX_HIT_BINS + HIT_GROUP_SIZE - 1) / HIT_GROUP_SIZE
	case 2:
		groups = 1
	case:
		groups = (data.batch.count + HIT_GROUP_SIZE - 1) / HIT_GROUP_SIZE
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, data.constants[data.phase])
	gpu.cmd_dispatch(ctx.cb, {groups, 1, 1})
}

// run_hit_shading dispatches each bin that the frame's hit table uses, with its material's hit pipeline, or the
// fallback's for bin 0, over the camera's frame constants.
@(private = "file")
run_hit_shading :: proc(ctx: ^Pass_Context) {
	data := (^Hit_Shading)(ctx.data)
	f := data.frame
	r := f.renderer
	sf := f.scene_frame
	g := ctx.graph
	push := Hit_Push {
		hits                 = gpu.read_index(gpu_buffer(g, data.batch.hits)),
		order                = gpu.read_index(gpu_buffer(g, data.order)),
		bins                 = gpu.read_index(gpu_buffer(g, data.bins)),
		surfaces             = gpu.write_index(gpu_buffer(g, data.batch.surfaces)),
		hit_instances        = gpu.read_index(sf.hit_instances.buffer),
		hit_instances_offset = sf.hit_instances.offset,
		hit_submeshes        = gpu.read_index(sf.hit_submeshes.buffer),
		hit_submeshes_offset = sf.hit_submeshes.offset,
	}
	arguments := gpu_buffer(g, data.arguments)
	for bin in sf.hit_bins {
		pipeline := bin == 0 ? r.ray_scene.fallback.pipeline : r.materials.pipelines[bin - 1].hit
		if pipeline == {} {
			continue
		}
		push.bin = bin
		gpu.cmd_set_pipeline(ctx.cb, pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch_indirect(ctx.cb, arguments, bin * size_of(gpu.Dispatch_Indirect_Args))
	}
}
