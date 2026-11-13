package nav

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"

// Drawing (see docs/ai/navigation.md#drawing): a volume's navmeshes, each agent type in its own color, paths, and an
// agent's last crowd tick, as debug lines for this frame. The editor's helpers draw the navmeshes in edit mode from the
// cooked blobs and the agents while the game plays, and a game can draw them in its own debug layer.

// The agent types' colors, by their index, around again past the last.
@(private = "file", rodata)
AGENT_COLORS := [?][4]f32 {
	{0.1, 0.8, 1.0, 1},
	{1.0, 0.6, 0.1, 1},
	{0.6, 1.0, 0.2, 1},
	{1.0, 0.3, 0.8, 1},
}

// The tiles' borders, the same for every agent type.
@(private = "file")
TILE_COLOR :: [4]f32{0.5, 0.5, 0.5, 0.5}
// A link across tiles is white over the edge that it covers.
@(private = "file")
LINK_COLOR :: [4]f32{1, 1, 1, 1}
// An agent's corridor, its next corners, the lines to its neighbors, and its desired and chosen velocities.
@(private = "file")
CORRIDOR_COLOR :: [4]f32{0.3, 0.6, 1, 0.5}
@(private = "file")
CORNER_COLOR :: [4]f32{1, 1, 1, 1}
@(private = "file")
NEIGHBOR_COLOR :: [4]f32{1, 0.6, 0.2, 0.7}
@(private = "file")
DESIRED_COLOR :: [4]f32{0.3, 0.6, 1, 1}
@(private = "file")
VELOCITY_COLOR :: [4]f32{0.3, 1, 0.3, 1}
// The velocities' arrows start this high over the agent's feet.
@(private = "file")
ARROW_HEIGHT :: 0.5

// agent_color is an agent type's color: walls at full alpha, and the edges between polygons faint.
agent_color :: proc "contextless" (agent: Agent_Type) -> [4]f32 {
	return AGENT_COLORS[int(agent) % len(AGENT_COLORS)]
}

// draw_volume draws the frame's navmeshes of a volume, by its scene ID: their polygons' edges, faint between two
// polygons and bright where nothing is across, their links across tiles, and their tiles' borders. The lines are
// lifted a cell up, over the floor that the navmesh lies on.
draw_volume :: proc(s: ^State, d: ^debug.Draw, volume: u64) {
	for &m in s.frame {
		if m.id.volume == volume {
			draw_mesh(&m, d)
		}
	}
}

@(private = "file")
draw_mesh :: proc(m: ^Mesh_View, d: ^debug.Draw) {
	lift := [3]f32{0, m.cell_height, 0}
	wall := agent_color(m.id.agent)
	inner := [4]f32{wall.r, wall.g, wall.b, 0.35}
	line :: proc(d: ^debug.Draw, m: ^Mesh_View, a, b: [3]f32, color: [4]f32) {
		debug.line(d, world(m, a), world(m, b), color)
	}
	for p in 0 ..< u32(len(m.polygons)) {
		polygon := &m.polygons[p]
		pts := points_of(m, p)
		tile := tile_of(m, p)
		for k in 0 ..< pts.count {
			a, b := pts.points[k] + lift, pts.points[(k + 1) % pts.count] + lift
			n := polygon.neighbors[k]
			switch {
			case n == format.NAV_NONE:
				line(d, m, a, b, wall)
			case n & format.NAV_EXTERNAL == 0:
				// Each edge between two polygons once, from the first of them.
				if p < tile.first_polygon + u32(n) {
					line(d, m, a, b, inner)
				}
			case:
				line(d, m, a, b, wall)
				for l in m.links[polygon.first_link:][:polygon.link_count] {
					if int(l.edge) == k {
						line(d, m, math.lerp(a, b, f32(l.t_min) / 255), math.lerp(a, b, f32(l.t_max) / 255), LINK_COLOR)
					}
				}
			}
		}
	}
	for &tile in m.tiles {
		if tile.polygon_count == 0 {
			continue
		}
		y := max(f32)
		for v in m.vertices[tile.first_vertex:][:tile.vertex_count] {
			y = min(y, v.y)
		}
		lo, hi := tile.bounds_min, tile.bounds_max
		corners := [4][3]f32{{lo.x, y, lo.z}, {lo.x, y, hi.z}, {hi.x, y, hi.z}, {hi.x, y, lo.z}}
		for k in 0 ..< 4 {
			line(d, m, corners[k] + lift, corners[(k + 1) % 4] + lift, TILE_COLOR)
		}
	}
}

// draw_corners draws a path through its corners, with a small cross at each.
draw_corners :: proc(d: ^debug.Draw, corners: []ecs.World_Position, color: [4]f32) {
	MARK :: 0.1
	for c, i in corners {
		if i > 0 {
			debug.line(d, corners[i - 1], c, color)
		}
		debug.line(d, ecs.position_offset(c, {-MARK, 0, 0}), ecs.position_offset(c, {MARK, 0, 0}), color)
		debug.line(d, ecs.position_offset(c, {0, 0, -MARK}), ecs.position_offset(c, {0, 0, MARK}), color)
	}
}

// draw_path draws an entity's path, Found or Partial, as the paths system last solved it.
draw_path :: proc(s: ^State, w: ^ecs.World, d: ^debug.Draw, e: ecs.Entity, color: [4]f32) {
	draw_corners(d, path_corners(s, w, e), color)
}

// draw_agent draws an agent's last crowd tick: its corridor's polygons, the corners that it steers by, a line to each
// neighbor that it avoids, and its desired and chosen velocities as arrows a second long, from at, where it is shown.
// It returns false for an entity that is not an agent of the crowd.
draw_agent :: proc(s: ^State, w: ^ecs.World, d: ^debug.Draw, e: ecs.Entity, at: ecs.World_Position) -> bool {
	info, m, corridor := crowd_debug(s, w, e)
	if info == nil {
		return false
	}
	if m != nil {
		lift := [3]f32{0, m.cell_height, 0}
		for polygon in corridor {
			pts := points_of(m, polygon)
			for k in 0 ..< pts.count {
				debug.line(d, world(m, pts.points[k] + lift), world(m, pts.points[(k + 1) % pts.count] + lift), CORRIDOR_COLOR)
			}
		}
	}
	draw_corners(d, info.corners[:info.corner_count], CORNER_COLOR)
	for n in info.neighbors[:info.neighbor_count] {
		if t := ecs.get(w, n, ecs.Transform); t != nil {
			debug.line(d, at, t.position, NEIGHBOR_COLOR)
		}
	}
	from := ecs.position_offset(at, {0, ARROW_HEIGHT, 0})
	debug.arrow(d, from, ecs.position_offset(from, info.desired), DESIRED_COLOR)
	debug.arrow(d, from, ecs.position_offset(from, info.velocity), VELOCITY_COLOR)
	return true
}
