package nav

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The frame's navmeshes as one surface (see docs/ai/navigation.md#seams). A polygon of any of them is a Poly: its
// mesh's slot in the frame and its index in the mesh's blob. A search, a corridor or a walk works in a Net, the frame's
// views and one origin, the anchor of the mesh that it starts on, and reads each mesh's points offset by its anchor's
// place from the origin. On one mesh the offset is zero, and everything is as the mesh's own. Seam links join the
// edges of two meshes that meet, as links join the tiles of one.

// Poly is a polygon of the frame's navmeshes: its mesh's slot in the frame, and its index in the mesh's blob.
Poly :: struct {
	slot:    u32,
	polygon: u32,
}

// NO_POLY is no polygon.
NO_POLY :: Poly{max(u32), max(u32)}

// Net is the frame's views, by slot, and the origin that points are relative to.
@(private)
Net :: struct {
	views:  []Mesh_View,
	origin: ecs.World_Position,
}

// net_at is the frame's views relative to a mesh's anchor.
@(private)
net_at :: proc "contextless" (s: ^State, m: ^Mesh_View) -> Net {
	return {views = s.frame, origin = m.anchor}
}

@(private)
view_of_poly :: proc "contextless" (n: ^Net, p: Poly) -> ^Mesh_View {
	return &n.views[p.slot]
}

// offset is where a mesh's anchor is from the net's origin.
@(private)
offset :: proc "contextless" (n: ^Net, m: ^Mesh_View) -> [3]f32 {
	d := ecs.position_sub_f64(m.anchor, n.origin)
	return {f32(d.x), f32(d.y), f32(d.z)}
}

// net_local is a position relative to the net's origin.
@(private)
net_local :: proc "contextless" (n: ^Net, p: ecs.World_Position) -> [3]f32 {
	d := ecs.position_sub_f64(p, n.origin)
	return {f32(d.x), f32(d.y), f32(d.z)}
}

// net_world is a position relative to the net's origin as a World_Position.
@(private)
net_world :: proc(n: ^Net, v: [3]f32) -> ecs.World_Position {
	return ecs.position_offset_f64(n.origin, {f64(v.x), f64(v.y), f64(v.z)})
}

// net_points is a polygon's vertices, relative to the net's origin.
@(private)
net_points :: proc "contextless" (n: ^Net, p: Poly) -> Polygon_Points {
	m := view_of_poly(n, p)
	pts := points_of(m, p.polygon)
	if o := offset(n, m); o != {} {
		for &v in pts.points[:pts.count] {
			v += o
		}
	}
	return pts
}

// net_height is the height of a polygon's surface under a point, relative to the net's origin.
@(private)
net_height :: proc "contextless" (n: ^Net, p: Poly, at: [3]f32) -> f32 {
	m := view_of_poly(n, p)
	o := offset(n, m)
	return height_at(m, p.polygon, at - o) + o.y
}

// net_closest is the point of a polygon nearest a point, relative to the net's origin, as closest_on_polygon.
@(private)
net_closest :: proc "contextless" (n: ^Net, p: Poly, at: [3]f32) -> (q: [3]f32, inside: bool) {
	m := view_of_poly(n, p)
	o := offset(n, m)
	q, inside = closest_on_polygon(m, p.polygon, at - o)
	return q + o, inside
}

// net_polygon_count is the polygons of every mesh, which bounds a walk that crosses each once.
@(private)
net_polygon_count :: proc "contextless" (n: ^Net) -> (count: int) {
	for &m in n.views {
		count += len(m.polygons)
	}
	return
}

// Crossing is a polygon across an edge, and the part of the edge that crosses to it, as fractions of the edge.
@(private)
Crossing :: struct {
	to:     Poly,
	t0, t1: f32,
}

// MAX_CROSSINGS is the most polygons across one edge that the walks keep.
@(private)
MAX_CROSSINGS :: 8

