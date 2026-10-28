package render

import "core:math"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"

// Material previews (see docs/rendering/materials.md#material-previews): a frame can draw a material on one mesh into a target of
// its own, as the editor's material editor shows it. A preview draws no world: its mesh, lit by one directional light
// and the ambient light, with the material's prepass and forward pipelines, then the output pass's tone mapping
// through the frame's lookup table. Its records are relative to its camera, which orbits the mesh's middle. It has no
// shadows, no clusters, no history and no exposure.

// The engine's preview meshes, a sphere, a cube and a plane, each 1 m across (lib/engine/content/models/preview.gltf),
// by their .meta file.
PREVIEW_MESHES :: #load("../content/models/preview.gltf.meta", string)

Preview_Shape :: enum {
	Sphere,
	Cube,
	Plane,
}

// The preview's camera, its light and its background.
PREVIEW_FOV :: math.PI / 4
PREVIEW_NEAR :: 0.01
PREVIEW_LIGHT_COLOR :: [3]f32{3, 2.9, 2.75}
PREVIEW_BACKGROUND :: [4]f32{0.02, 0.022, 0.026, 1}

// Preview_Desc is a preview that a frame draws, in frame memory.
Preview_Desc :: struct {
	// The target, in FRAME_TARGET_FORMAT, in the render target layout, as gpu_preview_target gives it.
	target:   gpu.Texture,
	size:     [2]u32,
	// Which preview this is, below gpu.MAX_PREVIEW_TARGETS: it keeps the pipelines of its unsaved material.
	id:       int,
	// The material or instance. With data, its blob instead of the cooked one, as the editor's unsaved graph cooks it,
	// and a version that changes with the data.
	material: format.Guid,
	data:     []byte,
	version:  u32,
	mesh:     format.Guid,
	// The camera turns about the mesh's middle, at a distance in meters.
	rotation: quaternion128,
	distance: f32,
	// If not nil, draw_frame sets it when the mesh, the material's pipelines and its textures were ready, so the
	// preview shows the material as it is. A preview that is not complete draws again in a later frame.
	complete: ^bool,
}

// Previews is the previews' state between frames, in the Renderer: the records of the one that a frame draws, and the
// pipelines of each preview's unsaved material.
Previews :: struct {
	instances: gpu.Buffer,
	draws:     gpu.Buffer,
	arguments: gpu.Buffer,
	unsaved:   [gpu.MAX_PREVIEW_TARGETS]Material_Pipeline,
}

// Preview_Frame is what one preview's passes need, in frame memory.
@(private)
Preview_Frame :: struct {
	renderer:    ^Renderer,
	frame:       ^Frame,
	desc:        ^Preview_Desc,
	pipeline:    ^Material_Pipeline,
	draw_count:  u32,
	records:     gpu.Upload,
	constants:   gpu.Upload,
	instances:   Buffer,
	draws:       Buffer,
	arguments:   Buffer,
	scene:       Texture,
	depth:       Texture,
	target:      Texture,
	instance_at: u32,
	draws_at:    u32,
	args_at:     u32,
}

// preview_mesh is the GUID of one of the engine's preview meshes.
preview_mesh :: proc(shape: Preview_Shape) -> format.Guid {
	meta, _ := format.meta_parse(PREVIEW_MESHES, context.temp_allocator)
	names := [Preview_Shape]string {
		.Sphere = "Sphere",
		.Cube   = "Cube",
		.Plane  = "Plane",
	}
	guid, _ := format.meta_subasset(meta, "mesh", names[shape])
	return guid
}

previews_init :: proc(p: ^Previews, r: ^Renderer) {
	platform := r.platform
	p.instances = platform.gpu_create_buffer({size = size_of(Instance_Record), label = "preview instance"}, nil)
	p.draws = platform.gpu_create_buffer({size = MAX_SUBMESHES * size_of(Draw_Record), label = "preview draws"}, nil)
	p.arguments = platform.gpu_create_buffer({size = MAX_SUBMESHES * size_of(gpu.Draw_Indirect_Args), usage = {.Storage, .Indirect}, label = "preview arguments"}, nil)
}

previews_destroy :: proc(p: ^Previews, r: ^Renderer) {
	platform := r.platform
	for b in ([]gpu.Buffer{p.instances, p.draws, p.arguments}) {
		platform.gpu_destroy_buffer(b)
	}
	for &u in p.unsaved {
		material_pipeline_destroy(&u, platform)
	}
	p^ = {}
}

