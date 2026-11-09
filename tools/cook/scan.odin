// A pass's scan, and what the pass looks at again. The daemon keeps what each pass learnt in its index, which it saves
// (see saved_index.odin), so a pass lists only the directories that changed, reads only the assets whose files changed,
// and carries the others. See docs/content/daemon-and-operations.md#saved-index.
package cook

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import format "cinnabar:engine/asset/format"

// File_Record is a file or a directory that a scan saw. A file's size and modification time tell when it changes; a
// directory has neither, since its time changes with what is in it.
File_Record :: struct {
	// Absolute, with forward slashes.
	path:      string,
	directory: bool,
	size:      i64,
	modified:  i64,
}

// Scan is what scan_pass found, in the temporary allocator.
Scan :: struct {
	// Every asset in the roots, in path order, read or carried, without those that share a GUID.
	assets:     []Asset_Source,
	folders:    []Folder,
	shared:     []format.Guid,
	// Every file and directory in the roots and the include directories, and the definition file, in path order.
	files:      []File_Record,
	// The paths that came, went or changed since the saved index, and the paths that the watcher reported, which
	// include files that the scan does not record, such as a .luaurc file.
	changed:    map[string]bool,
	// Whether the scan listed every directory, so that it looked at everything.
	everything: bool,
	ok:         bool,
}

// scan reads every asset in the roots, with its .meta file, in path order, and lists the folders. An asset without a
// .meta file gets a new GUID, and the cooker writes its .meta file. A .meta file without its asset, as when Explorer
// or git moves a source without it, is a warning. Files and directories whose names start with a dot are skipped.
scan :: proc(roots: []Root, problems: ^Problems) -> (assets: []Asset_Source, folders: []Folder, shared: []format.Guid, ok: bool) {
	pass := Pass {
		problems = problems^,
		read     = make([dynamic]string, context.temp_allocator),
	}
	s := scan_pass(roots, nil, "", nil, Changed_Everything{}, &pass)
	problems^ = pass.problems
	return s.assets, s.folders, s.shared, s.ok
}

