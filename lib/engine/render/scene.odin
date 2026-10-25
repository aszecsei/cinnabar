package render

import "core:log"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The GPU scene (see docs/rendering.md#gpu-scene): every Mesh_Renderer's instance at a stable slot of a persistent
// buffer, its pose relative to a render origin that snaps to a 1024 m grid. Each frame writes every slot, then culls
// each submesh of each instance on the GPU into the bin of its material's pipeline, and the world pass draws each bin
// with one indirect draw.

// The render origin snaps to cells of 1024 m: 2^34 units of 2^-24 m.
ORIGIN_CELL_BITS :: 34
ORIGIN_CELL :: f32(1 << (ORIGIN_CELL_BITS - 24))
// The origin moves when the camera is more than this many cells from it on any axis.
REBASE_CELLS :: 1.5
// At most this many instances.
MAX_INSTANCES :: 16384
// A Mesh_Renderer's material slots, one for each of its mesh's first submeshes.
MAX_MATERIAL_SLOTS :: 8
CULL_GROUP_SIZE :: 64

// CULL_SHADER is the engine's culling shader (lib/engine/content/shaders/cull_draws.hlsl), by its .meta file.
CULL_SHADER :: #load("../content/shaders/cull_draws.hlsl.meta", string)

// Frame_Constants matches Frame_Constants in material_common.hlsli: the material passes' constants.
Frame_Constants :: struct {
	view_projection: matrix[4, 4]f32,
	camera_offset:   [4]f32,
	sun_direction:   [4]f32,
	sun_color:       [4]f32,
	sky_color:       [4]f32,
	ground_color:    [4]f32,
	instances:       u32,
	draws:           u32,
	// The mesh records and the material table are in the upload ring, at these offsets of its buffer.
	meshes:          u32,
	materials:       u32,
	sampler_index:   u32,
	time:            f32,
	meshes_offset:   u32,
	materials_offset: u32,
}

// Draw_Record matches Draw_Record in material_common.hlsli. material is its block's offset in the material table.
Draw_Record :: struct {
	instance:    u32,
	mesh:        u32,
	first_index: u32,
	material:    u32,
}

MESH_RECORD_INDEX32 :: 1
MESH_RECORD_UV1 :: 2
MESH_RECORD_COLOR :: 4

// Mesh_Record matches Mesh_Record in material_common.hlsli: a resident mesh's buffers, as bindless indices.
Mesh_Record :: struct {
	positions:        u32,
	attributes:       u32,
	indices:          u32,
	attribute_stride: u32,
	flags:            u32,
	padding:          [3]u32,
}

// Instance_Record matches Instance_Record in material_common.hlsli and cull_draws.hlsl: the pose relative to the
// render origin, last frame's, and the entity's value in the ID buffer.
Instance_Record :: struct {
	rows:          [3][4]f32,
	previous_rows: [3][4]f32,
	id:            u32,
	flags:         u32,
	padding:       [2]u32,
}

// Cull_Item matches Item in cull_draws.hlsl.
Cull_Item :: struct {
	instance:    u32,
	mesh:        u32,
	first_index: u32,
	index_count: u32,
	material:    u32,
	bin:         u32,
	padding:     [2]u32,
	sphere:      [4]f32,
}

// Cull_Constants matches Cull_Constants in cull_draws.hlsl.
Cull_Constants :: struct {
	planes:        [5][4]f32,
	camera_offset: [4]f32,
	item_count:    u32,
	// The items and the bins' first draws are in the upload ring, at these offsets of its buffer.
	items:         u32,
	items_offset:  u32,
	instances:     u32,
	arguments:     u32,
	draws:         u32,
	counts:        u32,
	bin_offsets:   u32,
	bin_offsets_offset: u32,
}

#assert(size_of(Instance_Record) == 112 && size_of(Cull_Item) == 48 && size_of(Draw_Record) == 16 && size_of(Mesh_Record) == 32)

// Gpu_Scene is the GPU scene's state between frames, in the Renderer.
Gpu_Scene :: struct {
	origin:        ecs.World_Position,
	origin_set:    bool,
	// The slot of each entity with a Mesh_Renderer, in host memory.
	slots:         map[ecs.Entity]u32,
	slot_entities: [MAX_INSTANCES]ecs.Entity,
	// Each slot's presented pose in the last frame, and the frame that last wrote it.
	previous:      [MAX_INSTANCES]ecs.Transform,
	seen:          [MAX_INSTANCES]u64,
	free:          [dynamic]u32,
	// Slots below this have been used.
	high:          u32,
	frame:         u64,
	instances:     gpu.Buffer,
	// This frame's indirect draws and draw records, and each bin's count, which grow with the frame's draws.
	arguments:     gpu.Buffer,
	draws:         gpu.Buffer,
	counts:        gpu.Buffer,
	capacity:      int,
	bin_capacity:  int,
	cull_pipeline: Shader_Pipeline,
}

// Scene_Frame is what one frame's GPU scene passes need, in frame memory.
@(private)
Scene_Frame :: struct {
	items:           []Cull_Item,
	// A material pipeline for each bin, and each bin's first draw and its count of items.
	bin_pipelines:   []int,
	bin_offsets:     []u32,
	bin_counts:      []u32,
	instance_upload: gpu.Upload,
	instance_bytes:  int,
	item_upload:     gpu.Upload,
	bin_upload:      gpu.Upload,
	zero_upload:     gpu.Upload,
	frame_constants: gpu.Upload,
	cull_constants:  gpu.Upload,
	instances:       Buffer,
	arguments:       Buffer,
	draws:           Buffer,
	counts:          Buffer,
}

scene_init :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	s.slots = make(map[ecs.Entity]u32, platform.heap_allocator)
	s.free = make([dynamic]u32, platform.heap_allocator)
	s.instances = platform.gpu_create_buffer({size = MAX_INSTANCES * size_of(Instance_Record), label = "gpu scene instances"}, nil)
	s.cull_pipeline = shader_pipeline(CULL_SHADER)
}

