package ai

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"

import "cinnabar:core/jobs"
import "cinnabar:core/profile"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/script"

// Perception (see docs/ai/perception.md). An agent with a Perceiver sees the Perceivables in its cone that a ray from
// its eye reaches, and hears the noises that gameplay makes. What it perceives goes into a short memory in its pool
// slot, and its .perception asset's rows fill its blackboard's keys from that memory. The ai perceive system does the
// work on jobs: the rays have a budget in each tick, which the perceivers share in turn, and the results are the same
// on one job or many.

PERCEIVER_ID :: ecs.Component_Id(132)
PERCEIVABLE_ID :: ecs.Component_Id(133)

// The entities that an agent remembers.
MAX_MEMORY :: 8
// The nearest Perceivables in a perceiver's cone that its rays check, and the points of each.
MAX_SIGHT_TARGETS :: 8
MAX_SIGHT_POINTS :: 4
// The most rays that one perceiver casts in a tick.
MAX_PERCEIVER_RAYS :: MAX_SIGHT_TARGETS * MAX_SIGHT_POINTS
// The sight rays of a tick by default, which set_sight_budget changes, never below MAX_PERCEIVER_RAYS.
DEFAULT_SIGHT_BUDGET :: 64
// The perceivers that one job runs.
PERCEIVE_BATCH :: 16
// The edge of the grid's cells that the Perceivables are found in, in meters.
SIGHT_CELL :: 16.0
// The tags that the project's perception.tags names, and the length of each name.
MAX_TAGS :: 32
MAX_TAG_NAME :: 31

// Perceiver is an agent's senses: how far and how wide it sees, from where, which physics layers block its sight, how
// long it remembers what it perceived, and how well it hears. perception names the .perception asset that gives the
// tags it notices and fills its blackboard. It needs an Agent.
Perceiver :: struct {
	perception:   format.Guid `asset:"perception"`,
	// Meters.
	sight_range:  f32,
	// Degrees from the forward axis, +Z, to the cone's edge.
	half_angle:   f32 `editor:"range=0,180"`,
	// The eye, from the entity's position, in its frame.
	eye_offset:   [3]f32,
	// The physics layers that block sight and muffle noises, a bit each.
	sight_layers: u32,
	// Seconds that an entity is remembered after it was last perceived.
	memory:       f32,
	// What a noise's loudness is multiplied by to give the meters that it is heard at.
	hearing:      f32,
}

DEFAULT_PERCEIVER :: Perceiver {
	sight_range  = 20,
	half_angle   = 60,
	eye_offset   = {0, 1.7, 0},
	sight_layers = max(u32),
	memory       = 5,
	hearing      = 1,
}

// Sight_Points are the points of a Perceivable's body that sight checks, in its frame.
Sight_Points :: struct {
	p0, p1, p2, p3: [3]f32,
}

// Perceivable is an entity that perceivers notice: its tag, an index into the project's perception.tags, and the points
// that sight checks, the first point_count of points. 0 points checks its position.
Perceivable :: struct {
	tag:         u8 `editor:"range=0,31"`,
	point_count: u8 `editor:"range=0,4"`,
	points:      Sight_Points,
}

DEFAULT_PERCEIVABLE :: Perceivable {
	point_count = 1,
	points = {p0 = {0, 1, 0}},
}

#assert(size_of(Perceiver) <= ecs.MAX_COMPONENT_SIZE)

// Tag_Names are the tags that the project's perception.tags names, in order. A Perceivable's tag is an index into
// them. It is plain data, so a code reload keeps it.
Tag_Names :: struct {
	count:   int,
	names:   [MAX_TAGS][MAX_TAG_NAME]u8,
	lengths: [MAX_TAGS]u8,
}

// add_tag_name appends a tag. It returns false when the name is empty, too long, taken, or there are MAX_TAGS already.
add_tag_name :: proc(t: ^Tag_Names, name: string) -> bool {
	if name == "" || len(name) > MAX_TAG_NAME || t.count == MAX_TAGS {
		return false
	}
	if _, found := tag_index(t^, name); found {
		return false
	}
	copy(t.names[t.count][:], name)
	t.lengths[t.count] = u8(len(name))
	t.count += 1
	return true
}

tag_name :: proc(t: ^Tag_Names, index: int) -> string {
	return string(t.names[index][:t.lengths[index]])
}

