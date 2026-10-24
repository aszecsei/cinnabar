// tools/cook compiles source assets. See docs/content-pipeline.md#cooking.
//
// `cook shaders --dxc <dxc.exe> --include <dir> <dir>` cooks shaders, `cook scripts` cooks scripts (see
// scripts.odin), and `cook scenes` cooks scenes (see scenes.odin).
//
// Each <name>.hlsl compiles its vs_main, ps_main, cs_main, as_main and ms_main entry points to <name>.<stage>.dxil,
// with the fixed root signature attached, so DXC rejects a shader that does not fit it. A file with [shader("...")]
// attributes is a ray tracing library and compiles to <name>.lib.dxil. An output is rebuilt only when its cache key
// changes: a hash of the cooker version, the DXC version, the profile, the entry point, and the source with every
// file it includes. The key is stored next to the output in <output>.key.
package cook

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Changing how the cooker compiles changes this, which invalidates every cached output.
COOK_VERSION :: "shaders 1"
SHADER_MODEL :: "6_6"
STAGES :: [?]string{"vs", "ps", "cs", "as", "ms"}

Options :: struct {
	dxc:      string,
	includes: [dynamic]string,
	dir:      string,
}

USAGE :: `usage: cook shaders --dxc <dxc.exe> [--include <dir>]... <shader dir>
       cook scripts --cache <dir> --config dev|release [--definitions <file>] --root <name>=<dir> [--root <name>=<dir>]...
       cook scenes --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...`

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	command := len(os.args) > 1 ? os.args[1] : ""
	ok, parsed: bool
	switch command {
	case "shaders":
		options: Options
		if options, parsed = parse_args(os.args[1:]); parsed {
			ok = cook_shaders(options)
		}
	case "scripts":
		options: Script_Options
		if options, parsed = parse_script_args(os.args[2:]); parsed {
			ok = cook_scripts(options)
		}
	case "scenes":
		options: Script_Options
		if options, parsed = parse_script_args(os.args[2:]); parsed {
			ok = cook_scenes(options)
		}
	}
	if !parsed {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if !ok {
		os.exit(1)
	}
}

parse_args :: proc(args: []string) -> (options: Options, ok: bool) {
	if len(args) == 0 || args[0] != "shaders" {
		return
	}
	options.includes = make([dynamic]string, context.temp_allocator)
	for i := 1; i < len(args); i += 1 {
		switch {
		case args[i] == "--dxc" && i + 1 < len(args):
			options.dxc = args[i + 1]
			i += 1
		case args[i] == "--include" && i + 1 < len(args):
			append(&options.includes, args[i + 1])
			i += 1
		case options.dir == "":
			options.dir = args[i]
		case:
			return
		}
	}
	if options.dxc == "" || options.dir == "" {
		return
	}
	// Starting a process needs the executable's full path on Windows.
	dxc, err := os.get_absolute_path(options.dxc, context.temp_allocator)
	if err != nil {
		return
	}
	options.dxc = dxc
	return options, true
}

// Target is one output of a source file.
Target :: struct {
	stage:   string,
	profile: string,
	entry:   string,
}

// cook_shaders cooks every .hlsl file in the directory. It reports every failure, and returns false if any.
cook_shaders :: proc(options: Options) -> bool {
	dxc_version, version_ok := dxc_version(options.dxc)
	if !version_ok {
		log.errorf("cook: cannot run %s", options.dxc)
		return false
	}
	entries, err := os.read_all_directory_by_path(options.dir, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", options.dir, err)
		return false
	}
	ok := true
	compiled, current := 0, 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".hlsl") {
			continue
		}
		source_path := fmt.tprintf("%s/%s", options.dir, entry.name)
		source, read_err := os.read_entire_file(source_path, context.temp_allocator)
		if read_err != nil {
			log.errorf("cook: %s: %v", source_path, read_err)
			ok = false
			continue
		}
		inputs, includes_ok := gather_includes(source_path, options.includes[:])
		if !includes_ok {
			ok = false
			continue
		}
		for target in targets(string(source)) {
			output := fmt.tprintf("%s.%s.dxil", strings.trim_suffix(source_path, ".hlsl"), target.stage)
			key := cache_key(dxc_version, target, inputs[:])
			if cached_key(output) == key {
				current += 1
				continue
			}
			if !compile(options, source_path, output, target) {
				ok = false
				continue
			}
			write_err := os.write_entire_file(fmt.tprintf("%s.key", output), transmute([]byte)fmt.tprintf("%16x", key))
			if write_err != nil {
				log.errorf("cook: %s.key: %v", output, write_err)
			}
			compiled += 1
		}
	}
	log.infof("cook: %d shaders compiled, %d up to date", compiled, current)
	return ok
}

// targets lists a source file's outputs: one library, or one output per entry point that the source defines.
targets :: proc(source: string) -> []Target {
	if strings.contains(source, "[shader(\"") {
		result := make([]Target, 1, context.temp_allocator)
		result[0] = {stage = "lib", profile = "lib_" + SHADER_MODEL}
		return result
	}
	result := make([dynamic]Target, context.temp_allocator)
	for stage in STAGES {
		entry := fmt.tprintf("%s_main", stage)
		if contains_word(source, entry) {
			append(&result, Target{stage, fmt.tprintf("%s_%s", stage, SHADER_MODEL), entry})
		}
	}
	return result[:]
}

