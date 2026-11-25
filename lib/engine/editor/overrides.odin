package editor

import "core:fmt"
import "core:hash"
import "core:log"
import "core:slice"

import "cinnabar:engine/anim"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// Overrides are values that owners in the editor write over the world in Edit, outside the document (see
// docs/editor/link.md#overrides): fields, poses, Animators' driven samples, cameras on the game views' stacks, and
// entities that live only while the override does. They are in the session, and they end with it.
//
// An override keeps what its last frame writes. lay_overrides writes it over the world, and saves the values that it
// writes over first; lift_overrides puts the saved values back. Whatever reads or edits the document in the world
// (the editor's operations and loads, the edit-mode behaviours, and what the game sends the editor) does so while the
// overrides are lifted, so an edit of a field that an override holds goes to the document's value, under the override.
// Camera pushes, drives and spawned entities are not lifted: they stay from frame to frame, so no view cuts again and
// no drive starts again.
MAX_OVERRIDES :: 16

#assert(len(link.Override_Animator{}.samples) == anim.MAX_DRIVEN)

// Layer is whether the overrides are on the world. Only lift_overrides and lay_overrides change it.
Layer :: enum u8 {
	Lifted,
	Laid,
}

Overrides :: struct {
	// The live overrides, in the order that they began, in the host's heap. A later one lays over an earlier one.
	live:          [dynamic]Override,
	// The highest number that the editor began an override with in the session. A Begin_Override with one no higher is
	// late, and is dropped.
	last:          u64,
	layer:         Layer,
	// The hash of the Overridden_Entities that the editor last got, 0 for none.
	entities_sent: u64,
}

// Override is one override's last frame, resolved to the world's entities, and what it holds of the world.
@(private)
Override :: struct {
	id:        u64,
	fields:    [dynamic]Field_Write,
	poses:     [dynamic]Pose_Write,
	animators: [dynamic]Animator_Write,
	pushes:    [dynamic]Push,
	spawned:   [dynamic]Spawned,
	// The values that the layer wrote over, in the order that it wrote them, while it is laid.
	saved:     [dynamic]Saved,
}

@(private)
Field_Write :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	hash:      u64,
	place:     scene.Field_Place,
	bytes:     [scene.MAX_FIELD_SIZE]u8,
}

@(private)
Pose_Write :: struct {
	entity:   ecs.Entity,
	position: [3]i64,
	rotation: quaternion128,
	scale:    [3]f32,
}

// Animator_Write is an Animator's driven samples, and the drive that holds it, which stays from frame to frame.
@(private)
Animator_Write :: struct {
	entity:  ecs.Entity,
	hold:    bool,
	samples: [anim.MAX_DRIVEN]anim.Driven_Sample,
	token:   anim.Drive_Token,
}

// Push is a camera on a view's stack, and its token, which stays from frame to frame.
@(private)
Push :: struct {
	view:     int,
	entity:   ecs.Entity,
	priority: i32,
	token:    camera.Camera_Token,
}

@(private)
Spawned :: struct {
	key:  u64,
	root: ecs.Entity,
}

@(private)
Saved :: struct {
	entity:    ecs.Entity,
	component: ecs.Component_Id,
	hash:      u64,
	place:     scene.Field_Place,
	bytes:     [scene.MAX_FIELD_SIZE]u8,
}

// begin_override starts the override with the number, or tells the editor why it cannot.
@(private)
begin_override :: proc(e: ^Editor, id: u64) {
	o := &e.session.overrides
	if id <= o.last {
		return
	}
	o.last = id
	_, mirrors := e.session.mirror.?
	switch {
	case mode_of(e.session.mode) != .Edit || !mirrors:
		send_override_ended(e, id, .Not_Editing)
	case len(o.live) >= MAX_OVERRIDES:
		send_override_ended(e, id, .Full)
	case:
		heap := e.platform.heap_allocator
		append(
			&o.live,
			Override {
				id = id,
				fields = make([dynamic]Field_Write, heap),
				poses = make([dynamic]Pose_Write, heap),
				animators = make([dynamic]Animator_Write, heap),
				pushes = make([dynamic]Push, heap),
				spawned = make([dynamic]Spawned, heap),
				saved = make([dynamic]Saved, heap),
			},
		)
	}
}