scene_destroy :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	delete(s.slots)
	delete(s.free)
	for b in ([]gpu.Buffer{s.instances, s.arguments, s.draws, s.counts}) {
		platform.gpu_destroy_buffer(b)
	}
	destroy_shader_pipeline(&s.cull_pipeline, platform)
}

// snap_origin is the corner of the 1024 m cell that holds a position.
snap_origin :: proc(p: ecs.World_Position) -> ecs.World_Position {
	mask := ~i64((1 << ORIGIN_CELL_BITS) - 1)
	return {raw = {p.raw.x & mask, p.raw.y & mask, p.raw.z & mask}}
}

// build_scene writes the GPU scene for the frame and adds its passes: one that writes the instances and clears the
// bins' counts, and one that culls the draw items into the bins. The world pass then draws each bin.
@(private)
build_scene :: proc(f: ^Frame, w: ^ecs.World, hidden: []u32, sun: Sun) {
	r := f.renderer
	s := &r.scene
	s.frame += 1
	sf := new(Scene_Frame, r.platform.frame_allocator)
	f.scene_frame = sf

	// The origin moves when the camera is far from it, and then every pose is written relative to the new one.
	if !s.origin_set || max_abs(ecs.position_sub(f.view.position, s.origin)) > REBASE_CELLS * ORIGIN_CELL {
		s.origin, s.origin_set = snap_origin(f.view.position), true
	}
	sync_compute_pipeline(&s.cull_pipeline, r.platform, r.residency.assets, {label = "cull draws"}, r.reloaded)

	table := Material_Table {
		uses  = make(map[format.Guid]Material_Use, r.platform.frame_allocator),
		bytes = make([dynamic]byte, r.platform.frame_allocator),
	}
	meshes := make([dynamic]Mesh_Record, r.platform.frame_allocator)
	mesh_indices := make(map[^Resident_Mesh]u32, r.platform.frame_allocator)
	items := make([dynamic]Cull_Item, r.platform.frame_allocator)
	records := make([]Instance_Record, MAX_INSTANCES, r.platform.frame_allocator)

	it := ecs.query_iter(w, r.meshes.query)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Mesh_Renderer)
		for e, i in entities {
			slot, slot_ok := scene_slot(s, e)
			if !slot_ok {
				continue
			}
			pose := current[i]
			if previous != nil {
				pose = ecs.interpolate(ecs.Transform(previous[i]), pose, w.clock.alpha)
			}
			last := s.seen[slot] == s.frame - 1 ? s.previous[slot] : pose
			records[slot] = {rows = pose_rows(pose, s.origin), previous_rows = pose_rows(last, s.origin), id = entity_id(e)}
			s.previous[slot], s.seen[slot] = pose, s.frame
			if is_hidden(hidden, e) {
				continue
			}
			add_items(r, &table, &meshes, &mesh_indices, &items, renderers[i], slot)
		}
	}
	// A slot whose entity has no Mesh_Renderer any more is free again.
	for slot in 0 ..< s.high {
		if s.seen[slot] != s.frame && s.slot_entities[slot] != 0 {
			delete_key(&s.slots, s.slot_entities[slot])
			s.slot_entities[slot] = 0
			append(&s.free, slot)
		}
	}

	// Each pipeline's items are a bin, in one range of the frame's draws.
	slice.sort_by(items[:], proc(a, b: Cull_Item) -> bool {return a.bin < b.bin})
	pipelines := make([dynamic]int, r.platform.frame_allocator)
	pipeline_bins := make(map[int]u32, r.platform.frame_allocator)
	for &item in items {
		pipeline := int(item.bin)
		bin, seen := pipeline_bins[pipeline]
		if !seen {
			bin = u32(len(pipelines))
			pipeline_bins[pipeline] = bin
			append(&pipelines, pipeline)
		}
		item.bin = bin
	}
	sf.items, sf.bin_pipelines = items[:], pipelines[:]
	sf.bin_offsets = make([]u32, max(len(pipelines), 1), r.platform.frame_allocator)
	sf.bin_counts = make([]u32, max(len(pipelines), 1), r.platform.frame_allocator)
	for item in items {
		sf.bin_counts[item.bin] += 1
	}
	for b in 1 ..< len(pipelines) {
		sf.bin_offsets[b] = sf.bin_offsets[b - 1] + sf.bin_counts[b - 1]
	}
	ensure_draw_buffers(r, len(items), len(pipelines))

	platform := r.platform
	upload :: proc(platform: ^core.Platform_API, data: []byte, align := 16) -> (u: gpu.Upload, ok: bool) {
		u = platform.gpu_upload(max(len(data), 16), align) or_return
		copy(u.data, data)
		return u, true
	}
	ok := true
	sf.instance_bytes = int(s.high) * size_of(Instance_Record)
	sf.instance_upload, ok = upload(platform, slice.to_bytes(records[:s.high]))
	item_upload, items_ok := upload(platform, slice.to_bytes(items[:]))
	mesh_upload, meshes_ok := upload(platform, slice.to_bytes(meshes[:]))
	table_upload, table_ok := upload(platform, table.bytes[:])
	bin_upload, bins_ok := upload(platform, slice.to_bytes(sf.bin_offsets))
	zeros := make([]byte, max(len(pipelines), 1) * 4, platform.frame_allocator)
	zero_upload, zeros_ok := upload(platform, zeros)
	if !(ok && items_ok && meshes_ok && table_ok && bins_ok && zeros_ok) {
		log.error("render: the upload ring is full, so the frame draws no meshes")
		sf.items = nil
		return
	}
	sf.item_upload, sf.bin_upload, sf.zero_upload = item_upload, bin_upload, zero_upload

	g := f.graph
	sf.instances = import_buffer(g, s.instances)
	sf.arguments = import_buffer(g, s.arguments)
	sf.draws = import_buffer(g, s.draws)
	sf.counts = import_buffer(g, s.counts)
	camera_offset := ecs.position_sub(f.view.position, s.origin)
	frame_constants := Frame_Constants {
		view_projection = f.view_projection,
		camera_offset   = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		sun_direction   = {sun.direction.x, sun.direction.y, sun.direction.z, 0},
		sun_color       = {sun.color.r, sun.color.g, sun.color.b, 0},
		sky_color       = {sun.sky.r, sun.sky.g, sun.sky.b, 0},
		ground_color    = {sun.ground.r, sun.ground.g, sun.ground.b, 0},
		instances       = gpu.read_index(s.instances),
		draws           = gpu.read_index(s.draws),
		meshes          = gpu.read_index(mesh_upload.buffer),
		materials       = gpu.read_index(table_upload.buffer),
		sampler_index   = gpu.sampler_index(r.materials.sampler),
		meshes_offset   = mesh_upload.offset,
		materials_offset = table_upload.offset,
	}
	sf.frame_constants, ok = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		sf.items = nil
		return
	}
	(^Frame_Constants)(raw_data(sf.frame_constants.data))^ = frame_constants

	cull := Cull_Constants {
		planes        = frustum_planes(f.view_projection),
		camera_offset = frame_constants.camera_offset,
		item_count    = u32(len(items)),
		items         = gpu.read_index(item_upload.buffer),
		items_offset  = item_upload.offset,
		instances     = gpu.read_index(s.instances),
		arguments     = gpu.write_index(s.arguments),
		draws         = gpu.write_index(s.draws),
		counts        = gpu.write_index(s.counts),
		bin_offsets   = gpu.read_index(bin_upload.buffer),
		bin_offsets_offset = bin_upload.offset,
	}
	sf.cull_constants, ok = platform.gpu_upload(size_of(Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		sf.items = nil
		return
	}
	(^Cull_Constants)(raw_data(sf.cull_constants.data))^ = cull

	p := add_compute_pass(g, "update scene", update_scene, f)
	copy_dest(g, p, sf.instances)
	copy_dest(g, p, sf.counts)
	p = add_compute_pass(g, "cull draws", cull_draws, f)
	read(g, p, sf.instances)
	write(g, p, sf.arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
}

@(private = "file")
max_abs :: proc(v: [3]f32) -> f32 {
	return max(abs(v.x), abs(v.y), abs(v.z))
}

@(private = "file")
is_hidden :: proc(hidden: []u32, e: ecs.Entity) -> bool {
	index := ecs.entity_index(e)
	return int(index / 32) < len(hidden) && hidden[index / 32] & (1 << (index % 32)) != 0
}

// scene_slot gives an entity's slot, and a free one the first time.
@(private = "file")
scene_slot :: proc(s: ^Gpu_Scene, e: ecs.Entity) -> (slot: u32, ok: bool) {
	if found, has := s.slots[e]; has {
		return found, true
	}
	switch {
	case len(s.free) > 0:
		slot = pop(&s.free)
	case s.high < MAX_INSTANCES:
		slot = s.high
		s.high += 1
	case:
		log.errorf("render: more than %d instances", MAX_INSTANCES)
		return
	}
	s.slots[e] = slot
	s.slot_entities[slot] = e
	return slot, true
}

// add_items adds a draw item for each submesh of a Mesh_Renderer whose mesh is resident, with its material's block and
// pipeline. An item's bin holds its pipeline until build_scene numbers the bins.
@(private = "file")
add_items :: proc(r: ^Renderer, table: ^Material_Table, meshes: ^[dynamic]Mesh_Record, mesh_indices: ^map[^Resident_Mesh]u32, items: ^[dynamic]Cull_Item, renderer: Mesh_Renderer, slot: u32) {
	mesh, ready := resident_mesh(&r.residency, renderer.mesh)
	if !ready {
		return
	}
	mesh_index, known := mesh_indices[mesh]
	if !known {
		flags: u32
		if mesh.index_format == .U32 {
			flags |= MESH_RECORD_INDEX32
		}
		if .UV1 in mesh.flags {
			flags |= MESH_RECORD_UV1
		}
		if .Color in mesh.flags {
			flags |= MESH_RECORD_COLOR
		}
		mesh_index = u32(len(meshes))
		append(meshes, Mesh_Record{gpu.read_index(mesh.positions), gpu.read_index(mesh.attributes), gpu.read_index(mesh.indices), mesh.attribute_stride, flags, {}})
		mesh_indices[mesh] = mesh_index
	}
	for submesh, s in mesh.submeshes[:mesh.submesh_count] {
		material := renderer.materials[s] if s < MAX_MATERIAL_SLOTS else {}
		use, ok := use_material(r, table, material)
		if !ok {
			continue
		}
		b := mesh.submesh_bounds[s] if s < MAX_SUBMESHES else mesh.bounds
		append(
			items,
			Cull_Item {
				instance = slot,
				mesh = mesh_index,
				first_index = submesh.first_index,
				index_count = submesh.index_count,
				material = use.block,
				bin = u32(use.pipeline),
				sphere = {b.center.x, b.center.y, b.center.z, b.radius},
			},
		)
	}
}

// ensure_draw_buffers grows the frame's draw buffers to hold its items and bins.
@(private = "file")
ensure_draw_buffers :: proc(r: ^Renderer, items, bins: int) {
	s := &r.scene
	platform := r.platform
	if items > s.capacity || s.arguments == {} {
		platform.gpu_destroy_buffer(s.arguments)
		platform.gpu_destroy_buffer(s.draws)
		s.capacity = max(items, s.capacity * 2, 256)
		s.arguments = platform.gpu_create_buffer({size = u32(s.capacity * size_of(gpu.Draw_Indirect_Args)), usage = {.Storage, .Indirect}, label = "draw arguments"}, nil)
		s.draws = platform.gpu_create_buffer({size = u32(s.capacity * size_of(Draw_Record)), usage = {.Storage}, label = "draw records"}, nil)
	}
	if bins > s.bin_capacity || s.counts == {} {
		platform.gpu_destroy_buffer(s.counts)
		s.bin_capacity = max(bins, s.bin_capacity * 2, 64)
		s.counts = platform.gpu_create_buffer({size = u32(s.bin_capacity * 4), usage = {.Storage, .Indirect}, label = "draw counts"}, nil)
	}
}

// frustum_planes are the planes of a view's frustum, relative to the camera, from its projection: left, right, bottom
// and top, and the near plane. The far plane is at infinity. Each is normalized, so a sphere tests by its radius.
@(private)
frustum_planes :: proc(m: matrix[4, 4]f32) -> (planes: [5][4]f32) {
	row :: proc(m: matrix[4, 4]f32, r: int) -> [4]f32 {
		return {m[r, 0], m[r, 1], m[r, 2], m[r, 3]}
	}
	x, y, z, w := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	// Clip space keeps -w <= x, y <= w, and reversed depth keeps z <= w at the near plane.
	planes = {w + x, w - x, w + y, w - y, w - z}
	for &p in planes {
		p /= linalg.length(p.xyz)
	}
	return
}

@(private = "file")
update_scene :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	g := ctx.graph
	if sf.instance_bytes > 0 {
		gpu.cmd_copy_buffer(ctx.cb, sf.instance_upload.buffer, sf.instance_upload.offset, gpu_buffer(g, sf.instances), 0, u32(sf.instance_bytes))
	}
	gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.counts), 0, u32(len(sf.bin_counts) * 4))
}

@(private = "file")
cull_draws :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.scene.cull_pipeline.pipeline
	if len(sf.items) == 0 || pipeline == {} {
		return
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.cull_constants)
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.items) + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, 1, 1})
}

// draw_scene_bins draws each bin with one indirect draw, with its material's pipeline. A bin whose pipeline is not
// compiled yet draws nothing.
@(private)
draw_scene_bins :: proc(f: ^Frame, cb: ^gpu.Command_Buffer) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 {
		return
	}
	g := f.graph
	arguments, counts := gpu_buffer(g, sf.arguments), gpu_buffer(g, sf.counts)
	for pipeline_index, bin in sf.bin_pipelines {
		pipeline := f.renderer.materials.pipelines[pipeline_index].pipeline
		if pipeline == {} {
			continue
		}
		gpu.cmd_set_pipeline(cb, pipeline)
		gpu.cmd_set_pass_constants(cb, sf.frame_constants)
		gpu.cmd_draw_indirect(cb, arguments, sf.bin_offsets[bin] * size_of(gpu.Draw_Indirect_Args), sf.bin_counts[bin], counts, u32(bin) * 4)
	}
}
