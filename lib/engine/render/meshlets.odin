package render

import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"

// build_simple_meshlets cuts a submesh's triangles into meshlets of at most MESHLET_MAX_VERTICES vertices and
// MESHLET_MAX_TRIANGLES triangles, in index order, without meshoptimizer: one level, with an error of 0 and no parent,
// so the cluster LOD selection always takes them and the culling is as for any mesh (see
// docs/rendering/assets.md#gpu-residency). The game builds the editor's live meshes with it. Each meshlet gets the sphere
// around its vertices and the normal cone of its triangles, conservative as meshoptimizer's. It appends to the three
// arrays, with offsets into them, and returns how many meshlets it made.
build_simple_meshlets :: proc(positions: [][3]f32, indices: []u32, meshlets: ^[dynamic]format.Meshlet, meshlet_vertices: ^[dynamic]u32, meshlet_triangles: ^[dynamic]u32) -> int {
	local: [format.MESHLET_MAX_VERTICES]u32
	local_count := 0
	triangles: [format.MESHLET_MAX_TRIANGLES][3]u8
	triangle_count := 0
	made := 0
	flush :: proc(positions: [][3]f32, local: []u32, triangles: [][3]u8, meshlets: ^[dynamic]format.Meshlet, meshlet_vertices: ^[dynamic]u32, meshlet_triangles: ^[dynamic]u32) {
		m := format.Meshlet {
			vertex_offset   = u32(len(meshlet_vertices)),
			triangle_offset = u32(len(meshlet_triangles)),
			vertex_count    = u8(len(local)),
			triangle_count  = u8(len(triangles)),
			parent_error    = math.F32_MAX,
		}
		// The sphere: the box's center, and the farthest vertex.
		low, high := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}, [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
		for v in local {
			low, high = linalg.min(low, positions[v]), linalg.max(high, positions[v])
		}
		m.center = (low + high) / 2
		for v in local {
			m.radius = max(m.radius, linalg.length(positions[v] - m.center))
		}
		// The cone: the area-weighted mean of the triangles' normals, and the sine of the widest angle from it, as
		// meshoptimizer takes them. A spread of a right angle or more is too wide to cull.
		axis: [3]f32
		normals := make([][3]f32, len(triangles), context.temp_allocator)
		for t, i in triangles {
			a, b, c := positions[local[t[0]]], positions[local[t[1]]], positions[local[t[2]]]
			n := linalg.cross(b - a, c - a)
			axis += n
			normals[i] = linalg.normalize0(n)
		}
		axis = linalg.normalize0(axis)
		lowest: f32 = 1
		for n in normals {
			lowest = min(lowest, linalg.dot(n, axis))
		}
		m.cone_cutoff = 127
		if axis != {} && lowest > 0.1 {
			cutoff := math.sqrt(1 - lowest * lowest)
			m.cone_cutoff = i8(min(int(cutoff * 127 + 1), 127))
			for k in 0 ..< 3 {
				m.cone_axis[k] = i8(math.round(clamp(axis[k], -1, 1) * 127))
			}
		}
		append(meshlets, m)
		append(meshlet_vertices, ..local)
		for t in triangles {
			append(meshlet_triangles, u32(t[0]) | u32(t[1]) << 8 | u32(t[2]) << 16)
		}
	}
	for t in 0 ..< len(indices) / 3 {
		corners := indices[t * 3:][:3]
		// The corners that the meshlet does not have yet, each counted once.
		new := 0
		for c, k in corners {
			found := false
			for v in local[:local_count] {
				found ||= v == c
			}
			for other in corners[:k] {
				found ||= other == c
			}
			if !found {
				new += 1
			}
		}
		if triangle_count == format.MESHLET_MAX_TRIANGLES || local_count + new > format.MESHLET_MAX_VERTICES {
			flush(positions, local[:local_count], triangles[:triangle_count], meshlets, meshlet_vertices, meshlet_triangles)
			made += 1
			local_count, triangle_count = 0, 0
		}
		for c, k in corners {
			index := -1
			for v, i in local[:local_count] {
				if v == c {
					index = i
					break
				}
			}
			if index < 0 {
				index = local_count
				local[local_count] = c
				local_count += 1
			}
			triangles[triangle_count][k] = u8(index)
		}
		triangle_count += 1
	}
	if triangle_count > 0 {
		flush(positions, local[:local_count], triangles[:triangle_count], meshlets, meshlet_vertices, meshlet_triangles)
		made += 1
	}
	return made
}
