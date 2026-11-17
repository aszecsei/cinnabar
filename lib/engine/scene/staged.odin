package scene

import "core:log"
import "core:slice"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// SCENE_SPAWNS_PER_FRAME is how many entities advance_loads spawns in a frame, for all of the scenes that load.
SCENE_SPAWNS_PER_FRAME :: 1024
// SCENE_FILLS_PER_FRAME is how many entities advance_loads gives their components in a frame, for all of the scenes
// that load.
SCENE_FILLS_PER_FRAME :: 128

// Scene_Stage is where a scene is in its load (see docs/world/streaming.md#loading-in-stages). The stages come in order, and a
// scene's row has its stage's data: the blob and the entities live in the scene's memory, which goes with the scene.
// The zero value is no stage, and no row has it. Change it only with change_stage.
Scene_Stage :: union {
	Scene_Reading,
	Scene_Spawning,
	Scene_Filling,
	Scene_Settling,
	Scene_Ready,
}

// Scene_Reading is a scene whose blob the host is still reading.
Scene_Reading :: struct {
	read: asset.Blob_Read,
}

// Scene_Spawning is a scene that makes its entities, in blob order: next is the first that it has not made. spawned
// has an entity for each record, or 0 for one that was skipped.
Scene_Spawning :: struct {
	blob:    []byte,
	spawned: []ecs.Entity,
	next:    int,
}

// Scene_Filling is a scene whose entities all exist, and which gives them their components: next is the first that it
// has not given.
Scene_Filling :: struct {
	blob:    []byte,
	spawned: []ecs.Entity,
	next:    int,
}

// Scene_Settling is a scene that is complete and waits to be shown: for its bodies, then it takes Loading from its
// entities.
Scene_Settling :: struct {
	blob:    []byte,
	spawned: []ecs.Entity,
}

// Scene_Ready is a scene that is in the world and shown, as every scene is that add_scene added.
Scene_Ready :: struct {}

Scene_Stage_Kind :: enum u8 {
	Reading,
	Spawning,
	Filling,
	Settling,
	Ready,
}

// Load_Budget is how much work advance_loads does in a frame, in entities.
Load_Budget :: struct {
	spawns: int,
	fills:  int,
}

// Load_Work is how much work advance_loads did.
Load_Work :: struct {
	spawned: int,
	filled:  int,
}

// stage_of is the stage of the loaded scene with the number, or false if it is not loaded.
stage_of :: proc(s: ^Scenes, number: u32) -> (kind: Scene_Stage_Kind, ok: bool) {
	index := find_loaded(s, number) or_return
	return stage_kind(s.loaded[index].stage)
}

@(private = "file")
stage_kind :: proc(stage: Scene_Stage) -> (kind: Scene_Stage_Kind, ok: bool) {
	switch _ in stage {
	case Scene_Reading:
		return .Reading, true
	case Scene_Spawning:
		return .Spawning, true
	case Scene_Filling:
		return .Filling, true
	case Scene_Settling:
		return .Settling, true
	case Scene_Ready:
		return .Ready, true
	}
	return {}, false
}

// change_stage is the one writer of a scene's stage. A row starts in Reading or in Ready, and then goes to the next
// stage in order. It gives false, and changes nothing, for any other change.
@(private)
change_stage :: proc(loaded: ^Loaded_Scene, to: Scene_Stage) -> bool {
	from, has_from := stage_kind(loaded.stage)
	target, has_target := stage_kind(to)
	allowed := has_target
	if has_from {
		allowed &&= from != .Ready && target == Scene_Stage_Kind(int(from) + 1)
	} else {
		allowed &&= target == .Reading || target == .Ready
	}
	if !allowed {
		log.errorf(
			"scene: the scene %d cannot go from the stage %v to %v",
			loaded.number,
			from,
			target,
		)
		return false
	}
	loaded.stage = to
	return true
}

// end_read ends the read of a scene that is still reading, so the host stops it. Ending it again does nothing.
@(private)
end_read :: proc(s: ^Scenes, loaded: ^Loaded_Scene) {
	if reading, is_reading := &loaded.stage.(Scene_Reading); is_reading && s.assets != nil {
		asset.blob_read_end(s.assets, &reading.read)
	}
}

