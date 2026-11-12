package nav

import "base:runtime"
import "core:math"
import "core:math/linalg"

import "cinnabar:engine/ecs"
import "cinnabar:engine/random"

// The queries on the frame's navmeshes (see docs/ai/navigation.md#queries). They take and give World_Positions, and
// work in f32 relative to the navmesh's anchor inside. They only read the frame's views, and their scratch memory is
// the allocator that they are given, a job's own temp_allocator by default, so any number of jobs can call them at
// once, between prepare and end_frame. A query picks a navmesh by the agent type and by its point: the one of the
// agent type whose bounds hold the point, and of several, the one with the polygon nearest it.

// The nodes that a search may reach before it gives its best partial path.
DEFAULT_MAX_NODES :: 2048

// Location is a point on a navmesh, and its polygon.
Location :: struct {
	position: ecs.World_Position,
	mesh:     Mesh_Id,
	polygon:  u32,
}

// Path_Result is a path: its status, Found, Partial or Failed, its corners from the start to its end, and the corridor
// of polygons that it crosses.
Path_Result :: struct {
	status:   Path_Status,
	mesh:     Mesh_Id,
	corners:  []ecs.World_Position,
	corridor: []u32,
}

// Raycast_Hit is how far a straight walk along a navmesh goes: the fraction t of the way to its end, the point that it
// reaches, and the wall that stops it, by the wall's normal on the ground, or none when it reaches its end. polygon is
// the last that it crosses.
Raycast_Hit :: struct {
	t:        f32,
	position: ecs.World_Position,
	wall:     Maybe([3]f32),
	mesh:     Mesh_Id,
	polygon:  u32,
}

// default_extents is how far from a point a query looks for a navmesh's polygons, by the agent's size: across, twice
// its radius, and up and down, its height.
default_extents :: proc "contextless" (m: ^Mesh_View) -> [3]f32 {
	across := max(2 * m.radius, 2 * m.cell_size)
	return {across, max(m.height, 2 * m.cell_height), across}
}

// mesh_of is the frame's view of a navmesh, or nil when it is not loaded.
mesh_of :: proc(s: ^State, id: Mesh_Id) -> ^Mesh_View {
	for &m in s.frame {
		if m.id == id {
			return &m
		}
	}
	return nil
}

// agent_type is the agent type of the frame's navmeshes that has a name.
agent_type :: proc(s: ^State, name: string) -> (Agent_Type, bool) {
	for &m in s.frame {
		if m.name == name {
			return m.id.agent, true
		}
	}
	return 0, false
}

// snap is the polygon nearest a point within extents of it, of the navmeshes of an agent type whose bounds hold the
// point, and the point on it. With no extents, each navmesh's default_extents.
@(private)
snap :: proc(s: ^State, p: ecs.World_Position, agent: Agent_Type, extents: Maybe([3]f32) = nil) -> (m: ^Mesh_View, polygon: u32, point: [3]f32, ok: bool) {
	best := max(f32)
	polygon = NO_POLYGON
	for &v in s.frame {
		if v.id.agent != agent {
			continue
		}
		e := extents.? or_else default_extents(&v)
		q := local(&v, p)
		if !holds(&v, q, e) {
			continue
		}
		found, on, distance := nearest_in(&v, q, e)
		if found != NO_POLYGON && distance < best {
			m, polygon, point, best = &v, found, on, distance
		}
	}
	return m, polygon, point, polygon != NO_POLYGON
}

// nearest is the point of the navmeshes of an agent type nearest point, within extents of it, and its polygon.
nearest :: proc(s: ^State, point: ecs.World_Position, extents: [3]f32, agent: Agent_Type) -> (Location, bool) {
	m, polygon, on, ok := snap(s, point, agent, extents)
	if !ok {
		return {}, false
	}
	return {position = world(m, on), mesh = m.id, polygon = polygon}, true
}

