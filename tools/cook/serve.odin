package cook

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"

import cook_link "cinnabar:engine/asset/cook_link"

// While the editor is slow to read, log lines beyond this much unsent data are dropped and counted.
MAX_OUTBOX :: 16 * mem.Megabyte

// Server is the daemon's side of the cook link (see docs/content/daemon-and-operations.md#cook-link), as the host serves the editor
// link. It listens on loopback for one editor at a time. A reader thread queues the editor's messages and wakes the
// main thread, which handles them between passes. Everything that the daemon sends, the log included, goes into the
// outbox, and a writer thread sends it.
Server :: struct {
	listener:          net.TCP_Socket,
	acceptor:          ^thread.Thread,
	// Called from the reader thread when a message arrives or the editor leaves, to wake the main thread.
	wake:              proc(data: rawptr),
	wake_data:         rawptr,
	// Guards the fields down to closing, which the reader, writer and logger threads use.
	mutex:             sync.Mutex,
	client:            net.TCP_Socket,
	connected:         bool,
	// Counts connections, so a thread or a message of an old connection is recognised.
	connection:        u64,
	inbox:             [dynamic]Incoming,
	outbox:            [dynamic]byte,
	outbox_ready:      sync.Cond,
	dropped_logs:      int,
	// The logger sends to the editor while this is set, and to the console otherwise.
	logging_to_editor: bool,
	closing:           bool,
	console:           log.Logger,
}

Incoming :: struct {
	connection: u64,
	header:     cook_link.Header,
	// From the heap. server_take's caller frees it with server_release.
	payload:    []byte,
}

@(private = "file")
Connection :: struct {
	s:          ^Server,
	connection: u64,
	client:     net.TCP_Socket,
}

// server_start listens on 127.0.0.1:port. Only the local machine can connect.
server_start :: proc(s: ^Server, port: int, wake: proc(data: rawptr), wake_data: rawptr) -> bool {
	listener, err := net.listen_tcp({net.IP4_Loopback, port})
	if err != nil {
		log.errorf("cook: cook link: cannot listen on port %d: %v", port, err)
		return false
	}
	s.listener = listener
	s.wake = wake
	s.wake_data = wake_data
	s.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	s.outbox = make([dynamic]byte, runtime.heap_allocator())
	s.console = context.logger
	s.acceptor = thread.create_and_start_with_poly_data(s, accept_loop, context)
	log.infof("cook: cook link: listening on 127.0.0.1:%d", port)
	return true
}

server_stop :: proc(s: ^Server) {
	if s.acceptor == nil {
		return
	}
	sync.atomic_store(&s.logging_to_editor, false)
	sync.atomic_store(&s.closing, true)
	net.close(s.listener)
	sync.lock(&s.mutex)
	if s.connected {
		s.connected = false
		net.close(s.client)
		sync.cond_broadcast(&s.outbox_ready)
	}
	sync.unlock(&s.mutex)
	thread.join(s.acceptor)
	thread.destroy(s.acceptor)
	s.acceptor = nil
}

// server_logger logs to the editor while one is linked, and to the console otherwise.
server_logger :: proc(s: ^Server) -> log.Logger {
	return {procedure = server_logger_proc, data = s, lowest_level = s.console.lowest_level, options = s.console.options}
}

@(private = "file")
server_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	s := (^Server)(data)
	if !sync.atomic_load(&s.logging_to_editor) {
		s.console.procedure(s.console.data, level, text, options, location)
		return
	}
	location_buf: [256]byte
	where_ := fmt.bprintf(location_buf[:], "%s:%d:%s()", filepath.base(location.file_path), location.line, location.procedure)
	message := cook_link.Log {
		level    = log_level(level),
		time     = time.to_unix_nanoseconds(time.now()),
		location = where_,
		text     = text,
	}
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if s.connected && len(s.outbox) < MAX_OUTBOX {
		cook_link.write_message(&s.outbox, message)
		sync.cond_signal(&s.outbox_ready)
	} else {
		s.dropped_logs += 1
	}
}

