package nav

import "core:log"
import "core:slice"

import "cinnabar:core"
import "cinnabar:engine/ai"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/physics"

// Loading (see docs/ai/navigation.md#loading): the navmeshes of each of the world's scenes load with it, by the list in
// the scene's cooked blob, and unload when the scene leaves the world. The state holds asset handles, never blob
// pointers: each frame, prepare reads the loaded blobs into the frame's views, which the queries read, and end_frame lets
// them go before asset.poll can swap a blob. A recooked navmesh is the same handle with a new version, so the frame
// after the cook reads it, and the paths on it are found again. Each navmesh keeps a slot in the frame's views while it
// is loaded, which a Poly names it by.

// Mesh_Record is a navmesh that a scene lists: its GUID, its volume's scene ID, its slot, and its handle once it loads.
@(private)
Mesh_Record :: struct {
	guid:   format.Guid,
	volume: u64,
	slot:   u32,
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

// Scene_State is a scene of the world's: its navmeshes loaded, or its blob missing.
@(private)
Scene_State :: union #no_nil {
	Scene_Loaded,
	Scene_Missing,
}

// Mesh_Slots is how many slots the frame has, and the free ones among them, which the next navmesh to load takes from
// the end.
@(private)
Mesh_Slots :: struct {
	count: u32,
	free:  [dynamic]u32,
}

// State is navigation's state in Game_State: the scenes' navmeshes, the frame's views of them and the seams between
// them, the path requests and their pool, and the crowd. It holds handles and plain data only, so a code reload keeps
// it.
State :: struct {
	platform:      ^core.Platform_API,
	assets:        ^asset.Assets,
	// Physics lives in Game_State too, so the pointer stays valid across reloads. The crowd moves its agents' characters
	// in it; with none, they stand still.
	physics:       ^physics.State,
	// The world's scenes, each once, in the order that they came. sync_scenes is its only writer.
	scenes:        [dynamic]Scene_State,
	slots:         Mesh_Slots,
	// The loaded navmeshes by slot, an empty slot's with no stamp, in frame memory, from prepare to end_frame, and nil
	// between frames.
	frame:         []Mesh_View,
	// The seam links, each slot's run of them, and the stamps by slot that they were joined for. prepare writes them,
	// and join_seams the links, when prepare finds the stamps changed.
	seams:         [dynamic]Seam_Link,
	seam_runs:     [dynamic][2]u32,
	seam_stamps:   [dynamic]Mesh_Stamp,
	// Goes up when a navmesh unloads or is recooked, so a search that may have crossed it starts again.
	mesh_epoch:    u64,
	paths:         Path_Pool,
	// The Queued and Searching paths, in the order of their requests.
	queue:         [dynamic]Path_Handle,
	// The requests since the last tick: frame code's, and then the systems' jobs', which flush after their stage.
	pending:       [dynamic]Path_Request,
	searches:      [MAX_ACTIVE_SEARCHES]Active_Search,
	// The nodes that the paths system searches in a tick, shared by the searches.
	budget:        int,
	job_requests:  ecs.Job_Buffer,
	agents:        ecs.Query,
	crowd:         Crowd_Pool,
	// The moves and stops since the last crowd tick: frame code's and the scripts', and then the systems' jobs'.
	crowd_pending: [dynamic]Crowd_Request,
	job_crowd:     ecs.Job_Buffer,
	crowd_agents:  ecs.Query,
}

// init makes the state's lists and reserves the searches' memory. Call it once, before register. The crowd moves its
// agents in physics.
init :: proc(
	s: ^State,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
	physics: ^physics.State = nil,
) {
	s.platform, s.assets, s.physics = platform, assets, physics
	heap := platform.heap_allocator
	s.scenes = make([dynamic]Scene_State, heap)
	s.slots = {
		free = make([dynamic]u32, heap),
	}
	s.seams = make([dynamic]Seam_Link, heap)
	s.seam_runs = make([dynamic][2]u32, heap)
	s.seam_stamps = make([dynamic]Mesh_Stamp, heap)
	s.paths = {
		slots       = make([dynamic]Path_Slot, heap),
		generations = make([dynamic]u32, heap),
		free        = make([dynamic]u32, heap),
	}
	s.queue = make([dynamic]Path_Handle, heap)
	s.pending = make([dynamic]Path_Request, heap)
	s.crowd = {
		slots       = make([dynamic]Crowd_Slot, heap),
		generations = make([dynamic]u32, heap),
		free        = make([dynamic]u32, heap),
	}
	s.crowd_pending = make([dynamic]Crowd_Request, heap)
	for &a in s.searches {
		graph_reserve(&a.search.graph, MAX_PATH_NODES, heap)
	}
	s.budget = DEFAULT_TICK_NODES
}

