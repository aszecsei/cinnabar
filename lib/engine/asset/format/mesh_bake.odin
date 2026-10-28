package asset_format

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"

// A bake turns a Mesh_Source into the vertices and the triangles that a Mesh blob holds (see
// docs/content/kinds/meshes.md#mesh-files). It is written once, here, so the cooker and the game produce the same
// vertices: the cooker continues with meshoptimizer, and the game with its own meshlets. Faces are planar polygons,
// clockwise seen from their front, so a face's normal is the cross product of its first edges' way round.

// Mesh_Bake_Vertex is a baked vertex: every attribute of the blob's two streams, in f32.
Mesh_Bake_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	// xyz, and the bitangent's sign in w.
	tangent:  [4]f32,
	uv:       [2]f32,
}

// Mesh_Bake_Submesh is the triangles of one material slot: a range of the bake's indices. There is one for each slot
// up to the highest that a face uses, so a submesh's index is its slot, and a slot that no face uses is empty.
Mesh_Bake_Submesh :: struct {
	first_index: u32,
	index_count: u32,
	bounds:      Mesh_Bounds,
}

Mesh_Bake :: struct {
	vertices:       []Mesh_Bake_Vertex,
	// Three per triangle, front faces clockwise, grouped by submesh.
	indices:        []u32,
	// The face of each triangle, by its index in the source.
	triangle_faces: []u32,
	submeshes:      []Mesh_Bake_Submesh,
	// Each polygon edge once, as a pair of baked vertex indices, for an overlay that draws the faces' outlines rather
	// than the triangles' diagonals.
	edges:          [][2]u32,
	bounds:         Mesh_Bounds,
	// The faces that the bake left out, each a warning at the face's line.
	problems:       []Mesh_Problem,
}

