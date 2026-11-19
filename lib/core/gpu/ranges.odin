package gpu

import "base:runtime"

// Range is a free stretch of a Range_Allocator, in bytes from its start.
Range :: struct {
	offset: u64,
	size:   u64,
}

// Range_Allocator hands out aligned regions of a block of size bytes, such as a backend's heap that resources are placed
// in (see docs/gpu/resources-and-pipelines.md#memory). Its free list is sorted by offset, and a freed region merges with
// its free neighbours, so the list never holds two ranges that touch. An allocation takes the smallest free range that
// fits it. The allocator does not lock: its owner guards it.
Range_Allocator :: struct {
	size: u64,
	used: u64,
	free: [dynamic]Range,
}

range_init :: proc(a: ^Range_Allocator, size: u64, allocator := context.allocator) {
	a.size, a.used = size, 0
	a.free = make([dynamic]Range, allocator)
	if size > 0 {
		append(&a.free, Range{0, size})
	}
}

range_destroy :: proc(a: ^Range_Allocator) {
	delete(a.free)
	a^ = {}
}

// range_alloc returns the offset of size bytes aligned to align, a power of two, or false when no free range has room.
range_alloc :: proc(a: ^Range_Allocator, size, align: u64) -> (offset: u64, ok: bool) {
	assert(align > 0 && align & (align - 1) == 0, "gpu: a range's alignment is a power of two")
	if size == 0 {
		return 0, false
	}
	best := -1
	best_size: u64
	for r, i in a.free {
		start := runtime.align_forward_uint(uint(r.offset), uint(align))
		if u64(start) - r.offset + size <= r.size && (best < 0 || r.size < best_size) {
			best, best_size = i, r.size
		}
	}
	if best < 0 {
		return 0, false
	}
	r := a.free[best]
	offset = u64(runtime.align_forward_uint(uint(r.offset), uint(align)))
	front := Range{r.offset, offset - r.offset}
	back := Range{offset + size, r.offset + r.size - offset - size}
	// The range gives way to its padding and its tail, in order.
	switch {
	case front.size > 0 && back.size > 0:
		a.free[best] = front
		inject_at(&a.free, best + 1, back)
	case front.size > 0:
		a.free[best] = front
	case back.size > 0:
		a.free[best] = back
	case:
		ordered_remove(&a.free, best)
	}
	a.used += size
	return offset, true
}

// range_free returns a region that range_alloc gave, with the size it was asked for.
range_free :: proc(a: ^Range_Allocator, offset, size: u64) {
	assert(offset + size <= a.size, "gpu: a freed range is outside its allocator")
	// The first free range after the region.
	i := 0
	for i < len(a.free) && a.free[i].offset < offset {
		i += 1
	}
	assert(
		i == len(a.free) || offset + size <= a.free[i].offset,
		"gpu: a freed range overlaps a free one",
	)
	assert(
		i == 0 || a.free[i - 1].offset + a.free[i - 1].size <= offset,
		"gpu: a freed range overlaps a free one",
	)
	a.used -= size
	joins_before := i > 0 && a.free[i - 1].offset + a.free[i - 1].size == offset
	joins_after := i < len(a.free) && offset + size == a.free[i].offset
	switch {
	case joins_before && joins_after:
		a.free[i - 1].size += size + a.free[i].size
		ordered_remove(&a.free, i)
	case joins_before:
		a.free[i - 1].size += size
	case joins_after:
		a.free[i].offset = offset
		a.free[i].size += size
	case:
		inject_at(&a.free, i, Range{offset, size})
	}
}

// range_empty is true when every region has been freed.
range_empty :: proc(a: ^Range_Allocator) -> bool {
	return a.used == 0
}
