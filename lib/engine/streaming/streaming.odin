// Package streaming is the policy that loads the scenes of a world near its streaming sources and unloads the far ones
// (see docs/world/streaming.md#the-policy). It decides which scenes load and unload, and the scene package does the loads,
// across frames and within a budget. It has no Game: the game gives it the sources' positions each frame.
package streaming

import "core:log"
import "core:math"
import "core:slice"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/scene"
import "cinnabar:engine/script"

WORLD_STREAMER_ID :: ecs.Component_Id(144)
STREAM_SOURCE_ID :: ecs.Component_Id(145)

// MAX_SCENE_LOADS is how many streamed scenes load at once: scenes that are not ready.
MAX_SCENE_LOADS :: 2
// MAX_STREAMED_SCENES is how many scenes the policy keeps loaded, which leaves some of core.MAX_SCENE_MEMORY for the
// scenes that scripts and the game load.
MAX_STREAMED_SCENES :: core.MAX_SCENE_MEMORY - 8

// World_Streamer selects the world that streams, and receives the streaming events as script events. Put it on an entity
// of a scene that stays loaded. When more than one has it, the first that the policy finds wins.
World_Streamer :: struct {
	world: format.Guid `asset:"world"`,
}

// Stream_Source marks an entity, beside the camera, that scenes load around: the player, for example. Its position is
// its Transform's.
Stream_Source :: struct {}

// register_components registers World_Streamer and Stream_Source. Call it with the engine's components, in init and
// on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, World_Streamer, WORLD_STREAMER_ID, category = "World")
	ecs.register_component(r, Stream_Source, STREAM_SOURCE_ID, category = "World")
}

// Slot_Out is a scene of the world that is not loaded. It is the zero value of Slot.
Slot_Out :: struct {}

// Slot_In is a scene that the policy began to load, by its number in the scenes. It is loading or ready.
Slot_In :: struct {
	number: u32,
}

// Slot_Failed is a scene that did not load, with the version of the world blob that named it. It is not tried again
// until the blob changes.
Slot_Failed :: struct {
	version: u32,
}

// Slot is where a scene of the world is. The slot of a record has the record's index. Change it only with change_slot.
Slot :: union #no_nil {
	Slot_Out,
	Slot_In,
	Slot_Failed,
}

// Stream_Event_Kind is what happened to a scene.
Stream_Event_Kind :: enum u8 {
	Loading,
	Ready,
	Unloaded,
	Failed,
}

// Stream_Event is something that happened to a scene in the last update. number is the scene's number in the scenes, or
// 0 for a scene that did not begin to load.
Stream_Event :: struct {
	kind:   Stream_Event_Kind,
	number: u32,
	scene:  format.Guid,
}

// Stats is the work of the last update.
Stats :: struct {
	scenes_loading:   int,
	entities_spawned: int,
	entities_filled:  int,
}

// World_Loaded is the world whose blob the state keeps loaded, and the version of the blob that the slots follow.
World_Loaded :: struct {
	guid:    format.Guid,
	handle:  asset.Handle,
	version: u32,
}

// World_Failed is a world whose blob does not load. It is tried again when the streamer names another.
World_Failed :: struct {
	guid: format.Guid,
}

World :: union {
	World_Loaded,
	World_Failed,
}

// State is the policy's memory: the world it follows, a slot for each of the world's scenes, and the events and stats of
// the last update. The lists use the heap. It lives beside the world, in Game, so it holds no procedure pointer.
State :: struct {
	platform:     ^core.Platform_API,
	assets:       ^asset.Assets,
	// The level generation that the state was made in (see follow_level).
	level:        u64,
	streamer:     ecs.Entity,
	// Whether the policy warned that more than one World_Streamer exists, until the streamer changes.
	extra_warned: bool,
	world:        World,
	slots:        [dynamic]Slot,
	events:       [dynamic]Stream_Event,
	stats:        Stats,
}

