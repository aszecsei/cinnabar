// Package scene loads scenes into the world: a cooked scene blob, or a snapshot from the editor (see
// docs/editor/document-and-scenes.md#scenes). Both arrive as an asset_format.Scene, and load replaces the world with it. The editor's
// operations use the same procedures for one entity, component or field at a time.
package scene

import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

SCENE_ENTITY_ID :: ecs.Component_Id(8)

// A volume setting's override flag is a field of its own in a scene, <field>.override, which only false needs: a
// scene that sets the setting overrides it, unless it also sets the flag to false (see docs/world/volumes.md#volumes).
OVERRIDE_SUFFIX :: ".override"

// Scene_Entity marks an entity that a scene made, with its scene ID. Entities that the game spawns have none.
Scene_Entity :: struct {
	id: u64 `editor:"read"`,
}

// register_components registers the components that scenes use. Call it from the game's component registration
// procedure, as with ecs.register_engine_components.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Scene_Entity, SCENE_ENTITY_ID)
}

// Problem is something in a scene that the world cannot use, by the scene ID of its entity. The loader logs each,
// and the editor shows them on their entities.
Problem :: struct {
	entity:  u64,
	message: string,
}

// load_asset loads a cooked scene by GUID and replaces the world with it. The blob stays loaded, so a second load is
// cheap.
load_asset :: proc(w: ^ecs.World, scripts: ^script.Runtime, assets: ^asset.Assets, guid: format.Guid) -> bool {
	h := asset.load(assets, guid) or_return
	data := asset.data(assets, h) or_return
	s, ok := format.scene_read(data, w.platform.frame_allocator)
	if !ok {
		buffer: [32]u8
		log.errorf("scene: %s is not a scene blob of this build. Cook the content.", format.guid_format(guid, &buffer))
		return false
	}
	load(w, scripts, s)
	return true
}

// load replaces every entity in the world with the scene's. Call it between frames, outside the script phase. What
// the world cannot use, such as a component that the game no longer registers or a field that it no longer has, is
// skipped with a warning: the scene keeps it, so a broken build never deletes scene data.
//
// Fields that a scene does not set have the component's registered defaults, or are zero. Previous_Transform starts
// equal to Transform, so nothing interpolates from where the old world was. The behaviours wake in the next script
// phase. scripts can be nil, and then the behaviours are skipped. handles, if given, is cleared and gets the entity of
// each scene ID. problems, if given, gets each warning, in frame memory.
load :: proc(w: ^ecs.World, scripts: ^script.Runtime, s: format.Scene, handles: ^map[u64]ecs.Entity = nil, problems: ^[dynamic]Problem = nil) {
	ecs.despawn_all(w)
	local: map[u64]ecs.Entity
	target := handles
	if target == nil {
		local = make(map[u64]ecs.Entity, len(s.entities), w.platform.frame_allocator)
		target = &local
	}
	clear(target)
	spawned := add_entities(w, scripts, s.entities, target, problems)
	log.infof("scene: loaded %d entities", spawned)
}

