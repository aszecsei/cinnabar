// The daemon's asset operations: the changes to the content roots that the editor asks for (see
// docs/content-pipeline.md#asset-operations). Each checks everything first, so it fails without changing anything, or
// does all of it. The daemon then makes a pass, so the index has the change before the editor hears the result.
package cook

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// run_operation does an operation from the editor. It adds the assets that a re-import asks for to force, which the
// next pass cooks whatever their keys. It returns false for a message that is not an operation.
run_operation :: proc(
	roots: []Root,
	index: ^Index,
	message: cook_link.Message,
	force: ^map[format.Guid]bool,
) -> (
	result: cook_link.Operation_Result,
	is_operation: bool,
) {
	is_operation = true
	#partial switch op in message {
	case cook_link.Create_Asset:
		result = create_asset(roots, op)
	case cook_link.Create_Folder:
		result = create_folder(roots, op)
	case cook_link.Move_Assets:
		result = move_assets(roots, index, op)
	case cook_link.Rename_Asset:
		result = rename_asset(roots, index, op)
	case cook_link.Rename_Folder:
		result = rename_folder(roots, op)
	case cook_link.Duplicate_Assets:
		result = duplicate_assets(roots, index, op)
	case cook_link.Delete_Assets:
		result = delete_assets(roots, index, op)
	case cook_link.Set_Import_Settings:
		result = set_import_settings(roots, index, op)
	case cook_link.Reimport:
		result = reimport(index, op, force)
	case:
		is_operation = false
	}
	return
}

@(private = "file")
failed :: proc(format_string: string, args: ..any) -> cook_link.Operation_Result {
	return {error = fmt.tprintf(format_string, ..args)}
}

@(private = "file")
create_asset :: proc(roots: []Root, op: cook_link.Create_Asset) -> cook_link.Operation_Result {
	dir, error := folder_dir(roots, op.root, op.folder)
	if error != "" {
		return failed("%s", error)
	}
	kind: format.Asset_Kind = op.template == .Scene ? .Scene : .Script
	name := strings.trim_suffix(strings.trim_space(op.name), extension_of(kind))
	if !valid_name(name) {
		return failed("%q is not a name for a file", op.name)
	}
	path := fmt.tprintf("%s/%s%s", dir, name, extension_of(kind))
	if os.exists(path) || os.exists(meta_of(path)) {
		return failed("%s already exists", display(roots, path))
	}
	text := template_text(op.template, name)
	if err := os.write_entire_file(path, transmute([]byte)text); err != nil {
		return failed("cannot write %s: %s", display(roots, path), os.error_string(err))
	}
	meta, guid := new_meta(nil)
	if err := os.write_entire_file(meta_of(path), transmute([]byte)meta); err != nil {
		os.remove(path)
		return failed("cannot write %s: %s", display(roots, meta_of(path)), os.error_string(err))
	}
	log.infof("cook: created %s", display(roots, path))
	return {guids = guid_strings({guid})}
}

@(private = "file")
create_folder :: proc(roots: []Root, op: cook_link.Create_Folder) -> cook_link.Operation_Result {
	if op.path == "" {
		return failed("a new folder needs a name")
	}
	parent, error := folder_dir(roots, op.root, parent_of(op.path))
	if error != "" {
		return failed("%s", error)
	}
	name := name_of(op.path)
	if !valid_name(name) {
		return failed("%q is not a name for a folder", name)
	}
	path := fmt.tprintf("%s/%s", parent, name)
	if os.exists(path) {
		return failed("%s already exists", display(roots, path))
	}
	if err := os.make_directory(path); err != nil {
		return failed("cannot make %s: %s", display(roots, path), os.error_string(err))
	}
	log.infof("cook: created the folder %s", display(roots, path))
	return {}
}

// A move of a source and its .meta file, for undoing what a failed operation already did.
@(private = "file")
Move :: struct {
	from, to: string,
}

@(private = "file")
move_assets :: proc(roots: []Root, index: ^Index, op: cook_link.Move_Assets) -> cook_link.Operation_Result {
	dir, error := folder_dir(roots, op.root, op.folder)
	if error != "" {
		return failed("%s", error)
	}
	moves := make([dynamic]Move, context.temp_allocator)
	for guid in op.guids {
		from, found := asset_path(roots, index, guid)
		if !found {
			return not_found(index, guid)
		}
		to := fmt.tprintf("%s/%s", dir, name_of(from))
		if to == from {
			continue
		}
		for m in moves {
			if strings.equal_fold(m.to, to) {
				return failed("two of the assets are named %s", name_of(to))
			}
		}
		if os.exists(to) || os.exists(meta_of(to)) {
			return failed("%s already exists", display(roots, to))
		}
		append(&moves, Move{from, to})
	}
	return do_moves(roots, moves[:])
}

