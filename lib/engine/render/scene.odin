package render

import "core:log"
import "core:math"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The GPU scene (see docs/rendering/gpu-scene.md#gpu-scene): every Mesh_Renderer's instance at a stable slot of a persistent
// buffer, its pose relative to a render origin that snaps to a 1024 m grid. Each frame writes every slot, then culls
// each submesh of each instance on the GPU, for the camera, the view model and each shadow view, into the bin of its
// material's pipelines. The view model's instances are relative to the camera, not the origin (see
// docs/rendering/layers-and-output.md#view-model). The prepass, the shadow maps and the forward pass each draw a bin with one indirect draw.

// The render origin snaps to cells of 1024 m: 2^34 units of 2^-24 m.
ORIGIN_CELL_BITS :: 34
ORIGIN_CELL :: f32(1 << (ORIGIN_CELL_BITS - 24))
// The origin moves when the camera is more than this many cells from it on any axis.
REBASE_CELLS :: 1.5
// At most this many instances.
MAX_INSTANCES :: 16384
// A Mesh_Renderer's material slots, one for each of its mesh's first submeshes.
MAX_MATERIAL_SLOTS :: 8
// A mesh file names its slots by the same count.
#assert(MAX_MATERIAL_SLOTS == format.MESH_MAX_SLOTS)
CULL_GROUP_SIZE :: 64
// Each amplification group of the mesh shader path tests this many meshlets. Matches MESHLETS_PER_GROUP in
// material_mesh.hlsli.
MESHLETS_PER_GROUP :: 32

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
	origin_offset:            [4]f32,
	sky_color:                [4]f32,
	ground_color:             [4]f32,
	cascade_splits:           [4]f32,
	// The view's frustum, which the mesh shader path culls meshlets with, and where it looks from: a point relative to
	// the camera in w = 1, or the direction it looks along in w = 0.
	planes:                   [6][4]f32,
	cull_eye:                 [4]f32,
	// The camera's right and up, and last frame's camera's, in every view's copy, which billboards face (see
	// docs/rendering/gpu-scene.md#billboards).
	camera_right:             [4]f32,
	camera_up:                [4]f32,
	previous_camera_right:    [4]f32,
	previous_camera_up:       [4]f32,
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
	// The camera's jitter, which view_projection has, and the exposure buffer.
	jitter:                   [2]f32,
	exposure:                 u32,
	// Whether Material_Push has the fog volume, its sampler, and the share of its width and height that the screen
	// covers.
	fog:                      u32,
	fog_sampler:              u32,
	fog_scale:                [2]f32,
	// Whether Material_Push has the global illumination.
	gi:                       u32,
	// The area lights' lookup tables and their sampler.
	ltc_matrix:               u32,
	ltc_amplitude:            u32,
	ltc_sampler:              u32,
	// The editor's debug view, which the forward pass draws for the views that it has.
	debug_view:               u32,
	// The fog volume's depth slices (see FOG_LEVEL_SLICES), and the shadow maps' Shadow_Filter.
	fog_slices:               u32,
	shadow_filter:            u32,
	// The mesh shader path's level of detail: the camera's, in every view (see lod_scale).
	lod_scale:                f32,
	lod_near:                 f32,
	// Last frame's time, for the previous pose of a material's displacement (see
	// docs/rendering/materials.md#vertex-displacement).
	previous_time:            f32,
	// The frame's Surface_Records in the upload ring, at this offset of its buffer.
	surfaces:                 u32,
	surfaces_offset:          u32,
	// The particle ribbons' vertices (see docs/rendering/particles.md#ribbons).
	ribbon_vertices:          u32,
}

// Material_Push matches Material_Push in material_common.hlsli: the forward pass's textures that exist only once the
// frame records. ambient_occlusion is white without it, fog is read only when Frame_Constants.fog says so, and the global
// illumination only when Frame_Constants.gi does.
Material_Push :: struct {
	shadow_atlas:      u32,
	shadow_mask:       u32,
	ambient_occlusion: u32,
	fog:               u32,
	gi_diffuse:        u32,
	gi_specular:       u32,
	// Moment-based transparency's moments, which its transparent pass reads with transmittance set (see
	// docs/rendering/transparency.md#transparency).
	moments_zeroth:    u32,
	moments:           u32,
	transmittance:     u32,
}

// Draw_Record matches Draw_Record in material_common.hlsli. material is its block's offset in the material table.
// mesh is the mesh's index, with the submesh's index in its mesh above ID_ENTITY_BITS, as the ID buffer has it. first
// and count are the submesh's indices, or on the mesh shader path its meshlets. bound is the material's displacement
// bound in meters, which the mesh shader path's culling adds to each meshlet's sphere.
Draw_Record :: struct {
	instance: u32,
	mesh:     u32,
	first:    u32,
	material: u32,
	count:    u32,
	bound:    f32,
	padding:  [2]u32,
}

