// Package cutscene plays cutscenes: the entities that a cutscene acts on, its player, its evaluation and its tracks
// (see docs/cinematics/README.md).
package cutscene

import "core:log"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

// LOADING_SCENE is the scene number of the Loading tag on a spawned binding's entities. No scene has it, so a
// cutscene's entities never hold back a scene's load (see docs/cinematics/bindings.md#spawned-bindings).
LOADING_SCENE :: max(u32)

// Binding_State is where one binding is (see docs/cinematics/bindings.md#the-states). nil is a binding that is not
// resolved yet. Change it only with set_binding.
Binding_State :: union {
	Binding_Possessed,
	Binding_Spawned,
	Binding_Missing,
	Binding_Mapped,
}

// Binding_Possessed is an entity that the cutscene does not own: a scene's entity, or an override's. The binding
// suspends hold's systems on it.
Binding_Possessed :: struct {
	entity: ecs.Entity,
	hold:   Binding_Hold,
}

// Binding_Spawned is the root of a prefab instance that the cutscene spawned and owns. release_bindings despawns it. The
// binding suspends hold's systems on it from the moment that it spawns.
Binding_Spawned :: struct {
	entity: ecs.Entity,
	hold:   Binding_Hold,
}

// Binding_Hold is what a binding suspends on its entity while it is in its state (see
// docs/cinematics/possession.md): set_binding suspends the systems when the binding enters the state, and resumes them
// when it leaves.
Binding_Hold :: struct {
	systems:       ecs.Suspend_Set,
	// A body that the suspension made kinematic keeps its last velocity when it is dynamic again, instead of none.
	keep_velocity: bool,
}

// Binding_Missing is an optional binding whose entity was not found. Its tracks do nothing.
Binding_Missing :: struct {}

// Binding_Mapped is a binding of a sub-sequence that its section gives to a binding of the parent, by the parent's index
// (see docs/cinematics/tracks.md#sub-sequence-tracks). Its entity is the parent binding's, which tree_binding finds, and
// it suspends nothing: the parent's binding holds the entity.
Binding_Mapped :: struct {
	parent: u32,
}

// Bindings is the state of each binding of one cutscene, in the order of the blob's bindings. It uses the heap.
Bindings :: struct {
	states: [dynamic]Binding_State,
}

// Binding_Id is a binding's ID in its cutscene.
Binding_Id :: distinct u32

// Binding_Key names a binding by its ID or by its name.
Binding_Key :: union {
	Binding_Id,
	string,
}

// Binding_Override is an entity that a caller gives for a binding when it plays the cutscene. It wins over the asset's
// reference.
Binding_Override :: struct {
	binding: Binding_Key,
	entity:  ecs.Entity,
}

Binding_Failure_Reason :: enum u8 {
	// A required possessed binding's entity is not in a ready scene, and no override gave one.
	Missing,
	// A spawned binding's prefab did not spawn.
	Spawn_Failed,
}

// Binding_Failure is why resolve_bindings failed: the binding, by its index in the blob, and the reason, and for a
// binding of a sub-sequence, its cutscene, which is zero for the player's own. It holds no strings, so a player can keep
// it across a code reload.
Binding_Failure :: struct {
	index:    int,
	reason:   Binding_Failure_Reason,
	cutscene: format.Guid,
}

// Resolve is what resolve_bindings needs: the world, its scenes, the scripts that a prefab's behaviours attach to (or
// nil), the assets that prefabs load from, and the cutscene's blob. For a sub-sequence, mapped has, for each binding,
// the parent's binding that its section maps it to, or nil. With unheld, the bindings suspend nothing on their
// entities, for the editor's preview, where no system runs (see docs/editor/cutscene-editor.md#preview).
Resolve :: struct {
	world:   ^ecs.World,
	scenes:  ^scene.Scenes,
	scripts: ^script.Runtime,
	assets:  ^asset.Assets,
	data:    []byte,
	blob:    ^format.Cutscene_Blob,
	mapped:  []Maybe(Mapping),
	unheld:  bool,
}

// Mapping is a parent's binding that a sub-sequence's binding is mapped to: its index in the parent's blob, and its
// entity when the sub-sequence resolves, which a spawned binding under the mapped one spawns under. 0 for a parent's
// binding that is missing.
Mapping :: struct {
	parent: u32,
	entity: ecs.Entity,
}