// mesh_bake bakes a mesh into allocator. A face with fewer than three distinct vertices, without area, or that cannot
// be triangulated is left out with a problem at its line, and the rest bakes.
mesh_bake :: proc(mesh: Mesh_Source, allocator := context.allocator) -> (bake: Mesh_Bake) {
	problems := make([dynamic]Mesh_Problem, allocator)
	faces := mesh.faces
	normals := make([][3]f32, len(faces), context.temp_allocator)
	valid := make([]bool, len(faces), context.temp_allocator)
	highest := -1
	for f, i in faces {
		if int(f.slot) >= MESH_MAX_SLOTS {
			refuse(
				&problems,
				f,
				allocator,
				"uses material slot %d, and a mesh has %d",
				f.slot,
				MESH_MAX_SLOTS,
			)
			continue
		}
		unique := 0
		out_of_range := false
		for c, k in f.corners {
			if int(c) >= len(mesh.vertices) {
				out_of_range = true
				break
			}
			if !slice.contains(f.corners[:k], c) {
				unique += 1
			}
		}
		if out_of_range {
			refuse(&problems, f, allocator, "uses a vertex the mesh does not have")
			continue
		}
		if unique < 3 {
			refuse(&problems, f, allocator, "has fewer than three distinct vertices")
			continue
		}
		normals[i] = mesh_face_normal(mesh.vertices, f.corners)
		if normals[i] == {} {
			refuse(&problems, f, allocator, "has no area")
			continue
		}
		if f.mapping.scale.x == 0 || f.mapping.scale.y == 0 {
			refuse(&problems, f, allocator, "has a mapping whose scale is 0")
			continue
		}
		valid[i] = true
		highest = max(highest, int(f.slot))
	}

	// The corner normals: a vertex's normal in a face is the angle-weighted average of the faces around it that the
	// vertex reaches without crossing a sharp edge.
	corner_normals := make([][][3]f32, len(faces), context.temp_allocator)
	smooth_normals(mesh, normals, valid, corner_normals)

	// Each face's corners become baked vertices, welded where a position's corners agree in every attribute, as a
	// glTF cook's weld leaves them.
	welded := make(map[Mesh_Bake_Vertex]u32, context.temp_allocator)
	vertices := make([dynamic]Mesh_Bake_Vertex, allocator)
	corner_vertices := make([][]u32, len(faces), context.temp_allocator)
	for f, i in faces {
		if !valid[i] {
			continue
		}
		n := normals[i]
		tangent, bitangent := mapping_frame(f.mapping, n)
		if tangent == {} {
			// The u axis runs along the normal, so the texture is a line on the face: any tangent does.
			tangent = any_perpendicular(n)
			bitangent = linalg.cross(n, tangent)
			appendf(
				&problems,
				allocator,
				f.line,
				"has a mapping whose u axis runs along the face's normal, so its tangent is arbitrary",
			)
		}
		sign: f32 = linalg.dot(linalg.cross(n, tangent), bitangent) >= 0 ? 1 : -1
		corner_vertices[i] = make([]u32, len(f.corners), context.temp_allocator)
		for c, k in f.corners {
			v := Mesh_Bake_Vertex {
				position = mesh.vertices[c],
				normal   = corner_normals[i][k],
				tangent  = {tangent.x, tangent.y, tangent.z, sign},
				uv       = mapping_uv(f.mapping, mesh.vertices[c]),
			}
			index, found := welded[v]
			if !found {
				index = u32(len(vertices))
				welded[v] = index
				append(&vertices, v)
			}
			corner_vertices[i][k] = index
		}
	}

	// The triangles, grouped by slot in slot order.
	indices := make([dynamic]u32, allocator)
	triangle_faces := make([dynamic]u32, allocator)
	submeshes := make([]Mesh_Bake_Submesh, highest + 1, allocator)
	for slot in 0 ..= highest {
		first := len(indices)
		for f, i in faces {
			if !valid[i] || int(f.slot) != slot {
				continue
			}
			local := triangulate(mesh.vertices, f.corners, normals[i])
			if local == nil {
				refuse(&problems, f, allocator, "cannot be triangulated: it crosses itself")
				valid[i] = false
				continue
			}
			for k in local {
				append(&indices, corner_vertices[i][k])
			}
			for _ in 0 ..< len(local) / 3 {
				append(&triangle_faces, u32(i))
			}
		}
		submeshes[slot] = {
			first_index = u32(first),
			index_count = u32(len(indices) - first),
			bounds      = bounds_of(vertices[:], indices[first:]),
		}
	}

	// The polygon edges, each once, by the source vertices they join.
	seen := make(map[[2]u32]bool, context.temp_allocator)
	edges := make([dynamic][2]u32, allocator)
	for f, i in faces {
		if !valid[i] {
			continue
		}
		for c, k in f.corners {
			next := (k + 1) % len(f.corners)
			key := [2]u32{min(c, f.corners[next]), max(c, f.corners[next])}
			if key[0] == key[1] || seen[key] {
				continue
			}
			seen[key] = true
			append(&edges, [2]u32{corner_vertices[i][k], corner_vertices[i][next]})
		}
	}

	return {
		vertices = vertices[:],
		indices = indices[:],
		triangle_faces = triangle_faces[:],
		submeshes = submeshes,
		edges = edges[:],
		bounds = bounds_of(vertices[:], nil),
		problems = problems[:],
	}
}

@(private = "file")
refuse :: proc(
	problems: ^[dynamic]Mesh_Problem,
	f: Mesh_Face,
	allocator: mem.Allocator,
	format: string,
	args: ..any,
) {
	message := fmt.tprintf(format, ..args)
	appendf(problems, allocator, f.line, "the face %s, and is left out", message)
}

@(private = "file")
appendf :: proc(
	problems: ^[dynamic]Mesh_Problem,
	allocator: mem.Allocator,
	line: int,
	format: string,
	args: ..any,
) {
	append(
		problems,
		Mesh_Problem {
			line = line,
			message = fmt.aprintf(format, ..args, allocator = allocator),
			error = false,
		},
	)
}