// contains_word finds a whole identifier, so vs_main does not match my_vs_main.
contains_word :: proc(text, word: string) -> bool {
	is_ident :: proc(c: byte) -> bool {
		return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
	}
	rest := text
	for {
		i := strings.index(rest, word)
		if i < 0 {
			return false
		}
		before := i == 0 || !is_ident(rest[i - 1])
		end := i + len(word)
		after := end == len(rest) || !is_ident(rest[end])
		if before && after {
			return true
		}
		rest = rest[i + 1:]
	}
}

// Input is a file that a shader's output depends on.
Input :: struct {
	path: string,
	data: []byte,
}

// gather_includes reads a source file and every file that it includes, directly or not, in a stable order. An include
// resolves next to the including file first, then in the include directories, like DXC.
gather_includes :: proc(source_path: string, include_dirs: []string) -> (inputs: [dynamic]Input, ok: bool) {
	inputs = make([dynamic]Input, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	append(&pending, source_path)
	for len(pending) > 0 {
		path := pop_front(&pending)
		if seen[path] {
			continue
		}
		seen[path] = true
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			log.errorf("cook: %s: %v", path, err)
			return inputs, false
		}
		append(&inputs, Input{path, data})
		for name in include_names(string(data)) {
			resolved, found := resolve_include(name, filepath.dir(path), include_dirs)
			if !found {
				log.errorf("cook: %s: cannot find include %q", path, name)
				return inputs, false
			}
			append(&pending, resolved)
		}
	}
	return inputs, true
}

// include_names lists the files in #include "name" lines.
include_names :: proc(source: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	text := source
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "#include") {
			continue
		}
		rest := strings.trim_space(trimmed[len("#include"):])
		if len(rest) >= 2 && rest[0] == '"' {
			if end := strings.index_byte(rest[1:], '"'); end >= 0 {
				append(&names, rest[1:][:end])
			}
		}
	}
	return names[:]
}

resolve_include :: proc(name, from_dir: string, include_dirs: []string) -> (path: string, ok: bool) {
	candidate := fmt.tprintf("%s/%s", from_dir, name)
	if os.is_file(candidate) {
		return candidate, true
	}
	for dir in include_dirs {
		candidate = fmt.tprintf("%s/%s", dir, name)
		if os.is_file(candidate) {
			return candidate, true
		}
	}
	return
}

cache_key :: proc(dxc_version: string, target: Target, inputs: []Input) -> u64 {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "%s\x00%s\x00%s\x00%s\x00", COOK_VERSION, dxc_version, target.profile, target.entry)
	key := hash.fnv64a(transmute([]byte)strings.to_string(builder))
	for input in inputs {
		key = hash.fnv64a(input.data, key)
	}
	return key
}

// cached_key reads an output's stored key. It returns 0 if the output or its key is missing.
cached_key :: proc(output: string) -> u64 {
	if !os.is_file(output) {
		return 0
	}
	data, err := os.read_entire_file(fmt.tprintf("%s.key", output), context.temp_allocator)
	if err != nil {
		return 0
	}
	key, ok := strconv_parse_hex(strings.trim_space(string(data)))
	return ok ? key : 0
}

strconv_parse_hex :: proc(s: string) -> (value: u64, ok: bool) {
	if len(s) == 0 || len(s) > 16 {
		return
	}
	for c in transmute([]byte)s {
		digit: u64
		switch c {
		case '0' ..= '9':
			digit = u64(c - '0')
		case 'a' ..= 'f':
			digit = u64(c - 'a' + 10)
		case:
			return
		}
		value = value << 4 | digit
	}
	return value, true
}

dxc_version :: proc(dxc: string) -> (version: string, ok: bool) {
	state, stdout, _, err := os.process_exec({command = {dxc, "--version"}}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		log.errorf("cook: %s --version: %v, exited %v with %d", dxc, err, state.exited, state.exit_code)
		return
	}
	return strings.trim_space(string(stdout)), true
}

// compile runs DXC. Stage entry points get the fixed root signature, so DXC checks that the shader fits it.
// A library gets its global root signature from the pipeline (see docs/gpu.md#ray-tracing).
compile :: proc(options: Options, source, output: string, target: Target) -> bool {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, options.dxc, "-nologo", "-HV", "2021", "-T", target.profile, "-Zi", "-Qembed_debug", "-Fo", output)
	if target.entry != "" {
		append(&args, "-E", target.entry, "-rootsig-define", "CN_ROOT_SIGNATURE")
	}
	for dir in options.includes {
		append(&args, "-I", dir)
	}
	append(&args, source)
	state, stdout, stderr, err := os.process_exec({command = args[:]}, context.temp_allocator)
	if err != nil {
		log.errorf("cook: cannot run %s: %v", options.dxc, err)
		return false
	}
	if !state.exited || state.exit_code != 0 {
		log.errorf("cook: %s (%s):\n%s%s", source, target.profile, string(stdout), string(stderr))
		return false
	}
	return true
}
