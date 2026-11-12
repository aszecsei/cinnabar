package ai

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:core/luau"
import core_physics "cinnabar:core/physics"
import physics_host "cinnabar:core/physics/host"
import physics_jolt "cinnabar:core/physics/jolt"
import script_host "cinnabar:core/script"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/script"

// Perception's tests run on Jolt: walls are static colliders, and the rays are the backend's.

@(private = "file")
Fixture :: struct {
	frame:    virtual.Arena,
	platform: core.Platform_API,
	host:     core_physics.Host,
	world:    ecs.World,
	physics:  physics.State,
	cache:    string,
	assets:   asset.Assets,
	ai:       State,
	serial:   bool,
	scripts:  bool,
	runtime:  script.Runtime,
	agent:    ecs.Entity,
	reports:  [dynamic]f64,
}

@(private = "file")
BOARD :: format.Guid {
	0 = 0xb1,
}
@(private = "file")
DECISION :: format.Guid {
	0 = 0xd1,
}
@(private = "file")
PERCEPTION :: format.Guid {
	0 = 0xe1,
}
// A perception with a row whose key the blackboard does not have.
@(private = "file")
EXTRA :: format.Guid {
	0 = 0xe2,
}
@(private = "file")
BOARD_KEY :: 91

// The tags: Player 0, Enemy 1, Noise_Maker 2.
@(private = "file")
PLAYER :: 0
@(private = "file")
ENEMY :: 1

@(private = "file")
board_contents :: proc() -> format.Blackboard_Contents {
	keys := make([]format.Blackboard_Key_Contents, 6, context.temp_allocator)
	keys[0] = {
		name = "target",
		type = .Entity,
	}
	keys[1] = {
		name = "target_position",
		type = .Position,
	}
	keys[2] = {
		name = "target_visible",
		type = .Bool,
	}
	keys[3] = {
		name = "target_since",
		type = .Float,
	}
	keys[4] = {
		name = "heard",
		type = .Bool,
	}
	keys[5] = {
		name = "heard_position",
		type = .Position,
	}
	return {guid = BOARD, key = BOARD_KEY, keys = keys}
}

// The test perception notices players and noise makers, and fills the test blackboard:
//
//	target = nearest Player, target_position = position target, target_visible = visible target,
//	target_since = since target, heard = heard noise, heard_position = loudest noise
@(private = "file")
perception_contents :: proc(guid := PERCEPTION, extra := false) -> format.Perception_Contents {
	rows := make([dynamic]format.Perception_Row_Contents, context.temp_allocator)
	append(
		&rows,
		format.Perception_Row_Contents{key = "target", source = .Nearest, tag = "Player", of = format.PERCEPTION_NONE},
		format.Perception_Row_Contents{key = "target_position", source = .Position, of = 0},
		format.Perception_Row_Contents{key = "target_visible", source = .Visible, of = 0},
		format.Perception_Row_Contents{key = "target_since", source = .Since, of = 0},
		format.Perception_Row_Contents{key = "heard", source = .Heard_Noise, of = format.PERCEPTION_NONE},
		format.Perception_Row_Contents{key = "heard_position", source = .Loudest_Noise, of = format.PERCEPTION_NONE},
	)
	if extra {
		append(&rows, format.Perception_Row_Contents{key = "missing", source = .Nearest, of = format.PERCEPTION_NONE})
	}
	return {
		guid = guid,
		key = 17 if !extra else 18,
		notices = slice.clone([]string{"Player", "Noise_Maker"}, context.temp_allocator),
		rows = rows[:],
		source_path = "game/ai/test.perception",
	}
}

