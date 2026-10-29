package cook

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// IMPORTERS gives the extensions of each kind of asset that the cooker cooks, lowercase, the first one for new assets.
// Other files in the content roots are not assets. A Mesh is a .mesh file of its own, or a glTF model's sub-asset,
// which has no extension.
IMPORTERS :: [format.Asset_Kind][]string {
	.None    = nil,
	.Script  = {SCRIPT_EXTENSION},
	.Scene   = {format.SCENE_EXTENSION},
	.Shader  = {format.SHADER_EXTENSION},
	.Texture = TEXTURE_EXTENSIONS,
	.Model   = MODEL_EXTENSIONS,
	.Mesh    = {format.MESH_EXTENSION},
	.Shading_Model = {format.SHADING_EXTENSION},
	.Material = {format.MATERIAL_EXTENSION},
	.Material_Instance = {format.MATERIAL_INSTANCE_EXTENSION},
	.Material_Function = {format.MATERIAL_FUNCTION_EXTENSION},
	.Prefab = {format.PREFAB_EXTENSION},
	.Effect = {format.EFFECT_EXTENSION},
	.Stage  = STAGE_EXTENSIONS,
}

// Setting_Info is an import setting that an importer knows: the values that it takes, and the value of an asset that
// does not set it. The cooker checks .meta files with it, and the editor shows it (see cook_link.Setting_Info).
Setting_Info :: struct {
	key:         string,
	values:      []string,
	default:     string,
	description: string,
}

SCRIPT_SETTINGS := []Setting_Info {
	{
		key = "native",
		values = {"true", "false"},
		default = "false",
		description = "Compile the module to machine code at load, like a --!native comment at the top of the source.",
	},
}

// import_settings is the import settings that a kind of asset takes.
import_settings :: proc(kind: format.Asset_Kind) -> []Setting_Info {
	#partial switch kind {
	case .Script:
		return SCRIPT_SETTINGS
	case .Texture:
		return TEXTURE_SETTINGS
	case .Model:
		return MODEL_SETTINGS
	case .Mesh:
		return MESH_SETTINGS
	case .Stage:
		return STAGE_SETTINGS
	}
	return nil
}

// initial_settings are the import settings that the cooker writes in a new asset's .meta file: those that it guesses
// from the file, which then stay as they are when the file is renamed.
initial_settings :: proc(kind: format.Asset_Kind, path: string) -> []format.Meta_Setting {
	#partial switch kind {
	case .Texture:
		settings := make([]format.Meta_Setting, 1, context.temp_allocator)
		settings[0] = {"usage", texture_usage_for(path)}
		return settings
	}
	return nil
}

find_setting :: proc(settings: []Setting_Info, key: string) -> (Setting_Info, bool) {
	for s in settings {
		if s.key == key {
			return s, true
		}
	}
	return {}, false
}

// check_settings checks an asset's import settings with its importer. An unknown setting is a warning, and a value
// that the setting does not take is an error.
check_settings :: proc(a: Asset_Source, problems: ^Problems) -> bool {
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	ok := true
	for setting in a.meta.settings {
		info, known := find_setting(import_settings(a.kind), setting.key)
		if !known {
			report_warning(problems, meta_path, 0, 0, "unknown setting %q", setting.key)
		} else if !slice.contains(info.values, setting.value) {
			report_error(problems, meta_path, 0, 0, "%s must be %s", setting.key, strings.join(info.values, " or ", context.temp_allocator))
			ok = false
		}
	}
	return ok
}

Asset_Kinds :: bit_set[format.Asset_Kind]

ALL_KINDS :: Asset_Kinds{.Script, .Scene, .Shader, .Texture, .Model, .Mesh, .Shading_Model, .Material, .Material_Instance, .Material_Function, .Prefab, .Effect, .Stage}

// Asset_Source is a source asset with its .meta file. A cook fills in what it learns of the asset, for the daemon's
// index.
Asset_Source :: struct {
	kind:         format.Asset_Kind,
	root:         int,
	// Absolute, with forward slashes.
	path:         string,
	// The root's name and the path relative to the root, such as "game/scripts/hello.luau".
	name:         string,
	meta_text:    string,
	meta:         format.Meta,
	source:       []byte,
	// The cook could not cook it, so it keeps its old blob.
	failed:       bool,
	// The assets that it depends on: a script's requires, and the scripts that a scene's or a prefab's behaviours name
	// and the prefabs that it instantiates.
	dependencies: [dynamic]format.Guid,
	// For a script that defines a behaviour, the class's name.
	behaviour:    string,
	// The sub-assets that the cook made of it, such as a model's meshes (see docs/content/identity-and-cooking.md#identity).
	subassets:    [dynamic]Subasset,
	// For a material, the combinations of static switches that it and its instances use.
	permutations: int,
	// For a texture, its cooked size, from its blob. For a material or an instance, the texture that the editor's
	// texture tools measure by, and the material's hotspot rectangles in its texels, each x0 y0 x1 y1.
	size:         [2]u32,
	tool_texture: format.Guid,
	hotspots:     [][4]u32,
	// For a source that a stage generates, such as its prefab, the stage's GUID: it is not a file of its own, and its
	// meta is only its GUID (see stages.odin).
	owner:        format.Guid,
}

