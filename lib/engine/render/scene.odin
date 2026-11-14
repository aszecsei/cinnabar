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
// material's pipelines. An Instanced_Mesh_Renderer has one slot, and its instance set's instances are culled on the GPU
// first (see docs/rendering/gpu-scene.md#instanced-meshes). The view model's instances are relative to the camera, not the origin (see
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
// The instance sets' cells, which keep their visibility bits from frame to frame, are at most this many.
MAX_INSTANCE_CELLS :: 1 << 18
// The views' lists of visible instances hold at most this many, 128 MB. A set's list in a view that would pass it is
// cut short.
MAX_VISIBLE_INSTANCES :: 1 << 25
// Each cull_instances.hlsl group culls a cell.
#assert(format.INSTANCE_CELL_SIZE == 256)

// CULL_SHADER is the engine's culling shader (lib/engine/content/shaders/cull_draws.hlsl), by its .meta file.
CULL_SHADER :: #load("../content/shaders/cull_draws.hlsl.meta", string)
// INSTANCE_CULL_SHADER culls the instance sets' instances (lib/engine/content/shaders/cull_instances.hlsl).
INSTANCE_CULL_SHADER :: #load("../content/shaders/cull_instances.hlsl.meta", string)

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
	// The ambient light's constant, x, y and z (see Ambient).
	ambient:                  [4][4]f32,
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
	// The mesh particles' instances, which a draw with DRAW_PARTICLES reads (see
	// docs/rendering/particles.md#mesh-particles).
	particle_instances:       u32,
	// The views' lists of visible instances, which a draw with DRAW_INSTANCES reads (see
	// docs/rendering/gpu-scene.md#instanced-meshes).
	visible_instances:        u32,
	// The late view's Occlusion_Constants in the upload ring, which its amplification shaders test each meshlet
	// against (see occlusion.odin): the buffer's read index plus 1, and 0 in every other view.
	occlusion:                u32,
	occlusion_offset:         u32,
	// The meshlets that select meshlets picked, which a draw with DRAW_SELECTED reads (see meshlet_select.odin).
	selected_meshlets:        u32,
	// The virtual shadow map, whose levels are the first shadow views (see virtual_shadows.odin): how many, 0 without it,
	// how a distance picks one, the level that this view draws, the pool's read and write views, the page table, and
	// the pool's pages.
	virtual_levels:             u32,
	virtual_level:              u32,
	virtual_first_texel:        f32,
	virtual_pixel_angle:        f32,
	virtual_bias:               f32,
	virtual_pool:               u32,
	virtual_pool_storage:       u32,
	virtual_table:              u32,
	virtual_pool_pages_per_row: u32,
	virtual_pool_pages:         u32,
	// Whether this view is one of the levels, which its amplification shaders cull against the level's pages.
	virtual_draw:               u32,
	// The global illumination's voxelization, whose views draw a level of its clipmap (see Voxel_View): whether this view
	// is one, the level's voxels across and their size, its first voxel's corner relative to the camera and its texel,
	// and the albedo's, the normal's, the emission's and the mask's write views.
	voxel_draw:                 u32,
	voxel_res:                  u32,
	voxel_size:                 f32,
	voxel_min:                  [3]f32,
	voxel_phase:                [3]i32,
	voxel_albedo:               u32,
	voxel_normal:               u32,
	voxel_emission:             u32,
	voxel_mask:                 u32,
	// The sky's cubemap, which the specular light takes along the reflection (see Sky_Cube_Reads): no mips without one.
	sky_cube_current:           u32,
	sky_cube_previous:          u32,
	sky_cube_blend:             f32,
	sky_cube_mips:              f32,
	sky_cube_sampler:           u32,
	// The reflection probes (see Reflection_Probe_Reads): their records in the upload ring at this offset of its
	// buffer, how many, 0 without them, their lists in the light clusters, their cube array and its mips, and the
	// roughnesses between which they fade out over the global illumination's specular light.
	reflection_probes:            u32,
	reflection_probes_offset:     u32,
	reflection_probe_count:       u32,
	reflection_probe_clusters:    u32,
	reflection_probe_cubes:       u32,
	reflection_probe_mips:        f32,
	reflection_probe_rough_start: f32,
	reflection_probe_rough_end:   f32,
	// Whether this view is a face of a reflection probe's capture (see reflection_probes.odin), whose indirect light is
	// the world probes', when they run, at their grid in the upload ring, or the Environment's.
	capture:                      u32,
	world_probes:                 u32,
	world_probe_grid:             u32,
	world_probe_grid_offset:      u32,
	// The screen-space or traced reflections are in Material_Push.reflections: only the camera's view reads them (see
	// screen_reflections.odin).
	reflections:                  u32,
	// The cloud shadow map (see cloud_shadow_constants in clouds.odin): its read index, 0 without one, its bilinear
	// sampler, how dark the shadow is, the layer's bottom relative to the camera, the fade as the sun nears the horizon,
	// the map's center relative to the camera, 1 over its side, and the layer's top relative to the camera, above which
	// nothing takes the shadow. A reflection probe's faces have none.
	cloud_shadow:                 u32,
	cloud_shadow_sampler:         u32,
	cloud_shadow_strength:        f32,
	cloud_shadow_bottom:          f32,
	cloud_shadow_fade:            f32,
	cloud_shadow_center:          [2]f32,
	cloud_shadow_inv_extent:      f32,
	cloud_shadow_top:             f32,
	// The view's projection: the camera's in every view's copy, the view model's in its own, and a face's in a
	// reflection probe's capture.
	projection:                   View_Projection,
	// The pool of mesh pages and its page table, as read indices, which the mesh shader path draws a paged mesh's
	// meshlets from (see mesh_pages.odin).
	mesh_pool:                    u32,
	mesh_pages:                   u32,
	// Whether Material_Push has the aerial perspective volume, and its clamping sampler. A reflection probe's faces have
	// none.
	aerial:                       u32,
	aerial_sampler:               u32,
	// The atlas's soft shadows (see soft_shadow_map in material_lighting.hlsli): the level's Soft_Params, with no taps
	// without them, the sampler that the blocker search gathers depths with, and the blue noise that turns the taps and
	// its slice for this frame, 0 without it. Only the camera's view has them.
	shadow_soft_search:           u32,
	shadow_soft_taps:             u32,
	shadow_soft_radius:           f32,
	shadow_depth_sampler:         u32,
	shadow_noise:                 u32,
	shadow_noise_slice:           u32,
	soft_padding:                 [2]u32,
}

// Material_Push matches Material_Push in material_common.hlsli: the forward pass's textures that exist only once the
// frame records. ambient_occlusion is white without it, fog is read only when Frame_Constants.fog says so, the global
// illumination only when Frame_Constants.gi does, and the screen-space or traced reflections only when
// Frame_Constants.reflections does.
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
	// The forward pass's measurements, each a write index plus 1, and 0 when the frame does not count them (see
	// Shading_Frame).
	quad_counts:       u32,
	shading_stats:     u32,
	reflections:       u32,
	// The aerial perspective volume, read only when Frame_Constants.aerial says so.
	aerial:            u32,
}

// Draw_Record matches Draw_Record in material_common.hlsli. material is its block's offset in the material table.
// mesh is the mesh's index, with the submesh's index in its mesh above ID_ENTITY_BITS, as the ID buffer has it. first
// and count are the submesh's indices, or on the mesh shader path its meshlets. bound is the material's displacement
// bound in meters, which the mesh shader path's culling adds to each meshlet's sphere. A draw with DRAW_PARTICLES draws
// its submesh once for each of its emitter's living particles, whose instances start at instance in
// Frame_Constants.particle_instances (see docs/rendering/particles.md#mesh-particles). A draw with DRAW_INSTANCES draws
// its submesh once for each of its instance set's instances that its view sees, whose list starts at visible in
// Frame_Constants.visible_instances (see docs/rendering/gpu-scene.md#instanced-meshes). A draw with DRAW_SELECTED has
// its meshlets' indices, from first, in Frame_Constants.selected_meshlets, which select meshlets picked from its
// submesh's hierarchy (see docs/rendering/gpu-scene.md#mesh-shader-path).
Draw_Record :: struct {
	instance: u32,
	mesh:     u32,
	first:    u32,
	material: u32,
	count:    u32,
	bound:    f32,
	flags:    u32,
	visible:  u32,
}

// Match DRAW_PARTICLES, DRAW_INSTANCES and DRAW_SELECTED in material_common.hlsli, cull_draws.hlsl and
// particle_meshes.hlsl.
DRAW_PARTICLES :: 1
DRAW_INSTANCES :: 2
DRAW_SELECTED :: 4
// An instanced draw's flags have its count of instances above this bit, and on the mesh shader path its groups have
// its instances in rows of INSTANCE_GROUP_ROW, at most MAX_MESH_GROUPS in all, as D3D12 allows a mesh dispatch (see
// docs/rendering/gpu-scene.md#instanced-meshes).
DRAW_INSTANCE_SHIFT :: 8
INSTANCE_GROUP_ROW :: 32768
MAX_MESH_GROUPS :: 1 << 22

MESH_RECORD_INDEX32 :: 1
MESH_RECORD_UV1 :: 2
MESH_RECORD_COLOR :: 4
// A skinned entity's record: its positions, previous_positions and attributes are its own posed copies (see
// docs/rendering/gpu-scene.md#skinned-meshes).
MESH_RECORD_SKINNED :: 8
// A paged mesh's record: its meshlets are in the pool of pages, its pages are page_count entries of the page table from
// pages, and its positions, attributes and indices are its level 0, once that is resident.
MESH_RECORD_PAGED :: 16

// Mesh_Record matches Mesh_Record in material_common.hlsli and select_meshlets.hlsl: a resident mesh's buffers, as
// bindless indices, its meshlet nodes for a mesh with them, and its impostor's atlas, the side of its frames and the
// sphere that they see, for a mesh with one (see docs/rendering/gpu-scene.md#impostors). A skinned entity has a record
// of its own, whose previous_positions are last frame's posed positions.
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
	meshlet_nodes:     u32,
	previous_positions: u32,
	impostor_sphere:   [4]f32,
	pages:             u32,
	page_count:        u32,
	// Where the vertices start in positions and attributes, which only a shader sets, for a meshlet of a page.
	positions_offset:  u32,
	attributes_offset: u32,
}

// The clean slots that a run of the instance upload may cross, which costs less than a copy of its own.
@(private)
INSTANCE_RUN_GAP :: 16
// Past this many runs, one run covers them all.
@(private)
MAX_INSTANCE_RUNS :: 256

// Instance_Run is a range of slots whose records go to the persistent buffer.
@(private)
Instance_Run :: struct {
	first, count: u32,
}