// find_path is the path from start to goal for an agent type: A* over the polygons, at most max_nodes of them, and the
// funnel's straight path through their portals. Both points snap to the navmesh within its default_extents. A goal
// that no path reaches, or that no polygon is near, gives a Partial path to the nearest point that the search reached;
// a start that is on no navmesh gives Failed. The corners and the corridor are in allocator.
find_path :: proc(s: ^State, start, goal: ecs.World_Position, agent: Agent_Type, max_nodes := DEFAULT_MAX_NODES, allocator := context.temp_allocator) -> Path_Result {
	m, start_polygon, from, ok := snap(s, start, agent)
	if !ok {
		return {status = .Failed}
	}
	sr: Search
	graph_reserve(&sr.graph, max_nodes, allocator)
	begin_toward(&sr, m, from, start_polygon, goal)
	search_step(&sr, m, max(int))
	status, corners, corridor := search_finish(&sr, m, allocator)
	return {status = status, mesh = m.id, corners = to_world(m, corners, allocator), corridor = corridor}
}

// begin_toward starts a search from a point on a polygon toward a goal, which snaps onto the polygon nearest it, if one
// is.
@(private)
begin_toward :: proc(sr: ^Search, m: ^Mesh_View, from: [3]f32, start_polygon: u32, goal: ecs.World_Position) {
	to := local(m, goal)
	goal_polygon, on, _ := nearest_in(m, to, default_extents(m))
	if goal_polygon != NO_POLYGON {
		to = on
	}
	search_begin(sr, from, to, start_polygon, goal_polygon)
}

@(private)
to_world :: proc(m: ^Mesh_View, points: [][3]f32, allocator: runtime.Allocator) -> []ecs.World_Position {
	out := make([]ecs.World_Position, len(points), allocator)
	for p, i in points {
		out[i] = world(m, p)
	}
	return out
}

// raycast walks straight along the navmesh from start toward end, as Detour's raycast, from polygon to polygon across
// their edges on the xz plane, until it reaches end or an edge with nothing across. It fails for a start on no navmesh
// of the agent type.
raycast :: proc(s: ^State, start, end: ecs.World_Position, agent: Agent_Type) -> (hit: Raycast_Hit, ok: bool) {
	m, polygon, p0 := snap(s, start, agent) or_return
	p1 := local(m, end)
	t: f32
	current := polygon
	hit = {mesh = m.id}
	// Each polygon is crossed once at most on a straight line.
	for _ in 0 ..= len(m.polygons) {
		pts := points_of(m, current)
		_, tmax, _, leaving, crossed := cross_polygon_2d(p0, p1, &pts)
		hit.polygon = current
		if !crossed {
			// The segment misses the polygon, which only rounding does: the walk stops where it is.
			hit.wall = [3]f32{}
			break
		}
		t = max(t, tmax)
		if leaving < 0 {
			t = 1
			break
		}
		a, b := pts.points[leaving], pts.points[(leaving + 1) % pts.count]
		c := math.lerp(p0, p1, tmax)
		along := projection_2d(c, a, b)
		next, found := across(m, current, leaving, along)
		if !found {
			normal := [3]f32{b.z - a.z, 0, -(b.x - a.x)}
			if length := linalg.length(normal); length > 0 {
				normal /= length
			}
			hit.wall = normal
			break
		}
		current = next
	}
	p := math.lerp(p0, p1, t)
	p.y = height_at(m, hit.polygon, p)
	hit.t = t
	hit.position = world(m, p)
	return hit, true
}

// cross_polygon_2d is where segment p0 p1 enters and leaves a convex polygon on the xz plane, as Detour's
// dtIntersectSegmentPoly2D: the fractions of the segment, and the edges by their index, or -1 for an end inside.
@(private)
cross_polygon_2d :: proc "contextless" (p0, p1: [3]f32, pts: ^Polygon_Points) -> (tmin, tmax: f32, entering, leaving: int, ok: bool) {
	EPS :: 1e-6
	perp :: proc "contextless" (u, v: [3]f32) -> f32 {
		return u.z * v.x - u.x * v.z
	}
	tmin, tmax = 0, 1
	entering, leaving = -1, -1
	direction := p1 - p0
	j := pts.count - 1
	for i in 0 ..< pts.count {
		edge := pts.points[i] - pts.points[j]
		diff := p0 - pts.points[j]
		n := perp(edge, diff)
		d := perp(direction, edge)
		if abs(d) < EPS {
			// Parallel to the edge: outside it misses the polygon.
			if n < 0 {
				return
			}
			j = i
			continue
		}
		t := n / d
		if d < 0 {
			if t > tmin {
				tmin, entering = t, j
				if tmin > tmax {
					return
				}
			}
		} else {
			if t < tmax {
				tmax, leaving = t, j
				if tmax < tmin {
					return
				}
			}
		}
		j = i
	}
	ok = true
	return
}

