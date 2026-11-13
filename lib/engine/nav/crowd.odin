package nav

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"

import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"

// The crowd (see docs/ai/navigation.md#crowds): agents that follow their paths and avoid each other, as DetourCrowd
// does, and walk through their characters. move_to gives an agent a target, a position or an entity, and the crowd
// system, a Fixed system after the paths system, asks for its path, keeps its corridor as it moves, steers it to its
// next corner, picks a velocity that avoids the other agents and the walls near it, and gives that velocity to its
// Character, which the physics tick moves. The next tick reads where the character got to and fixes the corridor from
// there, so a pushed agent goes back to its path. Each agent's state is in the state's crowd, keyed by the slot in its
// Nav_Agent_State.

// The agents that a job of the crowd system steers, the neighbors that an agent avoids, the corners that it looks
// ahead to, the size of the cells that the neighbors are found in, and how often an agent may ask for a new path.
CROWD_BATCH :: 16
MAX_NEIGHBORS :: 6
MAX_CORNERS :: 4
@(private)
CROWD_CELL :: 4.0
@(private)
REPLAN_SECONDS :: 0.5
// How far around itself an agent looks for neighbors and walls, and ahead for a shortcut, in its radius, as
// DetourCrowd's collisionQueryRange and pathOptimizationRange.
@(private)
QUERY_RANGE :: 12
@(private)
SHORTCUT_RANGE :: 30
// How strongly an agent keeps away from those that it overlaps.
@(private)
SEPARATION_WEIGHT :: 2.0
// How far off the navmesh an agent may be before it steers back, and in how long it means to get back, in seconds.
@(private)
OFF_MESH :: 0.02
@(private)
RETURN_SECONDS :: 0.25

// Crowd_Target is where an agent goes: a position, or an entity that it follows.
Crowd_Target :: union {
	ecs.World_Position,
	ecs.Entity,
}

@(private)
Crowd_Request_Kind :: enum u8 {
	Move,
	Stop,
}

// Crowd_Request is a move or a stop for an agent. ticket is the tick that a move was asked in, and for a stop, the
// move that it stops, or zero for any.
@(private)
Crowd_Request :: struct {
	entity: ecs.Entity,
	kind:   Crowd_Request_Kind,
	target: Crowd_Target,
	ticket: u64,
}

// Crowd_Requests is where moves are recorded: frame code's list or a script's, or a system's job's, and the tick that
// they are asked in.
Crowd_Requests :: struct {
	list: ^[dynamic]Crowd_Request,
	tick: u64,
}

// crowd_requests is frame code's and the scripts': the moves that the next crowd tick applies.
crowd_requests :: proc(s: ^State, w: ^ecs.World) -> Crowd_Requests {
	return {&s.crowd_pending, w.clock.tick + 1}
}

// job_crowd is a system's job's own list, which the world flushes after the stage in system order and then job order,
// so the moves keep an order that does not depend on the jobs' timing. The next tick's crowd applies them.
job_crowd :: proc(s: ^State, ctx: ^ecs.System_Context) -> Crowd_Requests {
	return {(^[dynamic]Crowd_Request)(ecs.job_buffer(ctx, s.job_crowd)), ctx.world.clock.tick + 1}
}

// move_to sends an agent to a target, a position or an entity that it follows, from the next crowd tick, in place of
// its last move. It gives the move's ticket, which crowd_move tells the agent's move by.
move_to :: proc(to: Crowd_Requests, e: ecs.Entity, target: Crowd_Target) -> (ticket: u64) {
	append(to.list, Crowd_Request{entity = e, kind = .Move, target = target, ticket = to.tick})
	return to.tick
}

// stop stops an agent from the next crowd tick: it slows to a stop where it is, and its status is Idle. With a
// ticket, it stops only the move of that ticket, and not one that replaced it.
stop :: proc(to: Crowd_Requests, e: ecs.Entity, ticket: u64 = 0) {
	append(to.list, Crowd_Request{entity = e, kind = .Stop, ticket = ticket})
}

// Crowd_Move is an agent's move as the last crowd tick left it: its ticket, zero for none, its target and its status.
Crowd_Move :: struct {
	ticket: u64,
	target: Crowd_Target,
	status: Move_Status,
}