// Instance_Record matches Instance_Record in material_common.hlsli and cull_draws.hlsl: the pose relative to the
// render origin, last frame's, and the entity's value in the ID buffer.
Instance_Record :: struct {
	rows:          [3][4]f32,
	previous_rows: [3][4]f32,
	id:            u32,
	flags:         u32,
	// A mesh particle's color, as unorm8, which scales its mesh's vertex colors.
	color:         u32,
	// An Instanced_Mesh_Renderer's instance set's instances, whose poses are relative to these rows.
	instance_set:  u32,
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
// A mesh particle emitter's item of a submesh, whose draws particle_meshes.hlsl writes (see
// docs/rendering/particles.md#mesh-particles): cull_draws.hlsl skips it, and sort_bins gives it a bin of its own,
// which draws with vertex pulling.
ITEM_PARTICLES :: 256
// An Instanced_Mesh_Renderer's item of a submesh, or of its impostor, whose instances cull_instances.hlsl culls (see
// docs/rendering/gpu-scene.md#instanced-meshes): cull_draws.hlsl draws it once for each of its set's instances that a
// view sees in its list. Its entry is its set's in Scene_Frame.sets, and its list is a level bucket, or
// INSTANCE_IMPOSTOR_LIST.
ITEM_INSTANCED :: 512
// An item on the mesh shader path whose submesh has a hierarchy over its meshlets, which select meshlets walks (see
// meshlet_select.odin): its entry is its submesh's first meshlet node, and its list its count of roots.
ITEM_HIERARCHY :: 1024
// A skinned entity's item, whose mesh record is its own posed copy of its mesh (see
// docs/rendering/gpu-scene.md#skinned-meshes). It draws with vertex pulling whatever its material's pipelines are, so
// sort_bins gives it a bin of its own.
ITEM_SKINNED :: 2048
// The items that sort_bins gives bins of their own, apart from their pipelines' others.
ITEM_BIN_KINDS :: ITEM_IMPOSTOR | ITEM_PARTICLES | ITEM_SKINNED
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
	// An ITEM_PARTICLES item's entry in Scene_Frame.mesh_particles, an ITEM_INSTANCED item's set in Scene_Frame.sets, or
	// an ITEM_HIERARCHY item's first meshlet node.
	entry:    u32,
	// An ITEM_INSTANCED item's list of its set's instances, or an ITEM_HIERARCHY item's count of roots.
	list:     u32,
	lod_sphere: [4]f32,
}

// A view that draws only the items that cast shadows, and the view that draws only the view model's items, which every
// other view leaves out.
VIEW_CASTERS :: 1
VIEW_MODEL :: 2
// A view of the voxel cones' voxelization, which picks its own level of detail from every level's meshlets, as the
// camera's walk of a hierarchy does not.
VIEW_VOXELS :: 16

// Cull_View matches Cull_View in cull_draws.hlsl: a view's planes relative to the camera, the camera's offset from the
// space of the view's instances, and its first draw.
Cull_View :: struct {
	planes:     [6][4]f32,
	offset:     [4]f32,
	first_draw: u32,
	flags:      u32,
	// A virtual shadow map's level, which culls against its pages (see virtual_page_fields): 0 for another view.
	virtual_table: u32,
	virtual_page: u32,
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
	// The instance sets' counters (see Instance_Cull_Constants), with the count of views and where the lists' starts
	// are among them, in words: an instanced item's draw is its set's count of visible instances in its view.
	instance_counters:  u32,
	instance_views:     u32,
	instance_ranges:    u32,
	// The frame's Occlusion_Constants in the upload ring, without occlusion culling 0, and the first view of the
	// dispatch, whose rows are the views from it: the late view's culling is a dispatch of its own.
	occlusion:          u32,
	occlusion_offset:   u32,
	view_first:         u32,
	// The camera's tally (see Cull_Stats), as its write index.
	stats:              u32,
	// What select meshlets picked for each ITEM_HIERARCHY item (see meshlet_select.odin), as its read index.
	selections:         u32,
	// The virtual shadow map's levels, which the early dispatch's rows skip: they cull after the page table is written, in
	// a dispatch of their own.
	view_skip:          u32,
	padding:            u32,
}

// Instance_Set_Record matches Instance_Set_Record in cull_instances.hlsl: an Instanced_Mesh_Renderer's set this frame.
// instances and cells are its set's buffers, first_cell its first in the visibility bits, and first_job its first cell
// in the frame's. sphere is its mesh's, which each instance is culled by, grown by bound, its materials' largest
// displacement bound, and impostor_error picks between the mesh and its impostor, when the set has one.
Instance_Set_Record :: struct {
	instances:      u32,
	cells:          u32,
	first_cell:     u32,
	first_job:      u32,
	slot:           u32,
	flags:          u32,
	bound:          f32,
	impostor_error: f32,
	sphere:         [4]f32,
	// For each level below the last bucket's, the largest parent error of the mesh's meshlets there and how far their
	// parents' spheres reach from its center, which pick each instance's level bucket (see Resident_Mesh.levels).
	levels:         [INSTANCE_LEVEL_BUCKETS][2]f32,
}

// An instance set's visible instances in a view are in lists: one for each level bucket of its mesh, the finest level
// that the camera could select for the instance, up to the last bucket, which takes the levels past it too, and the
// impostor's. An item of a bucket draws the meshlets from its level up, so a far instance tests only its mesh's coarse
// meshlets.
INSTANCE_LEVEL_BUCKETS :: 8
INSTANCE_LISTS :: INSTANCE_LEVEL_BUCKETS + 1
INSTANCE_IMPOSTOR_LIST :: INSTANCE_LEVEL_BUCKETS

// A set whose instances cast shadows, which the shadow views take; whose mesh's impostor draws past where it takes
// over, for every submesh; and with a billboard's submesh, whose sphere turns about each instance's position.
SET_CASTS_SHADOWS :: 1
SET_IMPOSTOR :: 2
SET_BILLBOARD :: 4
// A set whose items are all opaque, which occlusion culling culls (see occlusion.odin).
SET_OCCLUDABLE :: 8

// Instance_Views are the views of a dispatch of cull_instances.hlsl: the early ones, the late view when the frame culls
// by occlusion, and a virtual shadow map's levels, once the page table is written.
Instance_Views :: enum {
	Early,
	Late,
	Virtual,
}

// The phases of cull_instances.hlsl, a dispatch each: culling each cell's instances in each view, which writes their
// bits and counts them; placing each set's lists; and listing each cell's visible instances in them.
INSTANCE_PHASE_CULL :: 0
INSTANCE_PHASE_PLACE :: 1
INSTANCE_PHASE_LIST :: 2

// Instance_Cull_Constants matches Instance_Cull_Constants in cull_instances.hlsl. The sets, the jobs (a cell each, as
// its set's index) and the views are in the upload ring. A cell's visibility bits in a view are at (view × bits_cells
// + cell) × INSTANCE_BITS_SIZE: 256 bits of the instances that the view sees, then 4 bits of each one's list. The
// counters are a word for each of each set's lists in each view (INSTANCE_LISTS): the counts, the cursors that the
// listing takes places with, the lists' starts, then the total.
Instance_Cull_Constants :: struct {
	phase:            u32,
	set_count:        u32,
	view_count:       u32,
	job_count:        u32,
	sets:             u32,
	sets_offset:      u32,
	jobs:             u32,
	jobs_offset:      u32,
	views:            u32,
	views_offset:     u32,
	instances:        u32,
	bits:             u32,
	bits_cells:       u32,
	counters:         u32,
	visible:          u32,
	visible_capacity: u32,
	camera:           [4]f32,
	lod_scale:        f32,
	lod_near:         f32,
	// The views of a dispatch, the early phases' or the late view's, and the frame's Occlusion_Constants.
	view_first:       u32,
	view_rows:        u32,
	occlusion:        u32,
	occlusion_offset: u32,
	// The camera's tally (see Cull_Stats).
	stats:            u32,
	// The virtual shadow map's levels, which the early phases' rows skip.
	view_skip:        u32,
}

// The bytes of a cell's visibility bits in a view, and the groups in a row of a dispatch of the cells.
INSTANCE_BITS_SIZE :: 160
INSTANCE_JOB_ROW :: 32768

// Cell_Range is a slot's range of the instance sets' cells.
Cell_Range :: struct {
	first, count: u32,
}

#assert(size_of(Instance_Record) == 112 && size_of(Cull_Item) == 80 && size_of(Draw_Record) == 32 && size_of(Mesh_Record) == 80)
#assert(size_of(Cull_View) == 128 && size_of(Frame_Constants) == 960 && size_of(Cull_Constants) == 144)
#assert(size_of(Instance_Set_Record) == 112 && size_of(Instance_Cull_Constants) == 112)

// Gpu_Scene is the GPU scene's state between frames, in the Renderer.
Gpu_Scene :: struct {
	origin:                   ecs.World_Position,
	origin_set:               bool,
	// The slot of each entity with a Mesh_Renderer, in host memory.
	slots:                    map[ecs.Entity]u32,
	slot_entities:            [MAX_INSTANCES]ecs.Entity,
	// Each slot's presented pose as of its last write, and the frame that last saw its entity.
	previous:                 [MAX_INSTANCES]ecs.Transform,
	seen:                     [MAX_INSTANCES]u64,
	// What the persistent buffer holds, or will once this frame's copy runs, and the slots that it does not hold yet.
	records:                  [MAX_INSTANCES]Instance_Record,
	dirty:                    [MAX_INSTANCES / 64]u64,
	// The world of the last frame. The versions of the last two frames' scans, of which the older is what this frame
	// compares with: a chunk that stopped moving gets one more write, so that last frame's pose catches up.
	world:                    ^ecs.World,
	versions:                 [2]u64,
	// The last alpha, and the frame that it changed.
	alpha:                    f32,
	alpha_frame:              u64,
	// The last frame whose copy into the persistent buffer ran. Any other frame's dirty slots were lost.
	copied_frame:             u64,
	// The slots that this frame's upload covers.
	uploaded_slots:           int,
	free:                     [dynamic]u32,
	// Slots below this have been used.
	high:                     u32,
	frame:                    u64,
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
	// What select meshlets picks each frame, and the pass (see meshlet_select.odin).
	meshlet_select:           Meshlet_Select,
	// The skinned entities' buffers and the pass that poses them (see skinning.odin).
	skins:                    Skin_State,
	// Each Instanced_Mesh_Renderer's slot's range of the instance sets' cells, the free ranges in order, and the end of
	// the used ones.
	slot_cells:               [MAX_INSTANCES]Cell_Range,
	cell_free:                [dynamic]Cell_Range,
	cell_high:                u32,
	// The cells' visibility bits in each view, which last from frame to frame while a slot keeps its range, the
	// instance sets' counters, and the views' lists of visible instances, each grown as a frame needs.
	instance_bits:            gpu.Buffer,
	bits_cells:               u32,
	bits_views:               u32,
	instance_counters:        gpu.Buffer,
	counter_capacity:         int,
	visible_instances:        gpu.Buffer,
	visible_capacity:         int,
	instance_pipeline:        Shader_Pipeline,
	occlusion:                Occlusion,
}

// Bin_Group is a range of the frame's bins: the opaque and masked materials', which the prepass, the shadow maps and
// the forward pass draw, those of moment-based transparency, and the sorted transparent and additive draws, a bin for
// each item, back to front (see docs/rendering/transparency.md#transparency).
Bin_Group :: enum u8 {
	Opaque,
	Moments,
	Sorted,
}

// Bin_Filter is which of a group's bins draw_scene_view draws. The camera's prepass draws the mesh particles' bins after
// the rest, once the particle history has the depth without them, so a mesh particle does not collide with itself or
// another (see docs/rendering/particles.md#collision).
Bin_Filter :: enum u8 {
	All,
	No_Particles,
	Particles,
}

