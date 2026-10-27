package host

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/capture"
import "cinnabar:core/gpu"
import "cinnabar:engine/editor/link"

// Screenshots and the history ring (see docs/editor/capture.md#capture). The main thread asks the backend for copies
// of the frame target between frames, and a worker thread turns the finished copies into images, keeps the ring,
// encodes the files and writes them, so the frame never waits for an encode. The editor's requests arrive over the
// link and are answered with Capture_Result when the file is written.

// The justfile's release build sets this false, which drops the history ring; requests are then refused with a
// reason.
CAPTURE :: #config(CAPTURE, true)
// The history ring's frames and the time between them: five seconds at ten frames per second.
RING_FRAMES :: 50
RING_INTERVAL :: 100 * time.Millisecond
// A screenshot request that finds no free capture slot for this many frames fails with a reason.
CAPTURE_WAIT_FRAMES :: 8
// The GIF's delay between frames, in hundredths of a second.
GIF_DELAY_CS :: 10

#assert(len(link.Output_Mode) == len(gpu.Output_Mode))

Capture :: struct {
	editor:    ^Link,
	// Main thread: the copies the backend is making, oldest first, and the editor's requests that wait for a frame.
	in_flight: [dynamic]In_Flight,
	requests:  [dynamic]Request,
	ring_last: time.Tick,
	ring_due:  bool,
	// The host's count of frames, which the results report.
	frame:     u64,
	// The worker, and what the threads share under mutex.
	worker:    ^thread.Thread,
	mutex:     sync.Mutex,
	wake:      sync.Cond,
	closing:   bool,
	jobs:      [dynamic]Job,
	done:      [dynamic]link.Capture_Result,
	// The worker's own.
	ring:      Ring,
}

In_Flight :: struct {
	frame: u64,
	tick:  time.Tick,
	// The screenshot request that the frame answers, or 0 for a ring sample only.
	id:    u32,
	// The request's path, from the heap.
	path:  string,
	ring:  bool,
}

Request :: struct {
	id:     u32,
	kind:   link.Capture_Kind,
	path:   string,
	waited: int,
}

Job_Kind :: enum u8 {
	Ring_Sample,
	Screenshot,
	Gif,
}

Job :: struct {
	kind:    Job_Kind,
	capture: gpu.Frame_Capture,
	frame:   u64,
	tick:    time.Tick,
	id:      u32,
	path:    string,
	// A screenshot's frame goes into the ring too, when one was due.
	ring:    bool,
}

Ring_Frame :: struct {
	frame: u64,
	tick:  time.Tick,
	image: capture.Image,
}

Ring :: struct {
	frames: [RING_FRAMES]Ring_Frame,
	next:   int,
	count:  int,
}

// capture_start starts the worker. Call it after core.init.
capture_start :: proc(c: ^Capture, l: ^Link) {
	c.editor = l
	l.capture = c
	c.in_flight = make([dynamic]In_Flight, runtime.heap_allocator())
	c.requests = make([dynamic]Request, runtime.heap_allocator())
	c.jobs = make([dynamic]Job, runtime.heap_allocator())
	c.done = make([dynamic]link.Capture_Result, runtime.heap_allocator())
	c.ring_last = time.tick_now()
	when CAPTURE {
		c.worker = thread.create_and_start_with_poly_data(c, capture_worker, context)
	}
}

// capture_stop finishes the worker's current job and joins it. Call it before core.shutdown: the worker's jobs hold
// the backend's capture memory.
capture_stop :: proc(c: ^Capture) {
	if c.worker != nil {
		sync.lock(&c.mutex)
		c.closing = true
		sync.cond_broadcast(&c.wake)
		sync.unlock(&c.mutex)
		thread.join(c.worker)
		thread.destroy(c.worker)
		c.worker = nil
	}
	for job in c.jobs {
		free_job(job)
	}
	for r in c.done {
		free_result(r)
	}
	for r in c.requests {
		delete(r.path, runtime.heap_allocator())
	}
	for f in c.in_flight {
		delete(f.path, runtime.heap_allocator())
	}
	for f in c.ring.frames {
		delete(f.image.pixels, runtime.heap_allocator())
	}
	delete(c.jobs)
	delete(c.done)
	delete(c.requests)
	delete(c.in_flight)
	c.ring = {}
	if c.editor != nil {
		c.editor.capture = nil
	}
}

