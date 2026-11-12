package nav

import "core:log"

import "cinnabar:core"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Loading (see docs/ai/navigation.md#loading): the navmeshes of the world's scene load with it, by the list in the
// scene's cooked blob, and unload when the world holds another scene. The state holds asset handles, never blob
// pointers: each frame, prepare reads the loaded blobs into the frame's views, which the queries read, and end_frame lets
// them go before asset.poll can swap a blob. A recooked navmesh is the same handle with a new version, so the frame
// after the cook reads it, and the paths on it are found again.

// Mesh_Record is a navmesh that the scene lists: its GUID, its volume's scene ID, and its handle once it loads.
@(private)
Mesh_Record :: struct {
	guid:   format.Guid,
	volume: u64,
	handle: asset.Handle,
	// The version whose blob was refused, so it is warned about once.
	warned: u32,
}

// Scene_Loaded is a scene whose blob loaded, its version when its list was read, and its navmeshes. generation is the
// cache's generation when a navmesh last could not load, to try again after a cook.
@(private)
Scene_Loaded :: struct {
	guid:       format.Guid,
	handle:     asset.Handle,
	version:    u32,
	generation: i64,
	meshes:     [dynamic]Mesh_Record,
}

// Scene_Missing is a scene whose blob could not load, which is tried again when the cache's generation changes.
@(private)
Scene_Missing :: struct {
	guid:       format.Guid,
	generation: i64,
}

// Scene_State is the scene whose navmeshes are loaded. nil is none.
@(private)
Scene_State :: union {
	Scene_Loaded,
	Scene_Missing,
}

// State is navigation's state in Game_State: the scene's navmeshes, the frame's views of them, and the path requests
// and their pool. It holds handles and plain data only, so a code reload keeps it.
State :: struct {
	platform:     ^core.Platform_API,
	assets:       ^asset.Assets,
	// sync_scene is its only writer.
	scene:        Scene_State,
	// The loaded navmeshes, in the scene's order, in frame memory, from prepare to end_frame, and nil between frames.
	frame:        []Mesh_View,
	paths:        Path_Pool,
	// The Queued and Searching paths, in the order of their requests.
	queue:        [dynamic]Path_Handle,
	// The requests since the last tick: frame code's, and then the systems' jobs', which flush after their stage.
	pending:      [dynamic]Path_Request,
	searches:     [MAX_ACTIVE_SEARCHES]Active_Search,
	// The nodes that the paths system searches in a tick, shared by the searches.
	budget:       int,
	job_requests: ecs.Job_Buffer,
	agents:       ecs.Query,
}

// init makes the state's lists and reserves the searches' memory. Call it once, before register.
init :: proc(s: ^State, platform: ^core.Platform_API, assets: ^asset.Assets) {
	s.platform, s.assets = platform, assets
	heap := platform.heap_allocator
	s.paths = {
		slots       = make([dynamic]Path_Slot, heap),
		generations = make([dynamic]u32, heap),
		free        = make([dynamic]u32, heap),
	}
	s.queue = make([dynamic]Path_Handle, heap)
	s.pending = make([dynamic]Path_Request, heap)
	for &a in s.searches {
		graph_reserve(&a.search.graph, MAX_PATH_NODES, heap)
	}
	s.budget = DEFAULT_TICK_NODES
}

// register makes the query, the requests' job buffer and the paths system. Call it after the world's components are
// registered, in init and in on_reload.
register :: proc(s: ^State, w: ^ecs.World) {
	s.frame = nil
	s.agents = ecs.query(w, {ecs.read(w, Nav_Path)})
	s.job_requests = ecs.register_job_buffer(w, {name = "path requests", user = s, make = make_job_requests, flush = flush_job_requests})
	reads := []ecs.Component_Id{ecs.TRANSFORM_ID}
	writes := []ecs.Component_Id{NAV_PATH_ID}
	ecs.register_system(w, {name = "nav paths", stage = .Fixed, procedure = tick_paths, reads = reads, writes = writes, data = s})
}

// reload keeps the state after a code reload.
reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
}

// destroy unloads the navmeshes and frees the paths and the searches.
destroy :: proc(s: ^State) {
	leave_scene(s)
	for i in 0 ..< len(s.paths.slots) {
		if s.paths.slots[i].phase != nil {
			release_phase(s, &s.paths.slots[i])
		}
	}
	delete(s.paths.slots)
	delete(s.paths.generations)
	delete(s.paths.free)
	delete(s.queue)
	delete(s.pending)
	for &a in s.searches {
		graph_delete(&a.search.graph)
	}
	s.frame = nil
}