// add_entities adds entities to the world, as load does, and returns how many it spawned. handles maps scene IDs to
// entities, for the new entities and the ones that their fields refer to, and gets the new ones. An entity whose
// scene ID handles already has is skipped.
add_entities :: proc(w: ^ecs.World, scripts: ^script.Runtime, entities: []format.Scene_Entity, handles: ^map[u64]ecs.Entity, problems: ^[dynamic]Problem = nil) -> int {
	l := loader(w, handles, problems)
	// Every entity exists before any field is set, so a field can refer to an entity later in the scene.
	spawned := make([]ecs.Entity, len(entities), w.platform.frame_allocator)
	count := 0
	for e, i in entities {
		l.entity = e.id
		if e.id == 0 || e.id in handles {
			warn(&l, "two entities have the scene ID %016x, or it is 0, so the second is skipped", e.id)
			continue
		}
		entity := ecs.spawn(w)
		spawned[i] = entity
		count += 1
		handles[e.id] = entity
		ecs.add(w, entity, Scene_Entity{e.id})
		if e.name != "" {
			ecs.add(w, entity, ecs.make_name(e.name))
		}
	}
	for e, i in entities {
		entity := spawned[i]
		if entity == 0 {
			continue
		}
		l.entity = e.id
		for c in e.components {
			add_component_to(&l, entity, c)
		}
		if e.parent != 0 {
			if parent, found := handles[e.parent]; found {
				ecs.add(w, entity, ecs.Parent{parent})
			} else {
				warn(&l, "its parent %016x is not in the scene", e.parent)
			}
		}
		if !e.active {
			ecs.add(w, entity, ecs.Disabled{})
		}
	}
	ecs.update_activity(w)
	for entity in spawned {
		if entity != 0 {
			settle(w, entity)
		}
	}
	if scripts == nil {
		return count
	}
	for e, i in entities {
		if spawned[i] == 0 {
			continue
		}
		l.entity = e.id
		for b in e.behaviours {
			script.attach_script(scripts, spawned[i], b.script, behaviour_fields(&l, b.fields))
		}
	}
	return count
}

// add_component adds or replaces a component of the entity with scene ID id, with the scene's values. It returns
// false, with a problem, for a component that the game does not register or that scenes do not set.
add_component :: proc(w: ^ecs.World, entity: ecs.Entity, id: u64, c: format.Scene_Component, handles: ^map[u64]ecs.Entity, problems: ^[dynamic]Problem = nil) -> bool {
	l := loader(w, handles, problems)
	l.entity = id
	if is_derived(ecs.Component_Id(c.id)) {
		warn(&l, "scenes set component %d (%s) through the entity's keys, not as a component", c.id, c.name)
		return false
	}
	added := add_component_to(&l, entity, c)
	settle(w, entity)
	return added
}

// set_field sets one field of a component of the entity with scene ID id, or with reset, sets it back to its default,
// as a scene without the field would leave it. It returns false, with a problem, when the entity has no such component
// or field, or the value does not fit.
//
// For a volume's setting, setting the value leaves its override flag as it is, and a reset clears the flag. The flag
// itself is the field <field>.override: setting it sets the flag, and a reset sets it to true, as a scene without the
// line that sets the value has it. The editor sends the value and the flag together.
set_field :: proc(w: ^ecs.World, entity: ecs.Entity, id: u64, component: u64, f: format.Scene_Field, reset: bool, handles: ^map[u64]ecs.Entity, problems: ^[dynamic]Problem = nil) -> bool {
	l := loader(w, handles, problems)
	l.entity = id
	info := ecs.registry_find(&w.registry, ecs.Component_Id(component))
	data := ecs.get_raw(w, entity, ecs.Component_Id(component))
	if info == nil || data == nil {
		warn(&l, "it has no component %d, so its field %s is not set", component, f.name)
		return false
	}
	field, is_flag := find_field(&l, info, f.hash)
	if field == nil {
		warn(&l, "%s has no field %s, so it is not set", info.name, f.name)
		return false
	}
	flag := (^bool)(uintptr(data) + uintptr(field.override_offset))
	switch {
	case is_flag && reset:
		flag^ = true
	case is_flag:
		if f.value.kind != .Bool {
			warn(&l, "%s.%s takes true or false, so it is not set", info.name, f.name)
			return false
		}
		flag^ = f.value.ints[0] != 0
	case reset:
		reset_field(data, ecs.registry_defaults(&w.registry, info), field^)
		if field.has_override {
			flag^ = false
		}
	case:
		if expected := write_field(&l, rawptr(uintptr(data) + uintptr(field.offset)), field^, f.value); expected != "" {
			warn(&l, "%s.%s takes %s, so it is not set", info.name, f.name, expected)
			return false
		}
	}
	if ecs.Component_Id(component) == ecs.TRANSFORM_ID {
		settle(w, entity)
	}
	return true
}

