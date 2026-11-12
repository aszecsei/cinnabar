package nav

import "base:runtime"
import "core:log"

import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// Path requests (see docs/ai/navigation.md#path-requests). request_path asks for an entity's path to a goal, and the
// paths system, a Fixed system, solves the requests in their order, a few searches at a time on jobs, with a budget of
// searched nodes in each tick that they share. A search runs over as many ticks as its nodes need, and stops only
// between nodes, so its path is the same on one job or many and with any budget: only the tick that it is ready in
// changes. The path is kept in the state's pool, keyed by the slot in the entity's Nav_Path.

// The searches that run at once, the nodes that they search in a tick together by default, and the nodes that one
// search may reach before it gives its best partial path.
MAX_ACTIVE_SEARCHES :: 8
DEFAULT_TICK_NODES :: 1024
MAX_PATH_NODES :: DEFAULT_MAX_NODES

// Path_Request is an entity's request for a path to a goal. The path starts where the entity is when its search
// starts.
Path_Request :: struct {
	entity: ecs.Entity,
	goal:   ecs.World_Position,
}

// Requests is where requests are recorded: frame code's list, or a system's job's.
Requests :: struct {
	list: ^[dynamic]Path_Request,
}

// requests is frame code's: the requests that the next tick admits.
requests :: proc(s: ^State) -> Requests {
	return {&s.pending}
}

// job_requests is a system's job's own list, which the world flushes after the stage in system order and then job
// order, so requests keep an order that does not depend on the jobs' timing.
job_requests :: proc(s: ^State, ctx: ^ecs.System_Context) -> Requests {
	return {(^[dynamic]Path_Request)(ecs.job_buffer(ctx, s.job_requests))}
}

// request_path asks for an entity's path to goal, on the navmeshes of its Nav_Path's agent type. A new request
// replaces the entity's last one. The entity's Nav_Path is Pending from the next tick until its path is solved.
request_path :: proc(to: Requests, e: ecs.Entity, goal: ecs.World_Position) {
	append(to.list, Path_Request{e, goal})
}

// path_corners is an entity's path, Found or Partial, from its start to its end, or nil. It stays valid until the
// paths system runs again.
path_corners :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> []ecs.World_Position {
	slot, ok := solved_slot(s, w, e)
	return slot.phase.(Path_Solved).corners[:] if ok else nil
}

// path_corridor is the navmesh and the polygons that an entity's path crosses, or nil.
path_corridor :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (Mesh_Id, []u32) {
	slot, ok := solved_slot(s, w, e)
	if !ok {
		return {}, nil
	}
	solved := slot.phase.(Path_Solved)
	return solved.mesh, solved.corridor[:]
}

@(private)
solved_slot :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (^Path_Slot, bool) {
	np := ecs.get(w, e, Nav_Path) if ecs.is_alive(w, e) else nil
	if np == nil {
		return nil, false
	}
	slot := slot_of(s, np.path)
	if slot == nil || slot.entity != e {
		return nil, false
	}
	_, solved := slot.phase.(Path_Solved)
	return slot, solved
}

// The phases of a path in the pool. A slot whose phase is nil is free.
Path_Queued :: struct {}
Path_Searching :: struct {
	// Its search in the state's searches.
	search: int,
}
Path_Solved :: struct {
	status:   Path_Status,
	mesh:     Mesh_Id,
	// The navmesh's blob that it was found on, which a recook changes.
	stamp:    Mesh_Stamp,
	corners:  [dynamic]ecs.World_Position,
	corridor: [dynamic]u32,
}
Path_Failed :: struct {}

Path_Phase :: union {
	Path_Queued,
	Path_Searching,
	Path_Solved,
	Path_Failed,
}

Path_Slot :: struct {
	entity: ecs.Entity,
	agent:  Agent_Type,
	goal:   ecs.World_Position,
	// set_phase is its only writer.
	phase:  Path_Phase,
}

// Path_Pool is the paths by slot, with a generation for each, which freeing the slot changes, so a stale handle
// finds nothing.
Path_Pool :: struct {
	slots:       [dynamic]Path_Slot,
	generations: [dynamic]u32,
	free:        [dynamic]u32,
}

// Active_Search is a search that runs, the path that it is for, and the navmesh that it runs on. owner is zero when it
// is free.
@(private)
Active_Search :: struct {
	search: Search,
	owner:  Path_Handle,
	mesh:   Mesh_Id,
	stamp:  Mesh_Stamp,
}

@(private)
slot_of :: proc(s: ^State, h: Path_Handle) -> ^Path_Slot {
	if h.generation == 0 || int(h.index) >= len(s.paths.slots) || s.paths.generations[h.index] != h.generation {
		return nil
	}
	slot := &s.paths.slots[h.index]
	return slot if slot.phase != nil else nil
}

