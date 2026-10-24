package ecs

import "core:log"
import "core:time"

import "cinnabar:core/jobs"

MAX_SYSTEMS :: 256
MAX_SYSTEM_ACCESS :: 32
MAX_SYSTEM_AFTER :: 8
DEFAULT_BATCH_CHUNKS :: 4
MAX_TICKS_PER_FRAME :: 4
DEFAULT_TICK_RATE :: 60

// Stage is when a system runs. See docs/world.md#systems.
Stage :: enum u8 {
	// Once per fixed tick, zero or more times per frame.
	Fixed,
	// Once per frame, before the script phase.
	Update,
	// Once per frame, after the script phase.
	Late,
}

System_Proc :: #type proc(ctx: ^System_Context)

// System_Context is one job of a system: a range of the chunks that its query matches.
System_Context :: struct {
	world:       ^World,
	// The data that the stage was run with, usually the Game_State.
	user:        rawptr,
	query:       Query,
	first_chunk: int,
	chunk_count: int,
	// Seconds: the tick duration in Fixed systems, the frame duration in the others.
	dt:          f32,
	// True in the first tick of a frame. Only that tick gets the input edges of the frame.
	first_tick:  bool,
	// Applied after the stage, or after the tick in Fixed systems.
	commands:    ^Commands,
}

System_Desc :: struct {
	// Unique. Other systems name it in after.
	name:         string,
	stage:        Stage,
	procedure:    System_Proc,
	// The system runs one job for each batch of the chunks that these terms match. Without terms, it runs one job.
	terms:        []Term,
	// Access to data that the terms do not name, such as resources in Game_State. Name a resource with component_id.
	reads:        []Component_Id,
	writes:       []Component_Id,
	// Systems in the same stage that must finish before this one starts.
	after:        []string,
	// Chunks per job. Zero means DEFAULT_BATCH_CHUNKS.
	batch_chunks: int,
}

// Clock schedules the fixed ticks. Its arithmetic is integer, so it never drifts. The state after tick n is the
// world at time tick_start(n + 1).
Clock :: struct {
	tick_rate: u32,
	// Tick n starts at base_time + (n - base_tick) * time.Second / tick_rate. A rate change moves the base.
	base_tick: u64,
	base_time: time.Duration,
	time:      time.Duration,
	// The number of ticks run.
	tick:      u64,
	// The fraction of the current tick that has passed. Presentation interpolates by it.
	alpha:     f32,
}

// Schedule holds the systems. It holds procedures and strings from the DLL image, so reload clears it.
@(private)
Schedule :: struct {
	systems: [MAX_SYSTEMS]System,
	count:   int,
	// The systems of each stage in run order.
	order:   [Stage][MAX_SYSTEMS]u16,
	ordered: [Stage]int,
	// For each system, the systems that it waits for.
	waits:   [MAX_SYSTEMS][MAX_SYSTEMS / 64]u64,
	built:   bool,
	failed:  bool,
}

@(private)
System :: struct {
	name:         string,
	procedure:    System_Proc,
	stage:        Stage,
	query:        Query,
	batch_chunks: int,
	reads:        [MAX_SYSTEM_ACCESS]Component_Id,
	read_count:   int,
	writes:       [MAX_SYSTEM_ACCESS]Component_Id,
	write_count:  int,
	after:        [MAX_SYSTEM_AFTER]string,
	after_count:  int,
}

// register_system adds a system. Systems are registrations: reload clears them, and the game registers them again.
register_system :: proc(w: ^World, desc: System_Desc) -> bool {
	s := &w.schedule
	if s.count == MAX_SYSTEMS || len(desc.after) > MAX_SYSTEM_AFTER || desc.procedure == nil {
		log.errorf("ecs: cannot register system %s", desc.name)
		return false
	}
	for &other in s.systems[:s.count] {
		if other.name == desc.name {
			log.errorf("ecs: system %s is registered twice", desc.name)
			return false
		}
	}
	sys := System {
		name         = desc.name,
		procedure    = desc.procedure,
		stage        = desc.stage,
		batch_chunks = desc.batch_chunks > 0 ? desc.batch_chunks : DEFAULT_BATCH_CHUNKS,
		after_count  = len(desc.after),
	}
	copy(sys.after[:], desc.after)
	for term in desc.terms {
		switch term.access {
		case .Read:
			add_access(&sys.reads, &sys.read_count, term.id) or_return
		case .Write:
			add_access(&sys.writes, &sys.write_count, term.id) or_return
		case .Without:
		}
	}
	for id in desc.reads {
		add_access(&sys.reads, &sys.read_count, id) or_return
	}
	for id in desc.writes {
		add_access(&sys.writes, &sys.write_count, id) or_return
	}
	if len(desc.terms) > 0 {
		sys.query = query(w, desc.terms)
		if sys.query == 0 {
			return false
		}
	}
	s.systems[s.count] = sys
	s.count += 1
	s.built = false
	return true
}