// behaviour_field converts a behaviour's value to a script value, for the entity with scene ID id. The script
// runtime checks it against the class.
behaviour_field :: proc(w: ^ecs.World, id: u64, f: format.Scene_Field, handles: ^map[u64]ecs.Entity, problems: ^[dynamic]Problem = nil) -> (field: script.Behaviour_Field, ok: bool) {
	l := loader(w, handles, problems)
	l.entity = id
	fields := behaviour_fields(&l, {f})
	if len(fields) == 0 {
		return
	}
	return fields[0], true
}

// is_derived is true for the components that the loader makes from an entity's keys, or that the world makes.
is_derived :: proc(id: ecs.Component_Id) -> bool {
	switch id {
	case SCENE_ENTITY_ID, ecs.INACTIVE_ID, ecs.PARENT_ID, ecs.NAME_ID:
		return true
	}
	return false
}

// settle makes Previous_Transform equal to Transform, so an entity that a scene or an edit placed does not
// interpolate from where it was.
@(private = "file")
settle :: proc(w: ^ecs.World, entity: ecs.Entity) {
	if pose := ecs.get(w, entity, ecs.Transform); pose != nil && ecs.has(w, entity, ecs.Previous_Transform) {
		ecs.teleport(w, entity, pose^)
	}
}

@(private = "file")
Loader :: struct {
	world:    ^ecs.World,
	// From scene ID to entity.
	handles:  ^map[u64]ecs.Entity,
	// The fields of each component type, made at its first use.
	fields:   map[ecs.Component_Id][]Field,
	problems: ^[dynamic]Problem,
	// The scene ID of the entity being loaded, for messages.
	entity:   u64,
}

@(private = "file")
loader :: proc(w: ^ecs.World, handles: ^map[u64]ecs.Entity, problems: ^[dynamic]Problem) -> Loader {
	return {world = w, handles = handles, fields = make(map[ecs.Component_Id][]Field, w.platform.frame_allocator), problems = problems}
}

// warn logs a problem with the entity being loaded, and keeps it.
@(private = "file")
warn :: proc(l: ^Loader, message: string, args: ..any) {
	text := fmt.aprintf(message, ..args, allocator = l.world.platform.frame_allocator)
	log.warnf("scene: entity %016x: %s", l.entity, text)
	if l.problems != nil {
		append(l.problems, Problem{l.entity, text})
	}
}

// find_field finds the field whose name has the hash, or the volume setting whose override flag it is.
@(private = "file")
find_field :: proc(l: ^Loader, info: ^ecs.Component_Info, name_hash: u64) -> (field: ^Field, is_flag: bool) {
	fields, known := l.fields[info.id]
	if !known {
		fields = component_fields(info.type, l.world.platform.frame_allocator)
		l.fields[info.id] = fields
	}
	for &candidate in fields {
		h := format.scene_field_hash(candidate.name)
		if h == name_hash {
			return &candidate, false
		}
		if candidate.has_override && hash.fnv64a(transmute([]byte)string(OVERRIDE_SUFFIX), h) == name_hash {
			return &candidate, true
		}
	}
	return nil, false
}

