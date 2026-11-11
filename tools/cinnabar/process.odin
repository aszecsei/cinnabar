package cinnabar

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// run runs a command with this tool's console, so its output reaches whoever reads the tool's: a terminal, or the
// editor's console. It returns whether the command ran and exited with 0.
run :: proc(command: ..string) -> bool {
	log.infof("cinnabar: %s", command_line(command))
	process, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		log.errorf("cinnabar: cannot run %s: %v", command[0], err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		log.errorf("cinnabar: %s: %v", command[0], wait_err)
		return false
	}
	if state.exit_code != 0 {
		log.errorf("cinnabar: %s exited with %d", command[0], state.exit_code)
		return false
	}
	return true
}

// command_line is a command as a shell would take it, for the log.
command_line :: proc(command: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for arg, i in command {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if strings.contains_any(arg, " \t\"") || arg == "" {
			fmt.sbprintf(&b, "%q", arg)
		} else {
			strings.write_string(&b, arg)
		}
	}
	return strings.to_string(b)
}