// write_override takes an override's frame in place of its last, while the overrides are lifted. It spawns the
// frame's new keys and despawns the keys that it does not have, ends the drives and pops the cameras that it does not
// have, and gives whether it despawned. A frame for an override that is not live is dropped.
@(private)
write_override :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	frame: link.Override_Frame,
) -> (
	despawned: bool,
) {
	assert(e.session.overrides.layer == .Lifted)
	o := find_override(e, frame.override) or_return
	despawned = spawn_keys(e, w, scripts, o, frame.spawns)
	write_fields_and_poses(e, w, o, frame.fields, frame.transforms)
	write_animators(e, w, o, frame.animators)
	write_cameras(e, w, o, frame.cameras)
	return
}

// write_fields_and_poses resolves a frame's fields and poses to the world's entities, in place of the last ones.
@(private)
write_fields_and_poses :: proc(
	e: ^Editor,
	w: ^ecs.World,
	o: ^Override,
	fields: []link.Override_Field,
	transforms: []link.Override_Transform,
) {
	clear(&o.fields)
	for f in fields {
		entity := override_target(e, w, o, f.target) or_continue
		name := fmt.aprintf("%016x", f.field, allocator = e.platform.frame_allocator)
		handles := scene.handles_of(e.scenes, f.target.scene)
		place, bytes, ok := scene.field_bytes(
			w,
			f.target.entity,
			ecs.Component_Id(f.component),
			{name = name, hash = f.field, value = scene_value_of(f.value)},
			handles,
		)
		if ok {
			append(
				&o.fields,
				Field_Write{entity, ecs.Component_Id(f.component), f.field, place, bytes},
			)
		}
	}
	clear(&o.poses)
	for t in transforms {
		entity := override_target(e, w, o, t.target) or_continue
		r := t.rotation
		append(
			&o.poses,
			Pose_Write {
				entity = entity,
				position = t.position,
				rotation = quaternion(x = r[0], y = r[1], z = r[2], w = r[3]),
				scale = t.scale,
			},
		)
	}
}

// release_override ends an override that the editor released, and gives whether it despawned.
@(private)
release_override :: proc(e: ^Editor, w: ^ecs.World, id: u64) -> (despawned: bool) {
	for o, i in e.session.overrides.live {
		if o.id == id {
			lift_overrides(e, w)
			return end_override(e, w, i, nil)
		}
	}
	return false
}

// end_overrides ends every override, with the world as the document has it, and tells the editor why, unless reason
// is nil, as when the editor has gone. It gives whether it despawned. A code reload calls it after the new
// registrations, so the saved values find their components.
end_overrides :: proc(
	e: ^Editor,
	w: ^ecs.World,
	reason: Maybe(link.Override_End_Reason),
) -> (
	despawned: bool,
) {
	lift_overrides(e, w)
	for len(e.session.overrides.live) > 0 {
		if end_override(e, w, len(e.session.overrides.live) - 1, reason) {
			despawned = true
		}
	}
	// The cutscene preview lays with the overrides, and ends with them.
	preview_reason: Maybe(link.Cutscene_Preview_End_Reason)
	if r, ended := reason.?; ended {
		switch r {
		case .Mode:
			preview_reason = .Mode
		case .Scene_Loaded:
			preview_reason = .Scene_Loaded
		case .Code_Reloaded:
			preview_reason = .Code_Reloaded
		case .Not_Editing, .Full:
			preview_reason = .Not_Editing
		}
	}
	if end_cutscene_preview(e, w, preview_reason) {
		despawned = true
	}
	return
}

// lift_overrides puts back the values that the cutscene preview and then the overrides wrote over, the last written
// first, and gives whether it changed the world. Transforms then need propagating again.
lift_overrides :: proc(e: ^Editor, w: ^ecs.World) -> (lifted: bool) {
	o := &e.session.overrides
	if o.layer == .Lifted {
		return false
	}
	o.layer = .Lifted
	lifted = lift_cutscene_preview(e, w)
	#reverse for &override in o.live {
		if lift_saved(w, &override) {
			lifted = true
		}
	}
	return
}

