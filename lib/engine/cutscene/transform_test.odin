package cutscene

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

@(private = "file")
SECOND :: format.CUTSCENE_TICKS_PER_SECOND

@(private = "file")
MOVE_GUID :: format.Guid {
	0  = 0x73,
	15 = 1,
}

@(private = "file")
SCENE_GUID :: format.Guid {
	0  = 0x73,
	15 = 2,
}

// FAR is 2^30 m from the world's origin, where an f32 of meters steps by 128 m.
@(private = "file")
FAR :: f64(1 << 30)

@(private = "file")
Move_Fixture :: struct {
	frame:     virtual.Arena,
	platform:  core.Platform_API,
	world:     ecs.World,
	assets:    asset.Assets,
	cutscenes: State,
	// The entities that the cutscene's bindings 1, 2, ... name, by override.
	entities:  [dynamic]ecs.Entity,
}

// move_setup makes a world with the engine's components and the cutscenes' own kinds of track, run on one thread.
@(private = "file")
move_setup :: proc(t: ^testing.T) -> ^Move_Fixture {
	f := new(Move_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return 0},
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
	}
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	asset.init(&f.assets, &f.platform, asset.loose_cache("cutscene_transform_test_none"))
	init(&f.cutscenes, &f.world, &f.assets)
	register(&f.cutscenes, &f.world)
	f.entities = make([dynamic]ecs.Entity)
	return f
}

@(private = "file")
move_teardown :: proc(f: ^Move_Fixture) {
	destroy(&f.cutscenes, &f.world)
	asset.destroy(&f.assets)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	delete(f.entities)
	free(f)
}

// thing spawns an entity at a pose, with a Previous_Transform, so presentation interpolates it, and gives it the next
// binding.
@(private = "file")
thing :: proc(
	f: ^Move_Fixture,
	position: [3]f64,
	rotation: quaternion128 = 1,
	scale := [3]f32{1, 1, 1},
) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	pose := ecs.Transform{ecs.position_from_meters(position), rotation, scale}
	ecs.add(&f.world, e, pose)
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	append(&f.entities, e)
	return e
}

// child spawns a child of a parent at an offset, with its Transform composed, and gives it the next binding.
@(private = "file")
child :: proc(f: ^Move_Fixture, parent: ecs.Entity, offset: [3]f32) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	local := ecs.Local_Transform{offset, 1, 1}
	pose := ecs.compose(ecs.get(&f.world, parent, ecs.Transform)^, local)
	ecs.add(&f.world, e, pose)
	ecs.add(&f.world, e, ecs.Previous_Transform(pose))
	ecs.add(&f.world, e, local)
	ecs.add(&f.world, e, ecs.Parent{parent})
	append(&f.entities, e)
	return e
}

@(private = "file")
key :: proc(
	time: i32,
	value: f32,
	interp := format.Cutscene_Interp.Linear,
	flags := format.Cutscene_Key_Flags{},
) -> format.Cutscene_Key {
	return {time = time, value = value, interp = interp, flags = flags}
}

@(private = "file")
keyed :: proc(name: string, keys: ..format.Cutscene_Key) -> format.Cutscene_Channel_Contents {
	return {name = name, keys = slice_of(keys)}
}

@(private = "file")
slice_of :: proc(keys: []format.Cutscene_Key) -> []format.Cutscene_Key {
	out := make([]format.Cutscene_Key, len(keys), context.temp_allocator)
	copy(out, keys)
	return out
}

@(private = "file")
section :: proc(
	id: u32,
	channels: ..format.Cutscene_Channel_Contents,
) -> []format.Cutscene_Section_Contents {
	sections := make([]format.Cutscene_Section_Contents, 1, context.temp_allocator)
	copied := make([]format.Cutscene_Channel_Contents, len(channels), context.temp_allocator)
	copy(copied, channels)
	sections[0] = {
		id       = id,
		start    = 0,
		end      = SECOND,
		weight   = 1,
		channels = copied,
	}
	return sections
}

