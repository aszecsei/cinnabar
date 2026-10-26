package host

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/profile"
import "cinnabar:engine/editor/link"

// While the editor is slow to read, log lines beyond this much unsent data are dropped and counted.
MAX_OUTBOX :: 16 * mem.Megabyte
// Host_Stats go out this often.
STATS_INTERVAL :: 250 * time.Millisecond

// The host's side of the editor link (see docs/editor/link.md#editor-link). It listens on loopback for one editor at a
// time. A reader thread queues the editor's messages, and the main thread handles them between frames. Everything
// that the host sends, the log included, goes into the outbox, and a writer thread sends it.
Link :: struct {
	listener:          net.TCP_Socket,
	acceptor:          ^thread.Thread,
	// Guards the fields down to dropped_logs, which the reader, writer and logger threads use.
	mutex:             sync.Mutex,
	client:            net.TCP_Socket,
	connected:         bool,
	// Counts connections, so a thread or a message of an old connection is recognised.
	connection:        u64,
	inbox:             [dynamic]Incoming,
	outbox:            [dynamic]byte,
	wake:              sync.Cond,
	dropped_logs:      int,
	// The logger sends to the editor while this is set, and to the console otherwise.
	logging_to_editor: bool,
	closing:           bool,
	// The main thread's own state.
	linked:            bool,
	linked_connection: u64,
	sent_generation:   i64,
	decode_arena:      virtual.Arena,
	// What the game's editor_poll wrote, before it goes into the outbox. The game appends to it with the host's heap.
	game_out:          [dynamic]byte,
	game:              string,
	layout_hash:       u64,
	console:           log.Logger,
	// The frames since the last Host_Stats.
	stats:             Frame_Stats,
	// The editor's capture requests that wait for their frames.
	captures:          [dynamic]Pending_Capture,
}

// Frame_Stats adds up the frames of an interval.
Frame_Stats :: struct {
	start:       time.Tick,
	frames:      u32,
	frame_total: time.Duration,
	frame_max:   time.Duration,
	work_total:  time.Duration,
	work_max:    time.Duration,
}

@(private = "file")
Incoming :: struct {
	connection: u64,
	header:     link.Header,
	// From the heap. The main thread frees it after handling it.
	payload:    []byte,
}

@(private = "file")
Connection :: struct {
	l:          ^Link,
	connection: u64,
	client:     net.TCP_Socket,
}

// link_start listens on 127.0.0.1:port. Only the local machine can connect.
link_start :: proc(l: ^Link, port: int, game: string) -> bool {
	listener, err := net.listen_tcp({net.IP4_Loopback, port})
	if err != nil {
		log.errorf("host: editor link: cannot listen on port %d: %v", port, err)
		return false
	}
	l.listener = listener
	l.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	l.outbox = make([dynamic]byte, runtime.heap_allocator())
	l.game_out = make([dynamic]byte, runtime.heap_allocator())
	l.captures = make([dynamic]Pending_Capture, runtime.heap_allocator())
	l.sent_generation = -1
	l.game = game
	l.console = context.logger
	l.acceptor = thread.create_and_start_with_poly_data(l, accept_loop, context)
	log.infof("host: editor link: listening on 127.0.0.1:%d", port)
	return true
}

link_stop :: proc(l: ^Link) {
	if l.acceptor == nil {
		return
	}
	sync.atomic_store(&l.logging_to_editor, false)
	sync.atomic_store(&l.closing, true)
	net.close(l.listener)
	sync.lock(&l.mutex)
	if l.connected {
		l.connected = false
		net.close(l.client)
		sync.cond_broadcast(&l.wake)
	}
	sync.unlock(&l.mutex)
	thread.join(l.acceptor)
	thread.destroy(l.acceptor)
	l.acceptor = nil
	virtual.arena_destroy(&l.decode_arena)
	delete(l.game_out)
	delete(l.captures)
}

// link_logger logs to the editor while one is linked, and to the console otherwise.
link_logger :: proc(l: ^Link) -> log.Logger {
	return {procedure = link_logger_proc, data = l, lowest_level = l.console.lowest_level, options = l.console.options}
}

