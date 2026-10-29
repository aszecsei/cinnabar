// `cook scenes --cache <dir> --config dev|release --root <name>=<dir>...` cooks every .scene and .prefab file in the
// content roots into <cache>/<config>/<guid>.blob. See docs/editor/document-and-scenes.md#scenes and
// docs/editor/prefabs.md#cooking.
package cook

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks scenes changes this, which invalidates every cooked scene.
SCENE_COOK_VERSION :: "scenes 2"

// cook_scenes cooks the prefabs and the scenes among the assets whose keys changed. The cooker cannot lay out native
// components, because their types exist only in the game DLL, so it checks only what the file itself says: its
// syntax, its prefabs, and that the scene IDs and script GUIDs that it refers to exist. It parses every prefab first,
// since a scene's cook expands the prefabs that it instantiates, and writes both kinds flat. It parses every scene,
// also one that is up to date, so its warnings and the assets that it names are known at every cook. It reports every
// failure, and returns false if any.
cook_scenes :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	scripts := make(map[format.Guid]bool, context.temp_allocator)
	for i in assets_of(assets, .Script) {
		scripts[assets[i].meta.guid] = true
	}
	// Every asset that a field can name, with the sub-assets in the .meta files, which the scan has read.
	known := make(map[format.Guid]format.Asset_Kind, len(assets), context.temp_allocator)
	for a in assets {
		known[a.meta.guid] = a.kind
		for s in a.meta.subassets {
			known[s.guid] = format.subasset_kind_of(s.kind)
		}
	}
	out_dir := config_dir(options)
	if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
		report_error(problems, out_dir, 0, 0, "%v", err)
		return false
	}
	// Each prefab that parses, by GUID, for the expansions, and the source of every prefab, for the scenes' keys.
	prefabs := make(map[format.Guid]format.Scene, context.temp_allocator)
	sources := make(map[format.Guid][]byte, context.temp_allocator)
	parsed := make(map[int]format.Scene, context.temp_allocator)
	for i in assets_of(assets, .Prefab) {
		s := &assets[i]
		sources[s.meta.guid] = s.source
		if scene, ok := parse_scene(s^, problems); ok {
			parsed[i] = scene
			prefabs[s.meta.guid] = scene
		}
	}
	resolver := format.Prefab_Resolver {
		data = &prefabs,
		find = proc(data: rawptr, prefab: format.Guid) -> (format.Scene, bool) {
			scene, found := (^map[format.Guid]format.Scene)(data)[prefab]
			return scene, found
		},
	}
	ok := true
	for kind in ([]format.Asset_Kind{.Prefab, .Scene}) {
		for i in assets_of(assets, kind) {
			s := &assets[i]
			settings_ok := check_settings(s^, problems)
			scene, scene_ok := parsed[i]
			if kind == .Scene {
				scene, scene_ok = parse_scene(s^, problems)
			}
			flat: format.Scene
			if scene_ok {
				flat, scene_ok = check_scene(s^, kind, scene, resolver, scripts, known, problems)
			}
			// A scene or a prefab with errors keeps its old blob, so the running game keeps the last good version.
			if !scene_ok || !settings_ok {
				s.failed = true
				ok = false
				continue
			}
			for e in scene.entities {
				dependencies := make([dynamic]format.Guid, context.temp_allocator)
				if e.prefab != {} {
					append(&dependencies, e.prefab)
				}
				for b in e.behaviours {
					append(&dependencies, b.script)
				}
				for d in dependencies {
					if _, found := slice.linear_search(s.dependencies[:], d); !found {
						append(&s.dependencies, d)
					}
				}
			}
			key := scene_key(options.config, s^, scene, prefabs, sources)
			buffer: [32]u8
			output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.meta.guid, &buffer))
			if cooked_key(output, kind, format.scene_layout()) == key && !pass.force[s.meta.guid] {
				pass.current[kind] += 1
				continue
			}
			if !write_blob(output, format.scene_write(flat, s.meta.guid, key, kind, context.temp_allocator)) {
				s.failed = true
				ok = false
				continue
			}
			pass.cooked[kind] += 1
		}
	}
	return ok
}

