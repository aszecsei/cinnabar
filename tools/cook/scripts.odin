// `cook scripts --cache <dir> --config dev|release [--definitions <file>] --root <name>=<dir>...` cooks every .luau
// file in the content roots into <cache>/<config>/<guid>.blob, and type checks it against the definition file. See
// docs/content/kinds/scripts.md#scripts.
package cook

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"

// Changing how the cooker compiles scripts changes this, which invalidates every cooked script.
SCRIPT_COOK_VERSION :: "scripts 5"
// The justfile passes the vendor/luau tag, so a Luau update cooks every script again.
LUAU_VERSION :: #config(LUAU_VERSION, "unknown")
SCRIPT_EXTENSION :: ".luau"
LUAURC :: ".luaurc"

Script_Config :: enum {
	Dev,
	Release,
}

Script_Source :: struct {
	// Its index in the scan's assets.
	asset:     int,
	root:      int,
	// Absolute, with forward slashes.
	path:      string,
	// The root's name and the path relative to the root, such as "game/scripts/hello.luau".
	name:      string,
	meta_text: string,
	meta:      format.Meta,
	source:    []byte,
	requires:  [dynamic]Found_Require,
	// The source calls Behaviour.define, so the cooker runs its top level to read the fields.
	defines_behaviour: bool,
	// The source starts with --!native.
	native_comment:    bool,
	// The resolved requires, sorted by path.
	resolved:  [dynamic]Resolved_Require,
	// The script cannot cook: it has an error, or it requires a script that has one.
	failed:    bool,
	// The class that it defines, if it is a behaviour.
	behaviour: string,
}

Resolved_Require :: struct {
	entry:  format.Require_Entry,
	// The target's index in the script list.
	target: int,
}

Found_Require :: struct {
	path: string,
	line: int,
}

// cook_scripts cooks the scripts among the assets whose keys changed. A script that fails keeps its old blob, so the
// running game keeps the last good version, and so does every script that requires it, directly or not. The other
// scripts still cook. It reports every failure, and returns false if any.
cook_scripts :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	scripts := collect_scripts(assets, problems)
	// The index learns what each script depends on, whether it cooked, and its behaviour class.
	defer for s in scripts {
		a := &assets[s.asset]
		a.failed = s.failed
		for r in s.resolved {
			append(&a.dependencies, r.entry.target)
		}
		a.behaviour = s.behaviour
	}
	by_path := make(map[string]int, len(scripts), context.temp_allocator)
	for s, i in scripts {
		by_path[s.path] = i
	}
	for &s in scripts {
		if s.failed || !find_requires(&s, problems) {
			s.failed = true
			continue
		}
		if !resolve_requires(scripts, by_path, &s, problems) {
			s.failed = true
		}
	}
	check_cycles(scripts, problems)
	fail_dependents(scripts, problems)
	ok := true
	for s in scripts {
		ok &&= !s.failed
	}

	out_dir := config_dir(options)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		report_error(problems, out_dir, 0, 0, "%v", err)
		return false
	}
	definitions := definitions_hash(options.definitions)
	// The type checker and the VM that reads behaviours' fields open on the first script that needs them, so a cook
	// that finds everything up to date stays quick.
	checker: Type_Checker
	checker_open := false
	defer type_checker_close(&checker)
	vm: Schema_VM
	defer schema_vm_close(&vm)
	for &s, index in scripts {
		if s.failed {
			continue
		}
		key := script_key(options.config, s, dependency_hash(scripts, index) ~ definitions)
		buffer: [32]u8
		output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.meta.guid, &buffer))
		if cooked, behaviour := cooked_script(output); cooked == key && !pass.force[s.meta.guid] {
			s.behaviour = behaviour
			pass.current[.Script] += 1
			continue
		}
		if !checker_open {
			if !type_checker_open(&checker, options.definitions, scripts, problems) {
				s.failed = true
				return false
			}
			checker_open = true
		}
		if !type_check(&checker, s, problems) {
			s.failed = true
			ok = false
			continue
		}
		class_name: string
		fields: []format.Field_Entry
		if s.defines_behaviour {
			if vm.L == nil && !schema_vm_open(&vm, options.config, scripts, problems) {
				s.failed = true
				return false
			}
			schema_ok: bool
			class_name, fields, schema_ok = read_schema(&vm, index)
			if !schema_ok {
				s.failed = true
				ok = false
				continue
			}
		}
		if !compile_script(options.config, s, key, output, class_name, fields, problems) {
			s.failed = true
			ok = false
			continue
		}
		s.behaviour = class_name
		pass.cooked[.Script] += 1
	}
	return ok
}