@(private = "file")
link_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	l := (^Link)(data)
	if !sync.atomic_load(&l.logging_to_editor) {
		l.console.procedure(l.console.data, level, text, options, location)
		return
	}
	// Any thread logs, inside jobs too, so this allocates nothing but outbox growth.
	location_buf: [256]byte
	where_ := fmt.bprintf(location_buf[:], "%s:%d:%s()", filepath.base(location.file_path), location.line, location.procedure)
	message := link.Log {
		level    = log_level(level),
		time     = time.to_unix_nanoseconds(time.now()),
		location = where_,
		text     = text,
	}
	sync.lock(&l.mutex)
	defer sync.unlock(&l.mutex)
	if l.connected && len(l.outbox) < MAX_OUTBOX {
		link.write_message(&l.outbox, message)
		sync.cond_signal(&l.wake)
	} else {
		l.dropped_logs += 1
	}
}

@(private = "file")
log_level :: proc(level: log.Level) -> link.Log_Level {
	switch {
	case level >= .Fatal:
		return .Fatal
	case level >= .Error:
		return .Error
	case level >= .Warning:
		return .Warning
	case level >= .Info:
		return .Info
	}
	return .Debug
}

// link_send queues a message for the editor, if one is connected.
link_send :: proc(l: ^Link, message: link.Message, request: u32 = 0) {
	sync.lock(&l.mutex)
	defer sync.unlock(&l.mutex)
	if l.connected {
		link.write_message(&l.outbox, message, request)
		sync.cond_signal(&l.wake)
	}
}

// link_frame counts a frame: the time since the last one started, and the time that the game's update and the frame's
// end took.
link_frame :: proc(l: ^Link, frame, work: time.Duration) {
	s := &l.stats
	s.frames += 1
	s.frame_total += frame
	s.frame_max = max(s.frame_max, frame)
	s.work_total += work
	s.work_max = max(s.work_max, work)
}

// send_stats sends Host_Stats once an interval has passed.
@(private = "file")
send_stats :: proc(l: ^Link) {
	s := &l.stats
	if s.start == {} {
		s.start = time.tick_now()
	}
	interval := time.tick_since(s.start)
	if interval < STATS_INTERVAL {
		return
	}
	ms :: proc(d: time.Duration) -> f32 {
		return f32(time.duration_milliseconds(d))
	}
	frames := max(s.frames, 1)
	gpu := core.gpu_stats()
	permanent, frame_max := core.memory_stats()
	// Right before the Host_Stats of the same interval, which the editor pairs it with.
	link_send(l, profile_summary(context.temp_allocator))
	link_send(
		l,
		link.Host_Stats {
			interval = f32(time.duration_seconds(interval)),
			frames = s.frames,
			frame_ms_average = ms(s.frame_total) / f32(frames),
			frame_ms_max = ms(s.frame_max),
			work_ms_average = ms(s.work_total) / f32(frames),
			work_ms_max = ms(s.work_max),
			permanent_bytes = permanent,
			frame_bytes_max = frame_max,
			upload_bytes_max = gpu.upload_bytes_max,
			buffers = gpu.buffers,
			textures = gpu.textures,
			samplers = gpu.samplers,
			pipelines = gpu.pipelines,
			accels = gpu.accels,
			video_memory_used = gpu.video_memory_used,
			video_memory_budget = gpu.video_memory_budget,
		},
	)
	s^ = {start = time.tick_now()}
}

