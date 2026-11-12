package nav

import "core:math"
import "core:math/linalg"
import "core:testing"

import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/random"

@(private = "file")
near :: proc(a, b: [3]f32, within: f32 = 0.01) -> bool {
	return linalg.length(a - b) <= within
}

@(private = "file")
near_2d :: proc(a, b: [3]f32, within: f32 = 0.01) -> bool {
	return linalg.length(a.xz - b.xz) <= within
}

// walkable is whether every leg of a path stays on the navmesh, sampled every few centimeters. A leg can run along a
// wall's edge, where a raycast stops, as Detour's does.
@(private = "file")
walkable :: proc(s: ^State, corners: []ecs.World_Position) -> bool {
	for i in 1 ..< len(corners) {
		a, b := meters(corners[i - 1]), meters(corners[i])
		steps := int(linalg.length(b - a) / 0.05) + 1
		for k in 0 ..= steps {
			p := linalg.lerp(a, b, f32(k) / f32(steps))
			if _, on := nearest(s, at(f64(p.x), f64(p.y), f64(p.z)), {0.001, 0.5, 0.001}, 0); !on {
				return false
			}
		}
	}
	return true
}

@(test)
a_path_goes_around_a_wall :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	start, goal := at(2.5, 0, 2.5), at(9.5, 0, 5.5)
	path := find_path(s, start, goal, 0)
	testing.expect_value(t, path.status, Path_Status.Found)
	if !testing.expect(t, len(path.corners) >= 3) {
		return
	}
	testing.expect(t, near(meters(path.corners[0]), {2.5, 0, 2.5}))
	testing.expect(t, near(meters(path.corners[len(path.corners) - 1]), {9.5, 0, 5.5}))
	// It turns at the wall's end, by the gap at z = 7.
	turns := false
	for c in path.corners[1:len(path.corners) - 1] {
		p := meters(c)
		turns ||= near_2d(p, {6, 0, 7}) || near_2d(p, {7, 0, 7})
	}
	testing.expect(t, turns, "the path does not turn at the wall's end")
	testing.expect(t, walkable(s, path.corners), "a leg of the path goes through the wall")
	// The raw line goes through the wall.
	hit, _ := raycast(s, start, goal, 0)
	testing.expect(t, hit.wall != nil)
}

@(test)
a_path_crosses_tiles :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	path := find_path(s, at(0.5, 0, 0.5), at(5.5, 0, 6.5), 0)
	testing.expect_value(t, path.status, Path_Status.Found)
	// A clear line: the start and the goal.
	testing.expect_value(t, len(path.corners), 2)
	seen: [6]bool
	m := &s.frame[0]
	for p in path.corridor {
		tile := tile_of(m, p)
		seen[tile.z * m.tiles_x + tile.x] = true
	}
	count := 0
	for v in seen {
		count += 1 if v else 0
	}
	testing.expectf(t, count >= 3, "the corridor crosses %d tiles", count)
}

@(test)
a_path_crosses_a_seam_only_where_its_link_reaches :: proc(t: ^testing.T) {
	// One row of 8 cells in two tiles, whose seam at x = 4 links only z = 0 to 0.5.
	s := frame_of(grid_blob({cells_x = 8, cells_z = 1, tile_cells = 4, half_seams = true}, "Human", 0))
	path := find_path(s, at(0.5, 0, 0.9), at(7.5, 0, 0.9), 0)
	testing.expect_value(t, path.status, Path_Status.Found)
	dips := false
	for c in path.corners {
		p := meters(c)
		dips ||= abs(p.x - 4) < 0.01 && p.z <= 0.51
	}
	testing.expect(t, dips, "the path does not cross the seam where its link is")
	// A walk along z = 0.9 stops at the seam, where nothing is across.
	hit, ok := raycast(s, at(0.5, 0, 0.9), at(7.5, 0, 0.9), 0)
	testing.expect(t, ok)
	testing.expect(t, hit.wall != nil)
	testing.expect(t, near(meters(hit.position), {4, 0, 0.9}))
	// Along z = 0.2 it crosses.
	hit, _ = raycast(s, at(0.5, 0, 0.2), at(7.5, 0, 0.2), 0)
	testing.expect(t, hit.wall == nil)
}

