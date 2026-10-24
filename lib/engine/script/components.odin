package script

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:reflect"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"

MAX_EXPOSED :: 64
MAX_FIELDS :: 512
MAX_NAME :: 64

// Field_Kind is how a component field looks to scripts.
@(private)
Field_Kind :: enum u8 {
	F32,
	F64,
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	Bool,
	// A string with the enum value's name.
	Enum,
	// [3]f32 as a vector.
	Vector,
	Quaternion,
	Position,
	Entity,
}

// Field is a component field that scripts can see. name and info point into the DLL image, so reload clears the
// fields and expose builds them again.
@(private)
Field :: struct {
	atom:     i16,
	name:     string,
	offset:   u32,
	kind:     Field_Kind,
	readonly: bool,
	info:     ^runtime.Type_Info,
}

// Exposed is a native component that scripts can see.
@(private)
Exposed :: struct {
	id:          ecs.Component_Id,
	name:        [MAX_NAME]u8,
	name_len:    int,
	size:        int,
	first_field: int,
	field_count: int,
	// The value that entity:add starts from.
	default:     [ecs.MAX_COMPONENT_SIZE]u8,
}

// expose makes a registered native component visible to scripts as a global with its script name (Local_Transform
// is LocalTransform). Scripts see the fields whose types they can hold: numbers, bool, enums, [3]f32, quaternion128,
// World_Position and Entity. The struct tag `script:"read"` makes a field read-only, and `script:"-"` hides it.
// entity:add starts from default. Call it from the game's Register_Proc, after the world's components exist.
expose :: proc {
	expose_zeroed,
	expose_with_default,
}

expose_zeroed :: proc(r: ^Runtime, $T: typeid) {
	expose_with_default(r, T, T{})
}

expose_with_default :: proc(r: ^Runtime, $T: typeid, default: T) {
	info := ecs.registry_find_type(&r.world.registry, T)
	if info == nil {
		log.panicf("script: register %v with the world before exposing it", typeid_of(T))
	}
	if r.exposed_count == MAX_EXPOSED {
		log.panicf("script: more than %d exposed components", MAX_EXPOSED)
	}
	x := &r.exposed[r.exposed_count]
	r.exposed_count += 1
	x^ = {
		id          = info.id,
		size        = size_of(T),
		first_field = r.field_count,
	}
	default := default
	mem.copy(&x.default, &default, size_of(T))
	x.name_len = len(script_name(info.name, x.name[:]))

	for f in reflect.struct_fields_zipped(T) {
		tag := reflect.struct_tag_get(f.tag, "script")
		kind, supported := field_kind(f.type)
		if tag == "-" || !supported || f.is_using {
			continue
		}
		if r.field_count == MAX_FIELDS {
			log.panicf("script: more than %d exposed fields", MAX_FIELDS)
		}
		r.fields[r.field_count] = {
			atom     = r.platform.script_atom(f.name),
			name     = f.name,
			offset   = u32(f.offset),
			kind     = kind,
			readonly = tag == "read",
			info     = f.type,
		}
		r.field_count += 1
	}
	x.field_count = r.field_count - x.first_field
	push_component_type(r.L, x.id)
	set_path(r, exposed_name(x))
}

@(private = "file")
field_kind :: proc(ti: ^runtime.Type_Info) -> (kind: Field_Kind, ok: bool) {
	switch ti.id {
	case ecs.World_Position:
		return .Position, true
	case ecs.Entity:
		return .Entity, true
	}
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			return .F32, true
		case 8:
			return .F64, true
		}
	case runtime.Type_Info_Integer:
		kinds := v.signed ? [4]Field_Kind{.I8, .I16, .I32, .I64} : [4]Field_Kind{.U8, .U16, .U32, .U64}
		switch ti.size {
		case 1:
			return kinds[0], true
		case 2:
			return kinds[1], true
		case 4:
			return kinds[2], true
		case 8:
			return kinds[3], true
		}
	case runtime.Type_Info_Boolean:
		return .Bool, ti.size == 1
	case runtime.Type_Info_Enum:
		return .Enum, true
	case runtime.Type_Info_Array:
		if v.count == 3 && v.elem.id == f32 {
			return .Vector, true
		}
	case runtime.Type_Info_Quaternion:
		return .Quaternion, ti.size == size_of(quaternion128)
	}
	return
}

