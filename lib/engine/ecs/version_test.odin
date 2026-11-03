package ecs

import "core:sync"
import "core:testing"

import "cinnabar:core/jobs"

// fill spawns entities with Health until they fill count chunks of their archetype, and gives the first entity of each
// chunk, in the frame allocator.
@(private = "file")
fill :: proc(f: ^Fixture, count: int) -> []Entity {
	w := &f.world
	firsts := make([]Entity, count, f.platform.frame_allocator)
	first := spawn(w)
	add(w, first, Health{})
	firsts[0] = first
	a := archetype(w, records(w)[entity_index(first)].archetype)
	for row in 1 ..< u32(count) * a.capacity {
		e := spawn(w)
		add(w, e, Health{})
		if row % a.capacity == 0 {
			firsts[row / a.capacity] = e
		}
	}
	return firsts
}

// views is what an iteration gives.
@(private = "file")
views :: proc(w: ^World, q: Query, since: u64, first := 0, count := max(int)) -> (chunks: int, rows: int) {
	it := query_iter(w, q, first, count, since)
	for view in query_next(&it) {
		chunks += 1
		rows += view.count
	}
	return
}

@(private = "file")
chunk_of :: proc(w: ^World, e: Entity) -> u32 {
	record := records(w)[entity_index(e)]
	return chunk_directory(w, record.archetype)[record.row / archetype(w, record.archetype).capacity]
}

// A query skips the chunks that did not change, which is what its consumers come for.
@(test)
a_query_gives_only_the_chunks_that_changed :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	firsts := fill(f, 3)
	q := query(w, {changed(read(w, Health))})
	capacity := int(archetype(w, records(w)[entity_index(firsts[0])].archetype).capacity)

	since := take_version(w)
	chunks, _ := views(w, q, since)
	testing.expect_value(t, chunks, 0)
	// Without a version, a filter does nothing.
	chunks, _ = views(w, q, 0)
	testing.expect_value(t, chunks, 3)

	get_write(w, firsts[1], Health).value = 5
	rows: int
	chunks, rows = views(w, q, since)
	testing.expect_value(t, chunks, 1)
	testing.expect_value(t, rows, capacity)
	it := query_iter(w, q, since = since)
	view, ok := query_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, entities(view)[0], firsts[1])
	testing.expect_value(t, column(view, 0, Health)[0].value, 5)

	// A later version does not see the write. get does not count as one.
	since = take_version(w)
	testing.expect_value(t, get(w, firsts[1], Health).value, 5)
	chunks, _ = views(w, q, since)
	testing.expect_value(t, chunks, 0)
}

// Only a term that names write access counts, and only on the chunks that the iteration gives.
@(test)
write_terms_mark_their_columns_and_read_terms_do_not :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	e := spawn(w)
	add(w, e, Health{})
	add(w, e, Velocity{})
	health_changes := query(w, {changed(read(w, Health))})
	velocity_changes := query(w, {changed(read(w, Velocity))})

	since := take_version(w)
	reader := query_iter(w, query(w, {read(w, Health), read(w, Velocity)}))
	for _ in query_next(&reader) {}
	chunks, _ := views(w, health_changes, since)
	testing.expect_value(t, chunks, 0)

	writer := query_iter(w, query(w, {read(w, Health), write(w, Velocity)}))
	for _ in query_next(&writer) {}
	chunks, _ = views(w, health_changes, since)
	testing.expect_value(t, chunks, 0)
	chunks, _ = views(w, velocity_changes, since)
	testing.expect_value(t, chunks, 1)
}

// A term without a changed flag does not filter, and a chunk that a term's optional column is missing from has not
// changed by it.
@(test)
a_filter_reads_only_changed_terms :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	both := spawn(w)
	add(w, both, Health{})
	add(w, both, Velocity{})
	alone := spawn(w)
	add(w, alone, Health{})
	q := query(w, {read(w, Health), changed(optional(read(w, Velocity)))})

	since := take_version(w)
	get_write(w, alone, Health).value = 1
	get_write(w, both, Health).value = 1
	chunks, _ := views(w, q, since)
	testing.expect_value(t, chunks, 0)

	get_write(w, both, Velocity).value = 1
	chunks, _ = views(w, q, since)
	testing.expect_value(t, chunks, 1)
}