// prepare loads the navmeshes of the world's scene, if the scene or its list changed, and reads the loaded ones into
// the frame's views. Call it in the frame code in every mode, before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	sync_scene(s, w.scene)
	loaded, _ := &s.scene.(Scene_Loaded)
	if loaded == nil {
		s.frame = nil
		return
	}
	views := make([dynamic]Mesh_View, 0, len(loaded.meshes), w.platform.frame_allocator)
	for &r in loaded.meshes {
		data, ok := asset.data(s.assets, r.handle)
		if !ok {
			continue
		}
		stamp := Mesh_Stamp{r.handle, asset.version(s.assets, r.handle)}
		view, valid := view_of(data, stamp, r.volume)
		if !valid {
			if r.warned != stamp.version {
				r.warned = stamp.version
				buffer: [32]u8
				log.warnf("nav: the navmesh %s is not a navmesh blob of this build. Cook the content.", format.guid_format(r.guid, &buffer))
			}
			continue
		}
		append(&views, view)
	}
	s.frame = views[:]
}

// end_frame lets the frame's views go, before asset.poll can swap their blobs. Call it at the end of the frame code.
end_frame :: proc(s: ^State) {
	s.frame = nil
}

// set_budget sets the nodes that the paths system searches in a tick (see docs/ai/navigation.md#path-requests).
set_budget :: proc(s: ^State, nodes: int) {
	s.budget = max(nodes, 1)
}

// sync_scene is the only writer of s.scene. It loads the navmeshes of a new scene and unloads the old scene's, reads
// the list of a recooked scene again, and tries again what could not load after the next cook.
@(private)
sync_scene :: proc(s: ^State, guid: format.Guid) {
	generation := s.assets.cache_generation
	switch &v in s.scene {
	case nil:
		enter_scene(s, guid)
	case Scene_Missing:
		if v.guid != guid || v.generation != generation {
			enter_scene(s, guid)
		}
	case Scene_Loaded:
		if v.guid != guid {
			leave_scene(s)
			enter_scene(s, guid)
		} else if asset.version(s.assets, v.handle) != v.version {
			list_meshes(s, &v)
		} else if v.generation != generation {
			for &r in v.meshes {
				if r.handle == {} {
					r.handle, _ = asset.load(s.assets, r.guid)
				}
			}
			v.generation = generation
		}
	}
}

@(private)
enter_scene :: proc(s: ^State, guid: format.Guid) {
	s.scene = nil
	if guid == {} {
		return
	}
	handle, ok := asset.load(s.assets, guid)
	if !ok {
		s.scene = Scene_Missing{guid, s.assets.cache_generation}
		return
	}
	s.scene = Scene_Loaded {
		guid   = guid,
		handle = handle,
		meshes = make([dynamic]Mesh_Record, s.platform.heap_allocator),
	}
	list_meshes(s, &s.scene.(Scene_Loaded))
}

// list_meshes reads the scene's list of navmeshes and loads them. The new list loads before the old one unloads, so a
// navmesh on both stays loaded.
@(private)
list_meshes :: proc(s: ^State, v: ^Scene_Loaded) {
	v.version = asset.version(s.assets, v.handle)
	v.generation = s.assets.cache_generation
	old := v.meshes
	v.meshes = make([dynamic]Mesh_Record, s.platform.heap_allocator)
	data, _ := asset.data(s.assets, v.handle)
	listed, ok := format.scene_nav_meshes(data, s.platform.frame_allocator)
	if !ok {
		buffer: [32]u8
		log.warnf("nav: the scene %s is not a scene blob of this build, so its navmeshes do not load.", format.guid_format(v.guid, &buffer))
	}
	for n in listed {
		handle, _ := asset.load(s.assets, n.guid)
		append(&v.meshes, Mesh_Record{guid = n.guid, volume = n.entity, handle = handle})
	}
	unload_meshes(s, old[:])
	delete(old)
}

@(private)
leave_scene :: proc(s: ^State) {
	if v, ok := &s.scene.(Scene_Loaded); ok {
		unload_meshes(s, v.meshes[:])
		delete(v.meshes)
		asset.unload(s.assets, v.handle)
	}
	s.scene = nil
}

@(private)
unload_meshes :: proc(s: ^State, meshes: []Mesh_Record) {
	for r in meshes {
		if r.handle != {} {
			asset.unload(s.assets, r.handle)
		}
	}
}
