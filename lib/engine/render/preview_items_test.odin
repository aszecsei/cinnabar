package render

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu/null"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(private = "file")
Scene_Text := `scene 2

entity 0000000000000001
name = "Root"
component 1 Transform
	position = [167772160, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $11111111111111111111111111111111

entity 0000000000000002
name = "Floor"
parent = @0000000000000001
component 2 Local_Transform
	offset = [0, 2, 0]
	rotation = [-0.7071068, 0, 0, 0.7071068]
	scale = [2, 2, 2]

entity 0000000000000003
name = "Column"
parent = @0000000000000002
component 2 Local_Transform
	offset = [1, 1, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $22222222222222222222222222222222
	materials.0 = $aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	materials.3 = $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

entity 0000000000000004
name = "Hidden"
parent = @0000000000000001
active = false
component 2 Local_Transform
	offset = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $33333333333333333333333333333333

entity 0000000000000005
name = "Under Hidden"
parent = @0000000000000004
component 2 Local_Transform
	offset = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $44444444444444444444444444444444
`

@(private = "file")
guid :: proc(text: string) -> format.Guid {
	g, _ := format.guid_parse(text)
	return g
}

@(test)
prefab_items_compose_parents_and_skip_inactive :: proc(t: ^testing.T) {
	scene, problems, ok := format.scene_parse(Scene_Text, context.temp_allocator)
	testing.expectf(t, ok, "%v", problems)

	items := prefab_preview_items(scene, 0, context.temp_allocator)

	testing.expect_value(t, len(items), 2)
	// The root stands at the origin, whatever its Transform says, as an instance replaces it.
	testing.expect(t, items[0].mesh == guid("11111111111111111111111111111111"))
	root := ecs.position_to_meters(items[0].pose.position)
	testing.expect_value(t, root, [3]f64{0, 0, 0})
	column := items[1]
	testing.expect(t, column.mesh == guid("22222222222222222222222222222222"))
	testing.expect(t, column.materials[0] == guid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
	testing.expect(t, column.materials[3] == guid("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
	testing.expect(t, column.materials[1] == {})
	// The floor is 2 m up, turned -90 degrees about X and twice the size, so the column's (1, 1, 0) goes to (2, 2, -2).
	at := ecs.position_to_meters(column.pose.position)
	testing.expectf(t, abs(at.x - 2) < 0.01 && abs(at.y - 2) < 0.01 && abs(at.z + 2) < 0.01, "the column is at %v", at)
	testing.expectf(t, abs(column.pose.scale.x - 2) < 0.001, "its scale is %v", column.pose.scale)

	// Only a node and what is under it.
	part := prefab_preview_items(scene, 2, context.temp_allocator)
	testing.expect_value(t, len(part), 1)
	testing.expect(t, part[0].mesh == guid("22222222222222222222222222222222"))
	testing.expect_value(t, len(prefab_preview_items(scene, 3, context.temp_allocator)), 1)
	testing.expect_value(t, len(prefab_preview_items(scene, 99, context.temp_allocator)), 0)
}

@(test)
fit_holds_every_item :: proc(t: ^testing.T) {
	centers := [][3]f32{{-10, 0, 0}, {10, 0, 0}, {0, 4, 3}}
	radii := []f32{1, 2, 0.5}
	center, radius := preview_fit(centers, radii)
	for c, i in centers {
		testing.expectf(t, linalg.length(c - center) + radii[i] <= radius + 0.001, "item %d is outside: %v %f", i, center, radius)
	}
	// From that far, the whole sphere is in the view.
	distance := preview_distance(radius)
	testing.expect(t, radius / distance <= math.sin(f32(PREVIEW_FOV) / 2))

	// With nothing to show, the view is still a view.
	_, empty := preview_fit(nil, nil)
	testing.expect(t, empty > 0)
	_, point := preview_fit({{1, 1, 1}}, {0})
	testing.expect(t, point > 0)
}

@(test)
draws_group_into_bins_opaque_first :: proc(t: ^testing.T) {
	draws := []Preview_Draw {
		{record = {instance = 0}, pipeline = 5, transparent = false},
		{record = {instance = 1}, pipeline = 2, transparent = true},
		{record = {instance = 2}, pipeline = 5, transparent = false},
		{record = {instance = 3}, pipeline = 1, transparent = false},
		{record = {instance = 4}, pipeline = 2, transparent = true},
	}
	bins := preview_group(draws, context.temp_allocator)

	testing.expect_value(t, len(bins), 3)
	testing.expect_value(t, bins[0].index, 1)
	testing.expect_value(t, bins[0].count, 1)
	testing.expect_value(t, bins[1].index, 5)
	testing.expect_value(t, bins[1].first, 1)
	testing.expect_value(t, bins[1].count, 2)
	testing.expect_value(t, bins[2].index, 2)
	testing.expect(t, bins[2].transparent)
	testing.expect_value(t, bins[2].first, 3)
	// A run keeps the order of its draws.
	testing.expect_value(t, draws[1].record.instance, 0)
	testing.expect_value(t, draws[2].record.instance, 2)
}

@(test)
over_budget_keeps_the_largest :: proc(t: ^testing.T) {
	radii := []f32{1, 9, 3, 7, 5}
	kept := preview_largest(radii, 3, context.temp_allocator)
	// In their order, so a preview's draws do not change order from frame to frame.
	testing.expect_value(t, len(kept), 3)
	testing.expect_value(t, kept[0], 1)
	testing.expect_value(t, kept[1], 3)
	testing.expect_value(t, kept[2], 4)
	testing.expect_value(t, len(preview_largest(radii, 99, context.temp_allocator)), 5)
}

@(test)
released_entries_leave_what_the_world_uses :: proc(t: ^testing.T) {
	// What is not in the cache fails, which residency logs.
	context.logger = log.nil_logger()
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := core.Platform_API {
		frame_allocator     = virtual.arena_allocator(&arena),
		heap_allocator      = runtime.heap_allocator(),
		asset_allocator     = runtime.heap_allocator(),
		file_read           = core.file_read,
		file_modified       = core.file_modified,
		gpu_destroy_buffer  = null.destroy_buffer,
		gpu_destroy_texture = null.destroy_texture,
	}
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)
	shared, only_baked, only_world := guid("11111111111111111111111111111111"), guid("22222222222222222222222222222222"), guid("33333333333333333333333333333333")

	r.baking = true
	resident_mesh(r, shared)
	resident_mesh(r, only_baked)
	r.baking = false
	resident_mesh(r, shared)
	resident_mesh(r, only_world)
	testing.expect_value(t, r.count, 3)

	testing.expect_value(t, residency_release_baked(r), 1)

	testing.expect_value(t, r.count, 2)
	_, gone := r.index[{only_baked, .Mesh}]
	testing.expect(t, !gone)
	// What stays is still found, after the table moved it.
	for g in ([]format.Guid{shared, only_world}) {
		i, found := r.index[{g, .Mesh}]
		testing.expect(t, found && r.entries[i].guid == g)
	}
	testing.expect_value(t, residency_release_baked(r), 0)

	// A mesh that failed is settled, and one that nothing asked for is too.
	testing.expect(t, resident_failed(r, shared))
	testing.expect(t, resident_failed(r, only_baked))
}
