package host

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "cinnabar:core"
import "cinnabar:core/capture"
import "cinnabar:core/gpu"
import "cinnabar:engine/editor/link"

// The host's side of a render out (see docs/editor/cutscene-editor.md#render-out): the game hands it each frame's
// target as it draws, and the host copies the target at the frame's end and writes it on the capture worker, in the
// order that the game drew the frames. One render out is open at a time, and while one is, the history ring takes no
// samples, so the backend's copies are the render out's.

// Render frames' tickets have this bit, so take_texture tells them from the thumbnail's.
RENDER_TICKET_BIT :: u32(1) << 31
// The most frames that a render out has copying or waiting to be written. The backend has CAPTURE_SLOTS copies, and the
// thumbnail and screenshots keep theirs.
RENDER_IN_FLIGHT_MOST :: 2

// Render_Output is the render out that the host writes: Open while it takes frames, Closing while it writes the last of
// them, and Closed, with how it went, until the next opens. nil is none. change_output is its one writer.
Render_Output :: union {
	Output_Open,
	Output_Closing,
	Output_Closed,
}

// Output_Files is what an open or closing render out writes. Its strings are in the heap.
Output_Files :: struct {
	run:         u64,
	folder:      string,
	name:        string,
	pattern:     string,
	format:      core.Render_Out_Format,
	size:        [2]u32,
	first_frame: i32,
	// The frames that the backend copies, by ticket and number, and those that the game handed over and the worker
	// wrote, or could not.
	in_flight:   [dynamic]Render_In_Flight,
	queued:      int,
	accepted:    i32,
	written:     i32,
	// The first frame that could not be written, from the heap, or "".
	failure:     string,
	// The sound, while it is written (see Wav_Output).
	wav:         Maybe(Wav_Output),
}

// Wav_Output is a run's sound, written to a temporary file beside its name as the frames come, and given its name
// with its header's sizes when the run closes. Its path is from the heap.
Wav_Output :: struct {
	file:   ^os.File,
	path:   string,
	frames: u32,
}

Render_In_Flight :: struct {
	ticket: u32,
	frame:  i32,
}

Output_Open :: struct {
	using files: Output_Files,
}

// Output_Closing writes the frames that it took. The sound is closed already.
Output_Closing :: struct {
	using files: Output_Files,
}

Output_Closed :: struct {
	run:    u64,
	ok:     bool,
	// From the heap.
	reason: string,
}

// Render_Written is a frame that the worker wrote, or could not, for the main thread to count and send. Its strings
// are from the heap.
Render_Written :: struct {
	run:    u64,
	frame:  i32,
	ok:     bool,
	reason: string,
	path:   string,
	size:   [2]u32,
}

// render_capture is the capture state that the platform's render out procedures act on, which capture_start sets.
@(private = "file")
render_capture: ^Capture

// render_out_procs are the host's render out procedures for Platform_API.render_out.
render_out_procs :: proc(c: ^Capture) -> core.Render_Out_Procs {
	render_capture = c
	return {
		open = render_out_open,
		room = render_out_room,
		audio = render_out_audio,
		frame = render_out_frame,
		close = render_out_close,
		status = render_out_status,
	}
}

// change_output is the one writer of the render out: it frees what the old value held that the new one does not.
@(private = "file")
change_output :: proc(c: ^Capture, to: Render_Output) {
	heap := runtime.heap_allocator()
	switch &o in c.render_output {
	case Output_Open:
		if _, closing := to.(Output_Closing); !closing {
			free_files(&o.files)
		}
	case Output_Closing:
		free_files(&o.files)
	case Output_Closed:
		delete(o.reason, heap)
	}
	c.render_output = to
}

@(private = "file")
free_files :: proc(f: ^Output_Files) {
	heap := runtime.heap_allocator()
	delete(f.folder, heap)
	delete(f.name, heap)
	delete(f.pattern, heap)
	delete(f.failure, heap)
	delete(f.in_flight)
	if w, writing := f.wav.?; writing {
		end_wav(w, false)
	}
}

