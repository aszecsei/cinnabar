package nav

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The geometry of a navmesh's polygons, as the queries read it. Everything here is in f32 meters relative to the mesh's
// anchor, along the world's axes, with y up. A polygon is named by its index in the blob's polygons (see
// docs/ai/navigation.md#queries).

// Mesh_Id is a navmesh by its volume's scene ID and its agent type, which hold across a recook.
Mesh_Id :: struct {
	volume: u64,
	agent:  Agent_Type,
}

// Mesh_Stamp is a navmesh's asset and the version of its blob, which a recook changes.
Mesh_Stamp :: struct {
	handle:  asset.Handle,
	version: u32,
}

// Mesh_View is a loaded navmesh's blob, read for one frame: prepare makes the frame's views and end_frame lets them go,
// because asset.poll can swap the blob.
Mesh_View :: struct {
	id:               Mesh_Id,
	stamp:            Mesh_Stamp,
	// The agent type's name, in the blob.
	name:             string,
	anchor:           ecs.World_Position,
	bounds_min:       [3]f32,
	bounds_max:       [3]f32,
	tile_size:        f32,
	cell_size:        f32,
	cell_height:      f32,
	radius:           f32,
	height:           f32,
	// The agent's step height: how far above or below a polygon a point is still on it.
	climb:            f32,
	tiles_x:          u32,
	tiles_z:          u32,
	tiles:            []format.Nav_Tile,
	vertices:         [][3]f32,
	polygons:         []format.Nav_Polygon,
	links:            []format.Nav_Link,
	details:          []format.Nav_Detail,
	detail_vertices:  [][3]f32,
	detail_triangles: [][4]u8,
}

// NO_POLYGON is no polygon.
NO_POLYGON :: max(u32)

// Two points closer than this are the same, as Detour's dtVequal has it.
@(private)
EQUAL_DISTANCE :: 1.0 / 16384.0

// view_of reads a navmesh blob of a volume into a view, or fails for one that nav_mesh_view refuses. prepare makes the
// frame's views with it.
view_of :: proc(data: []byte, stamp: Mesh_Stamp, volume: u64) -> (m: Mesh_View, ok: bool) {
	blob := format.nav_mesh_view(data) or_return
	agent := format.nav_mesh_agent(data, blob)
	return {
			id = {volume = volume, agent = Agent_Type(blob.agent_index)},
			stamp = stamp,
			name = agent.name,
			anchor = {raw = blob.anchor},
			bounds_min = blob.bounds_min,
			bounds_max = blob.bounds_max,
			tile_size = blob.tile_size,
			cell_size = blob.cell_size,
			cell_height = blob.cell_height,
			radius = agent.radius,
			height = agent.height,
			climb = agent.step_height,
			tiles_x = blob.tiles_x,
			tiles_z = blob.tiles_z,
			tiles = format.nav_mesh_tiles(data, blob),
			vertices = format.nav_mesh_vertices(data, blob),
			polygons = format.nav_mesh_polygons(data, blob),
			links = format.nav_mesh_links(data, blob),
			details = format.nav_mesh_details(data, blob),
			detail_vertices = format.nav_mesh_detail_vertices(data, blob),
			detail_triangles = format.nav_mesh_detail_triangles(data, blob),
		},
		true
}

// local is a position relative to the mesh's anchor.
@(private)
local :: proc "contextless" (m: ^Mesh_View, p: ecs.World_Position) -> [3]f32 {
	d := ecs.position_sub_f64(p, m.anchor)
	return {f32(d.x), f32(d.y), f32(d.z)}
}

// world is a position relative to the mesh's anchor as a World_Position.
@(private)
world :: proc(m: ^Mesh_View, v: [3]f32) -> ecs.World_Position {
	return ecs.position_offset_f64(m.anchor, {f64(v.x), f64(v.y), f64(v.z)})
}

// holds is whether the mesh's bounds, grown by margin, hold a point relative to its anchor.
@(private)
holds :: proc "contextless" (m: ^Mesh_View, p: [3]f32, margin: [3]f32 = {}) -> bool {
	lo, hi := m.bounds_min - margin, m.bounds_max + margin
	return p.x >= lo.x && p.y >= lo.y && p.z >= lo.z && p.x <= hi.x && p.y <= hi.y && p.z <= hi.z
}

