// `cook scenes --cache <dir> --config dev|release --root <name>=<dir>...` cooks every .scene file in the content
// roots into <cache>/<config>/<guid>.blob. See docs/editor.md#scenes.
package cook

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks scenes changes this, which invalidates every cooked scene.
SCENE_COOK_VERSION :: "scenes 1"

// cook_scenes cooks the scenes among the assets whose keys changed. The cooker cannot lay out native components,
// because their types exist only in the game DLL, so it checks only what the file itself says: its syntax, and that
// the scene IDs and script GUIDs that it refers to exist. It parses every scene, also one that is up to date, so its
// warnings and the scripts that it names are known at every cook. It reports every failure, and returns false if any.
cook_scenes :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	scripts := make(map[format.Guid]bool, context.temp_allocator)
	for i in assets_of(assets, .Script) {
		scripts[assets[i].meta.guid] = true
	}
	out_dir := config_dir(options)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		report_error(problems, out_dir, 0, 0, "%v", err)
		return false
	}
	ok := true
	for i in assets_of(assets, .Scene) {
		s := &assets[i]
		settings_ok := check_settings(s^, problems)
		scene, scene_ok := parse_scene(s^, scripts, problems)
		// A scene with errors keeps its old blob, so the running game keeps the last good version.
		if !scene_ok || !settings_ok {
			s.failed = true
			ok = false
			continue
		}
		for e in scene.entities {
			for behaviour in e.behaviours {
				if _, found := slice.linear_search(s.dependencies[:], behaviour.script); !found {
					append(&s.dependencies, behaviour.script)
				}
			}
		}
		key := scene_key(options.config, s^)
		buffer: [32]u8
		output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.meta.guid, &buffer))
		if cooked_key(output, .Scene, format.scene_layout()) == key && !pass.force[s.meta.guid] {
			pass.current[.Scene] += 1
			continue
		}
		if !write_blob(output, format.scene_write(scene, s.meta.guid, key, context.temp_allocator)) {
			s.failed = true
			ok = false
			continue
		}
		pass.cooked[.Scene] += 1
	}
	return ok
}

// scene_key covers what the blob depends on: the cooker, the configuration, the path, the source and the settings.
scene_key :: proc(config: Script_Config, s: Asset_Source) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%v\x00%s\x00%x\x00", SCENE_COOK_VERSION, config, s.name, format.scene_layout()))
	key = hash.fnv64a(s.source, key)
	return hash.fnv64a(transmute([]byte)s.meta_text, key)
}

// parse_scene parses a scene and reports its problems. A reference to a scene ID or a script that does not exist is
// a warning: the loader skips it, and the editor keeps it.
parse_scene :: proc(s: Asset_Source, scripts: map[format.Guid]bool, problems: ^Problems) -> (scene: format.Scene, ok: bool) {
	parsed: []format.Scene_Problem
	scene, parsed, ok = format.scene_parse(string(s.source), context.temp_allocator)
	for p in parsed {
		if p.error {
			report_error(problems, s.path, p.line, 0, "%s", p.message)
		} else {
			report_warning(problems, s.path, p.line, 0, "%s", p.message)
		}
	}
	if !ok {
		return
	}
	ids := make(map[u64]bool, len(scene.entities), context.temp_allocator)
	for e in scene.entities {
		ids[e.id] = true
	}
	check_reference :: proc(s: Asset_Source, ids: map[u64]bool, entity: u64, what: string, id: u64, problems: ^Problems) {
		if id != 0 && !ids[id] {
			report_warning(problems, s.path, 0, 0, "entity %016x: %s refers to %016x, which is not in the scene", entity, what, id)
		}
	}
	for e in scene.entities {
		check_reference(s, ids, e.id, "parent", e.parent, problems)
		for c in e.components {
			for f in c.fields {
				if f.value.kind == .Entity {
					check_reference(s, ids, e.id, fmt.tprintf("%s.%s", c.name, f.name), f.value.entity, problems)
				}
			}
		}
		for b in e.behaviours {
			if !scripts[b.script] {
				buffer: [32]u8
				report_warning(problems, s.path, 0, 0, "entity %016x: no script has the GUID %s", e.id, format.guid_format(b.script, &buffer))
			}
			for f in b.fields {
				if f.value.kind == .Entity {
					check_reference(s, ids, e.id, f.name, f.value.entity, problems)
				}
			}
		}
	}
	return scene, true
}
