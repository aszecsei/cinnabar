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
SCENE_COOK_VERSION :: "scenes 5"

// cook_scenes cooks the prefabs and the scenes among the assets whose keys changed. The cooker cannot lay out native
// components, because their types exist only in the game DLL, so it checks only what the file itself says: its
// syntax, its prefabs, and that the scene IDs and script GUIDs that it refers to exist. It parses every prefab that it
// looks at first, since a scene's cook expands the prefabs that it instantiates, and writes both kinds flat. It parses
// every scene that it looks at, also one that is up to date, so its warnings and the assets that it names are known.
// A carried prefab parses only when a scene that it looks at instantiates it. It reports every failure, and returns
// false if any.
cook_scenes :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	checked := carry_kind(pass, {.Scene, .Prefab})
	if len(checked) == 0 {
		return true
	}
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
	if !make_output_dir(pass, out_dir, {.Scene, .Prefab}) {
		return false
	}
	prefabs := Scene_Prefabs {
		pass   = pass,
		parsed = make(map[format.Guid]Maybe(format.Scene), context.temp_allocator),
		index  = make(map[format.Guid]int, context.temp_allocator),
	}
	for i in assets_of(assets, .Prefab) {
		prefabs.index[assets[i].meta.guid] = i
	}
	sublevels := project_sublevels(options, pass)
	// The prefabs that the pass looks at parse with their problems.
	parsed := make(map[int]format.Scene, context.temp_allocator)
	for i in checked {
		s := &assets[i]
		if s.kind != .Prefab {
			continue
		}
		asset_source(pass, i)
		scene, ok := parse_scene(s^, problems, sublevels)
		if ok {
			drop_scene_references(scene, s, problems)
		}
		prefabs.parsed[s.meta.guid] = scene if ok else nil
		if ok {
			parsed[i] = scene
		}
	}
	resolver := format.Prefab_Resolver {
		data = &prefabs,
		find = proc(data: rawptr, prefab: format.Guid) -> (format.Scene, bool) {
			return scene_prefab((^Scene_Prefabs)(data), prefab)
		},
	}
	ok := true
	for kind in ([]format.Asset_Kind{.Prefab, .Scene}) {
		of_kind := make([dynamic]int, context.temp_allocator)
		for i in checked {
			if assets[i].kind == kind {
				append(&of_kind, i)
			}
		}
		step_begin(pass, kind, "", len(of_kind))
		for i in of_kind {
			defer step_advance(pass)
			s := &assets[i]
			settings_ok := check_settings(s^, problems)
			scene, scene_ok := parsed[i]
			if kind == .Scene {
				asset_source(pass, i)
				scene, scene_ok = parse_scene(s^, problems, sublevels)
			}
			flat: format.Scene
			if scene_ok {
				flat, scene_ok = check_scene(s^, kind, scene, resolver, scripts, known, problems)
			}
			// A scene or a prefab with errors keeps its old blob, so the running game keeps the last good version.
			if !scene_ok || !settings_ok {
				settle(pass, i, .Failed)
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
			for e in flat.entities {
				for c in e.components {
					for f in c.fields {
						if f.value.kind == .Asset &&
						   f.value.asset != {} &&
						   !slice.contains(s.visual[:], f.value.asset) {
							append(&s.visual, f.value.asset)
						}
					}
				}
			}
			// A scene's navmeshes and sublevels are its sub-assets, which its blob lists (see nav_meshes.odin). A stage's
			// generated scene has no .meta file to keep their GUIDs in, so it neither splits nor bakes, and a prefab
			// does neither.
			owns_subassets := kind == .Scene && s.owner == {}
			parts := scene_parts(flat, owns_subassets)
			navs: []format.Scene_Nav_Mesh
			sublevels: []format.Scene_Sublevel
			if owns_subassets {
				subassets_ok: bool
				if navs, sublevels, subassets_ok = scene_subassets(options, pass, i, flat, parts);
				   !subassets_ok {
					settle(pass, i, .Failed)
					ok = false
					continue
				}
			}
			// The base keeps the scene's GUID, and each sublevel's blob has its own.
			guids := make([]format.Guid, len(parts), context.temp_allocator)
			guids[0] = s.meta.guid
			for l, j in sublevels {
				guids[j + 1] = l.guid
			}
			key := scene_key(options.config, s^, scene, &prefabs, navs, sublevels)
			current := !pass.force[s.meta.guid]
			for g in guids {
				current &&=
					cooked_key(scene_blob_path(out_dir, g), kind, format.scene_layout()) == key
			}
			if current {
				settle(pass, i, .Current)
				count_subassets(pass, .Scene, .Current, len(sublevels))
				continue
			}
			split_scene_references(parts, guids)
			blobs := make([][]byte, len(parts), context.temp_allocator)
			for p, j in parts {
				part_navs := make([dynamic]format.Scene_Nav_Mesh, context.temp_allocator)
				for n in navs {
					if scene_part_of(parts, n.entity) == j {
						append(&part_navs, n)
					}
				}
				blobs[j] = format.scene_write(
					{entities = p.entities[:]},
					guids[j],
					key,
					kind,
					part_navs[:],
					sublevels if j == 0 else nil,
					context.temp_allocator,
				)
			}
			if owns_subassets {
				remove_unused_sublevels(out_dir, s^, sublevels, problems)
			}
			written := true
			for b, j in blobs {
				if !write_blob(scene_blob_path(out_dir, guids[j]), b) {
					written = false
					break
				}
			}
			if !written {
				settle(pass, i, .Failed)
				ok = false
				continue
			}
			count_subassets(pass, .Scene, .Cooked, len(sublevels))
			settle(pass, i, .Cooked)
		}
	}
	return ok
}