@(test)
an_unreachable_goal_gives_a_partial_path :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	path := find_path(s, at(2.5, 0, 2.5), at(9.5, 0, 1.5), 0)
	testing.expect_value(t, path.status, Path_Status.Partial)
	if !testing.expect(t, len(path.corners) >= 2) {
		return
	}
	// It ends at the edge of the nearest reachable cell, beside the ring around the island.
	end := meters(path.corners[len(path.corners) - 1])
	testing.expectf(t, abs(end.x - 8) < 0.01 && end.z >= 1 && end.z <= 2, "it ends at %v", end)
	testing.expect(t, walkable(s, path.corners))
	for p in path.corridor {
		testing.expect(t, !is_island(&s.frame[0], p))
	}
}

@(test)
a_goal_off_the_mesh_gives_a_partial_path_toward_it :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	// Inside the wall, above the agent's reach.
	path := find_path(s, at(2.5, 0, 3.5), at(6.5, 5, 3.5), 0)
	testing.expect_value(t, path.status, Path_Status.Partial)
	end := meters(path.corners[len(path.corners) - 1])
	testing.expectf(t, linalg.length(end.xz - {6.5, 3.5}) <= 0.51, "it ends at %v", end)
	testing.expect(t, walkable(s, path.corners))
}

@(test)
a_node_budget_gives_a_partial_path :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	path := find_path(s, at(2.5, 0, 2.5), at(9.5, 0, 5.5), 0, max_nodes = 4)
	testing.expect_value(t, path.status, Path_Status.Partial)
	testing.expect(t, len(path.corridor) <= 4)
	testing.expect(t, walkable(s, path.corners))
}

@(test)
a_start_off_every_mesh_fails :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	testing.expect_value(t, find_path(s, at(-5, 0, -5), at(2.5, 0, 2.5), 0).status, Path_Status.Failed)
	testing.expect_value(t, find_path(s, at(2.5, 0, 2.5), at(3.5, 0, 2.5), 7).status, Path_Status.Failed)
}

@(test)
a_raycast_stops_at_a_wall :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	hit, ok := raycast(s, at(2.5, 0, 2.5), at(9.5, 0, 2.5), 0)
	testing.expect(t, ok)
	testing.expect(t, abs(hit.t - 0.5) < 1e-4)
	normal, walled := hit.wall.?
	testing.expect(t, walled)
	testing.expect(t, near(normal, {-1, 0, 0}, 1e-4))
	testing.expect(t, near(meters(hit.position), {6, 0, 2.5}))
}

@(test)
a_raycast_reaches_its_end_across_tiles :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	hit, ok := raycast(s, at(0.5, 0, 0.5), at(5.5, 0, 1.5), 0)
	testing.expect(t, ok)
	testing.expect(t, hit.wall == nil)
	testing.expect_value(t, hit.t, 1)
	testing.expect(t, near(meters(hit.position), {5.5, 0, 1.5}))
	m := &s.frame[0]
	testing.expect_value(t, tile_of(m, hit.polygon).x, 1)
}

@(test)
nearest_snaps_to_the_floor_and_its_edges :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	// On the ramp, its height.
	on, ok := nearest(s, at(1.5, 1, 6.5), {1, 1, 1}, 0)
	testing.expect(t, ok)
	testing.expect(t, near(meters(on.position), {1.5, 0.625, 6.5}))
	// In the wall, the edge of the first polygon beside it.
	on, ok = nearest(s, at(6.4, 0, 2.5), {1, 1, 1}, 0)
	testing.expect(t, ok)
	testing.expect(t, near(meters(on.position), {6, 0, 2.5}))
	// Too far from any.
	_, ok = nearest(s, at(6.5, 0, 2.5), {0.2, 1, 0.2}, 0)
	testing.expect(t, !ok)
	// Above the floor by less than the climb, the point under it.
	on, ok = nearest(s, at(2.5, 0.3, 2.5), {0.5, 1, 0.5}, 0)
	testing.expect(t, ok)
	testing.expect(t, near(meters(on.position), {2.5, 0, 2.5}))
}