// move_blob is a cutscene of a length whose bindings are possessed entities, one for each of the fixture's entities.
@(private = "file")
move_blob :: proc(
	f: ^Move_Fixture,
	tracks: []format.Cutscene_Track_Contents,
	length: i32 = SECOND,
	key: u64 = 1,
) -> []byte {
	names := [?]string{"A", "B", "C", "D"}
	bindings := make([]format.Cutscene_Binding_Contents, len(f.entities), context.temp_allocator)
	for &b, i in bindings {
		b = {
			id       = u32(i + 1),
			kind     = .Possessed,
			name     = names[i],
			parent   = format.CUTSCENE_NONE,
			asset    = SCENE_GUID,
			entity   = u64(i + 1),
			rotation = {0, 0, 0, 1},
			scale    = {1, 1, 1},
		}
	}
	return format.cutscene_write(
		{
			guid = MOVE_GUID,
			key = key,
			length = length,
			rate = 30,
			range_end = length,
			bindings = bindings,
			tracks = tracks,
			source_path = "game/cutscenes/move.cutscene",
		},
		context.temp_allocator,
	)
}

@(private = "file")
overrides_of :: proc(f: ^Move_Fixture) -> []Binding_Override {
	out := make([]Binding_Override, len(f.entities), context.temp_allocator)
	for e, i in f.entities {
		out[i] = {Binding_Id(i + 1), e}
	}
	return out
}

// scrub_of evaluates a blob outside a player, as the editor's scrub does.
@(private = "file")
scrub_of :: proc(t: ^testing.T, f: ^Move_Fixture, blob: []byte) -> ^Evaluation {
	testing.expect(t, asset.set_live(&f.assets, MOVE_GUID, blob))
	h, loaded := asset.find(&f.assets, MOVE_GUID)
	testing.expect(t, loaded)
	data, _ := asset.data(&f.assets, h)
	view, ok := format.cutscene_view(data)
	testing.expect(t, ok)
	e := new(Evaluation)
	init_evaluation(e, &f.world, h, data, view)
	failure := resolve_bindings(
		&e.bindings,
		{world = &f.world, assets = &f.assets, data = data, blob = view},
		overrides_of(f),
	)
	testing.expect(t, failure == nil)
	return e
}

@(private = "file")
end_scrub :: proc(f: ^Move_Fixture, e: ^Evaluation) {
	destroy_evaluation(e, &f.world)
	free(e)
}

// scrub_to seeks an evaluation to a time and evaluates it there.
@(private = "file")
scrub_to :: proc(f: ^Move_Fixture, e: ^Evaluation, t: i32) {
	data, blob, _ := cutscene_data(&f.cutscenes, e)
	seek(&f.cutscenes, e, &f.world, data, blob, t)
	evaluate(&f.cutscenes, e, &f.world, data, blob, .Fixed)
	free_all(f.platform.frame_allocator)
}

// play_blob plays a blob through a player, which is Playing after it.
@(private = "file")
play_blob :: proc(t: ^testing.T, f: ^Move_Fixture, blob: []byte) -> Player_Handle {
	testing.expect(t, asset.set_live(&f.assets, MOVE_GUID, blob))
	h, ok := play(&f.cutscenes, &f.world, {cutscene = MOVE_GUID, overrides = overrides_of(f)})
	testing.expect(t, ok)
	update(&f.cutscenes, {world = &f.world})
	testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Playing)
	return h
}

// tick runs one fixed tick and the frame's player update, as the frame code does.
@(private = "file")
tick :: proc(f: ^Move_Fixture) {
	clock := &f.world.clock
	it := ecs.begin_ticks(&f.world, ecs.tick_start(clock, clock.tick + 1) - clock.time)
	for ecs.next_tick(&it) {
		ecs.run_tick_systems(&it, f)
		ecs.update_transforms(&f.world)
	}
	ecs.run_stage(&f.world, .Late, ecs.tick_length(&f.world), f)
	update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
	free_all(f.platform.frame_allocator)
}

@(private = "file")
pose_of :: proc(f: ^Move_Fixture, e: ecs.Entity) -> ecs.Transform {
	return ecs.get(&f.world, e, ecs.Transform)^
}

@(private = "file")
previous_of :: proc(f: ^Move_Fixture, e: ecs.Entity) -> ecs.Transform {
	return ecs.Transform(ecs.get(&f.world, e, ecs.Previous_Transform)^)
}

