package render

import core "cinnabar:core"
import "cinnabar:core/gpu"

// The copies of a readback ring, a frame or more apart, so a read never waits for a frame in flight.
READBACK_COPIES :: 3

// Readback_Ring is a value that the GPU writes each frame and the CPU reads a frame or two later, such as a tally that
// the editor shows: its readback copies, whether each holds a frame's value that has not been read, the next copy to
// write, and whether a frame that executed copied into it since the last take. add_readback_copy records a frame's
// copy, and its commit, once the frame executes, is the only thing that marks a copy written; take_readback is the only
// read. So a frame that fails leaves the ring as it was.
@(private)
Readback_Ring :: struct {
	copies:  [READBACK_COPIES]gpu.Buffer,
	written: [READBACK_COPIES]bool,
	next:    int,
	copied:  bool,
}

// Readback_Take is what take_readback found: the newest copy that came back, copies that are still in flight, or no
// frame that executed and copied since the last take.
@(private)
Readback_Take :: enum {
	Idle,
	Waiting,
	Fresh,
}

// ensure_readback_ring creates the ring's copies of size bytes the first time. A ring has all of its copies or none: when
// one cannot be made, the others go, and a later call tries again.
@(private)
ensure_readback_ring :: proc(ring: ^Readback_Ring, platform: ^core.Platform_API, size: u32, label: string) -> bool {
	if ring.copies[0] != {} {
		return true
	}
	for &b in ring.copies {
		b = platform.gpu_create_buffer({size = size, usage = {.Readback}, label = label}, nil)
		if b == {} {
			destroy_readback_ring(ring, platform)
			return false
		}
	}
	return true
}

@(private)
destroy_readback_ring :: proc(ring: ^Readback_Ring, platform: ^core.Platform_API) {
	for b in ring.copies {
		platform.gpu_destroy_buffer(b)
	}
	ring^ = {}
}

@(private = "file")
Readback_Copy :: struct {
	ring:   ^Readback_Ring,
	slot:   int,
	source: Buffer,
	dest:   gpu.Buffer,
	size:   u32,
}

// add_readback_copy copies size bytes of source into the ring's next copy, in a pass of its own on queue. Once the frame
// executes, the copy is written and the ring moves on to the one after it. A frame copies into a ring at most once.
@(private)
add_readback_copy :: proc(g: ^Graph, platform: ^core.Platform_API, ring: ^Readback_Ring, source: Buffer, size: u32, name: string, queue := gpu.Queue.Graphics) {
	data := new_clone(Readback_Copy{ring = ring, slot = ring.next, source = source, dest = ring.copies[ring.next], size = size}, platform.frame_allocator)
	p := add_compute_pass(g, name, proc(ctx: ^Pass_Context) {
		c := (^Readback_Copy)(ctx.data)
		gpu.cmd_copy_buffer(ctx.cb, gpu_buffer(ctx.graph, c.source), 0, c.dest, 0, c.size)
	}, data, queue = queue)
	copy_source(g, p, source)
	copy_dest(g, p, import_buffer(g, data.dest))
	on_executed(g, commit_readback_copy, data)
}

@(private = "file")
commit_readback_copy :: proc(data: rawptr) {
	c := (^Readback_Copy)(data)
	mark_readback_copied(c.ring, c.slot)
}

// mark_readback_copied is what a frame's copy into slot leaves once the frame executes: the copy is written, and the ring
// moves on to the one after it. Only the copy's commit calls it, and tests that stand in for a frame.
@(private)
mark_readback_copied :: proc(ring: ^Readback_Ring, slot: int) {
	ring.written[slot] = true
	ring.next = (slot + 1) % READBACK_COPIES
	ring.copied = true
}

// take_readback takes each of the ring's copies that has come back, the newest last, and gives the newest's data, of at
// least size bytes, with Fresh. While copies are in flight and none came back, it is Waiting, and the caller keeps what
// it has. When no frame that executed copied into the ring since the last take, it drops the copies in flight and is
// Idle, so a frame without the value, or a frame that failed, shows none.
@(private)
take_readback :: proc(ring: ^Readback_Ring, platform: ^core.Platform_API, size: int) -> (data: []byte, take: Readback_Take) {
	defer ring.copied = false
	if !ring.copied {
		ring.written = {}
		return nil, .Idle
	}
	take = .Waiting
	for k in 0 ..< READBACK_COPIES {
		i := (ring.next + k) % READBACK_COPIES
		if !ring.written[i] {
			continue
		}
		if copy, ok := platform.gpu_read_buffer(ring.copies[i]); ok && len(copy) >= size {
			data, take = copy, .Fresh
			ring.written[i] = false
		}
	}
	return
}
