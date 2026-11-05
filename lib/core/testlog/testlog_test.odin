package testlog

import "base:runtime"
import "core:log"
import "core:sync"
import "core:testing"

// expected_errors keeps one runner, so these tests take turns.
@(private = "file")
lock: sync.Mutex

@(private = "file")
Heard :: struct {
	errors: int,
}

@(private = "file")
listener :: proc(heard: ^Heard) -> runtime.Logger {
	return {
		procedure = proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
			if level >= .Error {
				(^Heard)(data).errors += 1
			}
		},
		data = heard,
		lowest_level = .Debug,
	}
}

// What the test's own file reports reaches the runner, and that is how a test fails.
@(test)
an_expect_still_fails_a_test :: proc(t: ^testing.T) {
	sync.guard(&lock)
	heard: Heard
	outer := context.logger
	{
		context.logger = listener(&heard)
		context.logger = expected_errors()
		testing.expect(t, false)
		testing.expect_value(t, 1, 2)
		log.error("the test's own")
	}
	context.logger = outer
	testing.expect_value(t, heard.errors, 3)
}

@(test)
what_the_code_logs_goes_nowhere :: proc(t: ^testing.T) {
	sync.guard(&lock)
	heard: Heard
	outer := context.logger
	{
		context.logger = listener(&heard)
		context.logger = expected_errors()
		log.error("the code's", location = {file_path = "lib/engine/render/residency.odin"})
		log.errorf("the code's %d", 2, location = {file_path = "lib/engine/asset/asset.odin"})
	}
	context.logger = outer
	testing.expect_value(t, heard.errors, 0)
}

@(test)
asking_twice_keeps_the_runner :: proc(t: ^testing.T) {
	sync.guard(&lock)
	heard: Heard
	outer := context.logger
	{
		context.logger = listener(&heard)
		context.logger = expected_errors()
		context.logger = expected_errors()
		testing.expect(t, false)
	}
	context.logger = outer
	testing.expect_value(t, heard.errors, 1)
}
