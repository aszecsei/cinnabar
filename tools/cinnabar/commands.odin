package cinnabar

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import format "cinnabar:engine/asset/format"

// The GPU backend that the engine's builds link, as the justfile's gpu_backend.
GPU_BACKEND :: "d3d12"
// The runtime libraries that a release needs beside its executable, from the engine's build/dev: the Agility SDK's
// core, without the debug layer's library, and FSR's (see docs/overview/building-and-running.md#build-layout).
RELEASE_LIBRARIES :: [?]string{"D3D12/D3D12Core.dll", "amd_fidelityfx_loader_dx12.dll", "amd_fidelityfx_upscaler_dx12.dll", "amd_fidelityfx_LICENSE.txt"}

// game_dll_command builds a project's game package into its development DLL, which the host hot-reloads. Each build
// writes a PDB of its own, because a running host's debugger keeps the last one open.
game_dll_command :: proc(e: Engine, p: Project, stamp: i64) -> []string {
	return slice_of(
		"odin",
		"build",
		p.code,
		fmt.aprintf("-collection:cinnabar=%s", e.lib),
		fmt.aprintf("-collection:gpu_backend=%s/core/gpu/%s", e.lib, GPU_BACKEND),
		fmt.aprintf("-collection:physics_backend=%s/core/physics/plugin", e.lib),
		"-define:LUAU_SHARED=true",
		"-define:LUAU_DIRECT_ACCESS=false",
		"-build-mode:dll",
		fmt.aprintf("-out:%s", p.game_dll),
		fmt.aprintf("-pdb-name:%s/game_%d.pdb", p.pdb, stamp),
		"-debug",
	)
}

// release_command builds a project's release executable: the engine's runtime entry point with the project's game
// package, statically linked, as a Windows application (see docs/world/game-package.md#releases).
release_command :: proc(e: Engine, p: Project, exe: string) -> []string {
	return slice_of(
		"odin",
		"build",
		fmt.aprintf("%s/engine/game/runtime", e.lib),
		fmt.aprintf("-collection:cinnabar=%s", e.lib),
		fmt.aprintf("-collection:gpu_backend=%s/core/gpu/%s", e.lib, GPU_BACKEND),
		fmt.aprintf("-collection:physics_backend=%s/core/physics/jolt", e.lib),
		fmt.aprintf("-collection:project=%s", p.dir),
		"-define:LUAU_DIRECT_ACCESS=false",
		"-define:DEBUG_DRAW=false",
		"-define:PROFILE=false",
		"-define:BUNDLES=true",
		"-subsystem:windows",
		fmt.aprintf("-out:%s", exe),
		"-o:speed",
	)
}

// cook_command cooks every kind of the project's content and the engine's into a loose cache (see
// docs/content/identity-and-cooking.md#cooking). prune deletes the blobs of assets that left the content.
cook_command :: proc(e: Engine, p: Project, config, cache: string, prune: bool) -> []string {
	command := make([dynamic]string)
	append(&command, e.cook, "all", "--cache", cache, "--config", config, "--definitions", p.types, "--dxc", e.dxc)
	for include in e.includes {
		append(&command, "--include", include)
	}
	append(&command, "--root", fmt.aprintf("game=%s", p.content), "--root", fmt.aprintf("engine=%s", e.content))
	if prune {
		append(&command, "--prune")
	}
	return command[:]
}

// host_command runs the game in the development host, with the project's cache and settings.
host_command :: proc(e: Engine, p: Project) -> []string {
	return slice_of(e.host, p.game_dll, "--content", p.cache, "--project", p.settings)
}

// editor_command opens the project in the editor, which starts the host and the cook daemon itself (see
// docs/editor/processes-and-projects.md#processes).
editor_command :: proc(e: Engine, p: Project, scene: string) -> []string {
	command := make([dynamic]string)
	append(&command, e.editor, "--host", e.host, "--game", p.game_dll)
	if scene != "" {
		append(&command, "--scene", scene)
	}
	append(&command, "--cook", e.cook, "--cache", p.cache, "--definitions", p.types, "--dxc", e.dxc)
	for include in e.includes {
		append(&command, "--include", include)
	}
	append(&command, "--root", fmt.aprintf("game=%s", p.content), "--root", fmt.aprintf("engine=%s", e.content))
	append(&command, "--project", p.settings)
	return command[:]
}

slice_of :: proc(args: ..string) -> []string {
	s := make([]string, len(args))
	copy(s, args)
	return s
}

