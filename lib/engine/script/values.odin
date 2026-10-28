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

// method adds a method to a light userdata or userdata type. Registrations, like bindings: reload clears them.
@(private)
light_method :: proc(r: ^Runtime, tag: Light_Tag, name: string, procedure: script_host.Binding_Proc) {
	add_method(r, &r.light_methods[tag], name, procedure)
}

@(private)
userdata_method :: proc(r: ^Runtime, tag: Userdata_Tag, name: string, procedure: script_host.Binding_Proc) {
	add_method(r, &r.userdata_methods[tag], name, procedure)
}

@(private = "file")
add_method :: proc(r: ^Runtime, t: ^Type_Methods, name: string, procedure: script_host.Binding_Proc) {
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
			raise(L, fmt.aprintf("scripts refer to more than %d assets", MAX_ASSET_REFS, allocator = frame(r)))
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

push_component_type :: proc(L: ^luau.State, id: ecs.Component_Id) {
	luau.pushlightuserdatatagged(L, rawptr(uintptr(id)), c.int(Light_Tag.Component_Type))
}

check_component_type :: proc(L: ^luau.State, idx: c.int) -> ecs.Component_Id {
	id := ecs.Component_Id(uintptr(luau.tolightuserdatatagged(L, idx, c.int(Light_Tag.Component_Type))))
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
to_userdata :: proc(L: ^luau.State, idx: c.int, tag: Userdata_Tag, $T: typeid) -> (value: T, ok: bool) {
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
