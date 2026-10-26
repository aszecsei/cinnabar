package profile

import "base:runtime"
import "core:hash"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

MAX_NAMES :: 16384
// Names past MAX_NAMES all get this one.
OVERFLOW_NAME :: Name(1)
MAX_LANES :: 64
// Zones that a thread records between two frame boundaries. More are dropped and counted.
LANE_CAPACITY :: 16384
// Open zones per fiber. Deeper zones count for the balance but are not recorded.
MAX_DEPTH :: 32
// The recent frames that a capture can take.
FRAME_RING :: 128
ZONE_POOL :: 1 << 20
GPU_POOL :: 1 << 16
// The worst frames of the recent stats intervals, kept after the ring has moved on: a minute of 250 ms intervals.
PINNED_FRAMES :: 240

@(private)
Open_Zone :: struct {
	start:  u64,
	name:   Name,
	detail: u16,
	flags:  Zone_Flags,
}

// Fiber_Zones is a fiber's stack of open zones. The job system keeps one in each fiber, so a zone moves with its
// fiber between threads.
when ENABLED {
	Fiber_Zones :: struct {
		open:  [MAX_DEPTH]Open_Zone,
		count: int,
		fiber: u8,
	}
} else {
	Fiber_Zones :: struct {}
}

// Frame_Record is a closed frame: its time, its zones in the zone pool and its GPU spans in the GPU pool.
Frame_Record :: struct {
	number:     u64,
	start, end: u64,
	first:      u64,
	count:      u32,
	dropped:    u32,
	// The time the main thread waited in Wait zones.
	wait:       u64,
	gpu_first:  u64,
	gpu_count:  u32,
	// The backend has given the frame's GPU spans, or said that it has none.
	gpu_ready:  bool,
	gpu_none:   bool,
	gpu_begin:  u64,
	gpu_end:    u64,
}

Cost_Kind :: enum u8 {
	System,
	Script,
	Pass,
}

Cost_Key :: struct {
	kind:   Cost_Kind,
	queue:  u8,
	detail: u16,
	name:   Name,
}

Cost :: struct {
	total:    u64,
	max:      u64,
	calls:    u64,
}

Summary_Cost :: struct {
	key:     Cost_Key,
	// Per frame: per profiled frame for systems and scripts, per frame with GPU spans for passes.
	average: f64,
	max:     u64,
	calls:   f64,
}

// Summary is a stats interval: averages per frame and the worst frames.
Summary :: struct {
	first_frame, last_frame:          u64,
	frames, gpu_frames:               u32,
	cpu_average, wait_average:        f64,
	gpu_average:                      f64,
	cpu_max, wait_max, gpu_max:       u64,
	cpu_worst_frame, gpu_worst_frame: u64,
	costs:                            []Summary_Cost,
	dropped:                          u32,
}

// Capture is a frame's zones, with those of its neighbours that overlap it, and its GPU spans.
Capture :: struct {
	frame: Frame_Record,
	zones: []Zone,
	gpu:   []Gpu_Span,
}

@(private)
Name_Entry :: struct {
	text:     string,
	hash:     u64,
	category: Category,
}

@(private)
Lane :: struct {
	records:  []Zone,
	// The writing thread advances head and the frame boundary advances tail.
	head:     u64,
	tail:     u64,
	dropped:  u32,
	index:    u8,
	name:     [32]u8,
	name_len: int,
}

@(private)
Pinned :: struct {
	record: Frame_Record,
	zones:  [dynamic]Zone,
	gpu:    [dynamic]Gpu_Span,
}

@(private)
Interval :: struct {
	frames:                     u32,
	first_frame, last_frame:    u64,
	cpu_total, cpu_max:         u64,
	cpu_worst:                  u64,
	wait_total, wait_max:       u64,
	gpu_frames:                 u32,
	gpu_total, gpu_max:         u64,
	gpu_worst:                  u64,
	costs:                      map[Cost_Key]Cost,
	dropped:                    u32,
}