// scene_key covers what the blob depends on: the cooker, the configuration, the path, the source, the settings, and
// the source of every prefab that the scene instantiates, through the prefabs inside them, or that it is missing.
scene_key :: proc(config: Script_Config, s: Asset_Source, scene: format.Scene, prefabs: map[format.Guid]format.Scene, sources: map[format.Guid][]byte) -> u64 {
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%v\x00%s\x00%x\x00", SCENE_COOK_VERSION, config, s.name, format.scene_layout()))
	key = hash.fnv64a(s.source, key)
	key = hash.fnv64a(transmute([]byte)s.meta_text, key)
	used := make(map[format.Guid]bool, context.temp_allocator)
	pending := make([dynamic]format.Scene, context.temp_allocator)
	append(&pending, scene)
	for len(pending) > 0 {
		for e in pop(&pending).entities {
			if e.prefab == {} || used[e.prefab] {
				continue
			}
			used[e.prefab] = true
			if inner, found := prefabs[e.prefab]; found {
				append(&pending, inner)
			}
		}
	}
	guids := make([dynamic]format.Guid, 0, len(used), context.temp_allocator)
	for g in used {
		append(&guids, g)
	}
	slice.sort_by(guids[:], proc(a, b: format.Guid) -> bool {
		for i in 0 ..< len(a) {
			if a[i] != b[i] {
				return a[i] < b[i]
			}
		}
		return false
	})
	for &g in guids {
		key = hash.fnv64a(g[:], key)
		if source, found := sources[g]; found {
			key = hash.fnv64a(source, key)
		} else {
			key = hash.fnv64a(transmute([]byte)string("\x00missing"), key)
		}
	}
	return key
}

// parse_scene parses a scene or a prefab and reports the problems of its text.
parse_scene :: proc(s: Asset_Source, problems: ^Problems) -> (scene: format.Scene, ok: bool) {
	parsed: []format.Scene_Problem
	scene, parsed, ok = format.scene_parse(string(s.source), context.temp_allocator)
	for p in parsed {
		if p.error {
			report_error(problems, s.path, p.line, 0, "%s", p.message)
		} else {
			report_warning(problems, s.path, p.line, 0, "%s", p.message)
		}
	}
	return
}

// check_scene expands a parsed scene or prefab and reports its problems. A prefab has one root. An instance of an
// asset that is not a prefab is an error, as are the expansion's errors. A reference to a scene ID, a script or an
// asset that does not exist is a warning: the loader skips it, and the editor keeps it. The cooker cannot check an
// asset's kind, because field types exist only in the game DLL.
check_scene :: proc(s: Asset_Source, kind: format.Asset_Kind, scene: format.Scene, resolver: format.Prefab_Resolver, scripts: map[format.Guid]bool, known: map[format.Guid]format.Asset_Kind, problems: ^Problems) -> (flat: format.Scene, ok: bool) {
	ok = true
	if kind == .Prefab {
		if _, roots := format.prefab_root(scene); roots != 1 {
			report_error(problems, s.path, 0, 0, "a prefab has one root, an entity without a parent, not %d", roots)
			ok = false
		}
	}
	for e in scene.entities {
		if e.prefab == {} {
			continue
		}
		if k, found := known[e.prefab]; found && k != .Prefab {
			buffer: [32]u8
			report_error(problems, s.path, 0, 0, "entity %016x: the asset %s is not a prefab", e.id, format.guid_format(e.prefab, &buffer))
			ok = false
		}
	}
	if !ok {
		return
	}
	expanded: []format.Scene_Problem
	flat, expanded, ok = format.scene_expand(scene, resolver, kind == .Prefab ? s.meta.guid : {}, context.temp_allocator)
	for p in expanded {
		if p.error {
			report_error(problems, s.path, 0, 0, "%s", p.message)
		} else {
			report_warning(problems, s.path, 0, 0, "%s", p.message)
		}
	}
	if !ok {
		return
	}
	ids := make(map[u64]bool, len(flat.entities), context.temp_allocator)
	for e in flat.entities {
		ids[e.id] = true
	}
	check_reference :: proc(s: Asset_Source, ids: map[u64]bool, entity: u64, what: string, id: u64, problems: ^Problems) {
		if id != 0 && !ids[id] {
			report_warning(problems, s.path, 0, 0, "entity %016x: %s refers to %016x, which is not in the scene", entity, what, id)
		}
	}
	for e in flat.entities {
		check_reference(s, ids, e.id, "parent", e.parent, problems)
		for c in e.components {
			for f in c.fields {
				if f.value.kind == .Entity {
					check_reference(s, ids, e.id, fmt.tprintf("%s.%s", c.name, f.name), f.value.entity, problems)
				}
				if f.value.kind == .Asset && f.value.asset != {} && f.value.asset not_in known {
					buffer: [32]u8
					report_warning(problems, s.path, 0, 0, "entity %016x: %s.%s names the asset %s, which is not in the content", e.id, c.name, f.name, format.guid_format(f.value.asset, &buffer))
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
	return flat, true
}
