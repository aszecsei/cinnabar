package script

import "base:intrinsics"
import "core:c"

import "core:fmt"

import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The tags of the engine's light userdata. They are engine constants, never registration order, because values in
// the VM keep them across code reloads. All light userdata share one metatable, which dispatches on the tag.
Light_Tag :: enum c.int {
	None,
	// The payload is the 64-bit handle.
	Entity,
	// The payload is the component ID.
	Component_Type,
	// The key under which an instance table holds its native handle. Scripts cannot make light userdata, so they
	// cannot reach it.
	Instance_Key,
	// An asset reference. The payload is one more than the index of its GUID in the runtime's asset_refs, so two
	// references to one asset are the same value and compare equal.
	Asset,
	// The key under which a script action's instance table holds its native handle (see actions.odin).
	Action_Key,
	// A push of an input context. The payload is its core.Input_Context_Token (see input_actions.odin).
	Input_Context,
	// A cutscene's player. The payload is the cutscene package's handle, which only that package reads (see
	// docs/cinematics/scripts.md).
	Cutscene,
}

// Light_Value is a light userdata of a type that another package owns, such as a Cutscene: its tag, and a payload that
// only that package reads. It holds no pointer, so it survives a code reload.
Light_Value :: struct {
	tag:     Light_Tag,
	payload: u64,
}

// Value is a value that native code gives to Luau or reads back from it: an event's argument, an action's argument, a
// behaviour's field, a blackboard's value or a save's entry. nil is Luau's nil. A string is a view, into the VM after
// check_value or into whatever the caller made it from, so a caller that keeps one clones it.
Value :: union {
	f64,
	bool,
	string,
	[3]f32,
	ecs.Entity,
	ecs.World_Position,
	format.Guid,
	Light_Value,
}

// Value_Kind is a Value's member, and Nil for none.
Value_Kind :: enum u8 {
	Nil,
	Number,
	Boolean,
	String,
	Vector,
	Entity,
	Position,
	Asset,
	Light,
}

Value_Kinds :: bit_set[Value_Kind]

value_kind :: proc(v: Value) -> Value_Kind {
	switch _ in v {
	case f64:
		return .Number
	case bool:
		return .Boolean
	case string:
		return .String
	case [3]f32:
		return .Vector
	case ecs.Entity:
		return .Entity
	case ecs.World_Position:
		return .Position
	case format.Guid:
		return .Asset
	case Light_Value:
		return .Light
	}
	return .Nil
}

// push_value pushes one value: nil for nil, the nil entity and the zero GUID.
push_value :: proc(r: ^Runtime, L: ^luau.State, v: Value) {
	switch x in v {
	case f64:
		luau.pushnumber(L, x)
	case bool:
		luau.pushboolean(L, b32(x))
	case string:
		luau.pushlstring(L, raw_data(x), c.size_t(len(x)))
	case [3]f32:
		push_vector(L, x)
	case ecs.Entity:
		push_entity(L, x)
	case ecs.World_Position:
		push_position(L, x)
	case format.Guid:
		push_asset(r, L, x)
	case Light_Value:
		push_light(L, x)
	case:
		luau.pushnil(L)
	}
}

// check_value reads the value at idx if its kind is one of accepts, and is false otherwise. Unlike the other check
// procs it raises no error, so that each caller raises its own. nil is read only when Nil is accepted. A light
// userdata is an entity, then an asset, then any other tag's Light_Value, as far as each is accepted. A string is a
// view into the VM.
check_value :: proc(
	r: ^Runtime,
	L: ^luau.State,
	idx: c.int,
	accepts: Value_Kinds,
) -> (
	Value,
	bool,
) {
	#partial switch luau.type(L, idx) {
	case .NIL:
		return nil, .Nil in accepts
	case .NUMBER:
		if .Number in accepts {
			return luau.tonumber(L, idx), true
		}
	case .BOOLEAN:
		if .Boolean in accepts {
			return bool(luau.toboolean(L, idx)), true
		}
	case .STRING:
		if .String in accepts {
			return luau.toodinstring(L, idx), true
		}
	case .VECTOR:
		if .Vector in accepts {
			v := luau.tovector(L, idx)
			return [3]f32{v[0], v[1], v[2]}, true
		}
	case .LIGHTUSERDATA:
		tag := Light_Tag(luau.lightuserdatatag(L, idx))
		if tag == .Entity && .Entity in accepts {
			return to_entity(L, idx), true
		}
		if tag == .Asset && .Asset in accepts {
			if guid := to_asset(r, L, idx); guid != {} {
				return guid, true
			}
			return nil, false
		}
		if tag != .Entity && tag != .Asset && .Light in accepts {
			payload, _ := to_light(L, idx, tag)
			return Light_Value{tag, payload}, true
		}
	case .USERDATA:
		if .Position in accepts {
			if p, ok := to_position(L, idx); ok {
				return p, true
			}
		}
	}
	return nil, false
}