// crowd_move is an entity's move, or false when it is not an agent of the crowd yet.
crowd_move :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (Crowd_Move, bool) {
	_, slot := find_agent(s, w, e)
	if slot == nil {
		return {}, false
	}
	return {slot.move, slot.target, status_of_phase(slot.phase)}, true
}

// Crowd_Debug is what an agent did in its last tick, which the editor's helpers draw: its next corners, its neighbors,
// and its desired and chosen velocities.
Crowd_Debug :: struct {
	corners:        [MAX_CORNERS + 1]ecs.World_Position,
	corner_count:   int,
	neighbors:      [MAX_NEIGHBORS]ecs.Entity,
	neighbor_count: int,
	desired:        [3]f32,
	velocity:       [3]f32,
}

// crowd_debug is an agent's last tick, with its corridor's polygons on its navmesh, or nil when it is not an agent of
// the crowd. The corridor is valid until the crowd system runs again.
crowd_debug :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (debug: ^Crowd_Debug, mesh: ^Mesh_View, corridor: []u32) {
	_, slot := find_agent(s, w, e)
	if slot == nil {
		return nil, nil, nil
	}
	if f, following := slot.phase.(Crowd_Following); following {
		if m := mesh_of(s, f.mesh); m != nil && m.stamp == f.stamp {
			mesh, corridor = m, f.corridor[:]
		}
	}
	return &slot.debug, mesh, corridor
}

// The phases of an agent in the crowd. A slot whose phase is nil is free.
Crowd_Idle :: struct {}
// Waiting for its first path, which slot.asking is.
Crowd_Asking :: struct {}
Crowd_Following :: struct {
	mesh:     Mesh_Id,
	stamp:    Mesh_Stamp,
	// The polygons from the one that the agent is on to its path's end.
	corridor: [dynamic]u32,
	// Where the agent is on its first polygon, and its path's end.
	position: [3]f32,
	end:      [3]f32,
	// The path ends short of the target, which nothing reaches.
	partial:  bool,
}
Crowd_Arrived :: struct {}
Crowd_Failed :: struct {}

Crowd_Phase :: union {
	Crowd_Idle,
	Crowd_Asking,
	Crowd_Following,
	Crowd_Arrived,
	Crowd_Failed,
}

// Path_Ask is the path that an agent asked for and has not had yet: its ticket and its goal.
@(private)
Path_Ask :: struct {
	ticket: u64,
	goal:   ecs.World_Position,
}

Crowd_Slot :: struct {
	entity:   ecs.Entity,
	// Its move: the target and the ticket of the move.
	target:   Crowd_Target,
	move:     u64,
	// The path that it waits for, while it follows the last one or before its first.
	asking:   Maybe(Path_Ask),
	// Where its target was when it asked for the path that it follows, and the first tick that it may ask again.
	planned:  ecs.World_Position,
	next_ask: u64,
	// set_crowd_phase is its only writer.
	phase:    Crowd_Phase,
	// The velocity that it last chose, and the one its path asked for, which its neighbors read.
	velocity: [3]f32,
	desired:  [3]f32,
	debug:    Crowd_Debug,
	// It has no character, which is warned about once.
	warned:   bool,
}

// Crowd_Pool is the agents by slot, with a generation for each, which freeing the slot changes, so a stale handle
// finds nothing.
Crowd_Pool :: struct {
	slots:       [dynamic]Crowd_Slot,
	generations: [dynamic]u32,
	free:        [dynamic]u32,
}

@(private)
crowd_slot_of :: proc(s: ^State, h: Crowd_Handle) -> ^Crowd_Slot {
	if h.generation == 0 || int(h.index) >= len(s.crowd.slots) || s.crowd.generations[h.index] != h.generation {
		return nil
	}
	slot := &s.crowd.slots[h.index]
	return slot if slot.phase != nil else nil
}