tag_index :: proc(t: Tag_Names, name: string) -> (int, bool) {
	t := t
	for i in 0 ..< t.count {
		if tag_name(&t, i) == name {
			return i, true
		}
	}
	return 0, false
}

@(private)
tag_of_hash :: proc(t: ^Tag_Names, hash: u32) -> (int, bool) {
	for i in 0 ..< t.count {
		if format.animation_graph_hash(tag_name(t, i)) == hash {
			return i, true
		}
	}
	return 0, false
}

// set_tags gives the project's perception.tags. A perception's names are found in them again in the next frame.
set_tags :: proc(s: ^State, tags: Tag_Names) {
	s.tags = tags
}

// set_sight_budget sets the sight rays of a tick, at least MAX_PERCEIVER_RAYS (see docs/ai/perception.md#sight).
set_sight_budget :: proc(s: ^State, rays: int) {
	s.sight_budget = max(rays, MAX_PERCEIVER_RAYS)
}

// Sense is how an entity was perceived.
Sense :: enum u8 {
	Sight,
	Hearing,
}

// Memory_Entry is an entity that an agent perceived: where it was last perceived, how long ago, by what sense, and
// whether it is seen or heard now.
Memory_Entry :: struct {
	entity:   ecs.Entity,
	position: ecs.World_Position,
	since:    f32,
	tag:      u8,
	sense:    Sense,
	seen:     bool,
	heard:    bool,
}

// Sight_Ray is a ray of a perceiver's last sight check, from its eye, and whether something blocked it.
Sight_Ray :: struct {
	to:      ecs.World_Position,
	blocked: bool,
}

// Perception_Memory is an agent's perception, in its pool slot: what it remembers, in the order that it first
// perceived each, its eye and the rays of its last sight check, for drawing, and the blobs' keys that its rows were
// last checked against, so each mismatch is warned about once.
Perception_Memory :: struct {
	entries:       [MAX_MEMORY]Memory_Entry,
	count:         int,
	eye:           ecs.World_Position,
	forward:       [3]f32,
	rays:          [MAX_PERCEIVER_RAYS]Sight_Ray,
	ray_count:     int,
	checked_rows:  u64,
	checked_board: u64,
}

// perceived_now is whether an entry is seen or heard now.
perceived_now :: proc "contextless" (e: Memory_Entry) -> bool {
	return e.seen || e.heard
}

// Noise is a noise that gameplay made: where, how loud, its tag, and what made it, which may be none.
Noise :: struct {
	position: ecs.World_Position,
	loudness: f32,
	tag:      u8,
	source:   ecs.Entity,
}

Perception_Event_Kind :: enum u8 {
	Perceive,
	Forget,
}

// Perception_Event is an entity that an agent began to perceive, or forgot, which send_events gives its behaviours.
Perception_Event :: struct {
	agent: ecs.Entity,
	other: ecs.Entity,
	kind:  Perception_Event_Kind,
	sense: Sense,
}

// TAG_ANY is a row's tag that looks at every tag, and TAG_UNKNOWN one whose name the project does not give, which
// drops the row.
@(private)
TAG_ANY :: -1
@(private)
TAG_UNKNOWN :: -2

// Perception is a loaded perception blob, valid in the frame that prepare read it in, with its names found in the
// project's tags: the bits of the tags that it notices, and each row's tag.
Perception :: struct {
	data:    []byte,
	blob:    ^format.Perception_Blob,
	notices: u32,
	tags:    []i32,
}

// perception_of is the loaded perception of a GUID in the frame.
perception_of :: proc(s: ^State, guid: format.Guid) -> (Perception, bool) {
	for v in s.frame {
		if v.guid == guid && v.perception.blob != nil {
			return v.perception, true
		}
	}
	return {}, false
}