// register makes the queries, the requests' job buffers, the paths system and the crowd system. With the agents' AI,
// which must be registered before, the crowd runs after their actions, and registers the move_to and stop actions.
// Call it after the world's components are registered, in init and in on_reload.
register :: proc(s: ^State, w: ^ecs.World, agents: ^ai.State = nil) {
	s.frame = nil
	s.agents = ecs.query(w, {ecs.read(w, Nav_Path)})
	s.crowd_agents = ecs.query(w, {ecs.read(w, Nav_Agent)})
	s.job_requests = ecs.register_job_buffer(
		w,
		{name = "path requests", user = s, make = make_job_requests, flush = flush_job_requests},
	)
	s.job_crowd = ecs.register_job_buffer(
		w,
		{name = "crowd requests", user = s, make = make_job_crowd, flush = flush_job_crowd},
	)
	reads := []ecs.Component_Id{ecs.TRANSFORM_ID}
	writes := []ecs.Component_Id{NAV_PATH_ID}
	ecs.register_system(
		w,
		{
			name = "nav paths",
			stage = .Fixed,
			procedure = tick_paths,
			reads = reads,
			writes = writes,
			data = s,
		},
	)
	// The crowd reads the paths that the paths system solved in the tick, and the moves that the actions asked for.
	after := []string{"nav paths", "ai actions"} if agents != nil else []string{"nav paths"}
	crowd_reads := []ecs.Component_Id {
		NAV_AGENT_ID,
		NAV_PATH_ID,
		ecs.TRANSFORM_ID,
		physics.CHARACTER_ID,
		physics.PHYSICS_CHARACTER_ID,
	}
	crowd_writes := []ecs.Component_Id{NAV_AGENT_STATE_ID}
	ecs.register_system(
		w,
		{
			name = "nav crowd",
			stage = .Fixed,
			procedure = crowd_system,
			reads = crowd_reads,
			writes = crowd_writes,
			after = after,
			data = s,
		},
	)
	if agents != nil {
		register_crowd_actions(s, agents)
	}
}

// reload keeps the state after a code reload.
reload :: proc(s: ^State, platform: ^core.Platform_API) {
	s.platform = platform
}

// destroy unloads the navmeshes and frees the paths and the searches.
destroy :: proc(s: ^State) {
	for len(s.scenes) > 0 {
		leave_scene(s, len(s.scenes) - 1)
	}
	delete(s.scenes)
	delete(s.slots.free)
	delete(s.seams)
	delete(s.seam_runs)
	delete(s.seam_stamps)
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
	for i in 0 ..< len(s.crowd.slots) {
		release_crowd_phase(&s.crowd.slots[i])
	}
	delete(s.crowd.slots)
	delete(s.crowd.generations)
	delete(s.crowd.free)
	delete(s.crowd_pending)
	for &a in s.searches {
		graph_delete(&a.search.graph)
	}
	s.frame = nil
}

// prepare loads the navmeshes of the scenes that came into the world or whose list changed, unloads those of the
// scenes that went, reads the loaded ones into the frame's views by slot, and joins the seams between them again when
// any of them changed. Call it in the frame code in every mode, before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	sync_scenes(s, ecs.world_scenes(w))
	views := make([]Mesh_View, int(s.slots.count), w.platform.frame_allocator)
	for &scene in s.scenes {
		loaded, ok := &scene.(Scene_Loaded)
		if !ok {
			continue
		}
		for &r in loaded.meshes {
			data, has := asset.data(s.assets, r.handle)
			if !has {
				continue
			}
			stamp := Mesh_Stamp{r.handle, asset.version(s.assets, r.handle)}
			view, valid := view_of(data, stamp, loaded.guid, r.volume, r.slot)
			if !valid {
				if r.warned != stamp.version {
					r.warned = stamp.version
					buffer: [32]u8
					log.warnf(
						"nav: the navmesh %s is not a navmesh blob of this build. Cook the content.",
						format.guid_format(r.guid, &buffer),
					)
				}
				continue
			}
			views[r.slot] = view
		}
	}
	for &v, i in views {
		v.slot = u32(i)
	}
	changed := len(s.seam_stamps) != len(views)
	gone := false
	resize(&s.seam_stamps, len(views))
	for &v, i in views {
		if s.seam_stamps[i] != v.stamp {
			changed = true
			gone ||= s.seam_stamps[i] != {}
			s.seam_stamps[i] = v.stamp
		}
	}
	if gone {
		s.mesh_epoch += 1
	}
	if changed {
		join_seams(s, views)
	} else {
		for &v in views {
			run := s.seam_runs[v.slot]
			v.seams = s.seams[run[0]:run[1]]
		}
	}
	s.frame = views
}

