package cook

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/slashpath"

// Type_Checker checks scripts against the definition file that host.exe --emit-script-types writes (see
// docs/scripting.md#types-and-tooling).
Type_Checker :: struct {
	handle: ^Luau_Checker,
}

// definitions_hash is the definition file's hash, which is part of every script's cache key. It is zero when there is
// no file.
definitions_hash :: proc(definitions: string) -> u64 {
	if definitions == "" {
		return 0
	}
	source, err := os.read_entire_file(definitions, context.temp_allocator)
	return hash.fnv64a(source) if err == nil else 0
}

@(private = "file")
Report_Context :: struct {
	ctx:      runtime.Context,
	path:     string,
	problems: ^Problems,
	ok:       bool,
}

// type_checker_open loads the definitions and every script. Without a definition file, type checking is off, and
// the cooker says so: the scripts are checked once the file exists, because its hash is in their keys.
type_checker_open :: proc(checker: ^Type_Checker, definitions: string, scripts: []Script_Source, problems: ^Problems) -> bool {
	checker^ = {}
	if definitions == "" {
		return true
	}
	definitions_path := forward_slashes(os.get_absolute_path(definitions, context.temp_allocator) or_else definitions)
	source, err := os.read_entire_file(definitions, context.temp_allocator)
	if err != nil {
		report_warning(problems, definitions_path, 0, 0, "type checking is off, because the definition file does not exist. Run `just script-types`.")
		return true
	}
	checker.handle = cn_luau_checker_create()
	report := Report_Context{context, definitions_path, problems, true}
	on_error :: proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int) {
		r := (^Report_Context)(ud)
		context = r.ctx
		report_error(r.problems, r.path, int(line), 0, "%s", string(text[:size]))
		r.ok = false
	}
	if !cn_luau_checker_define(checker.handle, raw_data(source), c.size_t(len(source)), &report, on_error) || !report.ok {
		report_error(problems, definitions_path, 0, 0, "this is not a valid definition file. Run `just script-types` again.")
		return false
	}
	for s in scripts {
		mode := language_mode(slashpath.dir(s.path, context.temp_allocator))
		cn_luau_checker_add_module(checker.handle, raw_data(s.name), c.size_t(len(s.name)), raw_data(s.source), c.size_t(len(s.source)), mode)
		for r in s.resolved {
			to := scripts[r.target].name
			cn_luau_checker_add_require(
				checker.handle,
				raw_data(s.name),
				c.size_t(len(s.name)),
				raw_data(r.entry.path),
				c.size_t(len(r.entry.path)),
				raw_data(to),
				c.size_t(len(to)),
			)
		}
	}
	return true
}

type_checker_close :: proc(checker: ^Type_Checker) {
	if checker.handle != nil {
		cn_luau_checker_destroy(checker.handle)
	}
	checker^ = {}
}

// type_check reports the script's type errors, and returns false if it has any.
type_check :: proc(checker: ^Type_Checker, s: Script_Source, problems: ^Problems) -> bool {
	if checker.handle == nil {
		return true
	}
	report := Report_Context{context, s.path, problems, true}
	on_error :: proc "c" (ud: rawptr, module: [^]u8, module_size: c.size_t, line, column: c.int, text: [^]u8, size: c.size_t) {
		r := (^Report_Context)(ud)
		context = r.ctx
		report_error(r.problems, r.path, int(line), int(column), "%s", string(text[:size]))
	}
	return cn_luau_checker_check(checker.handle, raw_data(s.name), c.size_t(len(s.name)), &report, on_error) == 0
}

// language_mode is the languageMode of the nearest .luaurc: 0 for nocheck, 1 for nonstrict and 2 for strict.
// Without one, a script is nonstrict. A --! comment in the script overrides it.
language_mode :: proc(dir: string) -> c.int {
	Luaurc :: struct {
		languageMode: string,
	}
	current := dir
	for {
		if data, err := os.read_entire_file(fmt.tprintf("%s/%s", current, LUAURC), context.temp_allocator); err == nil {
			config: Luaurc
			if json.unmarshal(data, &config, .JSON5, context.temp_allocator) == nil {
				switch config.languageMode {
				case "nocheck":
					return 0
				case "nonstrict":
					return 1
				case "strict":
					return 2
				}
			}
		}
		parent := slashpath.dir(current, context.temp_allocator)
		if parent == current || parent == "" || parent == "." {
			return 1
		}
		current = parent
	}
}