// end_wav ends the tap and closes the sound's file, which keep gives its name to and the other deletes, and gives the
// name written, from the heap, or "".
@(private = "file")
end_wav :: proc(w: Wav_Output, keep: bool) -> (path: string, reason: string) {
	heap := runtime.heap_allocator()
	core.audio_tap_end()
	header := capture.wav_header(w.frames, core.AUDIO_SAMPLE_RATE, 2)
	_, err := os.write_at(w.file, header[:], 0)
	os.close(w.file)
	final := strings.trim_suffix(w.path, ".tmp")
	if keep && err == nil && os.rename(w.path, final) == nil {
		path = strings.clone(final, heap)
	} else {
		os.remove(w.path)
		if keep {
			reason = "the sound could not be written"
		}
	}
	delete(w.path, heap)
	return
}

@(private = "file")
open_files :: proc(c: ^Capture, run: u64) -> ^Output_Files {
	if o, open := &c.render_output.(Output_Open); open && o.run == run {
		return &o.files
	}
	return nil
}

@(private = "file")
render_out_open :: proc(desc: core.Render_Out_Desc) -> (ok: bool, reason: string) {
	c := render_capture
	when !CAPTURE {
		return false, "the host was built without captures (-define:CAPTURE=false)"
	}
	#partial switch _ in c.render_output {
	case Output_Open, Output_Closing:
		return false, "a render out is running"
	}
	if err := os.make_directory_all(desc.folder); err != nil && err != .Exist {
		return false, fmt.tprintf("cannot make %s: %v", desc.folder, err)
	}
	heap := runtime.heap_allocator()
	wav: Maybe(Wav_Output)
	if desc.audio {
		path, _ := filepath.join({desc.folder, fmt.tprintf("%s.wav.tmp", desc.name)}, heap)
		file, err := os.create(path)
		header := capture.wav_header(0, core.AUDIO_SAMPLE_RATE, 2)
		if err == nil {
			_, err = os.write(file, header[:])
		}
		if err != nil {
			delete(path, heap)
			return false, fmt.tprintf("cannot write the sound to %s: %v", desc.folder, err)
		}
		core.audio_tap_begin()
		wav = Wav_Output {
			file = file,
			path = path,
		}
	}
	change_output(
		c,
		Output_Open {
			files = {
				run = desc.run,
				folder = strings.clone(desc.folder, heap),
				name = strings.clone(desc.name, heap),
				pattern = strings.clone(desc.pattern, heap),
				format = desc.format,
				size = desc.size,
				first_frame = desc.first_frame,
				in_flight = make([dynamic]Render_In_Flight, heap),
				wav = wav,
			},
		},
	)
	return true, ""
}

@(private = "file")
render_out_room :: proc(run: u64) -> core.Render_Out_Answer {
	f := open_files(render_capture, run)
	if f == nil {
		return .Not_Open
	}
	return .Accepted if len(f.in_flight) + f.queued < RENDER_IN_FLIGHT_MOST else .No_Room
}

@(private = "file")
render_out_frame :: proc(run: u64, frame: i32, texture: gpu.Texture) -> core.Render_Out_Answer {
	c := render_capture
	f := open_files(c, run)
	if f == nil {
		return .Not_Open
	}
	if len(f.in_flight) + f.queued >= RENDER_IN_FLIGHT_MOST {
		return .No_Room
	}
	c.next_ticket = max(c.next_ticket + 1, 1)
	ticket := (c.next_ticket & ~RENDER_TICKET_BIT) | RENDER_TICKET_BIT
	if !core.platform_api().gpu_capture_texture(texture, ticket) {
		return .No_Room
	}
	append(&f.in_flight, Render_In_Flight{ticket, frame})
	f.accepted += 1
	return .Accepted
}

