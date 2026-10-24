package ecs

import "core:log"
import "core:slice"

MAX_QUERIES :: 256
MAX_QUERY_TERMS :: 12

@(private)
NO_COLUMN :: max(u8)

// Query is a handle to a query in the world. Queries are registrations: reload clears them, and systems create them
// again in on_reload. The zero Query is nil.
Query :: distinct u32

Access :: enum u8 {
	Read,
	Write,
	// The entity must not have the component.
	Without,
}

Term :: struct {
	id:       Component_Id,
	access:   Access,
	// An optional term matches entities without the component too. Its column is then nil.
	optional: bool,
}

// Chunk_View is one chunk of a query's results. Get its columns with column, in the order of the query's terms.
// It is valid until the next structural change.
Chunk_View :: struct {
	world:     ^World,
	archetype: ^Archetype,
	match:     ^Query_Match,
	data:      [^]byte,
	count:     int,
}

Query_Iterator :: struct {
	world:     ^World,
	query:     u32,
	match:     u32,
	chunk:     u32,
	remaining: int,
}

@(private)
Query_State :: struct {
	terms:       [MAX_QUERY_TERMS]Term,
	term_count:  u32,
	match_count: u32,
}

// Query_Match is an archetype that a query matches, and the column of each term in it.
@(private)
Query_Match :: struct {
	archetype: u32,
	columns:   [MAX_QUERY_TERMS]u8,
}

read :: proc(w: ^World, $T: typeid) -> Term {
	return {id = type_component(w, T), access = .Read}
}

write :: proc(w: ^World, $T: typeid) -> Term {
	return {id = type_component(w, T), access = .Write}
}

without :: proc(w: ^World, $T: typeid) -> Term {
	return {id = type_component(w, T), access = .Without}
}

optional :: proc(term: Term) -> Term {
	term := term
	term.optional = true
	return term
}

// query creates a query. It returns nil if a term's component is not registered.
query :: proc(w: ^World, terms: []Term) -> Query {
	if len(terms) > MAX_QUERY_TERMS {
		log.errorf("ecs: a query has more than %d terms", MAX_QUERY_TERMS)
		return 0
	}
	for term in terms {
		if registry_find(&w.registry, term.id) == nil {
			log.errorf("ecs: query component %x is not registered", u64(term.id))
			return 0
		}
	}
	if w.query_count == MAX_QUERIES ||
	   !region_commit(&w.queries, w.platform, int(w.query_count + 1) * size_of(Query_State)) {
		log.errorf("ecs: cannot create more than %d queries", w.query_count)
		return 0
	}
	index := w.query_count
	q := query_state(w, index)
	q^ = {
		term_count = u32(len(terms)),
	}
	copy(q.terms[:], terms)
	w.query_count += 1
	for a in 0 ..< w.archetype_count {
		match_archetype(w, index, a)
	}
	return Query(index + 1)
}

// collect appends every entity that has all the components to out, in archetype order. It scans every archetype,
// so it is for occasional lookups, such as scripts' World.query, not for systems.
collect :: proc(w: ^World, ids: []Component_Id, out: ^[dynamic]Entity) {
	outer: for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		components := archetype_components(a)
		for id in ids {
			if _, found := slice.binary_search(components, id); !found {
				continue outer
			}
		}
		for row in 0 ..< a.count {
			append(out, entity_at(w, index, row)^)
		}
	}
}

// query_iter iterates over count chunks of the results, from chunk first. Jobs can split the results into ranges
// of chunks this way. See query_chunk_count.
query_iter :: proc(w: ^World, q: Query, first := 0, count := max(int)) -> Query_Iterator {
	it := Query_Iterator {
		world     = w,
		query     = u32(q) - 1,
		remaining = count,
	}
	list := matches(w, it.query)
	skip := first
	for ; it.match < query_state(w, it.query).match_count; it.match += 1 {
		chunks := int(archetype(w, list[it.match].archetype).chunk_count)
		if skip < chunks {
			it.chunk = u32(skip)
			break
		}
		skip -= chunks
	}
	return it
}