// lift_saved puts back the values that a layer wrote over, the last written first, and forgets them. It gives whether
// it changed the world.
@(private)
lift_saved :: proc(w: ^ecs.World, o: ^Override) -> (lifted: bool) {
	#reverse for s in o.saved {
		data := ecs.get_raw(w, s.entity, s.component)
		if data == nil {
			continue
		}
		bytes := s.bytes
		copy(([^]u8)(data)[s.place.offset:][:s.place.size], bytes[:s.place.size])
		ecs.mark_changed(w, s.entity, s.component)
		if s.component == ecs.TRANSFORM_ID {
			ecs.teleport(w, s.entity, ecs.get(w, s.entity, ecs.Transform)^)
		}
		lifted = true
	}
	clear(&o.saved)
	return
}

// lay_overrides writes the overrides' last frames over the world, the first begun first, and then evaluates the
// cutscene preview over them, and gives whether it changed the world. Transforms then need propagating again. It skips an entity that is gone, starts a drive again for an
// Animator that lost its drive, and pushes a camera again whose entry went.
lay_overrides :: proc(e: ^Editor, w: ^ecs.World) -> (laid: bool) {
	o := &e.session.overrides
	if o.layer == .Laid {
		return false
	}
	o.layer = .Laid
	for &override in o.live {
		if lay_fields_and_poses(w, &override) {
			laid = true
		}
		for &a in override.animators {
			if e.animation == nil || !ecs.is_alive(w, a.entity) {
				continue
			}
			if !anim.is_driving(w, a.token) {
				a.token, _ = anim.begin_drive(e.animation, w, a.entity, a.hold)
			}
			anim.drive(w, a.token, a.samples[:])
		}
		for &p in override.pushes {
			if e.views != nil && !camera.is_pushed(e.views, p.token) && ecs.is_alive(w, p.entity) {
				p.token, _ = camera.push(e.views, w, p.view, p.entity, p.priority)
			}
		}
	}
	if lay_cutscene_preview(e, w) {
		laid = true
	}
	return
}

// lay_fields_and_poses writes a layer's fields and poses over the world, and gives whether it changed the world.
@(private)
lay_fields_and_poses :: proc(w: ^ecs.World, o: ^Override) -> (laid: bool) {
	for &f in o.fields {
		if hold(w, o, f.entity, f.component, f.hash, f.place, f.bytes[:f.place.size]) {
			laid = true
		}
	}
	for p in o.poses {
		if lay_pose(w, o, p) {
			laid = true
		}
	}
	return
}

// hold writes a field's bytes over an entity's component, and saves what it writes over, once for each override.
@(private)
hold :: proc(
	w: ^ecs.World,
	o: ^Override,
	entity: ecs.Entity,
	component: ecs.Component_Id,
	field_hash: u64,
	place: scene.Field_Place,
	bytes: []u8,
) -> bool {
	data := ecs.get_raw(w, entity, component)
	if data == nil {
		return false
	}
	dst := ([^]u8)(data)[place.offset:][:place.size]
	saved := false
	for s in o.saved {
		if s.entity == entity && s.component == component && s.hash == field_hash {
			saved = true
			break
		}
	}
	if !saved {
		s := Saved{entity, component, field_hash, place, {}}
		copy(s.bytes[:], dst)
		append(&o.saved, s)
	}
	copy(dst, bytes)
	ecs.mark_changed(w, entity, component)
	return true
}

// lay_pose writes a pose: a root's Transform, without interpolation, or a child's Local_Transform.
@(private)
lay_pose :: proc(w: ^ecs.World, o: ^Override, p: Pose_Write) -> bool {
	if !ecs.is_alive(w, p.entity) {
		return false
	}
	rotation, scale := p.rotation, p.scale
	if is_child(w, p.entity) {
		offset := ecs.position_sub({raw = p.position}, {})
		hold_named(w, o, p.entity, ecs.LOCAL_TRANSFORM_ID, "offset", &offset) or_return
		hold_named(w, o, p.entity, ecs.LOCAL_TRANSFORM_ID, "rotation", &rotation) or_return
		hold_named(w, o, p.entity, ecs.LOCAL_TRANSFORM_ID, "scale", &scale) or_return
		return true
	}
	world_position := ecs.World_Position {
		raw = p.position,
	}
	hold_named(w, o, p.entity, ecs.TRANSFORM_ID, "position", &world_position) or_return
	hold_named(w, o, p.entity, ecs.TRANSFORM_ID, "rotation", &rotation) or_return
	hold_named(w, o, p.entity, ecs.TRANSFORM_ID, "scale", &scale) or_return
	return ecs.teleport(w, p.entity, ecs.get(w, p.entity, ecs.Transform)^)
}

