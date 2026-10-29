package cook

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import si "core:sys/info"
import "core:thread"

import format "cinnabar:engine/asset/format"

// The memory that parallel_for allows each thread: a stage's 4096-texel texture takes about a gigabyte as it cooks, in
// floats with its mips, so a machine with less memory than threads runs fewer at once.
PARALLEL_THREAD_MEMORY :: 2 << 30

// Parallel_Work is a parallel_for's calls: each thread takes the next index until none is left.
@(private = "file")
Parallel_Work :: struct {
	count: int,
	next:  int,
	data:  rawptr,
	work:  proc(data: rawptr, index: int),
}

// parallel_for calls work with data and each index below count, on a thread for each of the CPU's, at most count and
// at most one for each PARALLEL_THREAD_MEMORY of the machine's memory, and returns once every call has returned. The
// calls take indices in order, so the costliest should come first. Each thread has its own temp allocator, which it
// frees after each call: what a call keeps belongs in memory that it allocates itself, as a Scratch. The calls must
// share nothing that they change.
parallel_for :: proc(count: int, data: rawptr, work: proc(data: rawptr, index: int)) {
	if count <= 0 {
		return
	}
	state := Parallel_Work{count, 0, data, work}
	worker :: proc(state: ^Parallel_Work) {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.temp_allocator = virtual.arena_allocator(&arena)
		for {
			i := sync.atomic_add(&state.next, 1)
			if i >= state.count {
				return
			}
			state.work(state.data, i)
			free_all(context.temp_allocator)
		}
	}
	thread_count := min(os.get_processor_core_count(), count)
	if ram, _, _, _, ok := si.ram_stats(); ok {
		thread_count = min(thread_count, int(ram / PARALLEL_THREAD_MEMORY))
	}
	threads := make([]^thread.Thread, max(thread_count, 1), context.temp_allocator)
	for &t in threads {
		t = thread.create_and_start_with_poly_data(&state, worker, context)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

// Cook_Result is what came of one job of a cook: it failed, its blob was up to date, or it cooked.
Cook_Result :: enum {
	Failed,
	Current,
	Cooked,
}

// Scratch is an arena for one sub-asset's cook, so its memory goes as soon as its blob is written. Problems reported
// inside it are copied out when it ends.
Scratch :: struct {
	arena:    virtual.Arena,
	outer:    runtime.Allocator,
	problems: Problems,
}

scratch_begin :: proc(s: ^Scratch, pass: ^Pass) {
	_ = virtual.arena_init_growing(&s.arena)
	s.outer = context.temp_allocator
	s.problems = Problems{log = pass.problems.log}
	context.temp_allocator = virtual.arena_allocator(&s.arena)
}

scratch_end :: proc(s: ^Scratch, pass: ^Pass) {
	context.temp_allocator = s.outer
	scratch_merge(s, pass)
}

// scratch_keep ends a parallel_for call's work: it copies the problems that the call reported, and the strings that
// it names, from its thread's temp allocator into the scratch, which the thread does not free.
scratch_keep :: proc(s: ^Scratch, keep: ..^string) {
	_ = virtual.arena_init_growing(&s.arena)
	allocator := virtual.arena_allocator(&s.arena)
	for k in keep {
		k^ = strings.clone(k^, allocator)
	}
	problems := s.problems.list
	s.problems.list = make([dynamic]Problem, 0, len(problems), allocator)
	for p in problems {
		append(&s.problems.list, Problem{strings.clone(p.file, allocator), p.line, p.column, p.error, strings.clone(p.text, allocator)})
	}
}

// scratch_merge copies a scratch's problems into the pass's, in the temp allocator, and frees the scratch.
scratch_merge :: proc(s: ^Scratch, pass: ^Pass) {
	if pass.problems.list == nil {
		pass.problems.list = make([dynamic]Problem, context.temp_allocator)
	}
	for p in s.problems.list {
		copied := p
		copied.file = strings.clone(p.file, context.temp_allocator)
		copied.text = strings.clone(p.text, context.temp_allocator)
		append(&pass.problems.list, copied)
	}
	virtual.arena_destroy(&s.arena)
}

// finish_job counts a job of a kind in the pass, moves its problems into the pass's and frees its scratch, on the
// thread that called parallel_for. It returns whether the job succeeded.
finish_job :: proc(result: Cook_Result, s: ^Scratch, kind: format.Asset_Kind, pass: ^Pass) -> bool {
	switch result {
	case .Failed:
	case .Current:
		pass.current[kind] += 1
	case .Cooked:
		pass.cooked[kind] += 1
	}
	scratch_merge(s, pass)
	return result != .Failed
}
