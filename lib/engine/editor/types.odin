package editor

import "base:runtime"

import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"
import "cinnabar:engine/scene"

// component_types describes every registered component, with the fields that scenes can set. Strings and slices are
// in allocator.
@(private)
component_types :: proc(w: ^ecs.World, allocator: runtime.Allocator) -> link.Component_Types {
	types := make([]link.Component_Type, w.registry.count, allocator)
	for info, i in w.registry.infos[:w.registry.count] {
		fields := scene.component_fields(info.type, allocator)
		infos := make([]link.Field_Info, len(fields), allocator)
		for f, j in fields {
			values := make([]link.Enum_Value, len(f.enum_values), allocator)
			for v, k in f.enum_values {
				values[k] = {name = v.name, value = v.value}
			}
			infos[j] = {
				name            = f.name,
				offset          = f.offset,
				kind            = link.Field_Kind(f.kind),
				enum_base       = link.Field_Kind(f.enum_base),
				enum_values     = values,
				read_only       = f.read_only,
				has_range       = f.has_range,
				range_min       = f.range_min,
				range_max       = f.range_max,
				color           = f.color,
				has_override    = f.has_override,
				override_offset = f.override_offset,
				asset_kind      = f.asset_kind,
			}
		}
		types[i] = {id = u64(info.id), name = info.name, size = u32(info.size), fields = infos}
	}
	return {types = types}
}

#assert(len(scene.Field_Kind) == len(link.Field_Kind))
#assert(int(scene.Field_Kind.Entity) == int(link.Field_Kind.Entity))
#assert(int(scene.Field_Kind.Enum) == int(link.Field_Kind.Enum))
#assert(int(scene.Field_Kind.Asset) == int(link.Field_Kind.Asset))
#assert(int(scene.Field_Kind.Vector2) == int(link.Field_Kind.Vector2))
#assert(len(render.Debug_View) == len(link.Debug_View))
#assert(int(render.Debug_View.Shadow_Cascades) == int(link.Debug_View.Shadow_Cascades))
#assert(int(render.Debug_View.Luminance) == int(link.Debug_View.Luminance))