// collect_scripts gives the scripts among the assets, and checks their settings. A script with a bad setting is
// marked failed.
collect_scripts :: proc(assets: []Asset_Source, problems: ^Problems) -> []Script_Source {
	found := make([dynamic]Script_Source, 0, len(assets), context.temp_allocator)
	for i in assets_of(assets, .Script) {
		a := assets[i]
		append(
			&found,
			Script_Source {
				asset = i,
				root = a.root,
				path = a.path,
				name = a.name,
				meta_text = a.meta_text,
				meta = a.meta,
				source = a.source,
				requires = make([dynamic]Found_Require, context.temp_allocator),
				resolved = make([dynamic]Resolved_Require, context.temp_allocator),
				failed = !check_settings(a, problems),
			},
		)
	}
	return found[:]
}

// fail_dependents marks every script that requires a failed script, directly or not, as failed, and says why.
fail_dependents :: proc(scripts: []Script_Source, problems: ^Problems) {
	for changed := true; changed; {
		changed = false
		for &s in scripts {
			if s.failed {
				continue
			}
			for r in s.resolved {
				if scripts[r.target].failed {
					report_error(problems, s.path, 0, 0, "not cooked, because it requires %s, which did not cook", scripts[r.target].name)
					s.failed = true
					changed = true
					break
				}
			}
		}
	}
}

@(private = "file")
Find_Context :: struct {
	ctx:      runtime.Context,
	script:   ^Script_Source,
	problems: ^Problems,
	failed:   bool,
}

// find_requires lists the script's require calls. A parse error or a require without a string literal is an error.
find_requires :: proc(s: ^Script_Source, problems: ^Problems) -> bool {
	on_require :: proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int) {
		f := (^Find_Context)(ud)
		context = f.ctx
		append(&f.script.requires, Found_Require{strings.clone(string(text[:size]), context.temp_allocator), int(line)})
	}
	on_error :: proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int) {
		f := (^Find_Context)(ud)
		context = f.ctx
		report_error(f.problems, f.script.path, int(line), 0, "%s", string(text[:size]))
		f.failed = true
	}
	f := Find_Context{ctx = context, script = s, problems = problems}
	cn_luau_find_requires(raw_data(s.source), c.size_t(len(s.source)), &f, on_require, on_error, &s.defines_behaviour, &s.native_comment)
	return !f.failed
}

// resolve_requires resolves each require of a script to a script in the roots, as Luau's require does (see
// docs/scripting/tooling-and-hot-reload.md#modules-and-require).
resolve_requires :: proc(scripts: []Script_Source, by_path: map[string]int, s: ^Script_Source, problems: ^Problems) -> bool {
	ok := true
	for r in s.requires {
		target, message := resolve_require(by_path, s.path, r.path)
		if message != "" {
			report_error(problems, s.path, r.line, 0, "cannot require %q: %s", r.path, message)
			ok = false
			continue
		}
		duplicate := false
		for e in s.resolved {
			duplicate ||= e.entry.path == r.path
		}
		if !duplicate {
			append(&s.resolved, Resolved_Require{{r.path, scripts[target].meta.guid}, target})
		}
	}
	slice.sort_by(s.resolved[:], proc(a, b: Resolved_Require) -> bool {return a.entry.path < b.entry.path})
	return ok
}

