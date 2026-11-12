package nav

import "core:testing"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

@(test)
nav_mesh_volumes_register_with_formats_defaults :: proc(t: ^testing.T) {
	r := new(ecs.Registry, context.temp_allocator)
	register_components(r)
	info := ecs.registry_find(r, NAV_MESH_VOLUME_ID)
	testing.expect(t, info != nil)
	if info == nil {
		return
	}
	defaults := (^Nav_Mesh_Volume)(ecs.registry_defaults(r, info))
	testing.expect(t, defaults != nil)
	if defaults != nil {
		testing.expect_value(t, defaults^, format.DEFAULT_NAV_MESH_VOLUME)
	}
}
