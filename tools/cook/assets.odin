package cook

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// IMPORTERS gives the extensions of each kind of asset that the cooker cooks, lowercase, the first one for new assets.
// Other files in the content roots are not assets. A Mesh is a .mesh file of its own, or a glTF model's sub-asset,
// which has no extension. An Instance_Set is only ever a USD stage's sub-asset, and a Skin or an Animation a glTF
// model's.
IMPORTERS :: [format.Asset_Kind][]string {
	.None    = nil,
	.Script  = {SCRIPT_EXTENSION},
	.Scene   = {format.SCENE_EXTENSION},
	.Shader  = {format.SHADER_EXTENSION},
	.Texture = TEXTURE_SOURCE_EXTENSIONS,
	.Model   = MODEL_EXTENSIONS,
	.Mesh    = {format.MESH_EXTENSION},
	.Shading_Model = {format.SHADING_EXTENSION},
	.Material = {format.MATERIAL_EXTENSION},
	.Material_Instance = {format.MATERIAL_INSTANCE_EXTENSION},
	.Material_Function = {format.MATERIAL_FUNCTION_EXTENSION},
	.Prefab = {format.PREFAB_EXTENSION},
	.Effect = {format.EFFECT_EXTENSION},
	.Stage  = STAGE_EXTENSIONS,
	.Instance_Set = nil,
	.Skin = nil,
	.Animation = nil,
	.Animation_Graph = {format.ANIMATION_GRAPH_EXTENSION},
	.Audio = AUDIO_EXTENSIONS,
	.Font = format.FONT_EXTENSIONS,
	.Ui = {format.UI_EXTENSION},
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
	case .Audio:
		return AUDIO_SETTINGS
	case .Font:
		return FONT_SETTINGS
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

ALL_KINDS :: Asset_Kinds{.Script, .Scene, .Shader, .Texture, .Model, .Mesh, .Shading_Model, .Material, .Material_Instance, .Material_Function, .Prefab, .Effect, .Stage, .Animation_Graph, .Audio, .Font, .Ui}

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
	// nil until it is read: a pass reads a carried asset's source only when another asset needs it (see asset_source).
	source:       Maybe([]byte),
	// What the pass did with it. Only settle changes it.
	result:       Asset_Result,
	// Set while the pass carries it: nothing that it depends on changed, so what the last pass learnt of it stands
	// (see docs/content/daemon-and-operations.md#saved-index). Only carry_source sets it, and only uncarry clears it.
	carried:      Maybe(Carried),
	// The assets that it depends on: a script's requires, and the scripts that a scene's or a prefab's behaviours name
	// and the prefabs that it instantiates.
	dependencies: [dynamic]format.Guid,
	// For a scene or a prefab, the assets that its flat entities name: what it looks like, which its dependencies do not say.
	visual:       [dynamic]format.Guid,
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
	// The files outside the content that its key covers, as they were when it cooked: a model's buffers and a stage's
	// layers and images. A change to one puts it in a daemon's pass.
	inputs:       [dynamic]Input_Stamp,
}

// Carried is what a pass keeps of an asset that it does not look at: the problems that the last pass found in it.
Carried :: struct {
	problems: []Problem,
}

// Input_Stamp is a file as an asset's cook read it: its absolute path, its size and its modification time.
Input_Stamp :: struct {
	path:     string,
	size:     i64,
	modified: i64,
}

// source_of is an asset's source, which the pass must have read.
source_of :: proc(a: Asset_Source, loc := #caller_location) -> []byte {
	source, read := a.source.?
	assert(read, "the pass reads an asset's source before it uses it (see asset_source)", loc)
	return source
}

