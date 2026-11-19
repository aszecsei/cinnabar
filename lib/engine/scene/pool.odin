package scene

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// Pooling keeps the entities of a prefab's instance when the game is done with it, and fills them with the prefab's
// values at the next spawn of that prefab, so a game that spawns many instances a second does not spawn and despawn
// entities, or read the blob into new archetype rows, each time (see docs/editor/prefabs.md#pooling).
//
// An instance is in one place at a time: in live, by its root, while it is in the world, or in its prefab's free list
// while it waits. pool_spawn moves it from free to live, and pool_release from live to free; nothing else does.

// Pooled_Instance is an instance that a pool spawned: its prefab, the version of the blob that made it, its root, and
// each of the prefab's entities in the blob's order, or 0 for one that its first spawn skipped. entities is the pools'.
@(private)
Pooled_Instance :: struct {
	prefab:   format.Guid,
	version:  u32,
	root:     ecs.Entity,
	entities: []ecs.Entity,
}

// Prefab_Pools is the instances that pool_spawn made: the ones in the world, by root, and the ones that wait, by
// prefab. They are part of Scenes, so a level unload forgets them with the scenes, and they live in the heap.
Prefab_Pools :: struct {
	live:     map[ecs.Entity]Pooled_Instance,
	free:     map[format.Guid][dynamic]Pooled_Instance,
	// The count of live instances at which pool_spawn next drops the ones whose root is gone.
	sweep_at: int,
}

@(private = "file")
FIRST_SWEEP :: 64

@(private)
init_pools :: proc(s: ^Scenes) {
	s.pools = {
		live     = make(map[ecs.Entity]Pooled_Instance, s.platform.heap_allocator),
		free     = make(map[format.Guid][dynamic]Pooled_Instance, s.platform.heap_allocator),
		sweep_at = FIRST_SWEEP,
	}
}

// clear_pools forgets every instance, as a level unload, whose despawn_all took their entities. It despawns nothing.
@(private)
clear_pools :: proc(s: ^Scenes) {
	p := &s.pools
	for _, instance in p.live {
		delete(instance.entities, s.platform.heap_allocator)
	}
	clear(&p.live)
	for _, &free in p.free {
		for instance in free {
			delete(instance.entities, s.platform.heap_allocator)
		}
		delete(free)
	}
	clear(&p.free)
	p.sweep_at = FIRST_SWEEP
}

@(private)
destroy_pools :: proc(s: ^Scenes) {
	clear_pools(s)
	delete(s.pools.live)
	delete(s.pools.free)
	s.pools = {}
}

// pool_spawn spawns an instance of a prefab as spawn_prefab does, with its root at a pose and, with an owner, owned
// by that scene, and gives its root. When pool_release kept an instance of the prefab, it takes that one: its entities
// get the prefab's values again, the components that the game added go, and its behaviours attach as new ones, so
// they get awake, on_enable and start again. An instance whose entities the game despawned, or that a hot reload of
// the prefab made stale, is despawned and replaced by a new one. The scenes' assets and scripts are what it spawns
// with. Call it between frames or in a serial phase.
pool_spawn :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	guid: format.Guid,
	pose: ecs.Transform,
	owner: u32 = 0,
) -> (
	root: ecs.Entity,
	ok: bool,
) {
	root, _, ok = pool_spawn_pending(s, w, guid, pose, owner, nil)
	return
}

// pool_spawn_pending spawns as pool_spawn does, and with pending, collects the behaviours there instead of attaching
// them, as World.spawn's spawner does. message says why it could not.
@(private = "file")
pool_spawn_pending :: proc(
	s: ^Scenes,
	w: ^ecs.World,
	guid: format.Guid,
	pose: ecs.Transform,
	owner: u32,
	pending: ^[dynamic]script.Pending_Behaviour,
) -> (
	root: ecs.Entity,
	message: string,
	ok: bool,
) {
	follow_level(s)
	instance, kept := take_free(s, w, guid)
	reuse := &instance if kept else nil
	spawned: Spawned_Prefab
	spawned, message, ok = spawn_prefab_entities(
		w,
		s.scripts,
		s.assets,
		guid,
		pose,
		pending,
		reuse,
	)
	if !ok {
		if kept {
			// The prefab is gone, so its kept instance cannot come back.
			if ecs.is_alive(w, instance.root) {
				ecs.despawn(w, instance.root)
			}
			delete(instance.entities, s.platform.heap_allocator)
		}
		return 0, message, false
	}
	if kept && len(instance.entities) == len(spawned.entities) {
		copy(instance.entities, spawned.entities)
	} else {
		if kept {
			delete(instance.entities, s.platform.heap_allocator)
		}
		instance.entities = make([]ecs.Entity, len(spawned.entities), s.platform.heap_allocator)
		copy(instance.entities, spawned.entities)
		sweep_live(s, w)
	}
	instance.prefab, instance.version, instance.root = guid, spawned.version, spawned.root
	if owner != 0 {
		ecs.add(w, spawned.root, Scene_Owned{owner})
	} else if ecs.has(w, spawned.root, Scene_Owned) {
		ecs.remove(w, spawned.root, Scene_Owned)
	}
	s.pools.live[spawned.root] = instance
	return spawned.root, "", true
}