// build_project builds what the project runs in development: its game DLL when it has Odin, the scripts' type
// definitions from that DLL, and its content and the engine's in the project's cache.
build_project :: proc(e: Engine, p: Project) -> bool {
	if !make_dirs(p.dev, p.pdb, filepath.dir(p.types)) {
		return false
	}
	if p.has_code && !run(..game_dll_command(e, p, time.now()._nsec)) {
		log.errorf("cinnabar: the project's game/ did not build. Is Odin on the PATH? (see docs/overview/getting-started.md#prerequisites)")
		return false
	}
	return run(e.host, p.game_dll, "--emit-script-types", p.types) && run(..cook_command(e, p, "dev", p.cache, false))
}

run_project :: proc(e: Engine, p: Project) -> bool {
	return build_project(e, p) && run(..host_command(e, p))
}

edit_project :: proc(e: Engine, p: Project) -> bool {
	if !build_project(e, p) {
		return false
	}
	scene := ""
	if guid, ok := format.guid_parse(setting(p.settings, MAIN_SCENE_KEY)); ok {
		scene = find_asset(p.content, guid)
	}
	return run(..editor_command(e, p, scene))
}

// export_project writes a release of the project into out: its executable under the game's name, its content's
// bundles, its settings without the user's, and the runtime libraries, so the folder runs anywhere as it is.
export_project :: proc(e: Engine, p: Project, out: string) -> bool {
	if !make_dirs(p.dev, p.pdb, filepath.dir(p.types), out) {
		return false
	}
	// The release cook type checks the scripts against the game's bindings, which the development DLL writes.
	if p.has_code && !run(..game_dll_command(e, p, time.now()._nsec)) {
		return false
	}
	if !run(e.host, p.game_dll, "--emit-script-types", p.types) {
		return false
	}
	if !run(..cook_command(e, p, "release", p.release_cache, true)) {
		return false
	}
	// A release folder holds one game: the executables and bundles of an earlier export go.
	if !clear_release(out) {
		return false
	}
	content := strings.concatenate({out, "/content"}, context.temp_allocator)
	if !run(e.cook, "package", "--cache", p.release_cache, "--out", content, "--project", p.settings) {
		return false
	}
	if !copy_into(p.settings, out, "project.settings") {
		return false
	}
	for library in RELEASE_LIBRARIES {
		if !copy_into(strings.concatenate({e.dev, "/", library}, context.temp_allocator), out, library) {
			return false
		}
	}
	exe := strings.concatenate({out, "/", p.name, ".exe"}, context.temp_allocator)
	if p.has_code {
		if !run(..release_command(e, p, exe)) {
			return false
		}
	} else if !copy_into(e.runtime, out, strings.concatenate({p.name, ".exe"}, context.temp_allocator)) {
		log.errorf("cinnabar: build the engine's runtime.exe with `just engine` in %s", e.root)
		return false
	}
	if icon := setting(p.settings, ICON_KEY); icon != "" {
		icon_path, _ := filepath.join({p.dir, icon}, context.temp_allocator)
		if !set_icon(exe, icon_path) {
			return false
		}
	}
	log.infof("cinnabar: exported %s to %s", p.name, out)
	return true
}

// clear_release deletes what an export writes into a folder: executables and the bundles' folder.
clear_release :: proc(out: string) -> bool {
	entries, err := os.read_all_directory_by_path(out, context.temp_allocator)
	if err != nil {
		log.errorf("cinnabar: %s: %v", out, err)
		return false
	}
	for e in entries {
		switch {
		case e.type == .Regular && strings.has_suffix(e.name, ".exe"):
			if remove_err := os.remove(e.fullpath); remove_err != nil {
				log.errorf("cinnabar: cannot delete %s: %v. Is the game running?", e.fullpath, remove_err)
				return false
			}
		case e.type == .Directory && e.name == "content":
			if remove_err := os.remove_all(e.fullpath); remove_err != nil {
				log.errorf("cinnabar: cannot delete %s: %v", e.fullpath, remove_err)
				return false
			}
		}
	}
	return true
}

// copy_into copies a file to a path in a folder, making the folders on the way.
copy_into :: proc(source, dir, name: string) -> bool {
	target := strings.concatenate({dir, "/", name}, context.temp_allocator)
	if err := os.make_directory_all(filepath.dir(target)); err != nil && err != .Exist {
		log.errorf("cinnabar: %s: %v", target, err)
		return false
	}
	if err := os.copy_file(target, source); err != nil {
		log.errorf("cinnabar: cannot copy %s to %s: %v", source, target, err)
		return false
	}
	return true
}

make_dirs :: proc(dirs: ..string) -> bool {
	for dir in dirs {
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			log.errorf("cinnabar: %s: %v", dir, err)
			return false
		}
	}
	return true
}