@(private = "file")
add_component_to :: proc(l: ^Loader, entity: ecs.Entity, c: format.Scene_Component) -> bool {
	id := ecs.Component_Id(c.id)
	if is_derived(id) {
		// The loader makes these from the entity's own keys.
		return false
	}
	info := ecs.registry_find(&l.world.registry, id)
	if info == nil {
		warn(l, "the game has no component %d (%s), so it is skipped", c.id, c.name)
		return false
	}
	data := make([]byte, info.size, l.world.platform.frame_allocator)
	if defaults := ecs.registry_defaults(&l.world.registry, info); defaults != nil {
		mem.copy(raw_data(data), defaults, info.size)
	}
	// The values first: a setting that the scene sets is overridden, unless its flag, in any order, says otherwise.
	for is_flags in ([2]bool{false, true}) {
		for f in c.fields {
			field, is_flag := find_field(l, info, f.hash)
			switch {
			case field == nil:
				if !is_flags {
					warn(l, "%s has no field %s, so it is skipped", info.name, f.name)
				}
			case is_flag != is_flags:
			case is_flag && f.value.kind != .Bool:
				warn(l, "%s.%s takes true or false, so it is skipped", info.name, f.name)
			case is_flag:
				data[field.override_offset] = u8(f.value.ints[0] != 0)
			case:
				if expected := write_field(l, raw_data(data[field.offset:]), field^, f.value); expected != "" {
					warn(l, "%s.%s takes %s, so it is skipped", info.name, f.name, expected)
				} else if field.has_override {
					data[field.override_offset] = 1
				}
			}
		}
	}
	ecs.add_raw(l.world, entity, id, data)
	return true
}

// write_field writes a value into a field. When the value does not fit the field's kind, it writes nothing and
// describes what the field takes.
@(private = "file")
write_field :: proc(l: ^Loader, dst: rawptr, field: Field, v: format.Scene_Value) -> (expected: string) {
	scalar := v.kind == .Number && v.count == 1
	integer := scalar && v.integer & 1 != 0
	switch field.kind {
	case .Bool:
		if v.kind != .Bool {
			return "true or false"
		}
		(^bool)(dst)^ = v.ints[0] != 0
	case .I8, .I16, .I32, .I64, .U8, .U16, .U32, .U64:
		if !integer || !put_integer(dst, field.kind, v.ints[0]) {
			return "an integer in its range"
		}
	case .F32:
		if !scalar {
			return "a number"
		}
		(^f32)(dst)^ = f32(v.floats[0])
	case .F64:
		if !scalar {
			return "a number"
		}
		(^f64)(dst)^ = v.floats[0]
	case .Enum:
		value: i64
		switch {
		case v.kind == .Name:
			found := false
			for e in field.enum_values {
				if e.name == v.text {
					value, found = e.value, true
				}
			}
			if !found {
				return "one of its enum's names"
			}
		case integer:
			value = v.ints[0]
		case:
			return "one of its enum's names"
		}
		if !put_integer(dst, field.enum_base, value) {
			return "a value that fits its enum"
		}
	case .Vector3:
		if v.kind != .Number || v.count != 3 {
			return "three numbers, such as [0, 1, 0]"
		}
		(^[3]f32)(dst)^ = {f32(v.floats[0]), f32(v.floats[1]), f32(v.floats[2])}
	case .Vector2:
		if v.kind != .Number || v.count != 2 {
			return "two numbers, such as [0, 1]"
		}
		(^[2]f32)(dst)^ = {f32(v.floats[0]), f32(v.floats[1])}
	case .Quaternion:
		if v.kind != .Number || v.count != 4 {
			return "four numbers, x, y, z and w"
		}
		(^[4]f32)(dst)^ = {f32(v.floats[0]), f32(v.floats[1]), f32(v.floats[2]), f32(v.floats[3])}
	case .Position:
		if v.kind != .Number || v.count != 3 || v.integer & 0b111 != 0b111 {
			return "three raw integers in units of 2^-24 m"
		}
		for i in 0 ..< 3 {
			raw := v.ints[i]
			if raw < -ecs.POSITION_LIMIT || raw > ecs.POSITION_LIMIT {
				return "raw values within the world's range"
			}
		}
		(^ecs.World_Position)(dst)^ = {raw = {v.ints[0], v.ints[1], v.ints[2]}}
	case .Entity:
		if v.kind != .Entity {
			return "a scene ID, such as @1b04c7e95a2f3d88"
		}
		(^ecs.Entity)(dst)^ = resolve(l, v.entity)
	case .Asset:
		if v.kind != .Asset {
			return "an asset's GUID, such as $9db8150cc7215ffc2708d20d77cf60bf"
		}
		(^format.Guid)(dst)^ = v.asset
	}
	return ""
}

