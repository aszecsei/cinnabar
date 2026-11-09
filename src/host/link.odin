package host

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/profile"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/wire/serve"

// Host_Stats go out this often.
STATS_INTERVAL :: 250 * time.Millisecond

// The host's side of the editor link (see docs/editor/link.md#editor-link). Its server listens on loopback for one
// editor at a time, and owns which connection is linked. The main thread handles the editor's messages between frames.
Link :: struct {
	server:          serve.Server,
	// The main thread's own state.
	sent_generation: i64,
	decode_arena:    virtual.Arena,
	// What the game's editor_poll wrote, before it goes into the outbox. The game appends to it with the host's heap.
	game_out:        [dynamic]byte,
	game:            string,
	layout_hash:     u64,
	// The frames since the last Host_Stats.
	stats:           Frame_Stats,
	// The editor's capture requests that wait for their frames.
	captures:        [dynamic]Pending_Capture,
	// The host's screenshots and history ring, which capture_start sets (see capture.odin).
	capture:         ^Capture,
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

// link_start listens on 127.0.0.1:port. Only the local machine can connect.
link_start :: proc(l: ^Link, port: int, game: string) -> bool {
	serve.start(&l.server, "host: editor link", port, write_log) or_return
	l.game_out = make([dynamic]byte, runtime.heap_allocator())
	l.captures = make([dynamic]Pending_Capture, runtime.heap_allocator())
	l.sent_generation = -1
	l.game = game
	return true
}

link_stop :: proc(l: ^Link) {
	if l.server.acceptor == nil {
		return
	}
	serve.stop(&l.server)
	virtual.arena_destroy(&l.decode_arena)
	delete(l.game_out)
	delete(l.captures)
}

// link_logger logs to the editor while one is linked, and to the console otherwise.
link_logger :: proc(l: ^Link) -> log.Logger {
	return serve.logger(&l.server)
}

// write_log is the server's Write_Log: a log line as the editor link's Log.
@(private = "file")
write_log :: proc(out: ^[dynamic]byte, level: log.Level, time: i64, location: string, text: string) {
	link.write_message(out, link.Log{level = log_level(level), time = time, location = location, text = text})
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

// link_send queues a message for the linked editor, if there is one.
link_send :: proc(l: ^Link, message: link.Message, request: u32 = 0) {
	serve.send_linked(&l.server, message, request)
}

// link_reply queues a message for a connection, if it is still the one that is open, linked or not.
@(private = "file")
link_reply :: proc(l: ^Link, connection: u64, message: link.Message) {
	serve.send(&l.server, connection, message)
}

// link_linked is true while an editor is linked.
link_linked :: proc(l: ^Link) -> bool {
	return serve.linked(&l.server) != 0
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
	if l.server.acceptor == nil {
		return
	}
	profile.zone_text("Editor link", .Editor)
	taken := serve.take(&l.server)
	defer serve.release(taken)
	handle_taken(l, taken, game, state)
}

// handle_taken handles what one take gave. The connection can close while it runs: the server then drops what goes
// to it, and does not link it.
@(private)
handle_taken :: proc(l: ^Link, taken: serve.Taken, game: core.Game_API, state: rawptr) {
	if taken.unlinked {
		core.pace_shared_frames(false)
		// Keys that the editor held stay down otherwise.
		core.queue_input({{kind = .Release_All}})
		// And no one reads the pads any more.
		for pad in 0 ..< core.MAX_GAMEPADS {
			core.queue_input({{kind = .Gamepad, pad = u8(pad)}})
		}
		clear(&l.captures)
		if l.capture != nil {
			capture_disconnect(l.capture)
		}
		profile.set_recording(true)
		log.info("host: the editor disconnected")
	}
	arena := virtual.arena_allocator(&l.decode_arena)
	for_game := make([dynamic]core.Editor_Message, arena)
	for m in taken.incoming {
		if !is_host_message(m.header.kind) {
			append(&for_game, core.Editor_Message{kind = m.header.kind, request = m.header.request, payload = m.payload})
			continue
		}
		message, ok := link.decode_message(m.header.kind, m.payload, arena)
		if !ok {
			log.warnf("host: editor link: cannot decode a message of kind %d", m.header.kind)
			continue
		}
		handle_message(l, message, taken.connection)
	}
	if game.editor_poll != nil {
		// The game logs while it polls, and the logger takes the server's mutex, so the game writes to its own buffer.
		clear(&l.game_out)
		linked := serve.linked(&l.server)
		game.editor_poll(state, linked, for_game[:], &l.game_out)
		if len(l.game_out) > 0 && linked != 0 {
			serve.send_bytes(&l.server, linked, l.game_out[:])
		}
	}
	virtual.arena_free_all(&l.decode_arena)

	if link_linked(l) {
		prefix, generation, size := core.shared_target()
		if i64(generation) != l.sent_generation {
			l.sent_generation = i64(generation)
			link_send(l, link.Frame_Target{prefix = prefix, generation = generation, width = size.x, height = size.y})
		}
	}
	if taken.dropped_logs > 0 {
		log.warnf("host: editor link: dropped %d log lines while the editor was slow to read", taken.dropped_logs)
	}
	if link_linked(l) {
		send_captures(l)
		send_stats(l)
	}
}

// is_host_message is true for the messages that the host handles itself: they need no game state. The game's
// editor_poll gets the others.
@(private = "file")
is_host_message :: proc(kind: u16) -> bool {
	switch kind {
	case link.kind_of(link.Hello), link.kind_of(link.Viewport_Size), link.kind_of(link.Frame_Acknowledged), link.kind_of(link.Preview_Acknowledged), link.kind_of(link.Viewport_Acknowledged), link.kind_of(link.Editor_Input), link.kind_of(link.Profile_Capture_Request), link.kind_of(link.Profile_Recording), link.kind_of(link.Capture_Request):
		return true
	case link.kind_of(link.Welcome), link.kind_of(link.Refused), link.kind_of(link.Log), link.kind_of(link.Game_Reloaded), link.kind_of(link.Frame_Target), link.kind_of(link.Host_Stats), link.kind_of(link.Profile_Summary), link.kind_of(link.Profile_Capture), link.kind_of(link.Capture_Result):
		// Only the host sends these, so handle_message reports them.
		return true
	}
	return false
}

// handle_message handles a message of the connection that is open. Only the Hello is handled before it is linked.
@(private = "file")
handle_message :: proc(l: ^Link, message: link.Message, connection: u64) {
	linked := serve.linked(&l.server) == connection
	switch m in message {
	case link.Hello:
		version := link.protocol_version()
		if m.protocol != version {
			reason := fmt.tprintf("the editor's protocol is %016x and the host's is %016x. Rebuild both with just build editor.", m.protocol, version)
			link_reply(l, connection, link.Refused{reason = reason, protocol = version})
			log.errorf("host: editor link: %s", reason)
			return
		}
		// The Welcome goes out before the link, and so before the first log line, so the editor sees it first.
		link_reply(l, connection, link.Welcome{protocol = version, game = l.game, layout_hash = l.layout_hash})
		if !serve.link(&l.server, connection) {
			log.infof("host: editor link: %s disconnected before it was linked", m.editor)
			return
		}
		l.sent_generation = -1
		core.pace_shared_frames(true)
		log.infof("host: linked to %s", m.editor)
	case link.Viewport_Size:
		if linked {
			core.resize_shared_target({m.width, m.height})
		}
	case link.Frame_Acknowledged:
		if linked {
			core.acknowledge_shared_frame(m.generation, m.frame)
		}
	case link.Preview_Acknowledged:
		if linked {
			core.acknowledge_preview_frame(int(m.id), m.generation, m.frame)
		}
	case link.Viewport_Acknowledged:
		// Viewport 0 is the frame target, which a Frame_Acknowledged acknowledges.
		if linked && m.viewport > 0 {
			core.acknowledge_viewport_frame(int(m.viewport) - 1, m.generation, m.frame)
		}
	case link.Editor_Input:
		if linked {
			events := make([]core.Input_Event, len(m.events), context.temp_allocator)
			for e, i in m.events {
				events[i] = {
					kind = core.Input_Event_Kind(e.kind),
					key = core.Key(e.key),
					position = e.position,
					scroll = e.scroll,
					pad = e.pad,
					reading = {
						connected = e.connected,
						buttons = transmute(core.Gamepad_Buttons)e.buttons,
						axes = transmute([core.Gamepad_Axis]f32)e.axes,
					},
					cursor = e.cursor,
				}
				// The event keeps its own copy: the message goes with this poll's arena, before the next frame applies it.
				core.input_text_append(&events[i].text, e.text)
			}
			core.queue_input(events)
		}
	case link.Profile_Capture_Request:
		if linked {
			request_capture(l, m)
		}
	case link.Profile_Recording:
		if linked {
			profile.set_recording(m.recording)
		}
	case link.Capture_Request:
		if linked && l.capture != nil {
			capture_request(l.capture, m)
		}
	case link.Welcome, link.Refused, link.Log, link.Game_Reloaded, link.Frame_Target, link.Host_Stats, link.Profile_Summary, link.Profile_Capture, link.Capture_Result:
		log.warnf("host: editor link: the editor sent a message that only the host sends: %v", message)
	case link.Component_Types, link.Entity_Snapshot, link.Entity_Delta, link.Watch_Entity, link.Unwatch_Entity, link.Entity_Values, link.Load_Scene, link.Apply_Operations, link.Edit_Problems, link.Editor_Camera, link.Set_Selection, link.Gizmo_State, link.Pick_Request, link.Pick_Result, link.Set_Hidden, link.Set_Mode, link.Step_Frame, link.Game_Stats, link.Game_Commands, link.Run_Game_Command, link.Game_Command_Result, link.Open_Preview, link.Preview_Settings, link.Close_Preview, link.Preview_Target, link.Set_Viewport_Settings, link.Open_Viewport, link.Close_Viewport, link.Viewport_Target, link.Live_Mesh, link.Live_Mesh_Vertices, link.Release_Live_Mesh, link.Mesh_Overlay, link.Sky_Sun_Request, link.Sky_Sun, link.Animator_View, link.Set_Preview_Parameter, link.Restart_Preview, link.Ui_Preview_Settings, link.Ui_Preview_Layout, link.Capture_Reflection_Probes, link.Reflection_Probe_View, link.Box_Handles, link.Bake_Thumbnail, link.Thumbnail_Failed:
		// is_host_message sends these to the game.
	}
}

// The editor's input is core's, value for value.
#assert(len(link.Input_Key) == len(core.Key))
#assert(int(link.Input_Key.Mouse_5) == int(core.Key.Mouse_5) && int(link.Input_Key.F1) == int(core.Key.F1))
#assert(len(link.Input_Event_Kind) == len(core.Input_Event_Kind))
#assert(int(link.Input_Event_Kind.Release_All) == int(core.Input_Event_Kind.Release_All))
#assert(int(link.Input_Event_Kind.Composition) == int(core.Input_Event_Kind.Composition))
#assert(len(core.Gamepad_Axis) == 6 && size_of(core.Gamepad_Buttons) == size_of(u16))
