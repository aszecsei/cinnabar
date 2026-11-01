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
	s := &r.shading
	defer shading_destroy(s, &platform)
	for &b in s.stats_copies {
		b = platform.gpu_create_buffer({size = SHADING_STATS_WORDS * 4, usage = {.Readback}, label = "test"}, nil)
	}
	tally :: proc(s: ^Shading, i: int, quads, pixels: u32) {
		data, _ := null.read_buffer(s.stats_copies[i])
		words := mem.slice_data_cast([]u32, data)
		words[0], words[1] = quads, pixels
		s.stats_written[i] = true
	}
	// Two frames' copies, the older first: the newer is the one kept, and both are taken.
	s.stats_next = 1
	tally(s, 1, 10, 30)
	tally(s, 2, 20, 50)
	s.stats_next = 0
	read_shading_stats(r)
	testing.expect_value(t, shading_stats(r), Shading_Stats{forward_quads = 20, forward_pixels = 50})
	testing.expect(t, !s.stats_written[1] && !s.stats_written[2])
	// A copy that has not come back is kept for later.
	read_shading_stats(r)
	testing.expect_value(t, shading_stats(r).forward_quads, 20)
}
