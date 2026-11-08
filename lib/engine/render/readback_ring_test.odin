package render

import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
import null "cinnabar:core/gpu/null"

@(test)
a_readback_ring_shows_what_the_frames_that_executed_copied :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 64}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator     = virtual.arena_allocator(&arena),
		jobs_run            = jobs.run,
		jobs_wait           = jobs.wait,
		gpu_frame_target    = null.frame_target,
		gpu_submit          = null.submit,
		gpu_create_buffer   = null.create_buffer,
		gpu_destroy_buffer  = null.destroy_buffer,
		gpu_read_buffer     = null.read_buffer,
		gpu_create_texture  = null.create_texture,
		gpu_destroy_texture = null.destroy_texture,
	}
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	source := platform.gpu_create_buffer({size = 4, usage = {.Storage}, label = "test tally"}, nil)
	defer platform.gpu_destroy_buffer(source)
	ring: Readback_Ring
	testing.expect(t, ensure_readback_ring(&ring, &platform, 4, "test readback"))
	defer destroy_readback_ring(&ring, &platform)

	Frame_Kind :: enum {
		Copies,
		Copies_And_Fails,
		Copies_Nothing,
	}
	// A frame whose copy holds value, since the null backend copies nothing. It reads the ring after it, as draw_frame
	// does, and gives what the read found.
	frame :: proc(t: ^testing.T, platform: ^core.Platform_API, cache: ^Texture_Cache, ring: ^Readback_Ring, source: gpu.Buffer, kind: Frame_Kind, value: u32) -> (take: Readback_Take, read: u32) {
		platform.gpu_submit = kind == .Copies_And_Fails ? fail_submit : null.submit
		defer platform.gpu_submit = null.submit
		g := begin(platform, cache)
		target := import_texture(&g, null.frame_target(), .Color)
		p := add_render_pass(&g, "output", proc(_: ^Pass_Context) {})
		color(&g, p, target, .Clear)
		if kind != .Copies_Nothing {
			copy, _ := null.read_buffer(ring.copies[ring.next])
			mem.slice_data_cast([]u32, copy)[0] = value
			add_readback_copy(&g, platform, ring, import_buffer(&g, source), 4, "test copy")
		}
		testing.expect_value(t, execute(&g), kind != .Copies_And_Fails)
		null.end_frame()
		free_all(platform.frame_allocator)
		data: []byte
		data, take = take_readback(ring, platform, 4)
		if take == .Fresh {
			read = mem.slice_data_cast([]u32, data)[0]
		}
		return
	}

	// Before any frame, nothing is read.
	_, take := take_readback(&ring, &platform, 4)
	testing.expect_value(t, take, Readback_Take.Idle)

	// Each frame that executes moves on to the next copy, and its copy is read once it is back: the null backend's
	// readback memory always is.
	for value in u32(1) ..= 4 {
		fresh, read := frame(t, &platform, &cache, &ring, source, .Copies, value)
		testing.expect_value(t, fresh, Readback_Take.Fresh)
		testing.expect_value(t, read, value)
		testing.expect_value(t, ring.next, int(value) % READBACK_COPIES)
	}

	// A frame that records its copy and then fails marks nothing written and does not move on, so the read finds no
	// frame that copied, drops what is in flight, and the stats show none.
	next := ring.next
	ring.written[(next + 1) % READBACK_COPIES] = true
	take, _ = frame(t, &platform, &cache, &ring, source, .Copies_And_Fails, 9)
	testing.expect_value(t, take, Readback_Take.Idle)
	testing.expect_value(t, ring.next, next)
	testing.expect_value(t, ring.written, [READBACK_COPIES]bool{})

	// So does a frame that copies nothing, even with an older copy in flight.
	_, _ = frame(t, &platform, &cache, &ring, source, .Copies, 5)
	ring.written[(ring.next + 1) % READBACK_COPIES] = true
	take, _ = frame(t, &platform, &cache, &ring, source, .Copies_Nothing, 0)
	testing.expect_value(t, take, Readback_Take.Idle)
	testing.expect_value(t, ring.written, [READBACK_COPIES]bool{})

	// Two copies back at once, the older first: the newer is the one read, and each is read once.
	next = ring.next
	older, newer := (next + 1) % READBACK_COPIES, (next + 2) % READBACK_COPIES
	for pair in ([2][2]int{{older, 6}, {newer, 7}}) {
		copy, _ := null.read_buffer(ring.copies[pair[0]])
		mem.slice_data_cast([]u32, copy)[0] = u32(pair[1])
		ring.written[pair[0]] = true
	}
	ring.copied = true
	data: []byte
	data, take = take_readback(&ring, &platform, 4)
	testing.expect_value(t, take, Readback_Take.Fresh)
	testing.expect_value(t, mem.slice_data_cast([]u32, data)[0], 7)
	testing.expect_value(t, ring.written, [READBACK_COPIES]bool{})

	// A frame copied, but its copy is not back: the read waits, and the caller keeps what it has.
	ring.copied = true
	_, take = take_readback(&ring, &platform, 4)
	testing.expect_value(t, take, Readback_Take.Waiting)
}

@(private = "file")
creates_left: int

@(test)
a_readback_ring_has_all_of_its_copies_or_none :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, null.init(nil, {64, 64}))
	defer null.shutdown()
	platform := core.Platform_API {
		gpu_create_buffer  = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
			if creates_left == 0 {
				return {}
			}
			creates_left -= 1
			return null.create_buffer(desc, data)
		},
		gpu_destroy_buffer = null.destroy_buffer,
	}
	// The second copy cannot be made: the first goes too, and the ring is as new.
	ring: Readback_Ring
	creates_left = 1
	testing.expect(t, !ensure_readback_ring(&ring, &platform, 4, "test readback"))
	testing.expect_value(t, ring, Readback_Ring{})
	// A later call makes them all.
	creates_left = READBACK_COPIES
	testing.expect(t, ensure_readback_ring(&ring, &platform, 4, "test readback"))
	for b in ring.copies {
		testing.expect(t, b != {})
	}
	destroy_readback_ring(&ring, &platform)
}