// find_agent is an entity's slot: by its Nav_Agent_State, or, in the tick that it got its slot, before the state is
// added, by the pool.
@(private)
find_agent :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (Crowd_Handle, ^Crowd_Slot) {
	if !ecs.is_alive(w, e) || !ecs.has(w, e, Nav_Agent) {
		return {}, nil
	}
	if state := ecs.get(w, e, Nav_Agent_State); state != nil {
		if slot := crowd_slot_of(s, state.crowd); slot != nil && slot.entity == e {
			return state.crowd, slot
		}
	}
	for &slot, i in s.crowd.slots {
		if slot.phase != nil && slot.entity == e {
			return {u32(i), s.crowd.generations[i]}, &slot
		}
	}
	return {}, nil
}

@(private)
alloc_crowd_slot :: proc(s: ^State, e: ecs.Entity) -> Crowd_Handle {
	p := &s.crowd
	h: Crowd_Handle
	if n := len(p.free); n > 0 {
		index := pop(&p.free)
		h = {index, p.generations[index]}
	} else {
		append(&p.slots, Crowd_Slot{})
		append(&p.generations, 1)
		h = {u32(len(p.slots) - 1), 1}
	}
	p.slots[h.index] = {
		entity = e,
		phase  = Crowd_Idle{},
	}
	return h
}

@(private)
free_crowd_slot :: proc(s: ^State, index: u32) {
	slot := &s.crowd.slots[index]
	release_crowd_phase(slot)
	slot^ = {}
	g := &s.crowd.generations[index]
	g^ += 1
	if g^ == 0 {
		g^ = 1
	}
	append(&s.crowd.free, index)
}

@(private)
release_crowd_phase :: proc(slot: ^Crowd_Slot) {
	if f, ok := &slot.phase.(Crowd_Following); ok {
		delete(f.corridor)
	}
}

@(private)
status_of_phase :: proc(phase: Crowd_Phase) -> Move_Status {
	switch _ in phase {
	case Crowd_Asking, Crowd_Following:
		return .Moving
	case Crowd_Arrived:
		return .Arrived
	case Crowd_Failed:
		return .Failed
	case Crowd_Idle, nil:
	}
	return .Idle
}

// set_crowd_phase is the only writer of an agent's phase. It frees what the old phase held, and shows the new status
// in the entity's Nav_Agent_State.
@(private)
set_crowd_phase :: proc(s: ^State, w: ^ecs.World, slot: ^Crowd_Slot, phase: Crowd_Phase) {
	release_crowd_phase(slot)
	slot.phase = phase
	if state := ecs.get_write(w, slot.entity, Nav_Agent_State); state != nil {
		state.status = status_of_phase(phase)
	}
}

@(private)
make_job_crowd :: proc(user: rawptr, allocator: runtime.Allocator) -> rawptr {
	list := new([dynamic]Crowd_Request, allocator)
	list^ = make([dynamic]Crowd_Request, allocator)
	return list
}

@(private)
flush_job_crowd :: proc(user: rawptr, buffers: []rawptr) {
	s := (^State)(user)
	for b in buffers {
		append(&s.crowd_pending, ..(^[dynamic]Crowd_Request)(b)[:])
	}
}

// Snapshot is an agent as the tick starts, which every job reads: where it is, how it moves, and its Nav_Agent.
@(private)
Snapshot :: struct {
	slot:     u32,
	entity:   ecs.Entity,
	agent:    Nav_Agent,
	position: ecs.World_Position,
	meters:   [3]f64,
	velocity: [3]f32,
	desired:  [3]f32,
}

// Agent_Result is what a job found for an agent, which the system applies after the jobs, in the agents' order.
@(private)
Agent_Result :: struct {
	velocity: [3]f32,
	desired:  [3]f32,
	// A new phase, and a path to ask for.
	phase:    Maybe(Crowd_Phase),
	ask:      Maybe(ecs.World_Position),
}

@(private)
Crowd_Job :: struct {
	s:         ^State,
	w:         ^ecs.World,
	snapshots: []Snapshot,
	grid:      ^map[[2]i32][dynamic]u32,
	first:     int,
	results:   []Agent_Result,
	dt:        f32,
	tick:      u64,
}