// preview_use gives a preview's material as its frame draws it: from its unsaved blob, with the pipelines that the
// preview keeps for it, or as the scene draws a material.
@(private = "file")
preview_use :: proc(r: ^Renderer, table: ^Material_Table, desc: ^Preview_Desc) -> (pipeline: ^Material_Pipeline, block: u32, ok: bool) {
	if desc.data == nil {
		use := use_material(r, table, desc.material) or_return
		return &r.materials.pipelines[use.pipeline], use.block, true
	}
	blob := format.material_view(desc.data) or_return
	b := material_block(desc.data, desc.material) or_return
	main := format.material_main_pass(blob)
	if format.material_code(desc.data, blob, b.switches, main, .Vertex) == nil {
		return
	}
	p := &r.previews.unsaved[desc.id]
	if p.material != desc.material || p.version != desc.version || p.pipelines[main] == {} && p.over[1] == {} {
		make_pipelines(r, p, desc.data, blob, b.switches)
		p.material, p.version = desc.material, desc.version
	}
	return p, add_block(r, table, b), true
}

// add_preview_passes adds a preview's passes to the frame: one that writes its records, its prepass and its forward
// pass, and the output pass into its target. Without its mesh or its material, it clears the target to the background.
@(private)
add_preview_passes :: proc(f: ^Frame, desc: ^Preview_Desc) {
	r := f.renderer
	g := f.graph
	platform := r.platform
	pf := new(Preview_Frame, platform.frame_allocator)
	pf.renderer, pf.desc = r, desc
	size := desc.size
	aspect := f32(size.x) / f32(max(size.y, 1))
	view := View {
		rotation     = desc.rotation,
		vertical_fov = PREVIEW_FOV,
		near         = PREVIEW_NEAR,
	}
	view_projection := view_projection(view, aspect)

	table := Material_Table {
		uses  = make(map[format.Guid]Material_Use, platform.frame_allocator),
		bytes = make([dynamic]byte, platform.frame_allocator),
	}
	mesh, mesh_ready := resident_mesh(&r.residency, desc.mesh)
	pipeline, block, material_ok := preview_use(r, &table, desc)
	// A patches material draws one patch in the mesh's place (see docs/rendering/surfaces.md#surfaces).
	patches := material_ok && pipeline.patches
	if (mesh_ready || patches) && material_ok {
		pf.pipeline = pipeline
		pf.draw_count = patches ? 1 : mesh.submesh_count
		ready := platform.gpu_pipeline_ready != nil
		pipelines, count := preview_pipelines(pipeline)
		for p in pipelines[:count] {
			ready &&= p != {} && platform.gpu_pipeline_ready(p)
		}
		if desc.complete != nil {
			// The output pass tone maps with the lookup table only once it is baked.
			desc.complete^ = ready && !table.waiting && r.post.lut_baked
		}
		write_preview_records(f, pf, patches ? nil : mesh, block, &table, view_projection)
	}

	pf.target = import_texture(g, desc.target, .Color)
	pf.scene = create_texture(g, {size = size, format = SCENE_FORMAT, label = "preview scene"})
	if pf.constants.data != nil {
		pf.depth = create_texture(g, {size = size, format = DEPTH_FORMAT, label = "preview depth"})
		normals := create_texture(g, {size = size, format = NORMAL_FORMAT, label = "preview normals"})
		velocity := create_texture(g, {size = size, format = VELOCITY_FORMAT, label = "preview velocity"})
		ids := create_texture(g, {size = size, format = ID_FORMAT, label = "preview ids"})
		pf.instances = import_buffer(g, r.previews.instances)
		pf.draws = import_buffer(g, r.previews.draws)
		pf.arguments = import_buffer(g, r.previews.arguments)
		p := add_compute_pass(g, "update preview", update_preview, pf)
		copy_dest(g, p, pf.instances)
		copy_dest(g, p, pf.draws)
		copy_dest(g, p, pf.arguments)
		p = add_render_pass(g, "preview prepass", proc(ctx: ^Pass_Context) {draw_preview(ctx, .Prepass)}, pf)
		color(g, p, normals, .Clear, store = .Discard)
		color(g, p, velocity, .Clear, store = .Discard)
		depth(g, p, pf.depth, .Clear)
		declare_preview_draws(g, p, pf)
		if pf.pipeline != nil && material_group(pf.pipeline) != .Opaque {
			// A transparent material's preview blends over the background, as a sorted draw does: it has no moments.
			p = add_render_pass(g, "preview", proc(ctx: ^Pass_Context) {draw_preview(ctx, .Transparent)}, pf)
			color(g, p, pf.scene, .Clear, PREVIEW_BACKGROUND)
		} else {
			p = add_render_pass(g, "preview", proc(ctx: ^Pass_Context) {draw_preview(ctx, .Forward)}, pf)
			color(g, p, pf.scene, .Clear, PREVIEW_BACKGROUND)
			color(g, p, ids, .Clear, store = .Discard)
		}
		depth(g, p, pf.depth, .Load, store = .Discard)
		declare_preview_draws(g, p, pf)
	} else {
		p := add_render_pass(g, "preview background", proc(_: ^Pass_Context) {}, pf)
		color(g, p, pf.scene, .Clear, PREVIEW_BACKGROUND)
	}
	pf.frame = f
	p := add_render_pass(g, "preview output", draw_preview_output, pf)
	read(g, p, pf.scene)
	read(g, p, f.lut)
	color(g, p, pf.target, .Discard)
}