// Scene_Frame is what one frame's GPU scene passes need, in frame memory.
@(private)
Scene_Frame :: struct {
	items:           []Cull_Item,
	// A material pipeline for each bin, and each bin's first draw and its count of items, within a view's draws.
	bin_pipelines:   []int,
	// The pipeline that each bin draws with this frame: its own, or a substitute while its own compiles.
	bin_draws:       []int,
	// The bins of impostors, which draw with their pipelines' impostor passes, and of mesh particles, which draw with
	// vertex pulling.
	bin_impostors:   []bool,
	bin_particles:   []bool,
	// The bins of skinned entities, which draw with vertex pulling too.
	bin_skinned:     []bool,
	bin_offsets:     []u32,
	bin_counts:      []u32,
	// A texture of a material that the frame draws is not resident yet, so it samples its default.
	waiting:         bool,
	// The draws of one view: the items, with each surface's reserved patches.
	draws_per_view:  int,
	// The patch surfaces' records, and their upload.
	surfaces:        []Surface_Record,
	surface_upload:  gpu.Upload,
	// The particle ribbons, with their items, and their vertices once the ribbons' build writes them (see
	// docs/rendering/particles.md#ribbons).
	ribbons:         []Ribbon_Entry,
	ribbon_vertices: Buffer,
	// The mesh particles' items, and their instances once the particles' update writes them (see
	// docs/rendering/particles.md#mesh-particles).
	mesh_particles:     []Mesh_Particle_Entry,
	particle_instances: Buffer,
	// The Instanced_Mesh_Renderers' sets and their upload, the frame's cells (a set's index each) and the count of the
	// sets' instances (see docs/rendering/gpu-scene.md#instanced-meshes).
	sets:               []Instance_Set_Record,
	set_upload:         gpu.Upload,
	job_upload:         gpu.Upload,
	job_count:          int,
	set_instances:      int,
	// The constants of each phase of cull_instances.hlsl, for each Instance_Views, and its buffers.
	instance_constants: [Instance_Views][3]gpu.Upload,
	instance_bits:      Buffer,
	instance_counters:  Buffer,
	visible_instances:  Buffer,
	// Each group's first bin and the bin after its last.
	groups:          [Bin_Group][2]int,
	// The camera, the view model, then each shadow view.
	view_count:      int,
	// With occlusion culling, the late view after them, and the views that have draws: the late view's too.
	occluding:       bool,
	late_view:       int,
	draw_views:      int,
	occlusion:       Occlusion_Frame,
	// The camera's tally (see Cull_Stats).
	stats:           Buffer,
	// The instance sets' counters this frame, in words, which update_scene zeroes.
	counter_words:   int,
	instance_upload: gpu.Upload,
	instance_runs:   []Instance_Run,
	item_upload:     gpu.Upload,
	mesh_upload:     gpu.Upload,
	table_upload:    gpu.Upload,
	bin_upload:      gpu.Upload,
	zero_upload:     gpu.Upload,
	// Each view's Frame_Constants.
	view_constants:  []gpu.Upload,
	cull_constants:  gpu.Upload,
	// The culling's constants for a virtual shadow map's levels, which run after the page table is written.
	virtual_cull:    gpu.Upload,
	// With the ray scene, the acceleration structure's instance of each mesh instance that casts shadows or has a
	// surface (see docs/rendering/ray-scene.md#ray-scene), the hit table's records of each slot and of their submeshes,
	// and the bins that its submeshes use.
	accel_instances: gpu.Upload,
	accel_count:     int,
	hit_instances:   gpu.Upload,
	hit_submeshes:   gpu.Upload,
	hit_instance_count: int,
	hit_bins:        []u32,
	instances:       Buffer,
	arguments:       Buffer,
	mesh_arguments:  Buffer,
	draws:           Buffer,
	counts:          Buffer,
	patches:         Buffer,
	patch_counts:    Buffer,
	meshlet_select:  Meshlet_Select_Frame,
	// The skinned entities' jobs this frame.
	skin:            Skin_Frame,
}

scene_init :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	// So that a slot that no frame has seen, whose seen is 0, was not seen in the frame before the first.
	s.frame = 1
	s.slots = make(map[ecs.Entity]u32, platform.heap_allocator)
	s.free = make([dynamic]u32, platform.heap_allocator)
	s.instances = platform.gpu_create_buffer({size = MAX_INSTANCES * size_of(Instance_Record), label = "gpu scene instances"}, nil)
	s.patches = platform.gpu_create_buffer({size = MAX_SURFACES * MAX_SURFACE_PATCHES * 4, usage = {.Storage}, label = "surface patches"}, nil)
	s.patch_counts = platform.gpu_create_buffer({size = MAX_SURFACES * 4, usage = {.Storage}, label = "surface patch counts"}, nil)
	s.cull_pipeline = shader_pipeline(CULL_SHADER)
	s.select_pipeline = shader_pipeline(SELECT_PATCHES_SHADER)
	s.cull_patches_pipeline = shader_pipeline(CULL_PATCHES_SHADER)
	s.cell_free = make([dynamic]Cell_Range, platform.heap_allocator)
	s.instance_pipeline = shader_pipeline(INSTANCE_CULL_SHADER)
	occlusion_init(&s.occlusion)
	meshlet_select_init(&s.meshlet_select, platform)
	skin_init(&s.skins, platform)
}

scene_destroy :: proc(s: ^Gpu_Scene, platform: ^core.Platform_API) {
	delete(s.slots)
	delete(s.free)
	delete(s.cell_free)
	for b in ([]gpu.Buffer{s.instances, s.arguments, s.mesh_arguments, s.draws, s.counts, s.patches, s.patch_counts, s.instance_bits, s.instance_counters, s.visible_instances}) {
		platform.gpu_destroy_buffer(b)
	}
	destroy_shader_pipeline(&s.cull_pipeline, platform)
	destroy_shader_pipeline(&s.instance_pipeline, platform)
	occlusion_destroy(&s.occlusion, platform)
	meshlet_select_destroy(&s.meshlet_select, platform)
	skin_destroy(&s.skins, platform)
	destroy_shader_pipeline(&s.select_pipeline, platform)
	destroy_shader_pipeline(&s.cull_patches_pipeline, platform)
}

// snap_origin is the corner of the 1024 m cell that holds a position.
snap_origin :: proc(p: ecs.World_Position) -> ecs.World_Position {
	mask := ~i64((1 << ORIGIN_CELL_BITS) - 1)
	return {raw = {p.raw.x & mask, p.raw.y & mask, p.raw.z & mask}}
}

