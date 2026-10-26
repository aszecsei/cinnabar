// `cook shaders --cache <dir> --config dev|release --dxc <dxc.exe> [--include <dir>]... --root <name>=<dir>...` cooks
// every .hlsl file in the content roots into <cache>/<config>/<guid>.blob. See docs/content/kinds/shaders.md#shaders.
//
// Each file's vs_main, ps_main, cs_main, as_main and ms_main entry points compile into one blob, with the fixed root
// signature attached, so DXC rejects a shader that does not fit it. A file with [shader("...")] attributes is a ray
// tracing library and has one library entry.
package cook

import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"

import format "cinnabar:engine/asset/format"

// Changing how the cooker compiles shaders changes this, which invalidates every cooked shader.
SHADER_COOK_VERSION :: "shaders 2"
SHADER_MODEL :: "6_6"
// The entry points that a source may define, by stage.
ENTRY_POINTS :: [?]struct {
	stage:  format.Shader_Stage,
	prefix: string,
}{{.Vertex, "vs"}, {.Pixel, "ps"}, {.Compute, "cs"}, {.Amplification, "as"}, {.Mesh, "ms"}}

// Target is one entry of a shader blob: a stage, its profile and its entry point. A library has no entry point.
Target :: struct {
	stage:   format.Shader_Stage,
	profile: string,
	entry:   string,
}

// cook_shaders cooks the shaders among the assets whose keys changed. A shader that fails keeps its old blob, so the
// running game keeps drawing with the last good version. It reports every failure, and returns false if any.
cook_shaders :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	shaders := assets_of(assets, .Shader)
	if len(shaders) == 0 {
		return true
	}
	if options.dxc == "" {
		for i in shaders {
			report_error(problems, assets[i].path, 0, 0, "not cooked: the cooker has no --dxc to compile shaders with")
			assets[i].failed = true
		}
		return false
	}
	out_dir := config_dir(options)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		report_error(problems, out_dir, 0, 0, "%v", err)
		return false
	}
	ok := true
	for i in shaders {
		s := &assets[i]
		inputs, inputs_ok := gather_includes(s.path, s.source, options.includes[:], problems)
		if !check_settings(s^, problems) || !inputs_ok {
			s.failed = true
			ok = false
			continue
		}
		key := shader_key(options, s^, inputs)
		buffer: [32]u8
		output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.meta.guid, &buffer))
		if cooked_key(output, .Shader, format.shader_layout()) == key && !pass.force[s.meta.guid] {
			pass.current[.Shader] += 1
			continue
		}
		entries := make([dynamic]format.Shader_Code, context.temp_allocator)
		compiled := true
		for target in targets(string(s.source)) {
			code, code_ok := compile(options, s^, target, out_dir, problems)
			if !code_ok {
				compiled = false
				continue
			}
			append(&entries, format.Shader_Code{target.stage, .DXIL, code})
		}
		if !compiled {
			s.failed = true
			ok = false
			continue
		}
		blob := format.shader_write({guid = s.meta.guid, key = key, entries = entries[:], source_path = s.name}, context.temp_allocator)
		if !write_blob(output, blob) {
			s.failed = true
			ok = false
			continue
		}
		pass.cooked[.Shader] += 1
	}
	return ok
}

// shader_key covers what the blob depends on: the cooker, DXC, the configuration, the path, the settings, the source
// and every file that it includes, directly or not.
shader_key :: proc(options: Cook_Options, s: Asset_Source, inputs: []Input) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00%x\x00", SHADER_COOK_VERSION, options.dxc_version, options.config, s.name, format.shader_layout()),
	)
	key = hash.fnv64a(transmute([]byte)s.meta_text, key)
	for input in inputs {
		key = hash.fnv64a(transmute([]byte)input.path, key)
		key = hash.fnv64a(input.data, key)
	}
	return key
}

