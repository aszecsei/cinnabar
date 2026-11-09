package render

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import null "cinnabar:core/gpu/null"

@(test)
the_shading_stats_are_the_newest_copy_that_came_back :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		heap_allocator     = runtime.heap_allocator(),
		gpu_create_buffer  = null.create_buffer,
		gpu_destroy_buffer = null.destroy_buffer,
		gpu_read_buffer    = null.read_buffer,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	s := &r.view.shading
	defer shading_state_destroy(s, &platform)
	testing.expect(t, ensure_readback_ring(&s.stats_ring, &platform, SHADING_STATS_WORDS * 4, "test"))
	// A frame's copy, as its commit leaves the ring (see a_readback_ring_shows_what_the_frames_that_executed_copied).
	tally :: proc(s: ^Shading_State, quads, pixels: u32) {
		ring := &s.stats_ring
		data, _ := null.read_buffer(ring.copies[ring.next])
		words := mem.slice_data_cast([]u32, data)
		words[0], words[1] = quads, pixels
		mark_readback_copied(ring, ring.next)
	}
	tally(s, 20, 50)
	read_shading_stats(r, &r.view)
	testing.expect_value(t, shading_stats(r), Shading_Stats{forward_quads = 20, forward_pixels = 50})
	// A copy that has not come back keeps the stats.
	s.stats_ring.copied = true
	read_shading_stats(r, &r.view)
	testing.expect_value(t, shading_stats(r).forward_quads, 20)
	// A frame without the stats, or that did not execute, shows none.
	read_shading_stats(r, &r.view)
	testing.expect_value(t, shading_stats(r), Shading_Stats{})
}
