package cook

import "core:log"
import "core:net"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"
import "cinnabar:engine/wire/serve"
import "cinnabar:engine/wire/servetest"

// The daemon handles messages under its server's logger, as run_daemon does. Only around the calls, so the test's own
// failures still reach the runner.
@(private = "file")
handle_logged :: proc(d: ^Daemon, taken: Maybe(serve.Taken) = nil) {
	context.logger = serve.logger(&d.server)
	if t, ok := taken.?; ok {
		handle_taken(d, t)
	} else {
		handle_messages(d)
	}
}

@(private = "file")
log_logged :: proc(d: ^Daemon, text: string) {
	context.logger = serve.logger(&d.server)
	log.info(text)
}

// An editor leaves while the daemon handles its Hello (#326). The daemon does not link it, and its log stays on the
// console. The next editor gets its Welcome before any log line.
@(test)
a_hello_after_its_editor_left_links_nothing :: proc(t: ^testing.T) {
	d: Daemon
	d.options.roots = make([dynamic]Root, context.temp_allocator)
	append(&d.options.roots, Root{"game", "C:/game"})
	console: servetest.Console
	defer servetest.console_destroy(&console)
	waker: servetest.Waker
	{
		context.logger = servetest.console_logger(&console)
		if !testing.expect(t, serve.start(&d.server, "cook: cook link", 0, write_log, servetest.wake, &waker)) {
			return
		}
	}
	defer serve.stop(&d.server)
	port := serve.bound_port(&d.server)
	hello :: proc(editor: string) -> cook_link.Message {
		return cook_link.Hello{protocol = cook_link.protocol_version(), editor = editor}
	}

	first, first_ok := servetest.dial(port)
	if !testing.expect(t, first_ok) {
		return
	}
	servetest.send(first, hello("first editor"))
	testing.expect(t, servetest.wait(&waker), "the first Hello did not arrive")
	taken := serve.take(&d.server)
	defer serve.release(taken)
	testing.expect_value(t, len(taken.incoming), 1)
	net.close(first)
	testing.expect(t, servetest.wait(&waker), "the daemon did not notice that the first editor left")
	handle_logged(&d, taken)
	testing.expect_value(t, serve.linked(&d.server), 0)
	log_logged(&d, "after the first editor left")
	testing.expect(t, servetest.heard(&console, "after the first editor left"), "a log line after the editor left did not reach the console")
	testing.expect(t, !servetest.heard(&console, "linked to first editor"))

	second, second_ok := servetest.dial(port)
	if !testing.expect(t, second_ok) {
		return
	}
	defer net.close(second)
	log_logged(&d, "before the second Hello")
	servetest.send(second, hello("second editor"))
	testing.expect(t, servetest.wait(&waker), "the second Hello did not arrive")
	handle_logged(&d)
	testing.expect(t, serve.linked(&d.server) != 0)
	testing.expect(t, servetest.heard(&console, "before the second Hello"))

	welcome, welcome_ok := servetest.receive(second, cook_link.Message)
	testing.expect(t, welcome_ok)
	_, is_welcome := welcome.(cook_link.Welcome)
	testing.expectf(t, is_welcome, "the editor got %v before its Welcome", welcome)
	found := false
	for _ in 0 ..< 100 {
		m, ok := servetest.receive(second, cook_link.Message)
		if !ok {
			break
		}
		if line, is_log := m.(cook_link.Log); is_log {
			testing.expect_value(t, line.text, "cook: linked to second editor")
			found = true
			break
		}
	}
	testing.expect(t, found, "the linked editor got no log line")
}
