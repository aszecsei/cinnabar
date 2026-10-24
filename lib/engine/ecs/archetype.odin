package ecs

import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"

CHUNK_SIZE :: 16 * mem.Kilobyte
MAX_CHUNKS :: 1 << 18
MAX_ARCHETYPES :: 4096
MAX_ARCHETYPE_CHUNKS :: 1 << 16
MAX_ARCHETYPE_COMPONENTS :: 32

// The archetype with no components. reserve creates entities in it.
EMPTY_ARCHETYPE :: 0
NO_ARCHETYPE :: max(u32)

// A power of two, at most half full.
@(private)
ARCHETYPE_TABLE_SIZE :: 2 * MAX_ARCHETYPES
#assert(ARCHETYPE_TABLE_SIZE & (ARCHETYPE_TABLE_SIZE - 1) == 0)
@(private)
DIRECTORY_PAGE :: 4 * mem.Kilobyte
@(private)
NO_CHUNK :: max(u32)

// Archetype stores the entities that have one set of components. Its rows fill chunks of CHUNK_SIZE in order, and
// row r is in chunk r / capacity. A chunk is struct-of-arrays: the entity handles at offset 0, then one column per
// component. Removing a row moves the last row into its place.
Archetype :: struct {
	// Sorted, so each set of components has one archetype.
	ids:             [MAX_ARCHETYPE_COMPONENTS]Component_Id,
	sizes:           [MAX_ARCHETYPE_COMPONENTS]u32,
	// The byte offset of each column in a chunk.
	offsets:         [MAX_ARCHETYPE_COMPONENTS]u32,
	component_count: u32,
	// Rows per chunk.
	capacity:        u32,
	count:           u32,
	chunk_count:     u32,
	hash:            u64,
}

// Chunk_Pool hands out chunks by index. A free chunk holds the index of the next free chunk in its first bytes.
@(private)
Chunk_Pool :: struct {
	memory:    Region,
	// The chunks [0, used) were handed out at least once, so they are committed.
	used:      u32,
	free_head: u32,
}

archetype_components :: proc "contextless" (a: ^Archetype) -> []Component_Id {
	return a.ids[:a.component_count]
}

// add_raw adds a component, or overwrites it if the entity has it. A nil data zeroes the component. Otherwise data
// must be the component's size. It returns false if the entity is not alive or the component is not registered.
add_raw :: proc(w: ^World, e: Entity, id: Component_Id, data: []byte) -> bool {
	flush_reserved(w)
	record := live_record(w, e)
	if record == nil {
		return false
	}
	if id == PARENT_ID {
		w.hierarchy_dirty = true
	}
	if id == PARENT_ID || id == DISABLED_ID {
		w.activity_dirty = true
	}
	a := archetype(w, record.archetype)
	column, found := slice.binary_search(archetype_components(a), id)
	if !found {
		n := int(a.component_count)
		if n == MAX_ARCHETYPE_COMPONENTS {
			log.errorf("ecs: an entity cannot have more than %d components", MAX_ARCHETYPE_COMPONENTS)
			return false
		}
		ids: [MAX_ARCHETYPE_COMPONENTS]Component_Id
		copy(ids[:], a.ids[:column])
		ids[column] = id
		copy(ids[column + 1:], a.ids[column:n])
		target := find_or_create_archetype(w, ids[:n + 1])
		if target == NO_ARCHETYPE {
			return false
		}
		move_entity(w, record, target)
		a = archetype(w, target)
	}
	ptr := component_at(w, record.archetype, u32(column), record.row)
	size := int(a.sizes[column])
	if data == nil {
		mem.zero(ptr, size)
	} else {
		assert(len(data) == size, "ecs: component data has the wrong size")
		mem.copy(ptr, raw_data(data), size)
	}
	return true
}

// remove_raw removes a component. It returns false if the entity is not alive or does not have the component.
remove_raw :: proc(w: ^World, e: Entity, id: Component_Id) -> bool {
	flush_reserved(w)
	record := live_record(w, e)
	if record == nil {
		return false
	}
	a := archetype(w, record.archetype)
	column, found := slice.binary_search(archetype_components(a), id)
	if !found {
		return false
	}
	if id == PARENT_ID {
		w.hierarchy_dirty = true
	}
	if id == PARENT_ID || id == DISABLED_ID {
		w.activity_dirty = true
	}
	log_removal(w, e, record.archetype, u32(column))
	ids: [MAX_ARCHETYPE_COMPONENTS]Component_Id
	copy(ids[:], a.ids[:column])
	copy(ids[column:], a.ids[column + 1:a.component_count])
	target := find_or_create_archetype(w, ids[:a.component_count - 1])
	if target == NO_ARCHETYPE {
		return false
	}
	move_entity(w, record, target)
	return true
}