// resolve_tags finds a perception's tags in the project's, and warns about the names that it does not give.
@(private)
resolve_tags :: proc(s: ^State, p: ^Perception, warn: bool, allocator: runtime.Allocator) {
	path := format.blob_string(p.data, p.blob.source_path)
	notices := format.perception_notices(p.data, p.blob)
	p.notices = max(u32) if len(notices) == 0 else 0
	for n in notices {
		name := format.blob_string(p.data, n)
		if index, found := tag_index(s.tags, name); found {
			p.notices |= 1 << u32(index)
		} else if warn {
			log.warnf("ai: %s notices the tag %s, which perception.tags does not give", path, name)
		}
	}
	rows := format.perception_rows(p.data, p.blob)
	p.tags = make([]i32, len(rows), allocator)
	for r, i in rows {
		p.tags[i] = TAG_ANY
		if r.tag.size == 0 {
			continue
		}
		if index, found := tag_of_hash(&s.tags, r.tag_hash); found {
			p.tags[i] = i32(index)
		} else {
			p.tags[i] = TAG_UNKNOWN
			if warn {
				log.warnf("ai: %s's row %s looks at the tag %s, which perception.tags does not give", path, format.blob_string(p.data, r.key), format.blob_string(p.data, r.tag))
			}
		}
	}
}

// noise makes a noise, from frame code or a serial script step. Perceivers hear it in the next tick. A tag that the
// project's perception.tags does not give is warned about, and the noise is dropped.
noise :: proc(s: ^State, position: ecs.World_Position, loudness: f32, tag: string, source: ecs.Entity = 0) {
	apply(s, noise_command(position, loudness, tag, source))
}

// write_noise asks to make a noise from a system's job. It is made when the job's commands apply, after the tick's
// Fixed systems, and perceivers hear it in the next tick.
write_noise :: proc(to: Writer, position: ecs.World_Position, loudness: f32, tag: string, source: ecs.Entity = 0) {
	append(to.list, noise_command(position, loudness, tag, source))
}

@(private)
noise_command :: proc(position: ecs.World_Position, loudness: f32, tag: string, source: ecs.Entity) -> Command {
	c := Command {
		entity = source,
		kind   = .Noise,
		key    = format.animation_graph_hash(tag),
		amount = loudness,
	}
	(^ecs.World_Position)(&c.value)^ = position
	return c
}

// apply_noise keeps a noise for the next tick's perception.
@(private)
apply_noise :: proc(s: ^State, c: Command) {
	tag, found := tag_of_hash(&s.tags, c.key)
	if !found {
		log.warnf("ai: a noise's tag is not one that perception.tags gives, so it is dropped")
		return
	}
	value := c.value
	append(&s.noises_pending, Noise{position = (^ecs.World_Position)(&value)^, loudness = c.amount, tag = u8(tag), source = c.entity})
}

// perception_debug is an agent's perception memory, for drawing, or nil for an agent that has perceived nothing yet.
perception_debug :: proc(s: ^State, e: ecs.Entity) -> ^Perception_Memory {
	_, ready := ready_of(s, s.world, e)
	if ready == nil {
		return nil
	}
	return ready.perception
}

// send_events gives the perceivers' behaviours on_perceive(entity, sense) and on_forget(entity), in the order that the
// tick's perception found them. Call it from the frame code after the tick's Fixed systems, before the scripts'
// fixed_events.
send_events :: proc(s: ^State, w: ^ecs.World, r: ^script.Runtime) {
	for e in s.events {
		if !ecs.is_alive(w, e.agent) || !ecs.has(w, e.agent, script.Behaviours) {
			continue
		}
		switch e.kind {
		case .Perceive:
			script.send(r, e.agent, "perceive", e.other, "sight" if e.sense == .Sight else "hearing")
		case .Forget:
			script.send(r, e.agent, "forget", e.other)
		}
	}
	clear(&s.events)
}

// sight_points are a Perceivable's points as positions, at its pose.
@(private)
sight_points :: proc(p: Perceivable, t: ecs.Transform) -> (points: [MAX_SIGHT_POINTS]ecs.World_Position, count: int) {
	offsets := [MAX_SIGHT_POINTS][3]f32{p.points.p0, p.points.p1, p.points.p2, p.points.p3}
	count = clamp(int(p.point_count), 0, MAX_SIGHT_POINTS)
	if count == 0 {
		points[0] = t.position
		return points, 1
	}
	for i in 0 ..< count {
		points[i] = ecs.position_offset(t.position, linalg.quaternion128_mul_vector3(t.rotation, offsets[i] * t.scale))
	}
	return
}

// eye_of is a perceiver's eye and forward axis, at its pose.
eye_of :: proc(p: Perceiver, t: ecs.Transform) -> (eye: ecs.World_Position, forward: [3]f32) {
	eye = ecs.position_offset(t.position, linalg.quaternion128_mul_vector3(t.rotation, p.eye_offset))
	forward = linalg.normalize0(linalg.quaternion128_mul_vector3(t.rotation, [3]f32{0, 0, 1}))
	return
}