// crowd_system is the crowd system. Serially, it frees the slots of agents that went and gives new agents theirs,
// applies the moves and stops, takes the paths that the agents asked for, and takes a snapshot of every agent and its
// cell. Then, on jobs of CROWD_BATCH agents, each agent fixes its corridor from where its character is, steers and
// avoids, and its job writes only its own slot and result. Last, in the slots' order, it applies the results: the
// phases, the paths that agents ask for, and their characters' moves.
@(private)
crowd_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	added := check_crowd(s, w, ctx.commands)
	apply_crowd_requests(s, w)
	adopt_paths(s, w)

	frame := w.platform.frame_allocator
	snapshots := make([dynamic]Snapshot, 0, len(s.crowd.slots), frame)
	for &slot, i in s.crowd.slots {
		if slot.phase == nil || ecs.has(w, slot.entity, ecs.Inactive) {
			continue
		}
		agent := ecs.get(w, slot.entity, Nav_Agent)
		transform := ecs.get(w, slot.entity, ecs.Transform)
		pc := ecs.get(w, slot.entity, physics.Physics_Character)
		if agent == nil || transform == nil {
			continue
		}
		if pc == nil {
			if !slot.warned && !ecs.has(w, slot.entity, physics.Character) {
				slot.warned = true
				log.warnf("nav: the agent %v has no Character, so it does not move", slot.entity)
			}
			continue
		}
		snapshot := Snapshot {
			slot     = u32(i),
			entity   = slot.entity,
			agent    = agent^,
			position = transform.position,
			meters   = ecs.position_to_meters(transform.position),
			velocity = pc.velocity,
			desired  = slot.desired,
		}
		append(&snapshots, snapshot)
	}
	grid := make(map[[2]i32][dynamic]u32, frame)
	for sn, i in snapshots {
		cell := cell_of(sn.meters)
		list, found := &grid[cell]
		if !found {
			grid[cell] = make([dynamic]u32, frame)
			list = &grid[cell]
		}
		append(list, u32(i))
	}

	results := make([]Agent_Result, len(snapshots), frame)
	batches := (len(snapshots) + CROWD_BATCH - 1) / CROWD_BATCH
	work := make([]Crowd_Job, batches, frame)
	list := make([]jobs.Job, batches, frame)
	for b in 0 ..< batches {
		first := b * CROWD_BATCH
		last := min(first + CROWD_BATCH, len(snapshots))
		work[b] = {
			s         = s,
			w         = w,
			snapshots = snapshots[:],
			grid      = &grid,
			first     = first,
			results   = results[first:last],
			dt        = ctx.dt,
			tick      = w.clock.tick + 1,
		}
		list[b] = {crowd_job, &work[b]}
	}
	if batches > 0 {
		counter: jobs.Counter
		w.platform.jobs_run(list, &counter)
		w.platform.jobs_wait(&counter)
	}

	effects: Maybe(physics.Effects)
	if s.physics != nil {
		effects = physics.job_effects(s.physics, ctx)
	}
	for sn, i in snapshots {
		r := results[i]
		slot := &s.crowd.slots[sn.slot]
		if phase, changed := r.phase.?; changed {
			set_crowd_phase(s, w, slot, phase)
		}
		if goal, ask := r.ask.?; ask {
			ask_path(s, w, slot, goal)
		}
		slot.velocity, slot.desired = r.velocity, r.desired
		if e, ok := effects.?; ok {
			physics.character_move(e, w, sn.entity, r.velocity, gravity = true)
		}
	}
	for &slot in s.crowd.slots {
		if slot.phase == nil {
			continue
		}
		if state := ecs.get_write(w, slot.entity, Nav_Agent_State); state != nil {
			state.status = status_of_phase(slot.phase)
			state.velocity, state.desired = slot.velocity, slot.desired
		}
	}
	// A new agent's state comes with its first tick's status, so a move asked for with it shows from the start.
	for h in added {
		slot := &s.crowd.slots[h.index]
		state := Nav_Agent_State {
			crowd    = h,
			status   = status_of_phase(slot.phase),
			velocity = slot.velocity,
			desired  = slot.desired,
		}
		ecs.command_add(ctx.commands, w, slot.entity, state)
	}
}

@(private)
cell_of :: proc "contextless" (m: [3]f64) -> [2]i32 {
	return {i32(math.floor(m.x / CROWD_CELL)), i32(math.floor(m.z / CROWD_CELL))}
}

