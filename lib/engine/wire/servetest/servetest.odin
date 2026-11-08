// Package servetest is for tests of a serve.Server: an editor's end of the link over loopback, a wake that a test waits
// for, and a console that keeps what it hears. Only _test.odin files import it.
package servetest

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "cinnabar:engine/wire"

// A test fails rather than waits longer than this for the server.
TIMEOUT :: 5 * time.Second

// Waker counts the server's wakes, which come when a message arrives or the editor leaves.
Waker :: struct {
	sema: sync.Sema,
}

wake :: proc(data: rawptr) {
	sync.sema_post(&(^Waker)(data).sema)
}

// wait waits for one wake, and is false if none comes in time.
wait :: proc(w: ^Waker) -> bool {
	return sync.sema_wait_with_timeout(&w.sema, TIMEOUT)
}

// Console is a console logger that keeps every line. Any thread can log to it.
Console :: struct {
	mutex: sync.Mutex,
	lines: [dynamic]string,
}

console_logger :: proc(c: ^Console) -> log.Logger {
	return {procedure = console_proc, data = c, lowest_level = .Debug}
}

@(private = "file")
console_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	c := (^Console)(data)
	sync.guard(&c.mutex)
	append(&c.lines, strings.clone(text, runtime.heap_allocator()))
}

// heard is true when the console has a line that contains text.
heard :: proc(c: ^Console, text: string) -> bool {
	sync.guard(&c.mutex)
	for line in c.lines {
		if strings.contains(line, text) {
			return true
		}
	}
	return false
}

console_destroy :: proc(c: ^Console) {
	for line in c.lines {
		delete(line, runtime.heap_allocator())
	}
	delete(c.lines)
}

// dial connects to a server on loopback, as an editor does. A receive waits at most TIMEOUT.
dial :: proc(port: int) -> (socket: net.TCP_Socket, ok: bool) {
	err: net.Network_Error
	socket, err = net.dial_tcp_from_address_and_port(net.IP4_Loopback, port)
	if err != nil {
		return
	}
	net.set_option(socket, .Receive_Timeout, TIMEOUT)
	return socket, true
}

// send sends one message of a link's union.
send :: proc(socket: net.TCP_Socket, message: $M, request: u32 = 0) -> bool where intrinsics.type_is_union(M) {
	buf: [dynamic]byte
	defer delete(buf)
	wire.write_message(&buf, message, request)
	for done := 0; done < len(buf); {
		n, err := net.send_tcp(socket, buf[done:])
		if err != nil || n <= 0 {
			return false
		}
		done += n
	}
	return true
}

// receive receives one message of a link's union, in the temporary allocator.
receive :: proc(socket: net.TCP_Socket, $M: typeid) -> (message: M, ok: bool) where intrinsics.type_is_union(M) {
	header, payload := receive_raw(socket) or_return
	return wire.decode_message(M, header.kind, payload, context.temp_allocator)
}

// receive_raw receives one message's header and payload, in the temporary allocator.
receive_raw :: proc(socket: net.TCP_Socket) -> (header: wire.Header, payload: []byte, ok: bool) {
	header_bytes: [wire.HEADER_SIZE]byte
	recv_all(socket, header_bytes[:]) or_return
	header = wire.read_header(header_bytes[:]) or_return
	payload = make([]byte, header.length, context.temp_allocator)
	recv_all(socket, payload) or_return
	return header, payload, true
}

@(private = "file")
recv_all :: proc(socket: net.TCP_Socket, buf: []byte) -> bool {
	for done := 0; done < len(buf); {
		n, err := net.recv_tcp(socket, buf[done:])
		if err != nil || n == 0 {
			return false
		}
		done += n
	}
	return true
}