// in_cone is whether a point is within a perceiver's range and cone.
in_cone :: proc(eye: ecs.World_Position, forward: [3]f32, range, cos_half: f32, point: ecs.World_Position) -> bool {
	d := ecs.position_sub(point, eye)
	length := linalg.length(d)
	if length > range {
		return false
	}
	if length < 1e-4 {
		return true
	}
	return linalg.dot(d, forward) >= cos_half * length
}

// Target is a Perceivable in the tick, in the order that the query found it.
@(private)
Target :: struct {
	entity:   ecs.Entity,
	position: ecs.World_Position,
	tag:      u8,
	points:   [MAX_SIGHT_POINTS]ecs.World_Position,
	count:    int,
}

// Candidate is a target in a perceiver's cone: its index, its distance, and its points in the cone, a bit each.
@(private)
Candidate :: struct {
	target:   u32,
	distance: f32,
	points:   u8,
}

// Perceiver_Work is a perceiver's part of a tick.
@(private)
Perceiver_Work :: struct {
	slot:       u32,
	entity:     ecs.Entity,
	perceiver:  Perceiver,
	perception: Perception,
	board:      Board,
	eye:        ecs.World_Position,
	forward:    [3]f32,
	candidates: [MAX_SIGHT_TARGETS]Candidate,
	count:      int,
	need:       int,
	visited:    bool,
}

// Perceive_Job is a batch of perceivers that one job runs.
@(private)
Perceive_Job :: struct {
	s:       ^State,
	world:   ^ecs.World,
	work:    []Perceiver_Work,
	targets: []Target,
	grid:    ^map[[3]i32][dynamic]u32,
	dt:      f32,
	out:     [dynamic]Command,
	events:  [dynamic]Perception_Event,
	ctx:     runtime.Context,
}

// perceive_system is the ai perceive system: it takes the noises of the last tick, finds each perceiver's candidates
// in its cone, gives the sight rays to the perceivers in turn within the budget, casts them, hears the noises, updates
// each memory, and fills the blackboards from the rows.
@(private)
perceive_system :: proc(ctx: ^ecs.System_Context) {
	s := (^State)(ctx.data)
	w := ctx.world
	clear(&s.noises)
	append(&s.noises, ..s.noises_pending[:])
	clear(&s.noises_pending)
	// Events that nothing sent since the last tick are dropped.
	clear(&s.events)
	work := perceivers(s, w)
	if len(work) == 0 {
		return
	}
	p := &w.platform.profile
	profile.begin(p, profile.name(p, "AI perceive", .Frame))
	defer profile.end(p)
	targets, grid := perceivables(s, w)
	batches := (len(work) + PERCEIVE_BATCH - 1) / PERCEIVE_BATCH
	jobs_data := make([]Perceive_Job, batches, w.platform.frame_allocator)
	list := make([]jobs.Job, batches, w.platform.frame_allocator)
	for b in 0 ..< batches {
		jobs_data[b] = {
			s       = s,
			world   = w,
			work    = work[b * PERCEIVE_BATCH:min((b + 1) * PERCEIVE_BATCH, len(work))],
			targets = targets,
			grid    = &grid,
			dt      = ctx.dt,
			out     = make([dynamic]Command, w.platform.frame_allocator),
			events  = make([dynamic]Perception_Event, w.platform.frame_allocator),
			ctx     = context,
		}
		list[b] = {find_candidates_job, &jobs_data[b]}
	}
	run :: proc(w: ^ecs.World, list: []jobs.Job) {
		counter: jobs.Counter
		w.platform.jobs_run(list, &counter)
		w.platform.jobs_wait(&counter)
	}
	run(w, list)
	share_rays(s, work)
	for b in 0 ..< batches {
		list[b] = {perceive_job, &jobs_data[b]}
	}
	run(w, list)
	out := job_commands(s, ctx)
	for &j in jobs_data {
		append(out, ..j.out[:])
		append(&s.events, ..j.events[:])
	}
}