// get_raw returns a pointer to a component, or nil. The pointer is valid until the next structural change. It is
// safe to call from jobs while no structural change runs.
get_raw :: proc(w: ^World, e: Entity, id: Component_Id) -> rawptr {
	record := live_record(w, e)
	if record == nil {
		return nil
	}
	column, found := slice.binary_search(archetype_components(archetype(w, record.archetype)), id)
	if !found {
		return nil
	}
	return component_at(w, record.archetype, u32(column), record.row)
}

has_raw :: proc(w: ^World, e: Entity, id: Component_Id) -> bool {
	return get_raw(w, e, id) != nil
}

add :: proc(w: ^World, e: Entity, value: $T) -> bool {
	value := value
	info := registry_find_type(&w.registry, T)
	if info == nil {
		log.errorf("ecs: component %v is not registered", typeid_of(T))
		return false
	}
	return add_raw(w, e, info.id, mem.ptr_to_bytes(&value))
}

remove :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	info := registry_find_type(&w.registry, T)
	return info != nil && remove_raw(w, e, info.id)
}

// get returns a pointer to a component, or nil. See get_raw.
get :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	info := registry_find_type(&w.registry, T)
	return info != nil ? (^T)(get_raw(w, e, info.id)) : nil
}

has :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	return get(w, e, T) != nil
}

@(private)
archetype :: proc "contextless" (w: ^World, index: u32) -> ^Archetype {
	return &([^]Archetype)(w.archetypes.base)[index]
}

// find_or_create_archetype returns the archetype for a sorted set of registered components, or NO_ARCHETYPE.
@(private)
find_or_create_archetype :: proc(w: ^World, ids: []Component_Id) -> u32 {
	h := hash.fnv64a(slice.to_bytes(ids))
	table := ([^]u32)(w.archetype_table.base)
	slot := h & (ARCHETYPE_TABLE_SIZE - 1)
	for table[slot] != 0 {
		index := table[slot] - 1
		a := archetype(w, index)
		if a.hash == h && slice.equal(archetype_components(a), ids) {
			return index
		}
		slot = (slot + 1) & (ARCHETYPE_TABLE_SIZE - 1)
	}

	if w.archetype_count == MAX_ARCHETYPES {
		log.errorf("ecs: more than %d archetypes", MAX_ARCHETYPES)
		return NO_ARCHETYPE
	}
	created := Archetype {
		component_count = u32(len(ids)),
		hash            = h,
	}
	aligns: [MAX_ARCHETYPE_COMPONENTS]int
	row_size := size_of(Entity)
	for id, i in ids {
		info := registry_find(&w.registry, id)
		if info == nil {
			log.errorf("ecs: component %x is not registered", u64(id))
			return NO_ARCHETYPE
		}
		created.ids[i] = id
		created.sizes[i] = u32(info.size)
		aligns[i] = info.align
		row_size += info.size
	}
	// Alignment padding can push the first guess over the chunk size.
	capacity := CHUNK_SIZE / row_size
	for capacity > 0 && layout_columns(&created, aligns[:len(ids)], capacity) > CHUNK_SIZE {
		capacity -= 1
	}
	if capacity == 0 {
		log.errorf("ecs: the components of an archetype do not fit in a chunk")
		return NO_ARCHETYPE
	}
	created.capacity = u32(capacity)

	index := w.archetype_count
	if !region_commit(&w.archetypes, w.platform, int(index + 1) * size_of(Archetype)) {
		log.error("ecs: cannot commit an archetype")
		return NO_ARCHETYPE
	}
	archetype(w, index)^ = created
	table[slot] = index + 1
	w.archetype_count += 1
	match_new_archetype(w, index)
	return index
}

// layout_columns sets the column offsets for capacity rows and returns the bytes that they use.
@(private = "file")
layout_columns :: proc(a: ^Archetype, aligns: []int, capacity: int) -> int {
	offset := capacity * size_of(Entity)
	for align, i in aligns {
		offset = mem.align_forward_int(offset, align)
		a.offsets[i] = u32(offset)
		offset += int(a.sizes[i]) * capacity
	}
	return offset
}