// tile_of is the tile of a polygon. The tiles' runs follow each other, which nav_mesh_view checks, so the first tile
// whose run ends after the polygon holds it.
@(private)
tile_of :: proc "contextless" (m: ^Mesh_View, polygon: u32) -> ^format.Nav_Tile {
	lo, hi := 0, len(m.tiles)
	for lo < hi {
		mid := (lo + hi) / 2
		t := &m.tiles[mid]
		if t.first_polygon + t.polygon_count > polygon {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return &m.tiles[lo]
}

// Polygon_Points is a polygon's vertices.
@(private)
Polygon_Points :: struct {
	points: [format.NAV_MAX_POLYGON_VERTICES][3]f32,
	count:  int,
}

@(private)
points_of :: proc "contextless" (m: ^Mesh_View, polygon: u32) -> (out: Polygon_Points) {
	tile := tile_of(m, polygon)
	p := &m.polygons[polygon]
	out.count = int(p.vertex_count)
	for k in 0 ..< out.count {
		out.points[k] = m.vertices[tile.first_vertex + u32(p.vertices[k])]
	}
	return
}

// The span of a polygon's points and its detail mesh's.
@(private)
polygon_bounds :: proc "contextless" (m: ^Mesh_View, polygon: u32) -> (lo, hi: [3]f32) {
	pts := points_of(m, polygon)
	lo, hi = pts.points[0], pts.points[0]
	for v in pts.points[1:pts.count] {
		lo, hi = linalg.min(lo, v), linalg.max(hi, v)
	}
	tile := tile_of(m, polygon)
	d := m.details[polygon]
	for v in m.detail_vertices[tile.first_detail_vertex + d.first_vertex:][:d.vertex_count] {
		lo.y, hi.y = min(lo.y, v.y), max(hi.y, v.y)
	}
	return
}

// Portal is the part of an edge that a polygon crosses to a neighbor by: its left and right ends, as an agent that
// leaves through it sees them. A link across tiles crosses by the part of the edge that it covers.
@(private)
Portal :: struct {
	neighbor:    u32,
	edge:        int,
	left, right: [3]f32,
}

// Portals goes through a polygon's portals: its edges' neighbors in the tile, and its links to the next tiles, in its
// edges' order and then its links'.
@(private)
Portals :: struct {
	m:       ^Mesh_View,
	polygon: u32,
	points:  Polygon_Points,
	edge:    int,
	link:    int,
}

@(private)
portals :: proc "contextless" (m: ^Mesh_View, polygon: u32) -> Portals {
	return {m = m, polygon = polygon, points = points_of(m, polygon)}
}

@(private)
next_portal :: proc "contextless" (it: ^Portals) -> (portal: Portal, ok: bool) {
	m := it.m
	p := &m.polygons[it.polygon]
	for it.edge < it.points.count {
		k := it.edge
		a, b := it.points.points[k], it.points.points[(k + 1) % it.points.count]
		n := p.neighbors[k]
		if n == format.NAV_NONE {
			it.edge += 1
			continue
		}
		if n & format.NAV_EXTERNAL == 0 {
			it.edge += 1
			return {neighbor = tile_of(m, it.polygon).first_polygon + u32(n), edge = k, left = a, right = b}, true
		}
		links := m.links[p.first_link:][:p.link_count]
		for it.link < len(links) {
			l := links[it.link]
			it.link += 1
			if int(l.edge) == k {
				t0, t1 := f32(l.t_min) / 255, f32(l.t_max) / 255
				return {neighbor = l.polygon, edge = k, left = math.lerp(a, b, t0), right = math.lerp(a, b, t1)}, true
			}
		}
		it.edge += 1
		it.link = 0
	}
	return
}

// portal_between is the portal that leads from one polygon to another.
@(private)
portal_between :: proc "contextless" (m: ^Mesh_View, from, to: u32) -> (Portal, bool) {
	it := portals(m, from)
	for portal in next_portal(&it) {
		if portal.neighbor == to {
			return portal, true
		}
	}
	return {}, false
}

// across is the polygon across an edge at a point on it, given by its fraction along the edge: the neighbor in the tile,
// or the link whose part of the edge holds the point.
@(private)
across :: proc "contextless" (m: ^Mesh_View, polygon: u32, edge: int, along: f32) -> (u32, bool) {
	p := &m.polygons[polygon]
	n := p.neighbors[edge]
	if n == format.NAV_NONE {
		return NO_POLYGON, false
	}
	if n & format.NAV_EXTERNAL == 0 {
		return tile_of(m, polygon).first_polygon + u32(n), true
	}
	// A link's ends are rounded to 255ths, so a point a little outside one still crosses by it.
	SLACK :: 0.5 / 255
	for l in m.links[p.first_link:][:p.link_count] {
		if int(l.edge) == edge && along >= f32(l.t_min) / 255 - SLACK && along <= f32(l.t_max) / 255 + SLACK {
			return l.polygon, true
		}
	}
	return NO_POLYGON, false
}

// tri_area_2d is twice the signed area of a triangle on the xz plane, as Detour's dtTriArea2D: positive for the
// winding that Recast gives polygons.
@(private)
tri_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
	abx, abz := b.x - a.x, b.z - a.z
	acx, acz := c.x - a.x, c.z - a.z
	return acx * abz - abx * acz
}

@(private)
equal_points :: proc "contextless" (a, b: [3]f32) -> bool {
	d := a - b
	return linalg.dot(d, d) < EQUAL_DISTANCE * EQUAL_DISTANCE
}

@(private)
distance_2d :: proc "contextless" (a, b: [3]f32) -> f32 {
	return math.sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z))
}