// asset_source is an asset's source, which it reads first if the pass has not. Only the pass's own thread calls it,
// so a parallel step reads what its jobs need before it starts.
asset_source :: proc(pass: ^Pass, index: int) -> []byte {
	a := &pass.assets[index]
	if source, read := a.source.?; read {
		return source
	}
	source, err := os.read_entire_file(a.path, context.temp_allocator)
	if err != nil {
		// The file went or cannot be read: the asset's cook then reports the problems of an empty source, and the next
		// pass, which the change starts, sees what happened to it.
		report_error(&pass.problems, a.path, 0, 0, "%v", err)
	}
	a.source = source
	append(&pass.read, a.path)
	return source
}

// uncarry makes a carried asset one that the pass looks at: what the last pass learnt of it goes, as its cook learns
// it again.
uncarry :: proc(a: ^Asset_Source) {
	a.carried = nil
	clear(&a.dependencies)
	clear(&a.visual)
	clear(&a.subassets)
	clear(&a.inputs)
	a.behaviour = ""
	a.permutations = 0
	a.size = {}
	a.tool_texture = {}
	a.hotspots = nil
}

// carry_kind settles the carried assets of some kinds, with the problems that the last pass found in them, and gives
// the others, which the kinds' pass looks at. With all_or_nothing, it carries them only when it carries every one:
// a pass that looks at one looks at all.
carry_kind :: proc(pass: ^Pass, kinds: Asset_Kinds, all_or_nothing := false) -> []int {
	if all_or_nothing {
		any_checked := false
		for a in pass.assets {
			if a.kind in kinds && a.carried == nil {
				any_checked = true
				break
			}
		}
		if any_checked {
			for &a in pass.assets {
				if a.kind in kinds && a.carried != nil {
					uncarry(&a)
				}
			}
		}
	}
	checked := make([dynamic]int, context.temp_allocator)
	for a, i in pass.assets {
		if a.kind not_in kinds {
			continue
		}
		if c, is_carried := a.carried.?; is_carried {
			if pass.problems.list == nil {
				pass.problems.list = make([dynamic]Problem, context.temp_allocator)
			}
			append(&pass.problems.list, ..c.problems)
			settle(pass, i, .Current)
		} else {
			append(&checked, i)
		}
	}
	return checked[:]
}

// Asset_Result is what a pass did with an asset. It is Pending until the pass of its kind settles it, and a pass that
// does not reach it leaves it Pending, which the index reports as failed.
Asset_Result :: enum u8 {
	Pending,
	// Its blob was up to date, or it has nothing to cook.
	Current,
	Cooked,
	// It did not cook, so it keeps its old blob, if it has one.
	Failed,
	// It did not cook, because an asset that it depends on failed.
	Blocked,
}

// asset_failed is whether an asset's result is a failure.
asset_failed :: proc(result: Asset_Result) -> bool {
	return result == .Failed || result == .Blocked
}

// settle records what the pass did with an asset, and counts it among the kind's cooked or up-to-date assets. It is
// the only writer of an asset's result, and each asset settles once in a pass.
settle :: proc(pass: ^Pass, index: int, result: Asset_Result, loc := #caller_location) {
	a := &pass.assets[index]
	assert(result != .Pending, "an asset settles with a result", loc)
	assert(a.result == .Pending, "an asset settles once in a pass", loc)
	a.result = result
	#partial switch result {
	case .Current:
		pass.current[a.kind] += 1
	case .Cooked:
		pass.cooked[a.kind] += 1
	}
}

// fail_pending settles each asset of the kinds that is still Pending as Failed: a pass that stops early has not cooked
// them.
fail_pending :: proc(pass: ^Pass, kinds: Asset_Kinds) {
	for a, i in pass.assets {
		if a.kind in kinds && a.result == .Pending {
			settle(pass, i, .Failed)
		}
	}
}

// make_output_dir makes a directory that a pass writes into. When it cannot, it reports why, and every asset of the
// kinds that is still Pending fails.
make_output_dir :: proc(pass: ^Pass, dir: string, kinds: Asset_Kinds) -> bool {
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		report_error(&pass.problems, dir, 0, 0, "%v", err)
		fail_pending(pass, kinds)
		return false
	}
	return true
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