// scan_pass lists the roots, the include directories and the definition file, and reads the assets. With a saved index
// and the paths that changed, it lists only the directories that hold them, and those that are new; it reads only the
// assets whose source or .meta file changed, or that the saved index does not have, and carries the others. Otherwise
// it lists and reads everything.
scan_pass :: proc(roots: []Root, includes: []string, definitions: string, saved: ^Index, changes: Watch_Changes, pass: ^Pass) -> (s: Scan) {
	problems := &pass.problems
	empty: Index
	saved := saved if saved != nil else &empty
	s.ok = true
	s.changed = make(map[string]bool, context.temp_allocator)
	records := make(map[string]File_Record, len(saved.files), context.temp_allocator)
	paths, partial := changes.(Changed_Paths)
	s.everything = !partial || len(saved.files) == 0
	if s.everything {
		for root in roots {
			s.ok = list_tree(root.dir, &records, nil, problems) && s.ok
		}
		for include in includes {
			// An include directory that does not exist holds nothing; a shader's include then reports it.
			list_tree(include, &records, nil, nil)
		}
		if definitions != "" {
			restat(definitions, &records, nil)
		}
		for path, r in records {
			if old, found := saved_file(saved, path); !found || old != r {
				s.changed[path] = true
			}
		}
		for f in saved.files {
			if f.path not_in records {
				s.changed[f.path] = true
			}
		}
	} else {
		for f in saved.files {
			records[f.path] = f
		}
		listed := make(map[string]bool, context.temp_allocator)
		for path in paths.paths {
			s.changed[path] = true
			root, in_root := root_of(roots, path)
			switch {
			case in_root && !hidden(roots[root], path):
				dir := parent_dir(path)
				if !listed[dir] {
					listed[dir] = true
					s.ok = relist(dir, &records, &s.changed, problems) && s.ok
				}
			case in_root:
			// The scan skips what starts with a dot, so it has no record of it.
			case path == definitions || in_dirs(includes, path):
				restat(path, &records, &s.changed)
			}
		}
	}
	files := make([]File_Record, len(records), context.temp_allocator)
	i := 0
	for _, r in records {
		files[i] = r
		i += 1
	}
	slice.sort_by(files, proc(a, b: File_Record) -> bool {return a.path < b.path})
	s.files = files

	found := make([dynamic]Asset_Source, context.temp_allocator)
	found_folders := make([dynamic]Folder, context.temp_allocator)
	new_meta := make([dynamic]File_Record, context.temp_allocator)
	for &r in s.files {
		root_index, in_root := root_of(roots, r.path)
		if !in_root || hidden(roots[root_index], r.path) {
			continue
		}
		root := roots[root_index]
		relative := r.path[len(root.dir) + 1:]
		if r.directory {
			append(&found_folders, Folder{root_index, relative})
			continue
		}
		name := relative[strings.last_index_byte(relative, '/') + 1:]
		if strings.has_suffix(name, format.META_EXTENSION) {
			if strings.trim_suffix(r.path, format.META_EXTENSION) not_in records {
				report_warning(problems, r.path, 0, 0, "has no asset next to it. Move it to its asset, which then keeps its GUID, or delete it.")
			}
			continue
		}
		kind := kind_of(name)
		if kind == .None {
			continue
		}
		a := Asset_Source {
			kind         = kind,
			root         = root_index,
			path         = r.path,
			name         = fmt.tprintf("%s/%s", root.name, relative),
			dependencies = make([dynamic]format.Guid, context.temp_allocator),
			visual       = make([dynamic]format.Guid, context.temp_allocator),
			subassets    = make([dynamic]Subasset, context.temp_allocator),
			inputs       = make([dynamic]Input_Stamp, context.temp_allocator),
		}
		meta_path := fmt.tprintf("%s%s", r.path, format.META_EXTENSION)
		if old, has_old := saved_source(saved, r.path); has_old && !s.changed[r.path] && !s.changed[meta_path] && carry_source(&a, old) {
			append(&found, a)
			continue
		}
		switch read_asset(root.dir, &a, problems) {
		case .Read:
			append(&found, a)
			append(&pass.read, a.path)
			// A .meta file that the scan wrote is part of the content from now on.
			if meta_path not_in records {
				restat(meta_path, &records, nil)
				if m, made := records[meta_path]; made {
					append(&new_meta, m)
				}
			}
		case .Gone:
		case .Failed:
			s.ok = false
		}
	}
	if len(new_meta) > 0 {
		all := make([]File_Record, len(s.files) + len(new_meta), context.temp_allocator)
		copy(all, s.files)
		copy(all[len(s.files):], new_meta[:])
		slice.sort_by(all, proc(a, b: File_Record) -> bool {return a.path < b.path})
		s.files = all
	}
	s.assets, s.folders, s.shared, s.ok = found_assets(found[:], found_folders[:], problems, s.ok)
	return
}

// carry_source fills in an asset that the scan does not read from what the saved index has of it.
@(private = "file")
carry_source :: proc(a: ^Asset_Source, saved: Saved_Source) -> bool {
	meta, ok := format.meta_parse(saved.meta_text, context.temp_allocator)
	if !ok {
		return false
	}
	a.meta_text = saved.meta_text
	a.meta = meta
	append(&a.dependencies, ..saved.dependencies)
	append(&a.subassets, ..saved.subassets)
	append(&a.visual, ..saved.visual)
	append(&a.inputs, ..saved.inputs)
	a.behaviour = saved.behaviour
	a.permutations = saved.permutations
	a.size = saved.size
	a.tool_texture = saved.tool_texture
	a.hotspots = saved.hotspots
	a.carried = Carried{saved.problems}
	return true
}