// targets lists a source file's entries: one library, or one entry per entry point that the source defines.
targets :: proc(source: string) -> []Target {
	if strings.contains(source, "[shader(\"") {
		result := make([]Target, 1, context.temp_allocator)
		result[0] = {stage = .Library, profile = "lib_" + SHADER_MODEL}
		return result
	}
	result := make([dynamic]Target, context.temp_allocator)
	for e in ENTRY_POINTS {
		entry := fmt.tprintf("%s_main", e.prefix)
		if contains_word(source, entry) {
			append(&result, Target{e.stage, fmt.tprintf("%s_%s", e.prefix, SHADER_MODEL), entry})
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

// Input is a file that a shader depends on: its source, or a file that it includes.
Input :: struct {
	// Absolute, with forward slashes.
	path: string,
	data: []byte,
}

// Include is an #include "name" line of a source.
Include :: struct {
	name: string,
	line: int,
}

// gather_includes gives a source and every file that it includes, directly or not, in a stable order. An include
// resolves next to the including file first, then in the include directories, like DXC. An include that cannot be
// found is a problem of the file that has it.
gather_includes :: proc(source_path: string, source: []byte, include_dirs: []string, problems: ^Problems) -> (inputs: []Input, ok: bool) {
	found := make([dynamic]Input, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]Input, context.temp_allocator)
	append(&pending, Input{source_path, source})
	ok = true
	for len(pending) > 0 {
		input := pop_front(&pending)
		if seen[input.path] {
			continue
		}
		seen[input.path] = true
		append(&found, input)
		for include in include_names(string(input.data)) {
			resolved, resolved_ok := resolve_include(include.name, filepath.dir(input.path), include_dirs)
			if !resolved_ok {
				report_error(problems, input.path, include.line, 0, "cannot find the include %q", include.name)
				ok = false
				continue
			}
			data, err := os.read_entire_file(resolved, context.temp_allocator)
			if err != nil {
				report_error(problems, resolved, 0, 0, "%v", err)
				ok = false
				continue
			}
			append(&pending, Input{resolved, data})
		}
	}
	return found[:], ok
}

// include_names lists the files in #include "name" lines, with their lines.
include_names :: proc(source: string) -> []Include {
	names := make([dynamic]Include, context.temp_allocator)
	text := source
	line := 0
	for l in strings.split_lines_iterator(&text) {
		line += 1
		trimmed := strings.trim_space(l)
		if !strings.has_prefix(trimmed, "#include") {
			continue
		}
		rest := strings.trim_space(trimmed[len("#include"):])
		if len(rest) >= 2 && rest[0] == '"' {
			if end := strings.index_byte(rest[1:], '"'); end >= 0 {
				append(&names, Include{rest[1:][:end], line})
			}
		}
	}
	return names[:]
}

// resolve_include finds an included file. The result has forward slashes.
resolve_include :: proc(name, from_dir: string, include_dirs: []string) -> (path: string, ok: bool) {
	// Generated material sources include their shading model by its absolute path.
	if filepath.is_abs(name) {
		return forward_slashes(name), os.is_file(name)
	}
	candidate := fmt.tprintf("%s/%s", from_dir, name)
	if os.is_file(candidate) {
		return forward_slashes(candidate), true
	}
	for dir in include_dirs {
		candidate = fmt.tprintf("%s/%s", dir, name)
		if os.is_file(candidate) {
			return forward_slashes(candidate), true
		}
	}
	return
}

dxc_version :: proc(dxc: string) -> (version: string, ok: bool) {
	state, stdout, _, err := run_process({dxc, "--version"})
	if err != nil || !state.exited || state.exit_code != 0 {
		log.errorf("cook: %s --version: %v, exited %v with %d", dxc, err, state.exited, state.exit_code)
		return
	}
	return strings.trim_space(string(stdout)), true
}

// compile runs DXC for one entry and gives its bytecode. Stage entry points get the fixed root signature, so DXC
// checks that the shader fits it. A library gets its global root signature from the pipeline (see
// docs/gpu/ray-tracing.md#ray-tracing). Development builds embed debug information, so PIX shows the source.
compile :: proc(options: Cook_Options, s: Asset_Source, target: Target, out_dir: string, problems: ^Problems) -> (code: []byte, ok: bool) {
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.%v.dxil.tmp", out_dir, format.guid_format(s.meta.guid, &buffer), target.stage)
	return compile_file(options, s.path, target, output, problems)
}

// compile_file compiles a source file's entry into output, a temporary file that it removes, and gives its bytecode. A
// failure without a message of its own is a problem of owner, the asset that the source is for, which is the source
// itself unless it is generated.
compile_file :: proc(options: Cook_Options, source_path: string, target: Target, output: string, problems: ^Problems, owner_path := "") -> (code: []byte, ok: bool) {
	defer os.remove(output)
	owner := owner_path if owner_path != "" else source_path
	args := make([dynamic]string, context.temp_allocator)
	append(&args, options.dxc, "-nologo", "-HV", "2021", "-T", target.profile, "-Fo", output)
	if options.config == .Dev {
		append(&args, "-Zi", "-Qembed_debug")
	}
	if target.entry != "" {
		append(&args, "-E", target.entry, "-rootsig-define", "CN_ROOT_SIGNATURE")
	}
	for dir in options.includes {
		append(&args, "-I", dir)
	}
	append(&args, source_path)
	state, stdout, stderr, err := run_process(args[:])
	if err != nil {
		report_error(problems, owner, 0, 0, "cannot run %s: %v", options.dxc, err)
		return
	}
	failed := !state.exited || state.exit_code != 0
	output_text := fmt.tprintf("%s%s", string(stdout), string(stderr))
	errors := report_dxc_messages(output_text, problems)
	if failed {
		if errors == 0 {
			report_error(problems, owner, 0, 0, "%s did not compile:\n%s", target.profile, strings.trim_space(output_text))
		} else if !has_error_in(problems, owner) {
			// Every error is in an include, which belongs to no asset, so the shader says why it did not cook.
			report_error(problems, owner, 0, 0, "%s did not compile, because a file that it includes has errors", target.profile)
		}
		return
	}
	data, read_err := os.read_entire_file(output, context.temp_allocator)
	if read_err != nil {
		report_error(problems, owner, 0, 0, "%s: %v", output, read_err)
		return
	}
	return data, true
}

// Windows children inherit every inheritable handle, so a process started on one thread can hold the pipes of a process
// that another thread started, which then never sees its output end. The cooker therefore runs one process at a time.
@(private = "file")
process_lock: sync.Mutex

// run_process runs a command to its end, and gives its output in the temporary allocator.
run_process :: proc(command: []string) -> (state: os.Process_State, stdout, stderr: []byte, err: os.Error) {
	sync.mutex_guard(&process_lock)
	return os.process_exec({command = command}, context.temp_allocator)
}

// report_dxc_messages reports DXC's errors and warnings, which it writes as `<file>:<line>:<column>: error: <text>`,
// as problems of their files. Each stage compiles on its own, so a message that an earlier stage's compile reported,
// as one in a shared include, is not reported again. It returns the number of errors.
report_dxc_messages :: proc(text: string, problems: ^Problems) -> (errors: int) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		for severity in ([?]string{": error: ", ": warning: "}) {
			at := strings.index(line, severity)
			if at < 0 {
				continue
			}
			file, row, column := dxc_place(line[:at])
			message := strings.trim_space(line[at + len(severity):])
			is_error := severity == ": error: "
			if is_error {
				errors += 1
			}
			if has_problem(problems, {file, row, column, is_error, message}) {
				break
			}
			if is_error {
				report_error(problems, file, row, column, "%s", message)
			} else {
				report_warning(problems, file, row, column, "%s", message)
			}
			break
		}
	}
	return
}

// dxc_place splits `<file>:<line>:<column>`. A file has a drive's colon, so the numbers are taken from the end.
dxc_place :: proc(place: string) -> (file: string, line, column: int) {
	file = forward_slashes(place)
	last := strings.last_index_byte(place, ':')
	if last < 0 {
		return
	}
	before := strings.last_index_byte(place[:last], ':')
	if before < 0 {
		return
	}
	l, l_ok := strconv.parse_int(place[before + 1:last])
	c, c_ok := strconv.parse_int(place[last + 1:])
	if !l_ok || !c_ok {
		return
	}
	return forward_slashes(place[:before]), l, c
}

@(private = "file")
has_problem :: proc(problems: ^Problems, problem: Problem) -> bool {
	for p in problems.list {
		if p == problem {
			return true
		}
	}
	return false
}

@(private = "file")
has_error_in :: proc(problems: ^Problems, file: string) -> bool {
	for p in problems.list {
		if p.error && strings.equal_fold(p.file, file) {
			return true
		}
	}
	return false
}