// The chunks that a filter leaves out still count, so jobs split the same chunks with a version as without.
@(test)
ranges_stay_the_same_under_a_filter :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	firsts := fill(f, 3)
	q := query(w, {changed(read(w, Health))})
	testing.expect_value(t, query_chunk_count(w, q), 3)

	since := take_version(w)
	get_write(w, firsts[2], Health).value = 1
	expected := [3]int{0, 0, 1}
	for want, chunk in expected {
		chunks, _ := views(w, q, since, chunk, 1)
		testing.expectf(t, chunks == want, "chunk %d: %d", chunk, chunks)
	}
	chunks, _ := views(w, q, since, 0, 2)
	testing.expect_value(t, chunks, 0)
}

// Each batch of a system marks the chunks that it runs over.
@(test)
a_system_marks_the_columns_that_it_writes :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	fill(f, 6)
	q := query(w, {changed(read(w, Health))})
	register_system(w, {
		name = "heal",
		stage = .Update,
		batch_chunks = 2,
		terms = {write(w, Health)},
		procedure = proc(ctx: ^System_Context) {
			it := query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
			for view in query_next(&it) {
				for &h in column(view, 0, Health) {
					h.value += 1
				}
			}
		},
	})
	since := take_version(w)
	run_stage(w, .Update, 0, nil)
	chunks, _ := views(w, q, since)
	testing.expect_value(t, chunks, 6)
}

// A row that arrives writes every column of its chunk, whoever else is in it.
@(test)
structural_changes_mark_the_chunks_they_write :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	firsts := fill(f, 3)
	q := query(w, {changed(read(w, Health))})

	// A new row goes in a new chunk.
	since := take_version(w)
	last := spawn(w)
	add(w, last, Health{})
	chunks, _ := views(w, q, since, 3, 1)
	testing.expect_value(t, chunks, 1)
	chunks, _ = views(w, q, since, 0, 3)
	testing.expect_value(t, chunks, 0)

	// The last row moves into a despawned row's place. Its old chunk is freed, and no other chunk changes.
	since = take_version(w)
	despawned := w.despawned
	testing.expect(t, despawn(w, firsts[0]))
	testing.expect_value(t, w.despawned, despawned + 1)
	chunks, _ = views(w, q, since)
	testing.expect_value(t, chunks, 1)
	chunks, _ = views(w, q, since, 0, 1)
	testing.expect_value(t, chunks, 1)

	// add_raw writes one column of an entity that has the component.
	since = take_version(w)
	add(w, firsts[1], Health{value = 3})
	chunks, _ = views(w, q, since)
	testing.expect_value(t, chunks, 1)
	chunks, _ = views(w, q, since, 1, 1)
	testing.expect_value(t, chunks, 1)
}

// The last row leaving changes no row that is left.
@(test)
removing_the_last_row_marks_nothing :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	a := spawn(w)
	add(w, a, Health{})
	b := spawn(w)
	add(w, b, Health{})
	q := query(w, {changed(read(w, Health))})

	since := take_version(w)
	testing.expect(t, despawn(w, b))
	chunks, _ := views(w, q, since)
	testing.expect_value(t, chunks, 0)
}

// A chunk goes back to the pool and comes out for an archetype with more columns, whose versions must all be new.
@(test)
a_reused_chunk_is_new_to_its_next_archetype :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	e := spawn(w)
	add(w, e, Health{})
	q := query(w, {changed(read(w, Health)), changed(read(w, Velocity))})
	used := w.chunks.used
	testing.expect(t, despawn(w, e))

	since := take_version(w)
	e = spawn(w)
	add(w, e, Velocity{})
	add(w, e, Health{})
	testing.expect_value(t, w.chunks.used, used)
	for version in chunk_versions(w, chunk_of(w, e))^ {
		testing.expect(t, version > since)
	}
	chunks, _ := views(w, q, since)
	testing.expect_value(t, chunks, 1)
}