// Scene_Prefabs gives the scenes' cook the prefabs, each parsed once. A carried prefab parses when a scene first
// instantiates it, and its problems are not reported again, as the pass carries them.
@(private = "file")
Scene_Prefabs :: struct {
	pass:   ^Pass,
	// By GUID, nil for one that did not parse.
	parsed: map[format.Guid]Maybe(format.Scene),
	// Every prefab's asset, by GUID.
	index:  map[format.Guid]int,
}

@(private = "file")
scene_prefab :: proc(p: ^Scene_Prefabs, guid: format.Guid) -> (format.Scene, bool) {
	if known, found := p.parsed[guid]; found {
		return known.?
	}
	i, is_prefab := p.index[guid]
	if !is_prefab {
		return {}, false
	}
	asset_source(p.pass, i)
	carried: Problems
	scene, ok := parse_scene(p.pass.assets[i], &carried)
	if ok {
		drop_scene_references(scene, nil, nil)
	}
	p.parsed[guid] = scene if ok else nil
	return scene, ok
}

// scene_key covers what the blobs depend on: the cooker, the configuration, the path, the source, the GUID, the
// settings, the navmeshes and the sublevels that the base lists, and the source of every prefab that the scene
// instantiates, through the prefabs inside them, or that it is missing. The source covers which part each entity is in.
// The sub-asset lines of the .meta file are not in it, because the cooker writes them: the GUIDs of the navmeshes and
// the sublevels are, through the lists.
@(private = "file")
scene_key :: proc(
	config: Script_Config,
	s: Asset_Source,
	scene: format.Scene,
	prefabs: ^Scene_Prefabs,
	navs: []format.Scene_Nav_Mesh,
	sublevels: []format.Scene_Sublevel,
) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%v\x00%s\x00%x\x00",
			SCENE_COOK_VERSION,
			config,
			s.name,
			format.scene_layout(),
		),
	)
	key = hash.fnv64a(source_of(s), key)
	guid := s.meta.guid
	key = hash.fnv64a(guid[:], key)
	for setting in s.meta.settings {
		key = hash.fnv64a(
			transmute([]byte)fmt.tprintf("%s=%s\x00", setting.key, setting.value),
			key,
		)
	}
	for &n in navs {
		key = hash.fnv64a(transmute([]byte)fmt.tprintf("%x\x00%s\x00", n.entity, n.agent), key)
		key = hash.fnv64a(n.guid[:], key)
	}
	for &l in sublevels {
		key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00", l.name), key)
		key = hash.fnv64a(l.guid[:], key)
	}
	used := make(map[format.Guid]bool, context.temp_allocator)
	pending := make([dynamic]format.Scene, context.temp_allocator)
	append(&pending, scene)
	for len(pending) > 0 {
		for e in pop(&pending).entities {
			if e.prefab == {} || used[e.prefab] {
				continue
			}
			used[e.prefab] = true
			if inner, found := scene_prefab(prefabs, e.prefab); found {
				append(&pending, inner)
			}
		}
	}
	guids := make([dynamic]format.Guid, 0, len(used), context.temp_allocator)
	for g in used {
		append(&guids, g)
	}
	slice.sort_by(guids[:], format.guid_less)
	for &g in guids {
		key = hash.fnv64a(g[:], key)
		if i, found := prefabs.index[g]; found {
			key = hash.fnv64a(asset_source(prefabs.pass, i), key)
		} else {
			key = hash.fnv64a(transmute([]byte)string("\x00missing"), key)
		}
	}
	return key
}