// smooth_normals fills each valid face's corner normals. The faces around a vertex are joined where they share an edge
// at it that is not sharp, and a corner's normal averages its group's face normals, weighted by the face's angle at
// the vertex, so a long thin face does not pull the normal as much as a wide one.
@(private = "file")
smooth_normals :: proc(
	mesh: Mesh_Source,
	normals: [][3]f32,
	valid: []bool,
	corner_normals: [][][3]f32,
) {
	sharp := make(map[[2]u32]bool, len(mesh.sharp), context.temp_allocator)
	for e in mesh.sharp {
		sharp[{min(e.a, e.b), max(e.a, e.b)}] = true
	}
	Corner :: struct {
		face, corner: int,
	}
	// The corners at each vertex, and the corners at each edge of each vertex, by the edge's other vertex.
	around := make(map[u32][dynamic]Corner, context.temp_allocator)
	for f, i in mesh.faces {
		if !valid[i] {
			continue
		}
		corner_normals[i] = make([][3]f32, len(f.corners), context.temp_allocator)
		for c, k in f.corners {
			if c not_in around {
				around[c] = make([dynamic]Corner, context.temp_allocator)
			}
			append(&around[c], Corner{i, k})
		}
	}
	for vertex, corners in around {
		// Union-find over the corners at the vertex: two join when their faces share an edge at it.
		parent := make([]int, len(corners), context.temp_allocator)
		for &p, i in parent {
			p = i
		}
		find :: proc(parent: []int, i: int) -> int {
			i := i
			for parent[i] != i {
				parent[i] = parent[parent[i]]
				i = parent[i]
			}
			return i
		}
		by_neighbor := make(map[u32]int, context.temp_allocator)
		for c, i in corners {
			f := mesh.faces[c.face]
			n := len(f.corners)
			for other in ([2]u32{f.corners[(c.corner + n - 1) % n], f.corners[(c.corner + 1) % n]}) {
				if other == vertex || sharp[{min(vertex, other), max(vertex, other)}] {
					continue
				}
				if j, found := by_neighbor[other]; found {
					parent[find(parent, i)] = find(parent, j)
				} else {
					by_neighbor[other] = i
				}
			}
		}
		sums := make(map[int][3]f32, context.temp_allocator)
		for c, i in corners {
			f := mesh.faces[c.face]
			n := len(f.corners)
			p := mesh.vertices[vertex]
			a := mesh.vertices[f.corners[(c.corner + n - 1) % n]] - p
			b := mesh.vertices[f.corners[(c.corner + 1) % n]] - p
			angle := linalg.angle_between(a, b)
			if math.is_nan(angle) {
				angle = 0
			}
			root := find(parent, i)
			sums[root] = sums[root] + normals[c.face] * angle
		}
		for c, i in corners {
			n := linalg.normalize0(sums[find(parent, i)])
			if n == {} {
				n = normals[c.face]
			}
			corner_normals[c.face][c.corner] = n
		}
	}
}

// mapping_uv is a position's UV from a mapping: the position along each axis in repeats, turned by the rotation about
// the mapping's origin, then shifted.
mapping_uv :: proc "contextless" (m: Mesh_Mapping, p: [3]f32) -> [2]f32 {
	a := linalg.dot(p, m.u_axis) / m.scale.x
	b := linalg.dot(p, m.v_axis) / m.scale.y
	s, c := math.sincos(math.to_radians(m.rotation))
	return {a * c - b * s + m.shift.x, a * s + b * c + m.shift.y}
}

// mapping_frame is the direction along the face in which u grows, and the one in which v grows, both projected onto
// the face's plane: the tangent, exact for a planar mapping, and the bitangent's direction. The tangent is zero when
// u grows only along the normal.
mapping_frame :: proc "contextless" (
	m: Mesh_Mapping,
	normal: [3]f32,
) -> (
	tangent, bitangent: [3]f32,
) {
	s, c := math.sincos(math.to_radians(m.rotation))
	du := m.u_axis / m.scale.x * c - m.v_axis / m.scale.y * s
	dv := m.u_axis / m.scale.x * s + m.v_axis / m.scale.y * c
	tangent = linalg.normalize0(du - normal * linalg.dot(du, normal))
	bitangent = linalg.normalize0(dv - normal * linalg.dot(dv, normal))
	return
}

