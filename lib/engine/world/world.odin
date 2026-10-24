package world

import "core:log"
import "core:mem"

import "cinnabar:core"

// Commits grow in steps of this size, so growth makes few calls into core.
@(private)
COMMIT_STEP :: 1 * mem.Megabyte

// World is the root of the ECS. It lives in Game_State. All its storage is in virtual memory reservations that never
// move, so it holds no allocators, and every handle and row index stays valid across a code reload.
World :: struct {
	platform:        ^core.Platform_API,
	registry:        Registry,
	entities:        Entities,
	archetypes:      Region,
	archetype_count: u32,
	// Open addressing from a component set's hash to an archetype index plus one. Zero is an empty slot.
	archetype_table: Region,
	// MAX_ARCHETYPE_CHUNKS chunk indices for each archetype, committed one page at a time.
	directory:       Region,
	chunks:          Chunk_Pool,
	queries:         Region,
	query_count:     u32,
	// MAX_ARCHETYPES matches for each query, committed one page at a time.
	matches:         Region,
	schedule:        Schedule,
	clock:           Clock,
	// Every child, sorted by depth. See rebuild_hierarchy.
	hierarchy:       Region,
	levels:          [MAX_HIERARCHY_DEPTH + 1]u32,
	// Set when a Parent is added or removed, or a child is despawned.
	hierarchy_dirty: bool,
}

// init reserves the world's storage and creates the empty archetype. Register the components after it.
init :: proc(w: ^World, platform: ^core.Platform_API) -> bool {
	w^ = {
		platform = platform,
		clock = {tick_rate = DEFAULT_TICK_RATE},
	}
	ok :=
		region_init(&w.entities.records, platform, MAX_ENTITIES * size_of(Entity_Record)) &&
		region_init(&w.entities.free, platform, MAX_ENTITIES * size_of(u32)) &&
		region_init(&w.archetypes, platform, MAX_ARCHETYPES * size_of(Archetype)) &&
		region_init(&w.archetype_table, platform, ARCHETYPE_TABLE_SIZE * size_of(u32)) &&
		region_commit(&w.archetype_table, platform, ARCHETYPE_TABLE_SIZE * size_of(u32)) &&
		region_init(&w.directory, platform, MAX_ARCHETYPES * MAX_ARCHETYPE_CHUNKS * size_of(u32)) &&
		region_init(&w.chunks.memory, platform, MAX_CHUNKS * CHUNK_SIZE) &&
		region_init(&w.queries, platform, MAX_QUERIES * size_of(Query_State)) &&
		region_init(&w.matches, platform, MAX_QUERIES * MAX_ARCHETYPES * size_of(Query_Match)) &&
		region_init(&w.hierarchy, platform, MAX_ENTITIES * size_of(Entity))
	w.chunks.free_head = NO_CHUNK
	if !ok || find_or_create_archetype(w, {}) != EMPTY_ARCHETYPE {
		log.error("world: cannot reserve storage")
		destroy(w)
		return false
	}
	return true
}

// destroy releases the world's storage. Every handle becomes invalid.
destroy :: proc(w: ^World) {
	for r in ([]^Region{&w.entities.records, &w.entities.free, &w.archetypes, &w.archetype_table, &w.directory, &w.chunks.memory, &w.queries, &w.matches, &w.hierarchy}) {
		region_release(r, w.platform)
	}
	w^ = {}
}

// reload starts a new registry after a code reload, and clears the queries and systems. Register every component,
// query and system again before the world is used.
reload :: proc(w: ^World, platform: ^core.Platform_API) {
	w.platform = platform
	w.registry = {}
	w.query_count = 0
	reset_schedule(w)
}

// Region is a range of reserved virtual memory with a committed prefix.
@(private)
Region :: struct {
	base:      [^]byte,
	reserved:  int,
	committed: int,
}

@(private)
region_init :: proc(r: ^Region, platform: ^core.Platform_API, size: int) -> bool {
	r^ = {
		base     = ([^]byte)(platform.memory_reserve(size)),
		reserved = size,
	}
	return r.base != nil
}

// region_commit makes the first size bytes usable.
@(private)
region_commit :: proc(r: ^Region, platform: ^core.Platform_API, size: int) -> bool {
	if size <= r.committed {
		return true
	}
	if size > r.reserved {
		return false
	}
	target := min(mem.align_forward_int(size, COMMIT_STEP), r.reserved)
	if !platform.memory_commit(&r.base[r.committed], target - r.committed) {
		return false
	}
	r.committed = target
	return true
}

@(private)
region_release :: proc(r: ^Region, platform: ^core.Platform_API) {
	if r.base != nil {
		platform.memory_release(r.base, r.reserved)
	}
	r^ = {}
}