MESH_RECORD_INDEX32 :: 1
MESH_RECORD_UV1 :: 2
MESH_RECORD_COLOR :: 4

// Mesh_Record matches Mesh_Record in material_common.hlsli: a resident mesh's buffers, as bindless indices, and its
// impostor's atlas, the side of its frames and the sphere that they see, for a mesh with one (see
// docs/rendering/gpu-scene.md#impostors).
Mesh_Record :: struct {
	positions:         u32,
	attributes:        u32,
	indices:           u32,
	attribute_stride:  u32,
	flags:             u32,
	meshlets:          u32,
	meshlet_vertices:  u32,
	meshlet_triangles: u32,
	impostor:          u32,
	impostor_size:     u32,
	padding:           [2]u32,
	impostor_sphere:   [4]f32,
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
// An item that draws on the mesh shader path, whose first and count are its meshlets.
ITEM_MESH_PATH :: 4
// A patch surface's item, whose draws the GPU adds (see docs/rendering/surfaces.md#surfaces): cull_draws.hlsl skips
// it, and cull_patches.hlsl writes a draw for each of its visible patches.
ITEM_SURFACE :: 8
// A billboard's item, whose sphere turns about its instance's position (see docs/rendering/gpu-scene.md#billboards).
ITEM_BILLBOARD :: 16
// An impostor's item, which draws its mesh's impostor past where it takes over, and the item of a submesh that has
// one, which draws up to there (see docs/rendering/gpu-scene.md#impostors).
ITEM_IMPOSTOR :: 32
ITEM_HAS_IMPOSTOR :: 64
// A particle ribbon's item, whose draw the GPU writes (see docs/rendering/particles.md#ribbons): cull_draws.hlsl skips
// it, and ribbon_build.hlsl writes its draw in the camera's view.
ITEM_RIBBON :: 128
// The vertices of an impostor's quad.
IMPOSTOR_VERTICES :: 6

// Cull_Item matches Item in cull_draws.hlsl. first and count are the submesh's indices, or with ITEM_MESH_PATH its
// meshlets. bound is how far the material's displacement may move a vertex, in meters, which culling adds to the
// sphere's radius after the instance's scale (see docs/rendering/materials.md#vertex-displacement). An item with
// ITEM_IMPOSTOR or ITEM_HAS_IMPOSTOR has its mesh's sphere in lod_sphere and its impostor's error, which pick between
// them.
Cull_Item :: struct {
	instance: u32,
	mesh:     u32,
	first:    u32,
	count:    u32,
	material: u32,
	bin:      u32,
	flags:    u32,
	// The index of the submesh in its mesh, which the ID buffer gets (see ID_ENTITY_BITS).
	submesh:  u32,
	sphere:   [4]f32,
	bound:    f32,
	impostor_error: f32,
	padding:  [2]u32,
	lod_sphere: [4]f32,
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
	// The mesh shader path's indirect draws.
	mesh_arguments:     u32,
	// The surfaces' records in the upload ring, how many, and the patches that the selection writes and the culling
	// reads, with each surface's count (see docs/rendering/surfaces.md#surfaces).
	surfaces:           u32,
	surfaces_offset:    u32,
	surface_count:      u32,
	patches:            u32,
	patch_counts:       u32,
	patches_read:       u32,
	patch_counts_read:  u32,
	// The camera's offset from the render origin, and its level of detail, which pick between a mesh and its impostor
	// in every view.
	camera:             [4]f32,
	lod_scale:          f32,
	lod_near:           f32,
	padding:            [2]u32,
}

#assert(size_of(Instance_Record) == 112 && size_of(Cull_Item) == 80 && size_of(Draw_Record) == 32 && size_of(Mesh_Record) == 64)
#assert(size_of(Cull_View) == 128 && size_of(Frame_Constants) == 640 && size_of(Cull_Constants) == 112)

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
	previous_rotation:        quaternion128,
	previous_view_projection: matrix[4, 4]f32,
	previous_view_model:      matrix[4, 4]f32,
	// Last frame's time, which a displacement's previous pose takes.
	previous_time:            f32,
	has_previous:             bool,
	instances:                gpu.Buffer,
	// This frame's indirect draws, the mesh shader path's in a buffer of their own, and draw records, and each view's
	// bins' counts, which grow with the frame's draws.
	arguments:                gpu.Buffer,
	mesh_arguments:           gpu.Buffer,
	draws:                    gpu.Buffer,
	counts:                   gpu.Buffer,
	capacity:                 int,
	count_capacity:           int,
	cull_pipeline:            Shader_Pipeline,
	// The patch surfaces' selected patches and each surface's count, and the passes that select and cull them.
	patches:                  gpu.Buffer,
	patch_counts:             gpu.Buffer,
	select_pipeline:          Shader_Pipeline,
	cull_patches_pipeline:    Shader_Pipeline,
}

