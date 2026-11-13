package cook

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// Index is what the daemon knows of the content after a pass: every asset with its status and problems, and every
// folder (see docs/content/daemon-and-operations.md#cook-daemon). Its entries are the cook link's, so they go to the editor as
// they are. Each pass builds a new index, which the daemon compares with the last one, and saves for the next daemon
// (see saved_index.odin). The next pass carries from it what nothing changed in.
Index :: struct {
	arena:     virtual.Arena,
	// By GUID.
	assets:    map[string]cook_link.Asset,
	folders:   []cook_link.Folder,
	// By GUID, with "" for the problems that belong to no asset. An asset without problems has no entry.
	problems:  map[string][]cook_link.Problem,
	// The shading models that cook, by name.
	shading:   cook_link.Shading_Models,
	// Every file and directory that the pass saw, in path order, and every source with what its cook learnt.
	files:     []File_Record,
	sources:   []Saved_Source,
	// By path, into sources.
	source_at: map[string]int,
	// The cache's generation after the pass.
	generation: u64,
}

// index_build makes an index from a pass, in memory of its own.
index_build :: proc(index: ^Index, pass: Pass, roots: []Root) {
	_ = virtual.arena_init_growing(&index.arena)
	allocator := virtual.arena_allocator(&index.arena)
	clone :: proc(s: string, allocator := context.allocator) -> string {
		return strings.clone(s, allocator)
	}
	index.assets = make(map[string]cook_link.Asset, len(pass.assets), allocator)
	// Each problem goes to the asset whose source or .meta file it is in.
	owner := make(map[string]string, len(pass.assets) * 2, context.temp_allocator)
	guids := make([]string, len(pass.assets), context.temp_allocator)
	// The generated text of each sub-asset that has one, by its GUID.
	generated := make(map[format.Guid]string, context.temp_allocator)
	for a, i in pass.assets {
		buffer: [32]u8
		guids[i] = clone(format.guid_format(a.meta.guid, &buffer), allocator)
		// A stage's generated text is not a file of the content; its problems are the stage's.
		if a.owner != {} {
			owner[a.path] = clone(format.guid_format(a.owner, &buffer), allocator)
			generated[a.meta.guid] = a.path
			continue
		}
		owner[a.path] = guids[i]
		owner[fmt.tprintf("%s%s", a.path, format.META_EXTENSION)] = guids[i]
	}
	grouped := make(map[string][dynamic]cook_link.Problem, context.temp_allocator)
	for p in pass.problems.list {
		guid := owner[p.file] or_else ""
		list := grouped[guid] or_else make([dynamic]cook_link.Problem, context.temp_allocator)
		append(&list, cook_link.Problem{clone(p.file, allocator), u32(p.line), u32(p.column), p.error, clone(p.text, allocator)})
		grouped[guid] = list
	}
	index.problems = make(map[string][]cook_link.Problem, len(grouped), allocator)
	for guid, list in grouped {
		index.problems[guid] = slice.clone(list[:], allocator)
	}
	for a, i in pass.assets {
		// The stage that generates it lists it among its sub-assets.
		if a.owner != {} {
			continue
		}
		root := roots[a.root]
		// Every kind's pass settles each of its assets, so a Pending one is a pass that missed it.
		when ODIN_DEBUG || ODIN_TEST {
			assert(a.result != .Pending, fmt.tprintf("the pass did not settle %s", a.name))
		}
		entry := cook_link.Asset {
			guid      = guids[i],
			kind      = link_kind(a.kind),
			root      = clone(root.name, allocator),
			path      = clone(a.name[len(root.name) + 1:], allocator),
			status    = link_status(a.result),
			behaviour = clone(a.behaviour, allocator),
			action    = clone(a.action, allocator),
			params    = clone_params(a.params, allocator),
			permutations = u32(a.permutations),
			size      = a.size,
		}
		if a.tool_texture != {} {
			buffer: [32]u8
			entry.tool_texture = clone(format.guid_format(a.tool_texture, &buffer), allocator)
		}
		hotspots := make([]cook_link.Hotspot, len(a.hotspots), allocator)
		for h, j in a.hotspots {
			hotspots[j] = {h[0], h[1], h[2], h[3]}
		}
		entry.hotspots = hotspots
		for p in index.problems[guids[i]] {
			if p.error {
				entry.errors += 1
			} else {
				entry.warnings += 1
			}
		}
		settings := make([]cook_link.Setting, len(a.meta.settings), allocator)
		for s, j in a.meta.settings {
			settings[j] = {clone(s.key, allocator), clone(s.value, allocator)}
		}
		entry.settings = settings
		dependencies := make([]string, len(a.dependencies), allocator)
		for d, j in a.dependencies {
			buffer: [32]u8
			dependencies[j] = clone(format.guid_format(d, &buffer), allocator)
		}
		entry.dependencies = dependencies
		index.assets[entry.guid] = entry
		// A sub-asset shares its file's root, path and status. Its problems are the file's.
		for s in a.subassets {
			buffer: [32]u8
			sub := cook_link.Asset {
				guid     = clone(format.guid_format(s.guid, &buffer), allocator),
				kind     = link_kind(s.kind),
				root     = entry.root,
				path     = entry.path,
				status   = entry.status,
				parent   = entry.guid,
				subasset = clone(s.name, allocator),
				generated = clone(generated[s.guid] or_else "", allocator),
			}
			index.assets[sub.guid] = sub
		}
	}
	folders := make([]cook_link.Folder, len(pass.folders), allocator)
	for f, i in pass.folders {
		folders[i] = {clone(roots[f.root].name, allocator), clone(f.path, allocator)}
	}
	index.folders = folders
	models := make([dynamic]cook_link.Shading_Model_Info, allocator)
	for decl in pass.shadings {
		if !shading_usable(pass.assets, decl) {
			continue
		}
		inputs := make([]cook_link.Node_Pin, len(decl.inputs), allocator)
		for input, i in decl.inputs {
			d := input.default
			inputs[i] = {name = clone(input.name, allocator), type = cook_link.Pin_Type(input.count - 1), default = {f32(d.x), f32(d.y), f32(d.z), f32(d.w)}}
		}
		append(&models, cook_link.Shading_Model_Info{name = clone(decl.name, allocator), guid = guids[decl.asset], inputs = inputs, no_lighting = decl.no_lighting})
	}
	slice.sort_by(models[:], proc(a, b: cook_link.Shading_Model_Info) -> bool {return a.name < b.name})
	index.shading = {models[:]}
	// A pass that carries every material parses no shading model, so the models are the last pass's.
	if pass.shadings == nil && pass.saved != nil {
		index.shading = {clone_shading_models(pass.saved.shading.models, allocator)}
	}
	index.generation = pass.generation
	index_keep_sources(index, pass)
}

