package render

import "core:log"
import "core:math/linalg"

import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// The terms that every extractor adds before the caller's: Transform, then the optional Previous_Transform. The
// caller's terms start at this index in each chunk view.
EXTRACT_TERMS :: 2
// Chunks per extraction job.
EXTRACT_BATCH :: 8

// Extractor selects the entities to extract: every entity with a Transform that matches the extractor's terms.
// It is a registration, like a query: create it again in on_reload.
Extractor :: struct {
	query: ecs.Query,
}

// Extracted_Chunk is a chunk that extract wrote, and the index of its first entity's record.
Extracted_Chunk :: struct {
	view:  ecs.Chunk_View,
	first: int,
}

// extractor creates an extractor. It returns the zero Extractor if the query cannot be created.
extractor :: proc(w: ^ecs.World, with: []ecs.Term) -> Extractor {
	if len(with) > ecs.MAX_QUERY_TERMS - EXTRACT_TERMS {
		log.errorf("render: an extractor has more than %d terms", ecs.MAX_QUERY_TERMS - EXTRACT_TERMS)
		return {}
	}
	terms: [ecs.MAX_QUERY_TERMS]ecs.Term
	terms[0] = ecs.read(w, ecs.Transform)
	terms[1] = ecs.optional(ecs.read(w, ecs.Previous_Transform))
	copy(terms[EXTRACT_TERMS:], with)
	return {ecs.query(w, terms[:EXTRACT_TERMS + len(with)])}
}

// extract_count is the number of records that extract writes.
extract_count :: proc(w: ^ecs.World, ex: Extractor) -> int {
	return ecs.query_entity_count(w, ex.query)
}

// extract writes each entity's presented pose, relative to origin, as the 3x4 matrix that pose_rows gives. Record i
// starts at out[i * stride], and records are in query order. It returns each chunk with the index of its first
// record, so the caller can fill the rest of each record from its own columns. The chunks are processed in parallel
// jobs, and the result is in frame memory.
//
// Run it while no system or structural change runs. out must hold extract_count records.
extract :: proc(w: ^ecs.World, ex: Extractor, origin: ecs.World_Position, out: []byte, stride: int) -> []Extracted_Chunk {
	assert(stride >= size_of([3][4]f32) && stride % align_of(f32) == 0, "render: the extraction stride is too small")
	allocator := w.platform.frame_allocator
	chunks := make([dynamic]Extracted_Chunk, allocator)
	count := 0
	it := ecs.query_iter(w, ex.query)
	for view in ecs.query_next(&it) {
		append(&chunks, Extracted_Chunk{view, count})
		count += view.count
	}
	assert(len(out) >= count * stride, "render: the extraction output is too small")

	batches := make([]Extract_Batch, (len(chunks) + EXTRACT_BATCH - 1) / EXTRACT_BATCH, allocator)
	list := make([]jobs.Job, len(batches), allocator)
	for &b, i in batches {
		b = {
			chunks = chunks[i * EXTRACT_BATCH:][:min(EXTRACT_BATCH, len(chunks) - i * EXTRACT_BATCH)],
			origin = origin,
			alpha  = w.clock.alpha,
			out    = out,
			stride = stride,
		}
		list[i] = {extract_batch, &b}
	}
	counter: jobs.Counter
	w.platform.jobs_run(list, &counter)
	w.platform.jobs_wait(&counter)
	return chunks[:]
}

// pose_rows is a pose as the rows of a 3x4 matrix, relative to origin. Only the difference of two world positions
// reaches the GPU, so it is small and precise however far the pose is from the world origin.
pose_rows :: proc(pose: ecs.Transform, origin: ecs.World_Position) -> (rows: [3][4]f32) {
	m := linalg.matrix3_from_quaternion_f32(pose.rotation)
	offset := ecs.position_sub(pose.position, origin)
	for r in 0 ..< 3 {
		rows[r] = {m[r, 0] * pose.scale.x, m[r, 1] * pose.scale.y, m[r, 2] * pose.scale.z, offset[r]}
	}
	return
}

@(private = "file")
Extract_Batch :: struct {
	chunks: []Extracted_Chunk,
	origin: ecs.World_Position,
	alpha:  f32,
	out:    []byte,
	stride: int,
}

@(private = "file")
extract_batch :: proc(data: rawptr) {
	b := (^Extract_Batch)(data)
	for c in b.chunks {
		current := ecs.column(c.view, 0, ecs.Transform)
		previous := ecs.column(c.view, 1, ecs.Previous_Transform)
		for pose, i in current {
			presented := pose
			if previous != nil {
				presented = ecs.interpolate(ecs.Transform(previous[i]), pose, b.alpha)
			}
			(^[3][4]f32)(&b.out[(c.first + i) * b.stride])^ = pose_rows(presented, b.origin)
		}
	}
}