// Subasset is an asset that a source file makes, with its own GUID from the file's .meta file and its own blob.
Subasset :: struct {
	kind: format.Asset_Kind,
	name: string,
	guid: format.Guid,
}

// Folder is a directory in a root, by the root's index and its path in the root, such as "scripts/ui".
Folder :: struct {
	root: int,
	path: string,
}

// scan reads every asset in the roots, with its .meta file, in path order, and lists the folders. An asset without a
// .meta file gets a new GUID, and the cooker writes its .meta file. A .meta file without its asset, as when Explorer
// or git moves a source without it, is a warning. Files and directories whose names start with a dot are skipped.
scan :: proc(roots: []Root, problems: ^Problems) -> (assets: []Asset_Source, folders: []Folder, shared: []format.Guid, ok: bool) {
	found := make([dynamic]Asset_Source, context.temp_allocator)
	found_folders := make([dynamic]Folder, context.temp_allocator)
	ok = true
	for root, root_index in roots {
		// os.walker leaves the last directory that it reads open, which stops a rename or a delete of it, so the scan
		// reads each directory itself.
		todo := make([dynamic]string, context.temp_allocator)
		append(&todo, root.dir)
		for len(todo) > 0 {
			dir := pop(&todo)
			infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
			if err != nil {
				report_error(problems, forward_slashes(dir), 0, 0, "%v", err)
				ok = false
				continue
			}
			for info in infos {
				if strings.has_prefix(info.name, ".") {
					continue
				}
				if info.type == .Directory {
					append(&todo, info.fullpath)
				}
				if !found_entry(root, root_index, info, &found, &found_folders, problems) {
					ok = false
				}
			}
		}
	}
	return found_assets(found[:], found_folders[:], problems, ok)
}

// found_assets sorts what the scan found, and leaves out the assets that share a GUID, which it also gives.

// found_entry adds a file or a directory that the scan found to what it found.
@(private = "file")
found_entry :: proc(
	root: Root,
	root_index: int,
	info: os.File_Info,
	found: ^[dynamic]Asset_Source,
	found_folders: ^[dynamic]Folder,
	problems: ^Problems,
) -> bool {
	if info.type == .Directory {
		path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
		append(found_folders, Folder{root_index, strings.trim_prefix(path, fmt.tprintf("%s/", root.dir))})
		return true
	}
	kind := kind_of(info.name)
	if info.type == .Regular && strings.has_suffix(info.name, format.META_EXTENSION) {
		meta_path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
		if !os.exists(strings.trim_suffix(meta_path, format.META_EXTENSION)) {
			report_warning(problems, meta_path, 0, 0, "has no asset next to it. Move it to its asset, which then keeps its GUID, or delete it.")
		}
		return true
	}
	if info.type != .Regular || kind == .None {
		return true
	}
	path := forward_slashes(strings.clone(info.fullpath, context.temp_allocator))
	a := Asset_Source {
		kind = kind,
		root = root_index,
		path = path,
		name = fmt.tprintf("%s/%s", root.name, strings.trim_prefix(path, fmt.tprintf("%s/", root.dir))),
		dependencies = make([dynamic]format.Guid, context.temp_allocator),
		subassets = make([dynamic]Subasset, context.temp_allocator),
	}
	if !read_asset(&a, problems) {
		return false
	}
	append(found, a)
	return true
}