// binding_index is the index of the binding with an ID or a name, and false when the cutscene has none.
binding_index :: proc(data: []byte, blob: ^format.Cutscene_Blob, key: Binding_Key) -> (int, bool) {
	bindings := format.cutscene_bindings(data, blob)
	switch k in key {
	case Binding_Id:
		for b, i in bindings {
			if b.id == u32(k) {
				return i, true
			}
		}
	case string:
		hash := format.animation_graph_hash(k)
		for b, i in bindings {
			if b.name_hash == hash && format.blob_string(data, b.name) == k {
				return i, true
			}
		}
	}
	return 0, false
}

// resolve_bindings finds or spawns the entity of each binding, once, in the blob's order (see
// docs/cinematics/bindings.md#resolving). An override wins over the asset's reference. A possessed binding finds its
// entity in the first ready scene with its GUID. A spawned one spawns its prefab hidden by Loading until
// reveal_bindings, and the cutscene owns it. A missing optional binding warns and does nothing. A missing required
// binding, or a prefab that does not spawn, fails: what was spawned is despawned, and the failure names the binding. A
// binding that r.mapped maps is Binding_Mapped, and an override of it does nothing.
resolve_bindings :: proc(
	b: ^Bindings,
	r: Resolve,
	overrides: []Binding_Override = nil,
) -> (
	failure: Maybe(Binding_Failure),
) {
	w := r.world
	bindings := format.cutscene_bindings(r.data, r.blob)
	release_bindings(b, w)
	if b.states == nil {
		b.states = make([dynamic]Binding_State, w.platform.heap_allocator)
	}
	resize(&b.states, len(bindings))

	given := make([]ecs.Entity, len(bindings), w.platform.frame_allocator)
	for o in overrides {
		index, found := binding_index(r.data, r.blob, o.binding)
		if !found {
			log.warnf("cutscene: %s: no binding %v to override", source_of(r), o.binding)
			continue
		}
		given[index] = o.entity
	}

	for binding, index in bindings {
		if index < len(r.mapped) {
			if m, is_mapped := r.mapped[index].?; is_mapped {
				set_binding(b, w, index, Binding_Mapped{m.parent})
				continue
			}
		}
		hold := Binding_Hold{} if r.unheld else hold_of(binding)
		if entity := given[index]; entity != 0 {
			if ecs.is_alive(w, entity) {
				set_binding(b, w, index, Binding_Possessed{entity, hold})
				continue
			}
			log.warnf(
				"cutscene: %s: the override of the binding %q is not alive",
				source_of(r),
				name_of(r, index),
			)
		}
		switch binding.kind {
		case .Possessed:
			if entity := find_possessed(r, binding); entity != 0 {
				set_binding(b, w, index, Binding_Possessed{entity, hold})
			} else if binding.policy == .Optional {
				log.warnf(
					"cutscene: %s: the optional binding %q is missing, so its tracks do nothing",
					source_of(r),
					name_of(r, index),
				)
				set_binding(b, w, index, Binding_Missing{})
			} else {
				return fail(b, r, {index = index, reason = .Missing})
			}
		case .Spawned:
			root, ok := spawn(b, r, binding, index)
			if !ok {
				return fail(b, r, {index = index, reason = .Spawn_Failed})
			}
			set_binding(b, w, index, Binding_Spawned{root, hold})
		}
	}
	ecs.update_activity(w)
	return nil
}

// binding_entity is the entity of the binding at the index while it is alive. A binding that is missing, not
// resolved, or whose entity was despawned or went with its scene, gives false: its tracks do nothing.
binding_entity :: proc(b: ^Bindings, w: ^ecs.World, index: int) -> (ecs.Entity, bool) {
	if index < 0 || index >= len(b.states) {
		return 0, false
	}
	entity: ecs.Entity
	switch s in b.states[index] {
	case Binding_Possessed:
		entity = s.entity
	case Binding_Spawned:
		entity = s.entity
	case Binding_Missing, Binding_Mapped:
		return 0, false
	}
	if entity == 0 || !ecs.is_alive(w, entity) {
		return 0, false
	}
	return entity, true
}