// check_crowd frees the slots of agents that are gone, that lost their Nav_Agent, or whose Nav_Agent_State names
// another slot, and gives a slot to each Nav_Agent without one: a new agent, or a copy of one, whose state names the
// original's slot. It gives the new slots, whose states the system adds at its end. It gives an agent without a
// Nav_Path one of its agent type, which its path requests need.
@(private)
check_crowd :: proc(s: ^State, w: ^ecs.World, commands: ^ecs.Commands) -> []Crowd_Handle {
	added := make([dynamic]Crowd_Handle, w.platform.frame_allocator)
	for i in 0 ..< u32(len(s.crowd.slots)) {
		slot := &s.crowd.slots[i]
		if slot.phase == nil {
			continue
		}
		alive := ecs.is_alive(w, slot.entity) && ecs.has(w, slot.entity, Nav_Agent)
		state := ecs.get(w, slot.entity, Nav_Agent_State) if alive else nil
		if !alive || (state != nil && state.crowd != {i, s.crowd.generations[i]}) {
			free_crowd_slot(s, i)
		}
	}
	it := ecs.query_iter(w, s.crowd_agents)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		for agent, row in ecs.column(view, 0, Nav_Agent) {
			e := entities[row]
			state := ecs.get(w, e, Nav_Agent_State)
			mine := false
			if state != nil {
				slot := crowd_slot_of(s, state.crowd)
				mine = slot != nil && slot.entity == e
			} else {
				for &slot in s.crowd.slots {
					mine ||= slot.phase != nil && slot.entity == e
				}
			}
			if !mine {
				append(&added, alloc_crowd_slot(s, e))
			}
			if np := ecs.get(w, e, Nav_Path); np == nil || np.agent != agent.agent {
				ecs.command_add(commands, w, e, Nav_Path{agent = agent.agent})
			}
		}
	}
	return added[:]
}

// apply_crowd_requests applies the moves and the stops in their order. A move asks for its path at once, and the agent
// follows its last path, if it has one, until the new one comes.
@(private)
apply_crowd_requests :: proc(s: ^State, w: ^ecs.World) {
	for r in s.crowd_pending {
		_, slot := find_agent(s, w, r.entity)
		if slot == nil {
			log.warnf("nav: a move was asked for entity %v, which has no Nav_Agent", r.entity)
			continue
		}
		switch r.kind {
		case .Move:
			slot.target, slot.move = r.target, r.ticket
			goal, ok := target_position(w, r.target)
			if !ok {
				slot.asking = nil
				set_crowd_phase(s, w, slot, Crowd_Failed{})
				continue
			}
			slot.next_ask = 0
			ask_path(s, w, slot, goal)
			if _, following := slot.phase.(Crowd_Following); !following {
				set_crowd_phase(s, w, slot, Crowd_Asking{})
			}
		case .Stop:
			if r.ticket != 0 && r.ticket != slot.move {
				continue
			}
			slot.target, slot.asking = nil, nil
			set_crowd_phase(s, w, slot, Crowd_Idle{})
		}
	}
	clear(&s.crowd_pending)
}

// target_position is where a target is now: a position, or an entity's Transform.
@(private)
target_position :: proc(w: ^ecs.World, target: Crowd_Target) -> (ecs.World_Position, bool) {
	switch t in target {
	case ecs.World_Position:
		return t, true
	case ecs.Entity:
		if ecs.is_alive(w, t) {
			if transform := ecs.get(w, t, ecs.Transform); transform != nil {
				return transform.position, true
			}
		}
	}
	return {}, false
}

// ask_path asks for the agent's path to goal, which the paths system admits in the next tick. Its ticket is the move's
// tick and the agent's slot, so the agent takes only the answer to its last ask.
@(private)
ask_path :: proc(s: ^State, w: ^ecs.World, slot: ^Crowd_Slot, goal: ecs.World_Position) {
	ticket := w.clock.tick + 1
	slot.asking = Path_Ask{ticket, goal}
	slot.next_ask = ticket + u64(math.ceil(REPLAN_SECONDS * f64(w.clock.tick_rate)))
	append(&s.pending, Path_Request{entity = slot.entity, goal = goal, ticket = ticket})
}

