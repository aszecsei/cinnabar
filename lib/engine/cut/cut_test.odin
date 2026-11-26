package cut

import "core:testing"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(test)
cutters_register_with_formats_defaults :: proc(t: ^testing.T) {
	r := new(ecs.Registry, context.temp_allocator)
	register_components(r)
	info := ecs.registry_find(r, MESH_CUTTER_ID)
	testing.expect(t, info != nil)
	testing.expect(t, ecs.registry_find(r, CUT_TARGET_ID) != nil)
	if info == nil {
		return
	}
	testing.expect_value(t, info.category, "Level Design")
	defaults := (^Mesh_Cutter)(ecs.registry_defaults(r, info))
	testing.expect(t, defaults != nil)
	if defaults != nil {
		testing.expect_value(t, defaults^, format.DEFAULT_MESH_CUTTER)
	}
}
