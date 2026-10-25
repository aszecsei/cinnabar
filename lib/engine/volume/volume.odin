// Volumes give settings that change with where a point is (see docs/world.md#volumes): the post-processing and the
// fog at the camera, and later the wind at a tree. A Volume component gives its entity a shape, and the settings
// components on the same entity give the values. Each setting is a Value, which a volume overrides or leaves to the
// volumes below it, so a small volume can change one setting and keep the rest.
package volume

import "base:runtime"
import "core:math/linalg"
import "core:mem"
import "core:slice"

import "cinnabar:engine/ecs"

VOLUME_ID :: ecs.Component_Id(42)

// In meters, for an extent of 0, as a component added in the editor leaves it.
DEFAULT_EXTENT :: 5

// At most this many volumes reach a point. The rest are left out, from the last that the query finds.
MAX_INFLUENCES :: 64

Shape :: enum u8 {
	// Everywhere, as a base that local volumes go over.
	Global,
	// A box along the entity's axes, extents times its scale.
	Box,
	// A sphere, a radius of extents.x times the largest of its scale.
	Sphere,
}

// Volume gives its entity's settings components a shape. Inside it, its settings have its weight, and outside it they
// fall off to 0 over the blend distance. Where volumes overlap, a higher priority goes on top, then a smaller volume.
// To turn a volume off, deactivate its entity.
Volume :: struct {
	shape:          Shape,
	// Half the box's size along each of the entity's axes, or the sphere's radius in x, in meters. 0 gives
	// DEFAULT_EXTENT.
	extents:        [3]f32 `editor:"range=0,100"`,
	// In meters outside the shape. 0 is a hard edge.
	blend_distance: f32 `editor:"range=0,100"`,
	priority:       f32 `editor:"range=-100,100"`,
	// The settings' share where the volume is whole, up to 1. 0 means 1.
	weight:         f32 `editor:"range=0,1"`,
}

// Value is a setting that a volume can override. With override, the volume gives value, as it is. Without, the volume
// keeps value but leaves the setting to the volumes below it, or the default, so turning override off and on compares
// the two. A scene that sets the field sets override, unless it also sets <field>.override = false, so a game that
// makes volumes in code sets override itself. The defaults are the settings component's registered defaults (see
// ecs.register_component), which a component added in the editor starts from.
Value :: struct($T: typeid) {
	override: bool,
	value:    T,
}

// register_components registers Volume. Call it with the engine's components, in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Volume, VOLUME_ID)
}

// Volumes finds the volumes. It is a registration, like a query: make it again in on_reload.
Volumes :: struct {
	query: ecs.Query,
}

register :: proc(v: ^Volumes, w: ^ecs.World) {
	v.query = ecs.query(w, {ecs.read(w, ecs.Transform), ecs.optional(ecs.read(w, ecs.Previous_Transform)), ecs.read(w, Volume)})
}

// Influence is a volume that reaches a point, with its weight there.
Influence :: struct {
	entity:   ecs.Entity,
	weight:   f32,
	priority: f32,
	// The shape's volume, in cubic meters, to put a smaller volume over a larger one.
	size:     f32,
	global:   bool,
}

// Influences are the volumes that reach a point, in the order that they apply: the last goes on top.
Influences :: struct {
	items: [MAX_INFLUENCES]Influence,
	count: int,
}

// gather finds the volumes that reach a point, at their presented poses. hidden holds the entity slots to leave out, a
// bit each, as the renderer's Frame_Desc.hidden does. It allocates nothing.
gather :: proc(v: ^Volumes, w: ^ecs.World, point: ecs.World_Position, hidden: []u32 = nil) -> (inf: Influences) {
	it := ecs.query_iter(w, v.query)
	for view in ecs.query_next(&it) {
		poses := ecs.column(view, 0, ecs.Transform)
		previous := ecs.column(view, 1, ecs.Previous_Transform)
		volumes := ecs.column(view, 2, Volume)
		for e, i in ecs.entities(view) {
			if inf.count == MAX_INFLUENCES || is_hidden(hidden, e) {
				continue
			}
			pose := poses[i]
			if previous != nil {
				pose = ecs.interpolate(ecs.Transform(previous[i]), pose, w.clock.alpha)
			}
			weight, size := influence(volumes[i], pose, point)
			if weight > 0 {
				inf.items[inf.count] = {e, weight, volumes[i].priority, size, volumes[i].shape == .Global}
				inf.count += 1
			}
		}
	}
	slice.sort_by(inf.items[:inf.count], proc(a, b: Influence) -> bool {
		if a.priority != b.priority {
			return a.priority < b.priority
		}
		if a.global != b.global {
			return a.global
		}
		if a.size != b.size {
			return a.size > b.size
		}
		return ecs.entity_index(a.entity) < ecs.entity_index(b.entity)
	})
	return
}

