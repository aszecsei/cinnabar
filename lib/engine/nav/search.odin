package nav

import "base:runtime"
import "core:math/bits"
import "core:math/linalg"

// The search over a navmesh's polygons, as Detour's dtNavMeshQuery does it, in the engine's own code (see
// docs/ai/navigation.md#queries). A* finds the polygons from the start to the goal, and the funnel pulls the straight
// path through their portals. A search keeps its state in a Search, so the paths system runs it for a few nodes in each
// tick, and a search stops only between nodes, so how many nodes a tick gives it changes when its path is ready and
// never the path.

// Each node's cost is scaled down in the heuristic a little, as Detour's H_SCALE, so the search prefers the nodes
// that it has.
@(private)
H_SCALE :: 0.999

@(private)
NO_NODE :: max(u32)

@(private)
Node_State :: enum u8 {
	New,
	Open,
	Closed,
}

// Node is a polygon that a search reached: from which node, at which point of its portal, and at what cost.
@(private)
Node :: struct {
	polygon:  u32,
	parent:   u32,
	position: [3]f32,
	cost:     f32,
	total:    f32,
	// Its place in the open heap, or -1.
	heap:     i32,
	state:    Node_State,
}

// Graph is a search's nodes, at most max_nodes of them, a table from polygons to nodes, and the open nodes as a heap
// by their total and then their index, so ties fall the same way on every run.
@(private)
Graph :: struct {
	nodes:     [dynamic]Node,
	// A node's index plus one by its polygon, by open addressing. Zero is an empty slot.
	table:     []u32,
	heap:      [dynamic]u32,
	max_nodes: int,
}

@(private)
graph_reserve :: proc(g: ^Graph, max_nodes: int, allocator: runtime.Allocator) {
	g.max_nodes = max(max_nodes, 1)
	g.nodes = make([dynamic]Node, 0, g.max_nodes, allocator)
	g.heap = make([dynamic]u32, 0, g.max_nodes, allocator)
	g.table = make([]u32, int(1) << uint(bits.len(uint(2 * g.max_nodes - 1))), allocator)
}

@(private)
graph_delete :: proc(g: ^Graph) {
	delete(g.nodes)
	delete(g.heap)
	delete(g.table, g.nodes.allocator)
	g^ = {}
}

@(private)
graph_clear :: proc(g: ^Graph) {
	clear(&g.nodes)
	clear(&g.heap)
	for &slot in g.table {
		slot = 0
	}
}

@(private)
graph_slot :: proc "contextless" (g: ^Graph, polygon: u32) -> int {
	mask := len(g.table) - 1
	i := int((polygon * 0x9E3779B1) >> 7) & mask
	for g.table[i] != 0 && g.nodes[g.table[i] - 1].polygon != polygon {
		i = (i + 1) & mask
	}
	return i
}

// graph_node is a polygon's node, which it adds as New if it has none and there is room.
@(private)
graph_node :: proc(g: ^Graph, polygon: u32) -> (index: u32, ok: bool) {
	slot := graph_slot(g, polygon)
	if g.table[slot] != 0 {
		return g.table[slot] - 1, true
	}
	if len(g.nodes) >= g.max_nodes {
		return NO_NODE, false
	}
	append(&g.nodes, Node{polygon = polygon, parent = NO_NODE, heap = -1})
	g.table[slot] = u32(len(g.nodes))
	return u32(len(g.nodes) - 1), true
}

@(private)
graph_find :: proc "contextless" (g: ^Graph, polygon: u32) -> u32 {
	slot := graph_slot(g, polygon)
	return g.table[slot] - 1 if g.table[slot] != 0 else NO_NODE
}

@(private)
heap_less :: proc "contextless" (g: ^Graph, a, b: u32) -> bool {
	na, nb := &g.nodes[a], &g.nodes[b]
	return na.total < nb.total || (na.total == nb.total && a < b)
}

@(private)
heap_set :: proc "contextless" (g: ^Graph, at: int, node: u32) {
	g.heap[at] = node
	g.nodes[node].heap = i32(at)
}