// Bin_Group is a range of the frame's bins: the opaque and masked materials', which the prepass, the shadow maps and
// the forward pass draw, those of moment-based transparency, and the sorted transparent and additive draws, a bin for
// each item, back to front (see docs/rendering/transparency.md#transparency).
Bin_Group :: enum u8 {
	Opaque,
	Moments,
	Sorted,
}

// Scene_Frame is what one frame's GPU scene passes need, in frame memory.
@(private)
Scene_Frame :: struct {
	items:           []Cull_Item,
	// A material pipeline for each bin, and each bin's first draw and its count of items, within a view's draws.
	bin_pipelines:   []int,
	// The pipeline that each bin draws with this frame: its own, or a substitute while its own compiles.
	bin_draws:       []int,
	// The bins of impostors, which draw with their pipelines' impostor passes.
	bin_impostors:   []bool,
	bin_offsets:     []u32,
	bin_counts:      []u32,
	// The draws of one view: the items, with each surface's reserved patches.
	draws_per_view:  int,
	// The patch surfaces' records, and their upload.
	surfaces:        []Surface_Record,
	surface_upload:  gpu.Upload,
	// The particle ribbons, with their items, and their vertices once the ribbons' build writes them (see
	// docs/rendering/particles.md#ribbons).
	ribbons:         []Ribbon_Entry,
	ribbon_vertices: Buffer,
	// Each group's first bin and the bin after its last.
	groups:          [Bin_Group][2]int,
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
	mesh_arguments:  Buffer,
	draws:           Buffer,
	counts:          Buffer,
	patches:         Buffer,
	patch_counts:    Buffer,
}

scene_init :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	s.slots = make(map[ecs.Entity]u32, platform.heap_allocator)
	s.free = make([dynamic]u32, platform.heap_allocator)
	s.instances = platform.gpu_create_buffer({size = MAX_INSTANCES * size_of(Instance_Record), label = "gpu scene instances"}, nil)
	s.patches = platform.gpu_create_buffer({size = MAX_SURFACES * MAX_SURFACE_PATCHES * 4, usage = {.Storage}, label = "surface patches"}, nil)
	s.patch_counts = platform.gpu_create_buffer({size = MAX_SURFACES * 4, usage = {.Storage}, label = "surface patch counts"}, nil)
	s.cull_pipeline = shader_pipeline(CULL_SHADER)
	s.select_pipeline = shader_pipeline(SELECT_PATCHES_SHADER)
	s.cull_patches_pipeline = shader_pipeline(CULL_PATCHES_SHADER)
}