// perceivers is the tick's perceivers: the ready agents with a Perceiver whose perception is loaded and whose entities
// are active, in slot order. Each gets its memory, and its rows are checked against its blackboard when either blob
// changed.
@(private)
perceivers :: proc(s: ^State, w: ^ecs.World) -> []Perceiver_Work {
	work := make([dynamic]Perceiver_Work, w.platform.frame_allocator)
	for &slot, index in s.agents.slots {
		ready, ok := &slot.phase.(Agent_Ready)
		if !ok || !ecs.is_alive(w, slot.entity) || ecs.has(w, slot.entity, ecs.Inactive) {
			continue
		}
		perceiver := ecs.get(w, slot.entity, Perceiver)
		transform := ecs.get(w, slot.entity, ecs.Transform)
		if perceiver == nil || transform == nil {
			continue
		}
		perception, perception_ok := perception_of(s, perceiver.perception)
		board, board_ok := board_of(s, slot.blackboard)
		if !perception_ok || !board_ok {
			continue
		}
		if ready.perception == nil {
			ready.perception = new(Perception_Memory, s.platform.heap_allocator)
		}
		m := ready.perception
		if m.checked_rows != perception.blob.header.key || m.checked_board != board.blob.header.key {
			m.checked_rows, m.checked_board = perception.blob.header.key, board.blob.header.key
			check_rows(slot.entity, perception, board)
		}
		eye, forward := eye_of(perceiver^, transform^)
		append(&work, Perceiver_Work{slot = u32(index), entity = slot.entity, perceiver = perceiver^, perception = perception, board = board, eye = eye, forward = forward})
	}
	return work[:]
}

// check_rows warns about the rows whose keys the agent's blackboard does not have, or has of another type.
@(private)
check_rows :: proc(e: ecs.Entity, p: Perception, board: Board) {
	path := format.blob_string(p.data, p.blob.source_path)
	keys := format.blackboard_keys(board.data, board.blob)
	for r in format.perception_rows(p.data, p.blob) {
		name := format.blob_string(p.data, r.key)
		want := format.perception_source_type(r.source)
		if index, found := format.blackboard_find(board.data, board.blob, r.key_hash); !found {
			log.warnf("ai: entity %v's blackboard has no key %s, which its perception %s fills", e, name, path)
		} else if keys[index].type != want {
			log.warnf("ai: entity %v's key %s is a %v, and its perception %s fills it with a %v", e, name, keys[index].type, path, want)
		}
	}
}

// perceivables is the tick's active Perceivables, in the order that the query finds them, and the grid of their
// cells.
@(private)
perceivables :: proc(s: ^State, w: ^ecs.World) -> ([]Target, map[[3]i32][dynamic]u32) {
	targets := make([dynamic]Target, w.platform.frame_allocator)
	grid := make(map[[3]i32][dynamic]u32, w.platform.frame_allocator)
	it := ecs.query_iter(w, s.perceivables)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		transforms := ecs.column(view, 1, ecs.Transform)
		for p, row in ecs.column(view, 0, Perceivable) {
			e := entities[row]
			if ecs.has(w, e, ecs.Inactive) {
				continue
			}
			t := Target {
				entity   = e,
				position = transforms[row].position,
				tag      = p.tag,
			}
			t.points, t.count = sight_points(p, transforms[row])
			cell := cell_of(t.position)
			if cell not_in grid {
				grid[cell] = make([dynamic]u32, w.platform.frame_allocator)
			}
			append(&grid[cell], u32(len(targets)))
			append(&targets, t)
		}
	}
	return targets[:], grid
}

@(private)
cell_of :: proc(p: ecs.World_Position) -> [3]i32 {
	m := ecs.position_sub_f64(p, {})
	return {i32(math.floor(m.x / SIGHT_CELL)), i32(math.floor(m.y / SIGHT_CELL)), i32(math.floor(m.z / SIGHT_CELL))}
}

@(private)
find_candidates_job :: proc(data: rawptr) {
	j := (^Perceive_Job)(data)
	context = j.ctx
	for &pw in j.work {
		find_candidates(j, &pw)
	}
}