// setup makes a world on Jolt with the AI's and physics' components and systems, a module that does nothing, and the
// test blobs. serial runs every job at once on the calling thread; otherwise the scheduler has workers threads.
@(private = "file")
setup :: proc(t: ^testing.T, serial := true, workers := 0, scripts := false) -> ^Fixture {
	sync.lock(&test_lock)
	f := new(Fixture)
	f.serial = serial
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.host = physics_host.table()
	api := physics_jolt.load(&f.host)
	physics_host.bind(api)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		jobs_run = jobs.run,
		jobs_wait = jobs.wait,
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
		physics = api^,
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
		script_open = script_host.open,
		script_close = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom = script_host.atom,
		script_direct_access = script_host.direct_access,
	}
	if serial {
		f.platform.jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		}
		f.platform.jobs_wait = proc(counter: ^jobs.Counter) {}
	} else {
		testing.expect(t, jobs.init(workers))
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	register_components(&f.world.registry)
	physics.register_components(&f.world.registry)
	script.register_components(&f.world.registry)
	cache, err := os.make_directory_temp("", "perception_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.cache = cache
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.cache))
	testing.expect(t, physics.init(&f.physics, &f.platform, assets = &f.assets))
	physics.register(&f.physics, &f.world)
	init(&f.ai, &f.platform, &f.assets, &f.runtime if scripts else nil, &f.physics)
	register(&f.ai, &f.world)
	register_module(&f.ai, .Behavior_Tree, {
		think = proc(t: ^Think_Context) {},
	})
	tags: Tag_Names
	for name in ([]string{"Player", "Enemy", "Noise_Maker"}) {
		add_tag_name(&tags, name)
	}
	set_tags(&f.ai, tags)
	if scripts {
		f.scripts = true
		f.reports = make([dynamic]f64)
		context.user_ptr = f
		testing.expect(t, script.init(&f.runtime, &f.platform, &f.world, nil, register_perception_scripts))
	}
	write :: proc(t: ^testing.T, f: ^Fixture, guid: format.Guid, data: []byte) {
		buffer: [32]u8
		path := fmt.tprintf("%s/%s.blob", f.cache, format.guid_format(guid, &buffer))
		testing.expect(t, os.write_entire_file(path, data) == nil)
	}
	write(t, f, BOARD, format.blackboard_write(board_contents(), context.temp_allocator))
	decision := format.Decision_Contents {
		guid           = DECISION,
		key            = 5,
		technique      = .Behavior_Tree,
		blackboard     = BOARD,
		blackboard_key = BOARD_KEY,
		source_path    = "game/ai/test.decision",
	}
	write(t, f, DECISION, format.decision_write(decision, context.temp_allocator))
	write(t, f, PERCEPTION, format.perception_write(perception_contents(), context.temp_allocator))
	write(t, f, EXTRA, format.perception_write(perception_contents(EXTRA, extra = true), context.temp_allocator))
	return f
}

@(private = "file")
register_perception_scripts :: proc(r: ^script.Runtime) {
	f := (^Fixture)(context.user_ptr)
	register_scripts(r, &f.ai)
	script.define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
	script.define(r, "Test.agent", proc(L: ^luau.State) -> c.int {
		script.push_entity(L, (^Fixture)(context.user_ptr).agent)
		return 1
	})
}

@(private = "file")
teardown :: proc(t: ^testing.T, f: ^Fixture) {
	if f.scripts {
		script.destroy(&f.runtime)
		delete(f.reports)
	}
	destroy(&f.ai)
	physics.destroy(&f.physics)
	testing.expect_value(t, f.platform.physics.world_destroy_all(), 0)
	asset.destroy(&f.assets)
	os.remove_all(f.cache)
	delete(f.cache)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	if !f.serial {
		testing.expect(t, jobs.drain_frame())
		jobs.shutdown()
	}
	free(f)
	sync.unlock(&test_lock)
}

// frame runs frames of one fixed tick each as the game does: prepare, the tick's systems, the scripts' fixed step, the
// physics tick, perception's events, and the frame's end. The views are read again after, so the test can look.
@(private = "file")
frame :: proc(f: ^Fixture, n := 1) {
	context.user_ptr = f
	for _ in 0 ..< n {
		free_all(f.platform.frame_allocator)
		prepare(&f.ai, &f.world)
		clock := &f.world.clock
		it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
		for ecs.next_tick(&it) {
			ecs.run_tick_systems(&it, f)
			if f.scripts {
				script.fixed_update(&f.runtime, &it, {})
			}
			ecs.update_transforms(&f.world)
			physics.tick(&f.physics, &f.world)
			if f.scripts {
				send_events(&f.ai, &f.world, &f.runtime)
				script.fixed_events(&f.runtime)
			}
			ecs.update_transforms(&f.world)
		}
		end_frame(&f.ai)
	}
	free_all(f.platform.frame_allocator)
	prepare(&f.ai, &f.world)
}