@(private)
hold_named :: proc(
	w: ^ecs.World,
	o: ^Override,
	entity: ecs.Entity,
	component: ecs.Component_Id,
	name: string,
	value: rawptr,
) -> bool {
	field_hash := format.scene_field_hash(name)
	place := scene.field_place(w, component, field_hash) or_return
	return hold(w, o, entity, component, field_hash, place, ([^]u8)(value)[:place.size])
}

// end_override ends a live override while the overrides are lifted: its drives, its cameras and its spawned entities.
// With a reason, it tells the editor why. It gives whether it despawned.
@(private)
end_override :: proc(
	e: ^Editor,
	w: ^ecs.World,
	index: int,
	reason: Maybe(link.Override_End_Reason),
) -> (
	despawned: bool,
) {
	assert(e.session.overrides.layer == .Lifted)
	o := &e.session.overrides.live[index]
	for a in o.animators {
		anim.end_drive(w, a.token)
	}
	if e.views != nil {
		for p in o.pushes {
			camera.pop(e.views, p.token)
		}
	}
	for s in o.spawned {
		if ecs.is_alive(w, s.root) && ecs.despawn(w, s.root) {
			despawned = true
		}
	}
	if r, ended := reason.?; ended {
		send_override_ended(e, o.id, r)
	}
	free_override(o)
	ordered_remove(&e.session.overrides.live, index)
	return
}

@(private)
free_override :: proc(o: ^Override) {
	delete(o.fields)
	delete(o.poses)
	delete(o.animators)
	delete(o.pushes)
	delete(o.spawned)
	delete(o.saved)
}

// free_overrides frees the overrides without touching the world, which a new game state does not have.
@(private)
free_overrides :: proc(o: ^Overrides) {
	for &override in o.live {
		free_override(&override)
	}
	delete(o.live)
}

@(private)
send_override_ended :: proc(e: ^Editor, id: u64, reason: link.Override_End_Reason) {
	link.write_message(&e.session.outbox, link.Override_Ended{override = id, reason = reason})
}

@(private)
find_override :: proc(e: ^Editor, id: u64) -> (^Override, bool) {
	for &o in e.session.overrides.live {
		if o.id == id {
			return &o, true
		}
	}
	return nil, false
}

// override_target is the entity that a target names: a document's entity, or one that the override spawned.
@(private)
override_target :: proc(
	e: ^Editor,
	w: ^ecs.World,
	o: ^Override,
	target: link.Override_Target,
) -> (
	ecs.Entity,
	bool,
) {
	switch target.kind {
	case .Scene_Entity:
		if !scene.has_maps(e.scenes) {
			scene.index(e.scenes, w)
		}
		if entity := scene.find(e.scenes, w, target.scene, target.entity); entity != 0 {
			return entity, true
		}
	case .Spawned:
		for s in o.spawned {
			if s.key == target.entity && ecs.is_alive(w, s.root) {
				return s.root, true
			}
		}
	case .Binding:
		// Only the cutscene preview's values name a binding, and they resolve it on each lay (see
		// write_preview_values).
		log.warnf(
			"editor: override %d names binding %d, which only the cutscene preview's values can",
			o.id,
			target.entity,
		)
		return 0, false
	}
	log.warnf("editor: override %d writes %v, which the world does not have", o.id, target)
	return 0, false
}

