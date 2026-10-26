package gpu_d3d12

import "core:sync"
import win "core:sys/windows"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"
import "cinnabar:core/profile"

// A frame's timestamps, both queues'. Timed markers past this are not timed.
@(private)
MAX_TIMESTAMPS :: 4096
// The frame's first and last timestamps, on the graphics queue.
@(private)
FRAME_BEGIN_TIMESTAMP :: 0
@(private)
FRAME_END_TIMESTAMP :: 1
// A span longer than this is a lost device or a power state change, not a pass.
@(private)
MAX_SPAN :: u64(1_000_000_000)

// Timestamps measure a frame's timed markers for the profiler (see docs/core/profiling.md#gpu-timestamps). Each frame
// slot has a query heap that both queues write, and a readback buffer that the frame's last graphics list resolves
// the heap into. begin_frame reads it after the slot's fence, FRAMES_IN_FLIGHT frames later.
@(private)
Timestamps :: struct {
	heap:        ^d3d.IQueryHeap,
	readback:    ^d3d.IResource,
	mapped:      [^]u64,
	// The next free index. Translation jobs take indices at once.
	count:       i32,
	// The markers' spans, which translation jobs add under dev.lists_mutex.
	spans:       [dynamic]Timestamp_Span,
	// The profiler's frame that the slot's work belongs to, and whether the frame resolved its timestamps.
	frame:       u64,
	resolved:    bool,
	calibration: [gpu.Queue]Calibration,
}

@(private)
Timestamp_Span :: struct {
	begin, end: u32,
	name:       profile.Name,
	detail:     u16,
	queue:      gpu.Queue,
	depth:      u8,
}

// Calibration is a queue's GPU timestamp and the CPU's time in nanoseconds at one moment.
@(private)
Calibration :: struct {
	gpu, cpu: u64,
}

@(private)
init_timestamps :: proc() -> bool {
	when !profile.ENABLED {
		return true
	} else {
		check(dev.queue->GetTimestampFrequency(&dev.timestamp_frequency[.Graphics]), "GetTimestampFrequency") or_return
		check(dev.compute_queue->GetTimestampFrequency(&dev.timestamp_frequency[.Compute]), "GetTimestampFrequency(compute)") or_return
		win.QueryPerformanceFrequency(&dev.qpc_frequency)
		for &frame in dev.frames {
			ts := &frame.timestamps
			heap_desc := d3d.QUERY_HEAP_DESC {
				Type  = .TIMESTAMP,
				Count = MAX_TIMESTAMPS,
			}
			check(dev.device->CreateQueryHeap(&heap_desc, d3d.IQueryHeap_UUID, (^rawptr)(&ts.heap)), "CreateQueryHeap(timestamps)") or_return
			resource, ok := create_buffer_resource({size = MAX_TIMESTAMPS * size_of(u64), usage = {.Readback}, label = "timestamps"}, .READBACK)
			if !ok {
				return false
			}
			ts.readback = resource
			check(resource->Map(0, nil, (^rawptr)(&ts.mapped)), "IResource.Map(timestamps)") or_return
			ts.spans = make([dynamic]Timestamp_Span, dev.allocator)
		}
		return true
	}
}

@(private)
shutdown_timestamps :: proc() {
	for &frame in dev.frames {
		ts := &frame.timestamps
		release(&ts.readback)
		release(&ts.heap)
		delete(ts.spans)
	}
}

// begin_timestamps gives the profiler the slot's last frame of spans, then starts the slot's new frame. Call it after
// the slot's fence.
@(private)
begin_timestamps :: proc(frame: ^Frame) {
	ts := &frame.timestamps
	if ts.heap == nil {
		return
	}
	if ts.frame != 0 {
		read_timestamps(ts)
	}
	ts.count = FRAME_END_TIMESTAMP + 1
	clear(&ts.spans)
	ts.frame = profile.current_frame()
	ts.resolved = false
	calibrate(&ts.calibration[.Graphics], dev.queue)
	calibrate(&ts.calibration[.Compute], dev.compute_queue)
}

@(private = "file")
calibrate :: proc(c: ^Calibration, queue: ^d3d.ICommandQueue) {
	qpc: u64
	if win.SUCCEEDED(queue->GetClockCalibration(&c.gpu, &qpc)) {
		c.cpu = u64(mul_div(i64(qpc), 1_000_000_000, i64(dev.qpc_frequency)))
	}
}

// mul_div is val * num / den without overflow for large val, as time.tick_now computes nanoseconds from the QPC.
@(private = "file")
mul_div :: proc(val, num, den: i64) -> i64 {
	q := val / den
	r := val % den
	return q * num + r * num / den
}

