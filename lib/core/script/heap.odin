package script_host

import "base:runtime"
import "core:mem"
import "core:mem/tlsf"
import "core:mem/virtual"

// The heap's address space. Only what the VM uses is committed.
HEAP_RESERVE :: 4 * mem.Gigabyte
// TLSF grows in pools of this size, and serves every block up to LARGE_BLOCK.
POOL_SIZE :: 8 * mem.Megabyte
// Larger blocks get their own virtual memory, so a pool never has to hold one.
LARGE_BLOCK :: 1 * mem.Megabyte
HEAP_ALIGN :: 16

// Heap is the allocator of one VM. Luau keeps small objects in its own size-class pages, so most requests here are
// pages and large arrays. Everything that Heap allocates is host memory, so it survives a code reload.
@(private)
Heap :: struct {
	ctx:   runtime.Context,
	pools: virtual.Arena,
	tlsf:  tlsf.Allocator,
	large: ^Large_Block,
	// Bytes that the VM holds, for statistics.
	bytes: int,
}

// Large_Block precedes each large block, so close can release the ones that the VM did not free.
@(private)
Large_Block :: struct #align (HEAP_ALIGN) {
	next, prev: ^Large_Block,
	size:       int,
}

@(private)
heap_init :: proc(h: ^Heap) -> bool {
	h.ctx = runtime.default_context()
	if virtual.arena_init_static(&h.pools, HEAP_RESERVE) != nil {
		return false
	}
	if tlsf.init_from_allocator(&h.tlsf, virtual.arena_allocator(&h.pools), POOL_SIZE, POOL_SIZE) != .None {
		virtual.arena_destroy(&h.pools)
		return false
	}
	return true
}

@(private)
heap_destroy :: proc(h: ^Heap) {
	context = h.ctx
	for block := h.large; block != nil; {
		next := block.next
		virtual.release(block, uint(size_of(Large_Block) + block.size))
		block = next
	}
	// The pools and TLSF's own records are all in the arena.
	virtual.arena_destroy(&h.pools)
	h^ = {}
}

// heap_alloc is the VM's lua_Alloc. Luau passes the true old size of every block, so the size tells which kind of
// block it is.
@(private)
heap_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	h := (^Heap)(ud)
	context = h.ctx
	old, new := ptr == nil ? 0 : int(osize), int(nsize)
	result: rawptr
	switch {
	case new == 0:
		heap_free(h, ptr, old)
	case old <= LARGE_BLOCK && new <= LARGE_BLOCK:
		mode: runtime.Allocator_Mode = ptr == nil ? .Alloc_Non_Zeroed : .Resize_Non_Zeroed
		data, err := tlsf.allocator_proc(&h.tlsf, mode, new, HEAP_ALIGN, ptr, old)
		if err != nil {
			return nil
		}
		result = raw_data(data)
	case:
		// One side is large, so the block moves. Luau treats nil as out of memory and keeps the old block.
		result = heap_alloc_fresh(h, new)
		if result == nil {
			return nil
		}
		if ptr != nil {
			mem.copy_non_overlapping(result, ptr, min(old, new))
			heap_free(h, ptr, old)
		}
	}
	h.bytes += new - old
	return result
}

@(private = "file")
heap_alloc_fresh :: proc(h: ^Heap, size: int) -> rawptr {
	if size <= LARGE_BLOCK {
		data, err := tlsf.allocator_proc(&h.tlsf, .Alloc_Non_Zeroed, size, HEAP_ALIGN, nil, 0)
		return err == nil ? raw_data(data) : nil
	}
	data, err := virtual.reserve_and_commit(uint(size_of(Large_Block) + size))
	if err != nil {
		return nil
	}
	block := (^Large_Block)(raw_data(data))
	block^ = {
		next = h.large,
		size = size,
	}
	if h.large != nil {
		h.large.prev = block
	}
	h.large = block
	return mem.ptr_offset(block, 1)
}

@(private = "file")
heap_free :: proc(h: ^Heap, ptr: rawptr, size: int) {
	if ptr == nil {
		return
	}
	if size <= LARGE_BLOCK {
		tlsf.allocator_proc(&h.tlsf, .Free, 0, 0, ptr, size)
		return
	}
	block := mem.ptr_offset((^Large_Block)(ptr), -1)
	if block.prev != nil {
		block.prev.next = block.next
	} else {
		h.large = block.next
	}
	if block.next != nil {
		block.next.prev = block.prev
	}
	virtual.release(block, uint(size_of(Large_Block) + block.size))
}