// adopt_paths gives the agents the paths that they asked for, which the paths system solved: a Found or a Partial
// one to follow, or Failed.
@(private)
adopt_paths :: proc(s: ^State, w: ^ecs.World) {
	for &slot in s.crowd.slots {
		ask, asking := slot.asking.?
		if slot.phase == nil || !asking {
			continue
		}
		np := ecs.get(w, slot.entity, Nav_Path)
		path := slot_of(s, np.path) if np != nil else nil
		if path == nil || path.entity != slot.entity || path.ticket != ask.ticket {
			continue
		}
		#partial switch p in path.phase {
		case Path_Solved:
			m := mesh_of(s, p.mesh)
			if m == nil || m.stamp != p.stamp || len(p.corridor) == 0 || len(p.corners) == 0 {
				continue
			}
			corridor := make([dynamic]u32, 0, len(p.corridor), s.platform.heap_allocator)
			append(&corridor, ..p.corridor[:])
			slot.asking = nil
			slot.planned = ask.goal
			following := Crowd_Following {
				mesh     = p.mesh,
				stamp    = p.stamp,
				corridor = corridor,
				position = local(m, p.corners[0]),
				end      = local(m, p.corners[len(p.corners) - 1]),
				partial  = p.status == .Partial,
			}
			set_crowd_phase(s, w, &slot, following)
		case Path_Failed:
			slot.asking = nil
			set_crowd_phase(s, w, &slot, Crowd_Failed{})
		}
	}
}

@(private)
crowd_job :: proc(data: rawptr) {
	j := (^Crowd_Job)(data)
	for k in 0 ..< len(j.results) {
		steer_agent(j, j.first + k, &j.results[k])
	}
}

// steer_agent is an agent's tick on a job: it reads the snapshot, the world and the navmeshes, and writes only its own
// slot's corridor and debug and its result.
@(private)
steer_agent :: proc(j: ^Crowd_Job, index: int, result: ^Agent_Result) {
	s, w := j.s, j.w
	sn := j.snapshots[index]
	slot := &s.crowd.slots[sn.slot]
	agent := sn.agent
	radius := max(agent.radius, 0.01)
	slot.debug = {}

	desired: [3]f32
	mesh: ^Mesh_View
	polygon := NO_POLYGON
	on_mesh: [3]f32
	goal, has_goal := target_position(w, slot.target)
	moved := has_goal && linalg.length(ecs.position_sub(goal, slot.planned)) > max(2 * radius, 0.5)
	_, asking := slot.asking.?
	may_ask := !asking && j.tick >= slot.next_ask

	#partial switch &f in slot.phase {
	case Crowd_Following:
		mesh = mesh_of(s, f.mesh)
		if mesh == nil || mesh.stamp != f.stamp {
			// The navmesh was recooked or unloaded: the agent waits for a path on what is there now.
			mesh = nil
			if has_goal {
				result.phase, result.ask = Crowd_Asking{}, goal
			} else {
				result.phase = Crowd_Failed{}
			}
			break
		}
		position := local(mesh, sn.position)
		// The corridor's start follows the character to where it got to.
		reached, visited := move_along_surface(mesh, f.corridor[0], f.position, position)
		if !merge_start_moved(&f.corridor, visited) || distance_2d(reached, position) > 2 * radius {
			// Pushed off its corridor, or off the navmesh: it asks for its path from where it is.
			if has_goal && may_ask {
				result.ask = goal
			}
		}
		f.position = reached
		polygon, on_mesh = f.corridor[0], reached
		if moved && may_ask {
			result.ask = goal
		}
		corners := next_corners(mesh, &f, radius)
		for c, i in corners {
			if i <= MAX_CORNERS {
				slot.debug.corners[i] = world(mesh, c)
				slot.debug.corner_count = i + 1
			}
		}
		remaining := distance_2d(position, f.end)
		if len(corners) < 2 || (len(corners) == 2 && remaining <= agent.stopping_distance) {
			if f.partial || !has_goal {
				if !moved {
					result.phase = Crowd_Failed{}
				}
			} else {
				result.phase = Crowd_Arrived{}
			}
			break
		}
		// It steers from its point on the navmesh, so one that was pushed off, toward a wall, does not walk into the wall,
		// and back onto the navmesh.
		next := corners[1]
		direction := next - reached
		direction.y = 0
		speed := agent.max_speed
		if len(corners) == 2 {
			speed = min(speed, math.sqrt(2 * max(agent.acceleration, 0.01) * remaining))
		}
		desired = linalg.normalize0(direction) * speed
		back := reached - position
		back.y = 0
		if linalg.length(back) > OFF_MESH {
			desired += back / RETURN_SECONDS
			if l := linalg.length(desired); l > agent.max_speed {
				desired *= agent.max_speed / l
			}
		}
	case Crowd_Arrived:
		// A followed entity that moves away takes the agent after it again.
		if moved && may_ask {
			result.phase, result.ask = Crowd_Asking{}, goal
		}
	}

	if mesh == nil {
		m, p, q, ok := snap(s, sn.position, agent.agent)
		if ok {
			mesh, polygon, on_mesh = m, p, q
		}
	}
	velocity := avoid(j, index, slot, mesh, polygon, on_mesh, desired, radius)
	result.desired, result.velocity = desired, velocity
	slot.debug.desired, slot.debug.velocity = desired, velocity
}

