package render

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// A preview of many meshes (see docs/rendering/materials.md#material-previews): what a prefab's thumbnail draws, each
// mesh with its own pose and materials, framed so that all of it shows. Like a material's preview, it draws no world and
// has no shadows, no clusters and no history.

// The most meshes that it draws, the largest first, and the most submeshes of them. Jungle Ruins has about 1,000
// entities that draw.
MAX_PREVIEW_ITEMS :: 1024
MAX_PREVIEW_DRAWS :: 2048
// How much of each of the renderer's tables a thumbnail leaves to the world, as their limits are hard. It is more than one
// item of a thumbnail can take, as it checks before each.
PREVIEW_ROOM :: 32
// A mesh is flat when its smallest side is this much of its largest.
PREVIEW_FLAT :: 0.01

// Preview_Item is a mesh that a preview draws.
Preview_Item :: struct {
	mesh:      format.Guid,
	materials: [MAX_MATERIAL_SLOTS]format.Guid,
	pose:      ecs.Transform,
}

// Preview_Draw is a submesh that a preview draws, before the draws are grouped by what they draw with.
@(private)
Preview_Draw :: struct {
	record:      Draw_Record,
	pipeline:    int,
	transparent: bool,
}

// Preview_Bin is a run of a preview's draws that one pipeline draws.
@(private)
Preview_Bin :: struct {
	pipeline:    ^Material_Pipeline,
	index:       int,
	first:       u32,
	count:       u32,
	transparent: bool,
}

// preview_group orders draws so that what one pipeline draws is together, with the opaque first, as a transparent draw
// blends over them, and gives the runs.
@(private)
preview_group :: proc(draws: []Preview_Draw, allocator: runtime.Allocator) -> (bins: []Preview_Bin) {
	slice.stable_sort_by(draws, proc(a, b: Preview_Draw) -> bool {
		if a.transparent != b.transparent {
			return !a.transparent
		}
		return a.pipeline < b.pipeline
	})
	out := make([dynamic]Preview_Bin, allocator)
	for d, i in draws {
		if len(out) > 0 && out[len(out) - 1].index == d.pipeline && out[len(out) - 1].transparent == d.transparent {
			out[len(out) - 1].count += 1
		} else {
			append(&out, Preview_Bin{index = d.pipeline, first = u32(i), count = 1, transparent = d.transparent})
		}
	}
	return out[:]
}

// preview_fit is the sphere that holds spheres: the middle of their box, and the distance from it to the farthest edge.
@(private)
preview_fit :: proc(centers: [][3]f32, radii: []f32) -> (center: [3]f32, radius: f32) {
	if len(centers) == 0 {
		return {}, 1
	}
	low, high := centers[0] - radii[0], centers[0] + radii[0]
	for c, i in centers {
		low = linalg.min(low, c - radii[i])
		high = linalg.max(high, c + radii[i])
	}
	center = (low + high) / 2
	for c, i in centers {
		radius = max(radius, linalg.length(c - center) + radii[i])
	}
	return center, max(radius, 0.01)
}

// preview_facing is how to turn a flat mesh so that a camera in a direction sees it, as a mesh has one side and a plane
// that looks away draws nothing. It keeps its up as far as it can. A mesh with depth stays as it is, and its blob is not read.
preview_facing :: proc(data: []byte, blob: ^format.Mesh_Blob, camera: [3]f32) -> quaternion128 {
	size := blob.bounds.max - blob.bounds.min
	if min(size.x, size.y, size.z) > PREVIEW_FLAT * max(size.x, size.y, size.z) {
		return 1
	}
	area := format.mesh_face_area(data, blob)
	if linalg.dot(area, camera) >= 0 {
		return 1
	}
	normal := linalg.normalize(area)
	up := [3]f32{0, 1, 0}
	axis := up - normal * linalg.dot(up, normal)
	if linalg.length(axis) < 0.1 {
		axis = {1, 0, 0}
	}
	return linalg.quaternion_angle_axis_f32(math.PI, linalg.normalize(axis))
}

// preview_distance is how far a camera must be from a sphere to see all of it.
@(private)
preview_distance :: proc(radius: f32) -> f32 {
	return radius / math.sin(f32(PREVIEW_FOV) / 2) * 1.05
}

