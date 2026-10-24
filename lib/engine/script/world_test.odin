package script

import "core:c"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"

@(private)
Mood :: enum u8 {
	Calm,
	Angry,
}

@(private)
Health :: struct {
	value:  i32,
	rate:   f32,
	limit:  f32 `script:"read"`,
	secret: u32 `script:"-"`,
	mood:   Mood,
	target: ecs.Entity,
	drift:  [3]f32,
}

@(private)
World_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	runtime:  Runtime,
	reports:  [dynamic]f64,
	errors:   [dynamic]string,
}

@(private)
register_world_test :: proc(r: ^Runtime) {
	expose(r, Health, Health{limit = 100})
	define(r, "Test.report", proc(L: ^luau.State) -> c.int {
		f := (^World_Fixture)(context.user_ptr)
		append(&f.reports, luau.L_checknumber(L, 1))
		return 0
	})
}

// The fixture is large, and the VM keeps a pointer into it, so it lives on the heap. Each test sets
// context.user_ptr to it.
@(private)
setup_world :: proc(t: ^testing.T) -> ^World_Fixture {
	f := new(World_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator     = virtual.arena_allocator(&f.frame),
		time_seconds        = proc() -> f64 {return 0},
		script_open         = script_host.open,
		script_close        = script_host.close,
		script_push_binding = script_host.push_binding,
		script_atom         = script_host.atom,
		memory_reserve      = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit       = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release      = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	f.reports = make([dynamic]f64)
	f.errors = make([dynamic]string)
	testing.expect(t, ecs.init(&f.world, &f.platform))
	ecs.register_engine_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Health)
	context.user_ptr = f
	testing.expect(t, init(&f.runtime, &f.platform, &f.world, nil, register_world_test))
	begin_phase(&f.runtime, 16 * time.Millisecond, {})
	return f
}

@(private)
teardown_world :: proc(f: ^World_Fixture) {
	destroy(&f.runtime)
	ecs.destroy(&f.world)
	delete(f.reports)
	for e in f.errors {
		delete(e)
	}
	delete(f.errors)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// run runs a script to its end or first yield, with the fixture's bindings.
@(private)
run :: proc(t: ^testing.T, f: ^World_Fixture, source: string, loc := #caller_location) -> bool {
	_, ok := spawn_source(&f.runtime, "=test", source)
	return ok
}

@(private)
expect_reports :: proc(t: ^testing.T, f: ^World_Fixture, expected: []f64, loc := #caller_location) {
	testing.expectf(t, len(f.reports) == len(expected), "reports %v, want %v", f.reports[:], expected, loc = loc)
	if len(f.reports) != len(expected) {
		return
	}
	for e, i in expected {
		testing.expectf(t, f.reports[i] == e, "report %d is %v, want %v", i, f.reports[i], e, loc = loc)
	}
	clear(&f.reports)
}

@(private)
capture_world_errors :: proc(f: ^World_Fixture) -> log.Logger {
	return {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			f := (^World_Fixture)(data)
			append(&f.errors, strings.clone(text))
		},
		data = f,
		lowest_level = .Error,
	}
}

@(private)
expect_world_error :: proc(t: ^testing.T, f: ^World_Fixture, fragment: string, loc := #caller_location) {
	for e in f.errors {
		if strings.contains(e, fragment) {
			return
		}
	}
	testing.expectf(t, false, "no error contains %q: %v", fragment, f.errors[:], loc = loc)
}

@(test)
entities_are_values :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
local a, b = World.spawn(), World.spawn()
local set = {[a] = 7}
Test.report(set[a])
Test.report(a == a and 1 or 0)
Test.report(a ~= b and 1 or 0)
Test.report(typeof(a) == "Entity" and 1 or 0)
Test.report(typeof(Health) == "ComponentType" and 1 or 0)
Test.report(tostring(Health) == "ComponentType(Health)" and 1 or 0)
Test.report(Health.name == "Health" and 1 or 0)
`))
	expect_reports(t, f, {7, 1, 1, 1, 1, 1, 1})
}

@(test)
component_fields_read_and_write_storage :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
local e = World.spawn()
Test.report(e:get(Health) == nil and 1 or 0)
local h = e:add(Health, {value = 5, mood = "Angry"})
h.value += 1
h.drift = vector.create(1, 2, 3)
Test.report(e:get(Health).value)
Test.report(h.limit)
Test.report(h.mood == "Angry" and 1 or 0)
Test.report(e:has(Health) and 1 or 0)
Test.report(h == e:get(Health) and 1 or 0)
Test.report(h.entity == e and 1 or 0)
target = e
`))
	expect_reports(t, f, {1, 6, 100, 1, 1, 1, 1})

	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {ecs.registry_find_type(&f.world.registry, Health).id}, &found)
	testing.expect_value(t, len(found), 1)
	if len(found) == 1 {
		h := ecs.get(&f.world, found[0], Health)
		testing.expect_value(t, h.value, 6)
		testing.expect_value(t, h.mood, Mood.Angry)
		testing.expect_value(t, h.drift, [3]f32{1, 2, 3})
	}
}