// crossings is what is across a polygon's edge: the neighbor in its tile, over the whole edge, or the links to the next
// tiles and then the seam links to other meshes, each over its part of the edge, in their order. None is a wall.
@(private)
crossings :: proc "contextless" (
	n: ^Net,
	p: Poly,
	edge: int,
	out: ^[MAX_CROSSINGS]Crossing,
) -> (
	count: int,
) {
	m := view_of_poly(n, p)
	polygon := &m.polygons[p.polygon]
	k := polygon.neighbors[edge]
	if k == format.NAV_NONE {
		return 0
	}
	if k & format.NAV_EXTERNAL == 0 {
		out[0] = {{p.slot, tile_of(m, p.polygon).first_polygon + u32(k)}, 0, 1}
		return 1
	}
	for l in m.links[polygon.first_link:][:polygon.link_count] {
		if int(l.edge) == edge && count < MAX_CROSSINGS {
			out[count] = {{p.slot, l.polygon}, f32(l.t_min) / 255, f32(l.t_max) / 255}
			count += 1
		}
	}
	for l in seams_of(m, p.polygon) {
		if int(l.edge) == edge && count < MAX_CROSSINGS {
			out[count] = {l.to, f32(l.t_min) / 255, f32(l.t_max) / 255}
			count += 1
		}
	}
	return
}

// Portal is the part of an edge that a polygon crosses to a neighbor by: its left and right ends, as an agent that
// leaves through it sees them, relative to the net's origin. A link crosses by the part of the edge that it covers.
@(private)
Portal :: struct {
	neighbor:    Poly,
	edge:        int,
	left, right: [3]f32,
}

// Portals goes through a polygon's portals: across each of its edges in order, what crossings gives.
@(private)
Portals :: struct {
	n:         ^Net,
	poly:      Poly,
	points:    Polygon_Points,
	edge:      int,
	crossings: [MAX_CROSSINGS]Crossing,
	count:     int,
	next:      int,
}

@(private)
portals :: proc "contextless" (n: ^Net, p: Poly) -> Portals {
	it := Portals {
		n      = n,
		poly   = p,
		points = net_points(n, p),
		edge   = -1,
	}
	return it
}

@(private)
next_portal :: proc "contextless" (it: ^Portals) -> (portal: Portal, ok: bool) {
	for it.next >= it.count {
		it.edge += 1
		if it.edge >= it.points.count {
			return
		}
		it.count = crossings(it.n, it.poly, it.edge, &it.crossings)
		it.next = 0
	}
	c := it.crossings[it.next]
	it.next += 1
	a, b := it.points.points[it.edge], it.points.points[(it.edge + 1) % it.points.count]
	return {
			neighbor = c.to,
			edge = it.edge,
			left = math.lerp(a, b, c.t0),
			right = math.lerp(a, b, c.t1),
		},
		true
}

// portal_between is the portal that leads from one polygon to another.
@(private)
portal_between :: proc "contextless" (n: ^Net, from, to: Poly) -> (Portal, bool) {
	it := portals(n, from)
	for portal in next_portal(&it) {
		if portal.neighbor == to {
			return portal, true
		}
	}
	return {}, false
}

// across is the polygon across an edge at a point on it, given by its fraction along the edge: the neighbor in the tile,
// or the link or seam link whose part of the edge holds the point.
@(private)
across :: proc "contextless" (n: ^Net, p: Poly, edge: int, along: f32) -> (Poly, bool) {
	// A link's ends are rounded to 255ths, so a point a little outside one still crosses by it.
	SLACK :: 0.5 / 255
	list: [MAX_CROSSINGS]Crossing
	count := crossings(n, p, edge, &list)
	for c in list[:count] {
		if along >= c.t0 - SLACK && along <= c.t1 + SLACK {
			return c.to, true
		}
	}
	return NO_POLY, false
}

// Slot_Stamp is a navmesh that something crossed, by its slot, and its blob then.
Slot_Stamp :: struct {
	slot:  u32,
	stamp: Mesh_Stamp,
}

// stamps_of gives the navmeshes that a corridor crosses, each once, in out.
@(private)
stamps_of :: proc(views: []Mesh_View, corridor: []Poly, out: ^[dynamic]Slot_Stamp) {
	clear(out)
	next: for p in corridor {
		for c in out {
			if c.slot == p.slot {
				continue next
			}
		}
		append(out, Slot_Stamp{p.slot, views[p.slot].stamp})
	}
}

// stamps_hold is whether each navmesh that something crossed is still in its slot, as it was.
@(private)
stamps_hold :: proc "contextless" (s: ^State, crossed: []Slot_Stamp) -> bool {
	for c in crossed {
		if mesh_at(s, c.slot, c.stamp) == nil {
			return false
		}
	}
	return true
}