// capture_request queues an editor's request.
capture_request :: proc(c: ^Capture, m: link.Capture_Request) {
	when !CAPTURE {
		link_send(
			c.editor,
			link.Capture_Result {
				id = m.id,
				kind = m.kind,
				reason = "the host was built without captures (-define:CAPTURE=false)",
			},
		)
		return
	}
	path := strings_clone_heap(m.path)
	switch m.kind {
	case .Screenshot:
		append(&c.requests, Request{id = m.id, kind = m.kind, path = path})
	case .Gif:
		post_job(
			c,
			Job{kind = .Gif, id = m.id, path = path, frame = c.frame, tick = time.tick_now()},
		)
	}
}

// capture_disconnect drops the requests of an editor that left. Jobs already posted finish, and their results are
// dropped when they come back.
capture_disconnect :: proc(c: ^Capture) {
	for r in c.requests {
		delete(r.path, runtime.heap_allocator())
	}
	clear(&c.requests)
}

// capture_tick runs on the main thread between frames: it collects the backend's finished copies for the worker,
// sends the worker's results, and asks for the next copy when the ring is due or a screenshot waits.
capture_tick :: proc(c: ^Capture) {
	c.frame += 1
	for {
		done, ok := core.poll_frame_capture()
		if !ok {
			break
		}
		if len(c.in_flight) == 0 {
			// Nothing asked for it, which cannot happen: one request per frame, answered in order.
			core.release_frame_capture(done)
			continue
		}
		f := c.in_flight[0]
		ordered_remove(&c.in_flight, 0)
		if f.id != 0 {
			post_job(
				c,
				Job {
					kind = .Screenshot,
					capture = done,
					frame = f.frame,
					tick = f.tick,
					id = f.id,
					path = f.path,
					ring = f.ring,
				},
			)
		} else {
			post_job(c, Job{kind = .Ring_Sample, capture = done, frame = f.frame, tick = f.tick})
		}
	}

	sync.lock(&c.mutex)
	results := c.done
	c.done = make([dynamic]link.Capture_Result, runtime.heap_allocator())
	sync.unlock(&c.mutex)
	for r in results {
		if c.editor != nil && c.editor.linked {
			link_send(c.editor, r)
		}
		free_result(r)
	}
	delete(results)

	when CAPTURE {
		if time.tick_since(c.ring_last) >= RING_INTERVAL {
			c.ring_due = true
		}
	}
	screenshot := -1
	for r, i in c.requests {
		if r.kind == .Screenshot {
			screenshot = i
			break
		}
	}
	if !c.ring_due && screenshot < 0 {
		return
	}
	if !core.request_frame_capture() {
		if screenshot >= 0 {
			r := &c.requests[screenshot]
			r.waited += 1
			if r.waited >= CAPTURE_WAIT_FRAMES {
				reason := fmt.tprintf(
					"no capture slot was free for %d frames; the window may be minimized",
					CAPTURE_WAIT_FRAMES,
				)
				link_send(
					c.editor,
					link.Capture_Result{id = r.id, kind = .Screenshot, reason = reason},
				)
				delete(r.path, runtime.heap_allocator())
				ordered_remove(&c.requests, screenshot)
			}
		}
		return
	}
	f := In_Flight {
		frame = c.frame,
		tick  = time.tick_now(),
		ring  = c.ring_due,
	}
	if screenshot >= 0 {
		r := c.requests[screenshot]
		f.id, f.path = r.id, r.path
		ordered_remove(&c.requests, screenshot)
	}
	if c.ring_due {
		c.ring_due = false
		c.ring_last = f.tick
	}
	append(&c.in_flight, f)
}