@(private)
alloc_slot :: proc(s: ^State) -> Path_Handle {
	p := &s.paths
	if n := len(p.free); n > 0 {
		index := pop(&p.free)
		return {index, p.generations[index]}
	}
	append(&p.slots, Path_Slot{})
	append(&p.generations, 1)
	return {u32(len(p.slots) - 1), 1}
}

// free_slot frees a path, its search or its corners with it, and takes it out of the queue.
@(private)
free_slot :: proc(s: ^State, index: u32) {
	slot := &s.paths.slots[index]
	release_phase(s, slot)
	slot^ = {}
	g := &s.paths.generations[index]
	g^ += 1
	if g^ == 0 {
		g^ = 1
	}
	append(&s.paths.free, index)
	unqueue(s, index)
}

@(private)
unqueue :: proc(s: ^State, index: u32) {
	for h, i in s.queue {
		if h.index == index {
			ordered_remove(&s.queue, i)
			return
		}
	}
}

// release_phase frees what a slot's phase holds: its search, or its corners.
@(private)
release_phase :: proc(s: ^State, slot: ^Path_Slot) {
	#partial switch &p in slot.phase {
	case Path_Searching:
		s.searches[p.search].owner = {}
	case Path_Solved:
		delete(p.corners)
		delete(p.corridor)
	}
}

// set_phase is the only writer of a path's phase. It frees what the old phase held, and shows the new one in the
// entity's Nav_Path.
@(private)
set_phase :: proc(s: ^State, w: ^ecs.World, h: Path_Handle, phase: Path_Phase) {
	slot := &s.paths.slots[h.index]
	release_phase(s, slot)
	slot.phase = phase
	status := Path_Status.Pending
	corners: u32
	switch p in phase {
	case Path_Queued, Path_Searching:
	case Path_Solved:
		status, corners = p.status, u32(len(p.corners))
	case Path_Failed:
		status = .Failed
	case nil:
		status = .None
	}
	if np := ecs.get_write(w, slot.entity, Nav_Path); np != nil {
		np.status, np.corners, np.path = status, corners, h
	}
}

@(private)
make_job_requests :: proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
	list := new([dynamic]Path_Request, allocator)
	list^ = make([dynamic]Path_Request, allocator)
	return list
}

@(private)
flush_job_requests :: proc(user: rawptr, buffers: []rawptr) {
	s := (^State)(user)
	for b in buffers {
		append(&s.pending, ..(^[dynamic]Path_Request)(b)[:])
	}
}

// tick_paths is the paths system: it lets go of the paths whose entities went, admits the new requests, finds again
// the paths on navmeshes that changed, starts the first searches of the queue, runs them for their share of the
// tick's budget, one job each, and gives the paths of those that finished, in the queue's order.
@(private)
tick_paths :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	check_paths(s, w)
	admit_requests(s, w)
	revalidate_paths(s, w)
	start_searches(s, w)
	run_searches(s, w)
	finish_searches(s, w)
}

// check_paths frees the paths of entities that are gone, that lost their Nav_Path, or whose Nav_Path names another
// slot, and clears a Nav_Path that names a slot that is not its own, as a copy of an entity's does.
@(private)
check_paths :: proc(s: ^State, w: ^ecs.World) {
	for i in 0 ..< u32(len(s.paths.slots)) {
		slot := &s.paths.slots[i]
		if slot.phase == nil {
			continue
		}
		np := ecs.get(w, slot.entity, Nav_Path) if ecs.is_alive(w, slot.entity) else nil
		if np == nil || np.path != {i, s.paths.generations[i]} {
			free_slot(s, i)
		}
	}
	stale := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	it := ecs.query_iter(w, s.agents)
	for view in ecs.query_next(&it) {
		for np, i in ecs.column(view, 0, Nav_Path) {
			if np.path == {} && np.status == .None {
				continue
			}
			slot := slot_of(s, np.path)
			e := ecs.entities(view)[i]
			if slot == nil || slot.entity != e {
				append(&stale, e)
			}
		}
	}
	for e in stale {
		np := ecs.get_write(w, e, Nav_Path)
		np.status, np.corners, np.path = .None, 0, {}
	}
}

@(private)
admit_requests :: proc(s: ^State, w: ^ecs.World) {
	for r in s.pending {
		np := ecs.get(w, r.entity, Nav_Path) if ecs.is_alive(w, r.entity) else nil
		if np == nil {
			log.warnf("nav: a path was asked for entity %v, which has no Nav_Path", r.entity)
			continue
		}
		h := np.path
		if slot := slot_of(s, h); slot == nil || slot.entity != r.entity {
			h = alloc_slot(s)
		} else {
			unqueue(s, h.index)
		}
		slot := &s.paths.slots[h.index]
		slot.entity, slot.agent, slot.goal = r.entity, np.agent, r.goal
		set_phase(s, w, h, Path_Queued{})
		append(&s.queue, h)
	}
	clear(&s.pending)
}

