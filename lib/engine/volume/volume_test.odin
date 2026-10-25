package volume

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"

@(private = "file")
Mode :: enum u8 {
	Soft,
	Hard,
}

@(private = "file")
Tone :: struct {
	gain:  Value(f32),
	tint:  Value([3]f32),
	mode:  Value(Mode),
	inner: struct {
		depth: Value(f32),
	},
}

@(private = "file")
TONE_DEFAULTS :: Tone {
	gain = {value = 1},
	tint = {value = {1, 1, 1}},
	mode = {value = .Soft},
	inner = {depth = {value = 2}},
}

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	volumes:  Volumes,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
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
	register_components(&f.world.registry)
	ecs.register_component(&f.world.registry, Tone, ecs.Component_Id(500), TONE_DEFAULTS)
	register(&f.volumes, &f.world)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
at :: proc(x, y, z: f64) -> ecs.World_Position {
	return ecs.position_from_meters({x, y, z})
}

@(private = "file")
spawn :: proc(f: ^Fixture, v: Volume, position := [3]f64{}, rotation := quaternion128(1), scale := [3]f32{1, 1, 1}) -> ecs.Entity {
	e := ecs.spawn(&f.world)
	ecs.add(&f.world, e, ecs.Transform{position = at(position.x, position.y, position.z), rotation = rotation, scale = scale})
	ecs.add(&f.world, e, v)
	return e
}

@(private = "file")
weight_at :: proc(f: ^Fixture, point: ecs.World_Position) -> f32 {
	inf := gather(&f.volumes, &f.world, point)
	return inf.count == 0 ? 0 : inf.items[0].weight
}

@(test)
shapes_weigh_a_point :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	spawn(f, {shape = .Global, weight = 0.25})
	testing.expect_value(t, weight_at(f, at(1e9, 0, -3e9)), 0.25)
	ecs.despawn_all(&f.world)

	// A box 2 m across x, the default 5 m in y and z, with a blend of 2 m.
	spawn(f, {shape = .Box, extents = {1, 0, 0}, blend_distance = 2}, {10, 0, 0})
	testing.expect_value(t, weight_at(f, at(10.9, 4.9, 0)), 1)
	testing.expect(t, math.abs(weight_at(f, at(12, 0, 0)) - 0.5) < 1e-4)
	testing.expect_value(t, weight_at(f, at(13.5, 0, 0)), 0)
	ecs.despawn_all(&f.world)

	// Turned a quarter about y and scaled, its x extent lies along the world's -z, twice as long.
	spawn(f, {shape = .Box, extents = {1, 1, 1}}, rotation = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0}), scale = {2, 1, 1})
	testing.expect_value(t, weight_at(f, at(0, 0, 1.9)), 1)
	testing.expect_value(t, weight_at(f, at(1.9, 0, 0)), 0)
	ecs.despawn_all(&f.world)

	spawn(f, {shape = .Sphere, extents = {2, 0, 0}, blend_distance = 1}, scale = {1, 3, 1})
	testing.expect_value(t, weight_at(f, at(0, 5.9, 0)), 1)
	testing.expect(t, math.abs(weight_at(f, at(0, 6.5, 0)) - 0.5) < 1e-4)
}

@(test)
far_from_the_origin_volumes_stay_exact :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	far := f64(ecs.POSITION_LIMIT) / f64(1 << 24) - 100
	spawn(f, {shape = .Box, extents = {1, 1, 1}}, {far, 0, 0})
	testing.expect_value(t, weight_at(f, at(far + 0.999, 0, 0)), 1)
	testing.expect_value(t, weight_at(f, at(far + 1.01, 0, 0)), 0)
}

@(test)
priority_then_size_order_the_volumes :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	high := spawn(f, {shape = .Sphere, extents = {1, 0, 0}, priority = 2})
	big := spawn(f, {shape = .Sphere, extents = {10, 0, 0}})
	global := spawn(f, {shape = .Global})
	small := spawn(f, {shape = .Sphere, extents = {1, 0, 0}})

	inf := gather(&f.volumes, &f.world, {})
	testing.expect_value(t, inf.count, 4)
	order := [4]ecs.Entity{global, big, small, high}
	for e, i in order {
		testing.expect_value(t, inf.items[i].entity, e)
	}

	// A hidden volume and an inactive one reach nothing.
	hidden := [1]u32{1 << ecs.entity_index(high)}
	ecs.set_active(&f.world, small, false)
	ecs.update_activity(&f.world)
	inf = gather(&f.volumes, &f.world, {}, hidden[:])
	testing.expect_value(t, inf.count, 2)
}

@(test)
settings_blend_by_weight :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	// Nothing reaches the point: the defaults, overriding nothing.
	inf := gather(&f.volumes, &f.world, {})
	result, touched := blend(&f.world, &inf, Tone)
	testing.expect(t, !touched)
	testing.expect_value(t, result, TONE_DEFAULTS)

	base := spawn(f, {shape = .Global})
	ecs.add(&f.world, base, Tone{gain = {true, 3}, mode = {true, .Hard}})
	local := spawn(f, {shape = .Global, priority = 1, weight = 0.25})
	// tint overrides with black, which is not its default; inner.depth keeps 9 but does not override it.
	ecs.add(&f.world, local, Tone{gain = {true, 7}, tint = {true, {}}, mode = {true, .Soft}, inner = {depth = {false, 9}}})

	inf = gather(&f.volumes, &f.world, {})
	result, touched = blend(&f.world, &inf, Tone)
	testing.expect(t, touched)
	// 3, then a quarter of the way to 7.
	testing.expect_value(t, result.gain, Value(f32){true, 4})
	testing.expect_value(t, result.tint, Value([3]f32){true, {0.75, 0.75, 0.75}})
	// Below a half, a choice keeps what is below it.
	testing.expect_value(t, result.mode, Value(Mode){true, .Hard})
	testing.expect_value(t, result.inner.depth, Value(f32){false, 2})

	ecs.get(&f.world, local, Volume).weight = 0.5
	inf = gather(&f.volumes, &f.world, {})
	result, _ = blend(&f.world, &inf, Tone)
	testing.expect_value(t, result.mode.value, Mode.Soft)
	testing.expect_value(t, sample(&f.volumes, &f.world, Tone, {}).gain.value, 5)
}

@(test)
an_override_of_zero_is_zero :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	e := spawn(f, {shape = .Global})
	ecs.add(&f.world, e, Tone{gain = {true, 0}, inner = {depth = {true, 0}}})
	inf := gather(&f.volumes, &f.world, {})
	result, _ := blend(&f.world, &inf, Tone)
	testing.expect_value(t, result.gain, Value(f32){true, 0})
	testing.expect_value(t, result.inner.depth, Value(f32){true, 0})
	testing.expect_value(t, result.tint, TONE_DEFAULTS.tint)
}
