package scene

import "base:runtime"
import "core:log"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

SCENE_OWNED_ID :: ecs.Component_Id(9)

// FIRST_RUNTIME_SCENE is the first number that add_scene gives a scene when no number is given. The editor numbers
// its scenes from 1, so a scene that the game streams in never takes an editor's number (see
// docs/world/scenes.md#numbers).
FIRST_RUNTIME_SCENE :: u32(1) << 31

// Scene_Owned marks an entity that a scene's entity spawned but that is not in the scene, such as a prefab's root that
// a behaviour spawned. It goes when its scene unloads (see unload_scene). Its children go with it, through Parent.
Scene_Owned :: struct {
	scene: u32 `editor:"read"`,
}

// Key is an entity of a scene: the scene's number and the entity's scene ID, which is 0 for an entity that the game
// spawned.
Key :: struct {
	scene: u32,
	id:    u64,
}

// Loaded_Scene is a scene in the world, by its number.
Loaded_Scene :: struct {
	number:   u32,
	guid:     format.Guid,
	// The blob that add_scene_asset loaded, which unload_scene lets go. has_blob is false for a scene that came from
	// the editor or from memory.
	blob:     asset.Handle,
	has_blob: bool,
	// The scene's own memory and GPU scope, which unload_scene closes (see docs/core/jobs-and-memory.md#scene-memory).
	memory:   core.Scene_Memory,
	// Where the scene's load is. It is Scene_Ready for a scene that add_scene added. Change it only with change_stage.
	stage:    Scene_Stage,
}

// Scene_Map is the map from scene ID to entity of one scene, and the memory that it is in: its scene's, or the level's
// for a scene that index found without add_scene, whose memory is the zero handle.
@(private)
Scene_Map :: struct {
	memory:  core.Scene_Memory,
	handles: ^map[u64]ecs.Entity,
}

// Scenes is the world's loaded scenes, and the entity of each scene ID by its scene. The level is every loaded scene:
// unload_level unloads all of them, and unload_scene one. The table and the map of maps use the heap. Each loaded
// scene's map is in its scene's memory, and goes with it; the map of a scene that index found without add_scene is in
// the Level arena. level is the level generation that they were made in (see maps). It lives beside the world, in
// Game_State.
Scenes :: struct {
	platform: ^core.Platform_API,
	// The blobs of add_scene_asset, or nil.
	assets:   ^asset.Assets,
	loaded:   [dynamic]Loaded_Scene,
	by_scene: map[u32]Scene_Map,
	level:    u64,
	// The number that add_scene gives the next scene without one.
	next:     u32,
}

// init_scenes makes an empty table. assets can be nil, and then add_scene_asset loads nothing.
init_scenes :: proc(s: ^Scenes, platform: ^core.Platform_API, assets: ^asset.Assets = nil) {
	s^ = {
		platform = platform,
		assets   = assets,
		loaded   = make([dynamic]Loaded_Scene, platform.heap_allocator),
		by_scene = make(map[u32]Scene_Map, platform.heap_allocator),
		level    = platform.level_generation(),
		next     = FIRST_RUNTIME_SCENE,
	}
}

// reload_scenes takes the new DLL's platform after a code reload.
reload_scenes :: proc(s: ^Scenes, platform: ^core.Platform_API) {
	s.platform = platform
}

// destroy_scenes lets the blobs go, closes the scenes' memory and frees the table. The maps of scenes that index
// found are the level's memory.
destroy_scenes :: proc(s: ^Scenes) {
	release_scenes(s)
	delete(s.loaded)
	delete(s.by_scene)
	s^ = {}
}

// loaded_scenes is the world's scenes, in the order that they loaded. A scene that is still loading is one of them
// (see stage_of).
loaded_scenes :: proc(s: ^Scenes) -> []Loaded_Scene {
	follow_level(s)
	return s.loaded[:]
}