query_next :: proc(it: ^Query_Iterator) -> (view: Chunk_View, ok: bool) {
	w := it.world
	list := matches(w, it.query)
	match_count := query_state(w, it.query).match_count
	for it.remaining > 0 && it.match < match_count {
		match := &list[it.match]
		a := archetype(w, match.archetype)
		if it.chunk < a.chunk_count {
			view = {
				world     = w,
				archetype = a,
				match     = match,
				data      = chunk_data(w, chunk_directory(w, match.archetype)[it.chunk]),
				count     = int(min(a.capacity, a.count - it.chunk * a.capacity)),
			}
			it.chunk += 1
			it.remaining -= 1
			return view, true
		}
		it.match += 1
		it.chunk = 0
	}
	return {}, false
}

query_chunk_count :: proc(w: ^World, q: Query) -> (count: int) {
	index := u32(q) - 1
	for match in matches(w, index)[:query_state(w, index).match_count] {
		count += int(archetype(w, match.archetype).chunk_count)
	}
	return
}

query_entity_count :: proc(w: ^World, q: Query) -> (count: int) {
	index := u32(q) - 1
	for match in matches(w, index)[:query_state(w, index).match_count] {
		count += int(archetype(w, match.archetype).count)
	}
	return
}

// column returns the column of a term in a chunk, or nil for an optional term that the chunk does not have.
column :: proc(view: Chunk_View, term: int, $T: typeid) -> []T {
	c := view.match.columns[term]
	if c == NO_COLUMN {
		return nil
	}
	a := view.archetype
	assert(int(a.sizes[c]) == size_of(T), "ecs: the column type has the wrong size")
	when ODIN_DEBUG {
		info := registry_find_type(&view.world.registry, T)
		assert(info != nil && info.id == a.ids[c], "ecs: the column type differs from the term")
	}
	return ([^]T)(&view.data[a.offsets[c]])[:view.count]
}

entities :: proc "contextless" (view: Chunk_View) -> []Entity {
	return ([^]Entity)(view.data)[:view.count]
}

// match_new_archetype adds a new archetype to every query that matches it.
@(private)
match_new_archetype :: proc(w: ^World, a: u32) {
	for q in 0 ..< w.query_count {
		match_archetype(w, q, a)
	}
}

@(private)
type_component :: proc(w: ^World, T: typeid) -> Component_Id {
	info := registry_find_type(&w.registry, T)
	if info == nil {
		log.errorf("ecs: component %v is not registered", T)
		return 0
	}
	return info.id
}

@(private = "file")
match_archetype :: proc(w: ^World, q: u32, a: u32) {
	state := query_state(w, q)
	ids := archetype_components(archetype(w, a))
	match := Query_Match {
		archetype = a,
	}
	for term, i in state.terms[:state.term_count] {
		column := NO_COLUMN
		for id, c in ids {
			if id == term.id {
				column = u8(c)
				break
			}
		}
		switch {
		case term.access == .Without && column != NO_COLUMN:
			return
		case term.access != .Without && column == NO_COLUMN && !term.optional:
			return
		}
		match.columns[i] = column
	}
	list := matches(w, q)
	if state.match_count * size_of(Query_Match) % DIRECTORY_PAGE == 0 &&
	   !w.platform.memory_commit(&list[state.match_count], DIRECTORY_PAGE) {
		panic("ecs: cannot commit query matches")
	}
	list[state.match_count] = match
	state.match_count += 1
}

@(private = "file")
query_state :: proc "contextless" (w: ^World, index: u32) -> ^Query_State {
	return &([^]Query_State)(w.queries.base)[index]
}

@(private = "file")
matches :: proc "contextless" (w: ^World, index: u32) -> [^]Query_Match {
	return ([^]Query_Match)(w.matches.base)[int(index) * MAX_ARCHETYPES:]
}
