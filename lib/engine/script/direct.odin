package script

import "base:intrinsics"
import "core:c"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"

// register_direct sets the direct access handlers of the engine's userdata (see docs/scripting/embedding.md#direct-field-access).
// They do what the metamethods do, without the closure call. A component field is found from the instruction's
// cached slot when it can be, and every other key takes the metamethods' path.
@(private)
register_direct :: proc(r: ^Runtime) {
	r.bindings.direct[Userdata_Tag.Component_Ref] = {
		get = ref_direct_get,
		set = ref_direct_set,
	}
	r.bindings.direct[Userdata_Tag.Quaternion] = {
		get = proc(L: ^luau.State, data: rawptr, atom: c.int, cachedslot: ^u16) {quaternion_index(L)},
		namecall = direct_namecall,
	}
	r.bindings.direct[Userdata_Tag.World_Position] = {
		namecall = direct_namecall,
	}
	// The VM rewrites a field access to its direct form only when the key has an atom.
	for name in ([?]string{"x", "y", "z", "w", "entity"}) {
		r.platform.script_atom(name)
	}
}

// enable_direct asks the host to call the direct access handlers. It needs the metatables, so init calls it once.
@(private)
enable_direct :: proc(r: ^Runtime) {
	if r.platform.script_direct_access == nil {
		return
	}
	for tag in ([?]Userdata_Tag{.Component_Ref, .Quaternion, .World_Position}) {
		r.direct_access = r.platform.script_direct_access(r.L, i32(tag)) || r.direct_access
	}
}

@(private = "file")
ref_direct_get :: proc(L: ^luau.State, data: rawptr, atom: c.int, cachedslot: ^u16) {
	r := runtime_of(L)
	ref := intrinsics.unaligned_load((^Component_Ref)(data))
	if f := cached_field(r, ref.id, atom, cachedslot); f != nil {
		push_field(L, f, component_data(r, L, ref))
		return
	}
	ref_index(L)
}

@(private = "file")
ref_direct_set :: proc(L: ^luau.State, data: rawptr, atom: c.int, cachedslot: ^u16) {
	r := runtime_of(L)
	ref := intrinsics.unaligned_load((^Component_Ref)(data))
	// A Transform write on a child also sets its local pose, so it takes the general path.
	if ref.id != ecs.TRANSFORM_ID {
		if f := cached_field(r, ref.id, atom, cachedslot); f != nil {
			set_field(r, L, f, component_data(r, L, ref), 3)
			return
		}
	}
	ref_newindex(L)
}

@(private = "file")
direct_namecall :: proc(L: ^luau.State, data: rawptr, atom: c.int, cachedslot: ^u16) -> c.int {
	return userdata_namecall(L)
}

// cached_field finds a component's field by atom. The slot holds a field's index plus one. Every tag shares the slot,
// so the field there is used only if it belongs to the component and has the atom.
@(private = "file")
cached_field :: proc(r: ^Runtime, id: ecs.Component_Id, atom: c.int, cachedslot: ^u16) -> ^Field {
	if atom < 0 {
		return nil
	}
	x := find_exposed(r, id)
	if x == nil {
		return nil
	}
	if index := int(cachedslot^) - 1; index >= x.first_field && index < x.first_field + x.field_count && c.int(r.fields[index].atom) == atom {
		return &r.fields[index]
	}
	f := find_field(r, x, atom, "")
	if f != nil {
		cachedslot^ = u16(int((uintptr(f) - uintptr(&r.fields[0])) / size_of(Field)) + 1)
	}
	return f
}