// The most assets that scripts can refer to at once. A GUID keeps its place for the runtime's life.
MAX_ASSET_REFS :: 4096

// The tags of the engine's full userdata. Each has its own metatable.
Userdata_Tag :: enum c.int {
	None,
	World_Position,
	Quaternion,
	Component_Ref,
}

// Component_Ref is the result of entity:get. It holds no pointer, so each access looks up the entity's row again.
Component_Ref :: struct {
	entity: ecs.Entity,
	id:     ecs.Component_Id,
}

MAX_TYPE_METHODS :: 32

// Method is a method of an engine type, found by the atom of its name.
@(private)
Method :: struct {
	atom:      i16,
	name:      string,
	procedure: script_host.Binding_Proc,
}

@(private)
Type_Methods :: struct {
	methods: [MAX_TYPE_METHODS]Method,
	count:   int,
}

// light_method adds a method to a light userdata type, such as one that another package owns. Registrations, like
// bindings: reload clears them, so register them again in the Register_Proc.
light_method :: proc(
	r: ^Runtime,
	tag: Light_Tag,
	name: string,
	procedure: script_host.Binding_Proc,
) {
	add_method(r, &r.light_methods[tag], name, procedure)
}

@(private)
userdata_method :: proc(
	r: ^Runtime,
	tag: Userdata_Tag,
	name: string,
	procedure: script_host.Binding_Proc,
) {
	add_method(r, &r.userdata_methods[tag], name, procedure)
}

@(private = "file")
add_method :: proc(
	r: ^Runtime,
	t: ^Type_Methods,
	name: string,
	procedure: script_host.Binding_Proc,
) {
	assert(t.count < MAX_TYPE_METHODS, "script: too many methods on one type")
	t.methods[t.count] = {r.platform.script_atom(name), name, procedure}
	t.count += 1
}

// find_method finds a method by its atom. A string whose atom was asked for before its name was interned has none,
// so the name is compared too.
@(private)
find_method :: proc(t: ^Type_Methods, atom: c.int, name: string) -> script_host.Binding_Proc {
	for m in t.methods[:t.count] {
		if atom >= 0 ? c.int(m.atom) == atom : m.name == name {
			return m.procedure
		}
	}
	return nil
}

push_vector :: proc(L: ^luau.State, v: [3]f32) {
	luau.pushvector(L, v.x, v.y, v.z)
}

check_vector :: proc(L: ^luau.State, idx: c.int) -> [3]f32 {
	return luau.L_checkvector(L, idx)^
}

push_entity :: proc(L: ^luau.State, e: ecs.Entity) {
	if e == 0 {
		luau.pushnil(L)
		return
	}
	luau.pushlightuserdatatagged(L, rawptr(uintptr(e)), c.int(Light_Tag.Entity))
}

// to_entity is the entity at idx, or the nil entity if the value is not one.
to_entity :: proc(L: ^luau.State, idx: c.int) -> ecs.Entity {
	return ecs.Entity(uintptr(luau.tolightuserdatatagged(L, idx, c.int(Light_Tag.Entity))))
}

check_entity :: proc(L: ^luau.State, idx: c.int) -> ecs.Entity {
	e := to_entity(L, idx)
	if e == 0 {
		luau.L_typeerrorL(L, idx, "Entity")
	}
	return e
}

// push_asset pushes a reference to an asset, or nil for the zero GUID.
push_asset :: proc(r: ^Runtime, L: ^luau.State, guid: format.Guid) {
	if guid == {} {
		luau.pushnil(L)
		return
	}
	index := -1
	for g, i in r.asset_refs[:r.asset_ref_count] {
		if g == guid {
			index = i
			break
		}
	}
	if index < 0 {
		if r.asset_ref_count == MAX_ASSET_REFS {
			raise(
				L,
				fmt.aprintf(
					"scripts refer to more than %d assets",
					MAX_ASSET_REFS,
					allocator = frame(r),
				),
			)
		}
		index = r.asset_ref_count
		r.asset_refs[index] = guid
		r.asset_ref_count += 1
	}
	luau.pushlightuserdatatagged(L, rawptr(uintptr(index + 1)), c.int(Light_Tag.Asset))
}

