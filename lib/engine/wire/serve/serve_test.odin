package serve

import "core:log"
import "core:net"
import "core:testing"

import "cinnabar:engine/wire"
import "cinnabar:engine/wire/servetest"

@(private = "file")
Hello :: struct {
	editor: string,
}

@(private = "file")
Welcome :: struct {
	server: string,
}

@(private = "file")
Line :: struct {
	text: string,
}

@(private = "file")
Test_Message :: union {
	Hello,
	Welcome,
	Line,
}

@(private = "file")
test_write_log :: proc(out: ^[dynamic]byte, level: log.Level, time: i64, location: string, text: string) {
	wire.write_message(out, Test_Message(Line{text}))
}

// A server on a free port, whose console and wakes the test sees. The caller stops it.
@(private = "file")
test_start :: proc(t: ^testing.T, s: ^Server, console: ^servetest.Console, waker: ^servetest.Waker) -> bool {
	context.logger = servetest.console_logger(console)
	return testing.expect(t, start(s, "test link", 0, test_write_log, servetest.wake, waker))
}

// log_through logs a line through the server's logger. Only around the line, so the test's own failures still reach
// the runner.
@(private = "file")
log_through :: proc(s: ^Server, text: string) {
	context.logger = logger(s)
	log.info(text)
}

// An editor connects and says Hello, and the test takes the Hello as the main thread would.
@(private = "file")
test_hello :: proc(t: ^testing.T, s: ^Server, waker: ^servetest.Waker) -> (client: net.TCP_Socket, taken: Taken, ok: bool) {
	client = servetest.dial(bound_port(s)) or_return
	servetest.send(client, Test_Message(Hello{"test editor"}))
	if !testing.expect(t, servetest.wait(waker), "the Hello did not arrive") {
		net.close(client)
		return
	}
	taken = take(s)
	testing.expect_value(t, len(taken.incoming), 1)
	testing.expect(t, taken.connection != 0)
	return client, taken, true
}

// The editor leaves while the main thread handles its Hello: the link fails, and the log stays on the console.
@(test)
a_connection_that_closed_does_not_link :: proc(t: ^testing.T) {
	s: Server
	console: servetest.Console
	defer servetest.console_destroy(&console)
	waker: servetest.Waker
	if !test_start(t, &s, &console, &waker) {
		return
	}
	defer stop(&s)
	client, taken, ok := test_hello(t, &s, &waker)
	defer release(taken)
	if !ok {
		return
	}
	net.close(client)
	testing.expect(t, servetest.wait(&waker), "the server did not notice that the editor left")

	send(&s, taken.connection, Test_Message(Welcome{"test"}))
	testing.expect(t, !link(&s, taken.connection))
	testing.expect_value(t, linked(&s), 0)
	log_through(&s, "after the editor left")
	testing.expect(t, servetest.heard(&console, "after the editor left"))
	after := take(&s)
	defer release(after)
	testing.expect(t, !after.unlinked, "an editor that never linked was reported as unlinked")
	testing.expect_value(t, after.dropped_logs, 0)
}

// The log goes to an editor only once it is linked, after its Welcome, and its leaving is reported once.
@(test)
the_log_goes_to_an_editor_once_it_is_linked :: proc(t: ^testing.T) {
	s: Server
	console: servetest.Console
	defer servetest.console_destroy(&console)
	waker: servetest.Waker
	if !test_start(t, &s, &console, &waker) {
		return
	}
	defer stop(&s)
	client, taken, ok := test_hello(t, &s, &waker)
	defer release(taken)
	if !ok {
		return
	}
	log_through(&s, "before the link")
	send(&s, taken.connection, Test_Message(Welcome{"test"}))
	testing.expect(t, link(&s, taken.connection))
	testing.expect_value(t, linked(&s), taken.connection)
	log_through(&s, "after the link")
	send_linked(&s, Test_Message(Welcome{"event"}))

	first, first_ok := servetest.receive(client, Test_Message)
	testing.expect(t, first_ok)
	testing.expect_value(t, first.(Welcome).server, "test")
	second, second_ok := servetest.receive(client, Test_Message)
	testing.expect(t, second_ok)
	testing.expect_value(t, second.(Line).text, "after the link")
	third, third_ok := servetest.receive(client, Test_Message)
	testing.expect(t, third_ok)
	testing.expect_value(t, third.(Welcome).server, "event")
	testing.expect(t, servetest.heard(&console, "before the link"))
	testing.expect(t, !servetest.heard(&console, "after the link"))

	net.close(client)
	testing.expect(t, servetest.wait(&waker), "the server did not notice that the editor left")
	testing.expect_value(t, linked(&s), 0)
	after := take(&s)
	testing.expect(t, after.unlinked)
	release(after)
	again := take(&s)
	testing.expect(t, !again.unlinked, "the editor's leaving was reported twice")
	release(again)
}

// stop closes an editor that is still connected, and joins the threads of its connection and the one before.
@(test)
stop_joins_every_thread :: proc(t: ^testing.T) {
	s: Server
	console: servetest.Console
	defer servetest.console_destroy(&console)
	waker: servetest.Waker
	if !test_start(t, &s, &console, &waker) {
		return
	}
	first, taken, ok := test_hello(t, &s, &waker)
	release(taken)
	if !ok {
		stop(&s)
		return
	}
	net.close(first)
	testing.expect(t, servetest.wait(&waker))
	second, second_taken, second_ok := test_hello(t, &s, &waker)
	release(second_taken)
	stop(&s)
	testing.expect(t, s.acceptor == nil && s.reader == nil && s.writer == nil)
	if second_ok {
		_, still_open := servetest.receive(second, Test_Message)
		testing.expect(t, !still_open, "stop left the editor's connection open")
		net.close(second)
	}
}