@(private)
state: struct {
	initialized:  bool,
	recording:    bool,
	names:        []Name_Entry,
	name_count:   int,
	slots:        []u16,
	names_mutex:  sync.Mutex,
	text:         virtual.Arena,
	lanes:        [MAX_LANES]^Lane,
	lane_count:   int,
	lanes_mutex:  sync.Mutex,
	main_lane:    u8,
	// The rest belongs to the main thread.
	frame:        u64,
	frame_start:  u64,
	frames:       [FRAME_RING]Frame_Record,
	pool:         []Zone,
	pool_written: u64,
	gpu_pool:     []Gpu_Span,
	gpu_written:  u64,
	pins:         [PINNED_FRAMES]Pinned,
	pin_next:     int,
	// The worst frames of closed intervals, pinned once their GPU spans arrive.
	to_pin:       [dynamic]u64,
	interval:     Interval,
	frame_costs:  map[Cost_Key]Cost,
}

// Counts init calls, so a thread's lane from an earlier run is not reused. It survives shutdown.
@(private)
generation: u64

@(private, thread_local)
local_lane: ^Lane
@(private, thread_local)
local_generation: u64
// The running fiber's zones, which the job system sets at each switch. Threads without fibers use thread_zones.
@(private, thread_local)
local_zones: ^Fiber_Zones
@(private, thread_local)
thread_zones: Fiber_Zones

// init starts the recorder. Call it from the main thread, before the job system.
init :: proc() -> bool {
	when !ENABLED {
		return true
	} else {
		if err := virtual.arena_init_growing(&state.text); err != nil {
			return false
		}
		generation += 1
		state.names = make([]Name_Entry, MAX_NAMES)
		state.slots = make([]u16, 2 * MAX_NAMES)
		state.names[OVERFLOW_NAME] = {text = "(too many names)", category = .Frame}
		state.name_count = 2
		state.pool = make([]Zone, ZONE_POOL)
		state.gpu_pool = make([]Gpu_Span, GPU_POOL)
		state.interval.costs = make(map[Cost_Key]Cost)
		state.frame_costs = make(map[Cost_Key]Cost)
		state.to_pin = make([dynamic]u64)
		state.initialized = true
		lane := current_lane()
		state.main_lane = lane.index
		set_lane_name(lane, "Main")
		sync.atomic_store(&state.recording, true)
		return true
	}
}

shutdown :: proc() {
	when ENABLED {
		if !state.initialized {
			return
		}
		sync.atomic_store(&state.recording, false)
		for lane in state.lanes[:state.lane_count] {
			delete(lane.records)
			free(lane)
		}
		for &p in state.pins {
			delete(p.zones)
			delete(p.gpu)
		}
		delete(state.names)
		delete(state.slots)
		delete(state.pool)
		delete(state.gpu_pool)
		delete(state.interval.costs)
		delete(state.frame_costs)
		delete(state.to_pin)
		virtual.arena_destroy(&state.text)
		local_zones = nil
		thread_zones = {}
		state = {}
	}
}

// set_recording turns recording on or off. Zones that open while it is off are not recorded.
set_recording :: proc(on: bool) {
	when ENABLED {
		sync.atomic_store(&state.recording, on && state.initialized)
	}
}

recording :: proc() -> bool {
	return sync.atomic_load(&state.recording)
}

// intern gives the name for a text, copying the text the first time.
intern :: proc(text: string, category: Category) -> Name {
	when !ENABLED {
		return NO_NAME
	} else {
		if !state.initialized || text == "" {
			return NO_NAME
		}
		h := text_hash(text)
		if id, found := find_name(text, h); found {
			return id
		}
		sync.guard(&state.names_mutex)
		mask := len(state.slots) - 1
		i := int(h) & mask
		for {
			id := sync.atomic_load_explicit(&state.slots[i], .Acquire)
			if id == 0 {
				break
			}
			if e := &state.names[id]; e.hash == h && e.text == text {
				return Name(id)
			}
			i = (i + 1) & mask
		}
		count := state.name_count
		if count == MAX_NAMES {
			return OVERFLOW_NAME
		}
		state.names[count] = {strings.clone(text, virtual.arena_allocator(&state.text)), h, category}
		sync.atomic_store_explicit(&state.name_count, count + 1, .Release)
		sync.atomic_store_explicit(&state.slots[i], u16(count), .Release)
		return Name(count)
	}
}

@(private = "file")
text_hash :: proc(text: string) -> u64 {
	return hash.fnv64a(transmute([]byte)text)
}

@(private = "file")
find_name :: proc(text: string, h: u64) -> (Name, bool) {
	mask := len(state.slots) - 1
	for i := int(h) & mask;; i = (i + 1) & mask {
		id := sync.atomic_load_explicit(&state.slots[i], .Acquire)
		if id == 0 {
			return NO_NAME, false
		}
		if e := &state.names[id]; e.hash == h && e.text == text {
			return Name(id), true
		}
	}
}