// reset_field sets a field of a component's data back to its bytes in the component's defaults, or zeroes it without.
@(private = "file")
reset_field :: proc(data, defaults: rawptr, field: Field) {
	dst := rawptr(uintptr(data) + uintptr(field.offset))
	if defaults != nil {
		mem.copy(dst, rawptr(uintptr(defaults) + uintptr(field.offset)), field_size(field))
	} else {
		mem.zero(dst, field_size(field))
	}
}

@(private = "file")
field_size :: proc(field: Field) -> int {
	switch field.kind {
	case .Bool, .I8, .U8:
		return 1
	case .I16, .U16:
		return 2
	case .I32, .U32, .F32:
		return 4
	case .I64, .U64, .F64, .Entity, .Vector2:
		return 8
	case .Enum:
		return field_size(Field{kind = field.enum_base})
	case .Vector3:
		return 12
	case .Quaternion:
		return 16
	case .Position:
		return 24
	case .Asset:
		return size_of(format.Guid)
	}
	return 0
}

// put_integer writes an integer of the kind, and returns false, writing nothing, if it does not fit. A u64 beyond
// i64's range arrives with its bits in an i64.
@(private = "file")
put_integer :: proc(dst: rawptr, kind: Field_Kind, value: i64) -> bool {
	fits :: proc(value: i64, $T: typeid) -> bool {
		return value >= i64(min(T)) && value <= i64(max(T))
	}
	#partial switch kind {
	case .I8:
		fits(value, i8) or_return
		(^i8)(dst)^ = i8(value)
	case .I16:
		fits(value, i16) or_return
		(^i16)(dst)^ = i16(value)
	case .I32:
		fits(value, i32) or_return
		(^i32)(dst)^ = i32(value)
	case .I64:
		(^i64)(dst)^ = value
	case .U8:
		fits(value, u8) or_return
		(^u8)(dst)^ = u8(value)
	case .U16:
		fits(value, u16) or_return
		(^u16)(dst)^ = u16(value)
	case .U32:
		fits(value, u32) or_return
		(^u32)(dst)^ = u32(value)
	case .U64:
		(^u64)(dst)^ = u64(value)
	case:
		return false
	}
	return true
}

@(private = "file")
resolve :: proc(l: ^Loader, id: u64) -> ecs.Entity {
	if id == 0 {
		return 0
	}
	entity, found := l.handles[id]
	if !found {
		warn(l, "it refers to %016x, which is not in the scene", id)
	}
	return entity
}

// behaviour_fields converts a behaviour's values to script values. The script runtime checks them against the class.
@(private = "file")
behaviour_fields :: proc(l: ^Loader, fields: []format.Scene_Field) -> []script.Behaviour_Field {
	result := make([dynamic]script.Behaviour_Field, 0, len(fields), l.world.platform.frame_allocator)
	for f in fields {
		v := f.value
		field := script.Behaviour_Field {
			name = f.name,
		}
		switch {
		case v.kind == .Bool:
			field.kind, field.boolean = .Boolean, v.ints[0] != 0
		case v.kind == .Number && v.count == 1:
			field.kind, field.number = .Number, v.floats[0]
		case v.kind == .Number && v.count == 3:
			field.kind, field.vector = .Vector, {f32(v.floats[0]), f32(v.floats[1]), f32(v.floats[2])}
		case v.kind == .String || v.kind == .Name:
			field.kind, field.text = .String, v.text
		case v.kind == .Entity:
			field.entity = resolve(l, v.entity)
			field.kind = .Entity if field.entity != 0 else .Nil
		case v.kind == .Asset:
			warn(l, "a behaviour's field %s is an asset, which behaviours do not take yet", f.name)
			continue
		case:
			warn(l, "a behaviour's field %s has %d numbers, which no field kind takes", f.name, v.count)
			continue
		}
		append(&result, field)
	}
	return result[:]
}

#assert(size_of(quaternion128) == size_of([4]f32))