@(private = "file")
at :: proc(x, y, z: f32) -> ecs.World_Position {
	return ecs.position_offset({}, {x, y, z})
}

// TURNED faces -Z.
@(private = "file")
TURNED :: quaternion(w = 0, x = 0, y = 1, z = 0)

// spawn_perceiver is an agent that perceives, facing +Z, with its eye 1.7 m up.
@(private = "file")
spawn_perceiver :: proc(f: ^Fixture, position: ecs.World_Position, perception := PERCEPTION, memory: f32 = 5) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = position, rotation = 1, scale = 1})
	ecs.add(&f.world, e, Agent{blackboard = BOARD, decision = DECISION})
	p := DEFAULT_PERCEIVER
	p.perception, p.memory = perception, memory
	ecs.add(&f.world, e, p)
	return e
}

// spawn_target is a Perceivable with the points given, or one 1 m up.
@(private = "file")
spawn_target :: proc(f: ^Fixture, position: ecs.World_Position, tag: u8 = PLAYER, points: ..[3]f32) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = position, rotation = 1, scale = 1})
	p := DEFAULT_PERCEIVABLE
	p.tag = tag
	if len(points) > 0 {
		offsets := [MAX_SIGHT_POINTS]^[3]f32{&p.points.p0, &p.points.p1, &p.points.p2, &p.points.p3}
		for point, i in points {
			offsets[i]^ = point
		}
		p.point_count = u8(len(points))
	}
	ecs.add(&f.world, e, p)
	return e
}

// wall is a static box of a size, in meters, at its center.
@(private = "file")
wall :: proc(f: ^Fixture, center: ecs.World_Position, size: [3]f32) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = center, rotation = 1, scale = 1})
	c := physics.DEFAULT_COLLIDER
	c.size = size
	ecs.add(&f.world, e, c)
	return e
}

@(private = "file")
memory_of :: proc(f: ^Fixture, e: ecs.Entity) -> ^Perception_Memory {
	return perception_debug(&f.ai, e)
}

// entry_of is what a perceiver remembers of an entity.
@(private = "file")
entry_of :: proc(f: ^Fixture, e, other: ecs.Entity) -> (Memory_Entry, bool) {
	m := memory_of(f, e)
	if m == nil {
		return {}, false
	}
	for entry in m.entries[:m.count] {
		if entry.entity == other {
			return entry, true
		}
	}
	return {}, false
}

@(private = "file")
sees :: proc(f: ^Fixture, e, other: ecs.Entity) -> bool {
	entry, found := entry_of(f, e, other)
	return found && entry.seen
}

@(private = "file")
key :: proc(f: ^Fixture, e: ecs.Entity, name: string) -> Value {
	v, _ := get_key(&f.ai, e, name)
	return v
}

// A perceiver sees a target in its cone and its range, and not one behind it, beside its cone or past its range. Turned
// around, it sees the one behind, which its blackboard's target becomes.
@(test)
sight_finds_a_target_in_the_cone_and_not_out_of_it :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	p := spawn_perceiver(f, {})
	ahead := spawn_target(f, at(0, 0, 10))
	behind := spawn_target(f, at(0, 0, -6))
	beside := spawn_target(f, at(12, 0, 5))
	far := spawn_target(f, at(0, 0, 30))
	frame(f, 3)
	testing.expect(t, sees(f, p, ahead), "the target ahead")
	for other in ([]ecs.Entity{behind, beside, far}) {
		_, found := entry_of(f, p, other)
		testing.expectf(t, !found, "%v is out of the cone or the range", other)
	}
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), ahead)
	testing.expect_value(t, key(f, p, "target_visible").(bool), true)
	testing.expect_value(t, key(f, p, "target_position").(ecs.World_Position), at(0, 0, 10))

	ecs.get_write(&f.world, p, ecs.Transform).rotation = TURNED
	frame(f)
	testing.expect(t, sees(f, p, behind), "the target behind, once it turned")
	testing.expect(t, !sees(f, p, ahead), "the target now behind it")
	// The one that it sees now comes before the one that it remembers.
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), behind)
}