// build_scene writes the GPU scene's records for the frame: every instance, a draw item for each visible submesh with
// its material's block, the mesh records and the material table. add_scene_passes then culls the items. An entity that
// has a pose in skins and a skinned mesh draws posed (see skinning.odin).
//
// An extra view (see Frame.extra) writes none of the scene's records and keeps none of its state: it takes the slots, the
// records and the origin that the frame's own view's call left in this frame, and makes the items and the bins of its own.
// A skinned entity draws as the frame's own view posed it. The view model is left out, as its records are relative to the
// frame's own camera, and so are the ribbons and the mesh particles.
@(private)
build_scene :: proc(f: ^Frame, w: ^ecs.World, hidden: []u32, skins: []Skin_Pose) {
	r := f.renderer
	s := &r.scene
	extra := f.extra
	if !extra {
		s.frame += 1
	}
	sf := new(Scene_Frame, r.platform.frame_allocator)
	f.scene_frame = sf

	full: bool
	poses: Pose_Change
	if !extra {
		// Every slot is written if the persistent buffer may not hold what records does, or if the poses mean something else.
		full = s.world != w || s.copied_frame != s.frame - 1
		s.world = w
		// The origin moves when the camera is far from it, and then every pose is written relative to the new one.
		if !s.origin_set || max_abs(ecs.position_sub(f.view.position, s.origin)) > REBASE_CELLS * ORIGIN_CELL {
			s.origin, s.origin_set = snap_origin(f.view.position), true
			full = true
		}
		since := full ? 0 : s.versions[0]
		s.versions[0], s.versions[1] = s.versions[1], ecs.take_version(w)
		if w.clock.alpha != s.alpha {
			s.alpha, s.alpha_frame = w.clock.alpha, s.frame
		}
		// A Transform written since the last tick's snapshot differs from its Previous_Transform, so the pose between them
		// moves with alpha. The frame after alpha stops is that one more write too.
		poses = {
			since         = since,
			snapshot      = w.snapshot_version,
			interpolating = s.frame - s.alpha_frame <= 1,
		}
	}
	sync_compute_pipeline(&s.cull_pipeline, r.platform, r.residency.assets, {label = "cull draws"}, r.reloaded)
	sync_compute_pipeline(&s.select_pipeline, r.platform, r.residency.assets, {label = "select patches"}, r.reloaded)
	sync_compute_pipeline(&s.cull_patches_pipeline, r.platform, r.residency.assets, {label = "cull patches"}, r.reloaded)
	sync_compute_pipeline(&s.instance_pipeline, r.platform, r.residency.assets, {label = "cull instances"}, r.reloaded)
	sync_compute_pipeline(&s.occlusion.pipeline, r.platform, r.residency.assets, {label = "depth pyramid"}, r.reloaded)
	sync_compute_pipeline(&s.meshlet_select.pipeline, r.platform, r.residency.assets, {label = "select meshlets"}, r.reloaded)
	sync_compute_pipeline(&s.skins.pipeline, r.platform, r.residency.assets, {label = "skin meshes"}, r.reloaded)

	table := Material_Table {
		uses  = make(map[format.Guid]Material_Use, r.platform.frame_allocator),
		bytes = make([dynamic]byte, r.platform.frame_allocator),
	}
	meshes := make([dynamic]Mesh_Record, r.platform.frame_allocator)
	mesh_indices := make(map[^Resident_Mesh]u32, r.platform.frame_allocator)
	items := make([dynamic]Cull_Item, r.platform.frame_allocator)
	accel_instances := make([dynamic]gpu.Accel_Instance, r.platform.frame_allocator)
	// An entity with a pose draws at rest until the skinning pipeline has compiled.
	skin := skin_build(extra || pipeline_ready(r.platform, &s.skins.pipeline) ? skins : nil, r.platform.frame_allocator)
	// Once a feature has traced, the meshes have acceleration structures, and hit shading needs the hit table.
	tracing := r.residency.accels
	hits: Hit_Table
	if tracing {
		hits.instances = make([]Hit_Instance, MAX_INSTANCES, r.platform.frame_allocator)
		hits.submeshes = make([dynamic]Hit_Submesh, r.platform.frame_allocator)
	}

	it := ecs.query_iter(w, r.meshes.query)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Mesh_Renderer)
		view_model := len(ecs.column(view, EXTRACT_TERMS + 1, View_Model)) > 0
		moved := chunk_poses_changed(view, poses, previous != nil)
		for e, i in entities {
			slot, slot_ok := frame_slot(s, e, extra)
			if !slot_ok {
				continue
			}
			if view_model {
				if extra {
					continue
				}
				pose := current[i]
				if previous != nil {
					pose = ecs.interpolate(ecs.Transform(previous[i]), pose, w.clock.alpha)
				}
				last := s.seen[slot] == s.frame - 1 ? s.previous[slot] : pose
				// Relative to the camera, and last frame's relative to last frame's camera, so it changes without its chunk.
				last_camera := f.state.previous.valid ? f.state.previous.position : f.view.position
				scene_write_record(s, slot, {rows = pose_rows(pose, f.view.position), previous_rows = pose_rows(last, last_camera), id = entity_id(e)})
				s.previous[slot], s.seen[slot] = pose, s.frame
			} else if !extra {
				scene_write_instance(s, w, e, slot, moved, i, current, previous)
			}
			if is_hidden(hidden, e) {
				continue
			}
			first_item := len(items)
			mesh := add_items(r, &table, &meshes, &mesh_indices, &items, &skin, renderers[i], e, slot, view_model, extra)
			// A skinned entity's rays see its own structure, over its posed positions, which the ray scene refits.
			skinned := mesh != nil && first_item < len(items) && items[first_item].flags & ITEM_SKINNED != 0
			blas := mesh != nil ? mesh.accel : {}
			if skinned {
				blas = s.skins.instances[slot].accel
			}
			// The view model's pose is not its place in the world, so rays do not see it.
			if tracing && mesh != nil && blas != {} && !view_model {
				mask: u8 = renderers[i].cast_shadows ? RAY_MASK_SHADOWS : 0
				if add_hit_entries(&hits, slot, mesh, items[first_item:], r.materials.pipelines[:], hit_pipeline_ready, r.platform) {
					mask |= RAY_MASK_SURFACES
				}
				if mask != 0 {
					reference := r.platform.gpu_accel_reference(blas)
					append(&accel_instances, gpu.accel_instance(s.records[slot].rows, reference, id = slot, mask = mask, flags = {.Force_Opaque}))
					// The frame's own view refits the skinned structures, over the positions that it posed.
					if skinned && !extra {
						append(&skin.refits, Skin_Refit{slot = slot, indices = mesh.indices})
					}
				}
			}
		}
	}
	// The Instanced_Mesh_Renderers: a slot each, at the entity's pose, which its set's instances are relative to, and an
	// item for each submesh, whose draws the GPU writes once it has culled the instances.
	sets := make([dynamic]Instance_Set_Record, r.platform.frame_allocator)
	jobs := make([dynamic]u32, r.platform.frame_allocator)
	set_instances := 0
	instanced_it := ecs.query_iter(w, r.instanced.query)
	for view in ecs.query_next(&instanced_it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Instanced_Mesh_Renderer)
		moved := chunk_poses_changed(view, poses, previous != nil)
		for e, i in entities {
			slot, slot_ok := frame_slot(s, e, extra)
			if !slot_ok {
				continue
			}
			if !extra {
				scene_write_instance(s, w, e, slot, moved, i, current, previous)
			}
			if is_hidden(hidden, e) {
				continue
			}
			set_instances += add_instanced_items(r, &table, &meshes, &mesh_indices, &items, &sets, &jobs, renderers[i], slot, extra)
		}
	}
	// The patch surfaces: an instance record as a mesh's, and one item each, whose draws the GPU adds (see
	// docs/rendering/surfaces.md#surfaces).
	surfaces := make([dynamic]Surface_Record, r.platform.frame_allocator)
	camera_offset := ecs.position_sub(f.view.position, s.origin)
	lod, _ := lod_scale(f.view, f.size.y, f.lod_error)
	surface_it := ecs.query_iter(w, r.surfaces.query)
	for view in ecs.query_next(&surface_it) {
		entities := ecs.entities(view)
		current := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		renderers := ecs.column(view, EXTRACT_TERMS, Surface_Renderer)
		moved := chunk_poses_changed(view, poses, previous != nil)
		for e, i in entities {
			slot, slot_ok := frame_slot(s, e, extra)
			if !slot_ok {
				continue
			}
			if !extra {
				scene_write_instance(s, w, e, slot, moved, i, current, previous)
			}
			if is_hidden(hidden, e) || len(surfaces) >= MAX_SURFACES {
				continue
			}
			add_surface(r, &table, &items, &surfaces, renderers[i], slot, s.records[slot].rows, camera_offset, lod)
		}
	}
	// The particle ribbons: a slot each, at their systems' anchors, and an item each, whose draw the GPU writes.
	ribbons := add_ribbon_items(f, w, &table, &items, hidden)
	// The mesh particles: an item for each submesh of each mesh emitter, whose draws the GPU writes.
	mesh_particles := add_mesh_particle_items(f, w, &table, &meshes, &mesh_indices, &items, hidden)
	if !extra {
		sweep_skins(&s.skins, r.platform, s.frame)
		// A slot whose entity has no Mesh_Renderer, Instanced_Mesh_Renderer, Surface_Renderer or particle system any more is
		// free again, and so are its cells.
		for slot in 0 ..< s.high {
			if s.seen[slot] != s.frame && s.slot_entities[slot] != 0 {
				delete_key(&s.slots, s.slot_entities[slot])
				s.slot_entities[slot] = 0
				scene_write_record(s, slot, {})
				free_cells(s, slot)
				append(&s.free, slot)
			}
		}
	}

	// Each pipeline's opaque or moment-based items are a bin, in one range of each view's draws. Each sorted item is a
	// bin of its own, back to front from the camera by its bounds' middle, so the bins draw in that order.
	camera := ecs.position_sub(f.view.position, s.origin)
	_, _, forward := view_axes(f.view)
	orthographic := is_orthographic(f.view)
	sorting := make([]Sort_Item, len(items), r.platform.frame_allocator)
	for item, i in items {
		sorting[i] = {item = item, group = material_group(&r.materials.pipelines[item.bin])}
		if sorting[i].group == .Sorted {
			// The view model's instances are relative to the camera already.
			eye := item.flags & ITEM_VIEW_MODEL != 0 ? [3]f32{} : camera
			// An orthographic view sorts by the depth along its axis, which is what covers what in it.
			sorting[i].distance = orthographic ? depth_along(s.records[item.instance].rows, item.sphere.xyz, eye, forward) : squared_distance(s.records[item.instance].rows, item.sphere.xyz, eye)
		}
	}
	sf.bin_pipelines, sf.groups = sort_bins(sorting, items[:], r.platform.frame_allocator)
	sf.bin_draws = bin_draws(r, sf.bin_pipelines)
	sf.waiting = table.waiting
	sf.bin_impostors = bin_impostors(items[:], len(sf.bin_pipelines), r.platform.frame_allocator)
	sf.bin_particles = bin_particles(items[:], len(sf.bin_pipelines), r.platform.frame_allocator)
	sf.bin_skinned = bin_skinned(items[:], len(sf.bin_pipelines), r.platform.frame_allocator)
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
		if item.flags & ITEM_PARTICLES != 0 {
			mesh_particles[item.entry].item = u32(i)
		}
	}
	sf.ribbons, sf.mesh_particles = ribbons, mesh_particles
	sf.meshlet_select.items = meshlet_select_items(r, items[:], f.no_meshlet_hierarchy, r.platform.frame_allocator)

	platform := r.platform
	// The frame's own view uploads the records that changed. An extra view uploads none, and leaves them dirty for that.
	uploaded := 0
	if !extra {
		sf.instance_runs = instance_runs(&s.dirty, s.high, full, r.platform.frame_allocator)
		s.dirty = {}
		s.uploaded_slots = 0
		for run in sf.instance_runs {
			s.uploaded_slots += int(run.count)
		}
		uploaded = s.uploaded_slots
	}
	packed := make([]Instance_Record, uploaded, r.platform.frame_allocator)
	packed_count := 0
	for run in sf.instance_runs {
		packed_count += copy(packed[packed_count:], s.records[run.first:][:run.count])
	}
	ok := true
	sf.instance_upload, ok = upload_bytes(platform, slice.to_bytes(packed))
	item_upload, items_ok := upload_bytes(platform, slice.to_bytes(items[:]))
	mesh_upload, meshes_ok := upload_bytes(platform, slice.to_bytes(meshes[:]))
	table_upload, table_ok := upload_bytes(platform, table.bytes[:])
	bin_upload, bins_ok := upload_bytes(platform, slice.to_bytes(sf.bin_offsets))
	accel_upload, accel_ok := upload_bytes(platform, slice.to_bytes(accel_instances[:]))
	hit_instance_upload, hit_submesh_upload: gpu.Upload
	hits_ok := true
	if tracing {
		instances_ok, submeshes_ok: bool
		hit_instance_upload, instances_ok = upload_bytes(platform, slice.to_bytes(hits.instances[:s.high]))
		hit_submesh_upload, submeshes_ok = upload_bytes(platform, slice.to_bytes(hits.submeshes[:]))
		hits_ok = instances_ok && submeshes_ok
	}
	surface_upload, surfaces_ok := upload_bytes(platform, slice.to_bytes(surfaces[:]))
	set_upload, sets_ok := upload_bytes(platform, slice.to_bytes(sets[:]))
	job_upload, jobs_ok := upload_bytes(platform, slice.to_bytes(jobs[:]))
	skin_ok := skin_upload(f, &skin)
	// The entities that an extra view draws as the frame's own view posed them, which it only reads.
	if extra {
		sf.skin.slots = skin.slots[:]
	}
	if !(ok && items_ok && meshes_ok && table_ok && bins_ok && accel_ok && hits_ok && surfaces_ok && sets_ok && jobs_ok && skin_ok) {
		log.error("render: the upload ring is full, so the frame draws no meshes")
		sf.items = nil
		return
	}
	sf.item_upload, sf.mesh_upload, sf.table_upload, sf.bin_upload = item_upload, mesh_upload, table_upload, bin_upload
	sf.surfaces, sf.surface_upload = surfaces[:], surface_upload
	sf.accel_instances, sf.accel_count = accel_upload, len(accel_instances)
	if tracing {
		sf.hit_instances, sf.hit_submeshes, sf.hit_instance_count = hit_instance_upload, hit_submesh_upload, int(s.high)
		// The fallback's bin is always dispatched: a hit of a submesh that has no record takes it too.
		bins := make([dynamic]u32, r.platform.frame_allocator)
		for used, bin in hits.used {
			if used || bin == 0 {
				append(&bins, u32(bin))
			}
		}
		sf.hit_bins = bins[:]
	}
	sf.sets, sf.set_upload, sf.job_upload, sf.job_count, sf.set_instances = sets[:], set_upload, job_upload, len(jobs), set_instances
}

// Sort_Item is a draw item as build_scene sorts it into bins. Its item's bin is its material pipeline.
@(private)
Sort_Item :: struct {
	item:     Cull_Item,
	group:    Bin_Group,
	// A sorted item's squared distance from the camera, or its depth along an orthographic view's axis.
	distance: f32,
}