// influence is a volume's weight at a point, and the size of its shape.
influence :: proc(v: Volume, pose: ecs.Transform, point: ecs.World_Position) -> (weight, size: f32) {
	base := v.weight > 0 ? min(v.weight, 1) : 1
	extent :: proc(e: f32) -> f32 {
		return e > 0 ? e : DEFAULT_EXTENT
	}
	scale := linalg.abs(pose.scale)
	offset := ecs.position_sub(point, pose.position)
	distance: f32
	switch v.shape {
	case .Global:
		return base, max(f32)
	case .Box:
		half := [3]f32{extent(v.extents.x), extent(v.extents.y), extent(v.extents.z)} * scale
		local := linalg.quaternion128_mul_vector3(linalg.quaternion_inverse(pose.rotation), offset)
		distance = linalg.length(linalg.max(linalg.abs(local) - half, 0))
		size = 8 * half.x * half.y * half.z
	case .Sphere:
		radius := extent(v.extents.x) * max(scale.x, scale.y, scale.z)
		distance = max(linalg.length(offset) - radius, 0)
		size = 4.18879 * radius * radius * radius
	}
	switch {
	case distance <= 0:
		return base, size
	case distance >= v.blend_distance:
		return 0, size
	}
	return base * (1 - distance / v.blend_distance), size
}

// blend_raw blends a registered settings component of the volumes that reach a point into out, which has its type. It
// starts from the component's defaults, and each volume with the component, from the bottom, moves the settings that it
// overrides toward its own by its weight: numbers and vectors in between, positions along the line, and everything else
// at a weight of a half or more. out's override flags say which settings a volume gave. touched is whether any volume
// with the component reaches the point.
blend_raw :: proc(w: ^ecs.World, inf: ^Influences, component: ecs.Component_Id, out: rawptr) -> (touched: bool) {
	info := ecs.registry_find(&w.registry, component)
	if info == nil {
		return false
	}
	if defaults := ecs.registry_defaults(&w.registry, info); defaults != nil {
		mem.copy(out, defaults, info.size)
	} else {
		mem.zero(out, info.size)
	}
	ti := type_info_of(info.type)
	for item in inf.items[:inf.count] {
		data := ecs.get_raw(w, item.entity, component)
		if data == nil {
			continue
		}
		touched = true
		blend_struct(ti, uintptr(data), uintptr(out), item.weight)
	}
	return
}

// blend blends a settings component, as blend_raw does. A component that is not registered gives zeros.
blend :: proc(w: ^ecs.World, inf: ^Influences, $T: typeid) -> (result: T, touched: bool) {
	info := ecs.registry_find_type(&w.registry, T)
	if info == nil {
		return {}, false
	}
	touched = blend_raw(w, inf, info.id, &result)
	return
}

// sample is a settings component at a point: gather, then blend.
sample :: proc(v: ^Volumes, w: ^ecs.World, $T: typeid, point: ecs.World_Position, hidden: []u32 = nil) -> T {
	inf := gather(v, w, point, hidden)
	result, _ := blend(w, &inf, T)
	return result
}

// blend_struct blends each Value field of a struct, and of the structs in it, at the same offsets in src and out.
@(private = "file")
blend_struct :: proc(ti: ^runtime.Type_Info, src, out: uintptr, weight: f32) {
	s, is_struct := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	if !is_struct {
		return
	}
	for i in 0 ..< s.field_count {
		field := s.types[i]
		offset := s.offsets[i]
		inner, is_inner := runtime.type_info_base(field).variant.(runtime.Type_Info_Struct)
		if !is_inner {
			continue
		}
		if inner.field_count != 2 || inner.names[0] != "override" || inner.names[1] != "value" || inner.types[0].id != bool {
			blend_struct(field, src + offset, out + offset, weight)
			continue
		}
		if !(^bool)(src + offset + inner.offsets[0])^ {
			continue
		}
		(^bool)(out + offset + inner.offsets[0])^ = true
		at := offset + inner.offsets[1]
		blend_value(inner.types[1], rawptr(src + at), rawptr(out + at), weight)
	}
}

@(private = "file")
blend_value :: proc(ti: ^runtime.Type_Info, from, out: rawptr, weight: f32) {
	if ti.id == ecs.World_Position {
		(^ecs.World_Position)(out)^ = ecs.position_lerp((^ecs.World_Position)(out)^, (^ecs.World_Position)(from)^, weight)
		return
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			(^f32)(out)^ = linalg.lerp((^f32)(out)^, (^f32)(from)^, weight)
			return
		case 8:
			(^f64)(out)^ = linalg.lerp((^f64)(out)^, (^f64)(from)^, f64(weight))
			return
		}
	case runtime.Type_Info_Array:
		if v.elem.id == f32 {
			a, b := ([^]f32)(out), ([^]f32)(from)
			for i in 0 ..< v.count {
				a[i] = linalg.lerp(a[i], b[i], weight)
			}
			return
		}
	}
	if weight >= 0.5 {
		mem.copy(out, from, ti.size)
	}
}

// is_hidden matches render.is_hidden: a bit for each entity slot.
@(private = "file")
is_hidden :: proc(hidden: []u32, e: ecs.Entity) -> bool {
	index := ecs.entity_index(e)
	return int(index / 32) < len(hidden) && hidden[index / 32] & (1 << (index % 32)) != 0
}