@(private)
heap_up :: proc "contextless" (g: ^Graph, at: int) {
	i := at
	node := g.heap[i]
	for i > 0 {
		parent := (i - 1) / 2
		if !heap_less(g, node, g.heap[parent]) {
			break
		}
		heap_set(g, i, g.heap[parent])
		i = parent
	}
	heap_set(g, i, node)
}

@(private)
heap_down :: proc "contextless" (g: ^Graph, at: int) {
	i := at
	node := g.heap[i]
	n := len(g.heap)
	for {
		child := 2 * i + 1
		if child >= n {
			break
		}
		if child + 1 < n && heap_less(g, g.heap[child + 1], g.heap[child]) {
			child += 1
		}
		if !heap_less(g, g.heap[child], node) {
			break
		}
		heap_set(g, i, g.heap[child])
		i = child
	}
	heap_set(g, i, node)
}

// heap_push opens a node, or moves an open one up after its total fell.
@(private)
heap_push :: proc(g: ^Graph, node: u32) {
	n := &g.nodes[node]
	if n.heap >= 0 {
		heap_up(g, int(n.heap))
		return
	}
	n.state = .Open
	append(&g.heap, node)
	heap_up(g, len(g.heap) - 1)
}

@(private)
heap_pop :: proc(g: ^Graph) -> u32 {
	top := g.heap[0]
	last := pop(&g.heap)
	if len(g.heap) > 0 {
		heap_set(g, 0, last)
		heap_down(g, 0)
	}
	g.nodes[top].heap = -1
	return top
}

// Search_State is where a search is.
@(private)
Search_State :: enum u8 {
	// It has open nodes left.
	Running,
	// It reached the goal's polygon.
	Reached,
	// It has no open nodes left: the goal is not reachable, or the node budget ran out on the way.
	Exhausted,
}

// Search is an A* search from a point on the start polygon to a goal, which goal_polygon holds, or NO_POLYGON for a
// goal that no polygon holds, which the search can only come near.
@(private)
Search :: struct {
	graph:          Graph,
	start, goal:    [3]f32,
	start_polygon:  u32,
	goal_polygon:   u32,
	// The node nearest the goal by its heuristic, where a partial path ends. An earlier node keeps a tie.
	best:           u32,
	best_heuristic: f32,
	state:          Search_State,
	// The nodes that the search expanded, for the tick's budget and the tests.
	expanded:       int,
}

@(private)
search_begin :: proc(sr: ^Search, start, goal: [3]f32, start_polygon, goal_polygon: u32) {
	g := &sr.graph
	graph_clear(g)
	sr.start, sr.goal = start, goal
	sr.start_polygon, sr.goal_polygon = start_polygon, goal_polygon
	sr.expanded = 0
	sr.state = .Running
	first, _ := graph_node(g, start_polygon)
	n := &g.nodes[first]
	n.position = start
	n.total = linalg.distance(start, goal) * H_SCALE
	heap_push(g, first)
	sr.best, sr.best_heuristic = first, n.total
}

// search_step expands at most expansions nodes, and gives whether the search is done.
@(private)
search_step :: proc(sr: ^Search, m: ^Mesh_View, expansions: int) -> (done: bool) {
	g := &sr.graph
	for _ in 0 ..< expansions {
		if sr.state != .Running {
			break
		}
		if len(g.heap) == 0 {
			sr.state = .Exhausted
			break
		}
		current := heap_pop(g)
		g.nodes[current].state = .Closed
		sr.expanded += 1
		if g.nodes[current].polygon == sr.goal_polygon {
			sr.best = current
			sr.state = .Reached
			break
		}
		from := g.nodes[current]
		it := portals(m, from.polygon)
		for portal in next_portal(&it) {
			if from.parent != NO_NODE && portal.neighbor == g.nodes[from.parent].polygon {
				continue
			}
			next, ok := graph_node(g, portal.neighbor)
			if !ok {
				continue
			}
			n := &g.nodes[next]
			// A new node is at the middle of the portal that first reaches it.
			if n.state == .New {
				n.position = (portal.left + portal.right) * 0.5
			}
			cost, heuristic: f32
			if portal.neighbor == sr.goal_polygon {
				cost = from.cost + linalg.distance(from.position, n.position) + linalg.distance(n.position, sr.goal)
			} else {
				cost = from.cost + linalg.distance(from.position, n.position)
				heuristic = linalg.distance(n.position, sr.goal) * H_SCALE
			}
			total := cost + heuristic
			if n.state != .New && total >= n.total {
				continue
			}
			n.parent, n.cost, n.total = current, cost, total
			heap_push(g, next)
			if heuristic < sr.best_heuristic {
				sr.best, sr.best_heuristic = next, heuristic
			}
		}
	}
	return sr.state != .Running
}

