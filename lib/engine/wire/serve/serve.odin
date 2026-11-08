// Package serve is the server side of the editor link and the cook link: the host and the cook daemon each serve one
// editor at a time over loopback (see docs/editor/link.md#editor-link). A reader thread queues the editor's messages,
// and the main thread takes them. Everything that the server sends, the log included, goes into the outbox, and a
// writer thread sends it. It is not part of package wire because the game imports wire, and needs no sockets or threads.
package serve

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"

import "cinnabar:engine/wire"

// While the editor is slow to read, log lines beyond this much unsent data are dropped and counted.
MAX_OUTBOX :: 16 * mem.Megabyte

// Server owns the one connection and whether it is linked, under its mutex. The main thread asks it with linked, and
// links a connection with link once it has answered that connection's Hello.
Server :: struct {
	// The prefix of the server's own log lines, such as "host: editor link".
	name:         string,
	listener:     net.TCP_Socket,
	acceptor:     ^thread.Thread,
	// Called from a reader thread when a message arrives or the editor leaves, to wake the main thread. It can be nil.
	wake:         proc(data: rawptr),
	wake_data:    rawptr,
	// Appends a log line to the outbox as the link's Log message.
	write_log:    Write_Log,
	console:      log.Logger,
	// The threads of the latest connection. Only accept_loop changes them, and stop joins them after the acceptor.
	reader:       ^thread.Thread,
	writer:       ^thread.Thread,
	// Guards everything below.
	mutex:        sync.Mutex,
	closing:      bool,
	peer:         Maybe(Peer),
	// Counts connections, so a thread or a message of an old connection is recognised. Connection 0 is none.
	connections:  u64,
	// A linked peer left since the last take. Only the main thread links, after a take, so at most one link ends
	// between two takes.
	unlinked:     bool,
	inbox:        [dynamic]Incoming,
	outbox:       [dynamic]byte,
	outbox_ready: sync.Cond,
	dropped_logs: int,
}

Write_Log :: proc(out: ^[dynamic]byte, level: log.Level, time: i64, location: string, text: string)

// Peer is the editor that is connected now.
Peer :: struct {
	connection: u64,
	client:     net.TCP_Socket,
	stage:      Peer_Stage,
}

Peer_Stage :: enum u8 {
	// Connected, and its Hello has not been answered. Nothing but the answers to its messages goes to it.
	Connected,
	// Its Hello was answered with a Welcome. The log and the server's events go to it.
	Linked,
}

Incoming :: struct {
	connection: u64,
	header:     wire.Header,
	// From the heap. release frees it.
	payload:    []byte,
}

// Taken is what take hands the main thread.
Taken :: struct {
	// The messages of the connection that is open now.
	incoming:     [dynamic]Incoming,
	// The connection that is open now, or 0.
	connection:   u64,
	// A linked editor left since the last take.
	unlinked:     bool,
	// The log lines dropped since the last take, while the editor was slow to read.
	dropped_logs: int,
}

@(private = "file")
Connection :: struct {
	s:          ^Server,
	connection: u64,
	client:     net.TCP_Socket,
}

// start listens on 127.0.0.1:port, where port 0 picks a free port. Only the local machine can connect.
start :: proc(s: ^Server, name: string, port: int, write_log: Write_Log, wake: proc(data: rawptr) = nil, wake_data: rawptr = nil) -> bool {
	listener, err := net.listen_tcp({net.IP4_Loopback, port})
	if err != nil {
		log.errorf("%s: cannot listen on port %d: %v", name, port, err)
		return false
	}
	s.name = name
	s.listener = listener
	s.write_log = write_log
	s.wake = wake
	s.wake_data = wake_data
	s.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	s.outbox = make([dynamic]byte, runtime.heap_allocator())
	s.console = context.logger
	s.acceptor = thread.create_and_start_with_poly_data(s, accept_loop, context)
	log.infof("%s: listening on 127.0.0.1:%d", name, bound_port(s))
	return true
}