@(private = "file")
rename_asset :: proc(roots: []Root, index: ^Index, op: cook_link.Rename_Asset) -> cook_link.Operation_Result {
	from, found := asset_path(roots, index, op.guid)
	if !found {
		return not_found(index, op.guid)
	}
	extension := extension_in(from)
	name := strings.trim_suffix(strings.trim_space(op.name), extension)
	if !valid_name(name) {
		return failed("%q is not a name for a file", op.name)
	}
	to := fmt.tprintf("%s/%s%s", parent_of(from), name, extension)
	if to == from {
		return {}
	}
	// Only the case of the name changes: on Windows, the destination exists, and is the asset itself.
	if !strings.equal_fold(to, from) && (os.exists(to) || os.exists(meta_of(to))) {
		return failed("%s already exists", display(roots, to))
	}
	return do_moves(roots, {{from, to}})
}

// do_moves moves each source with its .meta file. If one fails, it moves back what it moved, and fails.
@(private = "file")
do_moves :: proc(roots: []Root, moves: []Move) -> cook_link.Operation_Result {
	for m, i in moves {
		error := move_file(meta_of(m.from), meta_of(m.to))
		if error == "" {
			error = move_file(m.from, m.to)
			if error != "" {
				move_file(meta_of(m.to), meta_of(m.from))
			}
		}
		if error != "" {
			#reverse for done in moves[:i] {
				move_file(done.to, done.from)
				move_file(meta_of(done.to), meta_of(done.from))
			}
			return failed("cannot move %s to %s: %s", display(roots, m.from), display(roots, m.to), error)
		}
	}
	for m in moves {
		log.infof("cook: moved %s to %s", display(roots, m.from), display(roots, m.to))
	}
	return {}
}

@(private = "file")
rename_folder :: proc(roots: []Root, op: cook_link.Rename_Folder) -> cook_link.Operation_Result {
	if op.path == "" {
		return failed("a root cannot be renamed")
	}
	from, error := folder_dir(roots, op.root, op.path)
	if error != "" {
		return failed("%s", error)
	}
	name := strings.trim_space(op.name)
	if !valid_name(name) {
		return failed("%q is not a name for a folder", op.name)
	}
	to := fmt.tprintf("%s/%s", parent_of(from), name)
	if to == from {
		return {}
	}
	if !strings.equal_fold(to, from) && os.exists(to) {
		return failed("%s already exists", display(roots, to))
	}
	if move_error := move_file(from, to); move_error != "" {
		return failed("cannot rename %s: %s", display(roots, from), move_error)
	}
	log.infof("cook: renamed the folder %s to %s", display(roots, from), display(roots, to))
	return {}
}

@(private = "file")
duplicate_assets :: proc(roots: []Root, index: ^Index, op: cook_link.Duplicate_Assets) -> cook_link.Operation_Result {
	Copy :: struct {
		from, to: string,
		settings: []format.Meta_Setting,
	}
	copies := make([dynamic]Copy, context.temp_allocator)
	for guid in op.guids {
		from, found := asset_path(roots, index, guid)
		if !found {
			return not_found(index, guid)
		}
		extension := extension_in(from)
		stem := strings.trim_suffix(name_of(from), extension)
		to: string
		for n := 1;; n += 1 {
			to = fmt.tprintf("%s/%s_copy%s%s", parent_of(from), stem, n == 1 ? "" : fmt.tprintf("_%d", n), extension)
			taken := os.exists(to) || os.exists(meta_of(to))
			for c in copies {
				taken ||= strings.equal_fold(c.to, to)
			}
			if !taken {
				break
			}
		}
		entry := index.assets[guid]
		settings := make([]format.Meta_Setting, len(entry.settings), context.temp_allocator)
		for s, i in entry.settings {
			settings[i] = {s.key, s.value}
		}
		append(&copies, Copy{from, to, settings})
	}
	guids := make([dynamic]format.Guid, context.temp_allocator)
	for c in copies {
		source, read_err := os.read_entire_file(c.from, context.temp_allocator)
		if read_err != nil {
			return failed("cannot read %s: %s", display(roots, c.from), os.error_string(read_err))
		}
		if err := os.write_entire_file(c.to, source); err != nil {
			return failed("cannot write %s: %s", display(roots, c.to), os.error_string(err))
		}
		meta, guid := new_meta(c.settings)
		if err := os.write_entire_file(meta_of(c.to), transmute([]byte)meta); err != nil {
			os.remove(c.to)
			return failed("cannot write %s: %s", display(roots, meta_of(c.to)), os.error_string(err))
		}
		append(&guids, guid)
		log.infof("cook: copied %s to %s", display(roots, c.from), display(roots, c.to))
	}
	return {guids = guid_strings(guids[:])}
}

