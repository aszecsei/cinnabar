// tools/cook compiles source assets. See docs/content/identity-and-cooking.md#cooking.
//
// `cook scripts` cooks scripts (see scripts.odin), `cook scenes` cooks scenes (see scenes.odin), `cook shaders` cooks
// shaders (see shaders.odin), `cook models` cooks glTF models (see meshes.odin), `cook meshes` cooks mesh files (see
// mesh_files.odin), `cook stages` cooks USD stages (see stages.odin), and `cook daemon` cooks every kind whenever the
// content changes (see daemon.odin). `cook stage-report` measures stages against the renderer's limits.
package cook

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

USAGE :: `usage: cook scripts --cache <dir> --config dev|release [--definitions <file>] --root <name>=<dir> [--root <name>=<dir>]...
       cook scenes --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook materials --cache <dir> --config dev|release --dxc <dxc.exe> [--include <dir>]... --root <name>=<dir> [--root <name>=<dir>]...
       cook models --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook meshes --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook textures --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook shaders --cache <dir> --config dev|release --dxc <dxc.exe> [--include <dir>]... --root <name>=<dir> [--root <name>=<dir>]...
       cook effects --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook stages --cache <dir> --config dev|release --root <name>=<dir> [--root <name>=<dir>]...
       cook stage-report <stage>...
       cook daemon --cache <dir> [--definitions <file>] [--dxc <dxc.exe>] [--include <dir>]... [--link <port>] --root <name>=<dir> [--root <name>=<dir>]...
       cook --emit-link-schema <file>`

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	command := len(os.args) > 1 ? os.args[1] : ""
	ok, parsed: bool
	options: Cook_Options
	switch command {
	case "scripts":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Script)
		}
	case "scenes":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Scene)
		}
	case "materials":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = options.dxc != "" && cook_batch(options, .Material)
			if options.dxc == "" {
				log.error("cook: materials need --dxc")
			}
		}
	case "models":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Model)
		}
	case "meshes":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Mesh)
		}
	case "textures":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Texture)
		}
	case "effects":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Effect)
		}
	case "stages":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = cook_batch(options, .Stage)
		}
	case "stage-report":
		if parsed = len(os.args) > 2; parsed {
			ok = stage_report(os.args[2:])
		}
	case "shaders":
		if options, parsed = parse_cook_args(os.args[2:]); parsed {
			ok = options.dxc != "" && cook_batch(options, .Shader)
			if options.dxc == "" {
				log.error("cook: shaders need --dxc")
			}
		}
	case "daemon":
		if options, parsed = parse_cook_args(os.args[2:], daemon = true); parsed {
			ok = run_daemon(options)
		}
	case "--emit-link-schema":
		// The editor's source generator reads the cook link's schema (see docs/content/daemon-and-operations.md#cook-link).
		if parsed = len(os.args) == 3; parsed {
			ok = write_schema(os.args[2])
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

write_schema :: proc(path: string) -> bool {
	if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", path, err)
		return false
	}
	if err := os.write_entire_file(path, transmute([]byte)cook_link.schema(context.temp_allocator)); err != nil {
		log.errorf("cook: %s: %v", path, err)
		return false
	}
	log.infof("cook: wrote the cook link's schema to %s", path)
	return true
}

// cook_batch cooks one kind of asset once, while it holds the cache's lock. While the cook daemon runs, it keeps the
// dev configuration up to date itself, so a dev cook leaves it to the daemon, and `just build` works while the editor
// is open.
cook_batch :: proc(options: Cook_Options, kind: format.Asset_Kind) -> bool {
	lock, locked := lock_cache(options.cache)
	switch locked {
	case .Locked:
	case .Held:
		if options.config == .Dev {
			log.infof("cook: the cook daemon is running, and keeps %s up to date", config_dir(options))
			return true
		}
		log.errorf("cook: another cook is using %s. Stop the cook daemon (`just watch` or the editor) and cook again.", options.cache)
		return false
	case .Failed:
		return false
	}
	defer unlock_cache(&lock)
	pass := cook(options, {kind})
	log.infof("cook: %d %s cooked, %d up to date", pass.cooked[kind], kind_plural(kind), pass.current[kind])
	if kind == .Scene {
		log.infof("cook: %d %s cooked, %d up to date", pass.cooked[.Prefab], kind_plural(.Prefab), pass.current[.Prefab])
	}
	if kind == .Stage {
		for sub in ([]format.Asset_Kind{.Mesh, .Texture}) {
			log.infof("cook: %d %s of stages cooked, %d up to date", pass.cooked[sub], kind_plural(sub), pass.current[sub])
		}
	}
	return pass.ok
}

// kind_plural names a kind of asset in messages, such as "scripts".
kind_plural :: proc(kind: format.Asset_Kind) -> string {
	switch kind {
	case .None:
		return "assets"
	case .Script:
		return "scripts"
	case .Scene:
		return "scenes"
	case .Shader:
		return "shaders"
	case .Texture:
		return "textures"
	case .Model:
		return "models"
	case .Mesh:
		return "meshes"
	case .Shading_Model:
		return "shading models"
	case .Material:
		return "materials"
	case .Material_Instance:
		return "material instances"
	case .Material_Function:
		return "material functions"
	case .Prefab:
		return "prefabs"
	case .Effect:
		return "effects"
	case .Stage:
		return "stages"
	}
	return "assets"
}