// scene_blob_path is the path of the blob of a scene, or of a sublevel of one, in the configuration's directory.
@(private = "file")
scene_blob_path :: proc(out_dir: string, guid: format.Guid) -> string {
	buffer: [32]u8
	return fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
}

// Scene_Part is the entities of a scene that one blob holds: its base, whose name is "", or one of its sublevels.
Scene_Part :: struct {
	name:     string,
	entities: [dynamic]format.Scene_Entity,
}

// scene_parts splits a flat scene by the sublevels of its entities: the base first, which may be empty, then each
// sublevel by name. Each part keeps the entities in the scene's order, with their scene IDs. Without split, the scene is
// one part, its base.
scene_parts :: proc(flat: format.Scene, split: bool) -> []Scene_Part {
	names := make([dynamic]string, context.temp_allocator)
	if split {
		for e in flat.entities {
			if e.sublevel != "" && !slice.contains(names[:], e.sublevel) {
				append(&names, e.sublevel)
			}
		}
		slice.sort(names[:])
	}
	parts := make([]Scene_Part, len(names) + 1, context.temp_allocator)
	for &p, j in parts {
		p.name = j == 0 ? "" : names[j - 1]
		p.entities = make([dynamic]format.Scene_Entity, context.temp_allocator)
	}
	for e in flat.entities {
		j := 0
		if split && e.sublevel != "" {
			j, _ = slice.linear_search(names[:], e.sublevel)
			j += 1
		}
		append(&parts[j].entities, e)
	}
	return parts
}

// scene_part_of is the part that has the entity of a scene ID, or -1.
@(private = "file")
scene_part_of :: proc(parts: []Scene_Part, id: u64) -> int {
	for p, j in parts {
		for e in p.entities {
			if e.id == id {
				return j
			}
		}
	}
	return -1
}

// scene_subassets gives a scene's navmeshes and sublevels their GUIDs, which its .meta file keeps, in one call, so
// that neither's lines are taken for gone. It returns what the base's blob lists. It fails only when the .meta file
// cannot be written.
@(private = "file")
scene_subassets :: proc(
	options: Cook_Options,
	pass: ^Pass,
	index: int,
	flat: format.Scene,
	parts: []Scene_Part,
) -> (
	navs: []format.Scene_Nav_Mesh,
	sublevels: []format.Scene_Sublevel,
	ok: bool,
) {
	a := &pass.assets[index]
	nav := scene_nav_meshes(options, pass, index, flat)
	wanted := make(
		[dynamic]Subasset,
		0,
		len(nav.subassets) + len(parts) - 1,
		context.temp_allocator,
	)
	append(&wanted, ..nav.subassets)
	for p in parts[1:] {
		append(&wanted, Subasset{kind = .Scene, name = p.name})
	}
	if !assign_subassets(
		options.roots[a.root].dir,
		a,
		wanted[:],
		pass.force[a.meta.guid],
		&pass.problems,
	) {
		return nil, nil, false
	}
	navs = nav.navs
	for &n, j in navs {
		n.guid, _ = nav_mesh_guid(a^, nav.subassets[j].name)
	}
	sublevels = make([]format.Scene_Sublevel, len(parts) - 1, context.temp_allocator)
	for p, j in parts[1:] {
		sublevels[j].name = p.name
		for sub in a.subassets {
			if sub.kind == .Scene && sub.name == p.name {
				sublevels[j].guid = sub.guid
			}
		}
	}
	return navs, sublevels, true
}

// split_scene_references makes a reference from one part of a scene to an entity of another a reference to that part's
// GUID, which binds and unbinds as the part loads and unloads, and one to the part's own GUID local. guids are the
// parts' GUIDs, the scene's own first. A reference to an entity that no part has stays as it is. It changes copies of
// the entities' components, behaviours and fields, which a prefab's expansion can share.
split_scene_references :: proc(parts: []Scene_Part, guids: []format.Guid) {
	part_of := make(map[u64]int, context.temp_allocator)
	for p, j in parts {
		for e in p.entities {
			part_of[e.id] = j
		}
	}
	split :: proc(
		original: []format.Scene_Field,
		part: int,
		part_of: map[u64]int,
		guids: []format.Guid,
	) -> []format.Scene_Field {
		fields := slice.clone(original, context.temp_allocator)
		for &f in fields {
			if f.value.kind != .Entity || f.value.entity == 0 {
				continue
			}
			if f.value.scene != {} && !slice.contains(guids, f.value.scene) {
				continue
			}
			if target, found := part_of[f.value.entity]; found {
				f.value.scene = target == part ? {} : guids[target]
			}
		}
		return fields
	}
	for &p, j in parts {
		for &e in p.entities {
			e.components = slice.clone(e.components, context.temp_allocator)
			for &c in e.components {
				c.fields = split(c.fields, j, part_of, guids)
			}
			e.behaviours = slice.clone(e.behaviours, context.temp_allocator)
			for &b in e.behaviours {
				b.fields = split(b.fields, j, part_of, guids)
			}
		}
	}
}