@(private = "file")
render_out_audio :: proc(run: u64, frames: int) -> core.Render_Out_Answer {
	f := open_files(render_capture, run)
	if f == nil {
		return .Not_Open
	}
	w, writing := &f.wav.?
	if !writing || frames <= 0 {
		return .Accepted
	}
	samples := make([]core.Audio_Frame, frames, context.temp_allocator)
	if !core.audio_tap_take(samples) && f.failure == "" {
		f.failure = strings.clone(
			"the audio backend did not mix the sound in time",
			runtime.heap_allocator(),
		)
	}
	flat := ([^]f32)(raw_data(samples))[:2 * frames]
	bytes := capture.pcm16(flat, make([]u8, 4 * frames, context.temp_allocator))
	if _, err := os.write(w.file, bytes); err != nil && f.failure == "" {
		f.failure = strings.clone(
			fmt.tprintf("cannot write the sound: %v", err),
			runtime.heap_allocator(),
		)
	}
	w.frames += u32(frames)
	return .Accepted
}

@(private = "file")
render_out_close :: proc(run: u64, keep: bool) {
	c := render_capture
	o, open := c.render_output.(Output_Open)
	if !open || o.run != run {
		return
	}
	// The sound is whole now: the frames that are still writing have theirs in it.
	if w, writing := o.wav.?; writing {
		o.wav = nil
		path, reason := end_wav(w, keep)
		if reason != "" && o.failure == "" {
			o.failure = strings.clone(reason, runtime.heap_allocator())
		}
		if path != "" && c.editor != nil && link_linked(c.editor) {
			link_send(
				c.editor,
				link.Render_Out_Written{ticket = run, frame = -1, ok = true, path = path},
			)
		}
		delete(path, runtime.heap_allocator())
	}
	change_output(c, Output_Closing{files = o.files})
	render_out_settle(c)
}

@(private = "file")
render_out_status :: proc(run: u64) -> core.Render_Out_Status {
	switch o in render_capture.render_output {
	case Output_Open:
		if o.run == run {
			return core.Render_Out_Writing{o.accepted, o.written}
		}
	case Output_Closing:
		if o.run == run {
			return core.Render_Out_Writing{o.accepted, o.written}
		}
	case Output_Closed:
		if o.run == run {
			return core.Render_Out_Closed{o.ok, o.reason}
		}
	}
	return nil
}

// render_out_settle closes a closing render out once the worker has written every frame that it took.
@(private = "file")
render_out_settle :: proc(c: ^Capture) {
	o, closing := c.render_output.(Output_Closing)
	if !closing || o.written < o.accepted {
		return
	}
	heap := runtime.heap_allocator()
	change_output(
		c,
		Output_Closed{run = o.run, ok = o.failure == "", reason = strings.clone(o.failure, heap)},
	)
}

// render_out_active is whether a render out has frames to take or to write, during which the ring takes no samples.
render_out_active :: proc(c: ^Capture) -> bool {
	#partial switch _ in c.render_output {
	case Output_Open, Output_Closing:
		return true
	}
	return false
}

@(private = "file")
files_of :: proc(c: ^Capture) -> ^Output_Files {
	#partial switch &o in c.render_output {
	case Output_Open:
		return &o.files
	case Output_Closing:
		return &o.files
	}
	return nil
}

// take_render_frame gives the worker a render out's frame that the backend copied, or counts it as not written when
// the backend cancelled the copy.
take_render_frame :: proc(c: ^Capture, done: gpu.Frame_Capture) {
	f := files_of(c)
	index := -1
	if f != nil {
		for r, i in f.in_flight {
			if r.ticket == done.ticket {
				index = i
				break
			}
		}
	}
	if index < 0 {
		core.release_frame_capture(done)
		return
	}
	frame := f.in_flight[index].frame
	ordered_remove(&f.in_flight, index)
	if done.status != .Ready {
		core.release_frame_capture(done)
		render_frame_failed(c, f, frame, "the backend could not copy the frame")
		return
	}
	f.queued += 1
	post_render_job(c, done, f.run, frame, frame_path(f, frame, runtime.heap_allocator()))
}

