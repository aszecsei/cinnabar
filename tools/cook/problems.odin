package cook

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"

// Problem is an error or a warning of a cook, in a file: an asset's source or .meta file, or another file such as the
// definition file. The daemon gives each asset the problems in its files (see docs/content-pipeline.md#cook-daemon).
Problem :: struct {
	// Absolute, with forward slashes. Empty for a problem that is in no file.
	file:   string,
	// From 1, or 0 when the problem is in the whole file.
	line:   int,
	column: int,
	error:  bool,
	text:   string,
}

// Problems collects a cook's problems in the temporary allocator.
Problems :: struct {
	list: [dynamic]Problem,
	// Logs each problem as it is reported, as the batch commands do. The daemon logs only the problems that change.
	log:  bool,
}

report_error :: proc(p: ^Problems, file: string, line, column: int, format: string, args: ..any, location := #caller_location) {
	report(p, {file, line, column, true, fmt.tprintf(format, ..args)}, location)
}

report_warning :: proc(p: ^Problems, file: string, line, column: int, format: string, args: ..any, location := #caller_location) {
	report(p, {file, line, column, false, fmt.tprintf(format, ..args)}, location)
}

@(private = "file")
report :: proc(p: ^Problems, problem: Problem, location: runtime.Source_Code_Location) {
	if p.list == nil {
		p.list = make([dynamic]Problem, context.temp_allocator)
	}
	append(&p.list, problem)
	if p.log {
		log_problem(problem, location)
	}
}

// log_problem logs a problem as `cook: <file>:<line>:<column>: <text>`, which editors can follow to the line.
log_problem :: proc(problem: Problem, location := #caller_location) {
	log.log(problem.error ? .Error : .Warning, "cook:", problem_text(problem), location = location)
}

// problem_text is a problem with its place, as the log writes it.
problem_text :: proc(problem: Problem) -> string {
	b := strings.builder_make(context.temp_allocator)
	if problem.file != "" {
		strings.write_string(&b, problem.file)
		if problem.line > 0 {
			fmt.sbprintf(&b, ":%d", problem.line)
			if problem.column > 0 {
				fmt.sbprintf(&b, ":%d", problem.column)
			}
		}
		strings.write_string(&b, ": ")
	}
	strings.write_string(&b, problem.text)
	return strings.to_string(b)
}