// find_candidates finds the nearest MAX_SIGHT_TARGETS targets in a perceiver's cone that it notices, by distance and
// then by the query's order, and the rays that checking them takes.
@(private)
find_candidates :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work) {
	p := pw.perceiver
	range := max(p.sight_range, 0)
	cos_half := math.cos(math.to_radians(clamp(p.half_angle, 0, 180)))
	consider :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work, index: u32, range, cos_half: f32) {
		t := &j.targets[index]
		if t.entity == pw.entity || pw.perception.notices & (1 << u32(t.tag)) == 0 {
			return
		}
		points: u8
		for i in 0 ..< t.count {
			if in_cone(pw.eye, pw.forward, range, cos_half, t.points[i]) {
				points |= 1 << u8(i)
			}
		}
		if points == 0 {
			return
		}
		c := Candidate{index, linalg.length(ecs.position_sub(t.position, pw.eye)), points}
		// An insertion among the nearest, whose ties go by the query's order.
		at := pw.count
		for at > 0 && less(c, pw.candidates[at - 1]) {
			at -= 1
		}
		if at >= MAX_SIGHT_TARGETS {
			return
		}
		last := min(pw.count, MAX_SIGHT_TARGETS - 1)
		for i := last; i > at; i -= 1 {
			pw.candidates[i] = pw.candidates[i - 1]
		}
		pw.candidates[at] = c
		pw.count = min(pw.count + 1, MAX_SIGHT_TARGETS)
	}
	low := cell_of(ecs.position_offset(pw.eye, {-range, -range, -range}))
	high := cell_of(ecs.position_offset(pw.eye, {range, range, range}))
	span := (i64(high.x - low.x) + 1) * (i64(high.y - low.y) + 1) * (i64(high.z - low.z) + 1)
	if span > i64(len(j.targets)) {
		for i in 0 ..< len(j.targets) {
			consider(j, pw, u32(i), range, cos_half)
		}
	} else {
		for x in low.x ..= high.x {
			for y in low.y ..= high.y {
				for z in low.z ..= high.z {
					if cell, found := j.grid^[{x, y, z}]; found {
						for index in cell {
							consider(j, pw, index, range, cos_half)
						}
					}
				}
			}
		}
	}
	for c in pw.candidates[:pw.count] {
		pw.need += int(intrinsics.count_ones(c.points))
	}
}

@(private)
less :: proc(a, b: Candidate) -> bool {
	if a.distance != b.distance {
		return a.distance < b.distance
	}
	return a.target < b.target
}

// share_rays gives the tick's sight rays to the perceivers in turn: from the one after the last that was visited, by
// slot, each is visited while its rays fit in what is left. The first that does not fit is first in the next tick.
@(private)
share_rays :: proc(s: ^State, work: []Perceiver_Work) {
	start := 0
	for pw, i in work {
		if i64(pw.slot) > s.sight_cursor {
			start = i
			break
		}
	}
	left := s.sight_budget
	for k in 0 ..< len(work) {
		pw := &work[(start + k) % len(work)]
		if pw.need == 0 {
			continue
		}
		if pw.need > left {
			break
		}
		pw.visited = true
		left -= pw.need
		s.sight_cursor = i64(pw.slot)
	}
}

@(private)
perceive_job :: proc(data: rawptr) {
	j := (^Perceive_Job)(data)
	context = j.ctx
	for &pw in j.work {
		perceive(j, &pw)
	}
}

// perceive updates one perceiver's memory from its sight and hearing, and fills its blackboard.
@(private)
perceive :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work) {
	s, w := j.s, j.world
	slot := &s.agents.slots[pw.slot]
	ready := &slot.phase.(Agent_Ready)
	m := ready.perception
	m.eye, m.forward = pw.eye, pw.forward
	was: [MAX_MEMORY]bool
	for &e, i in m.entries[:m.count] {
		was[i] = perceived_now(e)
		e.heard = false
	}
	see(j, pw, m, &was)
	heard := hear(j, pw, m, &was)
	// Age, and forget what was not perceived for the perceiver's memory, or went.
	for i := 0; i < m.count; {
		e := &m.entries[i]
		if perceived_now(e^) {
			e.since = 0
			if !was[i] {
				append(&j.events, Perception_Event{pw.entity, e.entity, .Perceive, e.sense})
			}
			i += 1
			continue
		}
		e.since += j.dt
		if e.since > pw.perceiver.memory || !ecs.is_alive(w, e.entity) {
			append(&j.events, Perception_Event{pw.entity, e.entity, .Forget, e.sense})
			copy(m.entries[i:m.count - 1], m.entries[i + 1:m.count])
			copy(was[i:m.count - 1], was[i + 1:m.count])
			m.count -= 1
			continue
		}
		i += 1
	}
	fill(j, pw, m, heard, ready, slot)
}

