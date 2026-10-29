// Mesh files are .mesh text files: level geometry that the editor builds, as polygon faces with parametric texture
// mappings (see docs/content/kinds/meshes.md#mesh-files). A .mesh file is a Mesh asset of its own, with one blob under
// its own GUID. The cooker parses it with format.mesh_text_parse, bakes it with format.mesh_bake, which the game shares
// for the meshes it draws live, and then cooks the baked triangles as it cooks a glTF mesh's (see meshes.odin).
package cook

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strconv"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks mesh files changes this, which invalidates every cooked mesh file.
MESH_FILE_COOK_VERSION :: "mesh files 3"

MESH_SETTINGS := []Setting_Info {
	{
		key = "tangents",
		values = {"generate", "mikk"},
		default = "generate",
		description = "Take the tangents from the faces' mappings, which is exact for a planar mapping, or make MikkTSpace tangents.",
	},
	{
		key = "cluster_lod",
		values = {"true", "false"},
		default = "true",
		description = "Simplify the meshlets into a hierarchy of levels of detail, which the mesh shader path draws by distance. Without it, the meshlets are the mesh's own triangles only.",
	},
	{
		key = "collision",
		values = {"true", "false"},
		default = "true",
		description = "Write the welded triangles that a mesh collider is built from. Turn it off for a mesh that nothing collides with, to save its size.",
	},	{
		key = "impostor",
		values = {"true", "false"},
		default = "false",
		description = "Bake an octahedral impostor: views of the mesh from all around, which draw as one quad past its coarsest level of detail.",
	},
	{
		key = "impostor_size",
		values = {"32", "64", "128"},
		default = "64",
		description = "The side of each of the impostor's views in texels. The impostor takes over where a texel is too small to show.",
	},
}

// cook_mesh_files cooks the mesh files among the assets whose keys changed. It parses every one, also one that is up
// to date, so its problems are known at every cook. It reports every failure, and returns false if any.
cook_mesh_files :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	meshes := assets_of(assets, .Mesh)
	if len(meshes) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	ok := true
	for i in meshes {
		if !cook_mesh_file(options, &assets[i], out_dir, pass) {
			assets[i].failed = true
			ok = false
		}
	}
	return ok
}

@(private = "file")
cook_mesh_file :: proc(
	options: Cook_Options,
	a: ^Asset_Source,
	out_dir: string,
	pass: ^Pass,
) -> bool {
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	mesh, parsed, parsed_ok := format.mesh_text_parse(string(a.source), context.temp_allocator)
	for p in parsed {
		if p.error {
			report_error(problems, a.path, p.line, 0, "%s", p.message)
		} else {
			report_warning(problems, a.path, p.line, 0, "%s", p.message)
		}
	}
	// A mesh with errors keeps its old blob, so the running game keeps the last good version.
	if !parsed_ok || !settings_ok {
		return false
	}
	key := mesh_file_key(a^)
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(a.meta.guid, &buffer))
	if cooked_key(output, .Mesh, format.mesh_layout()) == key && !pass.force[a.meta.guid] {
		pass.current[.Mesh] += 1
		return true
	}
	bake := format.mesh_bake(mesh, context.temp_allocator)
	for p in bake.problems {
		report_warning(problems, a.path, p.line, 0, "%s", p.message)
	}
	if len(bake.indices) == 0 {
		report_error(problems, a.path, 0, 0, "has no faces that bake")
		return false
	}
	blob := finish_mesh(baked_mesh(a^, bake), a.meta.guid, key)
	if !write_blob(output, blob) {
		return false
	}
	pass.cooked[.Mesh] += 1
	return true
}

// baked_mesh is a bake as finish_mesh takes it: its triangles as corners, in the bake's submesh order, which is slot
// order. A submesh's name is its slot's number, since a mesh file names its slots by number.
@(private = "file")
baked_mesh :: proc(a: Asset_Source, bake: format.Mesh_Bake) -> Cook_Mesh {
	corners := make([]Vertex, len(bake.indices), context.temp_allocator)
	for index, i in bake.indices {
		v := bake.vertices[index]
		corners[i] = {
			position = v.position,
			normal   = v.normal,
			tangent  = v.tangent,
			uv0      = v.uv,
			color    = {1, 1, 1, 1},
		}
	}
	ranges := make([][2]int, len(bake.submeshes), context.temp_allocator)
	names := make([]string, len(bake.submeshes), context.temp_allocator)
	for s, i in bake.submeshes {
		ranges[i] = {int(s.first_index), int(s.first_index + s.index_count)}
		names[i] = fmt.tprintf("%d", i)
	}
	return {
		corners = corners,
		ranges = ranges,
		names = names,
		generate_tangents = mesh_file_setting(a, "tangents") == "mikk",
		lod = mesh_file_setting(a, "cluster_lod") == "true",
		collision = mesh_file_setting(a, "collision") == "true",
		impostor_size = mesh_file_setting(a, "impostor") == "true" ? (strconv.parse_int(mesh_file_setting(a, "impostor_size")) or_else 64) : 0,
		name = filepath.stem(a.path),
		source_path = a.name,
	}
}

// mesh_file_setting is an import setting's value, or its default.
@(private = "file")
mesh_file_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(MESH_SETTINGS, key)
	return info.default
}

// mesh_file_key covers what the blob depends on: the cooker, meshoptimizer, the path, the source, the GUID and the
// settings.
@(private = "file")
mesh_file_key :: proc(a: Asset_Source) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%s\x00%x\x00",
			MESH_FILE_COOK_VERSION,
			MESHOPTIMIZER_VERSION,
			a.name,
			format.mesh_layout(),
		),
	)
	key = hash.fnv64a(a.source, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	for s in a.meta.settings {
		key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s=%s\x00", s.key, s.value), key)
	}
	return key
}

// MESH_TEMPLATE is a new mesh file: a 1 m box on the origin's corner, each face clockwise from its front with a
// world-aligned mapping at one repeat per meter, so the texture's lines meet across its faces on the grid. The editor's
// Block tool makes the same box (see docs/editor/mesh-editing.md#primitives-and-draw).
MESH_TEMPLATE :: `mesh 1
v 0 0 0
v 1 0 0
v 1 0 1
v 0 0 1
v 0 1 0
v 1 1 0
v 1 1 1
v 0 1 1
f 0 0 1 2 3
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 4 7 6 5
map 1 0 0 0 0 -1 1 1 0 0 0
f 0 0 4 5 1
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 2 6 7 3
map 1 0 0 0 -1 0 1 1 0 0 0
f 0 3 7 4 0
map 0 0 1 0 -1 0 1 1 0 0 0
f 0 1 5 6 2
map 0 0 1 0 -1 0 1 1 0 0 0
e 0 1 sharp
e 1 2 sharp
e 2 3 sharp
e 3 0 sharp
e 4 5 sharp
e 5 6 sharp
e 6 7 sharp
e 7 4 sharp
e 0 4 sharp
e 1 5 sharp
e 2 6 sharp
e 3 7 sharp
`