// pool_release takes an instance that pool_spawn gave out of the world and keeps it for the prefab's next pool_spawn,
// in place of despawning it. Its behaviours end, with on_disable and on_destroy before it returns, and its root becomes
// inactive, so systems and queries skip it. It belongs to no scene while it waits, so a scene or a sublevel that
// unloads does not take it, and the pool keeps it for the next spawn, which gives it that spawn's owner; only a level
// unload despawns it. Entities that the game put under it stay under it. It returns false, and does nothing, for an
// entity that is not the root of an instance that pool_spawn gave and that is in the world. Call it between frames or
// in a serial phase.
pool_release :: proc(s: ^Scenes, w: ^ecs.World, root: ecs.Entity) -> bool {
	follow_level(s)
	instance, found := s.pools.live[root]
	if !found {
		return false
	}
	delete_key(&s.pools.live, root)
	if !ecs.is_alive(w, root) {
		delete(instance.entities, s.platform.heap_allocator)
		return false
	}
	for e in instance.entities {
		if e != 0 && ecs.has_raw(w, e, script.BEHAVIOURS_ID) {
			ecs.remove_raw(w, e, script.BEHAVIOURS_ID)
		}
	}
	ecs.set_active(w, root, false)
	if ecs.has(w, root, Scene_Owned) {
		ecs.remove(w, root, Scene_Owned)
	}
	if s.scripts != nil {
		script.forget_despawned(s.scripts)
	}
	put_free(s, instance)
	return true
}

// pool_reserve spawns count instances of a prefab straight into its pool, inactive and with no behaviours attached,
// so a game can pay for them while a level loads rather than at its first spawns. It returns how many it made.
pool_reserve :: proc(s: ^Scenes, w: ^ecs.World, guid: format.Guid, count: int) -> int {
	follow_level(s)
	made := 0
	for _ in 0 ..< count {
		// The behaviours are collected and dropped: pool_spawn attaches them when it gives the instance out.
		pending := make([dynamic]script.Pending_Behaviour, w.platform.frame_allocator)
		spawned, _, ok := spawn_prefab_entities(
			w,
			s.scripts,
			s.assets,
			guid,
			ecs.TRANSFORM_IDENTITY,
			&pending,
		)
		if !ok {
			break
		}
		ecs.set_active(w, spawned.root, false)
		entities := make([]ecs.Entity, len(spawned.entities), s.platform.heap_allocator)
		copy(entities, spawned.entities)
		put_free(s, {guid, spawned.version, spawned.root, entities})
		made += 1
	}
	return made
}

// pool_count is how many instances of a prefab wait in its pool, including ones whose entities have gone since.
pool_count :: proc(s: ^Scenes, guid: format.Guid) -> int {
	if free, found := s.pools.free[guid]; found {
		return len(free)
	}
	return 0
}

// forget_despawned_pools drops the live instances whose root is gone, such as those that a script destroyed in place
// of releasing them. The game calls it with its other forget_despawned sweeps, and pool_spawn as the live map grows.
forget_despawned_pools :: proc(s: ^Scenes, w: ^ecs.World) {
	dead := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	for root in s.pools.live {
		if !ecs.is_alive(w, root) {
			append(&dead, root)
		}
	}
	for root in dead {
		delete(s.pools.live[root].entities, s.platform.heap_allocator)
		delete_key(&s.pools.live, root)
	}
}