// remember finds an entity's entry, or makes one: in a full memory, in place of the entry perceived longest ago that
// is not perceived now, which is forgotten, or not at all.
@(private)
remember :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work, m: ^Perception_Memory, was: ^[MAX_MEMORY]bool, e: ecs.Entity, tag: u8) -> ^Memory_Entry {
	for &entry in m.entries[:m.count] {
		if entry.entity == e {
			return &entry
		}
	}
	at := m.count
	if m.count == MAX_MEMORY {
		at = -1
		for entry, i in m.entries[:m.count] {
			if !perceived_now(entry) && (at < 0 || entry.since > m.entries[at].since) {
				at = i
			}
		}
		if at < 0 {
			return nil
		}
		append(&j.events, Perception_Event{pw.entity, m.entries[at].entity, .Forget, m.entries[at].sense})
	} else {
		m.count += 1
	}
	m.entries[at] = {
		entity = e,
		tag    = tag,
	}
	was[at] = false
	return &m.entries[at]
}

// see checks a visited perceiver's candidates with its rays, from its eye to each point in its cone: a target is seen
// when a ray reaches one of its points, missing everything or hitting only the target. An unvisited perceiver keeps
// seeing what it saw while it stays in its cone.
@(private)
see :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work, m: ^Perception_Memory, was: ^[MAX_MEMORY]bool) {
	w := j.world
	was_seen: [MAX_MEMORY]bool
	for &e, i in m.entries[:m.count] {
		was_seen[i] = e.seen
		e.seen = false
	}
	if !pw.visited {
		for &e, i in m.entries[:m.count] {
			if !was_seen[i] {
				continue
			}
			for c in pw.candidates[:pw.count] {
				t := j.targets[c.target]
				if t.entity == e.entity {
					e.seen, e.position, e.sense = true, t.position, .Sight
				}
			}
		}
		return
	}
	rays := make([]physics.Ray, pw.need, w.platform.frame_allocator)
	hits := make([]physics.Hit, pw.need, w.platform.frame_allocator)
	n := 0
	for c in pw.candidates[:pw.count] {
		t := j.targets[c.target]
		for i in 0 ..< t.count {
			if c.points & (1 << u8(i)) != 0 {
				d := ecs.position_sub(t.points[i], pw.eye)
				rays[n] = {
					origin       = pw.eye,
					direction    = d,
					max_distance = linalg.length(d),
				}
				n += 1
			}
		}
	}
	if j.s.physics != nil {
		ignore := [1]ecs.Entity{pw.entity}
		physics.raycast_batch(j.s.physics, w, rays, hits, {layers = pw.perceiver.sight_layers, ignore = ignore[:]})
	}
	m.ray_count = 0
	n = 0
	for c in pw.candidates[:pw.count] {
		t := j.targets[c.target]
		seen := false
		for i in 0 ..< t.count {
			if c.points & (1 << u8(i)) == 0 {
				continue
			}
			clear := hits[n].entity == 0 || part_of(w, hits[n].entity, t.entity)
			seen ||= clear
			m.rays[m.ray_count] = {
				to      = t.points[i],
				blocked = !clear,
			}
			m.ray_count += 1
			n += 1
		}
		if seen {
			if e := remember(j, pw, m, was, t.entity, t.tag); e != nil {
				e.seen, e.position, e.sense, e.tag = true, t.position, .Sight, t.tag
			}
		}
	}
}

// part_of is whether an entity is another or one of its descendants, so a ray that hits the target's own body reaches
// it.
@(private)
part_of :: proc(w: ^ecs.World, e, of: ecs.Entity) -> bool {
	current := e
	for _ in 0 ..< 64 {
		if current == of {
			return true
		}
		parent := ecs.get(w, current, ecs.Parent)
		if parent == nil {
			return false
		}
		current = parent.entity
	}
	return false
}