// name_text is a name's text and category. The text stays valid until shutdown.
name_text :: proc(n: Name) -> (string, Category) {
	when ENABLED {
		if state.initialized && int(n) < sync.atomic_load_explicit(&state.name_count, .Acquire) {
			e := &state.names[n]
			return e.text, e.category
		}
	}
	return "", .Frame
}

// name_thread names the calling thread's lane.
name_thread :: proc(text: string) {
	when ENABLED {
		if lane := current_lane(); lane != nil {
			set_lane_name(lane, text)
		}
	}
}

@(private = "file")
set_lane_name :: proc(lane: ^Lane, text: string) {
	lane.name_len = copy(lane.name[:], text)
}

// lane_names lists the threads' lanes by index.
lane_names :: proc(allocator: runtime.Allocator) -> []string {
	count := sync.atomic_load(&state.lane_count)
	names := make([]string, count, allocator)
	for &name, i in names {
		lane := state.lanes[i]
		name = strings.clone(string(lane.name[:lane.name_len]), allocator)
	}
	return names
}

// main_lane is the lane of the thread that called init.
main_lane :: proc() -> u8 {
	return state.main_lane
}

@(private = "file")
now :: #force_inline proc() -> u64 {
	return u64(time.tick_now()._nsec)
}

// A fiber can move to another thread at every wait, so the thread-locals must be read again after each one.
// The call stops the compiler from reusing a thread-local address across a switch.
@(private = "file")
current_zones :: #force_no_inline proc() -> ^Fiber_Zones {
	if local_zones != nil {
		return local_zones
	}
	return &thread_zones
}

@(private = "file")
current_lane :: #force_no_inline proc() -> ^Lane {
	if local_lane != nil && local_generation == generation {
		return local_lane
	}
	if !state.initialized {
		return nil
	}
	sync.guard(&state.lanes_mutex)
	count := state.lane_count
	if count == MAX_LANES {
		return nil
	}
	lane := new(Lane)
	lane.records = make([]Zone, LANE_CAPACITY)
	lane.index = u8(count)
	lane.name_len = len(fmt_thread_name(lane.name[:], count))
	state.lanes[count] = lane
	sync.atomic_store(&state.lane_count, count + 1)
	local_lane, local_generation = lane, generation
	return lane
}

@(private = "file")
fmt_thread_name :: proc(buf: []byte, index: int) -> string {
	prefix :: "Thread "
	n := copy(buf, prefix)
	digits: [8]byte
	d := len(digits)
	for v := index;; v /= 10 {
		d -= 1
		digits[d] = '0' + byte(v % 10)
		if v < 10 {
			break
		}
	}
	n += copy(buf[n:], digits[d:])
	return string(buf[:n])
}

@(private = "file")
write :: proc(z: Zone) {
	lane := current_lane()
	if lane == nil {
		return
	}
	head := lane.head
	if head - sync.atomic_load_explicit(&lane.tail, .Acquire) >= LANE_CAPACITY {
		sync.atomic_add(&lane.dropped, 1)
		return
	}
	z := z
	z.lane = lane.index
	lane.records[head % LANE_CAPACITY] = z
	sync.atomic_store_explicit(&lane.head, head + 1, .Release)
}

@(private = "file")
close_open :: proc(zones: ^Fiber_Zones, depth: int, end: u64, flags: Zone_Flags) {
	when ENABLED {
		o := &zones.open[depth]
		if o.start == 0 || !sync.atomic_load(&state.recording) {
			return
		}
		write({start = o.start, end = end, name = o.name, detail = o.detail, depth = u8(depth), flags = o.flags + flags, fiber = zones.fiber})
	}
}

// begin_zone opens a zone on the calling fiber.
begin_zone :: proc(name: Name, detail: u16) {
	when ENABLED {
		zones := current_zones()
		d := zones.count
		zones.count += 1
		if d >= MAX_DEPTH {
			return
		}
		zones.open[d] = {now() if sync.atomic_load(&state.recording) else 0, name, detail, {}}
	}
}

// end_zone closes the calling fiber's innermost zone.
end_zone :: proc() {
	when ENABLED {
		zones := current_zones()
		if zones.count == 0 {
			return
		}
		zones.count -= 1
		if zones.count < MAX_DEPTH {
			close_open(zones, zones.count, now(), {})
		}
	}
}