scene_destroy :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	delete(s.slots)
	delete(s.free)
	for b in ([]gpu.Buffer{s.instances, s.arguments, s.mesh_arguments, s.draws, s.counts, s.patches, s.patch_counts}) {
		platform.gpu_destroy_buffer(b)
	}
	destroy_shader_pipeline(&s.cull_pipeline, platform)
	destroy_shader_pipeline(&s.select_pipeline, platform)
	destroy_shader_pipeline(&s.cull_patches_pipeline, platform)
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
	sync_compute_pipeline(&s.select_pipeline, r.platform, r.residency.assets, {label = "select patches"}, r.reloaded)
	sync_compute_pipeline(&s.cull_patches_pipeline, r.platform, r.residency.assets, {label = "cull patches"}, r.reloaded)

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
	// The patch surfaces: an instance record as a mesh's, and one item each, whose draws the GPU adds (see
	// docs/rendering/surfaces.md#surfaces).
	surfaces := make([dynamic]Surface_Record, r.platform.frame_allocator)
	camera_offset := ecs.position_sub(f.view.position, s.origin)
	lod := lod_scale(f.view, f.size.y, f.lod_error)
	surface_it := ecs.query_iter(w, r.surfaces.query)
	for view in ecs.query_next(&surface_it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Surface_Renderer)
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
			if is_hidden(hidden, e) || len(surfaces) >= MAX_SURFACES {
				continue
			}
			add_surface(r, &table, &items, &surfaces, renderers[i], slot, records[slot].rows, camera_offset, lod)
		}
	}
	// The particle ribbons: a slot each, at their systems' anchors, and an item each, whose draw the GPU writes.
	ribbons := add_ribbon_items(f, w, &table, &items, records, hidden)
	// A slot whose entity has no Mesh_Renderer, Surface_Renderer or ribbon any more is free again.
	for slot in 0 ..< s.high {
		if s.seen[slot] != s.frame && s.slot_entities[slot] != 0 {
			delete_key(&s.slots, s.slot_entities[slot])
			s.slot_entities[slot] = 0
			append(&s.free, slot)
		}
	}

	// Each pipeline's opaque or moment-based items are a bin, in one range of each view's draws. Each sorted item is a
	// bin of its own, back to front from the camera by its bounds' middle, so the bins draw in that order.
	camera := ecs.position_sub(f.view.position, s.origin)
	sorting := make([]Sort_Item, len(items), r.platform.frame_allocator)
	for item, i in items {
		sorting[i] = {item = item, group = material_group(&r.materials.pipelines[item.bin])}
		if sorting[i].group == .Sorted {
			// The view model's instances are relative to the camera already.
			eye := item.flags & ITEM_VIEW_MODEL != 0 ? [3]f32{} : camera
			sorting[i].distance = squared_distance(records[item.instance].rows, item.sphere.xyz, eye)
		}
	}
	sf.bin_pipelines, sf.groups = sort_bins(sorting, items[:], r.platform.frame_allocator)
	sf.bin_draws = bin_draws(r, sf.bin_pipelines)
	sf.bin_impostors = bin_impostors(items[:], len(sf.bin_pipelines), r.platform.frame_allocator)
	sf.items = items[:]
	sf.bin_counts, sf.bin_offsets, sf.draws_per_view = bin_sizes(items[:], len(sf.bin_pipelines), r.platform.frame_allocator)
	// The surfaces' records name their items, now that the bins' order is the items'.
	for item, i in items {
		if item.flags & ITEM_SURFACE != 0 {
			surfaces[item.mesh].item = u32(i)
		}
		if item.flags & ITEM_RIBBON != 0 {
			ribbons[item.mesh].item = u32(i)
		}
	}
	sf.ribbons = ribbons

	platform := r.platform
	ok := true
	sf.instance_bytes = int(s.high) * size_of(Instance_Record)
	sf.instance_upload, ok = upload_bytes(platform, slice.to_bytes(records[:s.high]))
	item_upload, items_ok := upload_bytes(platform, slice.to_bytes(items[:]))
	mesh_upload, meshes_ok := upload_bytes(platform, slice.to_bytes(meshes[:]))
	table_upload, table_ok := upload_bytes(platform, table.bytes[:])
	bin_upload, bins_ok := upload_bytes(platform, slice.to_bytes(sf.bin_offsets))
	accel_upload, accel_ok := upload_bytes(platform, slice.to_bytes(accel_instances[:]))
	surface_upload, surfaces_ok := upload_bytes(platform, slice.to_bytes(surfaces[:]))
	if !(ok && items_ok && meshes_ok && table_ok && bins_ok && accel_ok && surfaces_ok) {
		log.error("render: the upload ring is full, so the frame draws no meshes")
		sf.items = nil
		return
	}
	sf.item_upload, sf.mesh_upload, sf.table_upload, sf.bin_upload = item_upload, mesh_upload, table_upload, bin_upload
	sf.surfaces, sf.surface_upload = surfaces[:], surface_upload
	sf.accel_instances, sf.accel_count = accel_upload, len(accel_instances)
}

// Sort_Item is a draw item as build_scene sorts it into bins. Its item's bin is its material pipeline.
@(private)
Sort_Item :: struct {
	item:     Cull_Item,
	group:    Bin_Group,
	// A sorted item's squared distance from the camera.
	distance: f32,
}

// sort_bins writes the items in their bins' order, each with its bin, and gives each bin's material pipeline and each
// group's range of bins: the opaque bins, then moment-based transparency's, a bin for each pipeline, with its
// impostors' items in a bin after its own, then a bin for each sorted item, the farthest first.
@(private)
sort_bins :: proc(sorting: []Sort_Item, items: []Cull_Item, allocator := context.allocator) -> (pipelines: []int, groups: [Bin_Group][2]int) {
	slice.sort_by(sorting, proc(a, b: Sort_Item) -> bool {
		if a.group != b.group {
			return a.group < b.group
		}
		if a.group == .Sorted {
			return a.distance > b.distance
		}
		if a.item.bin != b.item.bin {
			return a.item.bin < b.item.bin
		}
		return a.item.flags & ITEM_IMPOSTOR < b.item.flags & ITEM_IMPOSTOR
	})
	bins := make([dynamic]int, allocator)
	group_bins: [Bin_Group]int
	for entry, i in sorting {
		pipeline := int(entry.item.bin)
		previous := sorting[max(i - 1, 0)]
		impostor := entry.item.flags & ITEM_IMPOSTOR != previous.item.flags & ITEM_IMPOSTOR
		if i == 0 || entry.group == .Sorted || entry.group != previous.group || pipeline != int(previous.item.bin) || impostor {
			append(&bins, pipeline)
			group_bins[entry.group] += 1
		}
		items[i] = entry.item
		items[i].bin = u32(len(bins) - 1)
	}
	first := 0
	for count, group in group_bins {
		groups[group] = {first, first + count}
		first += count
	}
	return bins[:], groups
}