// resolve_require finds the script that a require path names. On failure it returns a message.
//
// A file a/b.luau is the module a/b, and a/init.luau is the module a. "./" and "../" start at the module's parent,
// "@self/" at the module itself, and any other "@alias/" at the directory that the nearest .luaurc names for it.
resolve_require :: proc(by_path: map[string]int, requirer, path: string) -> (target: int, message: string) {
	module := module_of(requirer)
	base, rest: string
	switch {
	case strings.has_prefix(path, "./") || strings.has_prefix(path, "../"):
		base, rest = slashpath.dir(module, context.temp_allocator), path
	case strings.has_prefix(path, "@"):
		slash := strings.index_byte(path, '/')
		alias := strings.to_lower(path[1:slash if slash >= 0 else len(path)], context.temp_allocator)
		rest = slash >= 0 ? path[slash + 1:] : ""
		if alias == "self" {
			base = module
		} else {
			found: bool
			base, found, message = find_alias(slashpath.dir(requirer, context.temp_allocator), alias)
			if message != "" {
				return
			}
			if !found {
				return 0, fmt.tprintf("no %s file defines the alias @%s", LUAURC, alias)
			}
		}
	case:
		return 0, "the path must start with ./, ../ or @"
	}
	location := slashpath.clean(slashpath.join({base, rest}, context.temp_allocator), context.temp_allocator)
	file, file_found := by_path[fmt.tprintf("%s%s", location, SCRIPT_EXTENSION)]
	init, init_found := by_path[fmt.tprintf("%s/init%s", location, SCRIPT_EXTENSION)]
	switch {
	case file_found && init_found:
		return 0, fmt.tprintf("both %s%s and %s/init%s exist", location, SCRIPT_EXTENSION, location, SCRIPT_EXTENSION)
	case file_found:
		return file, ""
	case init_found:
		return init, ""
	}
	return 0, fmt.tprintf("no module at %s", location)
}

module_of :: proc(path: string) -> string {
	if slashpath.base(path, false, context.temp_allocator) == "init" + SCRIPT_EXTENSION {
		return slashpath.dir(path, context.temp_allocator)
	}
	return strings.trim_suffix(path, SCRIPT_EXTENSION)
}

// find_alias looks for the alias in the .luaurc files from dir up to the file system's root. Alias names are not
// case-sensitive, and a path is relative to the .luaurc that defines it.
find_alias :: proc(dir, alias: string) -> (target: string, found: bool, message: string) {
	Luaurc :: struct {
		aliases: map[string]string,
	}
	current := dir
	for {
		config_path := fmt.tprintf("%s/%s", current, LUAURC)
		if data, err := os.read_entire_file(config_path, context.temp_allocator); err == nil {
			config: Luaurc
			if json.unmarshal(data, &config, .JSON5, context.temp_allocator) != nil {
				return "", false, fmt.tprintf("%s is not valid JSON", config_path)
			}
			for name, value in config.aliases {
				if strings.to_lower(name, context.temp_allocator) != alias {
					continue
				}
				if strings.has_prefix(value, "@") {
					return "", false, fmt.tprintf("%s: the alias @%s names another alias, which the cooker does not support", config_path, name)
				}
				return slashpath.clean(slashpath.join({current, value}, context.temp_allocator), context.temp_allocator), true, ""
			}
		}
		parent := slashpath.dir(current, context.temp_allocator)
		if parent == current || parent == "" || parent == "." {
			return
		}
		current = parent
	}
}

// check_cycles reports each require cycle in each of its scripts, and marks them failed.
check_cycles :: proc(scripts: []Script_Source, problems: ^Problems) {
	State :: enum u8 {
		New,
		Visiting,
		Done,
	}
	states := make([]State, len(scripts), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	visit :: proc(scripts: []Script_Source, states: []State, stack: ^[dynamic]int, i: int, problems: ^Problems) {
		states[i] = .Visiting
		append(stack, i)
		for r in scripts[i].resolved {
			t := r.target
			switch states[t] {
			case .New:
				visit(scripts, states, stack, t, problems)
			case .Visiting:
				builder := strings.builder_make(context.temp_allocator)
				start, _ := slice.linear_search(stack[:], t)
				for s in stack[start:] {
					fmt.sbprintf(&builder, "%s -> ", scripts[s].name)
				}
				strings.write_string(&builder, scripts[t].name)
				for s in stack[start:] {
					report_error(problems, scripts[s].path, 0, 0, "require cycle: %s", strings.to_string(builder))
					scripts[s].failed = true
				}
			case .Done:
			}
		}
		pop(stack)
		states[i] = .Done
	}
	for i in 0 ..< len(scripts) {
		if states[i] == .New {
			visit(scripts, states, &stack, i, problems)
		}
	}
}

// script_key covers everything that the blob depends on: the cooker, Luau, the configuration, the source, the
// settings, the GUIDs that the requires resolve to, and the dependencies' sources (see dependency_hash).
script_key :: proc(config: Script_Config, s: Script_Source, dependencies: u64) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00%x\x00", SCRIPT_COOK_VERSION, LUAU_VERSION, config, s.name, dependencies))
	key = hash.fnv64a(s.source, key)
	key = hash.fnv64a(transmute([]byte)s.meta_text, key)
	for r in s.resolved {
		key = hash.fnv64a(transmute([]byte)r.entry.path, key)
		target := r.entry.target
		key = hash.fnv64a(target[:], key)
	}
	return key
}