@(private = "file")
clone_shading_models :: proc(models: []cook_link.Shading_Model_Info, allocator := context.allocator) -> []cook_link.Shading_Model_Info {
	result := make([]cook_link.Shading_Model_Info, len(models), allocator)
	for m, i in models {
		inputs := make([]cook_link.Node_Pin, len(m.inputs), allocator)
		for input, j in m.inputs {
			inputs[j] = input
			inputs[j].name = strings.clone(input.name, allocator)
			inputs[j].default_label = strings.clone(input.default_label, allocator)
		}
		result[i] = {name = strings.clone(m.name, allocator), guid = strings.clone(m.guid, allocator), inputs = inputs, no_lighting = m.no_lighting}
	}
	return result
}

// link_status is an asset's status in the index: current when its blob is up to date, and failed otherwise, also when
// no pass reached it.
link_status :: proc(result: Asset_Result) -> cook_link.Asset_Status {
	switch result {
	case .Current, .Cooked:
		return .Current
	case .Pending, .Failed, .Blocked:
	}
	return .Failed
}

index_destroy :: proc(index: ^Index) {
	virtual.arena_destroy(&index.arena)
	index^ = {}
}

// Index_Changes is what changed from one index to the next, in the temporary allocator.
Index_Changes :: struct {
	delta:    cook_link.Asset_Delta,
	// The assets whose problems changed, each with its new list, which is empty when they are gone.
	problems: []cook_link.Asset_Problems,
	shading:  bool,
}

index_changed :: proc(c: Index_Changes) -> bool {
	d := c.delta
	return len(d.changed) + len(d.removed) + len(d.added_folders) + len(d.removed_folders) + len(c.problems) > 0
}

