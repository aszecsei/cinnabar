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
import "cinnabar:engine/editor/link"

// While the editor is slow to read, log lines beyond this much unsent data are dropped and counted.
MAX_OUTBOX :: 16 * mem.Megabyte

// The host's side of the editor link (see docs/editor.md#editor-link). It listens on loopback for one editor at a
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
	game:              string,
	layout_hash:       u64,
	console:           log.Logger,
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

// link_poll handles the editor's messages and sends the events of this frame. The main thread calls it between
// frames, while no job runs.
link_poll :: proc(l: ^Link) {
	if l.acceptor == nil {
		return
	}
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
		log.info("host: the editor disconnected")
	}
	for m in incoming {
		defer delete(m.payload, runtime.heap_allocator())
		if !connected || m.connection != connection {
			continue
		}
		message, ok := link.decode_message(m.header.kind, m.payload, virtual.arena_allocator(&l.decode_arena))
		if !ok {
			log.warnf("host: editor link: cannot decode a message of kind %d", m.header.kind)
			continue
		}
		handle_message(l, message, connection)
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
	case link.Welcome, link.Refused, link.Log, link.Game_Reloaded, link.Frame_Target:
		log.warnf("host: editor link: the editor sent a message that only the host sends: %v", message)
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