@(private)
exposed_name :: proc(x: ^Exposed) -> string {
	return string(x.name[:x.name_len])
}

@(private)
find_exposed :: proc(r: ^Runtime, id: ecs.Component_Id) -> ^Exposed {
	for &x in r.exposed[:r.exposed_count] {
		if x.id == id {
			return &x
		}
	}
	return nil
}

@(private)
find_field :: proc(r: ^Runtime, x: ^Exposed, atom: c.int, name: string) -> ^Field {
	for &f in r.fields[x.first_field:][:x.field_count] {
		if atom >= 0 ? c.int(f.atom) == atom : f.name == name {
			return &f
		}
	}
	return nil
}

// component_name is the script name of a component type, for messages.
@(private)
component_name :: proc(r: ^Runtime, id: ecs.Component_Id) -> string {
	if x := find_exposed(r, id); x != nil {
		return exposed_name(x)
	}
	if info := ecs.registry_find(&r.world.registry, id); info != nil {
		return info.name
	}
	return fmt.aprintf("component %x", u64(id), allocator = frame(r))
}

// component_data finds the component behind a reference. It raises an error if the entity is destroyed or no longer
// has the component.
@(private)
component_data :: proc(r: ^Runtime, L: ^luau.State, ref: Component_Ref) -> [^]byte {
	if !ecs.is_alive(r.world, ref.entity) {
		raise(L, "the entity is destroyed")
	}
	data := ecs.get_raw(r.world, ref.entity, ref.id)
	if data == nil {
		raise(L, fmt.aprintf("the entity has no %s", component_name(r, ref.id), allocator = frame(r)))
	}
	return ([^]byte)(data)
}

@(private)
push_field :: proc(L: ^luau.State, f: ^Field, data: [^]byte) {
	p := rawptr(&data[f.offset])
	switch f.kind {
	case .F32:
		luau.pushnumber(L, f64((^f32)(p)^))
	case .F64:
		luau.pushnumber(L, (^f64)(p)^)
	case .I8:
		luau.pushnumber(L, f64((^i8)(p)^))
	case .I16:
		luau.pushnumber(L, f64((^i16)(p)^))
	case .I32:
		luau.pushnumber(L, f64((^i32)(p)^))
	case .I64:
		luau.pushnumber(L, f64((^i64)(p)^))
	case .U8:
		luau.pushnumber(L, f64((^u8)(p)^))
	case .U16:
		luau.pushnumber(L, f64((^u16)(p)^))
	case .U32:
		luau.pushnumber(L, f64((^u32)(p)^))
	case .U64:
		luau.pushnumber(L, f64((^u64)(p)^))
	case .Bool:
		luau.pushboolean(L, b32((^bool)(p)^))
	case .Enum:
		if name, ok := reflect.enum_name_from_value_any(any{p, f.info.id}); ok {
			luau.pushodinstring(L, name)
		} else {
			luau.pushnil(L)
		}
	case .Vector:
		push_vector(L, (^[3]f32)(p)^)
	case .Quaternion:
		push_quaternion(L, (^quaternion128)(p)^)
	case .Position:
		push_position(L, (^ecs.World_Position)(p)^)
	case .Entity:
		push_entity(L, (^ecs.Entity)(p)^)
	}
}