@(test)
fields_are_checked :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = capture_world_errors(f)
	testing.expect(t, !run(t, f, "World.spawn():add(Health).limit = 1"))
	expect_world_error(t, f, "limit is read-only")
	testing.expect(t, !run(t, f, "local _ = World.spawn():add(Health).secret"))
	expect_world_error(t, f, "Health has no field secret")
	testing.expect(t, !run(t, f, "World.spawn():add(Health).mood = 'Sleepy'"))
	expect_world_error(t, f, `"Sleepy" is not a value of mood`)
	testing.expect(t, !run(t, f, "World.spawn():add(Health).value = 'many'"))
	expect_world_error(t, f, "number expected")
}

@(test)
destroy_waits_for_the_end_of_the_phase :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = capture_world_errors(f)
	testing.expect(t, run(t, f, `
local e = World.spawn()
e:add(Health)
e:destroy()
Test.report(e:is_alive() and 1 or 0)
`))
	expect_reports(t, f, {1})
	ecs.apply(&f.world, end_phase(&f.runtime))
	begin_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect(t, run(t, f, "Test.report(#World.query(Health))"))
	expect_reports(t, f, {0})
}

@(test)
a_destroyed_entity_raises_an_error :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	context.logger = capture_world_errors(f)
	thread, ok := spawn_source(&f.runtime, "=stale", `
local e = World.spawn()
local h = e:add(Health)
e:destroy()
coroutine.yield()
local _ = h.value
`)
	testing.expect(t, ok)
	ecs.apply(&f.world, end_phase(&f.runtime))
	begin_phase(&f.runtime, 16 * time.Millisecond, {})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Failed)
	expect_world_error(t, f, "stale:6: the entity is destroyed")
	release(&f.runtime, thread)
}

@(test)
queries_collect_before_the_loop :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
for i = 1, 3 do World.spawn():add(Health, {value = i}) end
World.spawn()
local total = 0
for _, e in World.query(Health) do
	total += e:get(Health).value
	e:remove(Health)
	World.spawn():add(Health)
end
Test.report(total)
Test.report(#World.query(Health))
Test.report(#World.query(Transform))
`))
	expect_reports(t, f, {6, 3, 7})
}

@(test)
positions_stay_exact_far_from_the_origin :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
local e = World.spawn(WorldPosition.from_meters(1e9, 0, 0))
local start = e.transform.position
e.transform.position = start + vector.create(0.5, 0, 0)
e:move(vector.create(0, 0.25, 0))
local d = e.transform.position - start
Test.report(d.x)
Test.report(d.y)
Test.report(typeof(start) == "WorldPosition" and 1 or 0)
Test.report(tostring(start) == "WorldPosition(1000000000.000, 0.000, 0.000)" and 1 or 0)
Test.report(start == WorldPosition.from_meters(1e9, 0, 0) and 1 or 0)
local other = World.spawn(start + vector.create(0, 0, 3))
Test.report(e:offset_to(other).z)
`))
	expect_reports(t, f, {0.5, 0.25, 1, 1, 1, 3})
}

