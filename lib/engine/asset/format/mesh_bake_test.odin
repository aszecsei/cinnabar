package asset_format

import "core:math"
import "core:math/linalg"
import "core:testing"

// BOX_VERTICES and BOX_CORNERS are a 1 m box on the origin's corner, each face clockwise from its front.
@(private = "file")
BOX_VERTICES := [][3]f32 {
	{0, 0, 0},
	{1, 0, 0},
	{1, 0, 1},
	{0, 0, 1},
	{0, 1, 0},
	{1, 1, 0},
	{1, 1, 1},
	{0, 1, 1},
}
@(private = "file")
BOX_CORNERS := [][]u32 {
	{0, 1, 2, 3},
	{4, 7, 6, 5},
	{0, 4, 5, 1},
	{2, 6, 7, 3},
	{3, 7, 4, 0},
	{1, 5, 6, 2},
}

// box_source is the box with a world-aligned mapping on each face, in the slots given, with the sharp edges given.
@(private = "file")
box_source :: proc(sharp: []Mesh_Edge, slots: [6]u32 = {}) -> Mesh_Source {
	faces := make([]Mesh_Face, 6, context.temp_allocator)
	for c, i in BOX_CORNERS {
		faces[i] = {
			slot    = slots[i],
			corners = c,
			mapping = mesh_world_mapping(mesh_face_normal(BOX_VERTICES, c), 1),
			line    = i + 1,
		}
	}
	return {vertices = BOX_VERTICES, faces = faces, sharp = sharp}
}

@(private = "file")
ALL_BOX_EDGES := []Mesh_Edge {
	{0, 1},
	{1, 2},
	{2, 3},
	{3, 0},
	{4, 5},
	{5, 6},
	{6, 7},
	{7, 4},
	{0, 4},
	{1, 5},
	{2, 6},
	{3, 7},
}

@(private = "file")
near :: proc(a, b: [3]f32) -> bool {
	return linalg.length(a - b) < 1e-5
}

@(test)
sharp_edges_split_vertices_and_smooth_ones_do_not :: proc(t: ^testing.T) {
	// With every edge sharp, each corner's normal is its face's, and each face has its own four vertices.
	sharp := mesh_bake(box_source(ALL_BOX_EDGES), context.temp_allocator)
	testing.expectf(t, len(sharp.problems) == 0, "problems: %v", sharp.problems)
	testing.expect_value(t, len(sharp.vertices), 24)
	testing.expect_value(t, len(sharp.indices), 36)
	testing.expect_value(t, len(sharp.triangle_faces), 12)
	testing.expect_value(t, len(sharp.edges), 12)
	testing.expect_value(t, len(sharp.submeshes), 1)
	testing.expect_value(t, sharp.submeshes[0].index_count, 36)
	for i in 0 ..< 12 {
		face := sharp.triangle_faces[i]
		testing.expect_value(t, face, u32(i / 2))
		corners := sharp.indices[i * 3:][:3]
		a, b, c :=
			sharp.vertices[corners[0]], sharp.vertices[corners[1]], sharp.vertices[corners[2]]
		// Each triangle winds the same way as its face, so its geometric normal is the face's, and so is each
		// corner's.
		expected := linalg.normalize(
			linalg.cross(b.position - a.position, c.position - a.position),
		)
		testing.expectf(
			t,
			near(a.normal, expected) && near(b.normal, expected) && near(c.normal, expected),
			"triangle %d of face %d has normals %v, %v, %v, not %v",
			i,
			face,
			a.normal,
			b.normal,
			c.normal,
			expected,
		)
	}

	// With no edge sharp, the normals average the three faces at each corner, which point along the diagonals. The
	// UVs still differ between faces, so the vertices stay split.
	smooth := mesh_bake(box_source(nil), context.temp_allocator)
	testing.expect_value(t, len(smooth.vertices), 24)
	for v in smooth.vertices {
		expected := linalg.normalize(v.position * 2 - 1)
		testing.expectf(
			t,
			near(v.normal, expected),
			"%v has the normal %v, not %v",
			v.position,
			v.normal,
			expected,
		)
	}

	// With the top's four edges sharp, the top keeps its own normal and the sides smooth across the bottom only.
	top := mesh_bake(box_source({{4, 5}, {5, 6}, {6, 7}, {7, 4}}), context.temp_allocator)
	for v in top.vertices {
		if v.position.y == 1 && near(v.normal, {0, 1, 0}) {
			continue
		}
		side := v.position * 2 - 1
		side.y = v.position.y == 1 ? 0 : -1
		testing.expectf(
			t,
			near(v.normal, linalg.normalize(side)),
			"%v has the normal %v",
			v.position,
			v.normal,
		)
	}
}

