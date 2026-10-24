// `cook scripts --cache <dir> --config dev|release --root <name>=<dir>...` cooks every .luau file in the content
// roots into <cache>/<config>/<guid>.blob. See docs/content-pipeline.md#scripts.
package cook

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"

// Changing how the cooker compiles scripts changes this, which invalidates every cooked script.
SCRIPT_COOK_VERSION :: "scripts 2"
// The justfile passes the vendor/luau tag, so a Luau update cooks every script again.
LUAU_VERSION :: #config(LUAU_VERSION, "unknown")
SCRIPT_EXTENSION :: ".luau"
LUAURC :: ".luaurc"

Script_Config :: enum {
	Dev,
	Release,
}

Root :: struct {
	name: string,
	// Absolute, with forward slashes.
	dir:  string,
}

Script_Options :: struct {
	cache:  string,
	config: Script_Config,
	roots:  [dynamic]Root,
}

Script_Source :: struct {
	root:      int,
	// Absolute, with forward slashes.
	path:      string,
	// The root's name and the path relative to the root, such as "game/scripts/hello.luau".
	name:      string,
	meta_text: string,
	meta:      format.Meta,
	source:    []byte,
	requires:  [dynamic]Found_Require,
	// The resolved requires, sorted by path.
	resolved:  [dynamic]Resolved_Require,
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

parse_script_args :: proc(args: []string) -> (options: Script_Options, ok: bool) {
	options.roots = make([dynamic]Root, context.temp_allocator)
	config_set := false
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) {
			return
		}
		value := args[i + 1]
		switch args[i] {
		case "--cache":
			options.cache = value
		case "--config":
			switch value {
			case "dev":
				options.config = .Dev
			case "release":
				options.config = .Release
			case:
				return
			}
			config_set = true
		case "--root":
			equals := strings.index_byte(value, '=')
			if equals <= 0 {
				return
			}
			dir, err := os.get_absolute_path(value[equals + 1:], context.temp_allocator)
			if err != nil {
				return
			}
			append(&options.roots, Root{value[:equals], forward_slashes(dir)})
		case:
			return
		}
		i += 1
	}
	return options, options.cache != "" && config_set && len(options.roots) > 0
}

// cook_scripts cooks every script in the roots. It reports every failure, and returns false if any.
cook_scripts :: proc(options: Script_Options) -> bool {
	scripts, collected := collect_scripts(options.roots[:])
	ok := collected
	by_path := make(map[string]int, len(scripts), context.temp_allocator)
	for s, i in scripts {
		by_path[s.path] = i
	}
	for &s in scripts {
		if !find_requires(&s) {
			ok = false
			continue
		}
		if !resolve_requires(scripts, by_path, &s) {
			ok = false
		}
	}
	if !ok || !check_cycles(scripts) {
		return false
	}

	out_dir := fmt.tprintf("%s/%s", options.cache, options.config == .Dev ? "dev" : "release")
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", out_dir, err)
		return false
	}
	compiled, current := 0, 0
	for &s in scripts {
		key := script_key(options.config, s)
		buffer: [32]u8
		output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.meta.guid, &buffer))
		if cooked_script_key(output) == key {
			current += 1
			continue
		}
		if !compile_script(options.config, s, key, output) {
			ok = false
			continue
		}
		compiled += 1
	}
	log.infof("cook: %d scripts compiled, %d up to date", compiled, current)
	return ok
}