@(test)
a_child_keeps_the_world_pose_that_a_script_sets :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
local parent = World.spawn(WorldPosition.from_meters(10, 0, 0), Quaternion.angle_axis(90, vector.create(0, 1, 0)))
parent.transform.scale = vector.create(2, 2, 2)
local child = World.spawn(WorldPosition.from_meters(10, 0, 4))
child:set_parent(parent)
Test.report(child.parent == parent and 1 or 0)
child.transform.position = WorldPosition.from_meters(12, 1, 0)
child.transform.rotation = Quaternion.angle_axis(45, vector.create(0, 1, 0))
the_child = child
`))
	expect_reports(t, f, {1})

	found := make([dynamic]ecs.Entity, context.temp_allocator)
	ecs.collect(&f.world, {ecs.PARENT_ID}, &found)
	testing.expect_value(t, len(found), 1)
	if len(found) != 1 {
		return
	}
	child := found[0]
	parent := ecs.get(&f.world, child, ecs.Parent).entity
	composed := ecs.compose(ecs.get(&f.world, parent, ecs.Transform)^, ecs.get(&f.world, child, ecs.Local_Transform)^)
	pose := ecs.get(&f.world, child, ecs.Transform)^
	testing.expectf(t, linalg.length(ecs.position_sub(composed.position, pose.position)) < 1e-5, "composed %v, set %v", ecs.position_to_meters(composed.position), ecs.position_to_meters(pose.position))
	testing.expect(t, quaternion_equal(composed.rotation, pose.rotation))
	testing.expect(t, linalg.length(composed.scale - pose.scale) < 1e-6)
}

@(test)
quaternions_follow_unity :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	testing.expect(t, run(t, f, `
local function near(a, b) return math.abs(a - b) < 1e-4 and 1 or 0 end
local q = Quaternion.euler(vector.create(30, 45, 60))
local e = q:euler()
Test.report(near(e.x, 30)) Test.report(near(e.y, 45)) Test.report(near(e.z, 60))
local turned = Quaternion.angle_axis(90, vector.create(0, 1, 0)) * vector.create(0, 0, 1)
Test.report(near(turned.x, 1)) Test.report(near(turned.z, 0))
local look = Quaternion.look_rotation(vector.create(1, 0, 0)) * vector.create(0, 0, 1)
Test.report(near(look.x, 1))
Test.report(near(Quaternion.angle(Quaternion.identity, q:inverse() * q), 0))
Test.report(near(Quaternion.identity.w, 1))
Test.report(q == q:normalized() and 1 or 0)
local halfway = Quaternion.identity:rotate_towards(Quaternion.angle_axis(90, vector.create(1, 0, 0)), 30)
Test.report(near(Quaternion.angle(Quaternion.identity, halfway), 30))
`))
	expect_reports(t, f, {1, 1, 1, 1, 1, 1, 1, 1, 1, 1})
}

@(test)
euler_angles_round_trip :: proc(t: ^testing.T) {
	for angles in ([?][3]f32{{0, 0, 0}, {10, -20, 30}, {-80, 170, -120}, {45, 90, 0}}) {
		back := euler_of(quaternion_euler(angles))
		testing.expectf(t, quaternion_equal(quaternion_euler(back), quaternion_euler(angles)), "%v gave %v", angles, back)
	}
	// Unity's order: z, then x, then y. Rolling first leaves +Z on the yaw and pitch path.
	q := quaternion_euler({0, 90, 90})
	forward := linalg.quaternion_mul_vector3(q, FORWARD)
	testing.expect(t, linalg.length(forward - [3]f32{1, 0, 0}) < 1e-5)
	testing.expect(t, abs(quaternion_angle(1, linalg.quaternion_angle_axis_f32(math.PI / 2, UP)) - 90) < 1e-3)
}

@(test)
time_and_input_change_between_frames :: proc(t: ^testing.T) {
	f := setup_world(t)
	defer teardown_world(f)
	context.user_ptr = f
	begin_phase(&f.runtime, 16 * time.Millisecond, {down = {.Space}, mouse_position = {10, 20}})
	// The fields are read when the code runs, not when it loads (see format.script_mutable_globals).
	thread, ok := spawn_source(&f.runtime, "=frames", `
local function sample()
	Test.report(Time.delta)
	Test.report(Input.is_down(Key.Space) and 1 or 0)
	Test.report(Input.mouse_position.y)
	Test.report(Time.frame)
end
while true do
	sample()
	coroutine.yield()
end
`)
	testing.expect(t, ok)
	expect_reports(t, f, {0.016, 1, 20, 2})
	begin_phase(&f.runtime, 32 * time.Millisecond, {mouse_position = {10, 40}})
	testing.expect_value(t, resume(&f.runtime, thread), Resume_Result.Yielded)
	expect_reports(t, f, {0.032, 0, 40, 3})
	release(&f.runtime, thread)
}