@(private = "file")
found_assets :: proc(
	found: []Asset_Source,
	found_folders: []Folder,
	problems: ^Problems,
	scanned: bool,
) -> (
	assets: []Asset_Source,
	folders: []Folder,
	shared_guids: []format.Guid,
	ok: bool,
) {
	ok = scanned
	slice.sort_by(found[:], proc(a, b: Asset_Source) -> bool {return a.path < b.path})
	// Assets that share a GUID would write the same blob, so none of them cooks. A sub-asset's GUID counts as its
	// file's.
	first := make(map[format.Guid]int, len(found), context.temp_allocator)
	shared := make(map[format.Guid]bool, context.temp_allocator)
	for a, i in found {
		guids := make([dynamic]format.Guid, 0, 1 + len(a.meta.subassets), context.temp_allocator)
		append(&guids, a.meta.guid)
		for s in a.meta.subassets {
			append(&guids, s.guid)
		}
		for guid in guids {
			if j, seen := first[guid]; seen {
				report_error(problems, a.path, 0, 0, "has the same GUID as %s. Delete the .meta file of the copy.", found[j].path)
				shared[guid] = true
				ok = false
				continue
			}
			first[guid] = i
		}
	}
	unique := make([dynamic]Asset_Source, 0, len(found), context.temp_allocator)
	outer: for a in found {
		if shared[a.meta.guid] {
			continue
		}
		for s in a.meta.subassets {
			if shared[s.guid] {
				continue outer
			}
		}
		append(&unique, a)
	}
	slice.sort_by(found_folders[:], proc(a, b: Folder) -> bool {return a.root < b.root || (a.root == b.root && a.path < b.path)})
	keys, _ := slice.map_keys(shared, context.temp_allocator)
	return unique[:], found_folders[:], keys, ok
}

// kind_of is the kind of asset that a file name is, or .None.
kind_of :: proc(name: string) -> format.Asset_Kind {
	kind, _ := importer_of(name)
	return kind
}

// extension_in is the importer's extension that a file name ends in, as the name has it, such as ".PNG", or "".
extension_in :: proc(name: string) -> string {
	_, extension := importer_of(name)
	return extension
}

@(private = "file")
importer_of :: proc(name: string) -> (kind: format.Asset_Kind, extension: string) {
	lower := strings.to_lower(name, context.temp_allocator)
	for extensions, k in IMPORTERS {
		for e in extensions {
			if strings.has_suffix(lower, e) {
				return k, name[len(name) - len(e):]
			}
		}
	}
	return .None, ""
}

// extension_of is the extension of a kind of asset's new sources, such as ".luau".
extension_of :: proc(kind: format.Asset_Kind) -> string {
	importers := IMPORTERS
	return importers[kind][0] if len(importers[kind]) > 0 else ""
}

// link_kind is a kind of asset as the cook link names it.
link_kind :: proc(kind: format.Asset_Kind) -> cook_link.Asset_Kind {
	#partial switch kind {
	case .Scene:
		return .Scene
	case .Shader:
		return .Shader
	case .Texture:
		return .Texture
	case .Model:
		return .Model
	case .Mesh:
		return .Mesh
	case .Shading_Model:
		return .Shading_Model
	case .Material:
		return .Material
	case .Material_Instance:
		return .Material_Instance
	case .Material_Function:
		return .Material_Function
	case .Prefab:
		return .Prefab
	case .Effect:
		return .Effect
	case .Stage:
		return .Stage
	}
	return .Script
}

// assets_of is the indices of the assets of one kind, in the scan's order.
assets_of :: proc(assets: []Asset_Source, kind: format.Asset_Kind) -> []int {
	result := make([dynamic]int, context.temp_allocator)
	for a, i in assets {
		if a.kind == kind {
			append(&result, i)
		}
	}
	return result[:]
}

@(private = "file")
read_asset :: proc(a: ^Asset_Source, problems: ^Problems) -> bool {
	source, err := os.read_entire_file(a.path, context.temp_allocator)
	if err != nil {
		report_error(problems, a.path, 0, 0, "%v", err)
		return false
	}
	a.source = source
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	meta_bytes, meta_err := os.read_entire_file(meta_path, context.temp_allocator)
	if meta_err == .Not_Exist {
		text, _ := new_meta(initial_settings(a.kind, a.path))
		if write_err := os.write_entire_file(meta_path, transmute([]byte)text); write_err != nil {
			report_error(problems, meta_path, 0, 0, "%v", write_err)
			return false
		}
		log.infof("cook: assigned a GUID to %s", a.name)
		meta_bytes = transmute([]byte)text
	} else if meta_err != nil {
		report_error(problems, meta_path, 0, 0, "%v", meta_err)
		return false
	}
	a.meta_text = string(meta_bytes)
	meta, meta_ok := format.meta_parse(a.meta_text, context.temp_allocator)
	if !meta_ok {
		report_error(problems, meta_path, 0, 0, "needs `guid = <32 hex digits>`, and `key = value` lines")
		return false
	}
	a.meta = meta
	return true
}

// new_meta is the text of a .meta file with a new GUID and import settings.
new_meta :: proc(settings: []format.Meta_Setting) -> (text: string, guid: format.Guid) {
	crypto.rand_bytes(guid[:])
	return meta_with(guid, "", settings), guid
}