@(private = "file")
delete_assets :: proc(roots: []Root, index: ^Index, op: cook_link.Delete_Assets) -> cook_link.Operation_Result {
	paths := make([dynamic]string, context.temp_allocator)
	for guid in op.guids {
		path, found := asset_path(roots, index, guid)
		if !found {
			return not_found(index, guid)
		}
		append(&paths, path)
		if os.exists(meta_of(path)) {
			append(&paths, meta_of(path))
		}
	}
	for f in op.folders {
		if f.path == "" {
			return failed("a root cannot be deleted")
		}
		dir, error := folder_dir(roots, f.root, f.path)
		if error != "" {
			return failed("%s", error)
		}
		append(&paths, dir)
	}
	if !recycle(paths[:]) {
		return failed("cannot send %d files and folders to the Recycle Bin. A program may have one of them open.", len(paths))
	}
	for path in paths {
		if !strings.has_suffix(path, format.META_EXTENSION) {
			log.infof("cook: sent %s to the Recycle Bin", display(roots, path))
		}
	}
	return {}
}

@(private = "file")
set_import_settings :: proc(roots: []Root, index: ^Index, op: cook_link.Set_Import_Settings) -> cook_link.Operation_Result {
	path, found := asset_path(roots, index, op.guid)
	if !found {
		return not_found(index, op.guid)
	}
	entry := index.assets[op.guid]
	known := import_settings(kind_of(path))
	settings := make([]format.Meta_Setting, len(op.settings), context.temp_allocator)
	for s, i in op.settings {
		for other in op.settings[:i] {
			if other.key == s.key {
				return failed("%s is set twice", s.key)
			}
		}
		if info, ok := find_setting(known, s.key); ok {
			if !slice.contains(info.values, s.value) {
				return failed("%s must be %s", s.key, strings.join(info.values, " or ", context.temp_allocator))
			}
		} else if !slice.contains(entry.settings, cook_link.Setting{s.key, s.value}) {
			// A setting that the importer does not know stays as the .meta file has it, but is never added.
			return failed("%s has no setting %q", name_of(path), s.key)
		}
		settings[i] = {s.key, s.value}
	}
	meta_path := meta_of(path)
	old, err := os.read_entire_file(meta_path, context.temp_allocator)
	if err != nil {
		return failed("cannot read %s: %s", display(roots, meta_path), os.error_string(err))
	}
	guid, _ := format.guid_parse(op.guid)
	if !write_blob(meta_path, transmute([]byte)meta_with(guid, string(old), settings)) {
		return failed("cannot write %s", display(roots, meta_path))
	}
	log.infof("cook: changed the import settings of %s", display(roots, path))
	return {}
}

@(private = "file")
reimport :: proc(index: ^Index, op: cook_link.Reimport, force: ^map[format.Guid]bool) -> cook_link.Operation_Result {
	guids := make([dynamic]format.Guid, context.temp_allocator)
	for guid in op.guids {
		parsed, ok := format.guid_parse(guid)
		if !ok || guid not_in index.assets || index.assets[guid].parent != "" {
			return not_found(index, guid)
		}
		append(&guids, parsed)
	}
	for guid in guids {
		force[guid] = true
	}
	return {}
}

// template_text is the source of a new asset. A behaviour's class is named for its file, such as Door_Bell for
// door_bell.luau.
template_text :: proc(template: cook_link.Asset_Template, name: string) -> string {
	switch template {
	case .Script:
		return "--!strict\nlocal module = {}\n\nreturn module\n"
	case .Behaviour:
		class := class_name(name)
		return fmt.tprintf(
			"--!strict\nlocal %[0]s = Behaviour.define(\"%[0]s\", {{\n\t-- Fields, such as speed = Field.number(1), show in the properties panel.\n}})\n\nfunction %[0]s:start()\nend\n\nreturn %[0]s\n",
			class,
		)
	case .Scene:
		return "scene 1\n"
	}
	return ""
}

