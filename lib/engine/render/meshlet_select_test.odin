package render

import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"

@(test)
only_hierarchy_items_walk_and_only_while_the_walk_can_run :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := core.Platform_API {
		gpu_create_buffer  = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
			// The handle keeps the size, which the test reads back.
			return gpu.Buffer{index = desc.size, generation = 1}
		},
		gpu_destroy_buffer = proc(buffer: gpu.Buffer) {},
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	allocator := virtual.arena_allocator(&arena)
	items :: proc(allocator := context.allocator) -> []Cull_Item {
		list := make([]Cull_Item, 3, allocator)
		list[0].flags = ITEM_MESH_PATH | ITEM_HIERARCHY
		list[1].flags = ITEM_MESH_PATH
		list[2].flags = ITEM_MESH_PATH | ITEM_HIERARCHY
		return list
	}

	// Before the walk's pipeline is ready, every item tests all of its meshlets.
	before := items(allocator)
	testing.expect_value(t, len(meshlet_select_items(r, before, false, allocator)), 0)
	for item in before {
		testing.expect(t, item.flags & ITEM_HIERARCHY == 0)
	}

	// Once it is, the items with a hierarchy walk, by their index, and the selections hold every item's range after
	// the list's counter.
	m := &r.scene.meshlet_select
	m.pipeline.pipeline, m.selected = gpu.Pipeline{1, 1}, gpu.Buffer{1, 1}
	ready := items(allocator)
	walks := meshlet_select_items(r, ready, false, allocator)
	testing.expect_value(t, len(walks), 2)
	testing.expect(t, len(walks) == 2 && walks[0] == 0 && walks[1] == 2)
	testing.expect(t, ready[0].flags & ITEM_HIERARCHY != 0 && ready[2].flags & ITEM_HIERARCHY != 0)
	testing.expect(t, m.capacity >= 3)
	testing.expect_value(t, m.selections.index, u32(8 + m.capacity * 8))

	// Without the hierarchy, nothing walks.
	disabled := items(allocator)
	testing.expect_value(t, len(meshlet_select_items(r, disabled, true, allocator)), 0)
	for item in disabled {
		testing.expect(t, item.flags & ITEM_HIERARCHY == 0)
	}
}
