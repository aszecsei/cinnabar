package cook

import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
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

// A decision's preview is its problems at the lines of the text that the editor sends, whatever the file holds.
@(test)
a_preview_of_a_decision_or_a_blackboard_gives_the_problems_of_its_text :: proc(t: ^testing.T) {
	GUARD :: "0123456789abcdef0123456789abcdef"
	DECISION :: "00112233445566778899aabbccddeeff"
	head :: "decision 1\ntechnique = behavior_tree\nblackboard = $" + GUARD + "\nnode 1 wait\n"
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", "blackboard 1\nfloat health\n"},
			{"content/ai/guard.blackboard.meta", "guid = " + GUARD + "\n"},
			{"content/ai/guard.decision", head + "\tseconds = 1\n"},
			{"content/ai/guard.decision.meta", "guid = " + DECISION + "\n"},
		},
	)
	defer remove_tree(tree)
	d: Daemon
	d.options = tree_options(tree)
	pass := cook(d.options, {.Blackboard, .Decision}, log_problems = false)
	index_build(&d.index, pass, d.options.roots[:])
	defer index_destroy(&d.index)

	result := preview(&d, {guid = DECISION, text = head + "\tseconds = rest\n"})
	testing.expectf(t, len(result.problems) == 1 && result.problems[0].line == 5 && result.problems[0].error, "%v", result.problems)
	testing.expect(t, result.error != "")
	result = preview(&d, {guid = DECISION, text = head + "\tseconds = health\n"})
	testing.expectf(t, len(result.problems) == 0 && result.error == "", "%v", result)

	result = preview(&d, {guid = GUARD, text = "blackboard 1\nfloat health\nfloat health\n"})
	testing.expectf(t, len(result.problems) == 1 && result.problems[0].line == 3, "%v", result.problems)
	testing.expect(t, result.error != "")
	result = preview(&d, {guid = GUARD, text = "blackboard 1\nfloat health\n"})
	testing.expectf(t, len(result.problems) == 0 && result.error == "", "%v", result)
}


// A GOAP decision's preview plans the editor's plan query with the runtime's search: from the query's world state, the
// blackboard's defaults for the keys that it leaves out, and every action usable. A failed search gives its closest
// plan, with the keys that it lacks, and a goal or a key that the decision does not have is a problem.
@(test)
a_preview_of_a_goap_decision_plans_its_query :: proc(t: ^testing.T) {
	GUARD :: "0123456789abcdef0123456789abcdef"
	DECISION :: "00112233445566778899aabbccddeeff"
	board, _ := strings.replace_all(#load("testdata/decisions/guard.blackboard", string), "\r\n", "\n", context.temp_allocator)
	text, _ := strings.replace_all(#load("testdata/decisions/goap.decision", string), "\r\n", "\n", context.temp_allocator)
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", board},
			{"content/ai/guard.blackboard.meta", "guid = " + GUARD + "\n"},
			{"content/ai/hunter.decision", text},
			{"content/ai/hunter.decision.meta", "guid = " + DECISION + "\n"},
		},
	)
	defer remove_tree(tree)
	d: Daemon
	d.options = tree_options(tree)
	pass := cook(d.options, {.Blackboard, .Decision}, log_problems = false)
	index_build(&d.index, pass, d.options.roots[:])
	defer index_destroy(&d.index)

	ids :: proc(answer: cook_link.Plan_Answer) -> []u32 {
		result := make([]u32, len(answer.steps), context.temp_allocator)
		for s, i in answer.steps {
			result[i] = s.id
		}
		return result
	}
	result := preview(&d, {guid = DECISION, text = text, plan = {{goal = 1}}})
	if testing.expectf(t, result.error == "" && len(result.plan) == 1, "%v", result) {
		answer := result.plan[0]
		testing.expect_value(t, answer.outcome, cook_link.Plan_Outcome.Found)
		testing.expectf(t, slice.equal(ids(answer), []u32{10, 12, 11}), "%v", answer.steps)
		testing.expect_value(t, answer.steps[0].action, "pick_up")
		testing.expect_value(t, len(answer.unmet), 0)
	}
	// Already armed and near, it only attacks.
	result = preview(&d, {guid = DECISION, text = text, plan = {{goal = 1, state = {{"armed", 1}, {"near", 1}}}}})
	if testing.expectf(t, len(result.plan) == 1, "%v", result) {
		testing.expectf(t, slice.equal(ids(result.plan[0]), []u32{11}), "%v", result.plan[0].steps)
	}
	// Without the rifle, the closest plan comes near and attacks, and lacks only armed.
	PICK_UP :: "node 10 action\n\taction = pick_up(item = \"rifle\")\n\teffects = armed = true, ammo += 6\n\tcost = 2\n"
	unarmed, removed := strings.replace(text, PICK_UP, "", 1, context.temp_allocator)
	testing.expect(t, removed)
	result = preview(&d, {guid = DECISION, text = unarmed, plan = {{goal = 1}}})
	if testing.expectf(t, result.error == "" && len(result.plan) == 1, "%v", result) {
		answer := result.plan[0]
		testing.expect_value(t, answer.outcome, cook_link.Plan_Outcome.Closest)
		testing.expectf(t, slice.equal(ids(answer), []u32{12, 11}), "%v", answer.steps)
		testing.expectf(t, slice.equal(answer.unmet, []string{"armed"}), "%v", answer.unmet)
	}
	result = preview(&d, {guid = DECISION, text = text, plan = {{goal = 99}}})
	testing.expectf(t, len(result.plan) == 0 && len(result.problems) == 1 && result.error != "", "%v", result)
	result = preview(&d, {guid = DECISION, text = text, plan = {{goal = 1, state = {{"health", 1}}}}})
	testing.expectf(t, len(result.plan) == 0 && len(result.problems) == 1, "%v", result)
	// A decision with problems has no plan.
	result = preview(&d, {guid = DECISION, text = strings.concatenate({text, "node 30 bogus\n"}, context.temp_allocator), plan = {{goal = 1}}})
	testing.expectf(t, len(result.plan) == 0 && result.error != "", "%v", result)
}
