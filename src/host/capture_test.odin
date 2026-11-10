package host

import "base:runtime"
import "core:testing"
import "core:time"

import "cinnabar:core/capture"

// The ring keeps the frames of the capture source that the newest one is of, at its size: a change of either starts it
// again.
@(test)
the_ring_starts_again_when_its_source_or_size_changes :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	ring: Ring
	defer {
		for f in ring.frames {
			delete(f.image.pixels, heap)
		}
	}
	image :: proc(size: [2]u32, heap: runtime.Allocator) -> capture.Image {
		return {size = size, pixels = make([]byte, int(size.x * size.y) * 3, heap)}
	}
	push :: proc(ring: ^Ring, size: [2]u32, viewport: Maybe(int), frame: u64, heap: runtime.Allocator) {
		img := image(size, heap)
		defer delete(img.pixels, heap)
		ring_push(ring, img, frame, time.tick_now(), viewport)
	}
	for k in 0 ..< 3 {
		push(&ring, {8, 8}, nil, u64(k), heap)
	}
	frames, _, last := ring_frames(&ring, heap)
	testing.expect_value(t, len(frames), 3)
	delete(frames, heap)
	testing.expect_value(t, last.frame, 2)

	// Another viewport, at the same size, is another source.
	push(&ring, {8, 8}, 1, 3, heap)
	push(&ring, {8, 8}, 1, 4, heap)
	frames, _, last = ring_frames(&ring, heap)
	testing.expect_value(t, len(frames), 2)
	delete(frames, heap)
	testing.expect_value(t, last.frame, 4)

	// The same viewport at another size, and back to the frame target.
	push(&ring, {16, 8}, 1, 5, heap)
	frames, _, _ = ring_frames(&ring, heap)
	testing.expect_value(t, len(frames), 1)
	delete(frames, heap)
	push(&ring, {16, 8}, nil, 6, heap)
	frames, _, _ = ring_frames(&ring, heap)
	testing.expect_value(t, len(frames), 1)
	delete(frames, heap)
}