// next_corners shortens the corridor by a straight walk toward the corner after next, if nothing is in its way, as
// DetourCrowd's optimizePathVisibility, and gives the funnel's corners from the agent to the path's end: the agent's
// point first, and up to MAX_CORNERS after it, past those on the agent's point.
@(private)
next_corners :: proc(m: ^Mesh_View, f: ^Crowd_Following, radius: f32) -> [][3]f32 {
	corners := straight_path(m, f.position, f.end, f.corridor[:], context.temp_allocator)
	if len(corners) > 2 && len(f.corridor) > 1 {
		target := corners[2]
		distance := distance_2d(f.position, target)
		if distance > 0.01 {
			reach := min(distance + 0.01, SHORTCUT_RANGE * radius)
			ahead := f.position + (target - f.position) * (reach / distance)
			visited := make([dynamic]u32, context.temp_allocator)
			walk := raycast_local(m, f.corridor[0], f.position, ahead, &visited)
			if len(visited) > 1 && walk.t > 0.99 {
				merge_start_shortcut(&f.corridor, visited[:])
				corners = straight_path(m, f.position, f.end, f.corridor[:], context.temp_allocator)
			}
		}
	}
	// Corners on the agent's point are passed, as DetourCrowd's findCorners prunes them.
	first := 1
	for first < len(corners) && distance_2d(corners[first], f.position) < 0.01 {
		first += 1
	}
	pruned := make([dynamic][3]f32, 0, MAX_CORNERS + 1, context.temp_allocator)
	append(&pruned, f.position)
	for c in corners[first:] {
		if len(pruned) == MAX_CORNERS + 1 {
			break
		}
		append(&pruned, c)
	}
	return pruned[:]
}