// set_field writes the value at idx into a field. A value of the wrong type raises an error.
@(private)
set_field :: proc(r: ^Runtime, L: ^luau.State, f: ^Field, data: [^]byte, idx: c.int) {
	if f.readonly {
		raise(L, fmt.aprintf("%s is read-only", f.name, allocator = frame(r)))
	}
	p := rawptr(&data[f.offset])
	switch f.kind {
	case .F32:
		(^f32)(p)^ = f32(luau.L_checknumber(L, idx))
	case .F64:
		(^f64)(p)^ = luau.L_checknumber(L, idx)
	case .I8:
		(^i8)(p)^ = i8(luau.L_checknumber(L, idx))
	case .I16:
		(^i16)(p)^ = i16(luau.L_checknumber(L, idx))
	case .I32:
		(^i32)(p)^ = i32(luau.L_checknumber(L, idx))
	case .I64:
		(^i64)(p)^ = i64(luau.L_checknumber(L, idx))
	case .U8:
		(^u8)(p)^ = u8(luau.L_checknumber(L, idx))
	case .U16:
		(^u16)(p)^ = u16(luau.L_checknumber(L, idx))
	case .U32:
		(^u32)(p)^ = u32(luau.L_checknumber(L, idx))
	case .U64:
		(^u64)(p)^ = u64(luau.L_checknumber(L, idx))
	case .Bool:
		(^bool)(p)^ = bool(luau.L_checkboolean(L, idx))
	case .Enum:
		name := checkodinstring(L, idx)
		value, found := reflect.enum_from_name_any(f.info.id, name)
		if !found {
			raise(L, fmt.aprintf("%q is not a value of %s", name, f.name, allocator = frame(r)))
		}
		enum_info := runtime.type_info_base(f.info).variant.(runtime.Type_Info_Enum)
		switch enum_info.base.size {
		case 1:
			(^u8)(p)^ = u8(value)
		case 2:
			(^u16)(p)^ = u16(value)
		case 4:
			(^u32)(p)^ = u32(value)
		case 8:
			(^u64)(p)^ = u64(value)
		}
	case .Vector:
		(^[3]f32)(p)^ = check_vector(L, idx)
	case .Quaternion:
		(^quaternion128)(p)^ = check_quaternion(L, idx)
	case .Position:
		(^ecs.World_Position)(p)^ = check_position(L, idx)
	case .Entity:
		(^ecs.Entity)(p)^ = luau.isnil(L, idx) ? 0 : check_entity(L, idx)
	}
}

// ref_index is the __index of a component reference: a field of the component, or its entity.
@(private)
ref_index :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	ref, _ := to_component_ref(L, 1)
	key, atom := key_atom(L, 2)
	if key == "entity" {
		push_entity(L, ref.entity)
		return 1
	}
	if ref.id == ecs.TRANSFORM_ID && transform_index(r, L, ref, key) {
		return 1
	}
	f := ref_field(r, L, ref, atom, key)
	push_field(L, f, component_data(r, L, ref))
	return 1
}

// ref_newindex is the __newindex of a component reference. The write goes straight to the component's storage.
@(private)
ref_newindex :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	ref, _ := to_component_ref(L, 1)
	key, atom := key_atom(L, 2)
	if ref.id == ecs.TRANSFORM_ID && transform_newindex(r, L, ref, key) {
		return 0
	}
	f := ref_field(r, L, ref, atom, key)
	set_field(r, L, f, component_data(r, L, ref), 3)
	return 0
}

@(private = "file")
ref_field :: proc(r: ^Runtime, L: ^luau.State, ref: Component_Ref, atom: c.int, key: string) -> ^Field {
	x := find_exposed(r, ref.id)
	if x == nil {
		raise(L, fmt.aprintf("%s is not exposed to scripts", component_name(r, ref.id), allocator = frame(r)))
	}
	f := find_field(r, x, atom, key)
	if f == nil {
		raise(L, fmt.aprintf("%s has no field %s", exposed_name(x), key, allocator = frame(r)))
	}
	return f
}

@(private)
ref_tostring :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	ref, _ := to_component_ref(L, 1)
	luau.pushodinstring(L, fmt.aprintf("%s(%v)", component_name(r, ref.id), entity_text(r, ref.entity), allocator = frame(r)))
	return 1
}

@(private)
ref_eq :: proc(L: ^luau.State) -> c.int {
	a, a_ok := to_component_ref(L, 1)
	b, b_ok := to_component_ref(L, 2)
	luau.pushboolean(L, b32(a_ok && b_ok && a == b))
	return 1
}

// fill_fields sets the fields of a new component from a table of field values at idx.
@(private)
fill_fields :: proc(r: ^Runtime, L: ^luau.State, ref: Component_Ref, x: ^Exposed, idx: c.int) {
	luau.pushnil(L)
	for luau.next(L, idx) {
		if luau.type(L, -2) != .STRING {
			raise(L, "component values are given by field name")
		}
		key, atom := key_atom(L, -2)
		if !(ref.id == ecs.TRANSFORM_ID && transform_newindex(r, L, ref, key, value = -1)) {
			f := find_field(r, x, atom, key)
			if f == nil {
				raise(L, fmt.aprintf("%s has no field %s", exposed_name(x), key, allocator = frame(r)))
			}
			set_field(r, L, f, component_data(r, L, ref), luau.absindex(L, -1))
		}
		luau.pop(L, 1)
	}
}