// remove_unused_sublevels deletes the blob of each sublevel that the scene's .meta file names and that the scene no
// longer has, so that no loader finds it. Its .meta line stays, as a sub-asset's does, so it has the same GUID if it
// comes back.
@(private = "file")
remove_unused_sublevels :: proc(
	out_dir: string,
	s: Asset_Source,
	sublevels: []format.Scene_Sublevel,
	problems: ^Problems,
) {
	outer: for m in s.meta.subassets {
		if m.kind != format.SUBLEVEL_KIND {
			continue
		}
		for l in sublevels {
			if l.guid == m.guid {
				continue outer
			}
		}
		path := scene_blob_path(out_dir, m.guid)
		if err := os.remove(path); err != nil && err != .Not_Exist {
			report_warning(problems, path, 0, 0, "cannot delete: %v", err)
		}
	}
}

// scene_flat parses and expands a scene, as its cook does, without reporting its problems again: the scene's cook
// reports them.
scene_flat :: proc(pass: ^Pass, index: int) -> (flat: format.Scene, ok: bool) {
	prefabs := Scene_Prefabs {
		pass   = pass,
		parsed = make(map[format.Guid]Maybe(format.Scene), context.temp_allocator),
		index  = make(map[format.Guid]int, context.temp_allocator),
	}
	for i in assets_of(pass.assets, .Prefab) {
		prefabs.index[pass.assets[i].meta.guid] = i
	}
	resolver := format.Prefab_Resolver {
		data = &prefabs,
		find = proc(data: rawptr, prefab: format.Guid) -> (format.Scene, bool) {
			return scene_prefab((^Scene_Prefabs)(data), prefab)
		},
	}
	scene, _, parsed := format.scene_parse(
		string(asset_source(pass, index)),
		context.temp_allocator,
		{prefab = pass.assets[index].kind == .Prefab},
	)
	if !parsed {
		return
	}
	flat, _, ok = format.scene_expand(scene, resolver, {}, context.temp_allocator)
	return
}

// parse_scene parses a scene or a prefab and reports the problems of its text. A scene's sublevels that the project does
// not declare are warnings, unless sublevels is nil.
parse_scene :: proc(
	s: Asset_Source,
	problems: ^Problems,
	sublevels: Maybe([]format.Sublevel) = nil,
) -> (
	scene: format.Scene,
	ok: bool,
) {
	parsed: []format.Scene_Problem
	scene, parsed, ok = format.scene_parse(
		string(source_of(s)),
		context.temp_allocator,
		{prefab = s.kind == .Prefab, sublevels = sublevels},
	)
	for p in parsed {
		if p.error {
			report_error(problems, s.path, p.line, 0, "%s", p.message)
		} else {
			report_warning(problems, s.path, p.line, 0, "%s", p.message)
		}
	}
	return
}

// drop_scene_references makes every reference to an entity of another scene none, in place. A prefab has no scene of
// its own to name them from, and an instance of it can be in any scene. With a problems list, each one is a warning.
drop_scene_references :: proc(scene: format.Scene, s: ^Asset_Source, problems: ^Problems) {
	drop :: proc(
		e: format.Scene_Entity,
		what: string,
		fields: []format.Scene_Field,
		s: ^Asset_Source,
		problems: ^Problems,
	) {
		for &f in fields {
			if f.value.kind != .Entity || f.value.scene == {} {
				continue
			}
			if problems != nil {
				buffer: [32]u8
				report_warning(
					problems,
					s.path,
					0,
					0,
					"entity %016x: %s%s refers to an entity of the scene %s, which a prefab cannot do, so it is none",
					e.id,
					what,
					f.name,
					format.guid_format(f.value.scene, &buffer),
				)
			}
			f.value.entity = 0
			f.value.scene = {}
		}
	}
	for e in scene.entities {
		for c in e.components {
			drop(e, fmt.tprintf("%s.", c.name), c.fields, s, problems)
		}
		for b in e.behaviours {
			drop(e, "", b.fields, s, problems)
		}
	}
}