// is_loaded is whether the scene with the number is in the world.
is_loaded :: proc(s: ^Scenes, number: u32) -> bool {
	_, found := find_loaded(s, number)
	return found
}

// reserve_number gives the number that add_scene would give the next scene without one, and takes it, so a scene that
// loads later has it.
reserve_number :: proc(s: ^Scenes) -> u32 {
	follow_level(s)
	number := s.next
	s.next += 1
	return number
}

// add_scene adds a scene to the world beside the scenes that are loaded, and gives its number: number, or with none,
// the next of the game's own (see FIRST_RUNTIME_SCENE). The scene gets memory of its own, which goes when it unloads.
// It refuses a number that is loaded, or a scene when core.MAX_SCENE_MEMORY scenes are loaded, and gives false. The
// scene's IDs resolve only in the scene. The world's scene GUID, whose navmeshes load, is the first loaded scene's.
// Call it between frames, outside the script phase. problems, if given, gets each warning, in frame memory.
add_scene :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	scene: format.Scene,
	number: Maybe(u32) = nil,
	problems: ^[dynamic]Problem = nil,
) -> (
	added: u32,
	ok: bool,
) {
	added = append_scene(s, scene.guid, number, Scene_Ready{}) or_return
	if w.scene == {} {
		w.scene = scene.guid
	}
	spawned := add_entities(w, scripts, scene.entities, handles_of(s, added), problems, added)
	log.infof("scene: loaded the scene %d, %d entities", added, spawned)
	return added, true
}

// append_scene adds a row for a scene to the table, with its number as add_scene gives it, its memory and its first
// stage, and refuses as add_scene does.
@(private)
append_scene :: proc(
	s: ^Scenes,
	guid: format.Guid,
	number: Maybe(u32),
	stage: Scene_Stage,
) -> (
	added: u32,
	ok: bool,
) {
	follow_level(s)
	added = number.? or_else s.next
	if is_loaded(s, added) {
		log.warnf("scene: the scene %d is loaded, so it is not loaded again", added)
		return 0, false
	}
	memory, opened := s.platform.scene_memory_open()
	if !opened {
		log.errorf("scene: the scene %d has no memory, so it is not loaded", added)
		return 0, false
	}
	if added >= s.next {
		s.next = added + 1
	}
	// A map that index made in the level's memory before the scene loaded gives way to one in the scene's.
	delete_key(&s.by_scene, added)
	row := Loaded_Scene {
		number = added,
		guid   = guid,
		memory = memory,
	}
	change_stage(&row, stage)
	append(&s.loaded, row)
	return added, true
}

// add_scene_asset adds a cooked scene by GUID, as add_scene does. The blob stays loaded until the scene unloads.
add_scene_asset :: proc(
	w: ^ecs.World,
	scripts: ^script.Runtime,
	s: ^Scenes,
	guid: format.Guid,
	number: Maybe(u32) = nil,
) -> (
	added: u32,
	ok: bool,
) {
	if s.assets == nil {
		log.error("scene: there are no assets to load a scene from")
		return 0, false
	}
	h, scene := read_scene_blob(w, s.assets, guid) or_return
	if added, ok = add_scene(w, scripts, s, scene, number); !ok {
		asset.unload(s.assets, h)
		return
	}
	keep_blob(s, h)
	return
}