// write_preview_records uploads the preview's records: its instance, relative to its camera, a draw for each submesh,
// the mesh's record, the material table, its light, and its Frame_Constants. Without a mesh, the preview is a
// patches material's one patch, with a surface record in the mesh record's place.
@(private = "file")
write_preview_records :: proc(f: ^Frame, pf: ^Preview_Frame, mesh: ^Resident_Mesh, block: u32, table: ^Material_Table, view_projection: matrix[4, 4]f32) {
	r := f.renderer
	platform := r.platform
	desc := pf.desc
	// The mesh's middle is at the orbit's center, and the camera is distance behind it along its own +z.
	center: [3]f32
	if mesh != nil {
		center = mesh.bounds.center
	}
	camera := linalg.quaternion128_mul_vector3(desc.rotation, [3]f32{0, 0, -desc.distance})
	offset := -center - camera
	rows := [3][4]f32{{1, 0, 0, offset.x}, {0, 1, 0, offset.y}, {0, 0, 1, offset.z}}
	instance := Instance_Record {
		rows          = rows,
		previous_rows = rows,
	}
	draws := make([]Draw_Record, pf.draw_count, platform.frame_allocator)
	arguments := make([]gpu.Draw_Indirect_Args, pf.draw_count, platform.frame_allocator)
	record: Mesh_Record
	surface: Surface_Record
	if mesh == nil {
		draws[0] = {instance = 0, mesh = 0, first = 0, material = block, count = SURFACE_PATCH_VERTICES}
		arguments[0] = {draw_id = 0, vertex_count = SURFACE_PATCH_VERTICES, instance_count = 1}
		surface = preview_surface(r, pf.pipeline.displacement_bound)
	} else {
		for s in 0 ..< pf.draw_count {
			submesh := mesh.submeshes[s]
			draws[s] = {instance = 0, mesh = 0, first = submesh.first_index, material = block, count = submesh.index_count}
			arguments[s] = {draw_id = s, vertex_count = submesh.index_count, instance_count = 1}
		}
		record = mesh_record(mesh)
	}
	// The light comes from over the camera's left shoulder, so it turns with the camera.
	direction := linalg.normalize(linalg.quaternion128_mul_vector3(desc.rotation, [3]f32{0.55, -0.6, 0.6}))
	light := Light_Record {
		color     = PREVIEW_LIGHT_COLOR,
		type      = .Directional,
		direction = direction,
		shadow    = -1,
		mask      = -1,
	}

	// The records go in one upload, each at its own place. The instance and the draws are copied into the previews'
	// buffers, which the shaders read from their starts.
	bytes := make([dynamic]byte, platform.frame_allocator)
	place :: proc(bytes: ^[dynamic]byte, data: []byte) -> u32 {
		for len(bytes) % 16 != 0 {
			append(bytes, 0)
		}
		at := u32(len(bytes))
		append(bytes, ..data)
		return at
	}
	pf.instance_at = place(&bytes, slice.bytes_from_ptr(&instance, size_of(instance)))
	pf.draws_at = place(&bytes, slice.to_bytes(draws))
	pf.args_at = place(&bytes, slice.to_bytes(arguments))
	mesh_at := place(&bytes, slice.bytes_from_ptr(&record, size_of(record)))
	surface_at := place(&bytes, slice.bytes_from_ptr(&surface, size_of(surface)))
	table_at := place(&bytes, table.bytes[:])
	light_at := place(&bytes, slice.bytes_from_ptr(&light, size_of(light)))
	upload, ok := upload_bytes(platform, bytes[:])
	if !ok {
		return
	}
	pf.records = upload
	buffer := gpu.read_index(upload.buffer)
	right, up, _ := view_axes({rotation = desc.rotation})
	constants := Frame_Constants {
		// A billboard faces the orbiting camera.
		camera_right             = {right.x, right.y, right.z, 0},
		camera_up                = {up.x, up.y, up.z, 0},
		previous_camera_right    = {right.x, right.y, right.z, 0},
		previous_camera_up       = {up.x, up.y, up.z, 0},
		view_projection          = view_projection,
		previous_view_projection = view_projection,
		cluster_view_projection  = view_projection,
		// The preview's world has its origin at the mesh's middle.
		origin_offset            = {camera.x, camera.y, camera.z, 0},
		sky_color                = {DEFAULT_AMBIENT.sky.r, DEFAULT_AMBIENT.sky.g, DEFAULT_AMBIENT.sky.b, 0},
		ground_color             = {DEFAULT_AMBIENT.ground.r, DEFAULT_AMBIENT.ground.g, DEFAULT_AMBIENT.ground.b, 0},
		instances                = gpu.read_index(r.previews.instances),
		draws                    = gpu.read_index(r.previews.draws),
		meshes                   = buffer,
		materials                = buffer,
		sampler_index            = gpu.sampler_index(r.materials.sampler),
		time                     = frame_time(r),
		previous_time            = frame_time(r),
		meshes_offset            = upload.offset + mesh_at,
		materials_offset         = upload.offset + table_at,
		surfaces                 = buffer,
		surfaces_offset          = upload.offset + surface_at,
		lights                   = buffer,
		lights_offset            = upload.offset + light_at,
		directional_count        = 1,
		near                     = PREVIEW_NEAR,
		shadow_sampler           = gpu.sampler_index(r.shadows.sampler),
		screen_size              = {f32(desc.size.x), f32(desc.size.y)},
		exposure                 = gpu.read_index(r.post.unit_exposure),
		ltc_matrix               = gpu.read_index(r.lights.ltc_matrix),
		ltc_amplitude            = gpu.read_index(r.lights.ltc_amplitude),
		ltc_sampler              = gpu.sampler_index(r.lights.ltc_sampler),
	}
	pf.constants, ok = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Frame_Constants)(raw_data(pf.constants.data))^ = constants
}