@(private = "file")
post_job :: proc(c: ^Capture, job: Job) {
	when !CAPTURE {
		free_job(job)
		return
	}
	sync.lock(&c.mutex)
	append(&c.jobs, job)
	sync.cond_signal(&c.wake)
	sync.unlock(&c.mutex)
}

@(private = "file")
free_job :: proc(job: Job) {
	if job.capture.pixels != nil {
		core.release_frame_capture(job.capture)
	}
	delete(job.path, runtime.heap_allocator())
}

@(private = "file")
free_result :: proc(r: link.Capture_Result) {
	delete(r.path, runtime.heap_allocator())
	delete(r.reason, runtime.heap_allocator())
}

@(private = "file")
strings_clone_heap :: proc(s: string) -> string {
	if s == "" {
		return ""
	}
	out := make([]byte, len(s), runtime.heap_allocator())
	copy(out, s)
	return string(out)
}

@(private = "file")
capture_worker :: proc(c: ^Capture) {
	context.allocator = runtime.heap_allocator()
	for {
		sync.lock(&c.mutex)
		for len(c.jobs) == 0 && !c.closing {
			sync.cond_wait(&c.wake, &c.mutex)
		}
		if len(c.jobs) == 0 {
			sync.unlock(&c.mutex)
			return
		}
		job := c.jobs[0]
		ordered_remove(&c.jobs, 0)
		sync.unlock(&c.mutex)

		result, send := run_job(c, job)
		if send {
			sync.lock(&c.mutex)
			append(&c.done, result)
			sync.unlock(&c.mutex)
		}
		free_temp_allocator()
	}
}

@(private = "file")
free_temp_allocator :: proc() {
	free_all(context.temp_allocator)
}

// run_job does a job on the worker. Its result's strings are from the heap; the main thread frees them.
@(private = "file")
run_job :: proc(c: ^Capture, job: Job) -> (result: link.Capture_Result, send: bool) {
	heap := runtime.heap_allocator()
	switch job.kind {
	case .Ring_Sample, .Screenshot:
		img, ok := capture.to_rgb8(job.capture, heap)
		mode := link.Output_Mode(job.capture.mode)
		size := job.capture.size
		core.release_frame_capture(job.capture)
		if !ok {
			delete(job.path, heap)
			if job.kind == .Screenshot {
				return {
						id = job.id,
						kind = .Screenshot,
						frame = job.frame,
						output = mode,
						reason = strings_clone_heap("the frame's format cannot be read"),
					},
					true
			}
			return {}, false
		}
		if job.kind == .Ring_Sample || job.ring {
			ring_push(&c.ring, img, job.frame, job.tick)
		}
		if job.kind == .Ring_Sample {
			delete(img.pixels, heap)
			return {}, false
		}
		defer delete(img.pixels, heap)
		png, encoded := capture.encode_png(img, heap)
		defer delete(png, heap)
		if !encoded {
			delete(job.path, heap)
			return {
					id = job.id,
					kind = .Screenshot,
					frame = job.frame,
					output = mode,
					reason = strings_clone_heap("the PNG could not be encoded"),
				},
				true
		}
		path, reason := write_capture(job.path, .Screenshot, job.frame, png)
		return {
				id = job.id,
				kind = .Screenshot,
				ok = reason == "",
				reason = reason,
				path = path,
				frame = job.frame,
				width = size.x,
				height = size.y,
				output = mode,
			},
			true
	case .Gif:
		frames, first, last := ring_frames(&c.ring, heap)
		defer delete(frames, heap)
		if len(frames) == 0 {
			delete(job.path, heap)
			return {
					id = job.id,
					kind = .Gif,
					reason = strings_clone_heap("the history ring is empty"),
				},
				true
		}
		gif, encoded := capture.encode_gif(frames, GIF_DELAY_CS, heap)
		defer delete(gif, heap)
		if !encoded {
			delete(job.path, heap)
			return {
					id = job.id,
					kind = .Gif,
					reason = strings_clone_heap("the GIF could not be encoded"),
				},
				true
		}
		path, reason := write_capture(job.path, .Gif, last.frame, gif)
		return {
				id = job.id,
				kind = .Gif,
				ok = reason == "",
				reason = reason,
				path = path,
				frame = last.frame,
				width = frames[0].size.x,
				height = frames[0].size.y,
				frames = u32(len(frames)),
				duration_ms = f32(
					time.duration_milliseconds(time.tick_diff(first.tick, last.tick)),
				),
				output = .Sdr,
			},
			true
	}
	return {}, false
}

