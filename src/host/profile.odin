package host

import "base:runtime"
import "core:fmt"

import "cinnabar:core/profile"
import "cinnabar:engine/editor/link"

// A capture whose frame has not ended, or whose GPU times have not arrived, waits at most this many frames for them.
CAPTURE_GPU_FRAMES :: 8

// Pending_Capture is a capture request that waits for its frame.
Pending_Capture :: struct {
	id:    u32,
	frame: u64,
}

#assert(len(link.Profile_Category) == len(profile.Category))
#assert(len(link.Profile_Cost_Kind) == len(profile.Cost_Kind))
#assert(len(link.Profile_Callback) == len(profile.Callback))

// profile_summary closes the profiler's stats interval.
profile_summary :: proc(allocator: runtime.Allocator) -> link.Profile_Summary {
	ms :: proc(ns: f64) -> f32 {
		return f32(ns / 1e6)
	}
	s := profile.take_summary(allocator)
	costs := make([]link.Profile_Cost, len(s.costs), allocator)
	for c, i in s.costs {
		text, _ := profile.name_text(c.key.name)
		costs[i] = {
			kind       = link.Profile_Cost_Kind(c.key.kind),
			name       = text,
			callback   = link.Profile_Callback(c.key.detail) if c.key.kind == .Script else .None,
			queue      = c.key.queue,
			calls      = f32(c.calls),
			ms_average = ms(c.average),
			ms_max     = ms(f64(c.max)),
		}
	}
	return {
		first_frame = s.first_frame,
		last_frame = s.last_frame,
		frames = s.frames,
		gpu_frames = s.gpu_frames,
		cpu_ms_average = ms(s.cpu_average),
		cpu_ms_max = ms(f64(s.cpu_max)),
		cpu_worst_frame = s.cpu_worst_frame,
		wait_ms_average = ms(s.wait_average),
		wait_ms_max = ms(f64(s.wait_max)),
		gpu_ms_average = ms(s.gpu_average),
		gpu_ms_max = ms(f64(s.gpu_max)),
		gpu_worst_frame = s.gpu_worst_frame,
		dropped = s.dropped,
		recording = profile.recording(),
		costs = costs,
	}
}

// request_capture queues a capture request. The frame code of the frame that runs now is profile.current_frame, which
// has not ended.
request_capture :: proc(l: ^Link, m: link.Profile_Capture_Request) {
	when !profile.ENABLED {
		link_send(l, link.Profile_Capture{id = m.id, reason = "the host was built without the profiler (-define:PROFILE=false)"})
		return
	}
	frame: u64
	switch m.mode {
	case .Next:
		frame = profile.current_frame() + 1
	case .Worst_Recent:
		frame = profile.worst_recent(int(max(m.count, 1)))
	case .Frame:
		frame = m.frame
	}
	append(&l.captures, Pending_Capture{m.id, frame})
}

// send_captures answers the requests whose frames are ready, or gone.
send_captures :: proc(l: ^Link) {
	current := profile.current_frame()
	for i := 0; i < len(l.captures); {
		c := l.captures[i]
		exists, gpu_ready := profile.frame_state(c.frame)
		if c.frame >= current || exists && !gpu_ready && current < c.frame + CAPTURE_GPU_FRAMES {
			i += 1
			continue
		}
		unordered_remove(&l.captures, i)
		if !exists {
			reason := fmt.tprintf("the host no longer has frame %d: it keeps the last %d frames and the worst frames of the last %d stats intervals", c.frame, profile.FRAME_RING, profile.PINNED_FRAMES)
			link_send(l, link.Profile_Capture{id = c.id, frame = c.frame, reason = reason})
			continue
		}
		link_send(l, capture_message(c, context.temp_allocator))
	}
}

@(private = "file")
capture_message :: proc(c: Pending_Capture, allocator: runtime.Allocator) -> link.Profile_Capture {
	captured, _ := profile.capture(c.frame, allocator)
	r := captured.frame
	names := make([dynamic]link.Profile_Name, allocator)
	indices := make(map[profile.Name]u16, allocator = allocator)
	index_of :: proc(names: ^[dynamic]link.Profile_Name, indices: ^map[profile.Name]u16, n: profile.Name) -> u16 {
		if i, ok := indices[n]; ok {
			return i
		}
		text, category := profile.name_text(n)
		i := u16(len(names))
		append(names, link.Profile_Name{text, link.Profile_Category(category)})
		indices[n] = i
		return i
	}
	lane_names := profile.lane_names(allocator)
	lanes := make([dynamic]link.Profile_Lane, 0, len(lane_names) + 2, allocator)
	for name in lane_names {
		append(&lanes, link.Profile_Lane{name, .Thread})
	}
	gpu_lanes := [2]u8{u8(len(lanes)), u8(len(lanes) + 1)}
	append(&lanes, link.Profile_Lane{"GPU graphics", .Gpu_Graphics}, link.Profile_Lane{"GPU compute", .Gpu_Compute})

	offset :: proc(t, start: u64) -> i64 {
		return i64(t) - i64(start)
	}
	zones := make([]link.Profile_Zone, len(captured.zones) + len(captured.gpu), allocator)
	for z, i in captured.zones {
		zones[i] = {
			start    = offset(z.start, r.start),
			duration = u32(min(z.end - z.start, u64(max(u32)))),
			name     = index_of(&names, &indices, z.name),
			detail   = z.detail,
			lane     = z.lane,
			depth    = z.depth,
			flags    = transmute(u8)z.flags,
			fiber    = z.fiber,
		}
	}
	for s, i in captured.gpu {
		zones[len(captured.zones) + i] = {
			start    = offset(s.start, r.start),
			duration = u32(min(s.end - min(s.start, s.end), u64(max(u32)))),
			name     = index_of(&names, &indices, s.name),
			detail   = s.detail,
			lane     = gpu_lanes[min(s.queue, 1)],
			depth    = s.depth,
		}
	}
	m := link.Profile_Capture {
		id        = c.id,
		frame     = r.number,
		available = true,
		frame_ns  = r.end - r.start,
		wait_ns   = r.wait,
		cpu_ns    = (r.end - r.start) - min(r.wait, r.end - r.start),
		dropped   = r.dropped,
		names     = names[:],
		lanes     = lanes[:],
		zones     = zones,
	}
	if r.gpu_ready && !r.gpu_none && r.gpu_end > r.gpu_begin {
		m.gpu_ns = r.gpu_end - r.gpu_begin
		m.gpu_begin, m.gpu_end = offset(r.gpu_begin, r.start), offset(r.gpu_end, r.start)
	}
	return m
}