@(private = "file")
declare_preview_draws :: proc(g: ^Graph, p: Pass, pf: ^Preview_Frame) {
	indirect_buffer(g, p, pf.arguments)
	read(g, p, pf.draws)
	read(g, p, pf.instances)
}

@(private = "file")
update_preview :: proc(ctx: ^Pass_Context) {
	pf := (^Preview_Frame)(ctx.data)
	g := ctx.graph
	u := pf.records
	gpu.cmd_copy_buffer(ctx.cb, u.buffer, u.offset + pf.instance_at, gpu_buffer(g, pf.instances), 0, size_of(Instance_Record))
	gpu.cmd_copy_buffer(ctx.cb, u.buffer, u.offset + pf.draws_at, gpu_buffer(g, pf.draws), 0, pf.draw_count * size_of(Draw_Record))
	gpu.cmd_copy_buffer(ctx.cb, u.buffer, u.offset + pf.args_at, gpu_buffer(g, pf.arguments), 0, pf.draw_count * size_of(gpu.Draw_Indirect_Args))
}

// preview_pipelines are the pipelines that a preview draws with: an opaque material's prepass and forward pass, or a
// transparent one's passes over the scene, its back faces first.
@(private = "file")
preview_pipelines :: proc(p: ^Material_Pipeline) -> (pipelines: [2]gpu.Pipeline, count: int) {
	if material_group(p) == .Opaque {
		return {p.pipelines[.Prepass], p.pipelines[.Forward]}, 2
	}
	if p.two_sided {
		return p.over, 2
	}
	return {p.over[1], {}}, 1
}

@(private = "file")
draw_preview :: proc(ctx: ^Pass_Context, pass: format.Material_Pass) {
	pf := (^Preview_Frame)(ctx.data)
	if pf.draw_count == 0 {
		return
	}
	pipelines := [2]gpu.Pipeline{{}, pf.pipeline.pipelines[pass]}
	if pass == .Transparent {
		pipelines = pf.pipeline.over
	}
	cb := ctx.cb
	gpu.cmd_set_stencil_reference(cb, 0)
	for pipeline in pipelines {
		if pipeline == {} {
			continue
		}
		gpu.cmd_set_pipeline(cb, pipeline)
		gpu.cmd_set_pass_constants(cb, pf.constants)
		if pass == .Forward || pass == .Transparent {
			white := gpu.read_index(pf.renderer.materials.defaults[.White])
			push := Material_Push{shadow_atlas = white, shadow_mask = white, ambient_occlusion = white, fog = white, gi_diffuse = white, gi_specular = white}
			gpu.cmd_push_constants(cb, &push)
		}
		gpu.cmd_draw_indirect(cb, gpu_buffer(ctx.graph, pf.arguments), 0, pf.draw_count)
	}
}

@(private = "file")
draw_preview_output :: proc(ctx: ^Pass_Context) {
	pf := (^Preview_Frame)(ctx.data)
	g := ctx.graph
	output := pf.renderer.output_pipelines[.Sdr].pipeline
	if output == {} {
		return
	}
	push := output_push(pf.frame, gpu_texture(g, pf.scene), .Sdr)
	push.size = pf.desc.size
	gpu.cmd_set_pipeline(ctx.cb, output)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
}