// link_poll handles the editor's messages, passes the game's to Game_API.editor_poll, and sends the events of this
// frame. The main thread calls it between frames, while no job runs.
link_poll :: proc(l: ^Link, game: core.Game_API, state: rawptr) {
	if l.acceptor == nil {
		return
	}
	profile.zone_text("Editor link", .Editor)
	sync.lock(&l.mutex)
	incoming := l.inbox
	l.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	connected, connection := l.connected, l.connection
	dropped := l.dropped_logs
	l.dropped_logs = 0
	sync.unlock(&l.mutex)
	defer delete(incoming)

	if l.linked && (!connected || connection != l.linked_connection) {
		l.linked = false
		core.pace_shared_frames(false)
		// Keys that the editor held stay down otherwise.
		core.queue_input({{kind = .Release_All}})
		clear(&l.captures)
		profile.set_recording(true)
		log.info("host: the editor disconnected")
	}
	arena := virtual.arena_allocator(&l.decode_arena)
	for_game := make([dynamic]core.Editor_Message, arena)
	for m in incoming {
		if !connected || m.connection != connection {
			continue
		}
		if !is_host_message(m.header.kind) {
			append(&for_game, core.Editor_Message{kind = m.header.kind, request = m.header.request, payload = m.payload})
			continue
		}
		message, ok := link.decode_message(m.header.kind, m.payload, arena)
		if !ok {
			log.warnf("host: editor link: cannot decode a message of kind %d", m.header.kind)
			continue
		}
		handle_message(l, message, connection)
	}
	if game.editor_poll != nil {
		// The game logs while it polls, and the logger takes the mutex, so the game writes to its own buffer.
		clear(&l.game_out)
		game.editor_poll(state, l.linked_connection if l.linked else 0, for_game[:], &l.game_out)
		if len(l.game_out) > 0 {
			sync.lock(&l.mutex)
			if l.connected && l.connection == l.linked_connection {
				append(&l.outbox, ..l.game_out[:])
				sync.cond_signal(&l.wake)
			}
			sync.unlock(&l.mutex)
		}
	}
	for m in incoming {
		delete(m.payload, runtime.heap_allocator())
	}
	virtual.arena_free_all(&l.decode_arena)

	if l.linked {
		prefix, generation, size := core.shared_target()
		if i64(generation) != l.sent_generation {
			l.sent_generation = i64(generation)
			link_send(l, link.Frame_Target{prefix = prefix, generation = generation, width = size.x, height = size.y})
		}
	}
	if dropped > 0 {
		log.warnf("host: editor link: dropped %d log lines while the editor was slow to read", dropped)
	}
	if l.linked {
		send_captures(l)
		send_stats(l)
	}
}

// is_host_message is true for the messages that the host handles itself: they need no game state. The game's
// editor_poll gets the others.
@(private = "file")
is_host_message :: proc(kind: u16) -> bool {
	switch kind {
	case link.kind_of(link.Hello), link.kind_of(link.Viewport_Size), link.kind_of(link.Frame_Acknowledged), link.kind_of(link.Preview_Acknowledged), link.kind_of(link.Editor_Input), link.kind_of(link.Profile_Capture_Request), link.kind_of(link.Profile_Recording):
		return true
	case link.kind_of(link.Welcome), link.kind_of(link.Refused), link.kind_of(link.Log), link.kind_of(link.Game_Reloaded), link.kind_of(link.Frame_Target), link.kind_of(link.Host_Stats), link.kind_of(link.Profile_Summary), link.kind_of(link.Profile_Capture):
		// Only the host sends these, so handle_message reports them.
		return true
	}
	return false
}

@(private = "file")
handle_message :: proc(l: ^Link, message: link.Message, connection: u64) {
	switch m in message {
	case link.Hello:
		version := link.protocol_version()
		if m.protocol != version {
			reason := fmt.tprintf("the editor's protocol is %016x and the host's is %016x. Rebuild both with just build editor.", m.protocol, version)
			link_send(l, link.Refused{reason = reason, protocol = version})
			log.errorf("host: editor link: %s", reason)
			return
		}
		// The Welcome goes out before the first log line, so the editor sees it first.
		link_send(l, link.Welcome{protocol = version, game = l.game, layout_hash = l.layout_hash})
		l.linked = true
		l.linked_connection = connection
		l.sent_generation = -1
		core.pace_shared_frames(true)
		sync.atomic_store(&l.logging_to_editor, true)
		log.infof("host: linked to %s", m.editor)
	case link.Viewport_Size:
		if l.linked {
			core.resize_shared_target({m.width, m.height})
		}
	case link.Frame_Acknowledged:
		if l.linked {
			core.acknowledge_shared_frame(m.generation, m.frame)
		}
	case link.Preview_Acknowledged:
		if l.linked {
			core.acknowledge_preview_frame(int(m.id), m.generation, m.frame)
		}
	case link.Editor_Input:
		if l.linked {
			events := make([]core.Input_Event, len(m.events), context.temp_allocator)
			for e, i in m.events {
				events[i] = {kind = core.Input_Event_Kind(e.kind), key = core.Key(e.key), position = e.position, scroll = e.scroll}
			}
			core.queue_input(events)
		}
	case link.Profile_Capture_Request:
		if l.linked {
			request_capture(l, m)
		}
	case link.Profile_Recording:
		if l.linked {
			profile.set_recording(m.recording)
		}
	case link.Welcome, link.Refused, link.Log, link.Game_Reloaded, link.Frame_Target, link.Host_Stats, link.Profile_Summary, link.Profile_Capture:
		log.warnf("host: editor link: the editor sent a message that only the host sends: %v", message)
	case link.Component_Types, link.Entity_Snapshot, link.Entity_Delta, link.Watch_Entity, link.Unwatch_Entity, link.Entity_Values, link.Load_Scene, link.Apply_Operations, link.Edit_Problems, link.Editor_Camera, link.Set_Selection, link.Gizmo_State, link.Pick_Request, link.Pick_Result, link.Set_Hidden, link.Set_Mode, link.Step_Frame, link.Game_Stats, link.Game_Commands, link.Run_Game_Command, link.Game_Command_Result, link.Open_Preview, link.Preview_Settings, link.Close_Preview, link.Preview_Target, link.Viewport_Settings:
		// is_host_message sends these to the game.
	}
}