// collect_scripts reads every script in the roots with its .meta file, in path order. A script without a .meta file
// gets a new GUID, and the cooker writes its .meta file.
collect_scripts :: proc(roots: []Root) -> (scripts: []Script_Source, ok: bool) {
	found := make([dynamic]Script_Source, context.temp_allocator)
	ok = true
	for root, root_index in roots {
		walker := os.walker_create(root.dir)
		defer os.walker_destroy(&walker)
		for info in os.walker_walk(&walker) {
			if strings.has_prefix(info.name, ".") {
				if info.type == .Directory {
					os.walker_skip_dir(&walker)
				}
				continue
			}
			if info.type != .Regular || !strings.has_suffix(info.name, SCRIPT_EXTENSION) {
				continue
			}
			path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
			name := fmt.tprintf("%s/%s", root.name, strings.trim_prefix(path, fmt.tprintf("%s/", root.dir)))
			s := Script_Source {
				root     = root_index,
				path     = path,
				name     = name,
				requires = make([dynamic]Found_Require, context.temp_allocator),
				resolved = make([dynamic]Resolved_Require, context.temp_allocator),
			}
			if !read_script(&s) {
				ok = false
				continue
			}
			append(&found, s)
		}
		if path, err := os.walker_error(&walker); err != nil {
			log.errorf("cook: %s: %v", path, err)
			ok = false
		}
	}
	slice.sort_by(found[:], proc(a, b: Script_Source) -> bool {return a.path < b.path})
	for i in 1 ..< len(found) {
		for j in 0 ..< i {
			if found[i].meta.guid == found[j].meta.guid {
				log.errorf("cook: %s and %s have the same GUID. Delete the .meta file of the copy.", found[j].path, found[i].path)
				ok = false
			}
		}
	}
	return found[:], ok
}

@(private = "file")
read_script :: proc(s: ^Script_Source) -> bool {
	source, err := os.read_entire_file(s.path, context.temp_allocator)
	if err != nil {
		log.errorf("cook: %s: %v", s.path, err)
		return false
	}
	s.source = source
	meta_path := fmt.tprintf("%s%s", s.path, format.META_EXTENSION)
	meta_bytes, meta_err := os.read_entire_file(meta_path, context.temp_allocator)
	if meta_err == .Not_Exist {
		guid: format.Guid
		crypto.rand_bytes(guid[:])
		buffer: [32]u8
		text := fmt.tprintf("# cinnabar asset metadata. Keep this file next to its asset (see docs/content-pipeline.md#identity).\nguid = %s\n", format.guid_format(guid, &buffer))
		if write_err := os.write_entire_file(meta_path, transmute([]byte)text); write_err != nil {
			log.errorf("cook: %s: %v", meta_path, write_err)
			return false
		}
		log.infof("cook: assigned a GUID to %s", s.name)
		meta_bytes = transmute([]byte)text
	} else if meta_err != nil {
		log.errorf("cook: %s: %v", meta_path, meta_err)
		return false
	}
	s.meta_text = string(meta_bytes)
	meta, meta_ok := format.meta_parse(s.meta_text, context.temp_allocator)
	if !meta_ok {
		log.errorf("cook: %s: needs `guid = <32 hex digits>`, and `key = value` lines", meta_path)
		return false
	}
	s.meta = meta
	for setting in meta.settings {
		switch setting.key {
		case "native":
			if setting.value != "true" && setting.value != "false" {
				log.errorf("cook: %s: native must be true or false", meta_path)
				return false
			}
		case:
			log.warnf("cook: %s: unknown setting %q", meta_path, setting.key)
		}
	}
	return true
}

@(private = "file")
Find_Context :: struct {
	ctx:    runtime.Context,
	script: ^Script_Source,
	failed: bool,
}

// find_requires lists the script's require calls. A parse error or a require without a string literal is an error.
find_requires :: proc(s: ^Script_Source) -> bool {
	on_require :: proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int) {
		f := (^Find_Context)(ud)
		context = f.ctx
		append(&f.script.requires, Found_Require{strings.clone(string(text[:size]), context.temp_allocator), int(line)})
	}
	on_error :: proc "c" (ud: rawptr, text: [^]u8, size: c.size_t, line: c.int) {
		f := (^Find_Context)(ud)
		context = f.ctx
		log.errorf("cook: %s:%d: %s", f.script.path, line, string(text[:size]))
		f.failed = true
	}
	f := Find_Context{ctx = context, script = s}
	cn_luau_find_requires(raw_data(s.source), c.size_t(len(s.source)), &f, on_require, on_error)
	return !f.failed
}