// bound_port is the port that the server listens on.
bound_port :: proc(s: ^Server) -> int {
	endpoint, err := net.bound_endpoint(s.listener)
	if err != nil {
		return 0
	}
	return endpoint.port
}

// stop closes the listener and the connection, and joins every thread that the server started.
stop :: proc(s: ^Server) {
	if s.acceptor == nil {
		return
	}
	sync.lock(&s.mutex)
	s.closing = true
	if p, ok := s.peer.?; ok {
		net.close(p.client)
		s.peer = nil
		sync.cond_broadcast(&s.outbox_ready)
	}
	sync.unlock(&s.mutex)
	net.close(s.listener)
	thread.join(s.acceptor)
	thread.destroy(s.acceptor)
	s.acceptor = nil
	join_connection_threads(s)
	release({incoming = s.inbox})
	delete(s.outbox)
	s.inbox = nil
	s.outbox = nil
}

// logger logs to the editor while one is linked, and to the console otherwise.
logger :: proc(s: ^Server) -> log.Logger {
	return {procedure = logger_proc, data = s, lowest_level = s.console.lowest_level, options = s.console.options}
}

@(private = "file")
logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	s := (^Server)(data)
	sync.lock(&s.mutex)
	if p, ok := s.peer.?; !ok || p.stage != .Linked {
		sync.unlock(&s.mutex)
		s.console.procedure(s.console.data, level, text, options, location)
		return
	}
	defer sync.unlock(&s.mutex)
	if len(s.outbox) >= MAX_OUTBOX {
		s.dropped_logs += 1
		return
	}
	// Any thread logs, inside jobs too, so this allocates nothing but outbox growth.
	location_buf: [256]byte
	where_ := fmt.bprintf(location_buf[:], "%s:%d:%s()", filepath.base(location.file_path), location.line, location.procedure)
	s.write_log(&s.outbox, level, time.to_unix_nanoseconds(time.now()), where_, text)
	sync.cond_signal(&s.outbox_ready)
}

// link links a connection whose Hello the main thread answered, so the log and send_linked go to it. It fails when
// that connection is no longer the one that is open.
link :: proc(s: ^Server, connection: u64) -> bool {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	p, ok := &s.peer.?
	if !ok || p.connection != connection {
		return false
	}
	p.stage = .Linked
	return true
}

// linked is the linked connection, or 0.
linked :: proc(s: ^Server) -> u64 {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if p, ok := s.peer.?; ok && p.stage == .Linked {
		return p.connection
	}
	return 0
}

// send queues a message of a link's union for a connection, if it is still the one that is open.
send :: proc(s: ^Server, connection: u64, message: $M, request: u32 = 0) where intrinsics.type_is_union(M) {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if p, ok := s.peer.?; ok && p.connection == connection {
		wire.write_message(&s.outbox, message, request)
		sync.cond_signal(&s.outbox_ready)
	}
}

// send_linked queues a message of a link's union for the linked editor, if there is one.
send_linked :: proc(s: ^Server, message: $M, request: u32 = 0) where intrinsics.type_is_union(M) {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if p, ok := s.peer.?; ok && p.stage == .Linked {
		wire.write_message(&s.outbox, message, request)
		sync.cond_signal(&s.outbox_ready)
	}
}

// send_bytes queues messages that are already written for a connection, if it is still the one that is open.
send_bytes :: proc(s: ^Server, connection: u64, bytes: []byte) {
	sync.lock(&s.mutex)
	defer sync.unlock(&s.mutex)
	if p, ok := s.peer.?; ok && p.connection == connection {
		append(&s.outbox, ..bytes)
		sync.cond_signal(&s.outbox_ready)
	}
}

