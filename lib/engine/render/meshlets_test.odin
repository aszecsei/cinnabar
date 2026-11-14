package render

import "core:math"
import "core:math/linalg"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(test)
simple_meshlets_cover_every_triangle_once_within_the_limits :: proc(t: ^testing.T) {
	// A bumpy grid of 40 by 40 quads: 1681 vertices and 3200 triangles, more than one meshlet by both limits.
	size := 40
	positions := make([dynamic][3]f32, context.temp_allocator)
	for y in 0 ..= size {
		for x in 0 ..< size + 1 {
			fx, fy := f32(x) / f32(size), f32(y) / f32(size)
			append(&positions, [3]f32{fx, fy, 0.05 * math.sin(fx * 7) * math.cos(fy * 5)})
		}
	}
	indices := make([dynamic]u32, context.temp_allocator)
	row := u32(size + 1)
	for y in 0 ..< u32(size) {
		for x in 0 ..< u32(size) {
			i := y * row + x
			append(&indices, i, i + 1, i + row + 1, i, i + row + 1, i + row)
		}
	}
	meshlets := make([dynamic]format.Meshlet, context.temp_allocator)
	vertices := make([dynamic]u32, context.temp_allocator)
	triangles := make([dynamic]u8, context.temp_allocator)
	made := build_simple_meshlets(positions[:], indices[:], &meshlets, &vertices, &triangles)
	testing.expect_value(t, made, len(meshlets))
	testing.expect(t, made > 1)

	total := 0
	for m, i in meshlets {
		testing.expectf(t, m.vertex_count <= format.MESHLET_MAX_VERTICES && m.triangle_count <= format.MESHLET_MAX_TRIANGLES, "meshlet %d has %d vertices and %d triangles", i, m.vertex_count, m.triangle_count)
		testing.expect(t, m.depth == 0 && m.error == 0 && m.parent_error == math.F32_MAX)
		for triangle in 0 ..< int(m.triangle_count) {
			// Each triangle is the next of the submesh's, in order, and its corners are in the meshlet's vertices.
			corners := format.meshlet_triangle(m, triangles[:], triangle)
			for c, k in corners {
				testing.expect(t, c < u32(m.vertex_count))
				testing.expect_value(t, format.meshlet_vertex(m, vertices[:], int(c)), indices[total * 3 + k])
			}
			// The sphere holds the triangle.
			center, radius := format.meshlet_sphere(m)
			for c in corners {
				p := positions[format.meshlet_vertex(m, vertices[:], int(c))]
				testing.expect(t, linalg.length(p - center) <= radius)
			}
			total += 1
		}
	}
	testing.expect_value(t, total, len(indices) / 3)

	// The grid faces +z, so its cones are narrow enough to cull from behind.
	for m in meshlets {
		testing.expect(t, m.cone_cutoff < 127)
		testing.expect(t, m.cone_axis.z > 100)
	}
}

@(test)
simple_meshlets_cones_are_conservative :: proc(t: ^testing.T) {
	// A box's six faces in one meshlet point every way: no cone can cull it.
	positions := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}, {0, 1, 0}, {1, 1, 0}, {1, 1, 1}, {0, 1, 1}}
	quads := [][4]u32{{0, 1, 2, 3}, {4, 7, 6, 5}, {0, 4, 5, 1}, {2, 6, 7, 3}, {3, 7, 4, 0}, {1, 5, 6, 2}}
	indices := make([dynamic]u32, context.temp_allocator)
	for q in quads {
		append(&indices, q[0], q[1], q[2], q[0], q[2], q[3])
	}
	meshlets := make([dynamic]format.Meshlet, context.temp_allocator)
	vertices := make([dynamic]u32, context.temp_allocator)
	triangles := make([dynamic]u8, context.temp_allocator)
	testing.expect_value(t, build_simple_meshlets(positions, indices[:], &meshlets, &vertices, &triangles), 1)
	testing.expect_value(t, meshlets[0].cone_cutoff, 127)
	testing.expect_value(t, meshlets[0].vertex_count, 8)
	testing.expect_value(t, meshlets[0].triangle_count, 12)
	center, _ := format.meshlet_sphere(meshlets[0])
	testing.expect_value(t, center, [3]f32{0.5, 0.5, 0.5})

	// One face's two triangles: the cone is its normal, with no spread, so the cutoff is the smallest step.
	clear(&meshlets)
	clear(&vertices)
	clear(&triangles)
	testing.expect_value(t, build_simple_meshlets(positions, indices[:6], &meshlets, &vertices, &triangles), 1)
	testing.expect_value(t, meshlets[0].cone_axis, [3]i8{0, -127, 0})
	testing.expect_value(t, meshlets[0].cone_cutoff, 1)
	testing.expect_value(t, meshlets[0].vertex_count, 4)

	// Nothing makes nothing.
	testing.expect_value(t, build_simple_meshlets(positions, nil, &meshlets, &vertices, &triangles), 0)
}

// A meshlet's vertices are refs from its lowest, 16 bits when they all fit, whichever vertices the mesh gives it.
@(test)
simple_meshlets_narrow_their_refs_when_they_fit :: proc(t: ^testing.T) {
	positions := make([][3]f32, 70000, context.temp_allocator)
	for &p, i in positions {
		p = {f32(i % 100), f32(i / 100), 0}
	}
	build :: proc(positions: [][3]f32, indices: []u32) -> (m: format.Meshlet, stream: [dynamic]u32) {
		meshlets := make([dynamic]format.Meshlet, context.temp_allocator)
		triangles := make([dynamic]u8, context.temp_allocator)
		stream = make([dynamic]u32, context.temp_allocator)
		build_simple_meshlets(positions, indices, &meshlets, &stream, &triangles)
		return meshlets[0], stream
	}
	near := []u32{69000, 69001, 69002}
	m, stream := build(positions, near)
	testing.expect_value(t, m.short_refs, 1)
	testing.expect_value(t, m.base_vertex, 69000)
	testing.expect_value(t, len(stream), 2)
	for v, i in near {
		testing.expect_value(t, format.meshlet_vertex(m, stream[:], i), v)
	}
	far := []u32{69999, 3, 40}
	m, stream = build(positions, far)
	testing.expect_value(t, m.short_refs, 0)
	testing.expect_value(t, m.base_vertex, 3)
	testing.expect_value(t, len(stream), 3)
	for v, i in far {
		testing.expect_value(t, format.meshlet_vertex(m, stream[:], i), v)
	}
}