@(test)
corners_weld_where_their_attributes_agree :: proc(t: ^testing.T) {
	// Two triangles of one quad, in one plane with one mapping, share their two vertices.
	vertices := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	mapping := Mesh_Mapping {
		u_axis = {1, 0, 0},
		v_axis = {0, -1, 0},
		scale  = {1, 1},
	}
	mesh := Mesh_Source {
		vertices = vertices,
		faces    = {
			{corners = {0, 3, 2}, mapping = mapping},
			{corners = {0, 2, 1}, mapping = mapping},
		},
	}
	bake := mesh_bake(mesh, context.temp_allocator)
	testing.expect_value(t, len(bake.vertices), 4)
	testing.expect_value(t, len(bake.indices), 6)
	testing.expect_value(t, len(bake.edges), 5)
}

@(test)
uvs_and_tangents_follow_the_mapping :: proc(t: ^testing.T) {
	m := Mesh_Mapping {
		u_axis = {1, 0, 0},
		v_axis = {0, 0, -1},
		scale  = {2, 4},
		shift  = {0.25, -0.5},
	}
	// u = x / 2 + 0.25, v = -z / 4 - 0.5.
	testing.expect_value(t, mapping_uv(m, {1, 7, -1}), [2]f32{0.75, -0.25})
	// The rotation turns the texture about the mapping's origin: at 90°, u becomes v.
	m.rotation = 90
	uv := mapping_uv(m, {1, 0, -1})
	testing.expect(t, abs(uv.x - (-0.25 + 0.25)) < 1e-6 && abs(uv.y - (0.5 - 0.5)) < 1e-6)
	m.rotation = 0

	// The tangent is the u axis projected onto the face's plane, and the bitangent's sign says which way v goes.
	normal := [3]f32{0, 1, 0}
	tangent, bitangent := mapping_frame(m, normal)
	testing.expect(t, near(tangent, {1, 0, 0}))
	testing.expect(t, near(bitangent, {0, 0, -1}))
	tilted := linalg.normalize([3]f32{1, 1, 0})
	tangent, _ = mapping_frame(m, tilted)
	testing.expect(t, near(tangent, linalg.normalize([3]f32{1, -1, 0})))
	// A u axis along the normal has no tangent in the plane.
	tangent, _ = mapping_frame(m, {1, 0, 0})
	testing.expect_value(t, tangent, [3]f32{})

	// In a bake, the floor's v grows along -z, but cross(normal, tangent) is (0, 0, 1) for its normal of -y: sign -1.
	// The ceiling, with the same axes, has cross(normal, tangent) along -z: sign +1.
	bake := mesh_bake(box_source(ALL_BOX_EDGES), context.temp_allocator)
	for v in bake.vertices {
		switch {
		case near(v.normal, {0, -1, 0}):
			testing.expect(t, near(v.tangent.xyz, {1, 0, 0}) && v.tangent.w == -1)
			testing.expect_value(t, v.uv, [2]f32{v.position.x, -v.position.z})
		case near(v.normal, {0, 1, 0}):
			testing.expect(t, near(v.tangent.xyz, {1, 0, 0}) && v.tangent.w == 1)
		case near(v.normal, {1, 0, 0}):
			testing.expect(t, near(v.tangent.xyz, {0, 0, 1}))
			testing.expect_value(t, v.uv, [2]f32{v.position.z, -v.position.y})
		}
	}
}