// end_frame lets the frame's views go, before asset.poll can swap their blobs. Call it at the end of the frame code.
end_frame :: proc(s: ^State) {
	s.frame = nil
}

// set_budget sets the nodes that the paths system searches in a tick (see docs/ai/navigation.md#path-requests).
set_budget :: proc(s: ^State, nodes: int) {
	s.budget = max(nodes, 1)
}

// sync_scenes is the only writer of s.scenes. It unloads the navmeshes of the scenes that left the world, loads those
// of the scenes that came, once for a scene that the world holds twice, and keeps each scene's up to date.
@(private)
sync_scenes :: proc(s: ^State, guids: []format.Guid) {
	for i := len(s.scenes) - 1; i >= 0; i -= 1 {
		if !slice.contains(guids, guid_of(s.scenes[i])) {
			leave_scene(s, i)
		}
	}
	for guid, i in guids {
		if slice.contains(guids[:i], guid) {
			continue
		}
		found := false
		for &scene in s.scenes {
			if guid_of(scene) == guid {
				sync_scene(s, &scene)
				found = true
				break
			}
		}
		if !found {
			append(&s.scenes, enter_scene(s, guid))
		}
	}
}

@(private)
guid_of :: proc "contextless" (scene: Scene_State) -> format.Guid {
	switch v in scene {
	case Scene_Loaded:
		return v.guid
	case Scene_Missing:
		return v.guid
	}
	return {}
}

// sync_scene reads the list of a recooked scene again, and tries again what could not load after the next cook.
@(private)
sync_scene :: proc(s: ^State, scene: ^Scene_State) {
	generation := s.assets.cache_generation
	switch &v in scene {
	case Scene_Missing:
		if v.generation != generation {
			scene^ = enter_scene(s, v.guid)
		}
	case Scene_Loaded:
		if asset.version(s.assets, v.handle) != v.version {
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
enter_scene :: proc(s: ^State, guid: format.Guid) -> Scene_State {
	handle, ok := asset.load(s.assets, guid)
	if !ok {
		return Scene_Missing{guid, s.assets.cache_generation}
	}
	loaded := Scene_Loaded {
		guid   = guid,
		handle = handle,
		meshes = make([dynamic]Mesh_Record, s.platform.heap_allocator),
	}
	list_meshes(s, &loaded)
	return loaded
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
		log.warnf(
			"nav: the scene %s is not a scene blob of this build, so its navmeshes do not load.",
			format.guid_format(v.guid, &buffer),
		)
	}
	for n in listed {
		handle, _ := asset.load(s.assets, n.guid)
		// A navmesh on both lists keeps its slot, so the paths on it stay.
		slot := NO_SLOT
		for &r in old {
			if r.guid == n.guid && r.slot != NO_SLOT {
				slot, r.slot = r.slot, NO_SLOT
				break
			}
		}
		if slot == NO_SLOT {
			slot = take_slot(s)
		}
		append(
			&v.meshes,
			Mesh_Record{guid = n.guid, volume = n.entity, slot = slot, handle = handle},
		)
	}
	unload_meshes(s, old[:])
	delete(old)
}

// leave_scene unloads a scene's navmeshes and its blob, and forgets it.
@(private)
leave_scene :: proc(s: ^State, index: int) {
	if v, ok := &s.scenes[index].(Scene_Loaded); ok {
		unload_meshes(s, v.meshes[:])
		delete(v.meshes)
		asset.unload(s.assets, v.handle)
	}
	ordered_remove(&s.scenes, index)
}

// NO_SLOT is a record's slot once a new list of its scene took it.
@(private)
NO_SLOT :: max(u32)

// unload_meshes unloads navmeshes and frees their slots.
@(private)
unload_meshes :: proc(s: ^State, meshes: []Mesh_Record) {
	for r in meshes {
		if r.handle != {} {
			asset.unload(s.assets, r.handle)
		}
		if r.slot != NO_SLOT {
			append(&s.slots.free, r.slot)
		}
	}
}

// take_slot is a free slot of the frame's views, the last that was freed, or a new one.
@(private)
take_slot :: proc(s: ^State) -> u32 {
	slot: u32
	if len(s.slots.free) > 0 {
		slot = pop(&s.slots.free)
	} else {
		slot = s.slots.count
		s.slots.count += 1
	}
	return slot
}