// found_assets sorts what the scan found, and leaves out the assets that share a GUID, which it also gives.
@(private)
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
	case .Instance_Set:
		return .Instance_Set
	case .Skin:
		return .Skin
	case .Animation:
		return .Animation
	case .Animation_Graph:
		return .Animation_Graph
	case .Audio:
		return .Audio
	case .Font:
		return .Font
	case .Ui:
		return .Ui
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

@(private)
Read_Result :: enum {
	Read,
	// The asset moved or was deleted while the scan read it, so the next pass finds it where it went.
	Gone,
	Failed,
}

@(private)
read_asset :: proc(root_dir: string, a: ^Asset_Source, problems: ^Problems) -> Read_Result {
	source, err := os.read_entire_file(a.path, context.temp_allocator)
	if err != nil {
		report_error(problems, a.path, 0, 0, "%v", err)
		return .Failed
	}
	a.source = source
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	meta_bytes, meta_err := os.read_entire_file(meta_path, context.temp_allocator)
	if meta_err == .Not_Exist {
		result: Read_Result
		if meta_bytes, result = assign_guid(root_dir, a, meta_path, problems); result != .Read {
			return result
		}
	} else if meta_err != nil {
		report_error(problems, meta_path, 0, 0, "%v", meta_err)
		return .Failed
	}
	a.meta_text = string(meta_bytes)
	meta, meta_ok := format.meta_parse(a.meta_text, context.temp_allocator)
	if !meta_ok {
		report_error(problems, meta_path, 0, 0, "needs `guid = <32 hex digits>`, and `key = value` lines")
		return .Failed
	}
	a.meta = meta
	return .Read
}

// assign_guid writes the .meta file of an asset that had none, under the root's lock. Another cook, or an operation
// of the daemon's, may have written it, or moved the asset, since the scan looked, so it looks again first.
@(private = "file")
assign_guid :: proc(root_dir: string, a: ^Asset_Source, meta_path: string, problems: ^Problems) -> (meta_bytes: []byte, result: Read_Result) {
	lock, locked := lock_root(root_dir)
	if !locked {
		report_error(problems, meta_path, 0, 0, "cannot take the lock of its root to give the asset a GUID")
		return nil, .Failed
	}
	defer unlock(&lock)
	meta_err: os.Error
	if meta_bytes, meta_err = os.read_entire_file(meta_path, context.temp_allocator); meta_err == nil {
		return meta_bytes, .Read
	}
	if meta_err != .Not_Exist {
		report_error(problems, meta_path, 0, 0, "%v", meta_err)
		return nil, .Failed
	}
	if !os.exists(a.path) {
		return nil, .Gone
	}
	text, _ := new_meta(initial_settings(a.kind, a.path))
	if !write_blob(meta_path, transmute([]byte)text) {
		report_error(problems, meta_path, 0, 0, "cannot write the asset's GUID")
		return nil, .Failed
	}
	log.infof("cook: assigned a GUID to %s", a.name)
	return transmute([]byte)text, .Read
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
	case .Instance_Set:
		return format.INSTANCE_SET_KIND
	case .Skin:
		return format.SKIN_KIND
	case .Animation:
		return format.ANIMATION_KIND
	}
	return ""
}

