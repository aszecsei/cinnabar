package cook

import "core:fmt"
import "core:hash"
import "core:path/filepath"

import format "cinnabar:engine/asset/format"

// Instance sets are .instances text files: the poses that an Instanced_Mesh_Renderer draws its mesh at (see
// docs/content/kinds/instance-sets.md). The cooker packs each pose as an instance, sorts them into cells and writes an
// Instance_Set blob, as it does for a USD point instancer (see stages.odin).
INSTANCE_SET_COOK_VERSION :: "instance sets 1"

cook_instance_sets :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	sets := carry_kind(pass, {.Instance_Set})
	if len(sets) > 0 && !make_output_dir(pass, out_dir, {.Instance_Set}) {
		return false
	}
	ok := true
	step_begin(pass, .Instance_Set, "", len(sets))
	for i in sets {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_instance_set(&assets[i], out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

@(private = "file")
instance_set_key :: proc(a: Asset_Source) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%x\x00",
			INSTANCE_SET_COOK_VERSION,
			a.name,
			format.instance_set_layout(),
		),
	)
	key = hash.fnv64a(source_of(a), key)
	guid := a.meta.guid
	return hash.fnv64a(guid[:], key)
}

@(private = "file")
cook_instance_set :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> Asset_Result {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	poses, found := format.instances_text_parse(string(source_of(a^)), context.temp_allocator)
	for p in found {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// An instance set with errors keeps its old blob, so the running game keeps the last good version.
	if len(found) > 0 || !settings_ok {
		return .Failed
	}
	key := instance_set_key(a^)
	guid := a.meta.guid
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	if cooked_key(output, .Instance_Set, format.instance_set_layout()) == key &&
	   !pass.force[guid] {
		return .Current
	}
	instances := make([]format.Instance, len(poses), context.temp_allocator)
	for pose, i in poses {
		instances[i] = format.instance_pack(pose, u32(i))
	}
	contents := format.instance_cells(instances, context.temp_allocator)
	contents.guid, contents.key = guid, key
	contents.name, contents.source_path = filepath.stem(a.path), a.name
	if !write_blob(output, format.instance_set_write(contents, context.temp_allocator)) {
		return .Failed
	}
	return .Cooked
}