// spawn_keys spawns the keys that a frame has and the override does not, and despawns the ones that it does not have.
@(private)
spawn_keys :: proc(
	e: ^Editor,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	o: ^Override,
	spawns: []link.Override_Spawn,
) -> (
	despawned: bool,
) {
	for i := 0; i < len(o.spawned); {
		s := o.spawned[i]
		found := false
		for spawn in spawns {
			if spawn.key == s.key {
				found = true
				break
			}
		}
		if found {
			i += 1
			continue
		}
		if ecs.is_alive(w, s.root) && ecs.despawn(w, s.root) {
			despawned = true
		}
		ordered_remove(&o.spawned, i)
	}
	next: for spawn in spawns {
		for s in o.spawned {
			if s.key == spawn.key {
				continue next
			}
		}
		if e.assets == nil {
			log.warnf("editor: override %d cannot spawn without the game's assets", o.id)
			continue
		}
		r := spawn.rotation
		pose := ecs.Transform {
			position = {raw = spawn.position},
			rotation = quaternion(x = r[0], y = r[1], z = r[2], w = r[3]),
			scale = spawn.scale,
		}
		root, ok := scene.spawn_prefab(w, scripts, e.assets, format.Guid(spawn.prefab), pose)
		if !ok {
			log.warnf(
				"editor: override %d cannot spawn the prefab %v",
				o.id,
				format.Guid(spawn.prefab),
			)
			continue
		}
		append(&o.spawned, Spawned{spawn.key, root})
	}
	return
}

// write_animators keeps the drives of the Animators that a frame still drives, as they were, and ends the others.
@(private)
write_animators :: proc(
	e: ^Editor,
	w: ^ecs.World,
	o: ^Override,
	animators: []link.Override_Animator,
) {
	if len(animators) > 0 && e.animation == nil {
		log.warnf(
			"editor: override %d drives Animators, which the game does not give the editor",
			o.id,
		)
	}
	kept := make([dynamic]Animator_Write, 0, len(animators), e.platform.heap_allocator)
	for a in animators {
		entity := override_target(e, w, o, a.target) or_continue
		write := Animator_Write {
			entity = entity,
			hold   = a.hold,
		}
		for sample, i in a.samples {
			write.samples[i] = {
				clip        = format.Guid(sample.clip),
				time        = sample.time,
				weight      = sample.weight,
				root_motion = .Reported if sample.root_motion else .In_Place,
			}
		}
		for &old in o.animators {
			if old.entity == entity && old.hold == a.hold {
				write.token = old.token
				old.token = {}
			}
		}
		append(&kept, write)
	}
	for old in o.animators {
		anim.end_drive(w, old.token)
	}
	delete(o.animators)
	o.animators = kept
}

// write_cameras keeps the pushes that a frame still has, as they were, and pops the others.
@(private)
write_cameras :: proc(e: ^Editor, w: ^ecs.World, o: ^Override, cameras: []link.Override_Camera) {
	if len(cameras) > 0 && e.views == nil {
		log.warnf(
			"editor: override %d pushes cameras, which the game does not give the editor",
			o.id,
		)
	}
	kept := make([dynamic]Push, 0, len(cameras), e.platform.heap_allocator)
	for c in cameras {
		entity := override_target(e, w, o, c.target) or_continue
		push := Push {
			view     = int(c.view),
			entity   = entity,
			priority = c.priority,
		}
		for &old in o.pushes {
			if old.view == push.view && old.entity == entity && old.priority == c.priority {
				push.token = old.token
				old.token = {}
			}
		}
		append(&kept, push)
	}
	if e.views != nil {
		for old in o.pushes {
			if old.token != {} {
				camera.pop(e.views, old.token)
			}
		}
	}
	delete(o.pushes)
	o.pushes = kept
}

// held_fields is the fields of an entity that overrides hold, as the editor names them.
@(private)
held_fields :: proc(
	e: ^Editor,
	w: ^ecs.World,
	entity: ecs.Entity,
	allocator := context.allocator,
) -> []link.Held_Field {
	held := make([dynamic]link.Held_Field, allocator)
	for &o in e.session.overrides.live {
		add_held_fields(w, &o, entity, &held)
	}
	preview_held_fields(e, w, entity, &held)
	return held[:]
}

// add_held_fields adds the fields of an entity that a layer's fields and poses hold.
@(private)
add_held_fields :: proc(
	w: ^ecs.World,
	o: ^Override,
	entity: ecs.Entity,
	held: ^[dynamic]link.Held_Field,
) {
	add :: proc(held: ^[dynamic]link.Held_Field, field: link.Held_Field) {
		if !slice.contains(held[:], field) {
			append(held, field)
		}
	}
	for f in o.fields {
		if f.entity == entity {
			add(held, {u64(f.component), f.hash})
		}
	}
	for p in o.poses {
		if p.entity != entity {
			continue
		}
		if is_child(w, entity) {
			for name in ([]string{"offset", "rotation", "scale"}) {
				add(held, {u64(ecs.LOCAL_TRANSFORM_ID), format.scene_field_hash(name)})
			}
		} else {
			for name in ([]string{"position", "rotation", "scale"}) {
				add(held, {u64(ecs.TRANSFORM_ID), format.scene_field_hash(name)})
			}
		}
	}
}