// resolve_requires resolves each require of a script to a script in the roots, as Luau's require does (see
// docs/scripting.md#modules-and-require).
resolve_requires :: proc(scripts: []Script_Source, by_path: map[string]int, s: ^Script_Source) -> bool {
	ok := true
	for r in s.requires {
		target, message := resolve_require(by_path, s.path, r.path)
		if message != "" {
			log.errorf("cook: %s:%d: cannot require %q: %s", s.path, r.line, r.path, message)
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

// check_cycles reports each require cycle once.
check_cycles :: proc(scripts: []Script_Source) -> bool {
	State :: enum u8 {
		New,
		Visiting,
		Done,
	}
	states := make([]State, len(scripts), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	ok := true
	visit :: proc(scripts: []Script_Source, states: []State, stack: ^[dynamic]int, i: int, ok: ^bool) {
		states[i] = .Visiting
		append(stack, i)
		for r in scripts[i].resolved {
			t := r.target
			switch states[t] {
			case .New:
				visit(scripts, states, stack, t, ok)
			case .Visiting:
				builder := strings.builder_make(context.temp_allocator)
				start, _ := slice.linear_search(stack[:], t)
				for s in stack[start:] {
					fmt.sbprintf(&builder, "%s -> ", scripts[s].name)
				}
				strings.write_string(&builder, scripts[t].name)
				log.errorf("cook: require cycle: %s", strings.to_string(builder))
				ok^ = false
			case .Done:
			}
		}
		pop(stack)
		states[i] = .Done
	}
	for i in 0 ..< len(scripts) {
		if states[i] == .New {
			visit(scripts, states, &stack, i, &ok)
		}
	}
	return ok
}

// script_key covers everything that the blob depends on: the cooker, Luau, the configuration, the source, the
// settings and the GUIDs that the requires resolve to.
script_key :: proc(config: Script_Config, s: Script_Source) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00", SCRIPT_COOK_VERSION, LUAU_VERSION, config, s.name))
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
	data, err := os.read_entire_file(output, context.temp_allocator)
	if err != nil || len(data) < size_of(format.Blob_Header) {
		return 0
	}
	header: format.Blob_Header
	copy(([^]byte)(&header)[:size_of(header)], data)
	if header.magic != format.BLOB_MAGIC || header.kind != .Script || header.layout != format.script_layout() {
		return 0
	}
	return header.key
}

// compile_script compiles a script and writes its blob. The blob is written to a temporary file and renamed, so the
// running game never reads a partial blob.
compile_script :: proc(config: Script_Config, s: Script_Source, key: u64, output: string) -> bool {
	mutable_globals := format.script_mutable_globals()
	options := luau.Compile_Options {
		optimizationLevel = config == .Dev ? 1 : 2,
		debugLevel        = config == .Dev ? 2 : 1,
		mutableGlobals    = &mutable_globals[0],
	}
	size: c.size_t
	bytecode := luau.compile(raw_data(s.source), c.size_t(len(s.source)), &options, &size)
	defer luau.free_bytecode(bytecode)
	// Failed compilation gives a zero byte and the message.
	if size == 0 || bytecode[0] == 0 {
		log.errorf("cook: %s%s", s.path, size > 1 ? string(bytecode[1:size]) : ": cannot compile")
		return false
	}
	requires := make([]format.Require_Entry, len(s.resolved), context.temp_allocator)
	for r, i in s.resolved {
		requires[i] = r.entry
	}
	flags: format.Script_Flags
	if native, _ := format.meta_value(s.meta, "native"); native == "true" {
		flags += {.Native}
	}
	blob := format.script_write(
		{
			guid = s.meta.guid,
			key = key,
			flags = flags,
			bytecode = bytecode[:size],
			requires = requires,
			source_path = s.name,
		},
		context.temp_allocator,
	)
	temporary := fmt.tprintf("%s.tmp", output)
	if err := os.write_entire_file(temporary, blob); err != nil {
		log.errorf("cook: %s: %v", temporary, err)
		return false
	}
	if err := os.rename(temporary, output); err != nil {
		log.errorf("cook: %s: %v", output, err)
		return false
	}
	return true
}

forward_slashes :: proc(path: string) -> string {
	result, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return result
}
