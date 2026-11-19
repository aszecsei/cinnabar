package gpu_d3d12

import "core:fmt"
import "core:log"
import "core:sync"

import win "core:sys/windows"
import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// Buffers, acceleration structures and textures that are only sampled are placed in large heaps instead of each
// being a committed resource with a heap of its own (see docs/gpu/resources-and-pipelines.md#memory). Textures and
// buffers go in heaps of their own kind, which every resource heap tier allows.
@(private)
Heap_Kind :: enum u8 {
	Buffers,
	Textures,
}

// Each heap is this large. A heap is created when no heap of its kind has room, and released when its last
// resource is, unless it is the last of its kind.
@(private)
HEAP_BLOCK_SIZE :: 256 << 20

// A larger resource is committed, so that one resource does not take most of a heap.
@(private)
PLACED_MAX :: HEAP_BLOCK_SIZE / 4

// D3D12_SMALL_RESOURCE_PLACEMENT_ALIGNMENT and D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT, which vendor:directx/d3d12
// does not name.
@(private = "file")
SMALL_ALIGNMENT :: 4096
@(private = "file")
DEFAULT_ALIGNMENT :: 65536

@(private)
Heap_Block :: struct {
	heap:   ^d3d.IHeap,
	ranges: gpu.Range_Allocator,
}

// Placement is a placed resource's region of a heap. A committed resource has none.
@(private)
Placement :: struct {
	kind:   Heap_Kind,
	block:  ^Heap_Block,
	offset: u64,
	size:   u64,
}

@(private)
Heaps :: struct {
	// Each block is allocated on its own, so a Placement's pointer stays valid while blocks come and go.
	blocks:      [Heap_Kind][dynamic]^Heap_Block,
	// Guards the blocks and their ranges. Resources are created from jobs.
	heaps_mutex: sync.Mutex,
}

@(private)
init_heaps :: proc() {
	for &blocks in dev.blocks {
		blocks = make([dynamic]^Heap_Block, dev.allocator)
	}
}

// shutdown_heaps releases the heaps. Every placed resource must be released first.
@(private)
shutdown_heaps :: proc() {
	for &blocks in dev.blocks {
		for block in blocks {
			assert(
				gpu.range_empty(&block.ranges),
				"d3d12: a heap is released before its resources",
			)
			destroy_block(block)
		}
		delete(blocks)
	}
}

// create_resource creates a resource in the default heap: placed in a heap of its kind when it fits, or committed
// when it is too large or no heap can be made. A small texture, which fits_small_alignment says, takes the small
// alignment where the device allows it.
@(private)
create_resource :: proc(
	desc: ^d3d.RESOURCE_DESC1,
	layout: d3d.BARRIER_LAYOUT,
	kind: Heap_Kind,
	what: string,
	label: string,
	small := false,
) -> (
	resource: ^d3d.IResource,
	placement: Maybe(Placement),
	ok: bool,
) {
	info := allocation_info(desc, small)
	if info.SizeInBytes <= PLACED_MAX {
		placement = place(kind, info.SizeInBytes, info.Alignment)
	}
	if p, placed := placement.?; placed {
		hr := dev.device->CreatePlacedResource2(
			p.block.heap,
			p.offset,
			desc,
			layout,
			nil,
			0,
			nil,
			d3d.IResource_UUID,
			(^rawptr)(&resource),
		)
		if win.FAILED(hr) {
			check(hr, fmt.tprintf("CreatePlacedResource2(%s)", what))
			free_placement(&placement)
			return nil, nil, false
		}
	} else {
		desc.Alignment = 0
		heap_props := d3d.HEAP_PROPERTIES {
			Type = .DEFAULT,
		}
		hr := dev.device->CreateCommittedResource3(
			&heap_props,
			{},
			desc,
			layout,
			nil,
			nil,
			0,
			nil,
			d3d.IResource_UUID,
			(^rawptr)(&resource),
		)
		if win.FAILED(hr) {
			check(hr, fmt.tprintf("CreateCommittedResource3(%s)", what))
			return nil, nil, false
		}
	}
	set_name(resource, label)
	return resource, placement, true
}

// release_resource releases a resource now and returns its region to its heap. Deferred destruction calls it once the
// GPU no longer uses the resource.
@(private)
release_resource :: proc(resource: ^^d3d.IResource, placement: ^Maybe(Placement)) {
	release(resource)
	free_placement(placement)
}

