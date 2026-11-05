// Package testlog is for tests whose code logs errors on purpose. The test runner fails a test that logs an error, and
// testing.expect reports through the same logger, so a test under log.nil_logger() cannot fail at all.
package testlog

import "base:intrinsics"
import "base:runtime"
import "core:strings"

// The test runner's logger procedure, which is one procedure for every test, with each test's own data.
@(private)
runner: runtime.Logger_Proc

// expected_errors is a logger that hears only the test: what a _test.odin file logs reaches the runner, as testing.expect
// does, so the test can still fail, and what the code under test logs goes nowhere. Set it as the test's context.logger.
expected_errors :: proc() -> runtime.Logger {
	logger := context.logger
	if logger.procedure != filter {
		intrinsics.atomic_store(&runner, logger.procedure)
		logger.procedure = filter
	}
	return logger
}

@(private)
filter :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	if strings.has_suffix(location.file_path, "_test.odin") {
		intrinsics.atomic_load(&runner)(data, level, text, options, location)
	}
}