// localize_scene_references gives a reference to an entity of the scene itself, by its GUID, the form of a reference
// in its own file: the loader finds these without waiting for a scene.
localize_scene_references :: proc(scene: format.Scene, guid: format.Guid) {
	for e in scene.entities {
		for c in e.components {
			for &f in c.fields {
				if f.value.kind == .Entity && f.value.scene == guid {
					f.value.scene = {}
				}
			}
		}
		for b in e.behaviours {
			for &f in b.fields {
				if f.value.kind == .Entity && f.value.scene == guid {
					f.value.scene = {}
				}
			}
		}
	}
}

// check_scene expands a parsed scene or prefab and reports its problems. A prefab has one root. An instance of an
// asset that is not a prefab is an error, as are the expansion's errors. A reference to a scene ID, a script or an
// asset that does not exist is a warning: the loader skips it, and the editor keeps it. The cooker cannot check an
// asset's kind, because field types exist only in the game DLL.
check_scene :: proc(
	s: Asset_Source,
	kind: format.Asset_Kind,
	scene: format.Scene,
	resolver: format.Prefab_Resolver,
	scripts: map[format.Guid]bool,
	known: map[format.Guid]format.Asset_Kind,
	problems: ^Problems,
) -> (
	flat: format.Scene,
	ok: bool,
) {
	ok = true
	if kind == .Prefab {
		if _, roots := format.prefab_root(scene); roots != 1 {
			report_error(
				problems,
				s.path,
				0,
				0,
				"a prefab has one root, an entity without a parent, not %d",
				roots,
			)
			ok = false
		}
	}
	for e in scene.entities {
		if e.prefab == {} {
			continue
		}
		if k, found := known[e.prefab]; found && k != .Prefab {
			buffer: [32]u8
			report_error(
				problems,
				s.path,
				0,
				0,
				"entity %016x: the asset %s is not a prefab",
				e.id,
				format.guid_format(e.prefab, &buffer),
			)
			ok = false
		}
	}
	if !ok {
		return
	}
	expanded: []format.Scene_Problem
	flat, expanded, ok = format.scene_expand(
		scene,
		resolver,
		kind == .Prefab ? s.meta.guid : {},
		context.temp_allocator,
	)
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
	if kind == .Scene {
		localize_scene_references(flat, s.meta.guid)
	}
	ids := make(map[u64]bool, len(flat.entities), context.temp_allocator)
	for e in flat.entities {
		ids[e.id] = true
	}
	// A reference to another scene is checked by its scene's GUID. The entity is in a file that this scene does not
	// read, and the target is not a dependency, because the scene loads without it.
	check_reference :: proc(
		s: Asset_Source,
		ids: map[u64]bool,
		known: map[format.Guid]format.Asset_Kind,
		entity: u64,
		what: string,
		value: format.Scene_Value,
		problems: ^Problems,
	) {
		if value.scene != {} {
			if kind, found := known[value.scene]; !found || kind != .Scene {
				buffer: [32]u8
				report_warning(
					problems,
					s.path,
					0,
					0,
					"entity %016x: %s refers to the scene %s, which is not a scene in the content",
					entity,
					what,
					format.guid_format(value.scene, &buffer),
				)
			}
			return
		}
		id := value.entity
		if id != 0 && !ids[id] {
			report_warning(
				problems,
				s.path,
				0,
				0,
				"entity %016x: %s refers to %016x, which is not in the scene",
				entity,
				what,
				id,
			)
		}
	}
	for e in flat.entities {
		check_reference(
			s,
			ids,
			known,
			e.id,
			"parent",
			{kind = .Entity, entity = e.parent},
			problems,
		)
		for c in e.components {
			for f in c.fields {
				if f.value.kind == .Entity {
					check_reference(
						s,
						ids,
						known,
						e.id,
						fmt.tprintf("%s.%s", c.name, f.name),
						f.value,
						problems,
					)
				}
				if f.value.kind == .Asset && f.value.asset != {} && f.value.asset not_in known {
					buffer: [32]u8
					report_warning(
						problems,
						s.path,
						0,
						0,
						"entity %016x: %s.%s names the asset %s, which is not in the content",
						e.id,
						c.name,
						f.name,
						format.guid_format(f.value.asset, &buffer),
					)
				}
			}
		}
		for b in e.behaviours {
			if !scripts[b.script] {
				buffer: [32]u8
				report_warning(
					problems,
					s.path,
					0,
					0,
					"entity %016x: no script has the GUID %s",
					e.id,
					format.guid_format(b.script, &buffer),
				)
			}
			for f in b.fields {
				if f.value.kind == .Entity {
					check_reference(s, ids, known, e.id, f.name, f.value, problems)
				}
			}
		}
	}
	return flat, true
}
