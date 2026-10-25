package render

import "core:log"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The GPU scene (see docs/rendering.md#gpu-scene): every Mesh_Renderer's instance at a stable slot of a persistent
// buffer, its pose relative to a render origin that snaps to a 1024 m grid. Each frame writes every slot, then culls
// each submesh of each instance on the GPU, for the camera, the view model and each shadow view, into the bin of its
// material's pipelines. The view model's instances are relative to the camera, not the origin (see
// docs/rendering.md#view-model). The prepass, the shadow maps and the forward pass each draw a bin with one indirect draw.

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

// The culling's views: the camera, the view model, then the shadow views.
VIEW_CAMERA :: 0
VIEW_VIEW_MODEL :: 1
FIRST_SHADOW_VIEW :: 2

// Frame_Constants matches Frame_Constants in material_common.hlsli: the material passes' constants. A shadow view's
// copy differs in its view_projection, and the view model's in its projections, its offsets and its near plane.
Frame_Constants :: struct {
	view_projection:          matrix[4, 4]f32,
	previous_view_projection: matrix[4, 4]f32,
	cluster_view_projection:  matrix[4, 4]f32,
	camera_offset:            [4]f32,
	previous_camera_offset:   [4]f32,
	sky_color:                [4]f32,
	ground_color:             [4]f32,
	cascade_splits:           [4]f32,
	instances:                u32,
	draws:                    u32,
	meshes:                   u32,
	materials:                u32,
	sampler_index:            u32,
	time:                     f32,
	// The mesh records, the material table and the lights are in the upload ring, at these offsets of its buffer.
	meshes_offset:            u32,
	materials_offset:         u32,
	lights:                   u32,
	lights_offset:            u32,
	directional_count:        u32,
	clusters:                 u32,
	cluster_indices:          u32,
	cluster_columns:          u32,
	cluster_rows:             u32,
	slice_scale:              f32,
	slice_bias:               f32,
	near:                     f32,
	shadow_sampler:           u32,
	shadow_views:             u32,
	shadow_views_offset:      u32,
	clustered:                u32,
	screen_size:              [2]f32,
}

// Material_Push matches Material_Push in material_common.hlsli: the forward pass's textures that exist only once the
// frame records.
Material_Push :: struct {
	shadow_atlas: u32,
	shadow_mask:  u32,
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

// An item that casts shadows: its Mesh_Renderer's cast_shadows, and its material's.
ITEM_CASTS_SHADOWS :: 1
// An item of the view model, whose instance is relative to the camera.
ITEM_VIEW_MODEL :: 2

// Cull_Item matches Item in cull_draws.hlsl.
Cull_Item :: struct {
	instance:    u32,
	mesh:        u32,
	first_index: u32,
	index_count: u32,
	material:    u32,
	bin:         u32,
	flags:       u32,
	padding:     u32,
	sphere:      [4]f32,
}

// A view that draws only the items that cast shadows, and the view that draws only the view model's items, which every
// other view leaves out.
VIEW_CASTERS :: 1
VIEW_MODEL :: 2

// Cull_View matches Cull_View in cull_draws.hlsl: a view's planes relative to the camera, the camera's offset from the
// space of the view's instances, and its first draw.
Cull_View :: struct {
	planes:     [6][4]f32,
	offset:     [4]f32,
	first_draw: u32,
	flags:      u32,
	padding:    [2]u32,
}

// Cull_Constants matches Cull_Constants in cull_draws.hlsl.
Cull_Constants :: struct {
	item_count:         u32,
	// The items, the bins' first draws and the views are in the upload ring, at these offsets of its buffer.
	items:              u32,
	items_offset:       u32,
	instances:          u32,
	arguments:          u32,
	draws:              u32,
	counts:             u32,
	bin_offsets:        u32,
	bin_offsets_offset: u32,
	views:              u32,
	views_offset:       u32,
	bin_count:          u32,
	padding:            [3]u32,
}

#assert(size_of(Instance_Record) == 112 && size_of(Cull_Item) == 48 && size_of(Draw_Record) == 16 && size_of(Mesh_Record) == 32)
#assert(size_of(Cull_View) == 128 && size_of(Frame_Constants) == 368)

// Gpu_Scene is the GPU scene's state between frames, in the Renderer.
Gpu_Scene :: struct {
	origin:                   ecs.World_Position,
	origin_set:               bool,
	// The slot of each entity with a Mesh_Renderer, in host memory.
	slots:                    map[ecs.Entity]u32,
	slot_entities:            [MAX_INSTANCES]ecs.Entity,
	// Each slot's presented pose in the last frame, and the frame that last wrote it.
	previous:                 [MAX_INSTANCES]ecs.Transform,
	seen:                     [MAX_INSTANCES]u64,
	free:                     [dynamic]u32,
	// Slots below this have been used.
	high:                     u32,
	frame:                    u64,
	// Last frame's camera and projections, for the velocities.
	previous_position:        ecs.World_Position,
	previous_view_projection: matrix[4, 4]f32,
	previous_view_model:      matrix[4, 4]f32,
	has_previous:             bool,
	instances:                gpu.Buffer,
	// This frame's indirect draws and draw records, and each view's bins' counts, which grow with the frame's draws.
	arguments:                gpu.Buffer,
	draws:                    gpu.Buffer,
	counts:                   gpu.Buffer,
	capacity:                 int,
	count_capacity:           int,
	cull_pipeline:            Shader_Pipeline,
}

// Scene_Frame is what one frame's GPU scene passes need, in frame memory.
@(private)
Scene_Frame :: struct {
	items:           []Cull_Item,
	// A material pipeline for each bin, and each bin's first draw and its count of items, within a view's draws.
	bin_pipelines:   []int,
	bin_offsets:     []u32,
	bin_counts:      []u32,
	// The camera, the view model, then each shadow view.
	view_count:      int,
	instance_upload: gpu.Upload,
	instance_bytes:  int,
	item_upload:     gpu.Upload,
	mesh_upload:     gpu.Upload,
	table_upload:    gpu.Upload,
	bin_upload:      gpu.Upload,
	zero_upload:     gpu.Upload,
	// Each view's Frame_Constants.
	view_constants:  []gpu.Upload,
	cull_constants:  gpu.Upload,
	// With Ray_Query, the acceleration structure's instance of each instance that casts shadows.
	accel_instances: gpu.Upload,
	accel_count:     int,
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

// build_scene writes the GPU scene's records for the frame: every instance, a draw item for each visible submesh with
// its material's block, the mesh records and the material table. add_scene_passes then culls the items.
@(private)
build_scene :: proc(f: ^Frame, w: ^ecs.World, hidden: []u32) {
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
	accel_instances := make([dynamic]gpu.Accel_Instance, r.platform.frame_allocator)

	it := ecs.query_iter(w, r.meshes.query)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Mesh_Renderer)
		view_model := len(ecs.column(view, EXTRACT_TERMS + 1, View_Model)) > 0
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
			if view_model {
				// Relative to the camera, and last frame's relative to last frame's camera.
				last_camera := s.has_previous ? s.previous_position : f.view.position
				records[slot] = {rows = pose_rows(pose, f.view.position), previous_rows = pose_rows(last, last_camera), id = entity_id(e)}
			} else {
				records[slot] = {rows = pose_rows(pose, s.origin), previous_rows = pose_rows(last, s.origin), id = entity_id(e)}
			}
			s.previous[slot], s.seen[slot] = pose, s.frame
			if is_hidden(hidden, e) {
				continue
			}
			mesh := add_items(r, &table, &meshes, &mesh_indices, &items, renderers[i], slot, view_model)
			if mesh != nil && mesh.accel != {} && renderers[i].cast_shadows && !view_model {
				reference := r.platform.gpu_accel_reference(mesh.accel)
				append(&accel_instances, gpu.accel_instance(records[slot].rows, reference, id = slot, flags = {.Force_Opaque}))
			}
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

	// Each pipeline's items are a bin, in one range of each view's draws.
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

	platform := r.platform
	ok := true
	sf.instance_bytes = int(s.high) * size_of(Instance_Record)
	sf.instance_upload, ok = upload_bytes(platform, slice.to_bytes(records[:s.high]))
	item_upload, items_ok := upload_bytes(platform, slice.to_bytes(items[:]))
	mesh_upload, meshes_ok := upload_bytes(platform, slice.to_bytes(meshes[:]))
	table_upload, table_ok := upload_bytes(platform, table.bytes[:])
	bin_upload, bins_ok := upload_bytes(platform, slice.to_bytes(sf.bin_offsets))
	accel_upload, accel_ok := upload_bytes(platform, slice.to_bytes(accel_instances[:]))
	if !(ok && items_ok && meshes_ok && table_ok && bins_ok && accel_ok) {
		log.error("render: the upload ring is full, so the frame draws no meshes")
		sf.items = nil
		return
	}
	sf.item_upload, sf.mesh_upload, sf.table_upload, sf.bin_upload = item_upload, mesh_upload, table_upload, bin_upload
	sf.accel_instances, sf.accel_count = accel_upload, len(accel_instances)
}

// upload_bytes copies data into the upload ring.
@(private)
upload_bytes :: proc(platform: ^core.Platform_API, data: []byte, align := 16) -> (u: gpu.Upload, ok: bool) {
	u = platform.gpu_upload(max(len(data), 16), align) or_return
	copy(u.data, data)
	return u, true
}

// add_scene_passes writes each view's constants and adds the GPU scene's passes: one that writes the instances and
// zeroes the bins' counts, and one that culls the draw items into each view's bins. It runs after the lights and the
// shadows, whose views and records the constants name.
@(private)
add_scene_passes :: proc(f: ^Frame, ambient: Ambient) {
	r := f.renderer
	s := &r.scene
	sf := f.scene_frame
	lf := f.lights
	shadows := f.shadows
	platform := r.platform
	view_model := view_projection(view_model_view(f.view), f32(f.size.x) / f32(max(f.size.y, 1)))
	defer {
		s.previous_position, s.previous_view_projection, s.has_previous = f.view.position, f.view_projection, true
		s.previous_view_model = view_model
	}
	if len(sf.items) == 0 {
		return
	}
	sf.view_count = FIRST_SHADOW_VIEW + len(shadows.views)
	ensure_draw_buffers(r, len(sf.items) * sf.view_count, len(sf.bin_pipelines) * sf.view_count)
	zeros := make([]byte, len(sf.bin_pipelines) * sf.view_count * 4, platform.frame_allocator)
	ok: bool
	sf.zero_upload, ok = upload_bytes(platform, zeros)
	if !ok {
		sf.items = nil
		return
	}

	camera_offset := ecs.position_sub(f.view.position, s.origin)
	previous_offset := camera_offset
	previous_projection := f.view_projection
	previous_view_model := view_model
	if s.has_previous {
		previous_offset = ecs.position_sub(s.previous_position, s.origin)
		previous_projection = s.previous_view_projection
		previous_view_model = s.previous_view_model
	}
	constants := Frame_Constants {
		view_projection          = f.view_projection,
		previous_view_projection = previous_projection,
		cluster_view_projection  = f.view_projection,
		camera_offset            = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		previous_camera_offset   = {previous_offset.x, previous_offset.y, previous_offset.z, 0},
		sky_color                = {ambient.sky.r, ambient.sky.g, ambient.sky.b, 0},
		ground_color             = {ambient.ground.r, ambient.ground.g, ambient.ground.b, 0},
		cascade_splits           = shadows.cascade_splits,
		instances                = gpu.read_index(s.instances),
		draws                    = gpu.read_index(s.draws),
		meshes                   = gpu.read_index(sf.mesh_upload.buffer),
		materials                = gpu.read_index(sf.table_upload.buffer),
		sampler_index            = gpu.sampler_index(r.materials.sampler),
		time                     = frame_time(r),
		meshes_offset            = sf.mesh_upload.offset,
		materials_offset         = sf.table_upload.offset,
		lights                   = gpu.read_index(lf.upload.buffer),
		lights_offset            = lf.upload.offset,
		directional_count        = u32(lf.directional_count),
		cluster_columns          = lf.columns,
		cluster_rows             = lf.rows,
		slice_scale              = lf.slice_scale,
		slice_bias               = lf.slice_bias,
		near                     = f.view.near,
		shadow_sampler           = gpu.sampler_index(r.shadows.sampler),
		shadow_views             = gpu.read_index(shadows.views_upload.buffer),
		shadow_views_offset      = shadows.views_upload.offset,
		clustered                = u32(lf.clustered),
		screen_size              = {f32(f.size.x), f32(f.size.y)},
	}
	if lf.clustered {
		constants.clusters = gpu.read_index(r.lights.clusters)
		constants.cluster_indices = gpu.read_index(r.lights.indices)
	}
	sf.view_constants = make([]gpu.Upload, sf.view_count, platform.frame_allocator)
	views := make([]Cull_View, sf.view_count, platform.frame_allocator)
	for v in 0 ..< sf.view_count {
		c := constants
		views[v].first_draw = u32(v * len(sf.items))
		views[v].offset = constants.camera_offset
		switch v {
		case VIEW_CAMERA, VIEW_VIEW_MODEL:
			if v == VIEW_VIEW_MODEL {
				// The view model's instances are relative to the camera already.
				c.view_projection, c.previous_view_projection = view_model, previous_view_model
				c.camera_offset, c.previous_camera_offset = {}, {}
				c.near = view_model_view(f.view).near
				views[v].offset, views[v].flags = {}, VIEW_MODEL
			}
			planes := frustum_planes(c.view_projection)
			copy(views[v].planes[:], planes[:])
			// The far plane is at infinity.
			views[v].planes[5] = {0, 0, 0, 1}
		case:
			c.view_projection = shadows.matrices[v - FIRST_SHADOW_VIEW]
			views[v].planes = shadows.planes[v - FIRST_SHADOW_VIEW]
			views[v].flags = VIEW_CASTERS
		}
		sf.view_constants[v], ok = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			sf.items = nil
			return
		}
		(^Frame_Constants)(raw_data(sf.view_constants[v].data))^ = c
	}
	view_upload: gpu.Upload
	view_upload, ok = upload_bytes(platform, slice.to_bytes(views))
	if !ok {
		sf.items = nil
		return
	}

	g := f.graph
	sf.instances = import_buffer(g, s.instances)
	sf.arguments = import_buffer(g, s.arguments)
	sf.draws = import_buffer(g, s.draws)
	sf.counts = import_buffer(g, s.counts)
	cull := Cull_Constants {
		item_count         = u32(len(sf.items)),
		items              = gpu.read_index(sf.item_upload.buffer),
		items_offset       = sf.item_upload.offset,
		instances          = gpu.read_index(s.instances),
		arguments          = gpu.write_index(s.arguments),
		draws              = gpu.write_index(s.draws),
		counts             = gpu.write_index(s.counts),
		bin_offsets        = gpu.read_index(sf.bin_upload.buffer),
		bin_offsets_offset = sf.bin_upload.offset,
		views              = gpu.read_index(view_upload.buffer),
		views_offset       = view_upload.offset,
		bin_count          = u32(len(sf.bin_pipelines)),
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

// declare_scene_draws declares what a pass that draws the scene's bins reads.
@(private)
declare_scene_draws :: proc(f: ^Frame, p: Pass) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 {
		return
	}
	g := f.graph
	indirect_buffer(g, p, sf.arguments)
	indirect_buffer(g, p, sf.counts)
	read(g, p, sf.draws)
	read(g, p, sf.instances)
}

@(private)
max_abs :: proc(v: [3]f32) -> f32 {
	return max(abs(v.x), abs(v.y), abs(v.z))
}

@(private)
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
// pipeline, and gives the mesh, or nil if it is not ready. An item's bin holds its pipeline until build_scene numbers
// the bins.
@(private = "file")
add_items :: proc(
	r: ^Renderer,
	table: ^Material_Table,
	meshes: ^[dynamic]Mesh_Record,
	mesh_indices: ^map[^Resident_Mesh]u32,
	items: ^[dynamic]Cull_Item,
	renderer: Mesh_Renderer,
	slot: u32,
	view_model: bool,
) -> ^Resident_Mesh {
	mesh, ready := resident_mesh(&r.residency, renderer.mesh)
	if !ready {
		return nil
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
		// The view model casts no shadows: its pose is not its place in the world.
		flags: u32 = view_model ? ITEM_VIEW_MODEL : 0
		if renderer.cast_shadows && r.materials.pipelines[use.pipeline].cast_shadows && !view_model {
			flags |= ITEM_CASTS_SHADOWS
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
				flags = flags,
				sphere = {b.center.x, b.center.y, b.center.z, b.radius},
			},
		)
	}
	return mesh
}

// ensure_draw_buffers grows the frame's draw buffers to hold its draws in every view, and its bins' counts.
@(private = "file")
ensure_draw_buffers :: proc(r: ^Renderer, draws, counts: int) {
	s := &r.scene
	platform := r.platform
	if draws > s.capacity || s.arguments == {} {
		platform.gpu_destroy_buffer(s.arguments)
		platform.gpu_destroy_buffer(s.draws)
		s.capacity = max(draws, s.capacity * 2, 256)
		s.arguments = platform.gpu_create_buffer({size = u32(s.capacity * size_of(gpu.Draw_Indirect_Args)), usage = {.Storage, .Indirect}, label = "draw arguments"}, nil)
		s.draws = platform.gpu_create_buffer({size = u32(s.capacity * size_of(Draw_Record)), usage = {.Storage}, label = "draw records"}, nil)
	}
	if counts > s.count_capacity || s.counts == {} {
		platform.gpu_destroy_buffer(s.counts)
		s.count_capacity = max(counts, s.count_capacity * 2, 64)
		s.counts = platform.gpu_create_buffer({size = u32(s.count_capacity * 4), usage = {.Storage, .Indirect}, label = "draw counts"}, nil)
	}
}

// frustum_planes are the planes of a view's frustum, relative to the camera, from its projection: left, right, bottom
// and top, and the near plane. The far plane is at infinity. Each is normalized, so a sphere tests by its radius.
@(private)
frustum_planes :: proc(m: matrix[4, 4]f32) -> (planes: [5][4]f32) {
	all := frustum_planes_6(m)
	copy(planes[:], all[:5])
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
	gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.counts), 0, u32(len(sf.bin_pipelines) * sf.view_count * 4))
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
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.items) + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, u32(sf.view_count), 1})
}

