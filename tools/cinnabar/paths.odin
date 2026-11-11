package cinnabar

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The DXC release that the engine's cooker compiles shaders with, which the justfile gives (dxc_version).
DXC_VERSION :: #config(DXC_VERSION, "")
// The engine's own content root, by which a folder is known as the engine's checkout.
ENGINE_CONTENT :: "lib/engine/content"
// The variable that names the engine's checkout, when the command line does not.
ENGINE_VARIABLE :: "CINNABAR_ROOT"
// The settings' keys that the tool reads (see docs/overview/architecture.md#project-settings).
NAME_KEY :: "game.name"
ICON_KEY :: "game.icon"
MAIN_SCENE_KEY :: "game.main_scene"
ENGINE_PATH_KEY :: "engine.path"

// Engine is where a built engine checkout keeps what a project builds and runs with. Every path is absolute, with
// forward slashes.
Engine :: struct {
	root:        string,
	lib:         string,
	// The engine's content root, which every cook takes with the project's.
	content:     string,
	// The development host and the standard game's DLL, with the runtime libraries beside them.
	dev:         string,
	host:        string,
	standard:    string,
	// The standard game's release executable, which a project without Odin is exported with.
	runtime:     string,
	cook:        string,
	editor:      string,
	dxc:         string,
	// The directories that the shaders' includes resolve in.
	includes:    [3]string,
	// The project templates (see docs/overview/getting-started.md#a-new-project).
	templates:   string,
}

engine_paths :: proc(root_dir: string, allocator := context.allocator) -> Engine {
	context.allocator = allocator
	root := slashes(root_dir)
	join :: proc(parts: ..string) -> string {
		return strings.join(parts, "/")
	}
	return {
		root = root,
		lib = join(root, "lib"),
		content = join(root, ENGINE_CONTENT),
		dev = join(root, "build/dev"),
		host = join(root, "build/dev/host.exe"),
		standard = join(root, "build/dev/standard.dll"),
		runtime = join(root, "build/runtime/runtime.exe"),
		cook = join(root, "build/tools/cook.exe"),
		editor = join(root, "build/obj/dotnet/bin/Cinnabar.Editor/debug/editor.exe"),
		dxc = join(root, "vendor/dxc", DXC_VERSION, "dxc.exe"),
		includes = {join(root, "lib/core/gpu/shaders"), join(root, "lib/engine/content/shaders"), join(root, "vendor/smaa")},
		templates = join(root, "lib/engine/templates"),
	}
}

// Engine_Source is where find_engine found the engine's checkout.
Engine_Source :: enum u8 {
	Argument,
	Variable,
	User_Settings,
	Executable,
}

// find_engine finds the engine's checkout: --engine, then CINNABAR_ROOT, then engine.path in the project's user
// settings, then the checkout that this executable was built in, two folders up from build/tools. A candidate is the
// engine's when it has lib/engine/content. It returns the first candidate that is, and the candidates it tried.
find_engine :: proc(argument, variable, user_setting, exe_dir: string) -> (root: string, source: Engine_Source, ok: bool) {
	candidates := [Engine_Source]string {
		.Argument      = argument,
		.Variable      = variable,
		.User_Settings = user_setting,
		.Executable    = exe_dir == "" ? "" : filepath.dir(filepath.dir(exe_dir)),
	}
	for candidate, s in candidates {
		if candidate == "" {
			continue
		}
		if is_engine(candidate) {
			return absolute(candidate), s, true
		}
		// A root that the user named and that is not the engine's is an error, not a reason to look elsewhere.
		if s != .Executable {
			return candidate, s, false
		}
	}
	return "", .Executable, false
}

is_engine :: proc(dir: string) -> bool {
	content, _ := filepath.join({dir, ENGINE_CONTENT}, context.temp_allocator)
	return os.is_dir(content)
}

