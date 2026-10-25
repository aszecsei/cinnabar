package scene

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

Mode :: enum u8 {
	Idle,
	Busy = 5,
}

PROBE_ID :: ecs.Component_Id(100)

Probe :: struct {
	flag:   bool,
	small:  i8,
	big:    u64,
	ratio:  f32,
	mode:   Mode,
	dir:    [3]f32,
	turn:   quaternion128,
	at:     ecs.World_Position,
	target: ecs.Entity,
	model:  format.Guid `asset:"mesh"`,
	skins:  [2]format.Guid `asset:"material"`,
	inner:  struct {
		amount: f64,
	},
	hidden: i32 `editor:"-"`,
}

@(private = "file")
Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
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
	ecs.register_component(&f.world.registry, Probe, PROBE_ID)
	return f
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
parse :: proc(t: ^testing.T, text: string) -> format.Scene {
	s, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	return s
}

// find is the entity that a scene ID became.
@(private = "file")
find :: proc(f: ^Fixture, id: u64) -> ecs.Entity {
	it := ecs.world_iter(&f.world)
	for e in ecs.world_next(&it) {
		if s := ecs.get(&f.world, e, Scene_Entity); s != nil && s.id == id {
			return e
		}
	}
	return 0
}

@(private = "file")
count :: proc(f: ^Fixture) -> int {
	n := 0
	it := ecs.world_iter(&f.world)
	for _ in ecs.world_next(&it) {
		n += 1
	}
	return n
}

@(test)
a_scene_replaces_the_world :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	old := ecs.spawn(&f.world)

	text := `scene 1
entity 00000000000000a1
name = "Root"
component 1 Transform
	position = [2516582400000000000, 0, -16777216]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 4 Previous_Transform
entity 00000000000000b2
name = "Child"
parent = @00000000000000a1
active = false
component 100 Probe
	flag = true
	small = -5
	big = 18446744073709551615
	ratio = 0.25
	mode = Busy
	dir = [1, 2.5, 3]
	turn = [0, 0.7071068, 0, 0.7071068]
	at = [1, -2, 3]
	target = @00000000000000a1
	model = $9db8150cc7215ffc2708d20d77cf60bf
	skins.1 = $ffeeddccbbaa99887766554433221100
	inner.amount = 7
`
	load(&f.world, nil, parse(t, text))

	testing.expect(t, !ecs.is_alive(&f.world, old))
	testing.expect_value(t, count(f), 2)
	root, child := find(f, 0xa1), find(f, 0xb2)
	testing.expect(t, root != 0 && child != 0)
	testing.expect_value(t, ecs.name_of(&f.world, root), "Root")
	testing.expect_value(t, ecs.name_of(&f.world, child), "Child")
	// The world takes the slots from the lowest up, so the handles follow the scene's order.
	testing.expect(t, ecs.entity_index(root) < ecs.entity_index(child))
	testing.expect_value(t, ecs.get(&f.world, child, ecs.Parent).entity, root)
	testing.expect(t, ecs.has(&f.world, child, ecs.Disabled) && ecs.has(&f.world, child, ecs.Inactive))
	testing.expect(t, !ecs.has(&f.world, root, ecs.Inactive))

	pose := ecs.get(&f.world, root, ecs.Transform)
	testing.expect_value(t, pose.position.raw, [3]i64{2516582400000000000, 0, -16777216})
	testing.expect_value(t, pose.rotation, quaternion128(1))
	testing.expect_value(t, pose.scale, [3]f32{1, 1, 1})
	// Nothing interpolates from where the old world was.
	testing.expect_value(t, ecs.get(&f.world, root, ecs.Previous_Transform)^, ecs.Previous_Transform(pose^))

	p := ecs.get(&f.world, child, Probe)
	testing.expect(t, p.flag)
	testing.expect_value(t, p.small, -5)
	testing.expect_value(t, p.big, max(u64))
	testing.expect_value(t, p.ratio, 0.25)
	testing.expect_value(t, p.mode, Mode.Busy)
	testing.expect_value(t, p.dir, [3]f32{1, 2.5, 3})
	testing.expect_value(t, imag(p.turn), 0)
	testing.expect_value(t, real(p.turn), 0.7071068)
	testing.expect_value(t, jmag(p.turn), 0.7071068)
	testing.expect_value(t, p.at.raw, [3]i64{1, -2, 3})
	testing.expect_value(t, p.target, root)
	testing.expect_value(t, p.model, format.guid_parse("9db8150cc7215ffc2708d20d77cf60bf") or_else {})
	testing.expect_value(t, p.skins, [2]format.Guid{{}, format.guid_parse("ffeeddccbbaa99887766554433221100") or_else {}})
	testing.expect_value(t, p.inner.amount, 7)
}

@(test)
what_the_game_cannot_use_is_skipped :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)

	text := `scene 1
entity 0000000000000001
component 999 Gone
	x = 1
component 100 Probe
	small = 300
	ratio = "fast"
	mode = Asleep
	at = [1.5, 0, 0]
	hidden = 4
	removed = 1
	target = @0000000000000077
	big = 9
`
	load(&f.world, nil, parse(t, text))

	e := find(f, 1)
	testing.expect(t, e != 0)
	// The component that the game knows is still added, with the values that fit.
	p := ecs.get(&f.world, e, Probe)
	testing.expect(t, p != nil)
	testing.expect_value(t, p^, Probe{big = 9})
	testing.expect_value(t, len(ecs.entity_components(&f.world, e)), 2)
}

@(test)
fields_flatten_and_hide :: proc(t: ^testing.T) {
	fields := component_fields(Probe, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for field in fields {
		append(&names, field.name)
	}
	testing.expect_value(t, len(fields), 13)
	testing.expect_value(t, fields[12].name, "inner.amount")
	testing.expect_value(t, fields[12].offset, u32(offset_of(Probe, inner)))
	// An array of asset references is a field for each element.
	testing.expect_value(t, fields[11].name, "skins.1")
	testing.expect_value(t, fields[11].offset, u32(offset_of(Probe, skins) + size_of(format.Guid)))
	testing.expect_value(t, fields[11].asset_kind, "material")
	testing.expect_value(t, fields[9].kind, Field_Kind.Asset)
	testing.expect_value(t, fields[9].asset_kind, "mesh")
	testing.expect_value(t, fields[4].kind, Field_Kind.Enum)
	testing.expect_value(t, fields[4].enum_values[1], Enum_Value{"Busy", 5})
	testing.expect_value(t, fields[7].kind, Field_Kind.Position)
}