// bin_impostors gives whether each bin is of impostors, whose items sort_bins gives bins of their own.
@(private)
bin_impostors :: proc(items: []Cull_Item, bins: int, allocator := context.allocator) -> []bool {
	impostors := make([]bool, bins, allocator)
	for item in items {
		impostors[item.bin] = item.flags & ITEM_IMPOSTOR != 0
	}
	return impostors
}

// squared_distance is the squared distance to a point in an instance's space, moved by its rows, from another point.
@(private = "file")
squared_distance :: proc(rows: [3][4]f32, p: [3]f32, from: [3]f32) -> f32 {
	d: [3]f32
	for row, k in rows {
		d[k] = row.x * p.x + row.y * p.y + row.z * p.z + row.w - from[k]
	}
	return d.x * d.x + d.y * d.y + d.z * d.z
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
	f.previous_view_projection = s.has_previous ? s.previous_view_projection : f.view_projection
	f.camera_motion = s.has_previous ? ecs.position_sub(f.view.position, s.previous_position) : {}
	now := frame_time(r)
	defer {
		s.previous_position, s.previous_view_projection, s.has_previous = f.view.position, f.view_projection, true
		s.previous_rotation = f.view.rotation
		s.previous_view_model = view_model
		s.previous_time = now
	}
	// The fog's injection reads the camera's constants, so they are written without draws too.
	has_items := len(sf.items) > 0
	if !has_items && f.fog == nil {
		return
	}
	sf.view_count = FIRST_SHADOW_VIEW + len(shadows.views)
	ok: bool
	if has_items {
		ensure_draw_buffers(r, sf.draws_per_view * sf.view_count, len(sf.bin_pipelines) * sf.view_count)
		zeros := make([]byte, len(sf.bin_pipelines) * sf.view_count * 4, platform.frame_allocator)
		sf.zero_upload, ok = upload_bytes(platform, zeros)
		if !ok {
			sf.items = nil
			return
		}
	}

	camera_offset := ecs.position_sub(f.view.position, s.origin)
	previous_offset := camera_offset
	previous_projection := f.view_projection
	previous_view_model := view_model
	previous_rotation := f.view.rotation
	if s.has_previous {
		previous_offset = ecs.position_sub(s.previous_position, s.origin)
		previous_projection = s.previous_view_projection
		previous_view_model = s.previous_view_model
		previous_rotation = s.previous_rotation
	}
	right, up, _ := view_axes(f.view)
	previous_right, previous_up, _ := view_axes({rotation = previous_rotation})
	constants := Frame_Constants {
		view_projection          = f.view_projection,
		previous_view_projection = previous_projection,
		cluster_view_projection  = f.view_projection,
		camera_offset            = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		previous_camera_offset   = {previous_offset.x, previous_offset.y, previous_offset.z, 0},
		origin_offset            = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		sky_color                = {ambient.sky.r, ambient.sky.g, ambient.sky.b, 0},
		ground_color             = {ambient.ground.r, ambient.ground.g, ambient.ground.b, 0},
		cascade_splits           = shadows.cascade_splits,
		camera_right             = {right.x, right.y, right.z, 0},
		camera_up                = {up.x, up.y, up.z, 0},
		previous_camera_right    = {previous_right.x, previous_right.y, previous_right.z, 0},
		previous_camera_up       = {previous_up.x, previous_up.y, previous_up.z, 0},
		instances                = gpu.read_index(s.instances),
		draws                    = gpu.read_index(s.draws),
		meshes                   = gpu.read_index(sf.mesh_upload.buffer),
		materials                = gpu.read_index(sf.table_upload.buffer),
		sampler_index            = gpu.sampler_index(r.materials.sampler),
		time                     = now,
		previous_time            = s.has_previous ? s.previous_time : now,
		meshes_offset            = sf.mesh_upload.offset,
		materials_offset         = sf.table_upload.offset,
		surfaces                 = gpu.read_index(sf.surface_upload.buffer),
		surfaces_offset          = sf.surface_upload.offset,
		ribbon_vertices          = gpu.read_index(r.particles.ribbon_vertices),
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
		exposure                 = gpu.read_index(r.post.exposure),
		ltc_matrix               = gpu.read_index(r.lights.ltc_matrix),
		ltc_amplitude            = gpu.read_index(r.lights.ltc_amplitude),
		ltc_sampler              = gpu.sampler_index(r.lights.ltc_sampler),
		debug_view               = u32(f.debug_view),
		shadow_filter            = u32(shadows.params.filter),
		lod_scale                = lod_scale(f.view, f.size.y, f.lod_error),
		lod_near                 = f.view.near,
	}
	constants.gi = u32(f.gi != nil)
	if f.fog != nil {
		constants.fog, constants.fog_sampler, constants.fog_scale = 1, gpu.sampler_index(r.post.sampler), f.fog.scale
		constants.fog_slices = f.fog.grid.z
	}
	if lf.clustered {
		constants.clusters = gpu.read_index(r.lights.clusters)
		constants.cluster_indices = gpu.read_index(r.lights.indices)
	}
	sf.view_constants = make([]gpu.Upload, sf.view_count, platform.frame_allocator)
	views := make([]Cull_View, sf.view_count, platform.frame_allocator)
	for v in 0 ..< sf.view_count {
		c := constants
		views[v].first_draw = u32(v * sf.draws_per_view)
		views[v].offset = constants.camera_offset
		switch v {
		case VIEW_CAMERA, VIEW_VIEW_MODEL:
			if v == VIEW_VIEW_MODEL {
				// The view model's instances are relative to the camera already.
				c.view_projection, c.previous_view_projection = view_model, previous_view_model
				c.camera_offset, c.previous_camera_offset = {}, {}
				c.near = view_model_view(f.view).near
				c.lod_scale, c.lod_near = lod_scale(view_model_view(f.view), f.size.y, f.lod_error), c.near
				views[v].offset, views[v].flags = {}, VIEW_MODEL
			}
			planes := frustum_planes(c.view_projection)
			copy(views[v].planes[:], planes[:])
			// The far plane is at infinity.
			views[v].planes[5] = {0, 0, 0, 1}
			c.cull_eye = {0, 0, 0, 1}
			// The camera's views draw with its jitter, which the velocities leave out.
			c.view_projection = jitter_projection(c.view_projection, f.jitter)
			c.jitter = f.jitter
		case:
			c.view_projection = shadows.matrices[v - FIRST_SHADOW_VIEW]
			views[v].planes = shadows.planes[v - FIRST_SHADOW_VIEW]
			views[v].flags = VIEW_CASTERS
			c.cull_eye = shadows.eyes[v - FIRST_SHADOW_VIEW]
		}
		c.planes = views[v].planes
		sf.view_constants[v], ok = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			sf.items = nil
			return
		}
		(^Frame_Constants)(raw_data(sf.view_constants[v].data))^ = c
	}
	if !has_items {
		return
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
	sf.mesh_arguments = import_buffer(g, s.mesh_arguments)
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
		mesh_arguments     = gpu.write_index(s.mesh_arguments),
		surfaces           = gpu.read_index(sf.surface_upload.buffer),
		surfaces_offset    = sf.surface_upload.offset,
		surface_count      = u32(len(sf.surfaces)),
		patches            = gpu.write_index(s.patches),
		patch_counts       = gpu.write_index(s.patch_counts),
		patches_read       = gpu.read_index(s.patches),
		patch_counts_read  = gpu.read_index(s.patch_counts),
		camera             = constants.camera_offset,
		lod_scale          = constants.lod_scale,
		lod_near           = constants.lod_near,
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
	add_select_patches_pass(f)
	p = add_compute_pass(g, "cull draws", cull_draws, f)
	read(g, p, sf.instances)
	write(g, p, sf.arguments)
	write(g, p, sf.mesh_arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
	add_cull_patches_pass(f)
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
	indirect_buffer(g, p, sf.mesh_arguments)
	indirect_buffer(g, p, sf.counts)
	read(g, p, sf.draws)
	read(g, p, sf.instances)
	if sf.ribbon_vertices != 0 {
		read(g, p, sf.ribbon_vertices)
	}
}

@(private)
max_abs :: proc(v: [3]f32) -> f32 {
	return max(abs(v.x), abs(v.y), abs(v.z))
}

// is_hidden is whether Frame_Desc.hidden hides an entity, so a game leaves out what it draws for one, as the renderer
// does.
is_hidden :: proc(hidden: []u32, e: ecs.Entity) -> bool {
	index := ecs.entity_index(e)
	return int(index / 32) < len(hidden) && hidden[index / 32] & (1 << (index % 32)) != 0
}

// scene_slot gives an entity's slot, and a free one the first time.
@(private)
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
// the bins. A submesh of a mesh with an impostor, whose material has the impostor path, has a second item, its
// impostor's, and culling draws one of the two (see docs/rendering/gpu-scene.md#impostors).
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
		mesh_index = u32(len(meshes))
		append(meshes, mesh_record(mesh))
		mesh_indices[mesh] = mesh_index
	}
	for submesh, s in mesh.submeshes[:mesh.submesh_count] {
		material := renderer.materials[s] if s < MAX_MATERIAL_SLOTS else {}
		use, ok := use_material(r, table, material)
		if !ok {
			continue
		}
		// A material that draws patches or ribbons draws no mesh: the default material stands in.
		if r.materials.pipelines[use.pipeline].patches || r.materials.pipelines[use.pipeline].ribbon {
			use = use_material(r, table, {}) or_continue
		}
		// The view model casts no shadows: its pose is not its place in the world.
		flags: u32 = view_model ? ITEM_VIEW_MODEL : 0
		if renderer.cast_shadows && r.materials.pipelines[use.pipeline].cast_shadows && !view_model {
			flags |= ITEM_CASTS_SHADOWS
		}
		// The opaque draws of a material with mesh pipelines draw meshlets.
		first, count := submesh.first_index, submesh.index_count
		pipeline := &r.materials.pipelines[use.pipeline]
		if pipeline.mesh_path && material_group(pipeline) == .Opaque {
			flags |= ITEM_MESH_PATH
			first, count = submesh.first_meshlet, submesh.meshlet_count
		}
		if pipeline.billboard {
			flags |= ITEM_BILLBOARD
		}
		b := mesh.submesh_bounds[s] if s < MAX_SUBMESHES else mesh.bounds
		item := Cull_Item {
			instance = slot,
			mesh     = mesh_index,
			first    = first,
			count    = count,
			material = use.block,
			bin      = u32(use.pipeline),
			flags    = flags,
			submesh  = u32(min(s, ID_MAX_SUBMESH)),
			sphere   = {b.center.x, b.center.y, b.center.z, b.radius},
			bound    = pipeline.displacement_bound,
		}
		// The view model is near the camera, where its impostor never draws.
		if mesh.impostor != {} && pipeline.impostor_path && material_group(pipeline) == .Opaque && !view_model {
			m := mesh.bounds
			item.flags |= ITEM_HAS_IMPOSTOR
			item.lod_sphere = {m.center.x, m.center.y, m.center.z, m.radius}
			item.impostor_error = mesh.impostor_error
			impostor := item
			impostor.flags = flags & ~u32(ITEM_MESH_PATH) | ITEM_IMPOSTOR
			impostor.first, impostor.count = 0, IMPOSTOR_VERTICES
			impostor.sphere, impostor.bound = item.lod_sphere, 0
			append(items, impostor)
		}
		append(items, item)
	}
	return mesh
}