// begin_load adds a scene to the table that loads in stages, and gives its number as add_scene does: number, or with
// none, the next of the game's own. It refuses a number that is loaded, a scene when core.MAX_SCENE_MEMORY scenes are
// loaded, and a scene whose blob cannot be read, and gives false. advance_loads does the rest, a few entities each
// frame, and the scene's entities stay hidden until it is ready (see docs/world/streaming.md#loading-in-stages). Call it between
// frames, outside the script phase.
begin_load :: proc(
	w: ^ecs.World,
	s: ^Scenes,
	guid: format.Guid,
	number: Maybe(u32) = nil,
) -> (
	added: u32,
	ok: bool,
) {
	follow_level(s)
	if s.assets == nil {
		log.error("scene: there are no assets to load a scene from")
		return 0, false
	}
	if is_loaded(s, number.? or_else s.next) {
		log.warnf(
			"scene: the scene %d is loaded, so it is not loaded again",
			number.? or_else s.next,
		)
		return 0, false
	}
	// A streaming chunk's bundle in a release, which stays open until the scene unloads.
	bundle := asset.hold_bundle(s.assets, guid)
	read := asset.blob_read_begin(s.assets, guid)
	if _, failed := read.(asset.Blob_Read_Failed); failed {
		buffer: [32]u8
		log.errorf("scene: cannot begin to read the scene %s", format.guid_format(guid, &buffer))
		asset.release_bundle(s.assets, &bundle)
		return 0, false
	}
	if added, ok = append_scene(s, guid, number, Scene_Reading{read = read}, bundle); !ok {
		asset.blob_read_end(s.assets, &read)
		asset.release_bundle(s.assets, &bundle)
		return 0, false
	}
	if w.scene == {} {
		w.scene = guid
	}
	return added, true
}

@(private = "file")
Load_Step :: enum u8 {
	Waiting,
	Ready,
	Failed,
}

// advance_loads moves the scenes that load one step on, within the budget that all of them share: the scenes of order
// first, in that order, then the others. It gives the scenes that became ready, and the scenes that failed, which it
// has unloaded, in frame memory, and the work that it did.
//
// A scene that is reading polls its read. One that is spawning makes its entities, with Loading, so they are hidden;
// one that is filling gives them their components, their parents and their Disabled. When a scene's entities are all
// complete it waits in Settling, and is ready when its number is not in bodies_pending: the scenes that still have
// bodies to make (see physics.loading_scenes). That is checked a call later at the soonest, so that the bodies' scenes
// are known. Then it takes Loading from its entities, settles them and attaches their behaviours. Call it between
// frames, outside the script phase.
advance_loads :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	order: []u32,
	budget: Load_Budget,
	bodies_pending: []u32,
) -> (
	ready: []u32,
	failed: []u32,
	work: Load_Work,
) {
	follow_level(s)
	frame := w.platform.frame_allocator
	ready_list := make([dynamic]u32, frame)
	failed_list := make([dynamic]u32, frame)
	numbers := make([dynamic]u32, frame)
	for number in order {
		if kind, found := stage_of(s, number); found && kind != .Ready {
			if !slice.contains(numbers[:], number) {
				append(&numbers, number)
			}
		}
	}
	for loaded in s.loaded {
		if kind, _ := stage_kind(loaded.stage); kind != .Ready {
			if !slice.contains(numbers[:], loaded.number) {
				append(&numbers, loaded.number)
			}
		}
	}
	remaining := budget
	for number in numbers {
		switch advance_scene(w, scripts, s, number, &remaining, &work, bodies_pending) {
		case .Waiting:
		case .Ready:
			append(&ready_list, number)
		case .Failed:
			append(&failed_list, number)
		}
	}
	return ready_list[:], failed_list[:], work
}

// fail_load unloads a scene that cannot load, with what it made.
@(private = "file")
fail_load :: proc(w: ^ecs.World, s: ^Scenes, number: u32, why: string) -> Load_Step {
	log.errorf("scene: the scene %d does not load: %s", number, why)
	unload_scene(w, s, number)
	return .Failed
}