// A wall between a perceiver and its target hides it. The perceiver's own collider and the target's do not, and the
// target is remembered where it was last seen.
@(test)
a_wall_blocks_sight :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	p := spawn_perceiver(f, {})
	body := physics.DEFAULT_COLLIDER
	body.size = {1, 4, 1}
	ecs.add(&f.world, p, body)
	target := spawn_target(f, at(0, 0, 10), PLAYER, {0, 0, 0})
	ecs.add(&f.world, target, physics.DEFAULT_COLLIDER)
	frame(f, 3)
	testing.expect(t, sees(f, p, target), "nothing is between them")
	m := memory_of(f, p)
	testing.expect(t, m.ray_count == 1 && !m.rays[0].blocked)

	wall(f, at(0, 1, 5), {10, 10, 1})
	physics.sync(&f.physics, &f.world)
	frame(f)
	testing.expect(t, !sees(f, p, target), "the wall hides it")
	m = memory_of(f, p)
	testing.expect(t, m.ray_count == 1 && m.rays[0].blocked)
	entry, found := entry_of(f, p, target)
	testing.expect(t, found && entry.position == at(0, 0, 10) && entry.since > 0)
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), target)
	testing.expect_value(t, key(f, p, "target_visible").(bool), false)
	testing.expect(t, key(f, p, "target_since").(f32) > 0)
}

// Behind low cover, a target is seen by its head, and one with only its body's point is not.
@(test)
a_target_behind_low_cover_is_seen_by_its_head :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	p := spawn_perceiver(f, {})
	wall(f, at(0, 0.7, 5), {10, 1.4, 1})
	tall := spawn_target(f, at(-1, 0, 10), PLAYER, {0, 0.5, 0}, {0, 1.7, 0})
	short := spawn_target(f, at(1, 0, 10), PLAYER, {0, 0.5, 0})
	frame(f, 3)
	testing.expect(t, sees(f, p, tall), "its head shows over the cover")
	testing.expect(t, !sees(f, p, short), "its body is behind the cover")
	m := memory_of(f, p)
	blocked := 0
	for r in m.rays[:m.ray_count] {
		blocked += int(r.blocked)
	}
	testing.expect_value(t, m.ray_count, 3)
	testing.expect_value(t, blocked, 2)
}

// targets_in_front are eight Perceivables of four points each in front of the perceivers, so each perceiver's check
// takes MAX_PERCEIVER_RAYS rays.
@(private = "file")
targets_in_front :: proc(f: ^Fixture) {
	for i in 0 ..< MAX_SIGHT_TARGETS {
		spawn_target(f, at(f32(i) - 3.5, 0, 10), PLAYER, {0, 0.2, 0}, {0, 0.6, 0}, {0, 1, 0}, {0, 1.4, 0})
	}
}

// With a budget of one perceiver's rays in a tick, perceivers take turns by slot, and each comes back in its turn.
@(test)
the_ray_budget_spreads_perceivers_over_ticks :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	set_sight_budget(&f.ai, 1)
	testing.expect_value(t, f.ai.sight_budget, MAX_PERCEIVER_RAYS)
	perceivers := [3]ecs.Entity{spawn_perceiver(f, at(-1, 0, 0)), spawn_perceiver(f, {}), spawn_perceiver(f, at(1, 0, 0))}
	targets_in_front(f)
	frame(f, 2)
	counts :: proc(f: ^Fixture, perceivers: [3]ecs.Entity) -> (out: [3]int) {
		for p, i in perceivers {
			if m := memory_of(f, p); m != nil {
				out[i] = m.count
			}
		}
		return
	}
	frame(f)
	testing.expect_value(t, counts(f, perceivers), [3]int{8, 0, 0})
	frame(f)
	testing.expect_value(t, counts(f, perceivers), [3]int{8, 8, 0})
	frame(f)
	testing.expect_value(t, counts(f, perceivers), [3]int{8, 8, 8})
	testing.expect_value(t, f.ai.sight_cursor, i64(2))
	// The first comes back: its rays are of this tick.
	before := memory_of(f, perceivers[0]).eye
	ecs.get_write(&f.world, perceivers[0], ecs.Transform).position = at(-1, 0, 0.5)
	frame(f)
	testing.expect(t, memory_of(f, perceivers[0]).eye != before, "the first perceiver's turn came again")
	testing.expect_value(t, memory_of(f, perceivers[0]).ray_count, MAX_PERCEIVER_RAYS)

	// With room for all, each checks in every tick, and a lap ends on the one before where it began.
	set_sight_budget(&f.ai, 1000)
	frame(f)
	testing.expect_value(t, f.ai.sight_cursor, i64(0))
	for p in perceivers {
		testing.expect_value(t, memory_of(f, p).ray_count, MAX_PERCEIVER_RAYS)
	}
}