// cooked_script_key reads the key of a cooked script. It returns 0 if there is none, or if the blob is from a
// cooker with other blob structures.
cooked_script_key :: proc(output: string) -> u64 {
	return cooked_key(output, .Script, format.script_layout())
}

// cooked_script reads the key of a cooked script, as cooked_script_key does, and its behaviour class, if any.
cooked_script :: proc(output: string) -> (key: u64, behaviour: string) {
	key = cooked_script_key(output)
	if key == 0 {
		return
	}
	data, err := os.read_entire_file(output, context.temp_allocator)
	if err != nil {
		return 0, ""
	}
	// The blob's offsets assume the runtime's alignment.
	aligned, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, data)
	if blob, ok := format.script_view(aligned); ok && .Behaviour in blob.flags {
		behaviour = format.blob_string(aligned, blob.class_name)
	}
	return
}

// compile_script compiles a script and writes its blob.
compile_script :: proc(config: Script_Config, s: Script_Source, key: u64, output: string, class_name: string, fields: []format.Field_Entry, problems: ^Problems) -> bool {
	bytecode := compile_source(config, string(s.source))
	defer luau.free_bytecode(raw_data(bytecode))
	// Failed compilation gives a zero byte and the message.
	if len(bytecode) == 0 || bytecode[0] == 0 {
		// The message starts with the line, as ":3: ...".
		message, line := "cannot compile", 0
		if len(bytecode) > 1 {
			message = string(bytecode[1:])
			if rest := strings.trim_prefix(message, ":"); len(rest) < len(message) {
				if colon := strings.index_byte(rest, ':'); colon > 0 {
					if n, n_ok := strconv.parse_int(rest[:colon]); n_ok {
						line, message = n, strings.trim_space(rest[colon + 1:])
					}
				}
			}
		}
		report_error(problems, s.path, line, 0, "%s", message)
		return false
	}
	requires := make([]format.Require_Entry, len(s.resolved), context.temp_allocator)
	for r, i in s.resolved {
		requires[i] = r.entry
	}
	flags: format.Script_Flags
	// The runtime compiles the module to machine code (see docs/scripting/tooling-and-hot-reload.md#native-code-generation).
	if native, _ := format.meta_value(s.meta, "native"); native == "true" || s.native_comment {
		flags += {.Native}
	}
	if class_name != "" {
		flags += {.Behaviour}
	}
	blob := format.script_write(
		{
			guid = s.meta.guid,
			key = key,
			flags = flags,
			bytecode = bytecode,
			requires = requires,
			source_path = s.name,
			class_name = class_name,
			fields = fields,
		},
		context.temp_allocator,
	)
	return write_blob(output, blob)
}

// compile_source compiles with the configuration's settings. Release the result with luau.free_bytecode.
compile_source :: proc(config: Script_Config, source: string) -> []byte {
	mutable_globals := format.script_mutable_globals()
	options := luau.Compile_Options {
		optimizationLevel = config == .Dev ? 1 : 2,
		debugLevel        = config == .Dev ? 2 : 1,
		mutableGlobals    = &mutable_globals[0],
	}
	size: c.size_t
	bytecode := luau.compile(raw_data(source), c.size_t(len(source)), &options, &size)
	return bytecode[:size]
}

forward_slashes :: proc(path: string) -> string {
	result, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return result
}