@(private = "file")
meters_of :: proc(f: ^Move_Fixture, e: ecs.Entity) -> [3]f64 {
	return ecs.position_to_meters(pose_of(f, e).position)
}

@(private = "file")
near :: proc(a, b: [3]f64, tolerance := 1e-5) -> bool {
	return(
		abs(a.x - b.x) <= tolerance &&
		abs(a.y - b.y) <= tolerance &&
		abs(a.z - b.z) <= tolerance \
	)
}

@(private = "file")
same_rotation :: proc(a, b: quaternion128) -> bool {
	return abs(linalg.dot(a, b)) > 1 - 1e-5
}

// Keys at 2^30 m from the world's origin: the track keys f32 offsets from its origin there, so each position is the
// origin plus the offset, rounded to a World_Position unit, and an axis that the track does not key keeps its own
// value to the unit.
@(test)
a_track_far_from_the_origin_loses_no_precision_beyond_its_offsets :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	e := thing(f, {FAR, 0, FAR})
	// The entity's z is 3 units past the origin's: an f32 of meters there could not hold it.
	ecs.get_write(&f.world, e, ecs.Transform).position.raw.z += 3
	origin := ecs.position_from_meters({FAR, 0, FAR})
	xs := []format.Cutscene_Key{key(0, 0), key(SECOND, 10.123456)}
	ys := []format.Cutscene_Key {
		key(0, 0.25, .Auto),
		key(SECOND / 2, 3.75, .Auto),
		key(SECOND, -1, .Auto),
	}
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Far",
			binding = 0,
			space = .Absolute,
			origin = origin.raw,
			sections = section(1, keyed("position_x", ..xs), keyed("position_y", ..ys)),
		},
	}
	scrub := scrub_of(t, f, move_blob(f, tracks))
	defer end_scrub(f, scrub)
	own_z := pose_of(f, e).position.raw.z
	for moment in ([]i32{0, 1, 7777, SECOND / 2, 41234, SECOND - 1, SECOND, 0}) {
		scrub_to(f, scrub, moment)
		raw := pose_of(f, e).position.raw
		want_x :=
			origin.raw.x +
			i64(math.round(curve_value(xs, moment, .Constant, .Constant) * f32(1 << 24)))
		want_y :=
			origin.raw.y +
			i64(math.round(curve_value(ys, moment, .Constant, .Constant) * f32(1 << 24)))
		testing.expectf(t, raw.x == want_x, "x at %d: %d, not %d", moment, raw.x, want_x)
		testing.expectf(t, raw.y == want_y, "y at %d: %d, not %d", moment, raw.y, want_y)
		testing.expectf(t, raw.z == own_z, "z, which no channel keys, at %d: %d", moment, raw.z)
	}
}