// A seen target stays seen while its perceiver waits for its turn, and is hidden when a ray finds the wall.
@(test)
a_seen_target_stays_seen_until_a_ray_finds_it_hidden :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	set_sight_budget(&f.ai, MAX_PERCEIVER_RAYS)
	first, second := spawn_perceiver(f, at(-1, 0, 0)), spawn_perceiver(f, at(1, 0, 0))
	targets_in_front(f)
	frame(f, 4)
	seen :: proc(f: ^Fixture, p: ecs.Entity) -> int {
		m := memory_of(f, p)
		n := 0
		for e in m.entries[:m.count] {
			n += int(e.seen)
		}
		return n
	}
	testing.expect(t, seen(f, first) == 8 && seen(f, second) == 8)
	wall(f, at(0, 1, 5), {20, 10, 1})
	physics.sync(&f.physics, &f.world)
	// The first's turn: it finds them hidden, and the second still sees them.
	frame(f)
	testing.expect_value(t, seen(f, first), 0)
	testing.expect_value(t, seen(f, second), 8)
	testing.expect_value(t, key(f, second, "target_visible").(bool), true)
	// The second's turn.
	frame(f)
	testing.expect_value(t, seen(f, second), 0)
}

// A noise is heard in the tick after it is made, and only in that one. A wall halves its range, so a far noise behind
// one is not heard and a loud one is. A noise of a tag that the perceiver does not notice, or past its range, is not
// heard, and a noise's source is remembered where it was heard.
@(test)
a_noise_is_heard_in_the_next_tick_and_an_occluded_one_is_not :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	p := spawn_perceiver(f, {})
	frame(f, 3)
	testing.expect_value(t, key(f, p, "heard").(bool), false)

	noise(&f.ai, at(0, 0, 8), 10, "Noise_Maker")
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), true)
	testing.expect_value(t, key(f, p, "heard_position").(ecs.World_Position), at(0, 0, 8))
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), false)
	testing.expect_value(t, key(f, p, "heard_position").(ecs.World_Position), at(0, 0, 8))

	noise(&f.ai, at(0, 0, 8), 10, "Enemy")
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), false)
	noise(&f.ai, at(0, 0, 8), 5, "Noise_Maker")
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), false)

	wall(f, at(0, 1, 4), {10, 10, 1})
	physics.sync(&f.physics, &f.world)
	noise(&f.ai, at(0, 0, 9), 10, "Noise_Maker")
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), false)
	noise(&f.ai, at(0, 0, 9), 10, "Noise_Maker")
	noise(&f.ai, at(1, 0, 9), 20, "Noise_Maker")
	frame(f)
	testing.expect_value(t, key(f, p, "heard").(bool), true)
	testing.expect_value(t, key(f, p, "heard_position").(ecs.World_Position), at(1, 0, 9))

	// A player's footsteps behind the perceiver: it remembers the player by hearing, and does not see it.
	player := spawn_target(f, at(0, 0, -6))
	noise(&f.ai, at(0, 0, -6), 10, "Player", player)
	frame(f)
	entry, found := entry_of(f, p, player)
	testing.expect(t, found && entry.heard && !entry.seen && entry.sense == .Hearing)
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), player)
	testing.expect_value(t, key(f, p, "target_visible").(bool), false)

	// A noise of a tag that the project does not give is dropped.
	context.logger = testlog.expected_errors()
	noise(&f.ai, at(0, 0, 3), 10, "Nope")
	testing.expect_value(t, len(f.ai.noises_pending), 0)
}