@(private = "file")
accept_loop :: proc(l: ^Link) {
	for {
		client, _, err := net.accept_tcp(l.listener)
		if sync.atomic_load(&l.closing) {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			log.warnf("host: editor link: accept: %v", err)
			time.sleep(100 * time.Millisecond)
			continue
		}
		sync.lock(&l.mutex)
		busy := l.connected
		if !busy {
			l.client = client
			l.connected = true
			l.connection += 1
			// Whatever was queued for an earlier editor is not for this one.
			clear(&l.outbox)
		}
		c := Connection{l, l.connection, client}
		sync.unlock(&l.mutex)
		if busy {
			net.close(client)
			log.warn("host: editor link: another editor is linked, so a new connection was refused")
			continue
		}
		thread.create_and_start_with_poly_data(c, read_loop, context, self_cleanup = true)
		thread.create_and_start_with_poly_data(c, write_loop, context, self_cleanup = true)
	}
}

@(private = "file")
read_loop :: proc(c: Connection) {
	defer disconnect(c)
	header_bytes: [link.HEADER_SIZE]byte
	for {
		if !recv_all(c.client, header_bytes[:]) {
			return
		}
		header, ok := link.read_header(header_bytes[:])
		if !ok {
			log.warn("host: editor link: the editor sent a message that is too long, so the link is closed")
			return
		}
		payload := make([]byte, header.length, runtime.heap_allocator())
		if !recv_all(c.client, payload) {
			delete(payload, runtime.heap_allocator())
			return
		}
		sync.lock(&c.l.mutex)
		append(&c.l.inbox, Incoming{c.connection, header, payload})
		sync.unlock(&c.l.mutex)
	}
}

@(private = "file")
write_loop :: proc(c: Connection) {
	l := c.l
	sending := make([dynamic]byte, runtime.heap_allocator())
	defer delete(sending)
	for {
		sync.lock(&l.mutex)
		for len(l.outbox) == 0 && l.connected && l.connection == c.connection {
			sync.cond_wait(&l.wake, &l.mutex)
		}
		if !l.connected || l.connection != c.connection {
			sync.unlock(&l.mutex)
			return
		}
		// The writer sends one buffer while the others fill the other.
		sending, l.outbox = l.outbox, sending
		sync.unlock(&l.mutex)
		if !send_all(c.client, sending[:]) {
			disconnect(c)
			return
		}
		clear(&sending)
	}
}

// disconnect closes a connection once, whichever of its threads notices first.
@(private = "file")
disconnect :: proc(c: Connection) {
	l := c.l
	sync.lock(&l.mutex)
	defer sync.unlock(&l.mutex)
	if l.connected && l.connection == c.connection {
		l.connected = false
		sync.atomic_store(&l.logging_to_editor, false)
		net.close(l.client)
		sync.cond_broadcast(&l.wake)
	}
}

@(private = "file")
recv_all :: proc(client: net.TCP_Socket, buf: []byte) -> bool {
	for done := 0; done < len(buf); {
		n, err := net.recv_tcp(client, buf[done:])
		if err != nil || n == 0 {
			return false
		}
		done += n
	}
	return true
}

@(private = "file")
send_all :: proc(client: net.TCP_Socket, buf: []byte) -> bool {
	for done := 0; done < len(buf); {
		n, err := net.send_tcp(client, buf[done:])
		if err != nil || n <= 0 {
			return false
		}
		done += n
	}
	return true
}

// The editor's input is core's, value for value.
#assert(len(link.Input_Key) == len(core.Key))
#assert(int(link.Input_Key.Mouse_5) == int(core.Key.Mouse_5) && int(link.Input_Key.F1) == int(core.Key.F1))
#assert(len(link.Input_Event_Kind) == len(core.Input_Event_Kind))
