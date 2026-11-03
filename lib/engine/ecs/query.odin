package ecs

import "base:intrinsics"
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
	// An iteration with a version gives only the chunks where one of these terms' columns changed since it.
	changed:  bool,
}

@(private)
Term_Set :: bit_set[0 ..< MAX_QUERY_TERMS;u16]

// Chunk_View is one chunk of a query's results. Get its columns with column, in the order of the query's terms.
// It is valid until the next structural change.
Chunk_View :: struct {
	world:     ^World,
	archetype: ^Archetype,
	match:     ^Query_Match,
	chunk:     u32,
	data:      [^]byte,
	count:     int,
}

Query_Iterator :: struct {
	world:     ^World,
	query:     u32,
	match:     u32,
	chunk:     u32,
	remaining: int,
	since:     u64,
}

@(private)
Query_State :: struct {
	terms:       [MAX_QUERY_TERMS]Term,
	term_count:  u32,
	match_count: u32,
	// Which terms have Write access, and which have changed set.
	writes:      Term_Set,
	changes:     Term_Set,
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

// changed makes a term filter an iteration that has a version: it gives only the chunks where the column of one of
// the query's changed terms is newer than the version. A changed term with Write access stamps its own column, so
// every chunk it gives passes the filter the next time too.
changed :: proc(term: Term) -> Term {
	term := term
	term.changed = true
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
	for term, i in terms {
		if term.access == .Write {
			q.writes += {i}
		}
		if term.changed {
			q.changes += {i}
		}
	}
	w.query_count += 1
	for a in 0 ..< w.archetype_count {
		match_archetype(w, index, a)
	}
	return Query(index + 1)
}

// collect appends every entity that has all the components to out, in archetype order. Like a query, it skips
// Inactive entities unless ids names Inactive. It scans every archetype, so it is for occasional lookups, such as
// scripts' World.query, not for systems. With a version from take_version, it gives only the entities of the chunks
// where a column in ids changed since it.
collect :: proc(w: ^World, ids: []Component_Id, out: ^[dynamic]Entity, since: u64 = 0) {
	_, include_inactive := slice.linear_search(ids, INACTIVE_ID)
	outer: for index in 0 ..< w.archetype_count {
		a := archetype(w, index)
		components := archetype_components(a)
		if _, inactive := slice.binary_search(components, INACTIVE_ID); inactive && !include_inactive {
			continue
		}
		for id in ids {
			if _, found := slice.binary_search(components, id); !found {
				continue outer
			}
		}
		for first: u32 = 0; first < a.count; first += a.capacity {
			if since != 0 && !columns_changed(w, a, chunk_directory(w, index)[first / a.capacity], ids, since) {
				continue
			}
			for row in first ..< min(first + a.capacity, a.count) {
				append(out, entity_at(w, index, row)^)
			}
		}
	}
}

// take_version gives a version that every later write is newer than, for asking later what changed since now. Call it
// while no job runs.
take_version :: proc "contextless" (w: ^World) -> u64 {
	version := w.version
	w.version += 1
	return version
}

// query_iter iterates over count chunks of the results, from chunk first. Jobs can split the results into ranges
// of chunks this way. See query_chunk_count. With a version from take_version, it leaves out the chunks that the
// query's changed terms say did not change since it. These still count as chunks of the range, so ranges stay the
// same.
query_iter :: proc(w: ^World, q: Query, first := 0, count := max(int), since: u64 = 0) -> Query_Iterator {
	it := Query_Iterator {
		world     = w,
		query     = u32(q) - 1,
		remaining = count,
		since     = since,
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
	state := query_state(w, it.query)
	for it.remaining > 0 && it.match < state.match_count {
		match := &list[it.match]
		a := archetype(w, match.archetype)
		if it.chunk < a.chunk_count {
			chunk := chunk_directory(w, match.archetype)[it.chunk]
			index := it.chunk
			it.chunk += 1
			it.remaining -= 1
			if it.since != 0 && state.changes != {} && !terms_changed(w, match, state.changes, chunk, it.since) {
				continue
			}
			// A chunk's writers come through here, so this is where its columns count as written.
			for term in state.writes {
				if c := match.columns[term]; c != NO_COLUMN {
					stamp(w, chunk, int(c))
				}
			}
			view = {
				world     = w,
				archetype = a,
				match     = match,
				chunk     = chunk,
				data      = chunk_data(w, chunk),
				count     = int(min(a.capacity, a.count - index * a.capacity)),
			}
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

// changed_since is true if a term's column in a chunk is newer than a version from take_version, for code that visits
// every chunk but can skip some of its work. An optional term that the chunk does not have has not changed.
changed_since :: proc "contextless" (view: Chunk_View, term: int, since: u64) -> bool {
	c := view.match.columns[term]
	return c != NO_COLUMN && chunk_version(view.world, view.chunk, int(c)) > since
}

@(private)
chunk_versions :: proc "contextless" (w: ^World, chunk: u32) -> ^[CHUNK_VERSIONS]u64 {
	return &([^][CHUNK_VERSIONS]u64)(w.chunks.versions.base)[chunk]
}

@(private)
chunk_version :: proc "contextless" (w: ^World, chunk: u32, column: int) -> u64 {
	return intrinsics.atomic_load_explicit(&chunk_versions(w, chunk)[column], .Relaxed)
}

// stamp marks a chunk's column as written now. take_version runs only while no job does, so every job that stamps at
// the same time stamps the same value. Jobs of one system can share a chunk (see propagate), so it does not write what
// is already there, which would make them fight over the cache line.
@(private)
stamp :: proc "contextless" (w: ^World, chunk: u32, column: int) {
	version := &chunk_versions(w, chunk)[column]
	if intrinsics.atomic_load_explicit(version, .Relaxed) != w.version {
		intrinsics.atomic_store_explicit(version, w.version, .Relaxed)
	}
}

// stamp_chunk marks every column and the entity handles of a chunk as written now: a row was added or moved in.
@(private)
stamp_chunk :: proc "contextless" (w: ^World, a: ^Archetype, chunk: u32) {
	for column in 0 ..< int(a.component_count) {
		stamp(w, chunk, column)
	}
	stamp(w, chunk, ENTITY_COLUMN)
}

// columns_changed is true if the column of one of ids is newer than a version in a chunk of a.
@(private)
columns_changed :: proc "contextless" (w: ^World, a: ^Archetype, chunk: u32, ids: []Component_Id, since: u64) -> bool {
	for id in ids {
		for column in 0 ..< int(a.component_count) {
			if a.ids[column] == id && chunk_version(w, chunk, column) > since {
				return true
			}
		}
	}
	return false
}

@(private = "file")
terms_changed :: proc "contextless" (w: ^World, match: ^Query_Match, terms: Term_Set, chunk: u32, since: u64) -> bool {
	for term in terms {
		if c := match.columns[term]; c != NO_COLUMN && chunk_version(w, chunk, int(c)) > since {
			return true
		}
	}
	return false
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
	// An archetype of Inactive entities matches only a query that names Inactive.
	if _, inactive := slice.linear_search(ids, INACTIVE_ID); inactive {
		named := false
		for term in state.terms[:state.term_count] {
			named ||= term.id == INACTIVE_ID
		}
		if !named {
			return
		}
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