// The three spaces: from the track's origin, from the binding's own pose (its rotation turns the offsets), and from
// another binding's pose at each evaluation.
@(test)
each_space_places_the_keys_from_its_origin :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	turned := script.quaternion_euler({0, 90, 0})
	walker := thing(f, {FAR + 100, 0, 50}, turned)
	marker := thing(f, {0, 0, 0})
	ship := thing(f, {1000, 20, 0})
	// The rider starts on the ship, so the x and z that it does not key ride with the ship.
	rider := thing(f, {1000, 20, 0})
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Walks",
			binding = 0,
			sections = section(
				1,
				keyed("position_z", key(0, 0), key(SECOND, 2)),
				keyed("rotation_y", key(0, 0), key(SECOND, 90)),
			),
		},
		{
			id = 2,
			kind = .Transform,
			name = "Marks",
			binding = 1,
			space = .Absolute,
			origin = ecs.position_from_meters({5, 0, 0}).raw,
			sections = section(
				2,
				keyed("position_x", key(0, 1)),
				keyed("position_y", key(0, 2)),
				keyed("position_z", key(0, 3)),
				keyed("rotation_x", key(0, 30)),
			),
		},
		{
			id = 3,
			kind = .Transform,
			name = "Rides",
			binding = 3,
			space = .Relative_To,
			relative = 2,
			sections = section(3, keyed("position_y", key(0, 1.5))),
		},
	}
	h := play_blob(t, f, move_blob(f, tracks, 2 * SECOND))
	start := meters_of(f, walker)
	for i in 0 ..< 30 {
		tick(f)
		testing.expectf(
			t,
			near(meters_of(f, rider), meters_of(f, ship) + {0, 1.5, 0}),
			"tick %d: the rider is at %v, the ship at %v",
			i,
			meters_of(f, rider),
			meters_of(f, ship),
		)
		// The ship moves on its own, and the rider follows it in the next tick.
		ship_pose := ecs.get_write(&f.world, ship, ecs.Transform)
		ship_pose.position = ecs.position_offset(ship_pose.position, {1, 0, 0})
	}
	e, _ := player_evaluation(&f.cutscenes, h)
	progress := f32(e.time) / SECOND
	// The walker's z of 2 m turns with it, so it walks along x.
	forward := linalg.quaternion_mul_vector3(turned, [3]f32{0, 0, 2 * progress})
	want := start + {f64(forward.x), f64(forward.y), f64(forward.z)}
	testing.expectf(
		t,
		near(meters_of(f, walker), want, 1e-4),
		"the walker is at %v, not %v",
		meters_of(f, walker),
		want,
	)
	testing.expect(
		t,
		same_rotation(
			pose_of(f, walker).rotation,
			turned * script.quaternion_euler({0, 90 * progress, 0}),
		),
		"the walker turns from its own rotation",
	)
	testing.expect(
		t,
		near(meters_of(f, marker), {6, 2, 3}),
		"the marker is at the origin plus its keys",
	)
	testing.expect(
		t,
		same_rotation(pose_of(f, marker).rotation, script.quaternion_euler({30, 0, 0})),
	)
}

// A track relative to a binding whose own track comes later in the cutscene sees that binding's pose at this time,
// not the last tick's.
@(test)
a_track_relative_to_a_moving_binding_follows_it_whatever_the_order :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	ship := thing(f, {0, 0, 0})
	rider := thing(f, {0, 0, 0})
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Rides",
			binding = 1,
			space = .Relative_To,
			relative = 0,
			sections = section(1, keyed("position_y", key(0, 1)), keyed("rotation_y", key(0, 0))),
		},
		{
			id = 2,
			kind = .Transform,
			name = "Flies",
			binding = 0,
			space = .Absolute,
			sections = section(
				2,
				keyed("position_x", key(0, 0), key(SECOND, 6)),
				keyed("rotation_y", key(0, 0), key(SECOND, 90)),
			),
		},
	}
	scrub := scrub_of(t, f, move_blob(f, tracks))
	defer end_scrub(f, scrub)
	for moment in ([]i32{SECOND / 2, SECOND, 0}) {
		scrub_to(f, scrub, moment)
		ship_pose := pose_of(f, ship)
		up := linalg.quaternion_mul_vector3(ship_pose.rotation, [3]f32{0, 1, 0})
		testing.expectf(
			t,
			near(meters_of(f, rider), meters_of(f, ship) + {f64(up.x), f64(up.y), f64(up.z)}),
			"at %d the rider is at %v, the ship at %v",
			moment,
			meters_of(f, rider),
			meters_of(f, ship),
		)
		testing.expect(t, same_rotation(pose_of(f, rider).rotation, ship_pose.rotation))
	}
}

// Play crosses a key marked teleport: in that tick, Previous_Transform is the new pose, so presentation does not
// interpolate across the jump. The ticks before and after it interpolate.
@(test)
a_teleport_key_moves_the_entity_at_once :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	e := thing(f, {0, 0, 0})
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Jumps",
			binding = 0,
			space = .Absolute,
			sections = section(
				1,
				keyed(
					"position_x",
					key(0, 0),
					key(SECOND / 2, 1, .Constant),
					key(SECOND / 2 + 1, 100, .Linear, {.Teleport}),
					key(SECOND, 110),
				),
			),
		},
	}
	h := play_blob(t, f, move_blob(f, tracks))
	ev, _ := player_evaluation(&f.cutscenes, h)
	crossed := false
	for !crossed {
		before := ev.time
		tick(f)
		crossed = before <= SECOND / 2 && ev.time > SECOND / 2
		if !crossed && ev.time > 2000 && ev.time < SECOND / 2 {
			testing.expectf(
				t,
				previous_of(f, e) != pose_of(f, e),
				"a tick at %d that crosses no teleport key interpolates",
				ev.time,
			)
		}
	}
	testing.expectf(t, meters_of(f, e).x > 99, "the jump is done: %v", meters_of(f, e))
	testing.expect_value(t, previous_of(f, e), pose_of(f, e))
	tick(f)
	testing.expect(t, previous_of(f, e) != pose_of(f, e), "the next tick interpolates")
}