// preview_largest gives the indices of the count largest of radii, in their order, for a preview with too much to draw.
@(private)
preview_largest :: proc(radii: []f32, count: int, allocator: runtime.Allocator) -> []int {
	order := make([]int, len(radii), context.temp_allocator)
	for i in 0 ..< len(order) {
		order[i] = i
	}
	Sorter :: struct {
		radii: []f32,
	}
	context.user_ptr = &Sorter{radii}
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		s := (^Sorter)(context.user_ptr)
		return s.radii[a] > s.radii[b]
	})
	kept := slice.clone(order[:min(count, len(order))], allocator)
	slice.sort(kept)
	return kept
}

// prefab_preview_items is what a prefab's flat entities draw, each mesh in the prefab's space, in which its root stands
// at the origin as an instance's pose replaces the root's own. With a node, only that entity and its descendants. An
// inactive entity draws nothing, and neither does what is under it.
prefab_preview_items :: proc(scene: format.Scene, node: u64, allocator: runtime.Allocator) -> []Preview_Item {
	OFFSET := format.scene_field_hash("offset")
	ROTATION := format.scene_field_hash("rotation")
	SCALE := format.scene_field_hash("scale")
	MESH := format.scene_field_hash("mesh")
	slots: [MAX_MATERIAL_SLOTS]u64
	for s in 0 ..< MAX_MATERIAL_SLOTS {
		slots[s] = format.scene_field_hash(fmt.tprintf("materials.%d", s))
	}
	by_id := make(map[u64]^format.Scene_Entity, len(scene.entities), context.temp_allocator)
	for &e in scene.entities {
		by_id[e.id] = &e
	}
	local_of :: proc(e: ^format.Scene_Entity, offset_hash, rotation_hash, scale_hash: u64) -> ecs.Local_Transform {
		local := ecs.Local_Transform {
			rotation = 1,
			scale    = 1,
		}
		for c in e.components {
			if c.id != format.SCENE_LOCAL_TRANSFORM_ID {
				continue
			}
			for f in c.fields {
				v := f.value.floats
				switch f.hash {
				case offset_hash:
					local.offset = {f32(v[0]), f32(v[1]), f32(v[2])}
				case rotation_hash:
					local.rotation = quaternion(x = f32(v[0]), y = f32(v[1]), z = f32(v[2]), w = f32(v[3]))
				case scale_hash:
					local.scale = {f32(v[0]), f32(v[1]), f32(v[2])}
				}
			}
		}
		return local
	}
	// The pose of an entity, and whether it draws: active, as all that it is under is, and at or under the node.
	Found :: struct {
		pose:   ecs.Transform,
		active: bool,
		inside: bool,
	}
	memo := make(map[u64]Found, len(scene.entities), context.temp_allocator)
	resolve :: proc(e: ^format.Scene_Entity, node: u64, by_id: ^map[u64]^format.Scene_Entity, memo: ^map[u64]Found, hashes: [3]u64, depth: int) -> Found {
		if known, found := memo[e.id]; found {
			return known
		}
		result := Found {
			pose   = {rotation = 1, scale = 1},
			active = e.active,
			inside = node == 0 || e.id == node,
		}
		if parent, has := by_id[e.parent]; e.parent != 0 && has && depth < 64 {
			above := resolve(parent, node, by_id, memo, hashes, depth + 1)
			result.pose = ecs.compose(above.pose, local_of(e, hashes[0], hashes[1], hashes[2]))
			result.active &&= above.active
			result.inside ||= above.inside
		}
		memo[e.id] = result
		return result
	}
	items := make([dynamic]Preview_Item, allocator)
	for &e in scene.entities {
		found := resolve(&e, node, &by_id, &memo, {OFFSET, ROTATION, SCALE}, 0)
		if !found.active || !found.inside {
			continue
		}
		for c in e.components {
			if c.id != format.SCENE_MESH_RENDERER_ID {
				continue
			}
			item := Preview_Item {
				pose = found.pose,
			}
			for f in c.fields {
				if f.value.kind != .Asset {
					continue
				}
				if f.hash == MESH {
					item.mesh = f.value.asset
				}
				for slot, s in slots {
					if f.hash == slot {
						item.materials[s] = f.value.asset
					}
				}
			}
			if item.mesh != {} {
				append(&items, item)
			}
		}
	}
	return items[:]
}