// An entity that is not perceived is forgotten after the perceiver's memory, and one that goes is forgotten at once.
@(test)
a_perceived_entity_is_forgotten_after_its_memory :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	p := spawn_perceiver(f, {}, memory = 0.5)
	target := spawn_target(f, at(0, 0, 10))
	other := spawn_target(f, at(1, 0, 10))
	frame(f, 3)
	testing.expect(t, sees(f, p, target) && sees(f, p, other))
	ecs.get_write(&f.world, p, ecs.Transform).rotation = TURNED
	rate := int(f.world.clock.tick_rate)
	frame(f, rate * 4 / 10)
	_, found := entry_of(f, p, target)
	testing.expect(t, found, "remembered after 0.4 s")
	frame(f, rate * 2 / 10)
	_, found = entry_of(f, p, target)
	testing.expect(t, !found, "forgotten after 0.6 s")
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), ecs.Entity(0))
	testing.expect_value(t, key(f, p, "target_visible").(bool), false)

	ecs.get_write(&f.world, p, ecs.Transform).rotation = 1
	frame(f)
	testing.expect(t, sees(f, p, target))
	ecs.despawn(&f.world, target)
	frame(f)
	_, found = entry_of(f, p, target)
	testing.expect(t, !found, "an entity that went is forgotten at once")
}

// The rows fill the keys that the blackboard has, and a row whose key it does not have is warned about and skipped.
@(test)
rows_fill_the_keys_that_the_blackboard_has :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(t, f)
	context.logger = testlog.expected_errors()
	p := spawn_perceiver(f, {}, EXTRA)
	target := spawn_target(f, at(0, 0, 10))
	enemy := spawn_target(f, at(0, 0, 5), ENEMY)
	frame(f, 3)
	// The enemy is not noticed, so the target is the player.
	_, found := entry_of(f, p, enemy)
	testing.expect(t, !found, "the perception does not notice enemies")
	testing.expect_value(t, key(f, p, "target").(ecs.Entity), target)
	testing.expect_value(t, key(f, p, "target_since").(f32), 0)
	m := memory_of(f, p)
	testing.expect(t, m.checked_rows == 18 && m.checked_board == BOARD_KEY, "the rows were checked against the blackboard")
}

// A perceiver's behaviours get on_perceive when it begins to perceive an entity, by sight or hearing, and on_forget when
// it forgets one. Scripts make noises, which are heard in the next tick.
@(test)
behaviours_get_on_perceive_and_on_forget :: proc(t: ^testing.T) {
	f := setup(t, scripts = true)
	defer teardown(t, f)
	context.user_ptr = f
	f.agent = spawn_perceiver(f, {})
	target := spawn_target(f, at(0, 0, 10))
	_, ok := script.spawn_source(
		&f.runtime,
		"=watcher",
		`
local Watcher = Behaviour.define("Watcher")
function Watcher:on_perceive(other, sense) Test.report(if sense == "sight" then 1 else 2) end
function Watcher:on_forget(other) Test.report(3) end
Test.agent():add(Watcher)
`,
	)
	testing.expect(t, ok)
	frame(f, 3)
	testing.expectf(t, slice.equal(f.reports[:], []f64{1}), "%v", f.reports[:])
	clear(&f.reports)
	frame(f)
	testing.expectf(t, len(f.reports) == 0, "an entity that stays seen is perceived once: %v", f.reports[:])
	ecs.despawn(&f.world, target)
	frame(f)
	testing.expectf(t, slice.equal(f.reports[:], []f64{3}), "%v", f.reports[:])
	clear(&f.reports)

	player := spawn_target(f, at(0, 0, -6))
	f.agent = player
	_, ok = script.spawn_source(
		&f.runtime,
		"=footsteps",
		`
local Footsteps = Behaviour.define("Footsteps")
function Footsteps:fixed_update()
	if self.done then return end
	self.done = true
	Perception.noise(WorldPosition.from_meters(0, 0, -6), 10, "Player", self.entity)
	local ok = pcall(Perception.noise, WorldPosition.origin, 10, "Nope")
	Test.report(if ok then 10 else 20)
end
Test.agent():add(Footsteps)
`,
	)
	testing.expect(t, ok)
	// The noise is made in the scripts' fixed step, after the tick's perception, so it is heard in the next tick.
	for _ in 0 ..< 3 {
		if len(f.reports) > 0 {
			break
		}
		frame(f)
	}
	testing.expectf(t, slice.equal(f.reports[:], []f64{20}), "an unknown tag raises an error, and nothing is heard yet: %v", f.reports[:])
	frame(f)
	testing.expectf(t, slice.equal(f.reports[:], []f64{20, 2}), "the footsteps are heard: %v", f.reports[:])
}