// draw_scene_view draws each bin of a view with one indirect draw, with its material's pipeline for a pass (see
// VIEW_CAMERA). A bin whose pipeline is not compiled yet draws nothing. The forward pass pushes the frame's shadow
// textures. The prepass and the forward pass draw with the view model's stencil bit as the reference: set for the view
// model, clear for the world (see docs/rendering.md#view-model).
@(private)
draw_scene_view :: proc(f: ^Frame, cb: ^gpu.Command_Buffer, view: int, pass: format.Material_Pass) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 || view >= sf.view_count {
		return
	}
	g := f.graph
	arguments, counts := gpu_buffer(g, sf.arguments), gpu_buffer(g, sf.counts)
	push: Material_Push
	if pass == .Forward {
		white := gpu.read_index(f.renderer.materials.defaults[.White])
		push = {shadow_atlas = white, shadow_mask = white}
		if f.shadows.atlas != 0 {
			push.shadow_atlas = gpu.read_index(gpu_texture(g, f.shadows.atlas))
		}
		if f.shadows.mask != 0 {
			push.shadow_mask = gpu.read_index(gpu_texture(g, f.shadows.mask))
		}
	}
	if pass != .Depth {
		gpu.cmd_set_stencil_reference(cb, view == VIEW_VIEW_MODEL ? VIEW_MODEL_STENCIL : 0)
	}
	bin_count := len(sf.bin_pipelines)
	for pipeline_index, bin in sf.bin_pipelines {
		p := &f.renderer.materials.pipelines[pipeline_index]
		pipeline := p.pipelines[pass]
		if pipeline == {} {
			continue
		}
		gpu.cmd_set_pipeline(cb, pipeline)
		gpu.cmd_set_pass_constants(cb, sf.view_constants[view])
		if pass == .Forward {
			gpu.cmd_push_constants(cb, &push)
		}
		first := u32(view * len(sf.items)) + sf.bin_offsets[bin]
		gpu.cmd_draw_indirect(cb, arguments, first * size_of(gpu.Draw_Indirect_Args), sf.bin_counts[bin], counts, u32(view * bin_count + bin) * 4)
	}
}