@(test)
random_points_are_reachable_and_near_the_circle :: proc(t: ^testing.T) {
	s := frame_of(standard_grid())
	draw :: proc(s: ^State, seed: u64) -> [200]Location {
		g: random.State
		random.seed(&g, seed)
		out: [200]Location
		for &l in out {
			l, _ = random_point(s, at(7.5, 0, 2.5), 3, 0, &g)
		}
		return out
	}
	a, b := draw(s, 11), draw(s, 11)
	m := &s.frame[0]
	spread: [2]f32 = {max(f32), -max(f32)}
	for l, i in a {
		testing.expect_value(t, b[i], l)
		p := meters(l.position)
		testing.expect(t, !is_island(m, l.polygon), "a point on the island")
		testing.expectf(t, linalg.length(p.xz - {7.5, 2.5}) <= 3 + math.SQRT_TWO, "%v is far from the circle", p)
		on, found := nearest(s, l.position, {0.01, 0.5, 0.01}, 0)
		testing.expect(t, found && on.polygon == l.polygon)
		spread = {min(spread[0], p.z), max(spread[1], p.z)}
	}
	// The wall cuts the circle: points are found on its far side only through the gap, beyond the radius, so none.
	testing.expect(t, spread[1] - spread[0] > 1)
	c := draw(s, 12)
	testing.expect(t, c != a)
}

@(test)
agent_types_pick_their_mesh :: proc(t: ^testing.T) {
	s := frame_of(standard_grid("Human", 0), standard_grid("Small", 1, wall = false))
	small, ok := agent_type(s, "Small")
	testing.expect(t, ok)
	testing.expect_value(t, small, 1)
	_, ok = agent_type(s, "Large")
	testing.expect(t, !ok)
	start, goal := at(2.5, 0, 2.5), at(9.5, 0, 5.5)
	around := find_path(s, start, goal, 0)
	open := find_path(s, start, goal, small)
	testing.expect_value(t, open.status, Path_Status.Found)
	testing.expect_value(t, open.mesh.agent, small)
	testing.expect_value(t, around.mesh.agent, 0)
	// Without the wall, the path is shorter than around it.
	testing.expect(t, length_of(open.corners) + 2 < length_of(around.corners))
}

@(private = "file")
length_of :: proc(corners: []ecs.World_Position) -> (length: f32) {
	for i in 1 ..< len(corners) {
		length += linalg.length(meters(corners[i]) - meters(corners[i - 1]))
	}
	return
}

@(test)
a_volume_draws_its_edges_links_and_tiles :: proc(t: ^testing.T) {
	when !debug.DEBUG_DRAW {
		return
	}
	// One row of 8 cells in two tiles: 3 edges between cells in each tile, 2 walls on each cell's long sides and one at
	// each end, the 2 sides of the seam as walls with a link over each, and 4 sides of each tile.
	s := frame_of(grid_blob({cells_x = 8, cells_z = 1, tile_cells = 4, half_seams = true}, "Human", 0))
	d: debug.Draw
	debug.init(&d, context.allocator)
	defer debug.destroy(&d)
	draw_volume(s, &d, 0x100)
	testing.expect_value(t, len(debug.frame_lines(&d)), 6 + 16 + 2 + 2 + 2 + 8)
	debug.end_frame(&d)
	draw_volume(s, &d, 0x200)
	testing.expect_value(t, len(debug.frame_lines(&d)), 0)
	path := find_path(s, at(0.5, 0, 0.9), at(7.5, 0, 0.9), 0)
	draw_corners(&d, path.corners, {1, 1, 1, 1})
	testing.expect_value(t, len(debug.frame_lines(&d)), 3 * len(path.corners) - 1)
}