@(private = "file")
any_perpendicular :: proc "contextless" (n: [3]f32) -> [3]f32 {
	axis := [3]f32{1, 0, 0}
	if abs(n.x) > abs(n.y) && abs(n.x) > abs(n.z) {
		axis = {0, 1, 0}
	}
	return linalg.normalize0(linalg.cross(n, axis))
}

// triangulate splits a face into triangles, as indices into its corners, in the face's winding: a fan for a convex
// face, and ear clipping in the face's plane for a concave one. It returns nil for a face that crosses itself.
@(private = "file")
triangulate :: proc(vertices: [][3]f32, corners: []u32, normal: [3]f32) -> []int {
	n := len(corners)
	e1 := any_perpendicular(normal)
	e2 := linalg.cross(normal, e1)
	points := make([][2]f32, n, context.temp_allocator)
	for c, i in corners {
		points[i] = {linalg.dot(vertices[c], e1), linalg.dot(vertices[c], e2)}
	}
	// The polygon's turn in the plane: positive one way round, whichever the basis made it.
	area: f32
	for p, i in points {
		q := points[(i + 1) % n]
		area += p.x * q.y - q.x * p.y
	}
	turn: f32 = area >= 0 ? 1 : -1
	cross2 :: proc "contextless" (a, b, c: [2]f32) -> f32 {
		return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	}
	result := make([dynamic]int, 0, (n - 2) * 3, context.temp_allocator)
	convex := true
	for i in 0 ..< n {
		convex &&= cross2(points[(i + n - 1) % n], points[i], points[(i + 1) % n]) * turn >= 0
	}
	if convex {
		for i in 1 ..< n - 1 {
			append(&result, 0, i, i + 1)
		}
		return result[:]
	}
	remaining := make([dynamic]int, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		append(&remaining, i)
	}
	for len(remaining) > 3 {
		found := false
		for i in 0 ..< len(remaining) {
			prev, cur, next :=
				remaining[(i + len(remaining) - 1) % len(remaining)],
				remaining[i],
				remaining[(i + 1) % len(remaining)]
			a, b, c := points[prev], points[cur], points[next]
			if cross2(a, b, c) * turn <= 0 {
				continue
			}
			inside := false
			for other in remaining {
				if other == prev || other == cur || other == next {
					continue
				}
				p := points[other]
				if p == a || p == b || p == c {
					continue
				}
				if cross2(a, b, p) * turn >= 0 &&
				   cross2(b, c, p) * turn >= 0 &&
				   cross2(c, a, p) * turn >= 0 {
					inside = true
					break
				}
			}
			if inside {
				continue
			}
			append(&result, prev, cur, next)
			ordered_remove(&remaining, i)
			found = true
			break
		}
		if !found {
			return nil
		}
	}
	append(&result, remaining[0], remaining[1], remaining[2])
	return result[:]
}

// bounds_of is the box around the vertices that the indices use, or around every vertex without them, and the
// sphere at the box's center that holds them.
@(private = "file")
bounds_of :: proc(vertices: []Mesh_Bake_Vertex, indices: []u32) -> (b: Mesh_Bounds) {
	if len(vertices) == 0 || (indices != nil && len(indices) == 0) {
		return {}
	}
	b.min, b.max = math.F32_MAX, -math.F32_MAX
	each :: proc(
		vertices: []Mesh_Bake_Vertex,
		indices: []u32,
		b: ^Mesh_Bounds,
		visit: proc(b: ^Mesh_Bounds, p: [3]f32),
	) {
		if indices == nil {
			for v in vertices {
				visit(b, v.position)
			}
		} else {
			for i in indices {
				visit(b, vertices[i].position)
			}
		}
	}
	each(vertices, indices, &b, proc(b: ^Mesh_Bounds, p: [3]f32) {
		b.min = linalg.min(b.min, p)
		b.max = linalg.max(b.max, p)
	})
	b.center = (b.min + b.max) / 2
	each(vertices, indices, &b, proc(b: ^Mesh_Bounds, p: [3]f32) {
		b.radius = max(b.radius, linalg.length(p - b.center))
	})
	return
}