// Project is a project's folder and what the tool builds there (see docs/overview/getting-started.md#a-project). Every
// path is absolute, with forward slashes.
Project :: struct {
	dir:           string,
	settings:      string,
	user_settings: string,
	content:       string,
	// The project's Odin package, which it has when game/ holds a .odin file.
	code:          string,
	has_code:      bool,
	// The game's name, from game.name, or the folder's name.
	name:          string,
	build:         string,
	dev:           string,
	// The game's DLL, which the host runs: the project's own, or the engine's standard.dll.
	game_dll:      string,
	cache:         string,
	release_cache: string,
	release:       string,
	types:         string,
	pdb:           string,
	editor:        string,
}

project_paths :: proc(project_dir: string, engine: Engine, allocator := context.allocator) -> (p: Project) {
	context.allocator = allocator
	dir := slashes(absolute(project_dir))
	join :: proc(parts: ..string) -> string {
		return strings.join(parts, "/")
	}
	p = {
		dir           = dir,
		settings      = join(dir, "project.settings"),
		user_settings = join(dir, "project.user.settings"),
		content       = join(dir, "content"),
		code          = join(dir, "game"),
		build         = join(dir, "build"),
		dev           = join(dir, "build/dev"),
		cache         = join(dir, "build/cache"),
		release_cache = join(dir, "build/release-cache"),
		release       = join(dir, "build/release"),
		types         = join(dir, "build/types/cinnabar.d.luau"),
		pdb           = join(dir, "build/obj/pdb"),
		editor        = join(dir, "build/editor"),
	}
	p.has_code = has_odin(p.code)
	p.game_dll = join(p.dev, "game.dll") if p.has_code else engine.standard
	p.name = file_name(setting(p.settings, NAME_KEY))
	if p.name == "" {
		p.name = filepath.base(dir)
	}
	return
}

// has_odin is whether a folder holds a .odin file.
has_odin :: proc(dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for e in entries {
		if e.type == .Regular && strings.has_suffix(e.name, ".odin") {
			return true
		}
	}
	return false
}

// setting is a key's value in a settings file, its user file's in place of its own, or "".
setting :: proc(path, key: string) -> string {
	user := strings.concatenate({strings.trim_suffix(path, ".settings"), ".user.settings"}, context.temp_allocator)
	for file in ([]string{user, path}) {
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			continue
		}
		if value := format.settings_value(string(data), key); value != "" {
			return strings.clone(value)
		}
	}
	return ""
}

// file_name is a name that Windows takes as a file's: the characters that it refuses are left out, and the dots and
// spaces that it trims at the end too.
file_name :: proc(name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in name {
		switch r {
		case '<', '>', ':', '"', '/', '\\', '|', '?', '*':
			continue
		}
		if r < ' ' {
			continue
		}
		strings.write_rune(&b, r)
	}
	return strings.trim_right(strings.to_string(b), ". ")
}

// find_asset is the source file in a content root whose .meta file has a GUID, or "".
find_asset :: proc(dir: string, guid: format.Guid) -> string {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return ""
	}
	for e in entries {
		if e.type == .Directory {
			if strings.has_prefix(e.name, ".") {
				continue
			}
			if found := find_asset(e.fullpath, guid); found != "" {
				return found
			}
			continue
		}
		if !strings.has_suffix(e.name, ".meta") {
			continue
		}
		data, read_err := os.read_entire_file(e.fullpath, context.temp_allocator)
		if read_err != nil {
			continue
		}
		if g, ok := format.meta_guid(string(data)); ok && g == guid {
			return slashes(strings.clone(strings.trim_suffix(e.fullpath, ".meta")))
		}
	}
	return ""
}

slashes :: proc(path: string) -> string {
	s, _ := strings.replace_all(path, "\\", "/")
	return s
}

absolute :: proc(path: string) -> string {
	if full, err := os.get_absolute_path(path, context.allocator); err == nil {
		return full
	}
	return strings.clone(path)
}

// describe names where an engine root came from, for messages.
describe :: proc(source: Engine_Source) -> string {
	switch source {
	case .Argument:
		return "--engine"
	case .Variable:
		return ENGINE_VARIABLE
	case .User_Settings:
		return fmt.tprintf("%s in project.user.settings", ENGINE_PATH_KEY)
	case .Executable:
		return "the folder that cinnabar.exe was built in"
	}
	return ""
}