// revalidate_paths queues again, at the end, the solved paths whose navmesh was recooked or unloaded, and starts
// again, in place, the searches on one.
@(private)
revalidate_paths :: proc(s: ^State, w: ^ecs.World) {
	for i in 0 ..< u32(len(s.paths.slots)) {
		slot := &s.paths.slots[i]
		h := Path_Handle{i, s.paths.generations[i]}
		#partial switch p in slot.phase {
		case Path_Solved:
			if m := mesh_of(s, p.mesh); m == nil || m.stamp != p.stamp {
				set_phase(s, w, h, Path_Queued{})
				append(&s.queue, h)
			}
		case Path_Searching:
			a := &s.searches[p.search]
			if m := mesh_of(s, a.mesh); m == nil || m.stamp != a.stamp {
				set_phase(s, w, h, Path_Queued{})
			}
		}
	}
}

// start_searches starts a search for each Queued path among the first MAX_ACTIVE_SEARCHES of the queue, from where its
// entity is now. One whose entity is on no navmesh of its agent type fails.
@(private)
start_searches :: proc(s: ^State, w: ^ecs.World) {
	i := 0
	for i < min(len(s.queue), MAX_ACTIVE_SEARCHES) {
		h := s.queue[i]
		slot := &s.paths.slots[h.index]
		if _, queued := slot.phase.(Path_Queued); !queued {
			i += 1
			continue
		}
		transform := ecs.get(w, slot.entity, ecs.Transform)
		m: ^Mesh_View
		polygon: u32
		from: [3]f32
		ok := transform != nil
		if ok {
			m, polygon, from, ok = snap(s, transform.position, slot.agent)
		}
		if !ok {
			set_phase(s, w, h, Path_Failed{})
			ordered_remove(&s.queue, i)
			continue
		}
		free := 0
		for s.searches[free].owner != {} {
			free += 1
		}
		a := &s.searches[free]
		a.owner, a.mesh, a.stamp = h, m.id, m.stamp
		begin_toward(&a.search, m, from, polygon, slot.goal)
		set_phase(s, w, h, Path_Searching{free})
		i += 1
	}
}

@(private)
Search_Job :: struct {
	search:     ^Search,
	mesh:       ^Mesh_View,
	expansions: int,
}

@(private)
search_job :: proc(data: rawptr) {
	j := (^Search_Job)(data)
	search_step(j.search, j.mesh, j.expansions)
}

// run_searches runs each search for its share of the tick's budget, one job each. A job writes only its own search.
@(private)
run_searches :: proc(s: ^State, w: ^ecs.World) {
	active := 0
	for &a in s.searches {
		active += 1 if a.owner != {} else 0
	}
	if active == 0 {
		return
	}
	share := max(s.budget / active, 1)
	work := make([]Search_Job, active, w.platform.frame_allocator)
	list := make([]jobs.Job, active, w.platform.frame_allocator)
	n := 0
	for &a in s.searches {
		if a.owner == {} {
			continue
		}
		work[n] = {&a.search, mesh_of(s, a.mesh), share}
		list[n] = {search_job, &work[n]}
		n += 1
	}
	counter: jobs.Counter
	w.platform.jobs_run(list, &counter)
	w.platform.jobs_wait(&counter)
}

// finish_searches gives the paths of the searches that finished, in the queue's order.
@(private)
finish_searches :: proc(s: ^State, w: ^ecs.World) {
	i := 0
	for i < len(s.queue) {
		h := s.queue[i]
		p, searching := s.paths.slots[h.index].phase.(Path_Searching)
		if !searching || s.searches[p.search].search.state == .Running {
			i += 1
			continue
		}
		a := &s.searches[p.search]
		m := mesh_of(s, a.mesh)
		status, points, polygons := search_finish(&a.search, m, context.temp_allocator)
		heap := s.platform.heap_allocator
		solved := Path_Solved {
			status   = status,
			mesh     = a.mesh,
			stamp    = a.stamp,
			corners  = make([dynamic]ecs.World_Position, 0, len(points), heap),
			corridor = make([dynamic]u32, 0, len(polygons), heap),
		}
		for point in points {
			append(&solved.corners, world(m, point))
		}
		append(&solved.corridor, ..polygons)
		set_phase(s, w, h, solved)
		ordered_remove(&s.queue, i)
	}
}