// preview_has_room is whether a thumbnail can ask for more and still leave the world PREVIEW_ROOM of each table.
preview_has_room :: proc(r: ^Renderer) -> bool {
	return(
		r.materials.ref_count + PREVIEW_ROOM <= MAX_MATERIALS &&
		r.materials.pipeline_count + PREVIEW_ROOM <= MAX_MATERIAL_PIPELINES &&
		r.residency.count + PREVIEW_ROOM <= MAX_RESIDENT \
	)
}

// preview_touch makes what an item draws resident, as a thumbnail does a little at a time, so that a large prefab does not
// hold up one frame with all of its blobs.
preview_touch :: proc(r: ^Renderer, item: ^Preview_Item) {
	r.residency.baking = true
	defer r.residency.baking = false
	resident_mesh(&r.residency, item.mesh)
	table := Material_Table {
		uses  = make(map[format.Guid]Material_Use, r.platform.frame_allocator),
		bytes = make([dynamic]byte, r.platform.frame_allocator),
	}
	for material in item.materials {
		if material != {} {
			use_material(r, &table, material)
		}
	}
}

// add_preview_item_passes adds the passes of a preview of many meshes: one that writes its records, a prepass and a
// forward pass for what is opaque, one for what blends over it, and the output pass into its target. What is not resident
// yet draws next frame, and complete stays false until all of it can.
@(private)
add_preview_item_passes :: proc(f: ^Frame, desc: ^Preview_Desc) {
	r := f.renderer
	g := f.graph
	platform := r.platform
	pf := new(Preview_Frame, platform.frame_allocator)
	pf.renderer, pf.desc, pf.frame = r, desc, f
	table := Material_Table {
		uses  = make(map[format.Guid]Material_Use, platform.frame_allocator),
		bytes = make([dynamic]byte, platform.frame_allocator),
	}
	// A thumbnail's touches are not the world's, so what only it used can go when it is done.
	r.residency.baking = desc.capture != 0
	defer r.residency.baking = false

	Placed :: struct {
		mesh:   ^Resident_Mesh,
		item:   ^Preview_Item,
		center: [3]f32,
		radius: f32,
	}
	settled := true
	placed := make([dynamic]Placed, 0, len(desc.items), context.temp_allocator)
	for &item in desc.items {
		mesh, ready := resident_mesh(&r.residency, item.mesh)
		if !ready {
			settled &&= resident_failed(&r.residency, item.mesh)
			continue
		}
		center := mesh.bounds.center * item.pose.scale
		meters := ecs.position_to_meters(item.pose.position)
		world := [3]f32{f32(meters.x), f32(meters.y), f32(meters.z)} + linalg.quaternion128_mul_vector3(item.pose.rotation, center)
		scale := max(abs(item.pose.scale.x), abs(item.pose.scale.y), abs(item.pose.scale.z))
		append(&placed, Placed{mesh, &item, world, mesh.bounds.radius * scale})
	}
	if len(placed) > MAX_PREVIEW_ITEMS {
		radii := make([]f32, len(placed), context.temp_allocator)
		for p, i in placed {
			radii[i] = p.radius
		}
		kept := make([dynamic]Placed, 0, MAX_PREVIEW_ITEMS, context.temp_allocator)
		for i in preview_largest(radii, MAX_PREVIEW_ITEMS, context.temp_allocator) {
			append(&kept, placed[i])
		}
		placed = kept
	}
	centers := make([][3]f32, len(placed), context.temp_allocator)
	radii := make([]f32, len(placed), context.temp_allocator)
	for p, i in placed {
		centers[i], radii[i] = p.center, p.radius
	}
	center, radius := preview_fit(centers, radii)
	distance := desc.distance > 0 ? desc.distance : preview_distance(radius)
	view := View {
		rotation     = desc.rotation,
		vertical_fov = PREVIEW_FOV,
		near         = max(radius * 0.001, PREVIEW_NEAR),
	}
	view_projection := view_projection(view, f32(desc.size.x) / f32(max(desc.size.y, 1)))
	camera := linalg.quaternion128_mul_vector3(desc.rotation, [3]f32{0, 0, -distance})
	eye := center + camera
	origin := ecs.position_from_meters({f64(eye.x), f64(eye.y), f64(eye.z)})

	instances := make([]Instance_Record, len(placed), platform.frame_allocator)
	meshes := make([]Mesh_Record, len(placed), platform.frame_allocator)
	draws := make([dynamic]Preview_Draw, 0, len(placed), context.temp_allocator)
	for p, i in placed {
		rows := pose_rows(p.item.pose, origin)
		instances[i] = {rows = rows, previous_rows = rows}
		meshes[i] = mesh_record(p.mesh)
		for s in 0 ..< p.mesh.submesh_count {
			if len(draws) == MAX_PREVIEW_DRAWS {
				break
			}
			use, used := use_material(r, &table, p.item.materials[s] if s < MAX_MATERIAL_SLOTS else {})
			if !used {
				settled = false
				continue
			}
			// A material that draws patches or ribbons draws no mesh: the default material stands in, as in the scene.
			if r.materials.pipelines[use.pipeline].patches || r.materials.pipelines[use.pipeline].ribbon {
				use, used = use_material(r, &table, {})
				if !used {
					settled = false
					continue
				}
			}
			submesh := p.mesh.submeshes[s]
			append(&draws, Preview_Draw{
				record = {instance = u32(i), mesh = u32(i), first = submesh.first_index, material = use.block, count = submesh.index_count},
				pipeline = use.pipeline,
				transparent = material_group(&r.materials.pipelines[use.pipeline]) != .Opaque,
			})
		}
	}
	bins := preview_group(draws[:], platform.frame_allocator)
	records := make([]Draw_Record, len(draws), platform.frame_allocator)
	arguments := make([]gpu.Draw_Indirect_Args, len(draws), platform.frame_allocator)
	for d, i in draws {
		records[i] = d.record
		arguments[i] = {draw_id = u32(i), vertex_count = d.record.count, instance_count = 1}
	}
	// A pipeline that failed is as settled as one that compiled: the preview will not change until its shader does.
	ready := platform.gpu_pipeline_status != nil
	any_transparent := false
	for &bin in bins {
		bin.pipeline = &r.materials.pipelines[bin.index]
		any_transparent ||= bin.transparent
		pipelines, count := preview_pipelines(bin.pipeline)
		for p in pipelines[:count] {
			ready &&= p != {} && handle_status(platform, p) != .Compiling
		}
	}
	pf.bins = bins
	pf.draw_count = u32(len(draws))
	pf.instance_count = u32(len(instances))
	if desc.complete != nil {
		desc.complete^ = settled && ready && !table.waiting && lut_ready(f)
	}
	write_preview_item_records(f, pf, instances, records, arguments, meshes, &table, view_projection, camera, view.near)

	pf.target = import_texture(g, desc.target, .Color)
	pf.scene = create_texture(g, {size = desc.size, format = SCENE_FORMAT, label = "preview scene"})
	if pf.constants.data == nil || len(draws) == 0 {
		p := add_render_pass(g, "preview background", proc(_: ^Pass_Context) {}, pf)
		color(g, p, pf.scene, .Clear, PREVIEW_BACKGROUND)
		p = add_render_pass(g, "preview output", draw_preview_output, pf)
		read(g, p, pf.scene)
		read(g, p, f.lut)
		color(g, p, pf.target, .Discard)
		return
	}
	size := desc.size
	pf.depth = create_texture(g, {size = size, format = DEPTH_FORMAT, label = "preview depth"})
	normals := create_texture(g, {size = size, format = NORMAL_FORMAT, label = "preview normals"})
	velocity := create_texture(g, {size = size, format = VELOCITY_FORMAT, label = "preview velocity"})
	roughness := create_texture(g, {size = size, format = ROUGHNESS_FORMAT, label = "preview roughness"})
	ids := create_texture(g, {size = size, format = ID_FORMAT, label = "preview ids"})
	pf.instances = import_buffer(g, r.previews.instances)
	pf.draws = import_buffer(g, r.previews.draws)
	pf.arguments = import_buffer(g, r.previews.arguments)
	p := add_compute_pass(g, "update preview", update_preview, pf)
	copy_dest(g, p, pf.instances)
	copy_dest(g, p, pf.draws)
	copy_dest(g, p, pf.arguments)
	p = add_render_pass(g, "preview prepass", proc(ctx: ^Pass_Context) {draw_preview_bins(ctx, .Prepass)}, pf)
	color(g, p, normals, .Clear, store = .Discard)
	color(g, p, velocity, .Clear, store = .Discard)
	color(g, p, roughness, .Clear, {ROUGHNESS_NONE, 0, 0, 0}, .Discard)
	depth(g, p, pf.depth, .Clear)
	declare_preview_draws(g, p, pf)
	p = add_render_pass(g, "preview", proc(ctx: ^Pass_Context) {draw_preview_bins(ctx, .Forward)}, pf)
	color(g, p, pf.scene, .Clear, PREVIEW_BACKGROUND)
	color(g, p, ids, .Clear, store = .Discard)
	depth(g, p, pf.depth, .Load, store = any_transparent ? .Store : .Discard)
	declare_preview_draws(g, p, pf)
	if any_transparent {
		// A transparent draw has one color target, and blends over what the forward pass drew.
		p = add_render_pass(g, "preview transparent", proc(ctx: ^Pass_Context) {draw_preview_bins(ctx, .Transparent)}, pf)
		color(g, p, pf.scene, .Load)
		depth(g, p, pf.depth, .Load, store = .Discard)
		declare_preview_draws(g, p, pf)
	}
	p = add_render_pass(g, "preview output", draw_preview_output, pf)
	read(g, p, pf.scene)
	read(g, p, f.lut)
	color(g, p, pf.target, .Discard)
}