// sweep_live drops dead live instances when the live map has doubled since the last sweep, so the cost spreads over
// the spawns that grew it.
@(private = "file")
sweep_live :: proc(s: ^Scenes, w: ^ecs.World) {
	if len(s.pools.live) < s.pools.sweep_at {
		return
	}
	forget_despawned_pools(s, w)
	s.pools.sweep_at = max(FIRST_SWEEP, 2 * len(s.pools.live))
}

// take_free takes a waiting instance of a prefab whose root is alive. Ones whose root went, with a scene that unloaded,
// are dropped on the way.
@(private = "file")
take_free :: proc(s: ^Scenes, w: ^ecs.World, guid: format.Guid) -> (Pooled_Instance, bool) {
	free, found := &s.pools.free[guid]
	if !found {
		return {}, false
	}
	for len(free) > 0 {
		instance := pop(free)
		if ecs.is_alive(w, instance.root) {
			return instance, true
		}
		delete(instance.entities, s.platform.heap_allocator)
	}
	return {}, false
}

@(private = "file")
put_free :: proc(s: ^Scenes, instance: Pooled_Instance) {
	free, found := &s.pools.free[instance.prefab]
	if !found {
		s.pools.free[instance.prefab] = make([dynamic]Pooled_Instance, s.platform.heap_allocator)
		free = &s.pools.free[instance.prefab]
	}
	append(free, instance)
}

@(private = "file")
POOL_REGISTRY_KEY :: "cinnabar.scene.pools"

// register_pool_scripts defines the Pool library, which reaches s (see docs/editor/prefabs.md#pooling). register_scripts
// calls it.
@(private)
register_pool_scripts :: proc(r: ^script.Runtime, s: ^Scenes) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, POOL_REGISTRY_KEY)
	script.define(r, "Pool.spawn", proc(L: ^luau.State) -> c.int {
			r, s := pools_of(L)
			guid := script.to_asset(r, L, 1)
			if guid == {} {
				script.raise(L, "Pool.spawn takes a prefab asset")
			}
			pose := ecs.TRANSFORM_IDENTITY
			if !luau.isnoneornil(L, 2) {
				pose.position = script.check_position(L, 2)
			}
			if !luau.isnoneornil(L, 3) {
				pose.rotation = script.check_quaternion(L, 3)
			}
			pending := make([dynamic]script.Pending_Behaviour, r.world.platform.frame_allocator)
			root, message, ok := pool_spawn_pending(s, r.world, guid, pose, 0, &pending)
			if !ok {
				script.raise(L, message)
			}
			script.wake_spawned(r, L, root, pending[:])
			script.push_entity(L, root)
			return 1
		}, "(prefab: Asset, position: WorldPosition?, rotation: Quaternion?) -> Entity")
	script.define(r, "Pool.release", proc(L: ^luau.State) -> c.int {
			r, s := pools_of(L)
			root := script.check_entity(L, 1)
			if !pool_release(s, r.world, root) {
				script.raise(
					L,
					fmt.aprintf(
						"%v is not the root of an instance that Pool.spawn gave and that is in the world",
						root,
						allocator = r.world.platform.frame_allocator,
					),
				)
			}
			return 0
		}, "(root: Entity) -> ()")
	script.define(r, "Pool.reserve", proc(L: ^luau.State) -> c.int {
			r, s := pools_of(L)
			guid := script.to_asset(r, L, 1)
			if guid == {} {
				script.raise(L, "Pool.reserve takes a prefab asset")
			}
			count := luau.L_checknumber(L, 2)
			if count < 0 || count != f64(int(count)) {
				script.raise(L, "Pool.reserve takes a count of instances")
			}
			luau.pushnumber(L, f64(pool_reserve(s, r.world, guid, int(count))))
			return 1
		}, "(prefab: Asset, count: number) -> number")
}

// pools_of is the runtime and the scenes of a Pool binding. It raises an error where pools do not work: without the
// scenes, and in the editor's Edit mode, where a behaviour's spawn is an edit of the document.
@(private = "file")
pools_of :: proc(L: ^luau.State) -> (^script.Runtime, ^Scenes) {
	r := script.runtime_of(L)
	luau.getfield(L, luau.REGISTRYINDEX, POOL_REGISTRY_KEY)
	s := (^Scenes)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	if s == nil || r.world == nil {
		script.raise(L, "Pool needs the scenes, which the game gives scene.register_scripts")
	}
	if script.writing(r) {
		script.raise(
			L,
			"Pool works in Play, not in the editor's Edit mode. Use World.spawn there.",
		)
	}
	return r, s
}
