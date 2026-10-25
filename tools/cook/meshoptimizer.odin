package cook

import "core:c"

// vendor/meshoptimizer, which `just meshoptimizer` builds. Its API is C, so the cooker binds it directly. Only the
// cooker links it.
foreign import meshoptimizer "../../build/meshoptimizer/Release/meshoptimizer.lib"

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