// run_fixed advances the world time by dt and runs the fixed ticks that are due, at most MAX_TICKS_PER_FRAME.
// Each tick copies Transform to Previous_Transform, runs the Fixed systems, applies their commands and propagates
// transforms. It returns the number of ticks.
run_fixed :: proc(w: ^World, dt: time.Duration, user: rawptr) -> (ticks: int) {
	c := &w.clock
	c.time += dt
	for tick_start(c, c.tick + 1) <= c.time {
		if ticks == MAX_TICKS_PER_FRAME {
			log.warnf("ecs: the simulation is behind, so it dropped %v", c.time - tick_start(c, c.tick))
			c.time = tick_start(c, c.tick)
			break
		}
		snapshot_previous(w)
		run_systems(w, .Fixed, 1 / f32(c.tick_rate), user, ticks == 0)
		propagate(w)
		c.tick += 1
		ticks += 1
	}
	start := tick_start(c, c.tick)
	c.alpha = f32(c.time - start) / f32(tick_start(c, c.tick + 1) - start)
	return
}

// run_stage runs the Update or Late systems and applies their commands. After Late, it propagates transforms.
run_stage :: proc(w: ^World, stage: Stage, dt: time.Duration, user: rawptr) {
	assert(stage != .Fixed, "ecs: run the Fixed stage with run_fixed")
	run_systems(w, stage, f32(time.duration_seconds(dt)), user, false)
	if stage == .Late {
		propagate(w)
	}
}

// update_transforms propagates transforms without running any system, as the editor's edit mode does: the world
// does not move, but an edit of a parent moves its children.
update_transforms :: proc(w: ^World) {
	propagate(w)
}

// tick_length is the time of one fixed tick, which a step of one frame advances by.
tick_length :: proc "contextless" (w: ^World) -> time.Duration {
	return time.Second / time.Duration(w.clock.tick_rate)
}

tick_start :: proc "contextless" (c: ^Clock, tick: u64) -> time.Duration {
	return c.base_time + time.Duration(i64(tick - c.base_tick) * i64(time.Second) / i64(c.tick_rate))
}

// set_tick_rate changes the rate from the next tick on.
set_tick_rate :: proc(w: ^World, rate: u32) {
	assert(rate > 0)
	c := &w.clock
	c.base_time = tick_start(c, c.tick)
	c.base_tick = c.tick
	c.tick_rate = rate
}

@(private)
reset_schedule :: proc(w: ^World) {
	w.schedule.count = 0
	w.schedule.built = false
	w.schedule.failed = false
}

@(private)
Range_Proc :: #type proc(w: ^World, data: rawptr, first, count: int)

// parallel_for runs procedure over [0, total) in jobs of batch items, and waits for them.
@(private)
parallel_for :: proc(w: ^World, total, batch: int, procedure: Range_Proc, data: rawptr) {
	if total == 0 {
		return
	}
	n := (total + batch - 1) / batch
	ranges := make([]Range_Job, n, w.platform.frame_allocator)
	list := make([]jobs.Job, n, w.platform.frame_allocator)
	for &r, i in ranges {
		r = {procedure, w, data, i * batch, min(batch, total - i * batch)}
		list[i] = {run_range, &r}
	}
	counter: jobs.Counter
	w.platform.jobs_run(list, &counter)
	w.platform.jobs_wait(&counter)
}

@(private = "file")
Range_Job :: struct {
	procedure:    Range_Proc,
	world:        ^World,
	data:         rawptr,
	first, count: int,
}

@(private = "file")
run_range :: proc(data: rawptr) {
	r := (^Range_Job)(data)
	r.procedure(r.world, r.data, r.first, r.count)
}

// A system's driver job waits for the systems before it, then runs the system's batches.
@(private = "file")
Driver :: struct {
	run:     proc(job_list: []jobs.Job, counter: ^jobs.Counter),
	wait:    proc(counter: ^jobs.Counter),
	waits:   []^jobs.Counter,
	batches:    []Batch,
	batch_jobs: []jobs.Job,
	done:       jobs.Counter,
}

@(private = "file")
Batch :: struct {
	procedure: System_Proc,
	ctx:       System_Context,
	commands:  Commands,
}

