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

	// A frame's copy, as its commit leaves the ring (see a_readback_ring_shows_what_the_frames_that_executed_copied).
	tally :: proc(o: ^Occlusion, items: u32) {
		ring := &o.stats_ring
		data, _ := null.read_buffer(ring.copies[ring.next])
		mem.slice_data_cast([]u32, data)[0] = items
		mark_readback_copied(ring, ring.next)
	}
	tally(o, 7)
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r).early_items, 7)
	// A frame copied, but its copy is not back: the stats stay.
	o.stats_ring.copied = true
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r).early_items, 7)
	tally(o, 9)
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r).early_items, 9)
	// A frame that tallied nothing, or did not execute, shows none.
	read_cull_stats(r)
	testing.expect_value(t, cull_stats(r), Cull_Stats{})
}