// init makes an empty state.
init :: proc(st: ^State, platform: ^core.Platform_API, assets: ^asset.Assets) {
	st^ = {
		platform = platform,
		assets   = assets,
		level    = platform.level_generation(),
		slots    = make([dynamic]Slot, platform.heap_allocator),
		events   = make([dynamic]Stream_Event, platform.heap_allocator),
	}
}

// reload takes the new DLL's platform after a code reload.
reload :: proc(st: ^State, platform: ^core.Platform_API) {
	st.platform = platform
}

// destroy lets the world's blob go and frees the lists. The scenes are the scenes' own to unload.
destroy :: proc(st: ^State) {
	release_world(st)
	delete(st.slots)
	delete(st.events)
	st^ = {}
}

// events are what happened to the scenes in the last update, in order. They are valid until the next update.
events :: proc(st: ^State) -> []Stream_Event {
	return st.events[:]
}

// stats is the work of the last update.
stats :: proc(st: ^State) -> Stats {
	return st.stats
}

// change_slot is the one writer of a slot. A scene goes out to in or failed, in to out or failed, and failed to out
// when the world's blob changes. It gives false, and changes nothing, for any other change.
@(private)
change_slot :: proc(st: ^State, index: int, to: Slot) -> bool {
	allowed := false
	switch _ in st.slots[index] {
	case Slot_Out:
		_, to_out := to.(Slot_Out)
		allowed = !to_out
	case Slot_In:
		_, to_in := to.(Slot_In)
		allowed = !to_in
	case Slot_Failed:
		_, to_out := to.(Slot_Out)
		allowed = to_out
	}
	if !allowed {
		log.errorf(
			"streaming: the scene %d cannot change to %v from %v",
			index,
			to,
			st.slots[index],
		)
		return false
	}
	st.slots[index] = to
	return true
}

// follow_level forgets everything when the level unloaded since the state was made: the scenes went with it.
@(private)
follow_level :: proc(st: ^State) {
	if generation := st.platform.level_generation(); st.level != generation {
		release_world(st)
		clear(&st.slots)
		clear(&st.events)
		st.streamer = 0
		st.extra_warned = false
		st.stats = {}
		st.level = generation
	}
}

@(private)
release_world :: proc(st: ^State) {
	if loaded, ok := st.world.(World_Loaded); ok {
		asset.unload(st.assets, loaded.handle)
	}
	st.world = nil
	clear(&st.slots)
}

@(private)
emit :: proc(st: ^State, kind: Stream_Event_Kind, number: u32, guid: format.Guid) {
	append(&st.events, Stream_Event{kind = kind, number = number, scene = guid})
}

@(private)
guid_at :: proc(records: []format.World_Scene_Record, index: int) -> format.Guid {
	return records[index].guid if index < len(records) else {}
}

@(private)
is_persistent :: proc(record: format.World_Scene_Record) -> bool {
	return .Persistent in record.flags
}