// A child binding: the track writes its Local_Transform, and its Transform follows from its parent's. Relative to the
// child, the keys are in its parent's space; in an absolute space, the track turns the pose in the world into the
// parent's space.
@(test)
a_track_on_a_child_writes_its_local_transform :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	parent := thing(f, {10, 0, 0}, script.quaternion_euler({0, 90, 0}), {2, 2, 2})
	near_one := child(f, parent, {0, 0, 1})
	far_one := child(f, parent, {0, 0, -1})
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Near",
			binding = 1,
			sections = section(1, keyed("position_x", key(0, 3))),
		},
		{
			id = 2,
			kind = .Transform,
			name = "Far",
			binding = 2,
			space = .Absolute,
			origin = ecs.position_from_meters({20, 0, 0}).raw,
			sections = section(2, keyed("position_y", key(0, 4)), keyed("rotation_y", key(0, 0))),
		},
	}
	far_before := meters_of(f, far_one)
	play_blob(t, f, move_blob(f, tracks))
	parent_before := pose_of(f, parent)
	tick(f)
	local := ecs.get(&f.world, near_one, ecs.Local_Transform)^
	testing.expectf(t, local.offset == {3, 0, 1}, "the near child's offset is %v", local.offset)
	for c in ([]ecs.Entity{near_one, far_one}) {
		want := ecs.compose(pose_of(f, parent), ecs.get(&f.world, c, ecs.Local_Transform)^)
		testing.expect(
			t,
			near(meters_of(f, c), ecs.position_to_meters(want.position)),
			"propagation composes the child's Transform from its Local_Transform",
		)
	}
	// Only y is keyed: x and z keep the far child's own values.
	want_far := [3]f64{far_before.x, 4, far_before.z}
	testing.expectf(
		t,
		near(meters_of(f, far_one), want_far, 1e-4),
		"the far child is at %v",
		meters_of(f, far_one),
	)
	testing.expect(
		t,
		same_rotation(pose_of(f, far_one).rotation, 1),
		"the far child's rotation is the world's",
	)
	testing.expect_value(t, pose_of(f, parent), parent_before)
}

// When the cutscene finishes, a restore track teleports its binding back to its pose before the cutscene, and a keep
// track leaves it at its last pose. A skip lands on the last pose.
@(test)
a_transform_track_restores_or_keeps_its_pose_and_a_skip_lands_on_the_last :: proc(t: ^testing.T) {
	for finish in format.Cutscene_Finish {
		for skips in ([]bool{false, true}) {
			f := move_setup(t)
			e := thing(f, {1, 2, 3}, script.quaternion_euler({0, 45, 0}))
			before := pose_of(f, e)
			tracks := []format.Cutscene_Track_Contents {
				{
					id = 1,
					kind = .Transform,
					name = "Walks",
					binding = 0,
					finish = finish,
					space = .Absolute,
					sections = section(
						1,
						keyed("position_x", key(0, 0), key(SECOND, 4)),
						keyed("rotation_y", key(0, 0), key(SECOND, 180)),
						keyed("scale_y", key(0, 1), key(SECOND, 3)),
					),
				},
			}
			h := play_blob(t, f, move_blob(f, tracks))
			for _ in 0 ..< 10 {
				tick(f)
			}
			if skips {
				testing.expect_value(t, skip(&f.cutscenes, &f.world, h), Command_Result.Done)
				update(&f.cutscenes, {world = &f.world, dt = time.Second / 60})
			} else {
				for status(&f.cutscenes, h) != .Restored {
					tick(f)
				}
			}
			testing.expect_value(t, status(&f.cutscenes, h), Player_Status.Restored)
			after := pose_of(f, e)
			switch finish {
			case .Restore:
				testing.expectf(
					t,
					after == before,
					"skips %v: restored to %v, not %v",
					skips,
					after,
					before,
				)
			case .Keep:
				testing.expectf(
					t,
					near(meters_of(f, e), {4, 2, 3}),
					"skips %v: kept at %v",
					skips,
					meters_of(f, e),
				)
				testing.expect(
					t,
					same_rotation(after.rotation, script.quaternion_euler({0, 180, 0})),
				)
				testing.expect(t, abs(after.scale.y - 3) < 1e-6)
				testing.expect_value(t, after.scale.x, 1)
			}
			testing.expect_value(t, previous_of(f, e), after)
			move_teardown(f)
		}
	}
}