// advance_scene takes one scene through as many stages as the budget allows. A scene that reaches Settling in this
// call stays there until the next.
@(private = "file")
advance_scene :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	number: u32,
	remaining: ^Load_Budget,
	work: ^Load_Work,
	bodies_pending: []u32,
) -> Load_Step {
	frame := w.platform.frame_allocator
	just_settled := false
	for {
		index, found := find_loaded(s, number)
		if !found {
			return .Failed
		}
		row := &s.loaded[index]
		switch &stage in row.stage {
		case Scene_Reading:
			data, state := asset.blob_read_poll(s.assets, &stage.read, allocator_of(s, number))
			switch state {
			case .Pending:
				return .Waiting
			case .Failed:
				return fail_load(w, s, number, "its blob cannot be read")
			case .Done:
			}
			view, valid := format.scene_view(data)
			if !valid {
				return fail_load(
					w,
					s,
					number,
					"it is not a scene blob of this build. Cook the content.",
				)
			}
			spawned := make([]ecs.Entity, len(view.entities), allocator_of(s, number))
			change_stage(row, Scene_Spawning{blob = data, spawned = spawned})
		case Scene_Spawning:
			view, _ := format.scene_view(stage.blob)
			count := min(len(view.entities) - stage.next, remaining.spawns)
			if count > 0 {
				l := loader(w, handles_of(s, number), nil)
				for i in stage.next ..< stage.next + count {
					e, read := format.scene_entity_read(stage.blob, view, i, frame)
					if !read {
						return fail_load(w, s, number, "an entity record is damaged")
					}
					entity := spawn_entity(&l, e, true, number)
					if entity != 0 {
						ecs.add(w, entity, ecs.Loading{number})
						stage.spawned[i] = entity
						work.spawned += 1
					}
				}
				stage.next += count
				remaining.spawns -= count
				// The new entities are hidden before anything else sees them.
				ecs.update_activity(w)
			}
			if stage.next < len(view.entities) {
				return .Waiting
			}
			change_stage(row, Scene_Filling{blob = stage.blob, spawned = stage.spawned})
		case Scene_Filling:
			view, _ := format.scene_view(stage.blob)
			count := min(len(view.entities) - stage.next, remaining.fills)
			if count > 0 {
				l := loader(w, handles_of(s, number), nil)
				for i in stage.next ..< stage.next + count {
					if stage.spawned[i] == 0 {
						continue
					}
					e, read := format.scene_entity_read(stage.blob, view, i, frame)
					if !read {
						return fail_load(w, s, number, "an entity record is damaged")
					}
					fill_entity(&l, stage.spawned[i], e)
					work.filled += 1
				}
				stage.next += count
				remaining.fills -= count
				ecs.update_activity(w)
			}
			if stage.next < len(view.entities) {
				return .Waiting
			}
			change_stage(row, Scene_Settling{blob = stage.blob, spawned = stage.spawned})
			just_settled = true
		case Scene_Settling:
			if just_settled || slice.contains(bodies_pending, number) {
				return .Waiting
			}
			reveal(w, scripts, s, number, stage)
			change_stage(row, Scene_Ready{})
			log.infof("scene: the scene %d is ready", number)
			return .Ready
		case Scene_Ready:
			return .Waiting
		case nil:
			return fail_load(w, s, number, "it has no stage")
		}
	}
}

// reveal takes Loading from a scene's entities, so they are shown, and settles them and attaches their behaviours as
// add_entities does.
@(private = "file")
reveal :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	number: u32,
	stage: Scene_Settling,
) {
	for entity in stage.spawned {
		if entity != 0 {
			ecs.remove(w, entity, ecs.Loading)
		}
	}
	ecs.update_activity(w)
	for entity in stage.spawned {
		if entity != 0 {
			settle(w, entity)
		}
	}
	if scripts == nil {
		return
	}
	view, _ := format.scene_view(stage.blob)
	l := loader(w, handles_of(s, number), nil)
	for entity, i in stage.spawned {
		if entity == 0 || view.entities[i].behaviours.size == 0 {
			continue
		}
		if e, read := format.scene_entity_read(stage.blob, view, i, w.platform.frame_allocator);
		   read {
			attach_behaviours(&l, scripts, nil, entity, e)
		}
	}
}