// distance_to_segment_2d is the squared distance from p to segment ab on the xz plane, and where along ab the nearest
// point is.
@(private)
distance_to_segment_2d :: proc "contextless" (p, a, b: [3]f32) -> (distance_squared, t: f32) {
	dx, dz := b.x - a.x, b.z - a.z
	d := dx * dx + dz * dz
	if d > 0 {
		t = ((p.x - a.x) * dx + (p.z - a.z) * dz) / d
	}
	t = clamp(t, 0, 1)
	x, z := a.x + t * dx - p.x, a.z + t * dz - p.z
	return x * x + z * z, t
}

// inside_2d is whether a polygon holds a point on the xz plane, as Detour's dtPointInPolygon.
@(private)
inside_2d :: proc "contextless" (p: [3]f32, pts: ^Polygon_Points) -> bool {
	c := false
	j := pts.count - 1
	for i in 0 ..< pts.count {
		vi, vj := pts.points[i], pts.points[j]
		if ((vi.z > p.z) != (vj.z > p.z)) && (p.x < (vj.x - vi.x) * (p.z - vi.z) / (vj.z - vi.z) + vi.x) {
			c = !c
		}
		j = i
	}
	return c
}

// height_at is the height of a polygon's surface under a point, from its detail triangles, or from the nearest of
// their edges for a point beside them.
@(private)
height_at :: proc "contextless" (m: ^Mesh_View, polygon: u32, p: [3]f32) -> f32 {
	tile := tile_of(m, polygon)
	d := m.details[polygon]
	vertices := m.detail_vertices[tile.first_detail_vertex + d.first_vertex:][:d.vertex_count]
	triangles := m.detail_triangles[tile.first_detail_triangle + d.first_triangle:][:d.triangle_count]
	for t in triangles {
		if h, ok := height_on_triangle(p, vertices[t[0]], vertices[t[1]], vertices[t[2]]); ok {
			return h
		}
	}
	best := max(f32)
	height := p.y
	for t in triangles {
		for k in 0 ..< 3 {
			a, b := vertices[t[k]], vertices[t[(k + 1) % 3]]
			distance, along := distance_to_segment_2d(p, a, b)
			if distance < best {
				best = distance
				height = math.lerp(a.y, b.y, along)
			}
		}
	}
	return height
}