@(private = "file")
Error_Count :: struct {
	errors: int,
}

// Two bindings of one entity: a track of the first relative to the second is relative to itself, which the cooker
// cannot see. The track does nothing, and says so once.
@(test)
a_track_relative_to_itself_through_its_bindings_does_nothing :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	e := thing(f, {7, 0, 0})
	append(&f.entities, e)
	tracks := []format.Cutscene_Track_Contents {
		{
			id = 1,
			kind = .Transform,
			name = "Loops",
			binding = 0,
			space = .Relative_To,
			relative = 1,
			sections = section(1, keyed("position_x", key(0, 1))),
		},
	}
	heard: Error_Count
	logger := context.logger
	context.logger = {
		procedure = proc(
			data: rawptr,
			level: runtime.Logger_Level,
			text: string,
			options: runtime.Logger_Options,
			location := #caller_location,
		) {
			if level >= .Error {
				(^Error_Count)(data).errors += 1
			}
		},
		data = &heard,
		lowest_level = .Debug,
	}
	scrub := scrub_of(t, f, move_blob(f, tracks))
	for moment in ([]i32{0, SECOND / 2, SECOND}) {
		scrub_to(f, scrub, moment)
	}
	end_scrub(f, scrub)
	context.logger = logger
	testing.expect_value(t, heard.errors, 1)
	testing.expect(t, near(meters_of(f, e), {7, 0, 0}), "the entity stays")
}

// A hot reload while a rider rides a ship that the game moves keeps the rider where it stood on the ship: the start
// in the ship's space stays, because the snapshot still holds the rider's own pose that it came from.
@(test)
a_reload_keeps_where_a_rider_stands_on_a_moving_binding :: proc(t: ^testing.T) {
	f := move_setup(t)
	defer move_teardown(f)
	ship := thing(f, {0, 0, 0})
	rider := thing(f, {2, 0, 0})
	tracks_of :: proc(height: f32) -> []format.Cutscene_Track_Contents {
		tracks := make([]format.Cutscene_Track_Contents, 1, context.temp_allocator)
		tracks[0] = {
			id       = 1,
			kind     = .Transform,
			name     = "Rides",
			binding  = 1,
			space    = .Relative_To,
			relative = 0,
			sections = section(1, keyed("position_y", key(0, height))),
		}
		return tracks
	}
	play_blob(t, f, move_blob(f, tracks_of(1), 4 * SECOND))
	move_ship :: proc(f: ^Move_Fixture, ship: ecs.Entity) {
		pose := ecs.get_write(&f.world, ship, ecs.Transform)
		pose.position = ecs.position_offset(pose.position, {1, 0, 0})
	}
	for _ in 0 ..< 5 {
		tick(f)
		move_ship(f, ship)
	}
	testing.expect(
		t,
		asset.set_live(&f.assets, MOVE_GUID, move_blob(f, tracks_of(3), 4 * SECOND, key = 2)),
	)
	for _ in 0 ..< 3 {
		tick(f)
		testing.expectf(
			t,
			near(meters_of(f, rider), meters_of(f, ship) + {2, 3, 0}),
			"the rider is at %v, the ship at %v",
			meters_of(f, rider),
			meters_of(f, ship),
		)
		move_ship(f, ship)
	}
}