// unload_scene despawns the entities of the scene with the number, the entities that they own (see Scene_Owned) and
// their children, lets the scene's blob go, and closes the scene's memory, which frees its map and destroys the GPU
// resources in its scope. The other scenes, their entities, their memory and the game's own stay. A scene whose GUID is the world's passes it to the next
// loaded scene. It gives how many entities it despawned. Call it between frames, outside the script phase; the
// systems that keep data by entity drop the despawned ones at their next sweep, which game.forget_despawned runs at
// once (see docs/world/scenes.md#the-systems).
unload_scene :: proc(w: ^ecs.World, s: ^Scenes, number: u32) -> int {
	follow_level(s)
	index, found := find_loaded(s, number)
	if !found {
		log.warnf("scene: the scene %d is not loaded, so it is not unloaded", number)
		return 0
	}
	gone := s.loaded[index]
	ordered_remove(&s.loaded, index)
	end_read(s, &gone)
	if gone.has_blob && s.assets != nil {
		asset.unload(s.assets, gone.blob)
	}
	if w.scene == gone.guid {
		w.scene = {}
		for other in s.loaded {
			if other.guid != {} {
				w.scene = other.guid
				break
			}
		}
	}
	delete_key(&s.by_scene, number)
	s.platform.scene_memory_close(gone.memory)
	doomed := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if owner, has := scene_of(w, entity); has && owner == number {
			append(&doomed, entity)
		}
	}
	despawned := ecs.entity_count(w)
	ecs.despawn_many(w, doomed[:])
	ecs.update_activity(w)
	despawned -= ecs.entity_count(w)
	log.infof("scene: unloaded the scene %d, %d entities", number, despawned)
	return int(despawned)
}

// scene_of is the scene that an entity belongs to: its scene's for a scene's entity, its owner's for one that a
// scene's entity spawned (see Scene_Owned), or false for one that the game spawned.
scene_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> (number: u32, ok: bool) {
	if s := (^Scene_Entity)(ecs.get_raw(w, entity, SCENE_ENTITY_ID)); s != nil {
		return s.scene, true
	}
	if o := (^Scene_Owned)(ecs.get_raw(w, entity, SCENE_OWNED_ID)); o != nil {
		return o.scene, true
	}
	return 0, false
}

// key_of is an entity's scene and scene ID, or zero for one that the game spawned.
key_of :: proc(w: ^ecs.World, entity: ecs.Entity) -> Key {
	s := (^Scene_Entity)(ecs.get_raw(w, entity, SCENE_ENTITY_ID))
	return {s.scene, s.id} if s != nil else {}
}

// find is the entity with a scene ID in the scene with the number, or 0. A handle that the map has but that is gone,
// or that another entity's slot now holds, makes the maps be built again from every entity's Scene_Entity.
find :: proc(s: ^Scenes, w: ^ecs.World, number: u32, id: u64) -> ecs.Entity {
	if m, ok := maps(s)[number]; ok {
		if entity, has := m.handles[id]; has && key_of(w, entity) == {number, id} {
			return entity
		}
	}
	index(s, w)
	if m, ok := maps(s)[number]; ok {
		return m.handles[id] or_else 0
	}
	return 0
}

// index maps every entity that a scene made from its scene's number and its scene ID. A scene that the world got
// without add_scene, such as the game's own at init before this table, is found this way.
index :: proc(s: ^Scenes, w: ^ecs.World) {
	for _, m in maps(s) {
		clear(m.handles)
	}
	it := ecs.world_iter(w)
	for entity in ecs.world_next(&it) {
		if key := key_of(w, entity); key.id != 0 {
			handles_of(s, key.scene)[key.id] = entity
		}
	}
}

// has_maps is whether any scene has a map in this level, so a caller that needs them can build them first (see
// index).
has_maps :: proc(s: ^Scenes) -> bool {
	return len(maps(s)) != 0
}

// handles_of is the map from scene ID to entity of the scene with the number, made at its first use in the scene's
// memory, or in the level's for a scene that is not loaded. It stays where it is until its memory goes, so a new
// scene's map does not move it.
handles_of :: proc(s: ^Scenes, number: u32) -> ^map[u64]ecs.Entity {
	m := maps(s)
	if existing, ok := m[number]; ok {
		return existing.handles
	}
	memory, _ := memory_of(s, number)
	allocator := s.platform.level_allocator
	if memory != {} {
		allocator = s.platform.scene_memory_allocator(memory)
	}
	handles := new(map[u64]ecs.Entity, allocator)
	handles^ = make(map[u64]ecs.Entity, allocator)
	m[number] = {memory, handles}
	return handles
}