// ring_push adds a half-size copy of the image to the ring, over its oldest frame.
@(private = "file")
ring_push :: proc(r: ^Ring, img: capture.Image, frame: u64, tick: time.Tick) {
	heap := runtime.heap_allocator()
	slot := &r.frames[r.next]
	delete(slot.image.pixels, heap)
	slot^ = {
		frame = frame,
		tick  = tick,
		image = capture.downscale_half(img, heap),
	}
	r.next = (r.next + 1) % RING_FRAMES
	r.count = min(r.count + 1, RING_FRAMES)
}

// ring_frames is the ring's frames, oldest first, that have the newest frame's size, with the first and the last.
@(private = "file")
ring_frames :: proc(
	r: ^Ring,
	allocator: runtime.Allocator,
) -> (
	frames: []capture.Image,
	first, last: Ring_Frame,
) {
	if r.count == 0 {
		return
	}
	newest := r.frames[(r.next + RING_FRAMES - 1) % RING_FRAMES]
	out := make([dynamic]capture.Image, 0, r.count, allocator)
	for i in 0 ..< r.count {
		f := r.frames[(r.next + RING_FRAMES - r.count + i) % RING_FRAMES]
		if f.image.size != newest.image.size {
			clear(&out)
			continue
		}
		if len(out) == 0 {
			first = f
		}
		append(&out, f.image)
	}
	return out[:], first, newest
}

// write_capture writes the file at the request's path, or at the default beside the host, and gives the path written
// from the heap, or a reason, from the heap, why it could not.
@(private = "file")
write_capture :: proc(
	request_path: string,
	kind: link.Capture_Kind,
	frame: u64,
	data: []byte,
) -> (
	path, reason: string,
) {
	heap := runtime.heap_allocator()
	path = request_path
	if path == "" {
		path = default_capture_path(kind, frame, heap)
	}
	if dir := filepath.dir(path); dir != "" {
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			reason = strings_clone_heap(fmt.tprintf("cannot make %s: %v", dir, err))
			return
		}
	}
	if !core.file_write(path, data) {
		reason = strings_clone_heap(fmt.tprintf("cannot write %s", path))
		return
	}
	log.infof("host: wrote %s", path)
	return
}

// default_capture_path is captures/<utc yyyymmdd-hhmmss>-f<frame>.<png|gif> beside the host's executable.
@(private = "file")
default_capture_path :: proc(
	kind: link.Capture_Kind,
	frame: u64,
	allocator: runtime.Allocator,
) -> string {
	exe_dir, _ := os.get_executable_directory(context.temp_allocator)
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock_from_time(now)
	extension := "png" if kind == .Screenshot else "gif"
	name := fmt.tprintf(
		"%04d%02d%02d-%02d%02d%02d-f%d.%s",
		year,
		int(month),
		day,
		hour,
		minute,
		second,
		frame,
		extension,
	)
	path, _ := filepath.join({exe_dir, "captures", name}, allocator)
	return path
}