// carried_generated is a source that a carried stage generates, from the saved index: it is carried too, unless the
// pass looks at it, as when its material changed.
carried_generated :: proc(pass: ^Pass, saved: Saved_Source) -> Asset_Source {
	a := Asset_Source {
		kind         = saved.kind,
		root         = saved.root,
		path         = saved.path,
		name         = saved.name,
		owner        = saved.owner,
		dependencies = make([dynamic]format.Guid, context.temp_allocator),
		visual       = make([dynamic]format.Guid, context.temp_allocator),
		subassets    = make([dynamic]Subasset, context.temp_allocator),
		inputs       = make([dynamic]Input_Stamp, context.temp_allocator),
	}
	carry_source(&a, saved)
	if pass.scope[saved.guid] {
		uncarry(&a)
	}
	return a
}

// pass_scope decides what a pass looks at again, and carries the rest. It looks at:
//
// - what the scan read, and what went, or now shares its GUID;
// - what did not cook at the last pass, which it tries again, and what the editor re-imports;
// - what a file outside the content that it read changed in, such as a model's buffer;
// - every asset with problems, when the content's files or GUIDs came or went, since a problem may name what was
//   missing;
// - the shaders and materials, when a file that is not an asset changed, which may be an include;
// - every script, when the definition file or a .luaurc file changed;
//
// and every asset that depends on one of those, directly or not, through its dependencies, the assets that it draws
// with, or, for a stage's generated sources, its stage. A kind whose assets depend on each other in ways that no
// dependency says is looked at as a whole (see carry_kind).
pass_scope :: proc(pass: ^Pass, s: Scan, saved: ^Index, roots: []Root, includes: []string, definitions: string, force: map[format.Guid]bool) {
	scope := make(map[format.Guid]bool, context.temp_allocator)
	pass.scope = scope
	queue := make([dynamic]format.Guid, context.temp_allocator)
	present := make(map[format.Guid]bool, len(pass.assets), context.temp_allocator)
	for a in pass.assets {
		present[a.meta.guid] = true
		if a.carried == nil {
			append(&queue, a.meta.guid)
		}
	}
	// What depends on each GUID, and the sources that a stage generates, from the saved index.
	dependents := make(map[format.Guid][dynamic]format.Guid, len(saved.sources), context.temp_allocator)
	generated := make(map[format.Guid][dynamic]format.Guid, context.temp_allocator)
	by_guid := make(map[format.Guid]int, len(saved.sources), context.temp_allocator)
	add_dependent :: proc(dependents: ^map[format.Guid][dynamic]format.Guid, on, dependent: format.Guid) {
		list := dependents[on] or_else make([dynamic]format.Guid, context.temp_allocator)
		append(&list, dependent)
		dependents[on] = list
	}
	for src, i in saved.sources {
		by_guid[src.guid] = i
		for d in src.dependencies {
			add_dependent(&dependents, d, src.guid)
		}
		for d in src.visual {
			add_dependent(&dependents, d, src.guid)
		}
		if src.owner != {} {
			add_dependent(&generated, src.owner, src.guid)
		}
		gone := src.owner == {} ? !present[src.guid] : !present[src.owner]
		inputs_changed := false
		for input in src.inputs {
			if s.changed[input.path] {
				inputs_changed = true
			} else if s.everything {
				size, modified, ok := file_stamp(input.path)
				inputs_changed ||= !ok || size != input.size || modified != input.modified
			}
		}
		if gone || link_status(src.result) != .Current || force[src.guid] || inputs_changed {
			append(&queue, src.guid)
		}
	}
	for a in pass.assets {
		if force[a.meta.guid] {
			append(&queue, a.meta.guid)
		}
	}

	recheck_problems, includes_changed, scripts_changed := guids_changed(pass.assets, saved), false, false
	for path in s.changed {
		root, in_root := root_of(roots, path)
		name := path[strings.last_index_byte(path, '/') + 1:]
		switch {
		case path == definitions:
			scripts_changed = true
		case in_root && hidden(roots[root], path):
			switch name {
			case LOCK_FILE:
			case LUAURC:
				scripts_changed = true
			case:
				includes_changed = true
				recheck_problems = true
			}
		case in_root:
			_, was := saved_file(saved, path)
			r, is := file_in(s.files, path)
			if was != is {
				recheck_problems = true
			}
			if is && !r.directory && !strings.has_suffix(name, format.META_EXTENSION) && kind_of(name) == .None {
				includes_changed = true
			}
		case in_dirs(includes, path):
			includes_changed = true
		}
	}
	if recheck_problems {
		for src in saved.sources {
			if len(src.problems) > 0 {
				append(&queue, src.guid)
			}
		}
	}
	for a in pass.assets {
		if (includes_changed && a.kind in INCLUDING_KINDS) || (scripts_changed && a.kind == .Script) {
			append(&queue, a.meta.guid)
		}
	}

	for len(queue) > 0 {
		guid := pop(&queue)
		if scope[guid] {
			continue
		}
		scope[guid] = true
		append(&queue, ..dependents[guid][:])
		append(&queue, ..generated[guid][:])
		if i, found := by_guid[guid]; found {
			for sub in saved.sources[i].subassets {
				append(&queue, ..dependents[sub.guid][:])
			}
		}
	}
	for &a in pass.assets {
		if a.carried != nil && scope[a.meta.guid] {
			uncarry(&a)
		}
	}
}

