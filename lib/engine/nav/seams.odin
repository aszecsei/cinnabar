package nav

import "core:slice"

import format "cinnabar:engine/asset/format"

// Seams (see docs/ai/navigation.md#seams): where two loaded navmeshes of an agent type meet, their edges are joined
// as the cooker joins a navmesh's tiles. Each navmesh is baked from its own scene, and its edges on its bounds are
// border edges, NAV_EXTERNAL toward a tile that it does not have, with no link. Where another navmesh's bounds face
// touches that side, within a cell, its border edges on the facing side are across them, with format.nav_edge_overlap
// telling which parts. prepare joins them again whenever a navmesh loads, unloads or is recooked.

// Seam_Link is a seam link from a polygon's edge to another mesh's polygon, over the part of the edge that it covers,
// out of 255, as a Nav_Link is.
Seam_Link :: struct {
	polygon:      u32,
	edge:         u8,
	t_min, t_max: u8,
	to:           Poly,
}

// seams_of is the seam links from a polygon of a mesh, in its edges' order.
@(private)
seams_of :: proc "contextless" (m: ^Mesh_View, polygon: u32) -> []Seam_Link {
	lo, hi := 0, len(m.seams)
	for lo < hi {
		mid := (lo + hi) / 2
		if m.seams[mid].polygon < polygon {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	end := lo
	for end < len(m.seams) && m.seams[end].polygon == polygon {
		end += 1
	}
	return m.seams[lo:end]
}

// join_seams makes the seam links of the views, in s.seams, and gives each view its run of them. The views are those
// whose stamps s.seam_stamps holds.
@(private)
join_seams :: proc(s: ^State, views: []Mesh_View) {
	clear(&s.seams)
	resize(&s.seam_runs, len(views))
	for &a in views {
		start := len(s.seams)
		if a.stamp != {} {
			for &b in views {
				if b.stamp != {} && b.slot != a.slot && b.id.agent == a.id.agent {
					join_pair(s, views, &a, &b)
				}
			}
		}
		run := s.seams[start:]
		slice.sort_by(run, proc(x, y: Seam_Link) -> bool {
			if x.polygon != y.polygon {
				return x.polygon < y.polygon
			}
			if x.edge != y.edge {
				return x.edge < y.edge
			}
			if x.to.slot != y.to.slot {
				return x.to.slot < y.to.slot
			}
			return x.to.polygon < y.to.polygon
		})
		s.seam_runs[a.slot] = {u32(start), u32(len(s.seams))}
	}
	for &v in views {
		run := s.seam_runs[v.slot]
		v.seams = s.seams[run[0]:run[1]]
	}
}

// join_pair adds the seam links from a's border edges to b's, on each side of a whose bounds face touches b's
// opposite face.
@(private = "file")
join_pair :: proc(s: ^State, views: []Mesh_View, a, b: ^Mesh_View) {
	n := Net {
		views  = views,
		origin = a.anchor,
	}
	o := offset(&n, b)
	gap := max(a.cell_size, b.cell_size)
	b_min, b_max := b.bounds_min + o, b.bounds_max + o
	// The faces must share some of their extent across, and of their height.
	if b_min.y > a.bounds_max.y || b_max.y < a.bounds_min.y {
		return
	}
	climb := max(a.climb, b.climb) + max(a.cell_height, b.cell_height)
	for side in format.Nav_Side {
		touching: bool
		switch side {
		case .West:
			touching =
				abs(a.bounds_min.x - b_max.x) <= gap &&
				b_min.z < a.bounds_max.z &&
				b_max.z > a.bounds_min.z
		case .East:
			touching =
				abs(a.bounds_max.x - b_min.x) <= gap &&
				b_min.z < a.bounds_max.z &&
				b_max.z > a.bounds_min.z
		case .South:
			touching =
				abs(a.bounds_min.z - b_max.z) <= gap &&
				b_min.x < a.bounds_max.x &&
				b_max.x > a.bounds_min.x
		case .North:
			touching =
				abs(a.bounds_max.z - b_min.z) <= gap &&
				b_min.x < a.bounds_max.x &&
				b_max.x > a.bounds_min.x
		}
		if !touching {
			continue
		}
		opposite := format.Nav_Side((u16(side) + 2) % 4)
		for &tile in a.tiles {
			if !on_side(a, &tile, side) {
				continue
			}
			for pi in tile.first_polygon ..< tile.first_polygon + tile.polygon_count {
				join_polygon(s, &n, a, pi, side, b, opposite, climb, gap)
			}
		}
	}
}

// join_polygon adds the seam links from a polygon's border edges on a side to b's border edges on the opposite side.
@(private = "file")
join_polygon :: proc(
	s: ^State,
	n: ^Net,
	a: ^Mesh_View,
	polygon: u32,
	side: format.Nav_Side,
	b: ^Mesh_View,
	opposite: format.Nav_Side,
	climb, gap: f32,
) {
	p := &a.polygons[polygon]
	pts := net_points(n, {a.slot, polygon})
	for k in 0 ..< pts.count {
		if p.neighbors[k] != format.NAV_EXTERNAL | u16(side) {
			continue
		}
		e0, e1 := pts.points[k], pts.points[(k + 1) % pts.count]
		for &tile in b.tiles {
			if !on_side(b, &tile, opposite) {
				continue
			}
			for qi in tile.first_polygon ..< tile.first_polygon + tile.polygon_count {
				q := &b.polygons[qi]
				qpts := net_points(n, {b.slot, qi})
				for m in 0 ..< qpts.count {
					if q.neighbors[m] != format.NAV_EXTERNAL | u16(opposite) {
						continue
					}
					c, d := qpts.points[m], qpts.points[(m + 1) % qpts.count]
					t_min, t_max, ok := format.nav_edge_overlap(
						e0,
						e1,
						c,
						d,
						side,
						climb,
						a.cell_size,
						gap,
					)
					if ok {
						append(
							&s.seams,
							Seam_Link {
								polygon = polygon,
								edge = u8(k),
								t_min = t_min,
								t_max = t_max,
								to = {b.slot, qi},
							},
						)
					}
				}
			}
		}
	}
}

// on_side is whether a tile is on a side of its mesh's grid, where its border edges face out.
@(private = "file")
on_side :: proc "contextless" (
	m: ^Mesh_View,
	tile: ^format.Nav_Tile,
	side: format.Nav_Side,
) -> bool {
	switch side {
	case .West:
		return tile.x == 0
	case .East:
		return tile.x + 1 == m.tiles_x
	case .South:
		return tile.z == 0
	case .North:
		return tile.z + 1 == m.tiles_z
	}
	return false
}
