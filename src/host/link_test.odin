package host

import "core:log"
import "core:net"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/wire/serve"
import "cinnabar:engine/wire/servetest"

// The host handles messages under its link's logger, as main does. Only around the calls, so the test's own failures
// still reach the runner.
@(private = "file")
handle_logged :: proc(l: ^Link, taken: serve.Taken) {
	context.logger = link_logger(l)
	handle_taken(l, taken, core.Game_API{}, nil)
}

@(private = "file")
log_logged :: proc(l: ^Link, text: string) {
	context.logger = link_logger(l)
	log.info(text)
}

// An editor leaves while the host handles its Hello (#326). The host does not link it, and its log stays on the
// console. The next editor gets its Welcome before any log line.
@(test)
a_hello_after_its_editor_left_links_nothing :: proc(t: ^testing.T) {
	l: Link
	console: servetest.Console
	defer servetest.console_destroy(&console)
	waker: servetest.Waker
	{
		context.logger = servetest.console_logger(&console)
		if !testing.expect(t, link_start(&l, 0, "test")) {
			return
		}
	}
	defer link_stop(&l)
	// The host polls every frame, so it has no wake. The test waits for one instead of polling. The reader threads
	// start after this, when an editor connects.
	l.server.wake = servetest.wake
	l.server.wake_data = &waker
	port := serve.bound_port(&l.server)
	hello :: proc(editor: string) -> link.Message {
		return link.Hello{protocol = link.protocol_version(), editor = editor}
	}

	first, first_ok := servetest.dial(port)
	if !testing.expect(t, first_ok) {
		return
	}
	servetest.send(first, hello("first editor"))
	testing.expect(t, servetest.wait(&waker), "the first Hello did not arrive")
	taken := serve.take(&l.server)
	defer serve.release(taken)
	testing.expect_value(t, len(taken.incoming), 1)
	net.close(first)
	testing.expect(t, servetest.wait(&waker), "the host did not notice that the first editor left")
	handle_logged(&l, taken)
	testing.expect(t, !link_linked(&l))
	log_logged(&l, "after the first editor left")
	testing.expect(t, servetest.heard(&console, "after the first editor left"), "a log line after the editor left did not reach the console")
	testing.expect(t, !servetest.heard(&console, "linked to first editor"))

	second, second_ok := servetest.dial(port)
	if !testing.expect(t, second_ok) {
		return
	}
	defer net.close(second)
	log_logged(&l, "before the second Hello")
	servetest.send(second, hello("second editor"))
	testing.expect(t, servetest.wait(&waker), "the second Hello did not arrive")
	second_taken := serve.take(&l.server)
	defer serve.release(second_taken)
	handle_logged(&l, second_taken)
	testing.expect(t, link_linked(&l))
	testing.expect(t, servetest.heard(&console, "before the second Hello"))

	welcome, welcome_ok := servetest.receive(second, link.Message)
	testing.expect(t, welcome_ok)
	_, is_welcome := welcome.(link.Welcome)
	testing.expectf(t, is_welcome, "the editor got %v before its Welcome", welcome)
	found := false
	for _ in 0 ..< 100 {
		m, ok := servetest.receive(second, link.Message)
		if !ok {
			break
		}
		if line, is_log := m.(link.Log); is_log {
			testing.expect_value(t, line.text, "host: linked to second editor")
			found = true
			break
		}
	}
	testing.expect(t, found, "the linked editor got no log line")
}
