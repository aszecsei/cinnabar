package nav

import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"

// An agent's corridor (see docs/ai/navigation.md#crowds): the polygons of its path from the one that it stands on to
// its target's, as DetourCrowd's dtPathCorridor keeps them. As the agent moves, the corridor's start follows it over
// the polygons that it crossed; a straight walk to a corner ahead cuts the polygons between; and the funnel over the
// corridor gives the next corners to steer to. Everything here is relative to the navmesh's anchor.

// The polygons that a move along the surface searches, as Detour's moveAlongSurface's MAX_STACK.
@(private)
MOVE_SEARCH :: 48

// move_along_surface is where a move from start, on polygon first, toward end stops on the navmesh, as Detour's
// moveAlongSurface: end if a polygon near the move holds it, or the nearest point of a wall to it. visited is the
// polygons from first to the one that holds that point, in allocator.
@(private)
move_along_surface :: proc(m: ^Mesh_View, first: u32, start, end: [3]f32, allocator := context.temp_allocator) -> (result: [3]f32, visited: []u32) {
	Visit :: struct {
		polygon: u32,
		parent:  int,
	}
	nodes := make([dynamic]Visit, 0, MOVE_SEARCH, allocator)
	append(&nodes, Visit{first, -1})
	best := 0
	best_distance := max(f32)
	result = start
	// The search stays in the circle around the move.
	center := (start + end) * 0.5
	radius := distance_2d(start, end) * 0.5 + 0.001
	radius_squared := radius * radius
	for i := 0; i < len(nodes); i += 1 {
		current := nodes[i]
		pts := points_of(m, current.polygon)
		if inside_2d(end, &pts) {
			best = i
			result = end
			break
		}
		p := &m.polygons[current.polygon]
		for k in 0 ..< pts.count {
			a, b := pts.points[k], pts.points[(k + 1) % pts.count]
			neighbors: [format.NAV_MAX_POLYGON_VERTICES + 8]u32
			count := 0
			if p.neighbors[k] != format.NAV_NONE {
				if p.neighbors[k] & format.NAV_EXTERNAL == 0 {
					neighbors[0] = tile_of(m, current.polygon).first_polygon + u32(p.neighbors[k])
					count = 1
				} else {
					for l in m.links[p.first_link:][:p.link_count] {
						if int(l.edge) == k && count < len(neighbors) {
							neighbors[count] = l.polygon
							count += 1
						}
					}
				}
			}
			if count == 0 {
				// A wall: the nearest point of it to end is where the move stops, if no polygon holds end.
				distance, along := distance_to_segment_2d(end, a, b)
				if distance < best_distance {
					best_distance = distance
					result = math.lerp(a, b, along)
					best = i
				}
				continue
			}
			if distance, _ := distance_to_segment_2d(center, a, b); distance > radius_squared {
				continue
			}
			next: for n in neighbors[:count] {
				for v in nodes {
					if v.polygon == n {
						continue next
					}
				}
				if len(nodes) < MOVE_SEARCH {
					append(&nodes, Visit{n, i})
				}
			}
		}
	}
	length := 0
	for n := best; n >= 0; n = nodes[n].parent {
		length += 1
	}
	path := make([]u32, length, allocator)
	for n, i := best, length - 1; n >= 0; n, i = nodes[n].parent, i - 1 {
		path[i] = nodes[n].polygon
	}
	result.y = height_at(m, nodes[best].polygon, result)
	return result, path
}

// furthest_common is the last polygon of a corridor that visited has, by its index in each, as Detour's merges find it.
@(private)
furthest_common :: proc(path, visited: []u32) -> (in_path, in_visited: int, found: bool) {
	for i := len(path) - 1; i >= 0; i -= 1 {
		for j := len(visited) - 1; j >= 0; j -= 1 {
			if path[i] == visited[j] {
				return i, j, true
			}
		}
	}
	return -1, -1, false
}

// merge_start_moved fixes a corridor's start after a move along the surface, as Detour's dtMergeCorridorStartMoved:
// the polygons that the move crossed, from the one that it ended on back to the last that the corridor has, and then
// the corridor after it. A move that crossed none of the corridor leaves it as it was, and returns false.
@(private)
merge_start_moved :: proc(path: ^[dynamic]u32, visited: []u32) -> bool {
	in_path, in_visited := furthest_common(path[:], visited) or_return
	rest := path[in_path + 1:]
	merged := make([dynamic]u32, 0, len(visited) - in_visited + len(rest), context.temp_allocator)
	for j := len(visited) - 1; j >= in_visited; j -= 1 {
		append(&merged, visited[j])
	}
	append(&merged, ..rest)
	clear(path)
	append(path, ..merged[:])
	return true
}

// merge_start_shortcut cuts a corridor's start to the polygons that a straight walk crossed, as Detour's
// dtMergeCorridorStartShortcut: visited up to the last polygon that the corridor has, and then the corridor from it.
@(private)
merge_start_shortcut :: proc(path: ^[dynamic]u32, visited: []u32) {
	in_path, in_visited, found := furthest_common(path[:], visited)
	if !found || in_visited <= 0 {
		return
	}
	rest := path[in_path:]
	merged := make([dynamic]u32, 0, in_visited + len(rest), context.temp_allocator)
	append(&merged, ..visited[:in_visited])
	append(&merged, ..rest)
	clear(path)
	append(path, ..merged[:])
}