// index_diff compares two indices. The changes point into both, so they must be used before either is destroyed.
index_diff :: proc(old, new: ^Index) -> (changes: Index_Changes) {
	changed := make([dynamic]cook_link.Asset, context.temp_allocator)
	removed := make([dynamic]string, context.temp_allocator)
	for guid, a in new.assets {
		if before, found := old.assets[guid]; !found || !asset_equal(before, a) {
			append(&changed, a)
		}
	}
	for guid in old.assets {
		if guid not_in new.assets {
			append(&removed, guid)
		}
	}
	slice.sort_by(changed[:], proc(a, b: cook_link.Asset) -> bool {return a.root < b.root || (a.root == b.root && a.path < b.path)})
	slice.sort(removed[:])
	changes.delta = {
		changed         = changed[:],
		removed         = removed[:],
		added_folders   = folders_missing(new.folders, old.folders),
		removed_folders = folders_missing(old.folders, new.folders),
	}
	problems := make([dynamic]cook_link.Asset_Problems, context.temp_allocator)
	for guid, list in new.problems {
		if !problems_equal(old.problems[guid], list) {
			append(&problems, cook_link.Asset_Problems{guid, list})
		}
	}
	for guid in old.problems {
		if guid not_in new.problems {
			append(&problems, cook_link.Asset_Problems{guid, nil})
		}
	}
	slice.sort_by(problems[:], proc(a, b: cook_link.Asset_Problems) -> bool {return a.guid < b.guid})
	changes.problems = problems[:]
	changes.shading = !shading_equal(old.shading.models, new.shading.models)
	return
}

@(private = "file")
shading_equal :: proc(a, b: []cook_link.Shading_Model_Info) -> bool {
	if len(a) != len(b) {
		return false
	}
	for m, i in a {
		if m.name != b[i].name || m.guid != b[i].guid || m.no_lighting != b[i].no_lighting || !slice.equal(m.inputs, b[i].inputs) {
			return false
		}
	}
	return true
}

// index_snapshot is the whole index, for an editor that has just linked.
index_snapshot :: proc(index: ^Index) -> (snapshot: cook_link.Asset_Snapshot, problems: []cook_link.Asset_Problems) {
	assets := make([dynamic]cook_link.Asset, 0, len(index.assets), context.temp_allocator)
	for _, a in index.assets {
		append(&assets, a)
	}
	slice.sort_by(assets[:], proc(a, b: cook_link.Asset) -> bool {return a.root < b.root || (a.root == b.root && a.path < b.path)})
	list := make([dynamic]cook_link.Asset_Problems, 0, len(index.problems), context.temp_allocator)
	for guid, p in index.problems {
		append(&list, cook_link.Asset_Problems{guid, p})
	}
	slice.sort_by(list[:], proc(a, b: cook_link.Asset_Problems) -> bool {return a.guid < b.guid})
	return {assets[:], index.folders}, list[:]
}

@(private = "file")
folders_missing :: proc(from, other: []cook_link.Folder) -> []cook_link.Folder {
	missing := make([dynamic]cook_link.Folder, context.temp_allocator)
	for f in from {
		if _, found := slice.linear_search(other, f); !found {
			append(&missing, f)
		}
	}
	return missing[:]
}

// clone_params copies an action's parameters, with their names.
clone_params :: proc(params: []cook_link.Action_Param, allocator := context.allocator) -> []cook_link.Action_Param {
	if len(params) == 0 {
		return nil
	}
	copied := make([]cook_link.Action_Param, len(params), allocator)
	for p, i in params {
		copied[i] = {strings.clone(p.name, allocator), p.kind}
	}
	return copied
}

@(private = "file")
asset_equal :: proc(a, b: cook_link.Asset) -> bool {
	if a.thumbnail != b.thumbnail || a.thumbnail_ready != b.thumbnail_ready || a.generated != b.generated || a.guid != b.guid || a.kind != b.kind || a.root != b.root || a.path != b.path || a.status != b.status || a.errors != b.errors || a.warnings != b.warnings || a.behaviour != b.behaviour || a.action != b.action || a.parent != b.parent || a.subasset != b.subasset || a.permutations != b.permutations || a.size != b.size || a.tool_texture != b.tool_texture {
		return false
	}
	return slice.equal(a.settings, b.settings) && slice.equal(a.dependencies, b.dependencies) && slice.equal(a.hotspots, b.hotspots) && slice.equal(a.params, b.params)
}

@(private = "file")
problems_equal :: proc(a, b: []cook_link.Problem) -> bool {
	return slice.equal(a, b)
}