// to_asset is the GUID of the asset reference at idx, or the zero GUID if the value is not one.
to_asset :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> format.Guid {
	index := int(uintptr(luau.tolightuserdatatagged(L, idx, c.int(Light_Tag.Asset))))
	return index > 0 && index <= r.asset_ref_count ? r.asset_refs[index - 1] : {}
}

// push_light pushes a light userdata of a tag with its payload.
push_light :: proc(L: ^luau.State, value: Light_Value) {
	luau.pushlightuserdatatagged(L, rawptr(uintptr(value.payload)), c.int(value.tag))
}

// to_light is the payload of the light userdata of the tag at idx, and false if the value is not one.
to_light :: proc(L: ^luau.State, idx: c.int, tag: Light_Tag) -> (payload: u64, ok: bool) {
	if luau.type(L, idx) != .LIGHTUSERDATA || Light_Tag(luau.lightuserdatatag(L, idx)) != tag {
		return 0, false
	}
	return u64(uintptr(luau.tolightuserdatatagged(L, idx, c.int(tag)))), true
}

// check_light is the payload of the light userdata of the tag at idx, and raises a type error, with name, if the value
// is not one.
check_light :: proc(L: ^luau.State, idx: c.int, tag: Light_Tag, name: cstring) -> u64 {
	payload, ok := to_light(L, idx, tag)
	if !ok {
		luau.L_typeerrorL(L, idx, name)
	}
	return payload
}

push_component_type :: proc(L: ^luau.State, id: ecs.Component_Id) {
	luau.pushlightuserdatatagged(L, rawptr(uintptr(id)), c.int(Light_Tag.Component_Type))
}

check_component_type :: proc(L: ^luau.State, idx: c.int) -> ecs.Component_Id {
	id := ecs.Component_Id(
		uintptr(luau.tolightuserdatatagged(L, idx, c.int(Light_Tag.Component_Type))),
	)
	if id == 0 {
		luau.L_typeerrorL(L, idx, "ComponentType")
	}
	return id
}

// Userdata memory is 8-byte aligned, and a quaternion128 is 16-byte aligned, so userdata are read and written
// unaligned.
@(private)
push_userdata :: proc(L: ^luau.State, tag: Userdata_Tag, value: $T) {
	data := luau.newuserdatataggedwithmetatable(L, size_of(T), c.int(tag))
	intrinsics.unaligned_store((^T)(data), value)
}

@(private)
to_userdata :: proc(
	L: ^luau.State,
	idx: c.int,
	tag: Userdata_Tag,
	$T: typeid,
) -> (
	value: T,
	ok: bool,
) {
	data := luau.touserdatatagged(L, idx, c.int(tag))
	if data == nil {
		return
	}
	return intrinsics.unaligned_load((^T)(data)), true
}

push_quaternion :: proc(L: ^luau.State, q: quaternion128) {
	push_userdata(L, .Quaternion, q)
}

to_quaternion :: proc(L: ^luau.State, idx: c.int) -> (quaternion128, bool) {
	return to_userdata(L, idx, .Quaternion, quaternion128)
}

check_quaternion :: proc(L: ^luau.State, idx: c.int) -> quaternion128 {
	q, ok := to_quaternion(L, idx)
	if !ok {
		luau.L_typeerrorL(L, idx, "Quaternion")
	}
	return q
}

push_position :: proc(L: ^luau.State, p: ecs.World_Position) {
	push_userdata(L, .World_Position, p)
}

to_position :: proc(L: ^luau.State, idx: c.int) -> (ecs.World_Position, bool) {
	return to_userdata(L, idx, .World_Position, ecs.World_Position)
}

check_position :: proc(L: ^luau.State, idx: c.int) -> ecs.World_Position {
	p, ok := to_position(L, idx)
	if !ok {
		luau.L_typeerrorL(L, idx, "WorldPosition")
	}
	return p
}

@(private)
to_component_ref :: proc(L: ^luau.State, idx: c.int) -> (Component_Ref, bool) {
	return to_userdata(L, idx, .Component_Ref, Component_Ref)
}

// key_atom is the string at idx with its atom, for field and method lookups.
@(private)
key_atom :: proc(L: ^luau.State, idx: c.int) -> (key: string, atom: c.int) {
	size: c.size_t
	s := luau.tolstringatom(L, idx, &size, &atom)
	if s == nil {
		return "", -1
	}
	return string(s[:size]), atom
}

// script_name is an Odin type name as scripts see it: without underscores, so Local_Transform is LocalTransform.
@(private)
script_name :: proc(name: string, buffer: []u8) -> string {
	n := 0
	for i in 0 ..< len(name) {
		if name[i] != '_' && n < len(buffer) {
			buffer[n] = name[i]
			n += 1
		}
	}
	return string(buffer[:n])
}