// Walk is how far a straight walk from a point on a polygon goes, as raycast_local finds it: the fraction t of the way,
// the wall that stops it, by its normal on the ground, or none, and the last polygon that it crosses.
@(private)
Walk :: struct {
	t:       f32,
	wall:    Maybe([3]f32),
	polygon: u32,
}

// raycast_local walks straight from p0 on polygon first toward p1, as Detour's raycast, from polygon to polygon across
// their edges on the xz plane, until it reaches p1 or an edge with nothing across. With visited, it appends the
// polygons that it crosses, first among them.
@(private)
raycast_local :: proc(m: ^Mesh_View, first: u32, p0, p1: [3]f32, visited: ^[dynamic]u32 = nil) -> (walk: Walk) {
	current := first
	// Each polygon is crossed once at most on a straight line.
	for _ in 0 ..= len(m.polygons) {
		pts := points_of(m, current)
		_, tmax, _, leaving, crossed := cross_polygon_2d(p0, p1, &pts)
		walk.polygon = current
		if visited != nil {
			append(visited, current)
		}
		if !crossed {
			// The segment misses the polygon, which only rounding does: the walk stops where it is.
			walk.wall = [3]f32{}
			break
		}
		walk.t = max(walk.t, tmax)
		if leaving < 0 {
			walk.t = 1
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
			walk.wall = normal
			break
		}
		current = next
	}
	return
}

// Segment is a wall near an agent, from a to b.
@(private)
Segment :: struct {
	a, b: [3]f32,
}

// The walls that avoidance keeps for an agent, the nearest, and the polygons that their search visits.
@(private)
MAX_WALLS :: 16
@(private)
WALL_SEARCH :: 32

// wall_segments finds the walls within range of a point on a polygon, as Detour's findLocalNeighbourhood and
// getPolyWallSegments together: the polygons whose portals are within range, searched outward, and their edges that
// nothing crosses, or the parts of them that no link covers. It keeps the MAX_WALLS nearest, in out.
@(private)
wall_segments :: proc(m: ^Mesh_View, first: u32, center: [3]f32, range: f32, out: ^[MAX_WALLS]Segment) -> (count: int) {
	range_squared := range * range
	distances: [MAX_WALLS]f32
	keep :: proc(out: ^[MAX_WALLS]Segment, distances: ^[MAX_WALLS]f32, count: ^int, s: Segment, d: f32) {
		// Insertion by distance, then by the order found, so the walls do not depend on anything but the mesh.
		at := count^
		for at > 0 && distances[at - 1] > d {
			at -= 1
		}
		if at >= MAX_WALLS {
			return
		}
		last := min(count^, MAX_WALLS - 1)
		for i := last; i > at; i -= 1 {
			out[i], distances[i] = out[i - 1], distances[i - 1]
		}
		out[at], distances[at] = s, d
		count^ = min(count^ + 1, MAX_WALLS)
	}
	visited: [WALL_SEARCH]u32
	visited[0] = first
	n := 1
	for i := 0; i < n; i += 1 {
		polygon := visited[i]
		p := &m.polygons[polygon]
		pts := points_of(m, polygon)
		for k in 0 ..< pts.count {
			a, b := pts.points[k], pts.points[(k + 1) % pts.count]
			neighbor := p.neighbors[k]
			// The parts of the edge that something crosses, as fractions of it, in order.
			spans: [8][2]f32
			span_count := 0
			if neighbor != format.NAV_NONE {
				if neighbor & format.NAV_EXTERNAL == 0 {
					spans[0] = {0, 1}
					span_count = 1
					next := tile_of(m, polygon).first_polygon + u32(neighbor)
					add_visit(&visited, &n, m, center, range_squared, next, a, b)
				} else {
					for l in m.links[p.first_link:][:p.link_count] {
						if int(l.edge) != k || span_count == len(spans) {
							continue
						}
						t0, t1 := f32(l.t_min) / 255, f32(l.t_max) / 255
						spans[span_count] = {t0, t1}
						span_count += 1
						add_visit(&visited, &n, m, center, range_squared, l.polygon, math.lerp(a, b, t0), math.lerp(a, b, t1))
					}
				}
			}
			// The gaps between the spans are wall.
			for x in 1 ..< span_count {
				for y := x; y > 0 && spans[y - 1][0] > spans[y][0]; y -= 1 {
					spans[y - 1], spans[y] = spans[y], spans[y - 1]
				}
			}
			from: f32 = 0
			for x in 0 ..= span_count {
				to: f32 = spans[x][0] if x < span_count else 1
				if to - from > 0.01 {
					s := Segment{math.lerp(a, b, from), math.lerp(a, b, to)}
					if d, _ := distance_to_segment_2d(center, s.a, s.b); d <= range_squared {
						keep(out, &distances, &count, s, d)
					}
				}
				if x < span_count {
					from = max(from, spans[x][1])
				}
			}
		}
	}
	return
}

@(private = "file")
add_visit :: proc(visited: ^[WALL_SEARCH]u32, n: ^int, m: ^Mesh_View, center: [3]f32, range_squared: f32, polygon: u32, a, b: [3]f32) {
	if d, _ := distance_to_segment_2d(center, a, b); d > range_squared || n^ == WALL_SEARCH {
		return
	}
	for v in visited[:n^] {
		if v == polygon {
			return
		}
	}
	visited[n^] = polygon
	n^ += 1
}
