package gpu

import "core:math/rand"
import "core:testing"

@(private = "file")
check_ranges :: proc(t: ^testing.T, a: ^Range_Allocator) {
	free: u64
	for r, i in a.free {
		testing.expect(t, r.size > 0, "a free range is empty")
		testing.expect(t, r.offset + r.size <= a.size, "a free range is outside the allocator")
		if i > 0 {
			before := a.free[i - 1]
			// Touching ranges would have merged.
			testing.expect(t, before.offset + before.size < r.offset, "free ranges touch or overlap")
		}
		free += r.size
	}
	testing.expect_value(t, a.used + free, a.size)
}

@(test)
ranges_allocate_until_full :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 4096)
	defer range_destroy(&a)
	for i in 0 ..< u64(4) {
		offset, ok := range_alloc(&a, 1024, 256)
		testing.expect(t, ok)
		testing.expect_value(t, offset, i * 1024)
	}
	_, ok := range_alloc(&a, 1, 1)
	testing.expect(t, !ok)
	testing.expect_value(t, len(a.free), 0)
	_, ok = range_alloc(&a, 0, 1)
	testing.expect(t, !ok)
	check_ranges(t, &a)
}

// The padding in front of an aligned region stays free, and a smaller region takes it.
@(test)
ranges_reuse_alignment_padding :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 1 << 20)
	defer range_destroy(&a)
	small, _ := range_alloc(&a, 4096, 4096)
	large, _ := range_alloc(&a, 65536, 65536)
	testing.expect_value(t, small, 0)
	testing.expect_value(t, large, 65536)
	check_ranges(t, &a)
	padding, ok := range_alloc(&a, 4096, 4096)
	testing.expect(t, ok)
	testing.expect_value(t, padding, 4096)
	check_ranges(t, &a)
}

@(test)
ranges_merge_on_free :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 5 * 1024)
	defer range_destroy(&a)
	offsets: [5]u64
	for &o in offsets {
		o, _ = range_alloc(&a, 1024, 1024)
	}
	// Alone, between two live regions.
	range_free(&a, offsets[1], 1024)
	testing.expect_value(t, len(a.free), 1)
	// Merges with the free range before it.
	range_free(&a, offsets[2], 1024)
	testing.expect_value(t, len(a.free), 1)
	testing.expect_value(t, a.free[0], Range{1024, 2048})
	// Merges with the free range after it.
	range_free(&a, offsets[0], 1024)
	testing.expect_value(t, a.free[0], Range{0, 3072})
	// The last region, then the one between two free ranges, which merges with both.
	range_free(&a, offsets[4], 1024)
	testing.expect_value(t, len(a.free), 2)
	range_free(&a, offsets[3], 1024)
	testing.expect_value(t, len(a.free), 1)
	testing.expect_value(t, a.free[0], Range{0, 5 * 1024})
	testing.expect(t, range_empty(&a))
	check_ranges(t, &a)
}

// A freed region is used again, and the smallest hole that fits is taken.
@(test)
ranges_reuse_the_best_fit :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 16 * 1024)
	defer range_destroy(&a)
	big, _ := range_alloc(&a, 4096, 1024)
	_, _ = range_alloc(&a, 1024, 1024)
	small, _ := range_alloc(&a, 2048, 1024)
	_, _ = range_alloc(&a, 1024, 1024)
	range_free(&a, big, 4096)
	range_free(&a, small, 2048)
	offset, ok := range_alloc(&a, 2048, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, offset, small)
	offset, ok = range_alloc(&a, 4096, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, offset, big)
	check_ranges(t, &a)
}

// Random allocations and frees keep the regions apart and the free list whole, and freeing every region empties it.
@(test)
ranges_survive_random_use :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 1 << 24)
	defer range_destroy(&a)
	live := make([dynamic]Range)
	defer delete(live)
	state := rand.create(102)
	context.random_generator = rand.default_random_generator(&state)
	for _ in 0 ..< 4000 {
		if len(live) > 0 && rand.int_max(3) == 0 {
			i := rand.int_max(len(live))
			range_free(&a, live[i].offset, live[i].size)
			unordered_remove(&live, i)
		} else {
			size := u64(rand.int_max(256 * 1024) + 1)
			align := u64(1) << uint(rand.int_max(17))
			if offset, ok := range_alloc(&a, size, align); ok {
				testing.expect_value(t, offset % align, 0)
				for r in live {
					testing.expect(
						t,
						offset + size <= r.offset || r.offset + r.size <= offset,
						"live regions overlap",
					)
				}
				append(&live, Range{offset, size})
			}
		}
	}
	check_ranges(t, &a)
	for r in live {
		range_free(&a, r.offset, r.size)
	}
	testing.expect(t, range_empty(&a))
	testing.expect_value(t, len(a.free), 1)
	testing.expect_value(t, a.free[0], Range{0, 1 << 24})
}