// The perceptions of a crowd, with walls, moving targets and noises, are the same on one job and on eight workers,
// with a budget that spreads the perceivers over ticks and one that has room for all.
@(test)
perception_is_the_same_on_one_job_and_many :: proc(t: ^testing.T) {
	Outcome :: struct {
		count:  int,
		seen:   int,
		rays:   int,
		target: ecs.Entity,
		heard:  bool,
	}
	run :: proc(t: ^testing.T, serial: bool, budget: int) -> [dynamic]Outcome {
		f := setup(t, serial = serial, workers = 0 if serial else 8)
		defer teardown(t, f)
		set_sight_budget(&f.ai, budget)
		perceivers := make([dynamic]ecs.Entity, context.temp_allocator)
		targets := make([dynamic]ecs.Entity, context.temp_allocator)
		for i in 0 ..< 100 {
			e := spawn_perceiver(f, at(f32(i % 10) * 3, 0, f32(i / 10) * 3))
			if i % 2 == 1 {
				ecs.get_write(&f.world, e, ecs.Transform).rotation = TURNED
			}
			append(&perceivers, e)
		}
		for i in 0 ..< 20 {
			append(&targets, spawn_target(f, at(f32(i % 5) * 7, 0, f32(i / 5) * 7 + 1), PLAYER, {0, 0.5, 0}, {0, 1.7, 0}))
		}
		for i in 0 ..< 6 {
			wall(f, at(f32(i) * 5, 0.6, 14), {2, 1.2, 0.5})
		}
		outcomes := make([dynamic]Outcome)
		for tick in 0 ..< 12 {
			for e, i in targets {
				ecs.get_write(&f.world, e, ecs.Transform).position = at(f32(i % 5) * 7 + f32(tick) * 0.5, 0, f32(i / 5) * 7 + 1)
			}
			if tick % 3 == 0 {
				noise(&f.ai, at(f32(tick), 0, 12), 15, "Noise_Maker")
				noise(&f.ai, at(f32(tick), 0, 4), 8, "Player", targets[tick])
			}
			frame(f)
			for p in perceivers {
				o: Outcome
				if m := memory_of(f, p); m != nil {
					o.count, o.rays = m.count, m.ray_count
					for e in m.entries[:m.count] {
						o.seen += int(e.seen)
					}
				}
				target, _ := get_key(&f.ai, p, "target")
				heard, _ := get_key(&f.ai, p, "heard")
				o.target = target.(ecs.Entity) or_else 0
				o.heard = heard.(bool) or_else false
				append(&outcomes, o)
			}
		}
		return outcomes
	}
	for budget in ([?]int{MAX_PERCEIVER_RAYS, 1000}) {
		one := run(t, true, budget)
		defer delete(one)
		many := run(t, false, budget)
		defer delete(many)
		testing.expectf(t, slice.equal(one[:], many[:]), "budget %d: the outcomes differ", budget)
		seen := 0
		for o in one {
			seen += o.seen
		}
		testing.expectf(t, seen > 0, "budget %d: nothing was seen", budget)
	}
}
