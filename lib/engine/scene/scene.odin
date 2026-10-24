// Package scene loads scenes into the world: a cooked scene blob, or a snapshot from the editor (see
// docs/editor.md#scenes). Both arrive as an asset_format.Scene, and load replaces the world with it.
package scene

import "core:log"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

SCENE_ENTITY_ID :: ecs.Component_Id(8)

// Scene_Entity marks an entity that a scene made, with its scene ID. Entities that the game spawns have none.
Scene_Entity :: struct {
	id: u64 `editor:"read"`,
}

// register_components registers the components that scenes use. Call it from the game's component registration
// procedure, as with ecs.register_engine_components.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Scene_Entity, SCENE_ENTITY_ID)
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
// Fields that a scene does not set are zero. Previous_Transform starts equal to Transform, so nothing interpolates
// from where the old world was. The behaviours wake in the next script phase. scripts can be nil, and then the
// behaviours are skipped.
load :: proc(w: ^ecs.World, scripts: ^script.Runtime, s: format.Scene) {
	frame := w.platform.frame_allocator
	ecs.despawn_all(w)
	l := Loader {
		world   = w,
		handles = make(map[u64]ecs.Entity, len(s.entities), frame),
		fields  = make(map[ecs.Component_Id][]Field, frame),
	}
	// Every entity exists before any field is set, so a field can refer to an entity later in the scene.
	spawned := make([]ecs.Entity, len(s.entities), frame)
	for e, i in s.entities {
		if e.id == 0 || e.id in l.handles {
			log.warnf("scene: two entities have the scene ID %016x, or it is 0, so the second is skipped", e.id)
			continue
		}
		entity := ecs.spawn(w)
		spawned[i] = entity
		l.handles[e.id] = entity
		ecs.add(w, entity, Scene_Entity{e.id})
		if e.name != "" {
			ecs.add(w, entity, ecs.make_name(e.name))
		}
	}
	for e, i in s.entities {
		entity := spawned[i]
		if entity == 0 {
			continue
		}
		l.entity = e.id
		for c in e.components {
			add_component(&l, entity, c)
		}
		if e.parent != 0 {
			if parent, found := l.handles[e.parent]; found {
				ecs.add(w, entity, ecs.Parent{parent})
			} else {
				log.warnf("scene: entity %016x: its parent %016x is not in the scene", e.id, e.parent)
			}
		}
		if !e.active {
			ecs.add(w, entity, ecs.Disabled{})
		}
	}
	ecs.update_activity(w)
	for entity in spawned {
		if pose := ecs.get(w, entity, ecs.Transform); pose != nil && ecs.has(w, entity, ecs.Previous_Transform) {
			ecs.teleport(w, entity, pose^)
		}
	}
	log.infof("scene: loaded %d entities", len(l.handles))
	if scripts == nil {
		return
	}
	for e, i in s.entities {
		if spawned[i] == 0 {
			continue
		}
		l.entity = e.id
		for b in e.behaviours {
			script.attach_script(scripts, spawned[i], b.script, behaviour_fields(&l, b.fields))
		}
	}
}

@(private = "file")
Loader :: struct {
	world:   ^ecs.World,
	// From scene ID to the entity that it became.
	handles: map[u64]ecs.Entity,
	// The fields of each component type, made at its first use.
	fields:  map[ecs.Component_Id][]Field,
	// The scene ID of the entity being loaded, for messages.
	entity:  u64,
}

@(private = "file")
add_component :: proc(l: ^Loader, entity: ecs.Entity, c: format.Scene_Component) {
	id := ecs.Component_Id(c.id)
	switch id {
	case SCENE_ENTITY_ID, ecs.INACTIVE_ID, ecs.PARENT_ID, ecs.NAME_ID:
		// The loader makes these from the entity's own keys.
		return
	}
	info := ecs.registry_find(&l.world.registry, id)
	if info == nil {
		log.warnf("scene: entity %016x: the game has no component %d (%s), so it is skipped", l.entity, c.id, c.name)
		return
	}
	fields, known := l.fields[id]
	if !known {
		fields = component_fields(info.type, l.world.platform.frame_allocator)
		l.fields[id] = fields
	}
	data := make([]byte, info.size, l.world.platform.frame_allocator)
	for f in c.fields {
		field: ^Field
		for &candidate in fields {
			if format.scene_field_hash(candidate.name) == f.hash {
				field = &candidate
				break
			}
		}
		if field == nil {
			log.warnf("scene: entity %016x: %s has no field %s, so it is skipped", l.entity, info.name, f.name)
			continue
		}
		if expected := set_field(l, raw_data(data[field.offset:]), field^, f.value); expected != "" {
			log.warnf("scene: entity %016x: %s.%s takes %s, so it is skipped", l.entity, info.name, f.name, expected)
		}
	}
	ecs.add_raw(l.world, entity, id, data)
}

// set_field writes a value into a field. When the value does not fit the field's kind, it writes nothing and
// describes what the field takes.
@(private = "file")
set_field :: proc(l: ^Loader, dst: rawptr, field: Field, v: format.Scene_Value) -> (expected: string) {
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
	}
	return ""
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
		log.warnf("scene: entity %016x refers to %016x, which is not in the scene", l.entity, id)
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
		case:
			log.warnf("scene: entity %016x: a behaviour's field %s has %d numbers, which no field kind takes", l.entity, f.name, v.count)
			continue
		}
		append(&result, field)
	}
	return result[:]
}

#assert(size_of(quaternion128) == size_of([4]f32))
