// The commands that cook the content roots share their options and one pass: a scan of the roots, and then each kind
// of asset in turn. See docs/content/identity-and-cooking.md#cooking. The daemon's passes scan only what changed (see
// scan.odin).
package cook

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import format "cinnabar:engine/asset/format"

Root :: struct {
	name: string,
	// Absolute, with forward slashes.
	dir:  string,
}

Cook_Options :: struct {
	cache:       string,
	config:      Script_Config,
	roots:       [dynamic]Root,
	// The definition file to type check scripts against, or "" for none.
	definitions: string,
	// The daemon's port for the cook link, or 0 for none.
	link:        int,
	// DXC's absolute path and its version, or "" when shaders cannot cook.
	dxc:         string,
	dxc_version: string,
	// The directories that shader includes resolve in after the including file's own: absolute, with forward slashes.
	includes:    [dynamic]string,
}

// Pass is what one cook did, and what it found, in the temporary allocator.
Pass :: struct {
	ok:         bool,
	// The assets and sub-assets of each kind that the pass cooked, or found up to date. Only settle and count_subassets
	// change them.
	cooked:     [format.Asset_Kind]int,
	current:    [format.Asset_Kind]int,
	// The cache's generation after the pass. It changes only when the pass writes a blob.
	generation: u64,
	// Every asset in the roots, with what the cook learnt of it, and every folder.
	assets:     []Asset_Source,
	folders:    []Folder,
	// The GUIDs that more than one asset has, so that none of them is among the assets.
	shared:     []format.Guid,
	problems:   Problems,
	// Assets to cook also when their blobs are up to date, as a re-import asks.
	force:      map[format.Guid]bool,
	// The shading models that the pass parsed, and the bytecode of each generated material source that it compiled, by
	// its hash.
	shadings:   [dynamic]^Shading_Decl,
	compiled:   map[u64][][]byte,
	progress:   Progress,
	// The daemon's index from the last pass, which the pass carries what nothing changed in from, or nil for a pass that
	// looks at everything (see docs/content/daemon-and-operations.md#saved-index).
	saved:      ^Index,
	// The GUIDs of the assets that the pass looks at, when it has a saved index.
	scope:      map[format.Guid]bool,
	// Every file and directory that the scan saw, which the next index keeps.
	files:      []File_Record,
	// The sources that the pass read, by path: the scan's, and those that asset_source read for another asset.
	read:       [dynamic]string,
	// The project's agent types, which nav_project reads once in a pass, and the navmeshes' tiles that the pass baked or
	// found up to date (see nav_meshes.odin).
	nav:        Maybe(Nav_Project),
	nav_tiles:  [Asset_Result]int,
}

