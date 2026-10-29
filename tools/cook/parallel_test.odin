package cook

import "core:fmt"
import "core:sync"
import "core:testing"

@(test)
parallel_for_calls_each_index_once_and_keeps_what_the_calls_report :: proc(t: ^testing.T) {
	Work :: struct {
		calls:   [200]int,
		scratch: [200]Scratch,
		names:   [200]string,
	}
	work := new(Work)
	defer free(work)
	parallel_for(len(work.calls), work, proc(data: rawptr, index: int) {
		w := (^Work)(data)
		sync.atomic_add(&w.calls[index], 1)
		// In the thread's temp allocator, which it frees after the call: scratch_keep moves them into the scratch.
		w.names[index] = fmt.tprintf("job %d", index)
		if index % 7 == 0 {
			report_warning(&w.scratch[index].problems, w.names[index], 0, 0, "%d is a multiple of 7", index)
		}
		scratch_keep(&w.scratch[index], &w.names[index])
	})
	pass: Pass
	for calls, i in work.calls {
		testing.expect_value(t, calls, 1)
		testing.expect_value(t, work.names[i], fmt.tprintf("job %d", i))
		testing.expect(t, finish_job(.Cooked, &work.scratch[i], .Texture, &pass))
	}
	testing.expect_value(t, pass.cooked[.Texture], 200)
	// The problems join the pass's in the jobs' order, whichever thread ran each.
	testing.expect_value(t, len(pass.problems.list), 29)
	for p, i in pass.problems.list {
		testing.expect_value(t, p.file, fmt.tprintf("job %d", i * 7))
		testing.expect_value(t, p.text, fmt.tprintf("%d is a multiple of 7", i * 7))
	}
	testing.expect(t, !finish_job(.Failed, &Scratch{}, .Texture, &pass))
}