// class_name makes a Luau name from a file's name: each word capitalized, joined by underscores, such as Door_Bell
// for "door bell" or "door_bell".
class_name :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	start := true
	for r in name {
		if !unicode.is_letter(r) && !unicode.is_digit(r) || r > 127 {
			if !start {
				strings.write_byte(&b, '_')
			}
			start = true
			continue
		}
		if strings.builder_len(b) == 0 && unicode.is_digit(r) {
			strings.write_byte(&b, 'B')
		}
		strings.write_rune(&b, start ? unicode.to_upper(r) : r)
		start = false
	}
	class := strings.trim_right(strings.to_string(b), "_")
	return class == "" ? "Behaviour" : class
}

// valid_name is whether Windows takes a name for a file or a folder, and the scan does not skip it.
valid_name :: proc(name: string) -> bool {
	if name == "" || len(name) > 200 || name[0] == '.' || name[0] == ' ' || name[len(name) - 1] == '.' || name[len(name) - 1] == ' ' {
		return false
	}
	for r in name {
		if r < 32 || strings.contains_rune(`<>:"/\|?*`, r) {
			return false
		}
	}
	stem := name
	if dot := strings.index_byte(name, '.'); dot >= 0 {
		stem = name[:dot]
	}
	upper := strings.to_upper(strings.trim_space(stem), context.temp_allocator)
	switch upper {
	case "CON", "PRN", "AUX", "NUL":
		return false
	}
	if len(upper) == 4 && (strings.has_prefix(upper, "COM") || strings.has_prefix(upper, "LPT")) && upper[3] >= '0' && upper[3] <= '9' {
		return false
	}
	return true
}

// folder_dir is the directory of a folder of a root, which must exist. It fails on a name that is not a folder's.
@(private = "file")
folder_dir :: proc(roots: []Root, root_name, folder: string) -> (dir: string, error: string) {
	root, found := find_root(roots, root_name)
	if !found {
		return "", fmt.tprintf("there is no root %q", root_name)
	}
	if folder == "" {
		return root.dir, ""
	}
	for part in strings.split(folder, "/", context.temp_allocator) {
		if !valid_name(part) {
			return "", fmt.tprintf("%q is not a folder", folder)
		}
	}
	dir = fmt.tprintf("%s/%s", root.dir, folder)
	if !os.is_dir(dir) {
		return "", fmt.tprintf("there is no folder %s/%s", root_name, folder)
	}
	return dir, ""
}

@(private = "file")
find_root :: proc(roots: []Root, name: string) -> (Root, bool) {
	for root in roots {
		if root.name == name {
			return root, true
		}
	}
	return {}, false
}

// asset_path is an asset's source file, from the index.
@(private = "file")
asset_path :: proc(roots: []Root, index: ^Index, guid: string) -> (path: string, ok: bool) {
	entry, in_index := index.assets[guid]
	// A sub-asset lives in its file's .meta file, so the operations take the file instead.
	if !in_index || entry.parent != "" {
		return
	}
	root, root_found := find_root(roots, entry.root)
	if !root_found {
		return
	}
	return fmt.tprintf("%s/%s", root.dir, entry.path), true
}

// not_found says why an operation cannot find an asset: no asset has the GUID, or it is a sub-asset, which changes only
// with its file.
@(private = "file")
not_found :: proc(index: ^Index, guid: string) -> cook_link.Operation_Result {
	if entry, found := index.assets[guid]; found && entry.parent != "" {
		return failed("%s is part of %s, and changes with it: move, rename, duplicate, delete or re-import the file instead", entry.subasset, entry.path)
	}
	return failed("no asset has the GUID %s", guid)
}

// display is a path as the log shows it: the root's name and the path in the root, such as game/scripts/door.luau.
@(private = "file")
display :: proc(roots: []Root, path: string) -> string {
	for root in roots {
		if !strings.has_prefix(path, root.dir) {
			continue
		}
		if rest := path[len(root.dir):]; rest == "" || rest[0] == '/' {
			return fmt.tprintf("%s%s", root.name, rest)
		}
	}
	return path
}

@(private = "file")
meta_of :: proc(path: string) -> string {
	return fmt.tprintf("%s%s", path, format.META_EXTENSION)
}

@(private = "file")
name_of :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

@(private = "file")
parent_of :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	return slash < 0 ? "" : path[:slash]
}

@(private = "file")
guid_strings :: proc(guids: []format.Guid) -> []string {
	result := make([]string, len(guids), context.temp_allocator)
	for g, i in guids {
		buffer: [32]u8
		result[i] = strings.clone(format.guid_format(g, &buffer), context.temp_allocator)
	}
	return result
}
