// tools/cinnabar builds and runs a project with a built engine checkout, without the justfile: a game made with the
// engine instead of in it (see docs/overview/getting-started.md). The editor runs it for New Project and Export.
package cinnabar

import "core:fmt"
import "core:log"
import "core:os"

USAGE :: `usage: cinnabar new <dir> [--name <name>] [--template basic|odin] [--engine <dir>]
       cinnabar build [<project>] [--engine <dir>]
       cinnabar run [<project>] [--engine <dir>]
       cinnabar edit [<project>] [--engine <dir>]
       cinnabar export [<project>] [--out <dir>] [--engine <dir>]

<project> is a folder with project.settings, and the current folder when it is left out. The engine is --engine, then
CINNABAR_ROOT, then engine.path in the project's project.user.settings, then the checkout that cinnabar.exe was built in.`

Command :: enum u8 {
	None,
	New,
	Build,
	Run,
	Edit,
	Export,
}

Options :: struct {
	command:  Command,
	project:  string,
	engine:   string,
	out:      string,
	name:     string,
	template: string,
}

// parse_args reads the command line after the executable.
parse_args :: proc(args: []string) -> (o: Options, ok: bool) {
	if len(args) == 0 {
		return
	}
	switch args[0] {
	case "new":
		o.command = .New
	case "build":
		o.command = .Build
	case "run":
		o.command = .Run
	case "edit":
		o.command = .Edit
	case "export":
		o.command = .Export
	case:
		return
	}
	o.template = "basic"
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if len(arg) > 2 && arg[:2] == "--" {
			if i + 1 >= len(args) {
				return
			}
			value := args[i + 1]
			i += 1
			switch arg {
			case "--engine":
				o.engine = value
			case "--out":
				o.out = value
			case "--name":
				o.name = value
			case "--template":
				o.template = value
			case:
				return
			}
			continue
		}
		if o.project != "" {
			return
		}
		o.project = arg
	}
	if o.command == .New && o.project == "" {
		return
	}
	if o.project == "" {
		o.project = "."
	}
	return o, true
}

main :: proc() {
	context.logger = log.create_console_logger(.Info, {.Level, .Terminal_Color})
	o, parsed := parse_args(os.args[1:])
	if !parsed {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if !run_command(o) {
		os.exit(1)
	}
}

run_command :: proc(o: Options) -> bool {
	exe_dir, _ := os.get_executable_directory(context.temp_allocator)
	settings, _ := os.join_path({o.project, "project.settings"}, context.temp_allocator)
	user_engine := setting(settings, ENGINE_PATH_KEY) if o.command != .New else ""
	root, source, found := find_engine(o.engine, os.get_env(ENGINE_VARIABLE, context.temp_allocator), user_engine, exe_dir)
	if !found {
		if root == "" {
			log.errorf("cinnabar: cannot find the engine. Name its checkout with --engine or %s.", ENGINE_VARIABLE)
		} else {
			log.errorf("cinnabar: %s, from %s, is not the engine's checkout: it has no %s", root, describe(source), ENGINE_CONTENT)
		}
		return false
	}
	e := engine_paths(root)
	if o.command == .New {
		return new_project(e, o.project, o.name, o.template)
	}
	if !os.exists(settings) {
		log.errorf("cinnabar: %s has no project.settings. Make a project with `cinnabar new <dir>`.", o.project)
		return false
	}
	p := project_paths(o.project, e)
	switch o.command {
	case .None, .New:
	case .Build:
		return build_project(e, p)
	case .Run:
		return run_project(e, p)
	case .Edit:
		return edit_project(e, p)
	case .Export:
		return export_project(e, p, slashes(absolute(o.out)) if o.out != "" else p.release)
	}
	return false
}
