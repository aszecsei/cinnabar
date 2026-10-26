package cook

import "core:c"

// vendor/meshoptimizer, which `just meshoptimizer` builds. Its API is C, so the cooker binds it directly. Only the
// cooker links it.
foreign import meshoptimizer "../../build/meshoptimizer/Release/meshoptimizer.lib"
// Its cluster LOD builder, demo/clusterlod.h, which `just meshoptimizer` builds from tools/cook/clusterlod.
foreign import clusterlod "../../build/clusterlod/out/cn_clusterlod.lib"

// The justfile passes the vendor/meshoptimizer tag, so a meshoptimizer update cooks every mesh again.
MESHOPTIMIZER_VERSION :: #config(MESHOPTIMIZER_VERSION, "unknown")

// meshopt_TangentCompatible: tangents that match MikkTSpace, which is what normal maps are baked with.
MESHOPT_TANGENT_COMPATIBLE :: 1

Meshopt_Meshlet :: struct {
	vertex_offset:   c.uint,
	triangle_offset: c.uint,
	vertex_count:    c.uint,
	triangle_count:  c.uint,
}

Meshopt_Bounds :: struct {
	center:         [3]f32,
	radius:         f32,
	cone_apex:      [3]f32,
	cone_axis:      [3]f32,
	cone_cutoff:    f32,
	cone_axis_s8:   [3]i8,
	cone_cutoff_s8: i8,
}

// clodConfig: how clodBuild clusters, groups and simplifies. clod_default_config gives the defaults for rasterization.
Clod_Config :: struct {
	max_vertices:                  c.size_t,
	min_triangles:                 c.size_t,
	max_triangles:                 c.size_t,
	partition_spatial:             c.bool,
	partition_sort:                c.bool,
	partition_size:                c.size_t,
	cluster_spatial:               c.bool,
	cluster_fill_weight:           f32,
	cluster_split_factor:          f32,
	simplify_ratio:                f32,
	simplify_threshold:            f32,
	simplify_error_merge_previous: f32,
	simplify_error_merge_additive: f32,
	simplify_error_factor_sloppy:  f32,
	simplify_error_edge_limit:     f32,
	simplify_error_clamped:        c.bool,
	simplify_permissive:           c.bool,
	simplify_fallback_permissive:  c.bool,
	simplify_fallback_sloppy:      c.bool,
	simplify_regularize:           c.bool,
	simplify_preserve_folds:       c.bool,
	simplify_dilate_borders:       c.bool,
	optimize_bounds:               c.bool,
	optimize_clusters:             c.bool,
	optimize_clusters_level:       c.int,
}

Clod_Mesh :: struct {
	indices:                  [^]c.uint,
	index_count:              c.size_t,
	vertex_count:             c.size_t,
	vertex_positions:         [^]f32,
	vertex_positions_stride:  c.size_t,
	vertex_attributes:        [^]f32,
	vertex_attributes_stride: c.size_t,
	vertex_lock:              [^]u8,
	attribute_weights:        [^]f32,
	attribute_count:          c.size_t,
	attribute_protect_mask:   c.uint,
}

// Clod_Bounds is a sphere in the mesh's space, and the simplification error within it.
Clod_Bounds :: struct {
	center: [3]f32,
	radius: f32,
	error:  f32,
}

// Clod_Cluster: refined is the group whose simplification made it, or -1 for the mesh's own triangles. Its indices are
// the mesh's.
Clod_Cluster :: struct {
	refined:      c.int,
	bounds:       Clod_Bounds,
	indices:      [^]c.uint,
	index_count:  c.size_t,
	vertex_count: c.size_t,
}

// Clod_Group: its clusters' simplification, whose error is F32_MAX when the group could not simplify further.
Clod_Group :: struct {
	depth:      c.int,
	simplified: Clod_Bounds,
}

// Clod_Output gets each group with its clusters, in order, and returns the ID that clusters simplified from it get.
Clod_Output :: #type proc "c" (output_context: rawptr, group: Clod_Group, clusters: [^]Clod_Cluster, cluster_count: c.size_t) -> c.int

@(default_calling_convention = "c")
foreign clusterlod {
	@(link_name = "clodDefaultConfig")
	clod_default_config :: proc(max_triangles: c.size_t) -> Clod_Config ---
	@(link_name = "clodBuild")
	clod_build :: proc(config: Clod_Config, mesh: Clod_Mesh, output_context: rawptr, output_callback: Clod_Output) ---
	@(link_name = "clodLocalIndices")
	clod_local_indices :: proc(vertices: [^]c.uint, triangles: [^]u8, indices: [^]c.uint, index_count: c.size_t) -> c.size_t ---
}

@(default_calling_convention = "c")
foreign meshoptimizer {
	meshopt_generateVertexRemap :: proc(destination: [^]c.uint, indices: [^]c.uint, index_count: c.size_t, vertices: rawptr, vertex_count: c.size_t, vertex_size: c.size_t) -> c.size_t ---
	meshopt_remapVertexBuffer :: proc(destination: rawptr, vertices: rawptr, vertex_count: c.size_t, vertex_size: c.size_t, remap: [^]c.uint) ---
	meshopt_optimizeVertexCache :: proc(destination: [^]c.uint, indices: [^]c.uint, index_count: c.size_t, vertex_count: c.size_t) ---
	meshopt_optimizeVertexFetch :: proc(destination: rawptr, indices: [^]c.uint, index_count: c.size_t, vertices: rawptr, vertex_count: c.size_t, vertex_size: c.size_t) -> c.size_t ---
	meshopt_buildMeshletsBound :: proc(index_count: c.size_t, max_vertices: c.size_t, max_triangles: c.size_t) -> c.size_t ---
	meshopt_buildMeshlets :: proc(meshlets: [^]Meshopt_Meshlet, meshlet_vertices: [^]c.uint, meshlet_triangles: [^]u8, indices: [^]c.uint, index_count: c.size_t, vertex_positions: [^]f32, vertex_count: c.size_t, vertex_positions_stride: c.size_t, max_vertices: c.size_t, max_triangles: c.size_t, cone_weight: f32) -> c.size_t ---
	meshopt_optimizeMeshlet :: proc(meshlet_vertices: [^]c.uint, meshlet_triangles: [^]u8, triangle_count: c.size_t, vertex_count: c.size_t) ---
	meshopt_computeMeshletBounds :: proc(meshlet_vertices: [^]c.uint, meshlet_triangles: [^]u8, triangle_count: c.size_t, vertex_positions: [^]f32, vertex_count: c.size_t, vertex_positions_stride: c.size_t) -> Meshopt_Bounds ---
	meshopt_computeSphereBounds :: proc(positions: [^]f32, count: c.size_t, positions_stride: c.size_t, radii: [^]f32, radii_stride: c.size_t) -> Meshopt_Bounds ---
	meshopt_generateTangents :: proc(result: [^]f32, indices: [^]c.uint, index_count: c.size_t, vertex_positions: [^]f32, vertex_count: c.size_t, vertex_positions_stride: c.size_t, vertex_normals: [^]f32, vertex_normals_stride: c.size_t, vertex_uvs: [^]f32, vertex_uvs_stride: c.size_t, options: c.uint) ---
}