// meta_with is the text of a .meta file with a GUID, import settings and sub-assets. It keeps the comments of an old
// .meta file, or starts with one that says what the file is. With no sub-assets given, it keeps the old file's.
meta_with :: proc(guid: format.Guid, old_text: string, settings: []format.Meta_Setting, subassets: Maybe([]format.Meta_Subasset) = nil) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := old_text
	for line in strings.split_lines_iterator(&rest) {
		if trimmed := strings.trim_space(line); strings.has_prefix(trimmed, "#") {
			fmt.sbprintln(&b, trimmed)
		}
	}
	if strings.builder_len(b) == 0 {
		fmt.sbprintln(&b, "# cinnabar asset metadata. Keep this file next to its asset (see docs/content/identity-and-cooking.md#identity).")
	}
	buffer: [32]u8
	fmt.sbprintfln(&b, "guid = %s", format.guid_format(guid, &buffer))
	for s in settings {
		fmt.sbprintfln(&b, "%s = %s", s.key, s.value)
	}
	lines, given := subassets.?
	if !given {
		old, _ := format.meta_parse(old_text, context.temp_allocator)
		lines = old.subassets
	}
	for s in lines {
		fmt.sbprintfln(&b, "%s.%s = %s", s.kind, s.name, format.guid_format(s.guid, &buffer))
	}
	return strings.to_string(b)
}

// subasset_kind_name is the name that a kind of sub-asset has in .meta files, such as "mesh".
subasset_kind_name :: proc(kind: format.Asset_Kind) -> string {
	#partial switch kind {
	case .Mesh:
		return format.MESH_KIND
	case .Texture:
		return format.TEXTURE_KIND
	case .Material_Instance:
		return format.MATERIAL_INSTANCE_KIND
	case .Prefab:
		return format.PREFAB_KIND
	}
	return ""
}

// assign_subassets gives each sub-asset that a file makes its GUID: the one in the .meta file for its kind and name, or
// a new one, which it writes into the .meta file, and adds them to the asset's sub-assets. A line whose sub-asset is
// gone stays, with a warning, so one renamed back gets its GUID again, until a re-import drops it.
assign_subassets :: proc(a: ^Asset_Source, wanted: []Subasset, force: bool, problems: ^Problems) -> bool {
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	lines := make([dynamic]format.Meta_Subasset, 0, len(wanted), context.temp_allocator)
	current := make(map[string]bool, len(wanted), context.temp_allocator)
	changed := false
	for w in wanted {
		kind := subasset_kind_name(w.kind)
		guid, found := format.meta_subasset(a.meta, kind, w.name)
		if !found {
			_, guid = new_meta(nil)
			changed = true
		}
		append(&lines, format.Meta_Subasset{kind, w.name, guid})
		append(&a.subassets, Subasset{w.kind, w.name, guid})
		current[fmt.tprintf("%s.%s", kind, w.name)] = true
	}
	for s in a.meta.subassets {
		if current[fmt.tprintf("%s.%s", s.kind, s.name)] {
			continue
		}
		if force {
			changed = true
			continue
		}
		report_warning(problems, meta_path, 0, 0, "%s.%s is no longer in the file. Its GUID stays here until the file is re-imported.", s.kind, s.name)
		append(&lines, s)
	}
	if !changed {
		return true
	}
	text := meta_with(a.meta.guid, a.meta_text, a.meta.settings, lines[:])
	if !write_blob(meta_path, transmute([]byte)text) {
		report_error(problems, meta_path, 0, 0, "cannot write the sub-assets' GUIDs")
		return false
	}
	return true
}

// cooked_key reads the key of a cooked blob. It returns 0 if there is none, or if the blob is of another kind or from
// a cooker with other blob structures.
cooked_key :: proc(output: string, kind: format.Asset_Kind, layout: u64) -> u64 {
	f, open_err := os.open(output)
	if open_err != nil {
		return 0
	}
	defer os.close(f)
	header: format.Blob_Header
	n, read_err := os.read(f, ([^]byte)(&header)[:size_of(header)])
	if read_err != nil || n < size_of(header) {
		return 0
	}
	if header.magic != format.BLOB_MAGIC || header.kind != kind || header.layout != layout {
		return 0
	}
	return header.key
}

// write_blob writes a blob to a temporary file and renames it, so the running game never reads a partial blob.
write_blob :: proc(output: string, blob: []byte) -> bool {
	temporary := fmt.tprintf("%s.tmp", output)
	if err := os.write_entire_file(temporary, blob); err != nil {
		log.errorf("cook: %s: %v", temporary, err)
		return false
	}
	if err := os.rename(temporary, output); err != nil {
		log.errorf("cook: %s: %v", output, err)
		return false
	}
	return true
}
