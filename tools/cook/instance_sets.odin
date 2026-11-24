package cook

import "core:path/filepath"

import format "cinnabar:engine/asset/format"

// Instance sets are .instances text files: the poses that an Instanced_Mesh_Renderer draws its mesh at (see
// docs/content/kinds/instance-sets.md). The cooker packs each pose as an instance, sorts them into cells and writes an
// Instance_Set blob, as it does for a USD point instancer (see stages.odin).
INSTANCE_SET_COOK_VERSION :: "instance sets 1"

cook_instance_sets :: proc(options: Cook_Options, pass: ^Pass) -> bool {
	return cook_text_kind(options, pass, instance_set_text_cook(), nil, instance_set_step)
}

instance_set_text_cook :: proc() -> Text_Cook {
	return {.Instance_Set, INSTANCE_SET_COOK_VERSION, format.instance_set_layout()}
}

@(private = "file")
instance_set_step :: proc(a: ^Asset_Source, key: u64, _: rawptr, pass: ^Pass) -> ([]byte, bool) {
	poses, found := format.instances_text_parse(string(source_of(a^)), context.temp_allocator)
	for p in found {
		report_error(&pass.problems, a.path, p.line, 0, "%s", p.message)
	}
	if len(found) > 0 {
		return nil, false
	}
	instances := make([]format.Instance, len(poses), context.temp_allocator)
	for pose, i in poses {
		instances[i] = format.instance_pack(pose, u32(i))
	}
	contents := format.instance_cells(instances, context.temp_allocator)
	contents.guid, contents.key = a.meta.guid, key
	contents.name, contents.source_path = filepath.stem(a.path), a.name
	return format.instance_set_write(contents, context.temp_allocator), true
}