// reveal_bindings shows the spawned bindings' entities: it removes their Loading, and settles their poses, so they do
// not interpolate from where they spawned. Their behaviours wake in the next script phase.
reveal_bindings :: proc(b: ^Bindings, w: ^ecs.World) {
	for state in b.states {
		if s, spawned := state.(Binding_Spawned); spawned {
			for e in instance_of(w, s.entity) {
				if loading := ecs.get(w, e, ecs.Loading);
				   loading != nil && loading.scene == LOADING_SCENE {
					ecs.remove(w, e, ecs.Loading)
				}
			}
		}
	}
	ecs.update_activity(w)
	for state in b.states {
		if s, spawned := state.(Binding_Spawned); spawned {
			for e in instance_of(w, s.entity) {
				if pose := ecs.get(w, e, ecs.Transform); pose != nil {
					ecs.teleport(w, e, pose^)
				}
			}
		}
	}
}

// conceal_bindings hides the spawned bindings' entities again with Loading, as they spawned, for a sub-sequence whose
// section no longer covers the time. Their behaviours sleep until reveal_bindings.
conceal_bindings :: proc(b: ^Bindings, w: ^ecs.World) {
	for state in b.states {
		if s, spawned := state.(Binding_Spawned); spawned {
			for e in instance_of(w, s.entity) {
				if !ecs.has(w, e, ecs.Loading) {
					ecs.add(w, e, ecs.Loading{LOADING_SCENE})
				}
			}
		}
	}
	ecs.update_activity(w)
}

// release_bindings forgets every binding, which resumes what each suspended, and then despawns the spawned bindings'
// entities, with their children. Possessed entities stay. It gives how many roots it despawned. Call the systems'
// forget_despawned after it, as after scene.unload_scene.
release_bindings :: proc(b: ^Bindings, w: ^ecs.World) -> int {
	roots := make([dynamic]ecs.Entity, 0, len(b.states), w.platform.frame_allocator)
	for state in b.states {
		if s, spawned := state.(Binding_Spawned); spawned {
			append(&roots, s.entity)
		}
	}
	for i in 0 ..< len(b.states) {
		set_binding(b, w, i, nil)
	}
	return ecs.despawn_many(w, roots[:])
}

// destroy_bindings releases the bindings, so no spawned entity outlives them, and frees the states.
destroy_bindings :: proc(b: ^Bindings, w: ^ecs.World) {
	release_bindings(b, w)
	delete(b.states)
	b.states = nil
}

// set_binding is the one writer of a binding's state. It resumes what the old state suspended on its entity, while the
// entity is alive, and suspends what the new state holds.
@(private = "file")
set_binding :: proc(b: ^Bindings, w: ^ecs.World, index: int, to: Binding_State) {
	entity, hold := held_by(b.states[index])
	resume_hold(w, entity, hold)
	b.states[index] = to
	entity, hold = held_by(to)
	ecs.suspend(w, entity, hold.systems, hold.keep_velocity)
}

// held_by is the entity of a binding's state and what the state suspends on it.
@(private = "file")
held_by :: proc(state: Binding_State) -> (ecs.Entity, Binding_Hold) {
	switch s in state {
	case Binding_Possessed:
		return s.entity, s.hold
	case Binding_Spawned:
		return s.entity, s.hold
	case Binding_Missing, Binding_Mapped:
	}
	return 0, {}
}

// resume_hold gives back what a binding suspended on its entity. A dynamic body that the suspension made kinematic is
// dynamic again at rest when the last holder resumes it, unless any of its holders asked to keep its velocity.
@(private = "file")
resume_hold :: proc(w: ^ecs.World, entity: ecs.Entity, hold: Binding_Hold) {
	ended, keep := ecs.resume(w, entity, hold.systems)
	if .Physics not_in ended || keep {
		return
	}
	if rb := ecs.get(w, entity, physics.Rigid_Body); rb == nil || rb.motion != .Dynamic {
		return
	}
	if pb := ecs.get_write(w, entity, physics.Physics_Body); pb != nil {
		pb.linear_velocity, pb.angular_velocity = 0, 0
	}
}

// SUSPEND_OF is the world's system for each system that a cutscene's binding names.
@(private = "file")
SUSPEND_OF := [format.Cutscene_Suspend]ecs.Suspend {
	.Behaviours = .Behaviours,
	.AI         = .AI,
	.Navigation = .Navigation,
	.Physics    = .Physics,
}

