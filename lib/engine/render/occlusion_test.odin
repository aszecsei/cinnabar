package render

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import null "cinnabar:core/gpu/null"

@(test)
the_cull_stats_are_the_newest_copy_that_came_back :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		heap_allocator     = runtime.heap_allocator(),
		gpu_create_buffer  = null.create_buffer,
		gpu_destroy_buffer = null.destroy_buffer,
		gpu_read_buffer    = null.read_buffer,
		gpu_destroy_pipeline = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	o := &r.scene.occlusion
	testing.expect(t, ensure_cull_stats(r))
	defer occlusion_destroy(o, &platform)

	// Nothing written, nothing read.
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r), Cull_Stats{})

	// Two frames' copies, the older first: the newer is the one kept, and each is read once.
	tally :: proc(o: ^Occlusion, i: int, items: u32) {
		data, _ := null.read_buffer(o.stats_copies[i])
		mem.slice_data_cast([]u32, data)[0] = items
		o.stats_written[i] = true
	}
	o.stats_next = 1
	tally(o, 1, 5)
	tally(o, 2, 7)
	o.stats_next = 0
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r).early_items, 7)
	testing.expect(t, !o.stats_written[1] && !o.stats_written[2])
	tally(o, 0, 9)
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r).early_items, 9)
}