// projection_2d is where a point is along segment ab on the xz plane, as a fraction of it.
@(private)
projection_2d :: proc "contextless" (p, a, b: [3]f32) -> f32 {
	dx, dz := b.x - a.x, b.z - a.z
	d := dx * dx + dz * dz
	return ((p.x - a.x) * dx + (p.z - a.z) * dz) / d if d > 0 else 0
}

// random_point is a point on the navmesh that a walk from around reaches without leaving radius of it by more than a
// polygon, as Detour's findRandomPointAroundCircle: the polygons whose portals are within radius are searched outward,
// one is drawn by its area, and a point in it. Every polygon counts by its whole area, so the point can be outside the
// circle by up to a polygon's size. It draws from rng, so a seed gives the same points.
random_point :: proc(s: ^State, around: ecs.World_Position, radius: f32, agent: Agent_Type, rng: ^random.State, max_nodes := DEFAULT_MAX_NODES, allocator := context.temp_allocator) -> (Location, bool) {
	m, start_polygon, center, ok := snap(s, around, agent)
	if !ok {
		return {}, false
	}
	g: Graph
	graph_reserve(&g, max_nodes, allocator)
	first, _ := graph_node(&g, start_polygon)
	g.nodes[first].position = center
	heap_push(&g, first)
	chosen := NO_POLYGON
	area_sum: f32
	radius_squared := radius * radius
	for len(g.heap) > 0 {
		current := heap_pop(&g)
		g.nodes[current].state = .Closed
		from := g.nodes[current]
		pts := points_of(m, from.polygon)
		area := polygon_area_2d(&pts)
		area_sum += area
		if random.float32(rng) * area_sum <= area {
			chosen = from.polygon
		}
		it := portals(m, from.polygon)
		for portal in next_portal(&it) {
			if from.parent != NO_NODE && portal.neighbor == g.nodes[from.parent].polygon {
				continue
			}
			if d, _ := distance_to_segment_2d(center, portal.left, portal.right); d > radius_squared {
				continue
			}
			next, room := graph_node(&g, portal.neighbor)
			if !room {
				continue
			}
			n := &g.nodes[next]
			if n.state == .Closed {
				continue
			}
			if n.state == .New {
				n.position = (portal.left + portal.right) * 0.5
			}
			total := from.total + linalg.distance(from.position, n.position)
			if n.state == .Open && total >= n.total {
				continue
			}
			n.parent, n.total = current, total
			heap_push(&g, next)
		}
	}
	if chosen == NO_POLYGON {
		return {}, false
	}
	pts := points_of(m, chosen)
	p := point_in_polygon(&pts, random.float32(rng), random.float32(rng))
	p.y = height_at(m, chosen, p)
	return {position = world(m, p), mesh = m.id, polygon = chosen}, true
}

// point_in_polygon is the point of a convex polygon that two numbers in [0, 1) pick, uniformly over its area, as
// Detour's dtRandomPointInConvexPoly: one picks a triangle of its fan by area, and both a point in it.
@(private)
point_in_polygon :: proc "contextless" (pts: ^Polygon_Points, s, t: f32) -> [3]f32 {
	areas: [len(pts.points)]f32
	area_sum: f32
	for i in 2 ..< pts.count {
		areas[i] = max(abs(tri_area_2d(pts.points[0], pts.points[i - 1], pts.points[i])), 0.001)
		area_sum += areas[i]
	}
	threshold := s * area_sum
	accumulated: f32
	u: f32 = 1
	triangle := pts.count - 1
	for i in 2 ..< pts.count {
		if threshold >= accumulated && threshold < accumulated + areas[i] {
			u = (threshold - accumulated) / areas[i]
			triangle = i
			break
		}
		accumulated += areas[i]
	}
	v := math.sqrt(t)
	a, b, c := 1 - v, (1 - u) * v, u * v
	return a * pts.points[0] + b * pts.points[triangle - 1] + c * pts.points[triangle]
}