// sort_bins writes the items in their bins' order, each with its bin, and gives each bin's material pipeline and each
// group's range of bins: the opaque bins, then moment-based transparency's, a bin for each pipeline, with its
// impostors' items, its mesh particles' items and its skinned entities' items each in a bin after its own
// (ITEM_BIN_KINDS), then a bin for each sorted item, the farthest first. The items of a bin keep their order. A frame has tens of thousands of items, which
// a counting sort by their bins orders in one pass, and few sorted items, which sort by their distance.
@(private)
sort_bins :: proc(sorting: []Sort_Item, items: []Cull_Item, allocator := context.allocator) -> (pipelines: []int, groups: [Bin_Group][2]int) {
	// The kinds of bin that a pipeline has in a group: its own items', its impostors', its mesh particles' and its skinned
	// entities'.
	KINDS :: 4
	KEYS :: (len(Bin_Group) - 1) * MAX_MATERIAL_PIPELINES * KINDS
	bin_key :: proc(s: Sort_Item) -> int {
		kind := 0
		if s.item.flags & ITEM_IMPOSTOR != 0 {
			kind = 1
		} else if s.item.flags & ITEM_PARTICLES != 0 {
			kind = 2
		} else if s.item.flags & ITEM_SKINNED != 0 {
			kind = 3
		}
		return (int(s.group) * MAX_MATERIAL_PIPELINES + int(s.item.bin)) * KINDS + kind
	}
	Far :: struct {
		distance: f32,
		index:    int,
	}
	starts := make([]int, KEYS + 1, context.temp_allocator)
	far := make([dynamic]Far, context.temp_allocator)
	for s, i in sorting {
		if s.group == .Sorted {
			append(&far, Far{s.distance, i})
		} else {
			starts[bin_key(s) + 1] += 1
		}
	}
	for k in 1 ..< len(starts) {
		starts[k] += starts[k - 1]
	}
	order := make([]int, len(sorting), context.temp_allocator)
	for s, i in sorting {
		if s.group != .Sorted {
			k := bin_key(s)
			order[starts[k]] = i
			starts[k] += 1
		}
	}
	slice.sort_by(far[:], proc(a, b: Far) -> bool {return a.distance > b.distance})
	for f, k in far {
		order[len(sorting) - len(far) + k] = f.index
	}
	bins := make([dynamic]int, allocator)
	group_bins: [Bin_Group]int
	for index, i in order {
		entry := sorting[index]
		pipeline := int(entry.item.bin)
		previous := sorting[order[max(i - 1, 0)]]
		kind := entry.item.flags & ITEM_BIN_KINDS != previous.item.flags & ITEM_BIN_KINDS
		if i == 0 || entry.group == .Sorted || entry.group != previous.group || pipeline != int(previous.item.bin) || kind {
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

// bin_particles gives whether each bin is of mesh particles, whose items sort_bins gives bins of their own.
@(private)
bin_particles :: proc(items: []Cull_Item, bins: int, allocator := context.allocator) -> []bool {
	particles := make([]bool, bins, allocator)
	for item in items {
		particles[item.bin] = item.flags & ITEM_PARTICLES != 0
	}
	return particles
}

// bin_skinned gives whether each bin is of skinned entities, whose items sort_bins gives bins of their own.
@(private)
bin_skinned :: proc(items: []Cull_Item, bins: int, allocator := context.allocator) -> []bool {
	skinned := make([]bool, bins, allocator)
	for item in items {
		skinned[item.bin] = item.flags & ITEM_SKINNED != 0
	}
	return skinned
}

// has_mesh_particles is whether any of the frame's bins is of mesh particles.
@(private)
has_mesh_particles :: proc(sf: ^Scene_Frame) -> bool {
	return sf != nil && slice.contains(sf.bin_particles, true)
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

// depth_along is how far a point of an instance is from a point, along a direction.
@(private)
depth_along :: proc(rows: [3][4]f32, p: [3]f32, from: [3]f32, direction: [3]f32) -> f32 {
	depth: f32
	for row, k in rows {
		depth += (row.x * p.x + row.y * p.y + row.z * p.z + row.w - from[k]) * direction[k]
	}
	return depth
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
	// The view's last frame's camera, for the velocities. A view that was not drawn last frame has none.
	previous := &f.state.previous
	has_previous := previous.valid
	f.previous_view_projection = has_previous ? previous.view_projection : f.view_projection
	f.camera_motion = has_previous ? ecs.position_sub(f.view.position, previous.position) : {}
	now := frame_time(r)
	defer previous^ = {
		position        = f.view.position,
		rotation        = f.view.rotation,
		view_projection = f.view_projection,
		view_model      = view_model,
		time            = now,
		valid           = true,
	}
	// The fog's injection, the voxel cones' and the sprite renderers' draw read the camera's constants, so they are
	// written without draws too.
	has_items := len(sf.items) > 0
	voxels := f.gi != nil ? f.gi.voxel : nil
	if !has_items && f.fog == nil && voxels == nil && !f.wants_sheet_sprites {
		return
	}
	// The voxel cones' views come after the shadow views (see Voxel_View), then a reflection probe capture's faces.
	sf.view_count = FIRST_SHADOW_VIEW + len(shadows.views)
	if voxels != nil {
		voxels.first_view = sf.view_count
		sf.view_count += len(voxels.views)
	}
	if probes := f.reflection_probes; probes != nil && probes.capturing {
		probes.first_view = sf.view_count
		sf.view_count += int(probes.face_count)
	}
	// With occlusion culling, the late view is one more, after the shadow views.
	sf.occluding = has_items && occlusion_ready(f, f.no_occlusion)
	sf.late_view = sf.view_count
	sf.draw_views = sf.view_count + (sf.occluding ? 1 : 0)
	ok: bool
	if has_items {
		ensure_draw_buffers(r, sf.draws_per_view * sf.draw_views, len(sf.bin_pipelines) * sf.draw_views)
		if len(sf.sets) > 0 {
			sf.counter_words = 3 * len(sf.sets) * sf.draw_views * INSTANCE_LISTS + 1
			ensure_instance_buffers(r, sf.draw_views, sf.counter_words, min(sf.set_instances * sf.draw_views, MAX_VISIBLE_INSTANCES))
		}
		// The zeros clear the bins' counts, the instance sets' counters and this frame's slots' bits.
		zeros := make([]byte, max(len(sf.bin_pipelines) * sf.draw_views * 4, sf.counter_words * 4, MAX_INSTANCES / 8), platform.frame_allocator)
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
	if has_previous {
		previous_offset = ecs.position_sub(previous.position, s.origin)
		previous_projection = previous.view_projection
		previous_view_model = previous.view_model
		previous_rotation = previous.rotation
	}
	right, up, forward := view_axes(f.view)
	orthographic := is_orthographic(f.view)
	camera_lod_scale, camera_lod_near := lod_scale(f.view, f.size.y, f.lod_error)
	previous_right, previous_up, _ := view_axes({rotation = previous_rotation})
	constants := Frame_Constants {
		view_projection          = f.view_projection,
		previous_view_projection = previous_projection,
		cluster_view_projection  = f.view_projection,
		camera_offset            = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		previous_camera_offset   = {previous_offset.x, previous_offset.y, previous_offset.z, 0},
		origin_offset            = {camera_offset.x, camera_offset.y, camera_offset.z, 0},
		ambient                  = ambient_constants(ambient),
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
		previous_time            = has_previous ? previous.time : now,
		meshes_offset            = sf.mesh_upload.offset,
		materials_offset         = sf.table_upload.offset,
		surfaces                 = gpu.read_index(sf.surface_upload.buffer),
		surfaces_offset          = sf.surface_upload.offset,
		ribbon_vertices          = gpu.read_index(r.particles.ribbon_vertices),
		particle_instances       = gpu.read_index(r.particles.mesh_instances),
		visible_instances        = gpu.read_index(s.visible_instances),
		lights                   = gpu.read_index(lf.upload.buffer),
		lights_offset            = lf.upload.offset,
		directional_count        = u32(lf.directional_count),
		cluster_columns          = lf.columns,
		cluster_rows             = lf.rows,
		slice_scale              = lf.slice_scale,
		slice_bias               = lf.slice_bias,
		near                     = f.projection.z,
		projection               = f.projection,
		shadow_sampler           = gpu.sampler_index(r.shadows.sampler),
		shadow_views             = gpu.read_index(shadows.views_upload.buffer),
		shadow_views_offset      = shadows.views_upload.offset,
		clustered                = u32(lf.clustered),
		screen_size              = {f32(f.size.x), f32(f.size.y)},
		exposure                 = gpu.read_index(f.state.post.exposure),
		ltc_matrix               = gpu.read_index(r.lights.ltc_matrix),
		ltc_amplitude            = gpu.read_index(r.lights.ltc_amplitude),
		ltc_sampler              = gpu.sampler_index(r.lights.ltc_sampler),
		debug_view               = u32(f.debug_view),
		shadow_filter            = u32(shadows.params.filter),
		lod_scale                = camera_lod_scale,
		lod_near                 = camera_lod_near,
		selected_meshlets        = gpu.read_index(s.meshlet_select.selected),
		mesh_pool                = gpu.read_index(r.residency.pool.pool),
		mesh_pages               = gpu.read_index(r.residency.pool.table),
	}
	constants.gi = u32(f.gi != nil)
	constants.reflections = u32(f.ssr != nil)
	soft_shadow_constants(&constants, f)
	cube := sky_cube_reads(f)
	constants.sky_cube_current, constants.sky_cube_previous = cube.current, cube.previous
	constants.sky_cube_blend, constants.sky_cube_mips = cube.blend, cube.mips
	constants.sky_cube_sampler = gpu.sampler_index(r.post.sampler)
	reflection_probe_constants(&constants, f)
	cloud_shadow_constants(&constants, f)
	if shadows.virtual.count > 0 {
		virtual_constants(&constants, f)
	}
	if f.fog != nil {
		constants.fog, constants.fog_sampler, constants.fog_scale = 1, gpu.sampler_index(r.post.sampler), f.fog.scale
		constants.fog_slices = f.fog.grid.z
	}
	if f.sky != nil && f.sky.has_aerial {
		constants.aerial, constants.aerial_sampler = 1, gpu.sampler_index(r.post.sampler)
	}
	if lf.clustered {
		constants.clusters = gpu.read_index(r.lights.clusters)
		constants.cluster_indices = gpu.read_index(r.lights.indices)
	}
	sf.view_constants = make([]gpu.Upload, sf.draw_views, platform.frame_allocator)
	views := make([]Cull_View, sf.draw_views, platform.frame_allocator)
	for v in 0 ..< sf.view_count {
		c := constants
		views[v].first_draw = u32(v * sf.draws_per_view)
		views[v].offset = constants.camera_offset
		// Only the camera's surfaces are in the reflections' texture.
		if v != VIEW_CAMERA {
			c.reflections = 0
		}
		// The soft shadows' noise needs temporal AA's history, which only the camera's views have.
		if v != VIEW_CAMERA && v != VIEW_VIEW_MODEL {
			c.shadow_soft_taps = 0
		}
		switch v {
		case VIEW_CAMERA, VIEW_VIEW_MODEL:
			if v == VIEW_VIEW_MODEL {
				// The view model's instances are relative to the camera already.
				c.view_projection, c.previous_view_projection = view_model, previous_view_model
				c.camera_offset, c.previous_camera_offset = {}, {}
				c.projection = f.view_model_projection
				c.near = c.projection.z
				c.lod_scale, c.lod_near = lod_scale(view_model_view(f.view), f.size.y, f.lod_error)
				views[v].offset, views[v].flags = {}, VIEW_MODEL
			}
			planes := frustum_planes(c.view_projection)
			copy(views[v].planes[:], planes[:])
			if orthographic {
				// An orthographic view has a far plane, and looks along its axis from everywhere.
				views[v].planes[5] = frustum_planes_6(c.view_projection)[5]
				c.cull_eye = {forward.x, forward.y, forward.z, 0}
			} else {
				// The far plane is at infinity.
				views[v].planes[5] = {0, 0, 0, 1}
				c.cull_eye = {0, 0, 0, 1}
			}
			// The camera's views draw with its jitter, which the velocities leave out.
			c.view_projection = jitter_projection(c.view_projection, f.jitter)
			c.jitter = f.jitter
		case:
			if face, is_probe := reflection_probe_view(f, v); is_probe {
				reflection_probe_view_constants(f, &c, &views[v], face)
				break
			}
			if voxels != nil && v >= voxels.first_view {
				view := voxels.views[v - voxels.first_view]
				voxel_view_constants(&c, view, voxels.params.res)
				views[v].planes = view.planes
				views[v].flags = VIEW_VOXELS
				c.cull_eye = {0, 0, 0, 1}
				break
			}
			c.view_projection = shadows.matrices[v - FIRST_SHADOW_VIEW]
			if v - FIRST_SHADOW_VIEW < shadows.virtual.count {
				c.virtual_level, c.virtual_draw = u32(v - FIRST_SHADOW_VIEW), 1
				views[v].virtual_table = gpu.read_index(r.shadows.virtual.table) + 1
				views[v].virtual_page = virtual_page_fields(shadows.views[v - FIRST_SHADOW_VIEW], v - FIRST_SHADOW_VIEW)
			}
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
	// The late view draws as the camera does, after the early one.
	if sf.occluding {
		views[VIEW_CAMERA].flags |= VIEW_EARLY
		views[sf.late_view] = views[VIEW_CAMERA]
		views[sf.late_view].flags = VIEW_LATE
		views[sf.late_view].first_draw = u32(sf.late_view * sf.draws_per_view)
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
		selections         = gpu.read_index(s.meshlet_select.selections),
	}
	if ensure_cull_stats(r, f.state) {
		cull.stats = gpu.write_index(f.state.occlusion.stats)
		sf.stats = import_buffer(g, f.state.occlusion.stats)
	}
	if sf.occluding {
		if !occlusion_constants(f) {
			sf.items = nil
			return
		}
		cull.occlusion, cull.occlusion_offset = gpu.read_index(sf.occlusion.constants.buffer), sf.occlusion.constants.offset
		// The late view's constants are the camera's, with the occlusion constants for its meshlets.
		late := (^Frame_Constants)(raw_data(sf.view_constants[VIEW_CAMERA].data))^
		late.occlusion, late.occlusion_offset = cull.occlusion + 1, cull.occlusion_offset
		sf.view_constants[sf.late_view], ok = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			sf.items = nil
			return
		}
		(^Frame_Constants)(raw_data(sf.view_constants[sf.late_view].data))^ = late
	}
	if len(sf.sets) > 0 {
		cull.instance_counters = gpu.read_index(s.instance_counters)
		cull.instance_views = u32(sf.draw_views)
		cull.instance_ranges = u32(2 * len(sf.sets) * sf.draw_views * INSTANCE_LISTS)
		if !instance_constants(f, view_upload, cull) {
			sf.items = nil
			return
		}
		sf.instance_bits = import_buffer(g, s.instance_bits)
		sf.instance_counters = import_buffer(g, s.instance_counters)
		sf.visible_instances = import_buffer(g, s.visible_instances)
	}
	cull.view_skip = u32(shadows.virtual.count)
	sf.cull_constants, ok = platform.gpu_upload(size_of(Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		sf.items = nil
		return
	}
	(^Cull_Constants)(raw_data(sf.cull_constants.data))^ = cull
	if !meshlet_select_constants(f, cull) {
		sf.items = nil
		return
	}
	if shadows.virtual.count > 0 && has_items {
		levels := cull
		levels.view_first, levels.view_skip = FIRST_SHADOW_VIEW, 0
		sf.virtual_cull, ok = platform.gpu_upload(size_of(Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			sf.items = nil
			return
		}
		(^Cull_Constants)(raw_data(sf.virtual_cull.data))^ = levels
	}
	if sf.occluding {
		late := cull
		late.view_first, late.view_skip = u32(sf.late_view), 0
		sf.occlusion.late_cull, ok = platform.gpu_upload(size_of(Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if !ok {
			sf.items = nil
			return
		}
		(^Cull_Constants)(raw_data(sf.occlusion.late_cull.data))^ = late
	}

	add_skinning_pass(f)
	p := add_compute_pass(g, "update scene", update_scene, f)
	copy_dest(g, p, sf.instances)
	copy_dest(g, p, sf.counts)
	if len(sf.sets) > 0 {
		copy_dest(g, p, sf.instance_counters)
	}
	if sf.occluding {
		copy_dest(g, p, sf.occlusion.slot_seen_next)
	}
	if sf.stats != 0 {
		copy_dest(g, p, sf.stats)
	}
	if sf.meshlet_select.selections != 0 {
		copy_dest(g, p, sf.meshlet_select.selections)
	}
	add_select_patches_pass(f)
	add_meshlet_select_pass(f)
	add_instance_passes(f)
	p = add_compute_pass(g, "cull draws", cull_draws, f)
	read(g, p, sf.instances)
	if sf.meshlet_select.selections != 0 {
		read(g, p, sf.meshlet_select.selections)
	}
	if len(sf.sets) > 0 {
		read(g, p, sf.instance_counters)
	}
	if sf.occluding {
		read(g, p, sf.occlusion.slot_seen)
	}
	if sf.stats != 0 {
		write(g, p, sf.stats)
	}
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
	if sf.particle_instances != 0 {
		read(g, p, sf.particle_instances)
	}
	if sf.visible_instances != 0 {
		read(g, p, sf.visible_instances)
	}
	if sf.meshlet_select.selected != 0 {
		read(g, p, sf.meshlet_select.selected)
	}
	if f.mesh_pool.pool != 0 {
		read(g, p, f.mesh_pool.pool)
		read(g, p, f.mesh_pool.table)
	}
	declare_skinned_reads(f, p)
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

// Pose_Change is how a frame decides which chunks' poses it computes again.
@(private)
Pose_Change :: struct {
	since, snapshot: u64,
	interpolating:   bool,
}

// chunk_poses_changed is true if the presented poses of a chunk may differ from what its slots hold, by its Transform
// and Previous_Transform, the first two terms of the renderers' queries.
@(private)
chunk_poses_changed :: proc "contextless" (view: ecs.Chunk_View, change: Pose_Change, has_previous: bool) -> bool {
	return(
		ecs.changed_since(view, 0, change.since) ||
		ecs.changed_since(view, 1, change.since) ||
		(has_previous && change.interpolating && ecs.changed_since(view, 0, change.snapshot)) \
	)
}

// scene_write_instance writes the record of a row of a chunk, if its pose may have changed or its slot is new, and says
// that the slot's entity is still there.
@(private)
scene_write_instance :: proc(s: ^Gpu_Scene, w: ^ecs.World, e: ecs.Entity, slot: u32, moved: bool, i: int, current: []ecs.Transform, previous: []ecs.Previous_Transform) {
	if moved || s.seen[slot] != s.frame - 1 {
		pose := current[i]
		if previous != nil {
			pose = ecs.interpolate(ecs.Transform(previous[i]), pose, w.clock.alpha)
		}
		last := s.seen[slot] == s.frame - 1 ? s.previous[slot] : pose
		scene_write_record(s, slot, {rows = pose_rows(pose, s.origin), previous_rows = pose_rows(last, s.origin), id = entity_id(e), instance_set = s.records[slot].instance_set})
		s.previous[slot] = pose
	}
	s.seen[slot] = s.frame
}

// scene_write_record sets a slot's record, and the slot is dirty if that changed it.
@(private)
scene_write_record :: proc "contextless" (s: ^Gpu_Scene, slot: u32, record: Instance_Record) {
	if s.records[slot] != record {
		s.records[slot] = record
		s.dirty[slot / 64] |= 1 << (slot % 64)
	}
}

// instance_runs gives the ranges of slots to copy: all of them below high with full, or the dirty ones, in order. Runs
// cross small gaps, whose records are the same in both places, and many runs become one.
@(private)
instance_runs :: proc(dirty: ^[MAX_INSTANCES / 64]u64, high: u32, full: bool, allocator := context.allocator) -> []Instance_Run {
	runs := make([dynamic]Instance_Run, allocator)
	if full {
		if high > 0 {
			append(&runs, Instance_Run{0, high})
		}
		return runs[:]
	}
	for slot: u32 = 0; slot < high; slot += 1 {
		if dirty[slot / 64] == 0 && slot % 64 == 0 {
			slot += 63
			continue
		}
		if dirty[slot / 64] & (1 << (slot % 64)) == 0 {
			continue
		}
		if n := len(runs); n > 0 && slot - (runs[n - 1].first + runs[n - 1].count) <= INSTANCE_RUN_GAP {
			runs[n - 1].count = slot + 1 - runs[n - 1].first
		} else {
			append(&runs, Instance_Run{slot, 1})
		}
	}
	if len(runs) > MAX_INSTANCE_RUNS {
		last := runs[len(runs) - 1]
		first := runs[0].first
		clear(&runs)
		append(&runs, Instance_Run{first, last.first + last.count - first})
	}
	return runs[:]
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

// frame_slot gives an entity's slot: scene_slot's for the frame's own view, which gives a new entity a free one, and the
// slot that it holds for an extra view, which takes none, so an entity without a slot is not drawn there.
@(private = "file")
frame_slot :: proc(s: ^Gpu_Scene, e: ecs.Entity, extra: bool) -> (slot: u32, ok: bool) {
	if extra {
		return s.slots[e]
	}
	return scene_slot(s, e)
}

// scene_cells gives a slot's range of the instance sets' cells, which it keeps while its set's count of cells does, so
// their visibility bits are last frame's, or a new one.
@(private)
scene_cells :: proc(s: ^Gpu_Scene, slot: u32, count: u32) -> (cells: Cell_Range, ok: bool) {
	if s.slot_cells[slot].count == count {
		return s.slot_cells[slot], true
	}
	free_cells(s, slot)
	for &f, i in s.cell_free {
		if f.count >= count {
			cells = {f.first, count}
			f.first += count
			f.count -= count
			if f.count == 0 {
				ordered_remove(&s.cell_free, i)
			}
			s.slot_cells[slot] = cells
			return cells, true
		}
	}
	if s.cell_high + count > MAX_INSTANCE_CELLS {
		log.errorf("render: more than %d cells of instance sets", MAX_INSTANCE_CELLS)
		return
	}
	cells = {s.cell_high, count}
	s.cell_high += count
	s.slot_cells[slot] = cells
	return cells, true
}

// free_cells gives back a slot's range of cells, merged with the free ranges beside it, or below the used ones' end.
@(private)
free_cells :: proc(s: ^Gpu_Scene, slot: u32) {
	cells := s.slot_cells[slot]
	s.slot_cells[slot] = {}
	if cells.count == 0 {
		return
	}
	at := len(s.cell_free)
	for f, i in s.cell_free {
		if f.first > cells.first {
			at = i
			break
		}
	}
	inject_at(&s.cell_free, at, cells)
	if at + 1 < len(s.cell_free) && s.cell_free[at].first + s.cell_free[at].count == s.cell_free[at + 1].first {
		s.cell_free[at].count += s.cell_free[at + 1].count
		ordered_remove(&s.cell_free, at + 1)
	}
	if at > 0 && s.cell_free[at - 1].first + s.cell_free[at - 1].count == s.cell_free[at].first {
		s.cell_free[at - 1].count += s.cell_free[at].count
		ordered_remove(&s.cell_free, at)
		at -= 1
	}
	if last := s.cell_free[len(s.cell_free) - 1]; last.first + last.count == s.cell_high {
		s.cell_high = last.first
		pop(&s.cell_free)
	}
}

// add_instanced_items adds an Instanced_Mesh_Renderer's set, with a job for each of its cells, and an ITEM_INSTANCED
// item for each submesh of its mesh, when the mesh and the set are resident (see
// docs/rendering/gpu-scene.md#instanced-meshes). Its impostor's items are added too when every submesh's material has
// the impostor path, since each instance draws all of its submeshes or its impostor. It gives the set's count of
// instances.
@(private = "file")
add_instanced_items :: proc(
	r: ^Renderer,
	table: ^Material_Table,
	meshes: ^[dynamic]Mesh_Record,
	mesh_indices: ^map[^Resident_Mesh]u32,
	items: ^[dynamic]Cull_Item,
	sets: ^[dynamic]Instance_Set_Record,
	jobs: ^[dynamic]u32,
	renderer: Instanced_Mesh_Renderer,
	slot: u32,
	extra: bool,
) -> int {
	mesh, mesh_ready := resident_mesh(&r.residency, renderer.mesh)
	set, set_ready := resident_instance_set(&r.residency, renderer.instances)
	if !mesh_ready || !set_ready {
		return 0
	}
	// An extra view takes the cells that the frame's own view gave the slot, and none if they are not the set's.
	cells, cells_ok := r.scene.slot_cells[slot], r.scene.slot_cells[slot].count == set.cell_count
	if !extra {
		cells, cells_ok = scene_cells(&r.scene, slot, set.cell_count)
	}
	if !cells_ok {
		return 0
	}
	mesh_index, known := mesh_indices[mesh]
	if !known {
		mesh_index = u32(len(meshes))
		append(meshes, mesh_record(mesh))
		mesh_indices[mesh] = mesh_index
	}
	index := u32(len(sets))
	first_item := len(items)
	impostors := mesh.impostor != {}
	occludable := true
	set_flags: u32
	bound: f32
	// Each submesh's item, which has a copy for each level bucket and, with impostors, the impostor's.
	submesh_items := make([dynamic]Cull_Item, context.temp_allocator)
	for submesh, s in mesh.submeshes[:mesh.submesh_count] {
		material := renderer.materials[s] if s < MAX_MATERIAL_SLOTS else {}
		use := use_material(r, table, material) or_continue
		// A material that draws patches or ribbons draws no mesh: the default material stands in.
		if r.materials.pipelines[use.pipeline].patches || r.materials.pipelines[use.pipeline].ribbon {
			use = use_material(r, table, {}) or_continue
		}
		pipeline := &r.materials.pipelines[use.pipeline]
		flags: u32 = ITEM_INSTANCED
		if renderer.cast_shadows && pipeline.cast_shadows {
			flags |= ITEM_CASTS_SHADOWS
			set_flags |= SET_CASTS_SHADOWS
		}
		if pipeline.billboard {
			flags |= ITEM_BILLBOARD
			set_flags |= SET_BILLBOARD
		}
		// The mesh shader path tests every meshlet of an instanced mesh, so every page of a paged one stays. Vertex
		// pulling draws its level 0, once that is in.
		if pipeline.mesh_path && material_group(pipeline) == .Opaque {
			resident_pin(&r.residency, mesh)
		} else if !resident_level0(&r.residency, mesh) {
			continue
		}
		impostors &&= pipeline.impostor_path && material_group(pipeline) == .Opaque
		occludable &&= material_group(pipeline) == .Opaque
		bound = max(bound, pipeline.displacement_bound)
		b := mesh.submesh_bounds[s] if s < MAX_SUBMESHES else mesh.bounds
		item := Cull_Item {
			instance = slot,
			mesh     = mesh_index,
			first    = submesh.first_index,
			count    = submesh.index_count,
			material = use.block,
			bin      = u32(use.pipeline),
			flags    = flags,
			submesh  = u32(min(s, ID_MAX_SUBMESH)),
			sphere   = {b.center.x, b.center.y, b.center.z, b.radius},
			bound    = pipeline.displacement_bound,
			entry    = index,
		}
		append(&submesh_items, item)
		// On the mesh shader path, a bucket's item draws the submesh's meshlets from the bucket's level up; with vertex
		// pulling, each draws the submesh's indices.
		mesh_path := pipeline.mesh_path && material_group(pipeline) == .Opaque
		for bucket in 0 ..< INSTANCE_LEVEL_BUCKETS {
			level := item
			level.list = u32(bucket)
			if mesh_path {
				first := mesh.level_first[s][bucket] if s < MAX_SUBMESHES else 0
				level.flags |= ITEM_MESH_PATH
				level.first, level.count = submesh.first_meshlet + first, submesh.meshlet_count - first
			}
			append(items, level)
		}
	}
	if len(items) == first_item {
		return 0
	}
	if occludable {
		set_flags |= SET_OCCLUDABLE
	}
	if impostors {
		set_flags |= SET_IMPOSTOR
		for item in submesh_items {
			impostor := item
			impostor.flags |= ITEM_IMPOSTOR
			impostor.first, impostor.count, impostor.bound = 0, IMPOSTOR_VERTICES, 0
			impostor.list = INSTANCE_IMPOSTOR_LIST
			append(items, impostor)
		}
	}
	m := mesh.bounds
	append(sets, Instance_Set_Record {
		instances      = gpu.read_index(set.instances),
		cells          = gpu.read_index(set.cells),
		first_cell     = cells.first,
		first_job      = u32(len(jobs)),
		slot           = slot,
		flags          = set_flags,
		bound          = bound,
		impostor_error = mesh.impostor_error,
		sphere         = {m.center.x, m.center.y, m.center.z, m.radius},
		levels         = mesh.levels,
	})
	for _ in 0 ..< set.cell_count {
		append(jobs, index)
	}
	if !extra {
		record := r.scene.records[slot]
		record.instance_set = gpu.read_index(set.instances)
		scene_write_record(&r.scene, slot, record)
	}
	return int(set.count)
}

// add_items adds a draw item for each submesh of a Mesh_Renderer whose mesh is resident, with its material's block and
// pipeline, and gives the mesh, or nil if it is not ready. An item's bin holds its pipeline until build_scene numbers
// the bins. A submesh of a mesh with an impostor, whose material has the impostor path, has a second item, its
// impostor's, and culling draws one of the two (see docs/rendering/gpu-scene.md#impostors). The entity of a mesh with a
// skin stream that has a pose in skins draws posed instead: its items, all ITEM_SKINNED, name a mesh record of its own,
// and its job poses its vertices this frame (see skinning.odin).
@(private = "file")
add_items :: proc(
	r: ^Renderer,
	table: ^Material_Table,
	meshes: ^[dynamic]Mesh_Record,
	mesh_indices: ^map[^Resident_Mesh]u32,
	items: ^[dynamic]Cull_Item,
	skins: ^Skin_Build,
	renderer: Mesh_Renderer,
	entity: ecs.Entity,
	slot: u32,
	view_model: bool,
	extra: bool,
) -> ^Resident_Mesh {
	mesh, ready := resident_mesh(&r.residency, renderer.mesh)
	if !ready {
		return nil
	}
	mesh_index: u32
	pose := skins.poses[entity] if mesh.skin != {} else nil
	skinned := false
	if pose != nil && extra {
		// The buffers that the frame's own view posed this frame. An entity that it did not pose draws at rest.
		if instance, posed := skin_posed(&r.scene.skins, r.scene.frame, slot, entity, mesh); posed {
			skinned = true
			mesh_index = u32(len(meshes))
			append(meshes, skinned_mesh_record(mesh, instance))
			skin_reuse(skins, slot)
		}
	} else if pose != nil {
		instance, reset, instance_ok := skin_instance(
			&r.scene.skins,
			r.platform,
			r.scene.frame,
			slot,
			entity,
			mesh.positions,
			mesh.vertex_count,
			mesh.attribute_stride,
		)
		if instance_ok {
			skinned = true
			if r.residency.accels {
				skin_accel(&r.scene.skins, r.platform, slot, mesh)
			}
			mesh_index = u32(len(meshes))
			append(meshes, skinned_mesh_record(mesh, instance))
			skin_add(skins, mesh, instance, slot, pose, reset)
		}
	}
	if !skinned {
		known: bool
		mesh_index, known = mesh_indices[mesh]
		if !known {
			mesh_index = u32(len(meshes))
			append(meshes, mesh_record(mesh))
			mesh_indices[mesh] = mesh_index
		}
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
		// The opaque draws of a material with mesh pipelines draw meshlets, except a skinned entity's, whose posed vertices
		// only the vertex pulling path reads.
		first, count := submesh.first_index, submesh.index_count
		pipeline := &r.materials.pipelines[use.pipeline]
		mesh_path := pipeline.mesh_path && material_group(pipeline) == .Opaque && !skinned
		if mesh_path {
			flags |= ITEM_MESH_PATH
			first, count = submesh.first_meshlet, submesh.meshlet_count
			// The view model's amplification shaders test every meshlet, so every page of a paged mesh stays for it.
			if view_model {
				resident_pin(&r.residency, mesh)
			}
		} else if !resident_level0(&r.residency, mesh) {
			// Vertex pulling draws a paged mesh's level 0, which is on its way.
			continue
		}
		if skinned {
			flags |= ITEM_SKINNED
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
		// The pose moves the vertices out of their submesh's bounds, so every submesh takes the pose's sphere.
		if skinned {
			item.sphere = pose.sphere
		}
		// The view model's level of detail is its own view's, which the selection does not take, so its amplification
		// shaders test every meshlet. The impostor's item below is made from flags, without the hierarchy.
		if mesh_path && submesh.node_count > 0 && !view_model {
			item.flags |= ITEM_HIERARCHY
			item.entry, item.list = submesh.first_node, submesh.root_count
		}
		// The view model is near the camera, where its impostor never draws.
		if mesh.impostor != {} && pipeline.impostor_path && material_group(pipeline) == .Opaque && !view_model && !skinned {
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

// skinned_mesh_record is a skinned entity's record of its mesh: the mesh's, with the entity's posed copies of its
// positions and attributes, and last frame's positions. The hierarchy and the impostor are not for a posed mesh.
@(private)
skinned_mesh_record :: proc(mesh: ^Resident_Mesh, instance: Skinned_Instance) -> Mesh_Record {
	record := mesh_record(mesh)
	record.flags |= MESH_RECORD_SKINNED
	record.positions = gpu.read_index(instance.positions)
	record.attributes = gpu.read_index(instance.attributes)
	record.previous_positions = gpu.read_index(instance.previous)
	record.impostor, record.impostor_size, record.meshlet_nodes = 0, 0, 0
	return record
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
	if mesh.paged {
		flags |= MESH_RECORD_PAGED
	}
	return {
		pages = mesh.pages_first,
		page_count = mesh.page_count,
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
		meshlet_nodes = mesh.meshlet_nodes != {} ? gpu.read_index(mesh.meshlet_nodes) : 0,
		impostor_sphere = {mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, mesh.bounds.radius},
	}
}

// A view without perspective has one level of detail at every distance: its distances are all this far, which no
// point in the scene is, so an error over the distance is the error alone. The voxelization's views and an
// orthographic camera's take it.
LOD_FLAT_NEAR :: 1e9

// lod_scale is what the mesh shader path's level of detail scales an error by, over its distance, for a view of a
// height in pixels: the error's height on the screen, over the largest that may show (see Quality.lod_error). The mesh
// shader path draws the coarsest level of each part of a mesh that shows at most that. near is the least distance that
// counts: the near plane in perspective, and LOD_FLAT_NEAR in orthographic, where a pixel is as large at every
// distance.
@(private)
lod_scale :: proc(view: View, height: u32, error_pixels: f32) -> (scale, near: f32) {
	switch p in view.projection {
	case Perspective:
		return 0.5 * f32(height) / math.tan(p.vertical_fov * 0.5) / max(error_pixels, MIN_LOD_ERROR), p.near
	case Orthographic:
		return LOD_FLAT_NEAR * f32(height) / p.height / max(error_pixels, MIN_LOD_ERROR), LOD_FLAT_NEAR
	}
	return
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

// ensure_instance_buffers grows the instance sets' buffers to hold the frame's: their cells' visibility bits in every
// view, their counters, and the views' lists of visible instances. The bits are lost when their buffer grows.
@(private = "file")
ensure_instance_buffers :: proc(r: ^Renderer, views, counters, visible: int) {
	s := &r.scene
	platform := r.platform
	if s.cell_high > s.bits_cells || u32(views) > s.bits_views || s.instance_bits == {} {
		platform.gpu_destroy_buffer(s.instance_bits)
		s.bits_cells = min(max(s.cell_high, s.bits_cells * 2, 1024), MAX_INSTANCE_CELLS)
		s.bits_views = max(u32(views), s.bits_views)
		s.instance_bits = platform.gpu_create_buffer({size = s.bits_cells * s.bits_views * INSTANCE_BITS_SIZE, usage = {.Storage}, label = "instance bits"}, nil)
	}
	if counters > s.counter_capacity || s.instance_counters == {} {
		platform.gpu_destroy_buffer(s.instance_counters)
		s.counter_capacity = max(counters, s.counter_capacity * 2, 256)
		s.instance_counters = platform.gpu_create_buffer({size = u32(s.counter_capacity * 4), usage = {.Storage}, label = "instance counters"}, nil)
	}
	if visible > s.visible_capacity || s.visible_instances == {} {
		platform.gpu_destroy_buffer(s.visible_instances)
		s.visible_capacity = min(max(visible, s.visible_capacity * 2, 1024), MAX_VISIBLE_INSTANCES)
		s.visible_instances = platform.gpu_create_buffer({size = u32(s.visible_capacity * 4), usage = {.Storage}, label = "visible instances"}, nil)
	}
}

// instance_constants writes the constants of each phase of cull_instances.hlsl.
@(private = "file")
instance_constants :: proc(f: ^Frame, views: gpu.Upload, cull: Cull_Constants) -> bool {
	s := &f.renderer.scene
	sf := f.scene_frame
	c := Instance_Cull_Constants {
		set_count        = u32(len(sf.sets)),
		view_count       = u32(sf.draw_views),
		job_count        = u32(sf.job_count),
		sets             = gpu.read_index(sf.set_upload.buffer),
		sets_offset      = sf.set_upload.offset,
		jobs             = gpu.read_index(sf.job_upload.buffer),
		jobs_offset      = sf.job_upload.offset,
		views            = gpu.read_index(views.buffer),
		views_offset     = views.offset,
		instances        = gpu.read_index(s.instances),
		bits             = gpu.write_index(s.instance_bits),
		bits_cells       = s.bits_cells,
		counters         = gpu.write_index(s.instance_counters),
		visible          = gpu.write_index(s.visible_instances),
		visible_capacity = u32(s.visible_capacity),
		camera           = cull.camera,
		lod_scale        = cull.lod_scale,
		lod_near         = cull.lod_near,
		occlusion        = cull.occlusion,
		occlusion_offset = cull.occlusion_offset,
		stats            = cull.stats,
	}
	levels := f.shadows.virtual.count
	for &phases, views in sf.instance_constants {
		switch views {
		case .Early:
			c.view_first, c.view_rows, c.view_skip = 0, u32(sf.view_count - levels), u32(levels)
		case .Late:
			if !sf.occluding {
				continue
			}
			c.view_first, c.view_rows, c.view_skip = u32(sf.late_view), 1, 0
		case .Virtual:
			if levels == 0 {
				continue
			}
			c.view_first, c.view_rows, c.view_skip = FIRST_SHADOW_VIEW, u32(levels), 0
		}
		for &u, phase in phases {
			c.phase = u32(phase)
			ok: bool
			u, ok = f.renderer.platform.gpu_upload(size_of(Instance_Cull_Constants), gpu.PASS_CONSTANTS_ALIGN)
			if !ok {
				return false
			}
			(^Instance_Cull_Constants)(raw_data(u.data))^ = c
		}
	}
	return true
}

// add_instance_passes adds the phases of cull_instances.hlsl for the early views, after the scene's update and before
// the draws' culling, which draws each instanced item once for each instance that its set's list in the view has (see
// docs/rendering/gpu-scene.md#instanced-meshes). The camera's view takes only the instances that were visible last
// frame when the frame culls by occlusion, which reads their cells' bits.
@(private = "file")
add_instance_passes :: proc(f: ^Frame) {
	sf := f.scene_frame
	if len(sf.sets) == 0 {
		return
	}
	add_instance_phases(f, .Early)
}

// add_late_instance_passes adds the late view's phases of cull_instances.hlsl, after the depth pyramid: the instances
// that it shows and the early view did not take, and each cell's bits for next frame.
@(private)
add_late_instance_passes :: proc(f: ^Frame) {
	sf := f.scene_frame
	if len(sf.sets) == 0 {
		return
	}
	add_instance_phases(f, .Late)
}

// add_virtual_instance_passes adds a virtual shadow map's levels' phases of cull_instances.hlsl, once the page table is
// written, so they list only the instances that reach a page. It declares that they read the table.
@(private)
add_virtual_instance_passes :: proc(f: ^Frame, table: Buffer) {
	sf := f.scene_frame
	if len(sf.sets) == 0 {
		return
	}
	add_instance_phases(f, .Virtual, table)
}

// INSTANCE_PASS_NAMES are each phase's pass by its views, in INSTANCE_PHASE order.
@(private = "file", rodata)
INSTANCE_PASS_NAMES := [Instance_Views][3]string {
	.Early   = {"cull instances", "place instances", "list instances"},
	.Late    = {"cull late instances", "place late instances", "list late instances"},
	.Virtual = {"cull virtual shadow instances", "place virtual shadow instances", "list virtual shadow instances"},
}

@(private = "file")
add_instance_phases :: proc(f: ^Frame, views: Instance_Views, table: Buffer = 0) {
	sf := f.scene_frame
	g := f.graph
	alloc := f.renderer.platform.frame_allocator
	names := INSTANCE_PASS_NAMES[views]
	p := add_compute_pass(g, names[INSTANCE_PHASE_CULL], run_instance_phase, new_clone(Instance_Step{f, INSTANCE_PHASE_CULL, views}, alloc))
	read(g, p, sf.instances)
	write(g, p, sf.instance_bits)
	write(g, p, sf.instance_counters)
	if table != 0 {
		read(g, p, table)
	}
	if sf.occluding && views != .Virtual {
		if views == .Late {
			for t in sf.occlusion.hzb[:f.state.occlusion.hzb_levels] {
				read(g, p, t)
			}
		}
		write(g, p, sf.occlusion.cell_seen)
	}
	if sf.stats != 0 {
		write(g, p, sf.stats)
	}
	p = add_compute_pass(g, names[INSTANCE_PHASE_PLACE], run_instance_phase, new_clone(Instance_Step{f, INSTANCE_PHASE_PLACE, views}, alloc))
	write(g, p, sf.instance_counters)
	p = add_compute_pass(g, names[INSTANCE_PHASE_LIST], run_instance_phase, new_clone(Instance_Step{f, INSTANCE_PHASE_LIST, views}, alloc))
	write(g, p, sf.instance_bits)
	write(g, p, sf.instance_counters)
	write(g, p, sf.visible_instances)
}

// Instance_Step is a phase's pass's data, in frame memory.
@(private = "file")
Instance_Step :: struct {
	frame: ^Frame,
	phase: int,
	views: Instance_Views,
}

// run_instance_phase dispatches a phase: a group for each cell in each of its views, in rows of INSTANCE_JOB_ROW, or a
// thread for each of each set's lists in each of its views.
@(private = "file")
run_instance_phase :: proc(ctx: ^Pass_Context) {
	step := (^Instance_Step)(ctx.data)
	f := step.frame
	sf := f.scene_frame
	pipeline := f.renderer.scene.instance_pipeline.pipeline
	if pipeline == {} {
		return
	}
	levels := f.shadows.virtual.count
	rows := sf.view_count - levels
	switch step.views {
	case .Early:
	case .Late:
		rows = 1
	case .Virtual:
		rows = levels
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.instance_constants[step.views][step.phase])
	if step.phase == INSTANCE_PHASE_PLACE {
		gpu.cmd_dispatch(ctx.cb, {u32(len(sf.sets) * rows * INSTANCE_LISTS + format.INSTANCE_CELL_SIZE - 1) / format.INSTANCE_CELL_SIZE, 1, 1})
		return
	}
	jobs := u32(sf.job_count)
	gpu.cmd_dispatch(ctx.cb, {min(jobs, INSTANCE_JOB_ROW), (jobs + INSTANCE_JOB_ROW - 1) / INSTANCE_JOB_ROW, u32(rows)})
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
	source := sf.instance_upload.offset
	for run in sf.instance_runs {
		size := run.count * size_of(Instance_Record)
		gpu.cmd_copy_buffer(ctx.cb, sf.instance_upload.buffer, source, gpu_buffer(g, sf.instances), run.first * size_of(Instance_Record), size)
		source += size
	}
	// An extra view uploads no records, so it does not say that the copy ran.
	if !f.extra {
		f.renderer.scene.copied_frame = f.renderer.scene.frame
	}
	gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.counts), 0, u32(len(sf.bin_pipelines) * sf.draw_views * 4))
	if sf.counter_words > 0 {
		gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.instance_counters), 0, u32(sf.counter_words * 4))
	}
	if sf.occluding {
		gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.occlusion.slot_seen_next), 0, MAX_INSTANCES / 8)
	}
	if sf.stats != 0 {
		gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.stats), 0, CULL_STATS_WORDS * 4)
	}
	// The counter of the selected meshlets' list.
	if sf.meshlet_select.selections != 0 {
		gpu.cmd_copy_buffer(ctx.cb, sf.zero_upload.buffer, sf.zero_upload.offset, gpu_buffer(g, sf.meshlet_select.selections), 0, 4)
	}
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
	gpu.cmd_dispatch(ctx.cb, {u32(len(sf.items) + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, u32(sf.view_count - f.shadows.virtual.count), 1})
}

// draw_scene_view draws each bin of a view's group with one indirect draw, with its material's pipeline for a pass (see
// VIEW_CAMERA). A bin whose pipeline is not compiled yet draws with its blend mode's substitute, which bin_draws chose
// (see docs/rendering/materials.md#runtime). The forward and transparent passes push the frame's textures. The sorted
// transparent draws blend over the scene, a two-sided one's back faces first. Every pass but the shadow maps' draws with
// the view model's stencil bit as the reference: set for the view model, clear for the world (see
// docs/rendering/layers-and-output.md#view-model). filter leaves out the mesh particles' bins, or draws only them.
@(private)
draw_scene_view :: proc(f: ^Frame, cb: ^gpu.Command_Buffer, view: int, pass: format.Material_Pass, group := Bin_Group.Opaque, filter := Bin_Filter.All) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 || view >= sf.draw_views {
		return
	}
	g := f.graph
	arguments, mesh_arguments, counts := gpu_buffer(g, sf.arguments), gpu_buffer(g, sf.mesh_arguments), gpu_buffer(g, sf.counts)
	pushes := pass == .Forward || pass == .Transparent
	push: Material_Push
	if pushes {
		face, is_probe := reflection_probe_view(f, view)
		push = is_probe ? reflection_probe_push(f, face) : material_push(f, pass, group)
	}
	if pass != .Depth && pass != .Virtual_Depth && pass != .Voxelize {
		gpu.cmd_set_stencil_reference(cb, view == VIEW_VIEW_MODEL ? VIEW_MODEL_STENCIL : 0)
	}
	bin_count := len(sf.bin_pipelines)
	bins := sf.groups[group]
	for bin in bins[0] ..< bins[1] {
		if filter != .All && sf.bin_particles[bin] != (filter == .Particles) {
			continue
		}
		p := &f.renderer.materials.pipelines[sf.bin_draws[bin]]
		pipelines := [2]gpu.Pipeline{{}, p.pipelines[pass]}
		if pass == .Transparent && group == .Sorted {
			pipelines = p.over
		}
		// The same test as add_items, of the bin's own material, so the bin's items are all on the path that it draws. A
		// substitute without the path draws nothing there. An impostors' bin draws with the impostor passes, and the bins
		// of mesh particles and of skinned entities with vertex pulling.
		impostors := sf.bin_impostors[bin]
		// An impostor's quad faces the camera, so the voxels do not see it.
		if impostors && pass == .Voxelize {
			continue
		}
		mesh_path := f.renderer.materials.pipelines[sf.bin_pipelines[bin]].mesh_path && group == .Opaque && !impostors && !sf.bin_particles[bin] && !sf.bin_skinned[bin]
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
	black := gpu.read_index(f.renderer.materials.defaults[.Black])
	push := Material_Push{shadow_atlas = white, shadow_mask = white, ambient_occlusion = white, fog = white, gi_diffuse = white, gi_specular = white, reflections = black, aerial = white}
	if f.gi_diffuse != 0 {
		push.gi_diffuse = gpu.read_index(gpu_texture(g, f.gi_diffuse))
		push.gi_specular = gpu.read_index(gpu_texture(g, f.gi_specular))
	}
	if f.fog_volume != 0 {
		push.fog = gpu.read_index(gpu_texture(g, f.fog_volume))
	}
	if f.aerial != 0 {
		push.aerial = gpu.read_index(gpu_texture(g, f.aerial))
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
	// A frame has the mask or the contact shadows, never both (see add_shadow_passes).
	if f.shadows.mask != 0 {
		push.shadow_mask = gpu.read_index(gpu_texture(g, f.shadows.mask))
	} else if f.shadows.contact != 0 {
		push.shadow_mask = gpu.read_index(gpu_texture(g, f.shadows.contact))
	}
	if f.reflections != 0 {
		push.reflections = gpu.read_index(gpu_texture(g, f.reflections))
	}
	shading_push(f, &push.quad_counts, &push.shading_stats)
	return push
}