// Shown is what the world showed of the watched entities that overrides or the cutscene preview hold, before a poll
// lifted them, in frame memory (see link.Entity_Values.shown).
@(private)
Shown :: struct {
	entities: []Shown_Entity,
	preview:  link.Shown_Preview,
}

@(private)
Shown_Entity :: struct {
	entity: ecs.Entity,
	values: []link.Component_Value,
}

// capture_shown copies each component of each watched entity with a held field, as the world shows it now. Call it
// while the overrides are laid, before the poll lifts them, so the editor can key what the preview shows.
@(private)
capture_shown :: proc(
	e: ^Editor,
	w: ^ecs.World,
	allocator := context.allocator,
) -> (
	shown: Shown,
) {
	if e.session.overrides.layer != .Laid {
		return
	}
	if p, open := &e.session.cutscene_previews.open.?; open {
		shown.preview = {
			ticket = p.ticket,
			tick   = p.live.evaluation.time,
			blob   = p.modified if p.unsaved else 0,
			values = preview_values_serial(p),
		}
	}
	entities := make([dynamic]Shown_Entity, allocator)
	for watched in e.session.watched {
		if !ecs.is_alive(w, watched.entity) ||
		   len(held_fields(e, w, watched.entity, allocator)) == 0 {
			continue
		}
		append(
			&entities,
			Shown_Entity{watched.entity, component_values(w, watched.entity, allocator)},
		)
	}
	shown.entities = entities[:]
	return
}

// component_values copies each component of an entity, as it is in memory.
@(private)
component_values :: proc(
	w: ^ecs.World,
	entity: ecs.Entity,
	allocator := context.allocator,
) -> []link.Component_Value {
	components := ecs.entity_components(w, entity)
	values := make([]link.Component_Value, len(components), allocator)
	for id, j in components {
		values[j].id = u64(id)
		info := ecs.registry_find(&w.registry, id)
		data := ecs.get_raw(w, entity, id)
		if info != nil && data != nil {
			values[j].data = slice.clone(([^]u8)(data)[:info.size], allocator)
		}
	}
	return values
}

// send_overridden_entities tells the editor which entities the overrides and the cutscene preview write or spawned,
// when that changes.
@(private)
send_overridden_entities :: proc(
	e: ^Editor,
	w: ^ecs.World,
	out: ^[dynamic]byte,
	allocator := context.allocator,
) {
	entities := make([dynamic]u64, allocator)
	add :: proc(entities: ^[dynamic]u64, entity: ecs.Entity) {
		if !slice.contains(entities[:], u64(entity)) {
			append(entities, u64(entity))
		}
	}
	for &o in e.session.overrides.live {
		for f in o.fields {add(&entities, f.entity)}
		for p in o.poses {add(&entities, p.entity)}
		for a in o.animators {add(&entities, a.entity)}
		for p in o.pushes {add(&entities, p.entity)}
		for s in o.spawned {add(&entities, s.root)}
	}
	preview_entities(e, w, &entities)
	slice.sort(entities[:])
	h: u64 = 0
	if len(entities) > 0 {
		h = max(hash.fnv64a(slice.to_bytes(entities[:])), 1)
	}
	if h != e.session.overrides.entities_sent {
		e.session.overrides.entities_sent = h
		link.write_message(out, link.Overridden_Entities{entities = entities[:]})
	}
}

@(private)
scene_value_of :: proc(v: link.Scene_Value) -> format.Scene_Value {
	return {
		kind = format.Scene_Value_Kind(v.kind),
		count = v.count,
		integer = v.integer,
		ints = v.ints,
		floats = v.floats,
		text = v.text,
		entity = v.entity,
		scene = format.Guid(v.scene),
		asset = format.Guid(v.asset),
	}
}