// avoid is the agent's velocity for this tick: its desired velocity, kept apart from the neighbors that it overlaps,
// avoided around its neighbors and walls by sampling, and then changed from its current velocity by no more than its
// acceleration allows.
@(private)
avoid :: proc(j: ^Crowd_Job, index: int, slot: ^Crowd_Slot, m: ^Mesh_View, polygon: u32, on_mesh: [3]f32, desired: [3]f32, radius: f32) -> [3]f32 {
	sn := j.snapshots[index]
	agent := sn.agent
	range := QUERY_RANGE * radius
	neighbors := find_neighbors(j, index, range)
	for n, i in neighbors {
		slot.debug.neighbors[i] = j.snapshots[n].entity
	}
	slot.debug.neighbor_count = len(neighbors)

	desired_2d := [2]f32{desired.x, desired.z}
	speed := linalg.length(desired_2d)
	// Separation, as DetourCrowd's: away from the neighbors within reach, less the farther they are, but for those of a
	// lower priority.
	if speed > 0.0001 && len(neighbors) > 0 {
		push: [2]f32
		weights: f32
		for n in neighbors {
			other := j.snapshots[n]
			if other.agent.priority < agent.priority {
				continue
			}
			reach := 2 * (radius + other.agent.radius)
			d := sn.meters - other.meters
			diff := [2]f32{f32(d.x), f32(d.z)}
			distance_squared := linalg.dot(diff, diff)
			if distance_squared < 0.00001 || distance_squared > reach * reach {
				continue
			}
			distance := math.sqrt(distance_squared)
			weight := SEPARATION_WEIGHT * (1 - distance_squared / (reach * reach))
			push += diff * (weight / distance)
			weights += 1
		}
		if weights > 0.0001 {
			desired_2d += push / weights
			if l := linalg.length(desired_2d); l > speed {
				desired_2d *= speed / l
			}
		}
	}

	circles := make([dynamic]Circle, 0, len(neighbors), context.temp_allocator)
	for n in neighbors {
		other := j.snapshots[n]
		share: f32 = 0.5
		if other.agent.priority > agent.priority {
			share = 1
		} else if other.agent.priority < agent.priority {
			// The higher priority keeps its way.
			continue
		}
		d := other.meters - sn.meters
		append(
			&circles,
			Circle {
				position = {f32(d.x), f32(d.z)},
				radius = max(other.agent.radius, 0.01),
				velocity = {other.velocity.x, other.velocity.z},
				desired = {other.desired.x, other.desired.z},
				share = share,
			},
		)
	}
	walls := make([dynamic]Wall, 0, MAX_WALLS, context.temp_allocator)
	if m != nil && polygon != NO_POLYGON {
		segments: [MAX_WALLS]Segment
		count := wall_segments(m, polygon, on_mesh, range, &segments)
		position := local(m, sn.position)
		for seg in segments[:count] {
			a, b := seg.a - position, seg.b - position
			touch, _ := distance_to_segment_2d({}, a, b)
			append(&walls, Wall{a = {a.x, a.z}, b = {b.x, b.z}, touch = touch < radius * radius})
		}
	}

	current := [2]f32{sn.velocity.x, sn.velocity.z}
	chosen := desired_2d
	if len(circles) > 0 || len(walls) > 0 {
		prepare_circles(circles[:], desired_2d)
		chosen = choose_velocity(AVOID_PARAMS, current, desired_2d, radius, agent.max_speed, circles[:], walls[:])
	}
	change := chosen - current
	limit := max(agent.acceleration, 0) * j.dt
	if l := linalg.length(change); l > limit {
		change *= limit / l
	}
	next := current + change
	if l := linalg.length(next); l > agent.max_speed {
		next *= agent.max_speed / l
	}
	return {next.x, 0, next.y}
}

// find_neighbors is the agents nearest an agent within range on the ground and within its height above or below, at
// most MAX_NEIGHBORS, nearest first and then by slot, by their index in the snapshot.
@(private)
find_neighbors :: proc(j: ^Crowd_Job, index: int, range: f32) -> []int {
	HEIGHT :: 2.0
	sn := j.snapshots[index]
	found: [MAX_NEIGHBORS]int
	distances: [MAX_NEIGHBORS]f64
	count := 0
	lo := cell_of(sn.meters - f64(range))
	hi := cell_of(sn.meters + f64(range))
	for cz in lo.y ..= hi.y {
		for cx in lo.x ..= hi.x {
			list, ok := j.grid[{cx, cz}]
			if !ok {
				continue
			}
			for n in list {
				if int(n) == index {
					continue
				}
				other := j.snapshots[n]
				d := other.meters - sn.meters
				if abs(d.y) > HEIGHT {
					continue
				}
				distance := d.x * d.x + d.z * d.z
				if distance > f64(range * range) {
					continue
				}
				at := count
				for at > 0 && (distances[at - 1] > distance || (distances[at - 1] == distance && j.snapshots[found[at - 1]].slot > other.slot)) {
					at -= 1
				}
				if at >= MAX_NEIGHBORS {
					continue
				}
				for k := min(count, MAX_NEIGHBORS - 1); k > at; k -= 1 {
					found[k], distances[k] = found[k - 1], distances[k - 1]
				}
				found[at], distances[at] = int(n), distance
				count = min(count + 1, MAX_NEIGHBORS)
			}
		}
	}
	out := make([]int, count, context.temp_allocator)
	copy(out, found[:count])
	return out
}