zone_depth :: proc() -> int {
	when ENABLED {
		return current_zones().count
	} else {
		return 0
	}
}

close_zones :: proc(depth: int) {
	when ENABLED {
		zones := current_zones()
		t := now()
		for zones.count > max(depth, 0) {
			zones.count -= 1
			if zones.count < MAX_DEPTH {
				close_open(zones, zones.count, t, {.Unbalanced})
			}
		}
	}
}

// zone opens a host zone until the end of the enclosing scope. The host's own code calls the recorder directly.
@(deferred_none = end_zone)
zone :: proc(name: Name, detail: u16 = 0) {
	begin_zone(name, detail)
}

// zone_text interns the name on every call.
@(deferred_none = end_zone)
zone_text :: proc(text: string, category: Category) {
	begin_zone(intern(text, category), 0)
}

// The job system's hooks.

// init_fiber gives a fiber's zones the fiber's index, which links a zone's segments.
init_fiber :: proc(zones: ^Fiber_Zones, index: int) {
	when ENABLED {
		zones^ = {fiber = u8(index + 1)}
	}
}

// set_fiber makes zones the calling thread's open zones, or the thread's own with nil. The scheduler calls it at
// each switch.
set_fiber :: #force_no_inline proc(zones: ^Fiber_Zones) {
	when ENABLED {
		local_zones = zones
	}
}

// fiber_suspend records a segment of each open zone, innermost first, before the fiber switches out.
fiber_suspend :: proc() {
	when ENABLED {
		zones := current_zones()
		t := now()
		for d := min(zones.count, MAX_DEPTH) - 1; d >= 0; d -= 1 {
			close_open(zones, d, t, {.Suspended})
		}
	}
}

// fiber_resume starts a new segment of each open zone after the fiber switched back in, maybe on another thread.
fiber_resume :: proc() {
	when ENABLED {
		zones := current_zones()
		start := now() if sync.atomic_load(&state.recording) else 0
		for &o in zones.open[:min(zones.count, MAX_DEPTH)] {
			o.start = start
			o.flags += {.Resumed}
		}
	}
}

// current_name is the calling fiber's innermost zone, which names the jobs that it starts.
current_name :: proc() -> Name {
	when ENABLED {
		zones := current_zones()
		if zones.count > 0 && zones.count <= MAX_DEPTH {
			return zones.open[zones.count - 1].name
		}
	}
	return NO_NAME
}

// job_begin opens a job's zone, named after the zone that started the job.
job_begin :: proc(parent: Name) {
	when ENABLED {
		begin_zone(parent, 0)
		zones := current_zones()
		zones.open[0].flags += {.Job}
	}
}

// job_end closes the job's zones. Call it before the job counts as finished, so the frame boundary sees its zones.
job_end :: proc() {
	when ENABLED {
		close_zones(1)
		end_zone()
	}
}

// The frame ring.

// current_frame is the number of the frame that is running. Frames count from 1.
current_frame :: proc() -> u64 {
	return state.frame
}

// frame_boundary closes the frame that ran and opens the next. Call it first in each frame, on the main thread.
frame_boundary :: proc() {
	when ENABLED {
		if !state.initialized {
			return
		}
		t := now()
		if state.frame > 0 {
			close_frame(t)
		}
		state.frame += 1
		state.frame_start = t
		pin_ready()
	}
}

@(private = "file")
close_frame :: proc(t: u64) {
	r := &state.frames[state.frame % FRAME_RING]
	r^ = {number = state.frame, start = state.frame_start, end = t, first = state.pool_written}
	for lane in state.lanes[:sync.atomic_load(&state.lane_count)] {
		head := sync.atomic_load_explicit(&lane.head, .Acquire)
		for i in lane.tail ..< head {
			state.pool[state.pool_written % ZONE_POOL] = lane.records[i % LANE_CAPACITY]
			state.pool_written += 1
		}
		sync.atomic_store_explicit(&lane.tail, head, .Release)
		r.dropped += sync.atomic_exchange(&lane.dropped, 0)
	}
	r.count = u32(state.pool_written - r.first)
	measure(r)
}