// take gives the main thread the messages of the open connection, and what happened since the last take. The caller
// frees it with release.
take :: proc(s: ^Server) -> (taken: Taken) {
	sync.lock(&s.mutex)
	incoming := s.inbox
	s.inbox = make([dynamic]Incoming, runtime.heap_allocator())
	if p, ok := s.peer.?; ok {
		taken.connection = p.connection
	}
	taken.unlinked = s.unlinked
	s.unlinked = false
	taken.dropped_logs = s.dropped_logs
	s.dropped_logs = 0
	sync.unlock(&s.mutex)

	taken.incoming = make([dynamic]Incoming, 0, len(incoming), runtime.heap_allocator())
	for m in incoming {
		if m.connection == taken.connection && taken.connection != 0 {
			append(&taken.incoming, m)
		} else {
			delete(m.payload, runtime.heap_allocator())
		}
	}
	delete(incoming)
	return taken
}

release :: proc(taken: Taken) {
	for m in taken.incoming {
		delete(m.payload, runtime.heap_allocator())
	}
	delete(taken.incoming)
}

@(private = "file")
accept_loop :: proc(s: ^Server) {
	for {
		client, _, err := net.accept_tcp(s.listener)
		sync.lock(&s.mutex)
		closing := s.closing
		sync.unlock(&s.mutex)
		if closing {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			log.warnf("%s: accept: %v", s.name, err)
			time.sleep(100 * time.Millisecond)
			continue
		}
		sync.lock(&s.mutex)
		_, busy := s.peer.?
		if !busy {
			s.connections += 1
			s.peer = Peer{s.connections, client, .Connected}
			// Whatever was queued for an earlier editor is not for this one.
			clear(&s.outbox)
		}
		c := Connection{s, s.connections, client}
		sync.unlock(&s.mutex)
		if busy {
			net.close(client)
			log.warnf("%s: another editor is linked, so a new connection was refused", s.name)
			continue
		}
		// The earlier connection is closed, so its threads have returned or are returning.
		join_connection_threads(s)
		s.reader = thread.create_and_start_with_poly_data(c, read_loop, context)
		s.writer = thread.create_and_start_with_poly_data(c, write_loop, context)
	}
}

@(private = "file")
join_connection_threads :: proc(s: ^Server) {
	for t in ([]^^thread.Thread{&s.reader, &s.writer}) {
		if t^ != nil {
			thread.join(t^)
			thread.destroy(t^)
			t^ = nil
		}
	}
}

@(private = "file")
read_loop :: proc(c: Connection) {
	defer disconnect(c)
	header_bytes: [wire.HEADER_SIZE]byte
	for {
		if !recv_all(c.client, header_bytes[:]) {
			return
		}
		header, ok := wire.read_header(header_bytes[:])
		if !ok {
			log.warnf("%s: the editor sent a message that is too long, so the link is closed", c.s.name)
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
		if c.s.wake != nil {
			c.s.wake(c.s.wake_data)
		}
	}
}

@(private = "file")
write_loop :: proc(c: Connection) {
	s := c.s
	sending := make([dynamic]byte, runtime.heap_allocator())
	defer delete(sending)
	for {
		sync.lock(&s.mutex)
		for len(s.outbox) == 0 && is_open(s, c.connection) {
			sync.cond_wait(&s.outbox_ready, &s.mutex)
		}
		if !is_open(s, c.connection) {
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

// is_open is true while connection is the open one. The caller holds the mutex.
@(private = "file")
is_open :: proc(s: ^Server, connection: u64) -> bool {
	p, ok := s.peer.?
	return ok && p.connection == connection
}

// disconnect closes a connection once, whichever of its threads notices first, and wakes the main thread.
@(private = "file")
disconnect :: proc(c: Connection) {
	s := c.s
	sync.lock(&s.mutex)
	p, ok := s.peer.?
	closed := ok && p.connection == c.connection
	if closed {
		if p.stage == .Linked {
			s.unlinked = true
		}
		s.peer = nil
		net.close(p.client)
		sync.cond_broadcast(&s.outbox_ready)
	}
	sync.unlock(&s.mutex)
	if closed && s.wake != nil {
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
