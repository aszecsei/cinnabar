// Impostors: a mesh seen from IMPOSTOR_FRAMES² directions spread over the sphere, each view an orthographic frame of
// what a material needs at the nearest surface there, so that the impostor path draws one quad with the mesh's own
// materials past its coarsest level of detail (see docs/content/kinds/meshes.md#impostors).
package cook

import "core:c"
import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"

// impostor_direction is the direction toward the viewer of a frame of the atlas: its grid point unfolded from the
// octahedron, so the corners and the edges of the grid are views too, and a view between them blends its three
// nearest. Matches impostor_direction in material_impostor.hlsli.
impostor_direction :: proc(x, y: int) -> [3]f32 {
	p := [2]f32{f32(x), f32(y)} / f32(format.IMPOSTOR_FRAMES - 1) * 2 - 1
	n := [3]f32{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if n.z < 0 {
		n.xy = (1 - [2]f32{abs(n.y), abs(n.x)}) * [2]f32{n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1}
	}
	return linalg.normalize(n)
}

// impostor_basis is a frame's right and up, for the direction toward its viewer, who looks along -direction. Matches
// impostor_basis in material_impostor.hlsli.
impostor_basis :: proc(direction: [3]f32) -> (right, up: [3]f32) {
	forward := -direction
	reference := abs(direction.y) > 0.999 ? [3]f32{0, 0, 1} : [3]f32{0, 1, 0}
	right = linalg.normalize(linalg.cross(reference, forward))
	up = linalg.cross(forward, right)
	return
}

// bake_impostor rasterizes each frame of a mesh's impostor, in its bounding sphere: each texel is the surface nearest
// the frame's viewer at its middle, with its first UV set, its depth, its submesh, and its normal and tangent in the
// mesh's space. A face seen from behind gives its normal flipped, as a two-sided material shades it. size is a
// frame's side in texels.
bake_impostor :: proc(vertices: []Vertex, indices: []c.uint, submeshes: []format.Submesh_Entry, sphere: format.Mesh_Bounds, size: int, allocator := context.allocator) -> []format.Impostor_Texel {
	frames := format.IMPOSTOR_FRAMES
	texels := make([]format.Impostor_Texel, frames * frames * size * size, allocator)
	depths := make([]f32, size * size, context.temp_allocator)
	radius := max(sphere.radius, 1e-6)
	screen := make([][3]f32, len(vertices), context.temp_allocator)
	for fy in 0 ..< frames {
		for fx in 0 ..< frames {
			direction := impostor_direction(fx, fy)
			right, up := impostor_basis(direction)
			// x and y in texels, from the frame's top left, and the depth toward the viewer.
			for v, i in vertices {
				p := (v.position - sphere.center) / radius
				screen[i] = {(linalg.dot(p, right) * 0.5 + 0.5) * f32(size), (0.5 - linalg.dot(p, up) * 0.5) * f32(size), linalg.dot(p, direction)}
			}
			frame := texels[(fy * frames + fx) * size * size:][:size * size]
			for &d in depths {
				d = math.F32_MIN
			}
			for s, owner in submeshes {
				for t := s.first_index; t + 2 < s.first_index + s.index_count; t += 3 {
					corners := [3]u32{u32(indices[t]), u32(indices[t + 1]), u32(indices[t + 2])}
					raster_triangle(frame, depths, size, screen, vertices, corners, owner)
				}
			}
		}
	}
	return texels
}

// raster_triangle writes a triangle's texels that are nearer than the frame's own, at the middles of the texels that
// it covers. Front faces are clockwise on the frame, whose y points down.
@(private = "file")
raster_triangle :: proc(frame: []format.Impostor_Texel, depths: []f32, size: int, screen: [][3]f32, vertices: []Vertex, corners: [3]u32, owner: int) {
	a, b, c := screen[corners[0]], screen[corners[1]], screen[corners[2]]
	area := (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
	if abs(area) < 1e-12 {
		return
	}
	x0 := max(int(math.floor(min(a.x, b.x, c.x))), 0)
	x1 := min(int(math.ceil(max(a.x, b.x, c.x))), size - 1)
	y0 := max(int(math.floor(min(a.y, b.y, c.y))), 0)
	y1 := min(int(math.ceil(max(a.y, b.y, c.y))), size - 1)
	va, vb, vc := vertices[corners[0]], vertices[corners[1]], vertices[corners[2]]
	back := area < 0
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			// Each corner's weight is the share of the area that the opposite edge and the point make.
			wa := ((b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y)) / area
			wb := ((c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y)) / area
			wc := 1 - wa - wb
			if wa < 0 || wb < 0 || wc < 0 {
				continue
			}
			depth := wa * a.z + wb * b.z + wc * c.z
			i := y * size + x
			if depth <= depths[i] {
				continue
			}
			depths[i] = depth
			normal := linalg.normalize0(wa * va.normal + wb * vb.normal + wc * vc.normal)
			tangent := linalg.normalize0(wa * va.tangent.xyz + wb * vb.tangent.xyz + wc * vc.tangent.xyz)
			if back {
				normal = -normal
			}
			uv := wa * va.uv0 + wb * vb.uv0 + wc * vc.uv0
			flags := u16(min(owner, 254) + 1)
			if va.tangent.w < 0 {
				flags |= format.IMPOSTOR_TEXEL_FLIP
			}
			frame[i] = {
				uv      = {f16le(uv.x), f16le(uv.y)},
				depth   = f16le(depth),
				flags   = u16le(flags),
				normal  = snorm16_pair(format.mesh_octahedral(normal)),
				tangent = snorm16_pair(format.mesh_octahedral(tangent)),
			}
		}
	}
}

@(private = "file")
snorm16_pair :: proc(p: [2]f32) -> [2]i16le {
	return {i16le(math.round(clamp(p.x, -1, 1) * 32767)), i16le(math.round(clamp(p.y, -1, 1) * 32767))}
}

// impostor_error is how far an impostor may be from its mesh, in meters: the larger of the error of the mesh's
// coarsest level, which its top meshlets keep, and a texel of a frame. The impostor path draws the impostor where that
// is too small to show, so it takes over past the coarsest level.
impostor_error :: proc(meshlets: []format.Meshlet, sphere: format.Mesh_Bounds, size: int) -> f32 {
	coarsest: f32
	for m in meshlets {
		if m.parent_error == math.F32_MAX {
			coarsest = max(coarsest, m.error)
		}
	}
	return max(coarsest, 2 * sphere.radius / f32(size))
}