// Transform has fields beyond its struct: the local pose of a child, and its axes. Unity's +Z is forward, +Y up and
// +X right.
FORWARD :: [3]f32{0, 0, 1}
UP :: [3]f32{0, 1, 0}
RIGHT :: [3]f32{1, 0, 0}

@(private = "file")
transform_index :: proc(r: ^Runtime, L: ^luau.State, ref: Component_Ref, key: string) -> bool {
	switch key {
	case "local_position", "local_rotation", "local_scale":
		local := local_transform(r, L, ref.entity)
		switch key {
		case "local_position":
			push_vector(L, local.offset)
		case "local_rotation":
			push_quaternion(L, local.rotation)
		case:
			push_vector(L, local.scale)
		}
		return true
	case "forward", "up", "right":
		pose := (^ecs.Transform)(component_data(r, L, ref))
		axis := key == "forward" ? FORWARD : key == "up" ? UP : RIGHT
		push_vector(L, linalg.quaternion_mul_vector3(pose.rotation, axis))
		return true
	}
	return false
}

// transform_newindex handles the Transform fields that need more than a store. Setting position, rotation or scale
// on a child computes its Local_Transform, so the pose stays after propagation.
@(private = "file")
transform_newindex :: proc(r: ^Runtime, L: ^luau.State, ref: Component_Ref, key: string, value: c.int = 3) -> bool {
	idx := luau.absindex(L, value)
	switch key {
	case "position", "rotation", "scale":
		pose := (^ecs.Transform)(component_data(r, L, ref))^
		switch key {
		case "position":
			pose.position = check_position(L, idx)
		case "rotation":
			pose.rotation = check_quaternion(L, idx)
		case:
			pose.scale = check_vector(L, idx)
		}
		set_pose(r, L, ref.entity, pose)
		return true
	case "local_position", "local_rotation", "local_scale":
		local := local_transform(r, L, ref.entity)
		switch key {
		case "local_position":
			local.offset = check_vector(L, idx)
		case "local_rotation":
			local.rotation = check_quaternion(L, idx)
		case:
			local.scale = check_vector(L, idx)
		}
		if parent, ok := parent_pose(r, ref.entity); ok {
			(^ecs.Transform)(component_data(r, L, ref))^ = ecs.compose(parent, local^)
		}
		return true
	case "forward", "up", "right":
		raise(L, fmt.aprintf("%s is read-only", key, allocator = frame(r)))
	}
	return false
}

@(private = "file")
local_transform :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity) -> ^ecs.Local_Transform {
	local := ecs.get(r.world, e, ecs.Local_Transform)
	if local == nil {
		raise(L, "the entity has no parent, so it has no local pose")
	}
	return local
}

// parent_pose is the Transform of an entity's parent, if it has one.
@(private)
parent_pose :: proc(r: ^Runtime, e: ecs.Entity) -> (pose: ecs.Transform, ok: bool) {
	parent := ecs.get(r.world, e, ecs.Parent)
	if parent == nil {
		return
	}
	p := ecs.get(r.world, parent.entity, ecs.Transform)
	if p == nil {
		return
	}
	return p^, true
}

// set_pose sets an entity's world pose. For a child, it also sets the Local_Transform that gives that pose.
@(private)
set_pose :: proc(r: ^Runtime, L: ^luau.State, e: ecs.Entity, pose: ecs.Transform) {
	(^ecs.Transform)(component_data(r, L, {e, ecs.TRANSFORM_ID}))^ = pose
	if parent, ok := parent_pose(r, e); ok {
		if local := ecs.get(r.world, e, ecs.Local_Transform); local != nil {
			local^ = local_from_world(parent, pose)
		}
	}
}

// local_from_world inverts ecs.compose: the local pose that gives a world pose under a parent.
@(private)
local_from_world :: proc(parent, pose: ecs.Transform) -> ecs.Local_Transform {
	inverse := linalg.quaternion_inverse(parent.rotation)
	return {
		offset = linalg.quaternion_mul_vector3(inverse, ecs.position_sub(pose.position, parent.position)) / parent.scale,
		rotation = inverse * pose.rotation,
		scale = pose.scale / parent.scale,
	}
}
