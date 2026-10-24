package ecs

import "core:slice"
import "core:sync"

// Entity is a generational handle: the slot index in the low 32 bits and the generation in the high 32 bits.
// Generations start at 1, so the zero Entity is nil and is never alive.
Entity :: distinct u64

MAX_ENTITIES :: 1 << 24

entity_index :: proc "contextless" (e: Entity) -> u32 {
	return u32(e)
}

entity_generation :: proc "contextless" (e: Entity) -> u32 {
	return u32(e >> 32)
}

@(private)
make_entity :: proc "contextless" (index, generation: u32) -> Entity {
	return Entity(u64(generation) << 32 | u64(index))
}

@(private)
Entity_Record :: struct {
	generation: u32,
	// NO_ARCHETYPE while the slot is free, reserved or retired.
	archetype:  u32,
	row:        u32,
}

// Entities allocates slots. Destroyed slots go to a free list. reserve takes slots with one atomic, first from the
// end of the free list and then past count, so jobs can create handles while the world is read in parallel.
// flush_reserved then creates the reserved entities.
@(private)
Entities :: struct {
	records:     Region,
	// The slots [0, count) have records.
	count:       u32,
	free:        Region,
	free_count:  u32,
	// The free entries [0, free_cursor) are not reserved. Below zero, the slots [count, count - free_cursor) are
	// reserved too.
	free_cursor: i64,
}

// reserve gives a handle for a new entity. It is safe to call from jobs. The entity exists, with no components,
// after the next structural change or apply. It returns nil when the world is full.
//
// The index that a reservation gets depends on timing, so do not order or hash anything by handle value.
reserve :: proc "contextless" (w: ^World) -> Entity {
	es := &w.entities
	n := sync.atomic_sub(&es.free_cursor, 1)
	if n > 0 {
		index := free_list(w)[n - 1]
		return make_entity(index, records(w)[index].generation)
	}
	index := i64(es.count) - n
	if index >= MAX_ENTITIES {
		return 0
	}
	return make_entity(u32(index), 1)
}

// spawn creates an entity with no components.
spawn :: proc(w: ^World) -> Entity {
	e := reserve(w)
	flush_reserved(w)
	return e
}

// despawn destroys an entity, its components and its descendants. It returns false if the entity is not alive.
// To keep a child, remove its Parent first.
//
// Finding the descendants scans every child in the world, so despawn many entities with commands instead: apply
// scans once for all of them.
despawn :: proc(w: ^World, e: Entity) -> bool {
	flush_reserved(w)
	if !despawn_one(w, e) {
		return false
	}
	despawn_orphans(w)
	return true
}

// despawn_all despawns every entity. The next spawns take the freed slots from the lowest index up, so a world that is
// filled again, such as by a scene load, gets its handles in the order that it spawns them.
despawn_all :: proc(w: ^World) {
	flush_reserved(w)
	for index in 0 ..< w.entities.count {
		record := &records(w)[index]
		if record.archetype != NO_ARCHETYPE {
			despawn_one(w, make_entity(index, record.generation))
		}
	}
	// Every entity is gone, so no child is left for despawn_orphans to find.
	w.orphans_pending = false
	// reserve takes slots from the end of the free list.
	es := &w.entities
	slice.sort_by(free_list(w)[:es.free_count], proc(a, b: u32) -> bool {return a > b})
}

is_alive :: proc "contextless" (w: ^World, e: Entity) -> bool {
	return live_record(w, e) != nil
}

// despawn_one destroys one entity and leaves its children for despawn_orphans.
@(private)
despawn_one :: proc(w: ^World, e: Entity) -> bool {
	record := live_record(w, e)
	if record == nil {
		return false
	}
	// Any entity may be a parent.
	w.orphans_pending = true
	if _, child := column_index(archetype(w, record.archetype), PARENT_ID); child {
		w.hierarchy_dirty = true
	}
	log_despawn(w, e, record)
	remove_row(w, record.archetype, record.row)
	record.archetype = NO_ARCHETYPE
	if record.generation == max(u32) {
		// Retired: the slot is never reused, so no old handle can match it.
		return true
	}
	record.generation += 1
	es := &w.entities
	if !region_commit(&es.free, w.platform, int(es.free_count + 1) * size_of(u32)) {
		panic("ecs: cannot commit the free list")
	}
	free_list(w)[es.free_count] = entity_index(e)
	es.free_count += 1
	es.free_cursor = i64(es.free_count)
	return true
}

// despawn_orphans despawns every child whose parent is not alive, until none is left. Each pass removes at least
// one level of a despawned subtree.
@(private)
despawn_orphans :: proc(w: ^World) {
	if !w.orphans_pending {
		return
	}
	for despawned := true; despawned; {
		despawned = false
		for index in 0 ..< w.archetype_count {
			a := archetype(w, index)
			column := column_index(a, PARENT_ID) or_continue
			// Backward, because despawning a row moves the last row into it, and that row was already checked.
			for row := int(a.count) - 1; row >= 0; row -= 1 {
				parent := (^Parent)(component_at(w, index, column, u32(row)))
				if !is_alive(w, parent.entity) {
					despawn_one(w, entity_at(w, index, u32(row))^)
					despawned = true
				}
			}
		}
	}
	// despawn_one set it again for the orphans, whose children the passes above already handled.
	w.orphans_pending = false
}

@(private)
records :: proc "contextless" (w: ^World) -> [^]Entity_Record {
	return ([^]Entity_Record)(w.entities.records.base)
}

@(private)
free_list :: proc "contextless" (w: ^World) -> [^]u32 {
	return ([^]u32)(w.entities.free.base)
}

@(private)
live_record :: proc "contextless" (w: ^World, e: Entity) -> ^Entity_Record {
	index := entity_index(e)
	if index >= w.entities.count {
		return nil
	}
	record := &records(w)[index]
	if record.generation != entity_generation(e) || record.archetype == NO_ARCHETYPE {
		return nil
	}
	return record
}

// flush_reserved creates the entities that reserve handed out, in the empty archetype. Every structural change
// calls it first.
@(private)
flush_reserved :: proc(w: ^World) {
	es := &w.entities
	cursor := es.free_cursor
	if cursor == i64(es.free_count) {
		return
	}
	free := free_list(w)
	if cursor >= 0 {
		for i in cursor ..< i64(es.free_count) {
			place(w, free[i])
		}
		es.free_count = u32(cursor)
	} else {
		for i in 0 ..< es.free_count {
			place(w, free[i])
		}
		es.free_count = 0
		fresh := u32(min(-cursor, MAX_ENTITIES - i64(es.count)))
		if !region_commit(&es.records, w.platform, int(es.count + fresh) * size_of(Entity_Record)) {
			panic("ecs: cannot commit entity records")
		}
		for index in es.count ..< es.count + fresh {
			records(w)[index].generation = 1
			place(w, index)
		}
		es.count += fresh
	}
	es.free_cursor = i64(es.free_count)
}

@(private = "file")
place :: proc(w: ^World, index: u32) {
	record := &records(w)[index]
	record.archetype = EMPTY_ARCHETYPE
	record.row = push_row(w, EMPTY_ARCHETYPE, make_entity(index, record.generation))
}