// mesh_record is a resident mesh's record.
@(private)
mesh_record :: proc(mesh: ^Resident_Mesh) -> Mesh_Record {
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
	return {
		positions = gpu.read_index(mesh.positions),
		attributes = gpu.read_index(mesh.attributes),
		indices = gpu.read_index(mesh.indices),
		attribute_stride = mesh.attribute_stride,
		flags = flags,
		meshlets = gpu.read_index(mesh.meshlets),
		meshlet_vertices = gpu.read_index(mesh.meshlet_vertices),
		meshlet_triangles = gpu.read_index(mesh.meshlet_triangles),
		impostor = mesh.impostor != {} ? gpu.read_index(mesh.impostor) : 0,
		impostor_size = mesh.impostor_size,
		impostor_sphere = {mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, mesh.bounds.radius},
	}
}

// lod_scale is what the mesh shader path's level of detail scales an error by, over its distance, for a view of a
// height in pixels: the error's height on the screen, over the largest that may show (see Quality.lod_error). The mesh
// shader path draws the coarsest level of each part of a mesh that shows at most that.
@(private)
lod_scale :: proc(view: View, height: u32, error_pixels: f32) -> f32 {
	return 0.5 * f32(height) / math.tan(view.vertical_fov * 0.5) / max(error_pixels, MIN_LOD_ERROR)
}