@(private = "file")
read_timestamps :: proc(ts: ^Timestamps) {
	if !ts.resolved {
		profile.add_gpu(ts.frame, nil, 0, 0)
		return
	}
	to_cpu :: proc(ts: ^Timestamps, queue: gpu.Queue, value: u64) -> u64 {
		c := ts.calibration[queue]
		delta := i64(value) - i64(c.gpu)
		return u64(i64(c.cpu) + mul_div(delta, 1_000_000_000, i64(dev.timestamp_frequency[queue])))
	}
	spans := make([dynamic]profile.Gpu_Span, 0, len(ts.spans), context.temp_allocator)
	for s in ts.spans {
		begin, end := ts.mapped[s.begin], ts.mapped[s.end]
		if end < begin || end - begin > MAX_SPAN * dev.timestamp_frequency[s.queue] / 1_000_000_000 {
			continue
		}
		append(&spans, profile.Gpu_Span{to_cpu(ts, s.queue, begin), to_cpu(ts, s.queue, end), s.name, s.detail, u8(s.queue), s.depth})
	}
	begin := to_cpu(ts, .Graphics, ts.mapped[FRAME_BEGIN_TIMESTAMP])
	end := to_cpu(ts, .Graphics, ts.mapped[FRAME_END_TIMESTAMP])
	if end < begin || end - begin > MAX_SPAN {
		begin, end = 0, 0
	}
	profile.add_gpu(ts.frame, spans[:], begin, end)
}

// write_timestamp writes a timestamp at a fixed index, at the frame's start and end.
@(private)
write_timestamp :: proc(frame: ^Frame, list: ^d3d.IGraphicsCommandList7, index: u32) {
	if ts := &frame.timestamps; ts.heap != nil {
		list->EndQuery(ts.heap, .TIMESTAMP, index)
	}
}

// resolve_timestamps copies the frame's timestamps into the readback buffer. The frame's last graphics list does it,
// after the graphics queue waited for the compute queue.
@(private)
resolve_timestamps :: proc(frame: ^Frame, list: ^d3d.IGraphicsCommandList7) {
	ts := &frame.timestamps
	if ts.heap == nil {
		return
	}
	list->EndQuery(ts.heap, .TIMESTAMP, FRAME_END_TIMESTAMP)
	count := min(u32(sync.atomic_load(&ts.count)), MAX_TIMESTAMPS)
	list->ResolveQueryData(ts.heap, .TIMESTAMP, 0, count, ts.readback, 0)
	ts.resolved = true
}

// Marker_Timer pairs a command list's timed markers while translate records it.
@(private)
Marker_Timer :: struct {
	ts:    ^Timestamps,
	queue: gpu.Queue,
	// For each open marker: its begin index, or -1 for an untimed one or one past MAX_TIMESTAMPS.
	open:  [64]i32,
	names: [64]profile.Name,
	depth: int,
	spans: [dynamic]Timestamp_Span,
}

@(private)
marker_timer :: proc(frame: ^Frame, queue: gpu.Queue) -> Marker_Timer {
	ts := &frame.timestamps
	return {ts = ts if ts.heap != nil else nil, queue = queue, spans = make([dynamic]Timestamp_Span, context.temp_allocator)}
}

@(private)
timer_begin :: proc(t: ^Marker_Timer, list: ^d3d.IGraphicsCommandList7, label: string, timed: bool) {
	index := i32(-1)
	if timed && t.ts != nil {
		if i := sync.atomic_add(&t.ts.count, 1); i < MAX_TIMESTAMPS {
			index = i
			list->EndQuery(t.ts.heap, .TIMESTAMP, u32(i))
		}
	}
	if t.depth < len(t.open) {
		t.open[t.depth] = index
		if index >= 0 {
			t.names[t.depth] = profile.intern(label, .Render)
		}
	}
	t.depth += 1
}

@(private)
timer_end :: proc(t: ^Marker_Timer, list: ^d3d.IGraphicsCommandList7) {
	if t.depth == 0 {
		return
	}
	t.depth -= 1
	if t.depth >= len(t.open) || t.open[t.depth] < 0 {
		return
	}
	end := sync.atomic_add(&t.ts.count, 1)
	if end >= MAX_TIMESTAMPS {
		return
	}
	list->EndQuery(t.ts.heap, .TIMESTAMP, u32(end))
	depth := 0
	for d in 0 ..< t.depth {
		depth += 1 if t.open[d] >= 0 else 0
	}
	append(&t.spans, Timestamp_Span{u32(t.open[t.depth]), u32(end), t.names[t.depth], 0, t.queue, u8(depth)})
}

// timer_finish adds the list's spans to the frame's.
@(private)
timer_finish :: proc(t: ^Marker_Timer) {
	if t.ts == nil || len(t.spans) == 0 {
		return
	}
	sync.guard(&dev.lists_mutex)
	append(&t.ts.spans, ..t.spans[:])
}