// scene_distance is the distance in meters from the nearest source to a scene's bounds, 0 inside them.
@(private)
scene_distance :: proc(record: format.World_Scene_Record, sources: []ecs.World_Position) -> f64 {
	nearest := math.INF_F64
	for source in sources {
		closest: ecs.World_Position
		for axis in 0 ..< 3 {
			closest.raw[axis] = min(max(source.raw[axis], record.min[axis]), record.max[axis])
		}
		d := ecs.position_sub_f64(source, closest)
		nearest = min(nearest, math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
	}
	return nearest
}

// unload_slot unloads the scene of a slot that is in, loading or ready, and emits Unloaded.
@(private)
unload_slot :: proc(
	st: ^State,
	w: ^ecs.World,
	scenes: ^scene.Scenes,
	index: int,
	guid: format.Guid,
) {
	in_, is_in := st.slots[index].(Slot_In)
	if !is_in {
		return
	}
	scene.unload_scene(w, scenes, in_.number)
	change_slot(st, index, Slot_Out{})
	emit(st, .Unloaded, in_.number, guid)
}

// unload_all unloads every scene that the policy loaded, as its streamer goes. It gives whether any unloaded.
@(private)
unload_all :: proc(
	st: ^State,
	w: ^ecs.World,
	scenes: ^scene.Scenes,
	records: []format.World_Scene_Record,
) -> (
	unloaded: bool,
) {
	for index in 0 ..< len(st.slots) {
		if _, is_in := st.slots[index].(Slot_In); is_in {
			unload_slot(st, w, scenes, index, guid_at(records, index))
			unloaded = true
		}
	}
	return
}

// world_records is the records of the loaded world's blob, or nothing for a blob that is not a world of this build.
@(private)
world_records :: proc(
	st: ^State,
	loaded: World_Loaded,
) -> (
	records: []format.World_Scene_Record,
	ok: bool,
) {
	data := asset.data(st.assets, loaded.handle) or_return
	blob := format.world_view(data) or_return
	return format.world_scenes(data, blob), true
}

// streamer_valid is whether the streamer entity is alive and still has World_Streamer.
@(private)
streamer_valid :: proc(st: ^State, w: ^ecs.World) -> bool {
	return(
		st.streamer != 0 &&
		ecs.is_alive(w, st.streamer) &&
		ecs.get(w, st.streamer, World_Streamer) != nil \
	)
}

// find_streamer takes the first entity with World_Streamer as the streamer, and warns once when others have it.
@(private)
find_streamer :: proc(st: ^State, w: ^ecs.World) {
	found := make([dynamic]ecs.Entity, st.platform.frame_allocator)
	ecs.collect(w, {WORLD_STREAMER_ID}, &found)
	if len(found) == 0 {
		return
	}
	st.streamer = found[0]
	if len(found) > 1 && !st.extra_warned {
		log.warnf(
			"streaming: %d entities have World_Streamer, so the first one selects the world",
			len(found),
		)
		st.extra_warned = true
	}
}

// load_world loads the blob of the streamer's world. A blob that is missing or is not a world is logged once, and not
// tried again until the streamer names another world.
@(private)
load_world :: proc(st: ^State, guid: format.Guid) {
	buffer: [32]u8
	handle, loaded := asset.load(st.assets, guid)
	if !loaded {
		log.errorf("streaming: the world %s is missing", format.guid_format(guid, &buffer))
		st.world = World_Failed{guid}
		return
	}
	data, has_data := asset.data(st.assets, handle)
	if _, valid := format.world_view(data); !has_data || !valid {
		log.errorf(
			"streaming: %s is not a world blob of this build. Cook the content.",
			format.guid_format(guid, &buffer),
		)
		asset.unload(st.assets, handle)
		st.world = World_Failed{guid}
		return
	}
	st.world = World_Loaded {
		guid    = guid,
		handle  = handle,
		version = asset.version(st.assets, handle),
	}
}

// Candidate is a scene that may begin to load.
@(private)
Candidate :: struct {
	index:      int,
	persistent: bool,
	distance:   f64,
}

// nearer_first orders by persistent scenes first, then by distance.
@(private)
nearer_first :: proc(a, b: Candidate) -> bool {
	if a.persistent != b.persistent {
		return a.persistent
	}
	return a.distance < b.distance
}

// update is one frame of the policy, between frames and outside the script phase. sources are the positions that scenes
// load around, such as the camera's and the Stream_Source entities'. bodies_pending is physics.loading_scenes of this
// frame (see scene.advance_loads). It gives whether any scene unloaded, so the caller has the systems that keep data by
// entity forget the entities that went.
//
// With no sources, only the persistent scenes begin to load, nothing unloads, and the scenes that are loading go on
// loading. A scene unloads when
// the nearest source is farther than its unload distance, and begins to load when the nearest is within its load
// distance; the gap between the two is the hysteresis. Persistent scenes load first, then the nearest, and at most
// MAX_SCENE_LOADS are not ready at a time. A scene that cannot load is failed, and is not tried again until the world's
// blob changes. What happened is in events.
update :: proc(
	st: ^State,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	scenes: ^scene.Scenes,
	sources: []ecs.World_Position,
	bodies_pending: []u32,
) -> (
	unloaded: bool,
) {
	follow_level(st)
	clear(&st.events)
	st.stats = {}
	frame := st.platform.frame_allocator

	if st.streamer != 0 && !streamer_valid(st, w) {
		records: []format.World_Scene_Record
		if loaded, ok := st.world.(World_Loaded); ok {
			records, _ = world_records(st, loaded)
		}
		unloaded = unload_all(st, w, scenes, records) || unloaded
		release_world(st)
		st.streamer = 0
		st.extra_warned = false
	}
	if st.streamer == 0 {
		find_streamer(st, w)
	}
	if st.streamer == 0 {
		return
	}
	wanted := ecs.get(w, st.streamer, World_Streamer).world
	if wanted == {} {
		return
	}
	if current, has := st.world.(World_Loaded); has && current.guid != wanted {
		records, _ := world_records(st, current)
		unloaded = unload_all(st, w, scenes, records) || unloaded
		release_world(st)
	} else if failed, is_failed := st.world.(World_Failed); is_failed && failed.guid != wanted {
		st.world = nil
	}
	if st.world == nil {
		load_world(st, wanted)
	}
	loaded, has_world := st.world.(World_Loaded)
	if !has_world {
		return
	}
	records, valid := world_records(st, loaded)
	if !valid {
		log.error("streaming: the world's blob is not a world of this build")
		return
	}
	version := asset.version(st.assets, loaded.handle)
	if version != loaded.version || len(st.slots) != len(records) {
		unloaded = follow_blob(st, w, scenes, records, version) || unloaded
		if current, ok := &st.world.(World_Loaded); ok {
			current.version = version
		}
	}

	// A scene that something else unloaded is out.
	for index in 0 ..< len(st.slots) {
		if in_, is_in := st.slots[index].(Slot_In); is_in {
			if _, found := scene.stage_of(scenes, in_.number); !found {
				change_slot(st, index, Slot_Out{})
				emit(st, .Unloaded, in_.number, records[index].guid)
			}
		}
	}

	// Without a source every scene is infinitely far: only the persistent scenes begin, and nothing unloads.
	distances := make([]f64, len(records), frame)
	if len(sources) > 0 {
		for record, index in records {
			distances[index] = scene_distance(record, sources)
		}
		for record, index in records {
			unload_distance := max(f64(record.unload_distance), f64(record.load_distance))
			if _, is_in := st.slots[index].(Slot_In); is_in && !is_persistent(record) {
				if distances[index] > unload_distance {
					unload_slot(st, w, scenes, index, record.guid)
					unloaded = true
				}
			}
		}
	} else {
		for &distance in distances {
			distance = math.inf_f64(1)
		}
	}
	begin_loads(st, w, scenes, records, distances)
	advance(st, w, scripts, scenes, records, distances, bodies_pending)
	return
}

// follow_blob makes the slots follow a world blob that changed: there is a slot for each record, a scene whose record
// went unloads, and a failed scene is tried again.
@(private)
follow_blob :: proc(
	st: ^State,
	w: ^ecs.World,
	scenes: ^scene.Scenes,
	records: []format.World_Scene_Record,
	version: u32,
) -> (
	unloaded: bool,
) {
	for index in len(records) ..< len(st.slots) {
		if _, is_in := st.slots[index].(Slot_In); is_in {
			unload_slot(st, w, scenes, index, {})
			unloaded = true
		}
	}
	resize(&st.slots, len(records))
	for index in 0 ..< len(st.slots) {
		if failed, is_failed := st.slots[index].(Slot_Failed);
		   is_failed && failed.version != version {
			change_slot(st, index, Slot_Out{})
		}
	}
	return
}

// begin_loads begins the loads that the distances ask for, while fewer than MAX_SCENE_LOADS scenes are not ready.
@(private)
begin_loads :: proc(
	st: ^State,
	w: ^ecs.World,
	scenes: ^scene.Scenes,
	records: []format.World_Scene_Record,
	distances: []f64,
) {
	frame := st.platform.frame_allocator
	in_flight, total := 0, 0
	candidates := make([dynamic]Candidate, frame)
	for slot, index in st.slots {
		switch s in slot {
		case Slot_In:
			total += 1
			if kind, found := scene.stage_of(scenes, s.number); found && kind != .Ready {
				in_flight += 1
			}
		case Slot_Out:
			record := records[index]
			if is_persistent(record) || distances[index] <= f64(record.load_distance) {
				append(&candidates, Candidate{index, is_persistent(record), distances[index]})
			}
		case Slot_Failed:
		}
	}
	slice.stable_sort_by(candidates[:], nearer_first)
	version := st.world.(World_Loaded).version
	for candidate in candidates {
		if in_flight >= MAX_SCENE_LOADS || total >= MAX_STREAMED_SCENES {
			break
		}
		guid := records[candidate.index].guid
		number, began := scene.begin_load(w, scenes, guid)
		if !began {
			change_slot(st, candidate.index, Slot_Failed{version})
			emit(st, .Failed, 0, guid)
			continue
		}
		change_slot(st, candidate.index, Slot_In{number})
		emit(st, .Loading, number, guid)
		in_flight += 1
		total += 1
	}
}

// advance moves the loading scenes on, nearest first, and emits the scenes that became ready or failed.
@(private)
advance :: proc(
	st: ^State,
	w: ^ecs.World,
	scripts: ^script.Runtime,
	scenes: ^scene.Scenes,
	records: []format.World_Scene_Record,
	distances: []f64,
	bodies_pending: []u32,
) {
	frame := st.platform.frame_allocator
	order := make([dynamic]Candidate, frame)
	numbers := make([dynamic]u32, frame)
	for slot, index in st.slots {
		if s, is_in := slot.(Slot_In); is_in {
			if kind, found := scene.stage_of(scenes, s.number); found && kind != .Ready {
				append(&order, Candidate{index, is_persistent(records[index]), distances[index]})
			}
		}
	}
	slice.stable_sort_by(order[:], nearer_first)
	for candidate in order {
		append(&numbers, st.slots[candidate.index].(Slot_In).number)
	}
	ready, failed, work := scene.advance_loads(
		w,
		scripts,
		scenes,
		numbers[:],
		{scene.SCENE_SPAWNS_PER_FRAME, scene.SCENE_FILLS_PER_FRAME},
		bodies_pending,
	)
	st.stats.entities_spawned = work.spawned
	st.stats.entities_filled = work.filled
	version := st.world.(World_Loaded).version
	for number in ready {
		if index, found := slot_of(st, number); found {
			emit(st, .Ready, number, records[index].guid)
		}
	}
	for number in failed {
		if index, found := slot_of(st, number); found {
			change_slot(st, index, Slot_Failed{version})
			emit(st, .Failed, number, records[index].guid)
		}
	}
	for slot in st.slots {
		if s, is_in := slot.(Slot_In); is_in {
			if kind, found := scene.stage_of(scenes, s.number); found && kind != .Ready {
				st.stats.scenes_loading += 1
			}
		}
	}
}

@(private)
slot_of :: proc(st: ^State, number: u32) -> (index: int, found: bool) {
	for slot, i in st.slots {
		if s, is_in := slot.(Slot_In); is_in && s.number == number {
			return i, true
		}
	}
	return
}