// hold_of is what a binding of the blob suspends on its entity.
@(private = "file")
hold_of :: proc(binding: format.Cutscene_Binding) -> (hold: Binding_Hold) {
	for system in binding.suspend {
		hold.systems += {SUSPEND_OF[system]}
	}
	hold.keep_velocity = .Keep_Velocity in binding.flags
	return
}

// fail undoes what resolve_bindings did, logs the failure, and gives it.
@(private = "file")
fail :: proc(b: ^Bindings, r: Resolve, failure: Binding_Failure) -> Binding_Failure {
	switch failure.reason {
	case .Missing:
		log.errorf(
			"cutscene: %s: the required binding %q is not in a ready scene",
			source_of(r),
			name_of(r, failure.index),
		)
	case .Spawn_Failed:
		log.errorf(
			"cutscene: %s: the binding %q did not spawn",
			source_of(r),
			name_of(r, failure.index),
		)
	}
	release_bindings(b, r.world)
	return failure
}

// find_possessed is a possessed binding's entity in the first ready scene with its GUID, or 0.
@(private = "file")
find_possessed :: proc(r: Resolve, binding: format.Cutscene_Binding) -> ecs.Entity {
	number, ready := scene.ready_number(r.scenes, binding.asset)
	if !ready {
		return 0
	}
	return scene.find(r.scenes, r.world, number, binding.entity)
}

// spawn spawns a spawned binding's prefab with no owner, under its parent binding's entity when it has a live one, and
// hides every entity of the instance with Loading.
@(private = "file")
spawn :: proc(
	b: ^Bindings,
	r: Resolve,
	binding: format.Cutscene_Binding,
	index: int,
) -> (
	root: ecs.Entity,
	ok: bool,
) {
	w := r.world
	rotation := transmute(quaternion128)binding.rotation
	parent: ecs.Entity
	if binding.parent != format.CUTSCENE_NONE {
		parent, _ = binding_entity(b, w, int(binding.parent))
		if int(binding.parent) < len(r.mapped) {
			if m, is_mapped := r.mapped[binding.parent].?; is_mapped && ecs.is_alive(w, m.entity) {
				parent = m.entity
			}
		}
		if parent != 0 && !ecs.has(w, parent, ecs.Transform) {
			parent = 0
		}
		if parent == 0 {
			log.warnf(
				"cutscene: %s: the binding %q has no parent to spawn under, so it spawns at its position in the world",
				source_of(r),
				name_of(r, index),
			)
		}
	}
	meters := ecs.position_to_meters({raw = binding.position})
	local := ecs.Local_Transform {
		offset   = {f32(meters.x), f32(meters.y), f32(meters.z)},
		rotation = rotation,
		scale    = binding.scale,
	}
	pose := ecs.Transform {
		position = {raw = binding.position},
		rotation = rotation,
		scale = binding.scale,
	}
	if parent != 0 {
		pose = ecs.compose(ecs.get(w, parent, ecs.Transform)^, local)
	}
	root = scene.spawn_prefab(w, r.scripts, r.assets, binding.asset, pose) or_return
	if parent != 0 {
		ecs.add(w, root, local)
		ecs.add(w, root, ecs.Parent{parent})
	}
	for e in instance_of(w, root) {
		ecs.add(w, e, ecs.Loading{LOADING_SCENE})
	}
	return root, true
}

// instance_of is a root and its descendants, in frame memory.
@(private = "file")
instance_of :: proc(w: ^ecs.World, root: ecs.Entity) -> []ecs.Entity {
	found := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	if !ecs.is_alive(w, root) {
		return found[:]
	}
	append(&found, root)
	for i := 0; i < len(found); i += 1 {
		it := ecs.children_iter(w, found[i])
		for child in ecs.children_next(&it) {
			append(&found, child)
		}
	}
	return found[:]
}

@(private = "file")
source_of :: proc(r: Resolve) -> string {
	return format.blob_string(r.data, r.blob.source_path)
}

@(private = "file")
name_of :: proc(r: Resolve, index: int) -> string {
	return format.blob_string(r.data, format.cutscene_bindings(r.data, r.blob)[index].name)
}