@(private = "file")
render_frame_failed :: proc(c: ^Capture, f: ^Output_Files, frame: i32, reason: string) {
	f.written += 1
	if f.failure == "" {
		f.failure = strings.clone(
			fmt.tprintf("frame %d: %s", frame, reason),
			runtime.heap_allocator(),
		)
	}
	if c.editor != nil && link_linked(c.editor) {
		link_send(
			c.editor,
			link.Render_Out_Written{ticket = f.run, frame = frame, reason = reason},
		)
	}
	render_out_settle(c)
}

// frame_path is where a frame goes: the pattern in the folder, with {name} and {frame} replaced.
frame_path :: proc(f: ^Output_Files, frame: i32, allocator: runtime.Allocator) -> string {
	number := fmt.tprintf("%06d", f.first_frame + frame)
	named, _ := strings.replace_all(f.pattern, "{name}", f.name, context.temp_allocator)
	file, _ := strings.replace_all(named, "{frame}", number, context.temp_allocator)
	path, _ := filepath.join({f.folder, file}, allocator)
	return path
}

// run_render_frame encodes and writes a frame on the worker, and posts what it did for the main thread.
run_render_frame :: proc(c: ^Capture, job: Job) {
	heap := runtime.heap_allocator()
	result := Render_Written {
		run   = job.run,
		frame = i32(job.frame),
		size  = job.capture.size,
	}
	img, ok := capture.to_rgb8(job.capture, heap)
	core.release_frame_capture(job.capture)
	switch {
	case !ok:
		result.reason = strings.clone("the frame's format cannot be read", heap)
		delete(job.path, heap)
	case:
		defer delete(img.pixels, heap)
		png, encoded := capture.encode_png(img, heap)
		defer delete(png, heap)
		if !encoded {
			result.reason = strings.clone("the PNG could not be encoded", heap)
			delete(job.path, heap)
		} else if core.file_write(job.path, png) {
			result.ok, result.path = true, job.path
		} else {
			result.reason = strings.clone(fmt.tprintf("cannot write %s", job.path), heap)
			delete(job.path, heap)
		}
	}
	sync.lock(&c.mutex)
	append(&c.render_done, result)
	sync.unlock(&c.mutex)
}

// render_out_tick counts and sends the frames that the worker wrote since the last frame, and closes a closing render
// out once every frame is written.
render_out_tick :: proc(c: ^Capture) {
	heap := runtime.heap_allocator()
	sync.lock(&c.mutex)
	results := c.render_done
	c.render_done = make([dynamic]Render_Written, heap)
	sync.unlock(&c.mutex)
	f := files_of(c)
	for r in results {
		if f != nil && f.run == r.run {
			f.queued -= 1
			f.written += 1
			if !r.ok && f.failure == "" {
				f.failure = strings.clone(fmt.tprintf("frame %d: %s", r.frame, r.reason), heap)
			}
		}
		if c.editor != nil && link_linked(c.editor) {
			link_send(
				c.editor,
				link.Render_Out_Written {
					ticket = r.run,
					frame = r.frame,
					ok = r.ok,
					reason = r.reason,
					path = r.path,
					width = r.size.x,
					height = r.size.y,
				},
			)
		}
		delete(r.path, heap)
		delete(r.reason, heap)
	}
	delete(results)
	render_out_settle(c)
}

// render_out_abort closes a render out that the game can no longer finish, as at a soft restart or when the host
// stops: what the worker writes still counts, and the run's status says that it stopped.
render_out_abort :: proc(c: ^Capture, reason: string) {
	f := files_of(c)
	if f == nil {
		return
	}
	if f.failure == "" {
		f.failure = strings.clone(reason, runtime.heap_allocator())
	}
	f.written += i32(len(f.in_flight))
	clear(&f.in_flight)
	if o, open := c.render_output.(Output_Open); open {
		change_output(c, Output_Closing{files = o.files})
	}
	render_out_settle(c)
}

// render_out_stop frees the render out when the host stops.
render_out_stop :: proc(c: ^Capture) {
	for r in c.render_done {
		delete(r.path, runtime.heap_allocator())
		delete(r.reason, runtime.heap_allocator())
	}
	delete(c.render_done)
	change_output(c, nil)
	render_capture = nil
}