// ensure_draw_buffers grows the frame's draw buffers to hold its draws in every view, and its bins' counts.
@(private = "file")
ensure_draw_buffers :: proc(r: ^Renderer, draws, counts: int) {
	s := &r.scene
	platform := r.platform
	if draws > s.capacity || s.arguments == {} {
		platform.gpu_destroy_buffer(s.arguments)
		platform.gpu_destroy_buffer(s.mesh_arguments)
		platform.gpu_destroy_buffer(s.draws)
		s.capacity = max(draws, s.capacity * 2, 256)
		s.arguments = platform.gpu_create_buffer({size = u32(s.capacity * size_of(gpu.Draw_Indirect_Args)), usage = {.Storage, .Indirect}, label = "draw arguments"}, nil)
		s.mesh_arguments = platform.gpu_create_buffer({size = u32(s.capacity * size_of(gpu.Draw_Mesh_Indirect_Args)), usage = {.Storage, .Indirect}, label = "mesh draw arguments"}, nil)
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

// draw_scene_view draws each bin of a view's group with one indirect draw, with its material's pipeline for a pass (see
// VIEW_CAMERA). A bin whose pipeline is not compiled yet draws with its blend mode's substitute, which bin_draws chose
// (see docs/rendering/materials.md#runtime). The forward and transparent passes push the frame's textures. The sorted
// transparent draws blend over the scene, a two-sided one's back faces first. Every pass but the shadow maps' draws with
// the view model's stencil bit as the reference: set for the view model, clear for the world (see
// docs/rendering/layers-and-output.md#view-model).
@(private)
draw_scene_view :: proc(f: ^Frame, cb: ^gpu.Command_Buffer, view: int, pass: format.Material_Pass, group := Bin_Group.Opaque) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 || view >= sf.view_count {
		return
	}
	g := f.graph
	arguments, mesh_arguments, counts := gpu_buffer(g, sf.arguments), gpu_buffer(g, sf.mesh_arguments), gpu_buffer(g, sf.counts)
	pushes := pass == .Forward || pass == .Transparent
	push: Material_Push
	if pushes {
		push = material_push(f, pass, group)
	}
	if pass != .Depth {
		gpu.cmd_set_stencil_reference(cb, view == VIEW_VIEW_MODEL ? VIEW_MODEL_STENCIL : 0)
	}
	bin_count := len(sf.bin_pipelines)
	bins := sf.groups[group]
	for bin in bins[0] ..< bins[1] {
		p := &f.renderer.materials.pipelines[sf.bin_draws[bin]]
		pipelines := [2]gpu.Pipeline{{}, p.pipelines[pass]}
		if pass == .Transparent && group == .Sorted {
			pipelines = p.over
		}
		// The same test as add_items, of the bin's own material, so the bin's items are all on the path that it draws. A
		// substitute without the path draws nothing there. An impostors' bin draws with the impostor passes.
		impostors := sf.bin_impostors[bin]
		mesh_path := f.renderer.materials.pipelines[sf.bin_pipelines[bin]].mesh_path && group == .Opaque && !impostors
		if mesh_path {
			pipelines[1] = p.meshes[pass]
		}
		if impostors {
			pipelines[1] = p.pipelines[format.material_impostor_pass(pass)]
		}
		first := u32(view * sf.draws_per_view) + sf.bin_offsets[bin]
		for pipeline in pipelines {
			if pipeline == {} {
				continue
			}
			gpu.cmd_set_pipeline(cb, pipeline)
			gpu.cmd_set_pass_constants(cb, sf.view_constants[view])
			if pushes {
				gpu.cmd_push_constants(cb, &push)
			}
			count_offset := u32(view * bin_count + bin) * 4
			if mesh_path {
				gpu.cmd_draw_mesh_indirect(cb, mesh_arguments, first * size_of(gpu.Draw_Mesh_Indirect_Args), sf.bin_counts[bin], counts, count_offset)
			} else {
				gpu.cmd_draw_indirect(cb, arguments, first * size_of(gpu.Draw_Indirect_Args), sf.bin_counts[bin], counts, count_offset)
			}
		}
	}
}

// material_push is the frame's textures for the forward pass or a transparent pass. A transparent surface has no
// prepass, so its template reads neither the ambient occlusion nor the shadow mask, which belong to the opaque surface
// behind it. Moment-based transparency's transparent pass reads the moments.
@(private)
material_push :: proc(f: ^Frame, pass: format.Material_Pass, group: Bin_Group) -> Material_Push {
	g := f.graph
	white := gpu.read_index(f.renderer.materials.defaults[.White])
	push := Material_Push{shadow_atlas = white, shadow_mask = white, ambient_occlusion = white, fog = white, gi_diffuse = white, gi_specular = white}
	if f.gi_diffuse != 0 {
		push.gi_diffuse = gpu.read_index(gpu_texture(g, f.gi_diffuse))
		push.gi_specular = gpu.read_index(gpu_texture(g, f.gi_specular))
	}
	if f.fog_volume != 0 {
		push.fog = gpu.read_index(gpu_texture(g, f.fog_volume))
	}
	if f.shadows.atlas != 0 {
		push.shadow_atlas = gpu.read_index(gpu_texture(g, f.shadows.atlas))
	}
	if pass == .Transparent {
		if group == .Moments && f.moments_zeroth != 0 {
			push.moments_zeroth = gpu.read_index(gpu_texture(g, f.moments_zeroth))
			push.moments = gpu.read_index(gpu_texture(g, f.moments))
			push.transmittance = 1
		}
		return push
	}
	if f.ambient_occlusion != 0 {
		push.ambient_occlusion = gpu.read_index(gpu_texture(g, f.ambient_occlusion))
	}
	if f.shadows.mask != 0 {
		push.shadow_mask = gpu.read_index(gpu_texture(g, f.shadows.mask))
	}
	return push
}