@(private = "file")
log_level :: proc(level: log.Level) -> cook_link.Log_Level {
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

// server_log_to_editor sends the log to the editor from now on, or to the console again.
server_log_to_editor :: proc(s: ^Server, on: bool) {
	sync.atomic_store(&s.logging_to_editor, on)
}

// server_send queues a message for a connection, if it is still the connected one.
server_send :: proc(s: ^Server, connection: u64, message: cook_link.Message, request: u32 = 0) {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if s.connected && s.connection == connection {
		cook_link.write_message(&s.outbox, message, request)
		sync.cond_signal(&s.outbox_ready)
	}
}

// server_take gives the main thread the messages that arrived, and the connection that is open now, or 0.
server_take :: proc(s: ^Server) -> (incoming: [dynamic]Incoming, connection: u64, dropped_logs: int) {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	incoming = s.inbox
	s.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	dropped_logs = s.dropped_logs
	s.dropped_logs = 0
	return incoming, s.connection if s.connected else 0, dropped_logs
}

server_release :: proc(incoming: [dynamic]Incoming) {
	for m in incoming {
		delete(m.payload, runtime.heap_allocator())
	}
	delete(incoming)
}

@(private = "file")
accept_loop :: proc(s: ^Server) {
	for {
		client, _, err := net.accept_tcp(s.listener)
		if sync.atomic_load(&s.closing) {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			log.warnf("cook: cook link: accept: %v", err)
			time.sleep(100 * time.Millisecond)
			continue
		}
		sync.lock(&s.mutex)
		busy := s.connected
		if !busy {
			s.client = client
			s.connected = true
			s.connection += 1
			// Whatever was queued for an earlier editor is not for this one.
			clear(&s.outbox)
		}
		c := Connection{s, s.connection, client}
		sync.unlock(&s.mutex)
		if busy {
			net.close(client)
			log.warn("cook: cook link: another editor is linked, so a new connection was refused")
			continue
		}
		thread.create_and_start_with_poly_data(c, read_loop, context, self_cleanup = true)
		thread.create_and_start_with_poly_data(c, write_loop, context, self_cleanup = true)
	}
}

@(private = "file")
read_loop :: proc(c: Connection) {
	defer disconnect(c)
	header_bytes: [cook_link.HEADER_SIZE]byte
	for {
		if !recv_all(c.client, header_bytes[:]) {
			return
		}
		header, ok := cook_link.read_header(header_bytes[:])
		if !ok {
			log.warn("cook: cook link: the editor sent a message that is too long, so the link is closed")
			return
		}
		payload := make([]byte, header.length, runtime.heap_allocator())
		if !recv_all(c.client, payload) {
			delete(payload, runtime.heap_allocator())
			return
		}
		sync.lock(&c.s.mutex)
		append(&c.s.inbox, Incoming{c.connection, header, payload})
		sync.unlock(&c.s.mutex)
		c.s.wake(c.s.wake_data)
	}
}

@(private = "file")
write_loop :: proc(c: Connection) {
	s := c.s
	sending := make([dynamic]byte, runtime.heap_allocator())
	defer delete(sending)
	for {
		sync.lock(&s.mutex)
		for len(s.outbox) == 0 && s.connected && s.connection == c.connection {
			sync.cond_wait(&s.outbox_ready, &s.mutex)
		}
		if !s.connected || s.connection != c.connection {
			sync.unlock(&s.mutex)
			return
		}
		// The writer sends one buffer while the others fill the other.
		sending, s.outbox = s.outbox, sending
		sync.unlock(&s.mutex)
		if !send_all(c.client, sending[:]) {
			disconnect(c)
			return
		}
		clear(&sending)
	}
}

// disconnect closes a connection once, whichever of its threads notices first, and wakes the main thread.
@(private = "file")
disconnect :: proc(c: Connection) {
	s := c.s
	sync.lock(&s.mutex)
	closed := s.connected && s.connection == c.connection
	if closed {
		s.connected = false
		sync.atomic_store(&s.logging_to_editor, false)
		net.close(s.client)
		sync.cond_broadcast(&s.outbox_ready)
	}
	sync.unlock(&s.mutex)
	if closed {
		s.wake(s.wake_data)
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