// Propagation and the snapshot run every tick, so a world that does not move must not look changed.
@(test)
transforms_count_as_changed_only_when_they_change :: proc(t: ^testing.T) {
	sync.guard(&scheduler_lock)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	f := setup(t)
	defer teardown(f)
	w := &f.world
	parent := spawn(w)
	add(w, parent, TRANSFORM_IDENTITY)
	child := spawn(w)
	add(w, child, TRANSFORM_IDENTITY)
	add(w, child, LOCAL_TRANSFORM_IDENTITY)
	add(w, child, Parent{parent})
	add(w, child, Previous_Transform(TRANSFORM_IDENTITY))
	poses := query(w, {changed(read(w, Transform)), read(w, Parent)})
	previous := query(w, {changed(read(w, Previous_Transform))})
	update_transforms(w)
	snapshot_previous(w)

	since := take_version(w)
	update_transforms(w)
	snapshot_previous(w)
	chunks, _ := views(w, poses, since)
	testing.expect_value(t, chunks, 0)
	chunks, _ = views(w, previous, since)
	testing.expect_value(t, chunks, 0)

	get_write(w, parent, Transform).position = position_offset({}, {1, 0, 0})
	update_transforms(w)
	chunks, _ = views(w, poses, since)
	testing.expect_value(t, chunks, 1)
	testing.expect_value(t, get(w, child, Transform).position, position_offset({}, {1, 0, 0}))
	chunks, _ = views(w, previous, since)
	testing.expect_value(t, chunks, 0)

	// The snapshot copies a Transform that moved, and its version is older than what wrote the Transform.
	snapshot_previous(w)
	testing.expect_value(t, get(w, child, Previous_Transform).position, position_offset({}, {1, 0, 0}))
	chunks, _ = views(w, previous, since)
	testing.expect_value(t, chunks, 1)
	testing.expect(t, w.snapshot_version > since)
}

@(test)
teleport_marks_both_poses :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	e := spawn(w)
	add(w, e, TRANSFORM_IDENTITY)
	add(w, e, Previous_Transform(TRANSFORM_IDENTITY))
	poses := query(w, {changed(read(w, Transform))})
	previous := query(w, {changed(read(w, Previous_Transform))})

	since := take_version(w)
	testing.expect(t, teleport(w, e, TRANSFORM_IDENTITY))
	chunks, _ := views(w, poses, since)
	testing.expect_value(t, chunks, 1)
	chunks, _ = views(w, previous, since)
	testing.expect_value(t, chunks, 1)
}

// The tools' walk sees new rows whatever they have, and the columns that it names.
@(test)
the_world_iterator_skips_chunks_that_did_not_change :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	firsts := fill(f, 2)
	ids := []Component_Id{registry_find_type(&w.registry, Health).id}
	a := archetype(w, records(w)[entity_index(firsts[0])].archetype)

	count :: proc(w: ^World, since: u64, ids: []Component_Id) -> (n: u32) {
		it := world_iter_changed(w, since, ids)
		for _, _, _ in world_next(&it) {
			n += 1
		}
		return
	}
	since := take_version(w)
	testing.expect_value(t, count(w, since, ids), 0)
	// Every entity, at a version older than any.
	testing.expect_value(t, count(w, 0, ids), 2 * a.capacity)

	// A chunk of a column it does not name stays skipped.
	get_write(w, firsts[0], Health).value = 1
	testing.expect_value(t, count(w, since, nil), 0)
	testing.expect_value(t, count(w, since, ids), a.capacity)

	// An entity in the empty archetype has no column at all.
	since = take_version(w)
	empty := spawn(w)
	it := world_iter_changed(w, since, ids)
	e, _, components, ok := world_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, e, empty)
	testing.expect_value(t, len(components), 0)
	_, _, _, ok = world_next(&it)
	testing.expect(t, !ok)
}

@(test)
collect_gives_the_chunks_that_changed_since_a_version :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	w := &f.world
	firsts := fill(f, 2)
	ids := []Component_Id{registry_find_type(&w.registry, Health).id}
	a := archetype(w, records(w)[entity_index(firsts[0])].archetype)
	found := make([dynamic]Entity, f.platform.frame_allocator)

	collect(w, ids, &found)
	testing.expect_value(t, u32(len(found)), 2 * a.capacity)

	since := take_version(w)
	clear(&found)
	collect(w, ids, &found, since)
	testing.expect_value(t, len(found), 0)

	get_write(w, firsts[1], Health).value = 1
	collect(w, ids, &found, since)
	testing.expect_value(t, u32(len(found)), a.capacity)
	testing.expect_value(t, found[0], firsts[1])
}