@(private)
chunk_data :: proc "contextless" (w: ^World, chunk: u32) -> [^]byte {
	return w.chunks.memory.base[int(chunk) * CHUNK_SIZE:]
}

@(private)
chunk_directory :: proc "contextless" (w: ^World, index: u32) -> [^]u32 {
	return ([^]u32)(w.directory.base)[int(index) * MAX_ARCHETYPE_CHUNKS:]
}

@(private)
entity_at :: proc "contextless" (w: ^World, index: u32, row: u32) -> ^Entity {
	a := archetype(w, index)
	data := chunk_data(w, chunk_directory(w, index)[row / a.capacity])
	return &([^]Entity)(data)[row % a.capacity]
}

@(private)
component_at :: proc "contextless" (w: ^World, index: u32, column: u32, row: u32) -> rawptr {
	a := archetype(w, index)
	data := chunk_data(w, chunk_directory(w, index)[row / a.capacity])
	return &data[a.offsets[column] + row % a.capacity * a.sizes[column]]
}

// push_row adds a row for e at the end of an archetype and returns it. The component columns are not set.
@(private)
push_row :: proc(w: ^World, index: u32, e: Entity) -> u32 {
	a := archetype(w, index)
	if a.count == a.chunk_count * a.capacity {
		if a.chunk_count == MAX_ARCHETYPE_CHUNKS {
			log.panicf("ecs: an archetype has more than %d chunks", MAX_ARCHETYPE_CHUNKS)
		}
		directory := chunk_directory(w, index)
		if a.chunk_count * size_of(u32) % DIRECTORY_PAGE == 0 &&
		   !w.platform.memory_commit(&directory[a.chunk_count], DIRECTORY_PAGE) {
			panic("ecs: cannot commit a chunk directory")
		}
		directory[a.chunk_count] = chunk_alloc(w)
		a.chunk_count += 1
	}
	row := a.count
	a.count += 1
	entity_at(w, index, row)^ = e
	return row
}

// remove_row moves the last row into row, and frees the last chunk when it becomes empty.
@(private)
remove_row :: proc(w: ^World, index: u32, row: u32) {
	a := archetype(w, index)
	last := a.count - 1
	if row != last {
		moved := entity_at(w, index, last)^
		entity_at(w, index, row)^ = moved
		for column in 0 ..< a.component_count {
			mem.copy(component_at(w, index, column, row), component_at(w, index, column, last), int(a.sizes[column]))
		}
		records(w)[entity_index(moved)].row = row
	}
	a.count = last
	if a.count == (a.chunk_count - 1) * a.capacity {
		a.chunk_count -= 1
		chunk_free(w, chunk_directory(w, index)[a.chunk_count])
	}
}

// move_entity moves an entity's row to another archetype and copies the components that both have.
@(private)
move_entity :: proc(w: ^World, record: ^Entity_Record, target: u32) {
	source := record.archetype
	row := push_row(w, target, entity_at(w, source, record.row)^)
	from, to := archetype(w, source), archetype(w, target)
	i: u32
	for column in 0 ..< to.component_count {
		for i < from.component_count && from.ids[i] < to.ids[column] {
			i += 1
		}
		if i < from.component_count && from.ids[i] == to.ids[column] {
			mem.copy(component_at(w, target, column, row), component_at(w, source, i, record.row), int(to.sizes[column]))
		}
	}
	remove_row(w, source, record.row)
	record.archetype = target
	record.row = row
}

@(private = "file")
chunk_alloc :: proc(w: ^World) -> u32 {
	pool := &w.chunks
	if pool.free_head != NO_CHUNK {
		chunk := pool.free_head
		pool.free_head = (^u32)(chunk_data(w, chunk))^
		return chunk
	}
	if pool.used == MAX_CHUNKS || !region_commit(&pool.memory, w.platform, int(pool.used + 1) * CHUNK_SIZE) {
		panic("ecs: out of chunk memory")
	}
	pool.used += 1
	return pool.used - 1
}

@(private = "file")
chunk_free :: proc(w: ^World, chunk: u32) {
	(^u32)(chunk_data(w, chunk))^ = w.chunks.free_head
	w.chunks.free_head = chunk
}