@(private = "file")
run_systems :: proc(w: ^World, stage: Stage, dt: f32, user: rawptr, first_tick: bool) {
	s := &w.schedule
	if !s.built && !s.failed && !build_schedule(w) {
		s.failed = true
	}
	if s.failed {
		return
	}
	order := s.order[stage][:s.ordered[stage]]
	if len(order) == 0 {
		return
	}

	allocator := w.platform.frame_allocator
	drivers := make([]Driver, len(order), allocator)
	position: [MAX_SYSTEMS]int
	buffer_count := 0
	for index, p in order {
		position[index] = p
		sys := &s.systems[index]
		batch_count := 1
		if sys.query != 0 {
			chunks := query_chunk_count(w, sys.query)
			batch_count = (chunks + sys.batch_chunks - 1) / sys.batch_chunks
		}
		d := &drivers[p]
		d.run = w.platform.jobs_run
		d.wait = w.platform.jobs_wait
		d.batches = make([]Batch, batch_count, allocator)
		d.batch_jobs = make([]jobs.Job, batch_count, allocator)
		for &b, i in d.batches {
			b = {
				procedure = sys.procedure,
				commands = commands(allocator),
			}
			b.ctx = {
				world       = w,
				user        = user,
				query       = sys.query,
				first_chunk = i * sys.batch_chunks,
				chunk_count = sys.batch_chunks,
				dt          = dt,
				first_tick  = first_tick,
				commands    = &b.commands,
			}
			d.batch_jobs[i] = {run_batch, &b}
		}
		buffer_count += batch_count

		waits := make([dynamic]^jobs.Counter, allocator)
		for earlier in order[:p] {
			if s.waits[index][earlier / 64] & (1 << (earlier % 64)) != 0 {
				append(&waits, &drivers[position[earlier]].done)
			}
		}
		d.waits = waits[:]
	}

	// Each driver starts after the drivers that it waits for, so their counters are already raised.
	for &d in drivers {
		w.platform.jobs_run([]jobs.Job{{run_driver, &d}}, &d.done)
	}
	buffers := make([dynamic]Commands, 0, buffer_count, allocator)
	for &d in drivers {
		w.platform.jobs_wait(&d.done)
		for b in d.batches {
			append(&buffers, b.commands)
		}
	}
	apply(w, buffers[:])
}

@(private = "file")
run_driver :: proc(data: rawptr) {
	d := (^Driver)(data)
	for counter in d.waits {
		d.wait(counter)
	}
	batches: jobs.Counter
	d.run(d.batch_jobs, &batches)
	d.wait(&batches)
}

@(private = "file")
run_batch :: proc(data: rawptr) {
	b := (^Batch)(data)
	b.procedure(&b.ctx)
}

// build_schedule orders each stage and finds what each system waits for. A system runs after the systems that it
// names in after. Otherwise registration order is kept. A system waits for every earlier system whose access
// conflicts with its own, and for the systems in its after.
@(private = "file")
build_schedule :: proc(w: ^World) -> bool {
	s := &w.schedule
	after: [MAX_SYSTEMS][MAX_SYSTEM_AFTER]int
	for &sys, i in s.systems[:s.count] {
		for name, a in sys.after[:sys.after_count] {
			after[i][a] = -1
			for &other, j in s.systems[:s.count] {
				if other.name == name && other.stage == sys.stage {
					after[i][a] = j
				}
			}
			if after[i][a] < 0 {
				log.errorf("ecs: system %s runs after %s, which is not in its stage", sys.name, name)
				return false
			}
		}
	}

	s.waits = {}
	for stage in Stage {
		placed: [MAX_SYSTEMS]bool
		in_stage := 0
		for &sys in s.systems[:s.count] {
			if sys.stage == stage {
				in_stage += 1
			}
		}
		s.ordered[stage] = 0
		for s.ordered[stage] < in_stage {
			next := -1
			candidates: for &sys, i in s.systems[:s.count] {
				if sys.stage != stage || placed[i] {
					continue
				}
				for a in after[i][:sys.after_count] {
					if !placed[a] {
						continue candidates
					}
				}
				next = i
				break
			}
			if next < 0 {
				log.errorf("ecs: the after lists of the %v systems form a cycle", stage)
				return false
			}
			placed[next] = true
			s.order[stage][s.ordered[stage]] = u16(next)
			s.ordered[stage] += 1
		}

		order := s.order[stage][:s.ordered[stage]]
		for index, p in order {
			sys := &s.systems[index]
			for earlier in order[:p] {
				named := false
				for a in after[index][:sys.after_count] {
					if a == int(earlier) {
						named = true
					}
				}
				if named || conflicts(sys, &s.systems[earlier]) {
					s.waits[index][earlier / 64] |= 1 << (earlier % 64)
				}
			}
		}
	}
	s.built = true
	return true
}

@(private = "file")
conflicts :: proc(a, b: ^System) -> bool {
	a_reads, a_writes := a.reads[:a.read_count], a.writes[:a.write_count]
	b_reads, b_writes := b.reads[:b.read_count], b.writes[:b.write_count]
	return overlaps(a_writes, b_reads) || overlaps(a_writes, b_writes) || overlaps(a_reads, b_writes)
}

@(private = "file")
overlaps :: proc(a, b: []Component_Id) -> bool {
	for x in a {
		for y in b {
			if x == y {
				return true
			}
		}
	}
	return false
}

@(private = "file")
add_access :: proc(list: ^[MAX_SYSTEM_ACCESS]Component_Id, count: ^int, id: Component_Id) -> bool {
	if count^ == MAX_SYSTEM_ACCESS {
		log.errorf("ecs: a system has more than %d accesses", MAX_SYSTEM_ACCESS)
		return false
	}
	list[count^] = id
	count^ += 1
	return true
}