// The kinds whose cooks read include files, which are not assets.
@(private = "file")
INCLUDING_KINDS :: Asset_Kinds{.Shader, .Shading_Model, .Material, .Material_Instance, .Material_Function}

// guids_changed is whether the GUIDs that the content's .meta files give came or went since the saved index: an
// asset came or went, or the scan read a .meta file that gives other GUIDs.
@(private = "file")
guids_changed :: proc(assets: []Asset_Source, saved: ^Index) -> bool {
	count := 0
	for a in assets {
		old, found := saved_source(saved, a.path)
		if !found {
			return true
		}
		count += 1
		if a.carried != nil || old.meta_text == a.meta_text {
			continue
		}
		meta, _ := format.meta_parse(old.meta_text, context.temp_allocator)
		if meta.guid != a.meta.guid || len(meta.subassets) != len(a.meta.subassets) {
			return true
		}
		for sub, i in meta.subassets {
			if sub.guid != a.meta.subassets[i].guid {
				return true
			}
		}
	}
	saved_count := 0
	for src in saved.sources {
		saved_count += int(src.owner == {})
	}
	return count != saved_count
}

// list_tree adds a directory's records, and those of everything under it, to records, and marks each as changed. It
// skips what starts with a dot. A directory that it cannot read is a problem, unless problems is nil.
@(private = "file")
list_tree :: proc(dir: string, records: ^map[string]File_Record, changed: ^map[string]bool, problems: ^Problems) -> bool {
	ok := true
	// os.walker leaves the last directory that it reads open, which stops a rename or a delete of it, so the scan
	// reads each directory itself.
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, dir)
	for len(todo) > 0 {
		next := pop(&todo)
		infos, err := os.read_all_directory_by_path(next, context.temp_allocator)
		if err != nil {
			if problems != nil {
				report_error(problems, forward_slashes(next), 0, 0, "%v", err)
				ok = false
			}
			continue
		}
		for info in infos {
			if strings.has_prefix(info.name, ".") {
				continue
			}
			r := record_of(info)
			records[r.path] = r
			if changed != nil {
				changed[r.path] = true
			}
			if r.directory {
				append(&todo, r.path)
			}
		}
	}
	return ok
}