// height_on_triangle is the height of triangle abc under a point, as Detour's dtClosestHeightPointTriangle, if the
// triangle holds it on the xz plane.
@(private)
height_on_triangle :: proc "contextless" (p, a, b, c: [3]f32) -> (f32, bool) {
	EPS :: 1e-6
	v0, v1, v2 := c - a, b - a, p - a
	denom := v0.x * v1.z - v0.z * v1.x
	if abs(denom) < EPS {
		return 0, false
	}
	u := v1.z * v2.x - v1.x * v2.z
	v := v0.x * v2.z - v0.z * v2.x
	if denom < 0 {
		denom, u, v = -denom, -u, -v
	}
	if u >= 0 && v >= 0 && u + v <= denom {
		return a.y + (v0.y * u + v1.y * v) / denom, true
	}
	return 0, false
}

// closest_on_polygon is the point of a polygon nearest p: under it, on the surface, if the polygon holds it on the xz
// plane, and on the nearest edge otherwise.
@(private)
closest_on_polygon :: proc "contextless" (m: ^Mesh_View, polygon: u32, p: [3]f32) -> (q: [3]f32, inside: bool) {
	pts := points_of(m, polygon)
	q = p
	if inside_2d(p, &pts) {
		inside = true
	} else {
		best := max(f32)
		for k in 0 ..< pts.count {
			a, b := pts.points[k], pts.points[(k + 1) % pts.count]
			distance, along := distance_to_segment_2d(p, a, b)
			if distance < best {
				best = distance
				q = math.lerp(a, b, along)
			}
		}
	}
	q.y = height_at(m, polygon, q)
	return
}

// polygon_area_2d is a polygon's area on the xz plane.
@(private)
polygon_area_2d :: proc "contextless" (pts: ^Polygon_Points) -> (area: f32) {
	for k in 2 ..< pts.count {
		area += abs(tri_area_2d(pts.points[0], pts.points[k - 1], pts.points[k])) * 0.5
	}
	return
}

// The tiles under a box on the xz plane, relative to the anchor, as ranges of the grid's columns and rows, empty when
// it misses the grid.
@(private)
tiles_under :: proc "contextless" (m: ^Mesh_View, lo, hi: [3]f32) -> (x0, z0, x1, z1: int) {
	if m.tile_size <= 0 || m.tiles_x == 0 || m.tiles_z == 0 {
		return 0, 0, -1, -1
	}
	cell :: proc "contextless" (v, origin, size: f32, count: u32) -> int {
		return clamp(int(math.floor((v - origin) / size)), 0, int(count) - 1)
	}
	if hi.x < m.bounds_min.x || hi.z < m.bounds_min.z || lo.x > m.bounds_max.x || lo.z > m.bounds_max.z {
		return 0, 0, -1, -1
	}
	x0 = cell(lo.x, m.bounds_min.x, m.tile_size, m.tiles_x)
	x1 = cell(hi.x, m.bounds_min.x, m.tile_size, m.tiles_x)
	z0 = cell(lo.z, m.bounds_min.z, m.tile_size, m.tiles_z)
	z1 = cell(hi.z, m.bounds_min.z, m.tile_size, m.tiles_z)
	return
}

// nearest_in is the polygon of a mesh nearest p within extents of it, and the point on it, as Detour's
// findNearestPoly: for a polygon over or under the point, only the height past the agent's climb counts. Ties go to
// the first polygon in the blob's order. distance is squared.
@(private)
nearest_in :: proc "contextless" (m: ^Mesh_View, p, extents: [3]f32) -> (polygon: u32, point: [3]f32, distance: f32) {
	polygon, distance = NO_POLYGON, max(f32)
	lo, hi := p - extents, p + extents
	x0, z0, x1, z1 := tiles_under(m, lo, hi)
	for tz in z0 ..= z1 {
		for tx in x0 ..= x1 {
			tile := &m.tiles[u32(tz) * m.tiles_x + u32(tx)]
			for i in tile.first_polygon ..< tile.first_polygon + tile.polygon_count {
				blo, bhi := polygon_bounds(m, i)
				if bhi.x < lo.x || blo.x > hi.x || bhi.y < lo.y || blo.y > hi.y || bhi.z < lo.z || blo.z > hi.z {
					continue
				}
				q, over := closest_on_polygon(m, i, p)
				d: f32
				if over {
					h := abs(p.y - q.y) - m.climb
					d = h * h if h > 0 else 0
				} else {
					diff := p - q
					d = linalg.dot(diff, diff)
				}
				if d < distance {
					polygon, point, distance = i, q, d
				}
			}
		}
	}
	return
}