@(test)
concave_faces_ear_clip_and_crossing_ones_are_refused :: proc(t: ^testing.T) {
	// An L shape in the xz plane, seen from above, clockwise.
	l := [][3]f32{{0, 0, 0}, {0, 0, 2}, {1, 0, 2}, {1, 0, 1}, {2, 0, 1}, {2, 0, 0}}
	mesh := Mesh_Source {
		vertices = l,
		faces    = {
			{corners = {0, 1, 2, 3, 4, 5}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 3},
		},
	}
	bake := mesh_bake(mesh, context.temp_allocator)
	testing.expect_value(t, len(bake.problems), 0)
	testing.expect_value(t, len(bake.indices), 4 * 3)
	testing.expect_value(t, len(bake.vertices), 6)
	testing.expect_value(t, len(bake.edges), 6)
	// Every triangle winds with the face, and their areas sum to the L's: 3 m².
	area: f32
	for i in 0 ..< 4 {
		c := bake.indices[i * 3:][:3]
		a, b, d :=
			bake.vertices[c[0]].position,
			bake.vertices[c[1]].position,
			bake.vertices[c[2]].position
		n := linalg.cross(b - a, d - a)
		testing.expect(t, n.y > 0)
		area += linalg.length(n) / 2
	}
	testing.expect(t, abs(area - 3) < 1e-5)
	testing.expect_value(t, bake.bounds.min, [3]f32{0, 0, 0})
	testing.expect_value(t, bake.bounds.max, [3]f32{2, 0, 2})
	testing.expect_value(t, bake.bounds.center, [3]f32{1, 0, 1})
	testing.expect(t, abs(bake.bounds.radius - math.sqrt_f32(2)) < 1e-5)

	// A bowtie's halves cancel, so it has no area, nor does a collinear face; a face of two distinct vertices is too
	// few, and one may not use a vertex the mesh lacks: each is left out with its line, and the rest bakes.
	bad := Mesh_Source {
		vertices = {{0, 0, 0}, {1, 0, 1}, {1, 0, 0}, {0, 0, 1}, {2, 0, 2}, {3, 0, 3}},
		faces    = {
			{corners = {0, 1, 2, 3}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 10},
			{corners = {0, 4, 5}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 11},
			{corners = {0, 1, 0, 1}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 12},
			{corners = {0, 1, 9}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 13},
			{corners = {0, 3, 1}, mapping = mesh_world_mapping({0, 1, 0}, 1), line = 14},
		},
	}
	bake = mesh_bake(bad, context.temp_allocator)
	testing.expect_value(t, len(bake.problems), 4)
	for p, i in bake.problems {
		testing.expect(t, !p.error)
		testing.expectf(t, p.line == 10 + i, "problem %d is at line %d: %s", i, p.line, p.message)
	}
	testing.expect_value(t, len(bake.indices), 3)
	testing.expect_value(t, len(bake.triangle_faces), 1)
	testing.expect_value(t, bake.triangle_faces[0], 4)
}

@(test)
submeshes_are_slots_in_order :: proc(t: ^testing.T) {
	// The top in slot 2 and the rest in slot 0: three submeshes, with slot 1 empty.
	bake := mesh_bake(box_source(nil, {0, 2, 0, 0, 0, 0}), context.temp_allocator)
	testing.expect_value(t, len(bake.submeshes), 3)
	testing.expect_value(t, bake.submeshes[0].first_index, 0)
	testing.expect_value(t, bake.submeshes[0].index_count, 30)
	testing.expect_value(t, bake.submeshes[1].index_count, 0)
	testing.expect_value(t, bake.submeshes[1].bounds, Mesh_Bounds{})
	testing.expect_value(t, bake.submeshes[2].first_index, 30)
	testing.expect_value(t, bake.submeshes[2].index_count, 6)
	testing.expect_value(t, bake.submeshes[2].bounds.min, [3]f32{0, 1, 0})
	testing.expect_value(t, bake.submeshes[2].bounds.max, [3]f32{1, 1, 1})
	for i in bake.indices[30:] {
		testing.expect_value(t, bake.vertices[i].position.y, 1)
	}
	for face in bake.triangle_faces[10:] {
		testing.expect_value(t, face, 1)
	}
	testing.expect_value(t, bake.bounds.max, [3]f32{1, 1, 1})
	testing.expect(t, abs(bake.bounds.radius - math.sqrt_f32(3) / 2) < 1e-5)
}