// search_finish gives a done search's path: Found to the goal, or Partial to the point of the nearest polygon that it
// reached nearest the goal. corners and corridor are in allocator.
@(private)
search_finish :: proc(sr: ^Search, m: ^Mesh_View, allocator: runtime.Allocator) -> (status: Path_Status, corners: [][3]f32, corridor: []u32) {
	g := &sr.graph
	count := 0
	for n := sr.best; n != NO_NODE; n = g.nodes[n].parent {
		count += 1
	}
	corridor = make([]u32, count, allocator)
	for n, i := sr.best, count - 1; n != NO_NODE; n, i = g.nodes[n].parent, i - 1 {
		corridor[i] = g.nodes[n].polygon
	}
	end := sr.goal
	if sr.state == .Reached {
		status = .Found
	} else {
		status = .Partial
		end, _ = closest_on_polygon(m, corridor[count - 1], sr.goal)
	}
	corners = straight_path(m, sr.start, end, corridor, allocator)
	return
}

// straight_path pulls a path through the portals of a corridor of polygons, from start on the first to end on the
// last, with the funnel of Detour's findStraightPath. Its corners start with start and end with end.
@(private)
straight_path :: proc(m: ^Mesh_View, start, end: [3]f32, corridor: []u32, allocator: runtime.Allocator) -> [][3]f32 {
	out := make([dynamic][3]f32, 0, len(corridor) + 1, allocator)
	add :: proc(out: ^[dynamic][3]f32, p: [3]f32) {
		if len(out) == 0 || !equal_points(out[len(out) - 1], p) {
			append(out, p)
		}
	}
	add(&out, start)
	if len(corridor) > 1 {
		apex, left, right := start, start, start
		apex_index, left_index, right_index := 0, 0, 0
		for i := 0; i < len(corridor); i += 1 {
			next_left, next_right: [3]f32
			if i + 1 < len(corridor) {
				portal, ok := portal_between(m, corridor[i], corridor[i + 1])
				if !ok {
					// The corridor is broken: it ends at the nearest point of the last polygon that it reached.
					q, _ := closest_on_polygon(m, corridor[i], end)
					add(&out, q)
					return out[:]
				}
				next_left, next_right = portal.left, portal.right
				// A start on the first portal would make the funnel empty.
				if i == 0 {
					if d, _ := distance_to_segment_2d(apex, next_left, next_right); d < EQUAL_DISTANCE * EQUAL_DISTANCE {
						continue
					}
				}
			} else {
				next_left, next_right = end, end
			}
			if tri_area_2d(apex, right, next_right) <= 0 {
				if equal_points(apex, right) || tri_area_2d(apex, left, next_right) > 0 {
					right, right_index = next_right, i
				} else {
					apex, apex_index = left, left_index
					add(&out, apex)
					left, right = apex, apex
					left_index, right_index = apex_index, apex_index
					i = apex_index
					continue
				}
			}
			if tri_area_2d(apex, left, next_left) >= 0 {
				if equal_points(apex, left) || tri_area_2d(apex, right, next_left) < 0 {
					left, left_index = next_left, i
				} else {
					apex, apex_index = right, right_index
					add(&out, apex)
					left, right = apex, apex
					left_index, right_index = apex_index, apex_index
					i = apex_index
					continue
				}
			}
		}
	}
	add(&out, end)
	return out[:]
}
