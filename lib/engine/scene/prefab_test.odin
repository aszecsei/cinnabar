package scene

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// A prefab of a root and a child that refers to it, with a field that names an entity outside the prefab.
@(private = "file")
TURRET :: `scene 2
entity 1000000000000001
name = "Turret"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]

entity 1000000000000002
name = "Barrel"
parent = @1000000000000001
component 2 Local_Transform
	offset = [0, 1, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 100 Probe
	target = @1000000000000001
`

@(private = "file")
Prefab_Fixture :: struct {
	platform: core.Platform_API,
	frame:    virtual.Arena,
	world:    ecs.World,
	assets:   asset.Assets,
	dir:      string,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Prefab_Fixture {
	f := new(Prefab_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.frame),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
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
	temp, err := os.make_directory_temp("", "prefab_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = temp
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	return f
}

@(private = "file")
teardown :: proc(f: ^Prefab_Fixture) {
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	ecs.destroy(&f.world)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// write_blob writes a scene as a blob of a kind, as the cooker would.
@(private = "file")
write_blob :: proc(t: ^testing.T, f: ^Prefab_Fixture, guid: format.Guid, text: string, kind: format.Asset_Kind) {
	s, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	blob := format.scene_write(s, guid, 1, kind, context.temp_allocator)
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer)), blob) == nil)
}

@(test)
a_prefab_spawns_as_new_entities_with_its_references_inside :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	guid := format.Guid{0 = 0x7e, 15 = 1}
	write_blob(t, f, guid, TURRET, .Prefab)
	pose := ecs.TRANSFORM_IDENTITY
	pose.position = {raw = {16777216, 0, 0}}

	first, ok := spawn_prefab(&f.world, nil, &f.assets, guid, pose)
	testing.expect(t, ok)
	second, again := spawn_prefab(&f.world, nil, &f.assets, guid, ecs.TRANSFORM_IDENTITY)
	testing.expect(t, again)
	testing.expect(t, first != second)

	// The root is at the pose, and has no scene ID, as a game's entities have none.
	testing.expect_value(t, ecs.get(&f.world, first, ecs.Transform).position, pose.position)
	testing.expect(t, !ecs.has(&f.world, first, Scene_Entity))
	children: [dynamic]ecs.Entity
	defer delete(children)
	ecs.collect(&f.world, {PROBE_ID}, &children)
	testing.expect_value(t, len(children), 2)
	for child in children {
		parent := ecs.get(&f.world, child, ecs.Parent).entity
		// Each barrel is its own turret's, and refers to it.
		testing.expect(t, parent == first || parent == second)
		testing.expect_value(t, ecs.get(&f.world, child, Probe).target, parent)
		testing.expect(t, !ecs.has(&f.world, child, Scene_Entity))
	}
}

@(test)
only_a_cooked_prefab_spawns :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	// A refused spawn logs an error, which a test would count as its failure.
	context.logger = log.nil_logger()
	scene_guid := format.Guid{0 = 0x7e, 15 = 2}
	write_blob(t, f, scene_guid, TURRET, .Scene)

	_, ok := spawn_prefab(&f.world, nil, &f.assets, scene_guid, ecs.TRANSFORM_IDENTITY)
	testing.expect(t, !ok)
	_, ok = spawn_prefab(&f.world, nil, &f.assets, format.Guid{0 = 0x7e, 15 = 3}, ecs.TRANSFORM_IDENTITY)
	testing.expect(t, !ok)
	testing.expect_value(t, ecs.entity_count(&f.world), 0)
}