// measure finds a closed frame's wait and costs. A lane's zones are in the order they ended, so a zone's children come
// right before it: script time is counted without the script callbacks nested in it.
@(private = "file")
measure :: proc(r: ^Frame_Record) {
	clear(&state.frame_costs)
	nested: [MAX_DEPTH + 1]u64
	lane := -1
	for i in r.first ..< r.first + u64(r.count) {
		z := &state.pool[i % ZONE_POOL]
		if int(z.lane) != lane {
			lane = int(z.lane)
			nested = {}
		}
		duration := z.end - z.start
		category := state.names[z.name].category
		d := int(z.depth)
		children := nested[d + 1]
		nested[d + 1] = 0
		if .Job in z.flags {
			nested[d] += children
			continue
		}
		calls := u64(0 if .Resumed in z.flags else 1)
		#partial switch category {
		case .Wait:
			if z.lane == state.main_lane {
				r.wait += duration
			}
		case .System:
			add_cost(&state.frame_costs, {kind = .System, name = z.name}, duration, calls)
		case .Script:
			add_cost(&state.frame_costs, {kind = .Script, detail = z.detail, name = z.name}, duration - min(children, duration), calls)
		}
		nested[d] += duration if category == .Script else children
	}

	iv := &state.interval
	if iv.frames == 0 {
		iv.first_frame = r.number
	}
	iv.last_frame = r.number
	iv.frames += 1
	iv.dropped += r.dropped
	cpu := (r.end - r.start) - min(r.wait, r.end - r.start)
	iv.cpu_total += cpu
	if cpu > iv.cpu_max {
		iv.cpu_max, iv.cpu_worst = cpu, r.number
	}
	iv.wait_total += r.wait
	iv.wait_max = max(iv.wait_max, r.wait)
	fold_costs()
}

@(private = "file")
add_cost :: proc(costs: ^map[Cost_Key]Cost, key: Cost_Key, duration, calls: u64) {
	_, c, _, _ := map_entry(costs, key)
	c.total += duration
	c.calls += calls
}

@(private = "file")
fold_costs :: proc() {
	for key, c in state.frame_costs {
		_, total, _, _ := map_entry(&state.interval.costs, key)
		total.total += c.total
		total.max = max(total.max, c.total)
		total.calls += c.calls
	}
}

// add_gpu gives a frame's GPU spans, between the frame's first and last GPU timestamps. No spans and no times mean
// the frame had no GPU work. The backend calls it once for each frame, a few frames after the frame ends.
add_gpu :: proc(frame: u64, spans: []Gpu_Span, begin, end: u64) {
	when ENABLED {
		r, ok := find_ring(frame)
		if !ok {
			return
		}
		r.gpu_first = state.gpu_written
		for s in spans {
			state.gpu_pool[state.gpu_written % GPU_POOL] = s
			state.gpu_written += 1
		}
		r.gpu_count = u32(len(spans))
		r.gpu_ready = true
		r.gpu_none = len(spans) == 0 && begin == end
		r.gpu_begin, r.gpu_end = begin, end
		if r.gpu_none {
			return
		}
		iv := &state.interval
		gpu := end - min(begin, end)
		iv.gpu_frames += 1
		iv.gpu_total += gpu
		if gpu > iv.gpu_max {
			iv.gpu_max, iv.gpu_worst = gpu, frame
		}
		clear(&state.frame_costs)
		for s in spans {
			add_cost(&state.frame_costs, {kind = .Pass, queue = s.queue, name = s.name}, s.end - min(s.start, s.end), 1 if s.detail == 0 else 0)
		}
		fold_costs()
	}
}

@(private)
find_ring :: proc(number: u64) -> (^Frame_Record, bool) {
	if number == 0 {
		return nil, false
	}
	r := &state.frames[number % FRAME_RING]
	if r.number != number || state.pool_written - r.first > ZONE_POOL {
		return nil, false
	}
	return r, true
}

@(private = "file")
find_pin :: proc(number: u64) -> (^Pinned, bool) {
	if number == 0 {
		return nil, false
	}
	for &p in state.pins {
		if p.record.number == number {
			return &p, true
		}
	}
	return nil, false
}

// frame_state is whether a frame can be captured, and whether its GPU spans have arrived.
frame_state :: proc(number: u64) -> (exists, gpu_ready: bool) {
	if r, ok := find_ring(number); ok {
		return true, r.gpu_ready
	}
	if p, ok := find_pin(number); ok {
		return true, p.record.gpu_ready
	}
	return false, false
}