@(private = "file")
write_preview_item_records :: proc(f: ^Frame, pf: ^Preview_Frame, instances: []Instance_Record, draws: []Draw_Record, arguments: []gpu.Draw_Indirect_Args, meshes: []Mesh_Record, table: ^Material_Table, view_projection: matrix[4, 4]f32, camera: [3]f32, near: f32) {
	r := f.renderer
	platform := r.platform
	desc := pf.desc
	surface: Surface_Record
	// The light comes from over the camera's left shoulder, as in a material's preview.
	direction := linalg.normalize(linalg.quaternion128_mul_vector3(desc.rotation, [3]f32{0.55, -0.6, 0.6}))
	light := Light_Record {
		color     = PREVIEW_LIGHT_COLOR,
		type      = .Directional,
		direction = direction,
		shadow    = -1,
		mask      = -1,
	}
	bytes := make([dynamic]byte, platform.frame_allocator)
	place :: proc(bytes: ^[dynamic]byte, data: []byte) -> u32 {
		for len(bytes) % 16 != 0 {
			append(bytes, 0)
		}
		at := u32(len(bytes))
		append(bytes, ..data)
		return at
	}
	pf.instance_at = place(&bytes, slice.to_bytes(instances))
	pf.draws_at = place(&bytes, slice.to_bytes(draws))
	pf.args_at = place(&bytes, slice.to_bytes(arguments))
	mesh_at := place(&bytes, slice.to_bytes(meshes))
	surface_at := place(&bytes, slice.bytes_from_ptr(&surface, size_of(surface)))
	table_at := place(&bytes, table.bytes[:])
	light_at := place(&bytes, slice.bytes_from_ptr(&light, size_of(light)))
	upload, ok := upload_bytes(platform, bytes[:])
	if !ok {
		return
	}
	pf.records = upload
	preview_write_constants(pf, r, desc, upload, view_projection, camera, near, mesh_at, surface_at, table_at, light_at)
}

@(private = "file")
draw_preview_bins :: proc(ctx: ^Pass_Context, pass: format.Material_Pass) {
	pf := (^Preview_Frame)(ctx.data)
	cb := ctx.cb
	gpu.cmd_set_stencil_reference(cb, 0)
	for bin in pf.bins {
		if bin.transparent != (pass == .Transparent) {
			continue
		}
		pipelines := [2]gpu.Pipeline{{}, bin.pipeline.pipelines[pass]}
		if pass == .Transparent {
			pipelines = bin.pipeline.over
		}
		for pipeline in pipelines {
			if pipeline == {} {
				continue
			}
			gpu.cmd_set_pipeline(cb, pipeline)
			gpu.cmd_set_pass_constants(cb, pf.constants)
			if pass != .Prepass {
				white := gpu.read_index(pf.renderer.materials.defaults[.White])
				push := Material_Push{shadow_atlas = white, shadow_mask = white, ambient_occlusion = white, fog = white, gi_diffuse = white, gi_specular = white}
				gpu.cmd_push_constants(cb, &push)
			}
			gpu.cmd_draw_indirect(cb, gpu_buffer(ctx.graph, pf.arguments), bin.first * size_of(gpu.Draw_Indirect_Args), bin.count)
		}
	}
}