// memory_stats is the memory of the heaps, and the part of it that placed resources take.
@(private)
memory_stats :: proc() -> (heap_memory, resource_memory: u64) {
	sync.guard(&dev.heaps_mutex)
	for blocks in dev.blocks {
		for block in blocks {
			heap_memory += block.ranges.size
			resource_memory += block.ranges.used
		}
	}
	return
}

// fits_small_alignment is true when a 2D texture's most detailed mip, every layer of it, takes at most 16 of the 4 KB
// tiles, which D3D12 needs for the small alignment. A tile is 4 KB of texels, or of blocks for a block-compressed
// format, in the standard shape for their size.
@(private)
fits_small_alignment :: proc(desc: gpu.Texture_Desc) -> bool {
	if desc.depth > 0 {
		return false
	}
	tile: [2]u32
	switch gpu.format_size(desc.format) {
	case 1:
		tile = {64, 64}
	case 2:
		tile = {64, 32}
	case 4:
		tile = {32, 32}
	case 8:
		tile = {32, 16}
	case 16:
		tile = {16, 16}
	case:
		return false
	}
	size := desc.size
	if gpu.is_block_format(desc.format) {
		size = (size + 3) / 4
	}
	tiles :=
		(size.x + tile.x - 1) / tile.x * ((size.y + tile.y - 1) / tile.y) * max(desc.layers, 1)
	return tiles <= 16
}

// allocation_info is the resource's size and alignment in a heap. A small texture takes the small alignment where the
// device allows it, which it says by returning that alignment.
@(private = "file")
allocation_info :: proc(desc: ^d3d.RESOURCE_DESC1, small: bool) -> d3d.RESOURCE_ALLOCATION_INFO {
	info: d3d.RESOURCE_ALLOCATION_INFO
	if small {
		desc.Alignment = SMALL_ALIGNMENT
		dev.device->GetResourceAllocationInfo2(&info, 0, 1, desc, nil)
		if info.Alignment == SMALL_ALIGNMENT {
			return info
		}
	}
	desc.Alignment = 0
	dev.device->GetResourceAllocationInfo2(&info, 0, 1, desc, nil)
	return info
}

// place takes a region from a heap of the kind, or from a new heap when none has room. It returns nil when no heap can
// be made, and the resource is then committed.
@(private = "file")
place :: proc(kind: Heap_Kind, size, align: u64) -> Maybe(Placement) {
	sync.guard(&dev.heaps_mutex)
	for block in dev.blocks[kind] {
		if offset, ok := gpu.range_alloc(&block.ranges, size, align); ok {
			return Placement{kind, block, offset, size}
		}
	}
	FLAGS := [Heap_Kind]d3d.HEAP_FLAGS {
		.Buffers  = d3d.HEAP_FLAG_ALLOW_ONLY_BUFFERS,
		.Textures = d3d.HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES,
	}
	heap_desc := d3d.HEAP_DESC {
		SizeInBytes = HEAP_BLOCK_SIZE,
		Properties = {Type = .DEFAULT},
		Alignment = DEFAULT_ALIGNMENT,
		Flags = FLAGS[kind],
	}
	heap: ^d3d.IHeap
	if !check(dev.device->CreateHeap(&heap_desc, d3d.IHeap_UUID, (^rawptr)(&heap)), "CreateHeap") {
		return nil
	}
	block := new(Heap_Block, dev.allocator)
	block.heap = heap
	gpu.range_init(&block.ranges, HEAP_BLOCK_SIZE, dev.allocator)
	append(&dev.blocks[kind], block)
	log.debugf("d3d12: %v heap %d", kind, len(dev.blocks[kind]))
	offset, ok := gpu.range_alloc(&block.ranges, size, align)
	assert(ok, "d3d12: a resource does not fit an empty heap")
	return Placement{kind, block, offset, size}
}

// free_placement returns the region to its heap, and releases the heap when it is empty and not the last of its kind.
@(private)
free_placement :: proc(placement: ^Maybe(Placement)) {
	p, placed := placement.?
	if !placed {
		return
	}
	placement^ = nil
	sync.guard(&dev.heaps_mutex)
	gpu.range_free(&p.block.ranges, p.offset, p.size)
	blocks := &dev.blocks[p.kind]
	if !gpu.range_empty(&p.block.ranges) || len(blocks) == 1 {
		return
	}
	for block, i in blocks {
		if block == p.block {
			ordered_remove(blocks, i)
			break
		}
	}
	destroy_block(p.block)
}

@(private = "file")
destroy_block :: proc(block: ^Heap_Block) {
	release(&block.heap)
	gpu.range_destroy(&block.ranges)
	free(block, dev.allocator)
}