// hear hears the last tick's noises that the perceiver notices: within half of its range, loudness times its hearing,
// at once, and up to its range when a ray from its eye reaches the noise. A noise with a source updates its entry. It
// gives the noises heard, in the order that they were made.
@(private)
hear :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work, m: ^Perception_Memory, was: ^[MAX_MEMORY]bool) -> []u32 {
	s, w := j.s, j.world
	heard := make([dynamic]u32, w.platform.frame_allocator)
	for n, index in s.noises {
		if n.source == pw.entity || pw.perception.notices & (1 << u32(n.tag)) == 0 {
			continue
		}
		range := n.loudness * pw.perceiver.hearing
		distance := linalg.length(ecs.position_sub(n.position, pw.eye))
		if distance > range {
			continue
		}
		if distance > range / 2 && s.physics != nil {
			ignore := [2]ecs.Entity{pw.entity, n.source}
			d := ecs.position_sub(n.position, pw.eye)
			if hit, blocked := physics.raycast(s.physics, w, pw.eye, d, distance, {layers = pw.perceiver.sight_layers, ignore = ignore[:]});
			   blocked && !part_of(w, hit.entity, n.source) {
				continue
			}
		}
		append(&heard, u32(index))
		if n.source == 0 || !ecs.is_alive(w, n.source) {
			continue
		}
		if e := remember(j, pw, m, was, n.source, n.tag); e != nil {
			e.heard = true
			if !e.seen {
				e.position, e.sense, e.tag = n.position, .Hearing, n.tag
			}
		}
	}
	return heard[:]
}

// fill writes each row's key that the agent's blackboard has, of the row's type, through the job's commands.
@(private)
fill :: proc(j: ^Perceive_Job, pw: ^Perceiver_Work, m: ^Perception_Memory, heard: []u32, ready: ^Agent_Ready, slot: ^Agent_Slot) {
	p := pw.perception
	rows := format.perception_rows(p.data, p.blob)
	keys := format.blackboard_keys(pw.board.data, pw.board.blob)
	matches :: proc(tag: i32, of: u8) -> bool {
		return tag == TAG_ANY || i32(of) == tag
	}
	put :: proc(c: ^Command, v: $T) {
		(^T)(&c.value)^ = v
	}
	chosen: [format.MAX_PERCEPTION_ROWS]int
	for r, i in rows {
		chosen[i] = -1
		tag := p.tags[i]
		if tag == TAG_UNKNOWN {
			continue
		}
		if format.perception_source_chooses(r.source) {
			best := -1
			for e, k in m.entries[:m.count] {
				if !matches(tag, e.tag) || (r.source == .Nearest_Seen && !e.seen) || (r.source == .Nearest_Heard && !e.heard) {
					continue
				}
				if best < 0 || closer(m, e, m.entries[best]) {
					best = k
				}
			}
			chosen[i] = best
		}
		slot_index, found := format.blackboard_find(pw.board.data, pw.board.blob, r.key_hash)
		if !found || keys[slot_index].type != format.perception_source_type(r.source) {
			continue
		}
		c := Command {
			entity = pw.entity,
			agent  = {pw.slot, j.s.agents.generations[pw.slot]},
			kind   = .Write,
			key    = u32(slot_index),
			type   = keys[slot_index].type,
		}
		of := -1
		if format.perception_source_reads_row(r.source) {
			of = chosen[r.of]
		}
		switch r.source {
		case .Nearest, .Nearest_Seen, .Nearest_Heard:
			choice: ecs.Entity
			if chosen[i] >= 0 {
				choice = m.entries[chosen[i]].entity
			}
			put(&c, choice)
		case .Position:
			if of < 0 {
				continue
			}
			put(&c, m.entries[of].position)
		case .Visible:
			put(&c, u8(of >= 0 && m.entries[of].seen))
		case .Since:
			since: f32
			if of >= 0 {
				since = m.entries[of].since
			}
			put(&c, since)
		case .Heard_Noise:
			any_heard := false
			for n in heard {
				any_heard ||= matches(tag, j.s.noises[n].tag)
			}
			put(&c, u8(any_heard))
		case .Loudest_Noise:
			loudest := -1
			for n in heard {
				if matches(tag, j.s.noises[n].tag) && (loudest < 0 || j.s.noises[n].loudness > j.s.noises[loudest].loudness) {
					loudest = int(n)
				}
			}
			if loudest < 0 {
				continue
			}
			put(&c, j.s.noises[loudest].position)
		}
		append(&j.out, c)
	}
}

// closer is whether an entry comes before another for a nearest row: perceived now first, then nearer the eye.
@(private)
closer :: proc(m: ^Perception_Memory, a, b: Memory_Entry) -> bool {
	if perceived_now(a) != perceived_now(b) {
		return perceived_now(a)
	}
	return linalg.length(ecs.position_sub(a.position, m.eye)) < linalg.length(ecs.position_sub(b.position, m.eye))
}