// assign_subassets gives each sub-asset that a file makes its GUID: the one in the .meta file for its kind and name, or
// a new one, which it writes into the .meta file, and adds them to the asset's sub-assets. A line whose sub-asset is
// gone stays, with a warning, so one renamed back gets its GUID again, until a re-import drops it.
assign_subassets :: proc(root_dir: string, a: ^Asset_Source, wanted: []Subasset, force: bool, problems: ^Problems) -> bool {
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	if !subassets_changed(a.meta, wanted, force) {
		subasset_lines(a, meta_path, wanted, force, problems)
		return true
	}
	// The .meta file changes, so it is written under the root's lock, from the file as it is now: another cook may have
	// given a sub-asset its GUID, or the daemon changed an import setting, since the scan read it.
	lock, locked := lock_root(root_dir)
	if !locked {
		report_error(problems, meta_path, 0, 0, "cannot take the lock of its root to write the sub-assets' GUIDs")
		return false
	}
	defer unlock(&lock)
	data, err := os.read_entire_file(meta_path, context.temp_allocator)
	if err != nil {
		report_error(problems, meta_path, 0, 0, "%v", err)
		return false
	}
	meta, meta_ok := format.meta_parse(string(data), context.temp_allocator)
	if !meta_ok || meta.guid != a.meta.guid {
		report_error(problems, meta_path, 0, 0, "changed while the asset cooked. Cook it again.")
		return false
	}
	a.meta_text = string(data)
	a.meta = meta
	lines, changed := subasset_lines(a, meta_path, wanted, force, problems)
	if !changed {
		return true
	}
	text := meta_with(a.meta.guid, a.meta_text, a.meta.settings, lines)
	if !write_blob(meta_path, transmute([]byte)text) {
		report_error(problems, meta_path, 0, 0, "cannot write the sub-assets' GUIDs")
		return false
	}
	return true
}

// subassets_changed says whether the sub-assets need another .meta file than meta: one that meta has no GUID for, or
// a line that a re-import drops.
@(private = "file")
subassets_changed :: proc(meta: format.Meta, wanted: []Subasset, force: bool) -> bool {
	for w in wanted {
		if _, found := format.meta_subasset(meta, subasset_kind_name(w.kind), w.name); !found {
			return true
		}
	}
	if !force {
		return false
	}
	outer: for s in meta.subassets {
		for w in wanted {
			if s.kind == subasset_kind_name(w.kind) && s.name == w.name {
				continue outer
			}
		}
		return true
	}
	return false
}

// subasset_lines gives each sub-asset its GUID from the asset's .meta file, or a new one, and adds them to the asset's
// sub-assets. It returns the .meta file's sub-asset lines, and whether they changed.
@(private = "file")
subasset_lines :: proc(a: ^Asset_Source, meta_path: string, wanted: []Subasset, force: bool, problems: ^Problems) -> (lines: []format.Meta_Subasset, changed: bool) {
	result := make([dynamic]format.Meta_Subasset, 0, len(wanted), context.temp_allocator)
	current := make(map[string]bool, len(wanted), context.temp_allocator)
	for w in wanted {
		kind := subasset_kind_name(w.kind)
		guid, found := format.meta_subasset(a.meta, kind, w.name)
		if !found {
			_, guid = new_meta(nil)
			changed = true
		}
		append(&result, format.Meta_Subasset{kind, w.name, guid})
		// The pass's index reads the names after the file's parse, which they may point into, is freed.
		append(&a.subassets, Subasset{w.kind, strings.clone(w.name, context.temp_allocator), guid})
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
		append(&result, s)
	}
	return result[:], changed
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

// A running game holds a blob open for a moment when it reads it, as a stream does twice a second, and Windows refuses a
// rename over an open file. Reads are far shorter than this.
WRITE_BLOB_ATTEMPTS :: 10
WRITE_BLOB_WAIT :: 20 * time.Millisecond

// write_blob writes a blob or a .meta file to a temporary file and renames it, so no reader sees a partial file: not
// the running game a blob, nor another cook's scan or the editor a .meta file. Every .meta file that a cook writes goes
// through it.
write_blob :: proc(output: string, blob: []byte) -> bool {
	temporary := fmt.tprintf("%s.tmp", output)
	if err := os.write_entire_file(temporary, blob); err != nil {
		log.errorf("cook: %s: %v", temporary, err)
		return false
	}
	err := os.rename(temporary, output)
	for attempt := 1; err != nil && attempt < WRITE_BLOB_ATTEMPTS; attempt += 1 {
		time.sleep(WRITE_BLOB_WAIT)
		err = os.rename(temporary, output)
	}
	if err != nil {
		log.errorf("cook: %s: %v", output, err)
		return false
	}
	return true
}