// worst_recent is the longest of the last count closed frames that the ring still holds, or 0.
worst_recent :: proc(count: int) -> u64 {
	worst, longest: u64
	for back in 1 ..= min(count, FRAME_RING - 4) {
		if u64(back) >= state.frame {
			break
		}
		r, ok := find_ring(state.frame - u64(back))
		if ok && r.end - r.start > longest {
			worst, longest = r.number, r.end - r.start
		}
	}
	return worst
}

// take_summary closes the stats interval. Its worst frames are pinned once their GPU spans arrive.
take_summary :: proc(allocator: runtime.Allocator) -> (s: Summary) {
	iv := &state.interval
	s = {
		first_frame     = iv.first_frame,
		last_frame      = iv.last_frame,
		frames          = iv.frames,
		gpu_frames      = iv.gpu_frames,
		cpu_max         = iv.cpu_max,
		wait_max        = iv.wait_max,
		gpu_max         = iv.gpu_max,
		cpu_worst_frame = iv.cpu_worst,
		gpu_worst_frame = iv.gpu_worst,
		dropped         = iv.dropped,
	}
	frames, gpu_frames := f64(max(iv.frames, 1)), f64(max(iv.gpu_frames, 1))
	s.cpu_average = f64(iv.cpu_total) / frames
	s.wait_average = f64(iv.wait_total) / frames
	s.gpu_average = f64(iv.gpu_total) / gpu_frames
	costs := make([dynamic]Summary_Cost, 0, len(iv.costs), allocator)
	for key, c in iv.costs {
		per := gpu_frames if key.kind == .Pass else frames
		append(&costs, Summary_Cost{key = key, average = f64(c.total) / per, max = c.max, calls = f64(c.calls) / per})
	}
	slice.sort_by(costs[:], proc(a, b: Summary_Cost) -> bool {
		return a.average > b.average
	})
	s.costs = costs[:]
	for worst in ([2]u64{iv.cpu_worst, iv.gpu_worst}) {
		if worst != 0 && !slice.contains(state.to_pin[:], worst) {
			append(&state.to_pin, worst)
		}
	}
	costs_map := iv.costs
	clear(&costs_map)
	iv^ = {costs = costs_map}
	return
}

@(private = "file")
pin_ready :: proc() {
	for i := 0; i < len(state.to_pin); {
		number := state.to_pin[i]
		r, ok := find_ring(number)
		if ok && !r.gpu_ready {
			i += 1
			continue
		}
		if ok {
			pin(r)
		}
		unordered_remove(&state.to_pin, i)
	}
}

@(private = "file")
pin :: proc(r: ^Frame_Record) {
	if _, pinned := find_pin(r.number); pinned {
		return
	}
	p := &state.pins[state.pin_next]
	state.pin_next = (state.pin_next + 1) % PINNED_FRAMES
	p.record = r^
	clear(&p.zones)
	clear(&p.gpu)
	collect(r, &p.zones, &p.gpu)
}

// collect gathers a frame's zones, with the zones of its neighbours that overlap it, and its GPU spans. The frame's
// own zones are those that ended in it.
@(private = "file")
collect :: proc(r: ^Frame_Record, zones: ^[dynamic]Zone, gpu: ^[dynamic]Gpu_Span) {
	for number in r.number - 1 ..= r.number + 1 {
		n, ok := find_ring(number)
		if !ok {
			continue
		}
		for i in n.first ..< n.first + u64(n.count) {
			z := state.pool[i % ZONE_POOL]
			if number == r.number || z.end > r.start && z.start < r.end {
				append(zones, z)
			}
		}
	}
	if r.gpu_ready && state.gpu_written - r.gpu_first <= GPU_POOL {
		for i in r.gpu_first ..< r.gpu_first + u64(r.gpu_count) {
			append(gpu, state.gpu_pool[i % GPU_POOL])
		}
	}
}

// capture copies a frame from the ring or the pinned frames.
capture :: proc(number: u64, allocator: runtime.Allocator) -> (c: Capture, ok: bool) {
	zones := make([dynamic]Zone, allocator)
	gpu := make([dynamic]Gpu_Span, allocator)
	if r, found := find_ring(number); found {
		collect(r, &zones, &gpu)
		return {r^, zones[:], gpu[:]}, true
	}
	if p, found := find_pin(number); found {
		append(&zones, ..p.zones[:])
		append(&gpu, ..p.gpu[:])
		return {p.record, zones[:], gpu[:]}, true
	}
	return {}, false
}