// relist lists one directory again: it updates the records of what is in it, lists the directories that are new in
// it, and drops what went, with everything under it. A directory that went goes with everything under it.
@(private = "file")
relist :: proc(dir: string, records: ^map[string]File_Record, changed: ^map[string]bool, problems: ^Problems) -> bool {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err == .Not_Exist {
		drop_tree(dir, records, changed)
		return true
	}
	if err != nil {
		report_error(problems, dir, 0, 0, "%v", err)
		return false
	}
	ok := true
	seen := make(map[string]bool, len(infos), context.temp_allocator)
	for info in infos {
		if strings.has_prefix(info.name, ".") {
			continue
		}
		r := record_of(info)
		seen[r.path] = true
		old, had := records[r.path]
		if had && old == r {
			continue
		}
		if had && old.directory != r.directory {
			drop_tree(r.path, records, changed)
		}
		records[r.path] = r
		changed[r.path] = true
		if r.directory && !(had && old.directory) {
			ok = list_tree(r.path, records, changed, problems) && ok
		}
	}
	gone := make([dynamic]string, context.temp_allocator)
	for path in records {
		if parent_dir(path) == dir && !seen[path] {
			append(&gone, path)
		}
	}
	for path in gone {
		drop_tree(path, records, changed)
	}
	return ok
}

// drop_tree drops a path's record, and those of everything under it, and marks each as changed.
@(private = "file")
drop_tree :: proc(path: string, records: ^map[string]File_Record, changed: ^map[string]bool) {
	prefix := fmt.tprintf("%s/", path)
	gone := make([dynamic]string, context.temp_allocator)
	for p in records {
		if p == path || strings.has_prefix(p, prefix) {
			append(&gone, p)
		}
	}
	for p in gone {
		delete_key(records, p)
		changed[p] = true
	}
	changed[path] = true
}

// restat updates the record of a file that the watcher reported outside the roots, or drops it if it went.
@(private = "file")
restat :: proc(path: string, records: ^map[string]File_Record, changed: ^map[string]bool) {
	info, err := os.stat(path, context.temp_allocator)
	old, had := records[path]
	if err != nil || info.type == .Directory {
		if had && changed != nil {
			changed[path] = true
		}
		delete_key(records, path)
		return
	}
	r := record_of(info)
	r.path = strings.clone(path, context.temp_allocator)
	records[r.path] = r
	if changed != nil && (!had || old != r) {
		changed[r.path] = true
	}
}

@(private = "file")
record_of :: proc(info: os.File_Info) -> File_Record {
	path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
	if info.type == .Directory {
		return {path = path, directory = true}
	}
	return {path = path, size = info.size, modified = time.to_unix_nanoseconds(info.modification_time)}
}

// saved_file is a path's record in the saved index.
@(private = "file")
saved_file :: proc(saved: ^Index, path: string) -> (File_Record, bool) {
	return file_in(saved.files, path)
}

// file_in is a path's record among records in path order.
@(private = "file")
file_in :: proc(files: []File_Record, path: string) -> (File_Record, bool) {
	i, found := slice.binary_search_by(files, path, proc(r: File_Record, path: string) -> slice.Ordering {
		return slice.Ordering(int(r.path > path) - int(r.path < path))
	})
	return files[i] if found else {}, found
}

// saved_source is what the saved index has of the asset at a path.
saved_source :: proc(saved: ^Index, path: string) -> (Saved_Source, bool) {
	if i, found := saved.source_at[path]; found {
		return saved.sources[i], true
	}
	return {}, false
}

// root_of is the index of the root that a path is under.
@(private = "file")
root_of :: proc(roots: []Root, path: string) -> (int, bool) {
	for r, i in roots {
		if len(path) > len(r.dir) && strings.has_prefix(path, r.dir) && path[len(r.dir)] == '/' {
			return i, true
		}
	}
	return -1, false
}

@(private = "file")
in_dirs :: proc(dirs: []string, path: string) -> bool {
	for dir in dirs {
		if len(path) > len(dir) && strings.has_prefix(path, dir) && path[len(dir)] == '/' {
			return true
		}
	}
	return false
}

// hidden is whether a path in a root is one that the scan skips: a name in it starts with a dot.
@(private = "file")
hidden :: proc(root: Root, path: string) -> bool {
	rest := path[len(root.dir) + 1:]
	for part in strings.split_iterator(&rest, "/") {
		if strings.has_prefix(part, ".") {
			return true
		}
	}
	return false
}

@(private = "file")
parent_dir :: proc(path: string) -> string {
	return path[:max(strings.last_index_byte(path, '/'), 0)]
}