// memory_of is the memory of the loaded scene with the number, or false if it is not loaded. A holder of data in it
// keeps the handle, and drops its pointers once Platform_API.scene_memory_alive is false: the scene unloaded.
memory_of :: proc(s: ^Scenes, number: u32) -> (core.Scene_Memory, bool) {
	index, found := find_loaded(s, number)
	if !found {
		return {}, false
	}
	return s.loaded[index].memory, true
}

// allocator_of is the allocator of the memory of the loaded scene with the number, or the nil allocator if it is not
// loaded. What it allocates goes when the scene unloads.
allocator_of :: proc(s: ^Scenes, number: u32) -> runtime.Allocator {
	if memory, ok := memory_of(s, number); ok {
		return s.platform.scene_memory_allocator(memory)
	}
	return runtime.nil_allocator()
}

// maps is the maps of every scene by its number. A map whose memory went is dropped: the level's maps once the level
// unloads, and a scene's once its memory closes. The next use builds them again. Read by_scene only through it.
@(private)
maps :: proc(s: ^Scenes) -> ^map[u32]Scene_Map {
	follow_level(s)
	for {
		stale, found := u32(0), false
		for number, m in s.by_scene {
			if m.memory != {} && !s.platform.scene_memory_alive(m.memory) {
				stale, found = number, true
				break
			}
		}
		if !found {
			break
		}
		delete_key(&s.by_scene, stale)
	}
	return &s.by_scene
}

// follow_level forgets the maps and the scenes when the level unloaded since they were made. unload_level lets the
// blobs go first; a level that another caller unloaded lets them go here. level_unload closed the scenes' memory.
@(private)
follow_level :: proc(s: ^Scenes) {
	if generation := s.platform.level_generation(); s.level != generation {
		forget_level(s)
		s.level = generation
	}
}

@(private)
forget_level :: proc(s: ^Scenes) {
	release_scenes(s)
	clear(&s.loaded)
	clear(&s.by_scene)
	s.next = FIRST_RUNTIME_SCENE
}

// release_scenes lets the blobs go and closes the memory of the scenes that are loaded. Memory that level_unload
// closed already stays closed.
@(private)
release_scenes :: proc(s: ^Scenes) {
	for &loaded in s.loaded {
		end_read(s, &loaded)
		if loaded.has_blob && s.assets != nil {
			asset.unload(s.assets, loaded.blob)
			loaded.has_blob = false
		}
		s.platform.scene_memory_close(loaded.memory)
		loaded.memory = {}
	}
}

@(private)
find_loaded :: proc(s: ^Scenes, number: u32) -> (index: int, found: bool) {
	follow_level(s)
	for loaded, i in s.loaded {
		if loaded.number == number {
			return i, true
		}
	}
	return
}

// read_scene_blob loads a cooked scene's blob, keeps it loaded, and reads it into frame memory.
@(private)
read_scene_blob :: proc(
	w: ^ecs.World,
	assets: ^asset.Assets,
	guid: format.Guid,
) -> (
	h: asset.Handle,
	scene: format.Scene,
	ok: bool,
) {
	buffer: [32]u8
	loaded: bool
	if h, loaded = asset.load(assets, guid); !loaded {
		log.errorf("scene: the scene %s is missing", format.guid_format(guid, &buffer))
		return {}, {}, false
	}
	data, has_data := asset.data(assets, h)
	scene, ok = format.scene_read(data, w.platform.frame_allocator)
	if !has_data || !ok {
		log.errorf(
			"scene: %s is not a scene blob of this build. Cook the content.",
			format.guid_format(guid, &buffer),
		)
		asset.unload(assets, h)
		return {}, {}, false
	}
	return h, scene, true
}

// keep_blob gives the scene that add_scene added last its blob, which unload_scene lets go.
@(private)
keep_blob :: proc(s: ^Scenes, h: asset.Handle) {
	loaded := &s.loaded[len(s.loaded) - 1]
	loaded.blob, loaded.has_blob = h, true
}