// parse_cook_args reads `--cache <dir> --config dev|release [--definitions <file>] [--dxc <dxc.exe>] [--include <dir>]...
// --root <name>=<dir>...`. --cache is the loose cache itself, where the blobs go, such as build/dev/content, and
// --config is what to cook into it. The daemon always cooks the dev configuration, so it takes no --config, and it
// takes `--link <port>`.
parse_cook_args :: proc(args: []string, daemon := false) -> (options: Cook_Options, ok: bool) {
	options.roots = make([dynamic]Root, context.temp_allocator)
	options.includes = make([dynamic]string, context.temp_allocator)
	config_set := daemon
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) {
			return
		}
		value := args[i + 1]
		switch args[i] {
		case "--cache":
			options.cache = value
		case "--definitions":
			options.definitions = value
		case "--dxc":
			// Starting a process needs the executable's full path on Windows.
			dxc, err := os.get_absolute_path(value, context.temp_allocator)
			if err != nil {
				return
			}
			version, version_ok := dxc_version(dxc)
			if !version_ok {
				return
			}
			options.dxc, options.dxc_version = dxc, version
		case "--include":
			dir, err := os.get_absolute_path(value, context.temp_allocator)
			if err != nil {
				return
			}
			append(&options.includes, forward_slashes(dir))
		case "--link":
			port, port_ok := strconv.parse_int(value)
			if !daemon || !port_ok || port <= 0 || port > 65535 {
				return
			}
			options.link = port
		case "--config":
			if daemon {
				return
			}
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

// cook scans the roots and cooks the assets of the kinds whose keys changed. When it writes a blob, it then writes the
// cache's generation, so a running game swaps the pass's blobs together (see docs/content/blobs-and-loading.md#loading). It
// logs each problem as it finds it, unless log_problems is false. It cooks the assets in force whatever their keys.
// With the daemon's saved index, it scans what changes says changed, and carries what nothing changed in (see
// scan_pass and pass_scope).
cook :: proc(
	options: Cook_Options,
	kinds: Asset_Kinds,
	log_problems := true,
	force: map[format.Guid]bool = nil,
	progress: Progress = {},
	saved: ^Index = nil,
	changes: Watch_Changes = Changed_Everything{},
) -> (
	pass: Pass,
) {
	pass.problems.log = log_problems
	pass.force = force
	pass.progress = progress
	pass.progress.start = time.tick_now()
	pass.saved = saved
	pass.read = make([dynamic]string, context.temp_allocator)
	scanned := scan_pass(options.roots[:], options.includes[:], options.definitions, saved, changes, &pass)
	pass.assets, pass.folders, pass.shared, pass.files = scanned.assets, scanned.folders, scanned.shared, scanned.files
	pass.ok = scanned.ok
	if saved != nil {
		pass_scope(&pass, scanned, saved, options.roots[:], options.includes[:], options.definitions, force)
	}
	// A stage's material instances and prefab are text that its cook generates, which the material and scene passes
	// then cook as they would files, so the stages go first whenever either pass runs.
	if kinds & {.Stage, .Scene, .Prefab, .Shading_Model, .Material, .Material_Instance, .Material_Function} != {} {
		pass.ok = cook_stages(options, &pass) && pass.ok
	}
	if .Script in kinds {
		pass.ok = cook_scripts(options, pass.assets, &pass) && pass.ok
	}
	// A scene's cook expands the prefabs that it instantiates, so one pass cooks both kinds.
	if kinds & {.Scene, .Prefab} != {} {
		pass.ok = cook_scenes(options, pass.assets, &pass) && pass.ok
	}
	if .Shader in kinds {
		pass.ok = cook_shaders(options, pass.assets, &pass) && pass.ok
	}
	if .Texture in kinds {
		pass.ok = cook_textures(options, pass.assets, &pass) && pass.ok
	}
	if .Model in kinds {
		pass.ok = cook_models(options, pass.assets, &pass) && pass.ok
	}
	if .Mesh in kinds {
		pass.ok = cook_mesh_files(options, pass.assets, &pass) && pass.ok
	}
	if kinds & {.Shading_Model, .Material, .Material_Instance, .Material_Function} != {} {
		pass.ok = cook_materials(options, pass.assets, &pass) && pass.ok
	}
	if .Effect in kinds {
		pass.ok = cook_effects(options, pass.assets, &pass) && pass.ok
	}
	if .Animation_Graph in kinds {
		pass.ok = cook_animation_graphs(options, pass.assets, &pass) && pass.ok
	}
	if .Audio in kinds {
		pass.ok = cook_audio(options, pass.assets, &pass) && pass.ok
	}
	if .Font in kinds {
		pass.ok = cook_fonts(options, pass.assets, &pass) && pass.ok
	}
	if .Ui in kinds {
		pass.ok = cook_ui_documents(options, pass.assets, &pass) && pass.ok
	}
	if .Sprite_Sheet in kinds {
		pass.ok = cook_sprite_sheets(options, pass.assets, &pass) && pass.ok
	}
	// A navmesh reads the cooked meshes of its scene's colliders, so it bakes after the meshes, and its GUID is the one
	// that the scene's cook gave it.
	if .Nav_Mesh in kinds {
		pass.ok = cook_nav_meshes(options, &pass) && pass.ok
	}
	written := 0
	for n in pass.cooked {
		written += n
	}
	out_dir := config_dir(options)
	if written == 0 {
		pass.generation = read_generation(out_dir)
		return
	}
	generation, generation_ok := write_generation(out_dir)
	pass.generation = generation
	pass.ok &&= generation_ok
	return
}

// config_dir is the loose cache, where the blobs and the generation go: --cache, which names one configuration's.
config_dir :: proc(options: Cook_Options) -> string {
	return options.cache
}

// read_generation reads the counter in a configuration directory's generation file. It is 0 if there is none.
read_generation :: proc(dir: string) -> u64 {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), context.temp_allocator)
	if err != nil {
		return 0
	}
	return strconv.parse_u64(strings.trim_space(string(data))) or_else 0
}

// write_generation adds one to the counter in a configuration directory's generation file.
write_generation :: proc(dir: string) -> (generation: u64, ok: bool) {
	generation = read_generation(dir) + 1
	text := fmt.tprintf("%d\n", generation)
	return generation, write_blob(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), transmute([]byte)text)
}
