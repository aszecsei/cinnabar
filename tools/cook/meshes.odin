// Models are .gltf and .glb files, read with cgltf. A model is a file of meshes: each glTF mesh is a Mesh sub-asset,
// in its own space, or with combine = true the whole default scene is one. The cooker converts them to the engine's
// axes, welds and orders their vertices, and builds their meshlets and the meshlets' LOD hierarchy with meshoptimizer
// (see meshoptimizer.odin). See docs/content/kinds/meshes.md#meshes.
package cook

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "vendor:cgltf"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks models changes this, which invalidates every cooked mesh.
MODEL_COOK_VERSION :: "models 3"
MODEL_EXTENSIONS :: []string{".gltf", ".glb"}
// How much meshoptimizer weighs a meshlet's normal cone against its size, without cluster_lod: some, so culling by cone
// works.
MESHLET_CONE_WEIGHT :: 0.25
// How much simplification weighs each component of the normal against the positions, as meshoptimizer's demo does.
LOD_NORMAL_WEIGHT :: 0.5

MODEL_SETTINGS := []Setting_Info {
	{
		key = "combine",
		values = {"true", "false"},
		default = "false",
		description = "Make one mesh of the whole default scene, with its node transforms baked in, instead of a mesh for each glTF mesh.",
	},
	{
		key = "scale",
		values = {"0.001", "0.01", "0.0254", "0.1", "1", "10", "100"},
		default = "1",
		description = "Scale the meshes: 0.01 for a file in centimeters, 0.0254 for inches.",
	},
	{
		key = "tangents",
		values = {"file", "generate"},
		default = "file",
		description = "Take the tangents from the file, or make MikkTSpace tangents. A primitive without tangents always gets made ones.",
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

// Vertex is a mesh's vertex while it cooks: every attribute in f32, in the engine's axes.
@(private)
Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	// xyz, and the bitangent's sign in w.
	tangent:  [4]f32,
	uv0:      [2]f32,
	uv1:      [2]f32,
	color:    [4]f32,
}

// Model_Mesh is one mesh that a model makes: its glTF primitives, each with the transform that places it.
@(private = "file")
Model_Mesh :: struct {
	name:  string,
	parts: [dynamic]Model_Part,
}

@(private = "file")
Model_Part :: struct {
	primitive: ^cgltf.primitive,
	transform: matrix[4, 4]f32,
}

// cook_models cooks the models among the assets whose keys changed, and gives each mesh a GUID in its model's .meta
// file. A model whose meshes do not all cook keeps every old blob. It reports every failure, and returns false if any.
cook_models :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	models := assets_of(assets, .Model)
	if len(models) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	ok := true
	for i in models {
		if !cook_model(options, &assets[i], out_dir, pass) {
			assets[i].failed = true
			ok = false
		}
	}
	return ok
}

@(private = "file")
cook_model :: proc(options: Cook_Options, a: ^Asset_Source, out_dir: string, pass: ^Pass) -> bool {
	problems := &pass.problems
	if !check_settings(a^, problems) {
		return false
	}
	gltf_options: cgltf.options
	data, result := cgltf.parse(gltf_options, raw_data(a.source), uint(len(a.source)))
	if result != .success {
		report_error(problems, a.path, 0, 0, "cannot read the glTF file: %v", result)
		return false
	}
	defer cgltf.free(data)

	combine := model_setting(a^, "combine") == "true"
	meshes := model_meshes(data, combine, filepath.stem(a.path))
	if len(meshes) == 0 {
		report_warning(problems, a.path, 0, 0, "has no meshes")
	}
	force := pass.force[a.meta.guid]
	assign_subassets(a, meshes, force, problems) or_return

	key, key_ok := model_key(options, a^, data, problems)
	if !key_ok {
		return false
	}
	current := !force
	for s in a.subassets {
		buffer: [32]u8
		output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(s.guid, &buffer))
		current &&= cooked_key(output, .Mesh, format.mesh_layout()) == key
	}
	if current {
		pass.current[.Model] += 1
		return true
	}

	path := strings.clone_to_cstring(a.path, context.temp_allocator)
	if result = cgltf.load_buffers(gltf_options, data, path); result != .success {
		report_error(problems, a.path, 0, 0, "cannot load the glTF file's buffers: %v", result)
		return false
	}
	// Every mesh cooks before any blob is written, so a model never has some new meshes and some old.
	blobs := make([][]byte, len(meshes), context.temp_allocator)
	for m, i in meshes {
		blob, built := build_mesh(a^, m, a.subassets[i].guid, key, problems)
		if !built {
			return false
		}
		blobs[i] = blob
	}
	for blob, i in blobs {
		buffer: [32]u8
		if !write_blob(fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(a.subassets[i].guid, &buffer)), blob) {
			return false
		}
	}
	pass.cooked[.Model] += 1
	pass.cooked[.Mesh] += len(blobs)
	return true
}

// model_setting is an import setting's value, or its default.
@(private = "file")
model_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(MODEL_SETTINGS, key)
	return info.default
}

// model_meshes lists the meshes that a model makes. Without combine, each glTF mesh is one, named for itself, else for
// the first node that uses it, else for its index. Names are made unique with a number.
@(private = "file")
model_meshes :: proc(data: ^cgltf.data, combine: bool, stem: string) -> []Model_Mesh {
	result := make([dynamic]Model_Mesh, context.temp_allocator)
	if combine {
		m := Model_Mesh{name = stem, parts = make([dynamic]Model_Part, context.temp_allocator)}
		roots: []^cgltf.node
		switch {
		case data.scene != nil:
			roots = data.scene.nodes
		case len(data.scenes) > 0:
			roots = data.scenes[0].nodes
		case:
			// A file without scenes: every node without a parent.
			found := make([dynamic]^cgltf.node, context.temp_allocator)
			for &n in data.nodes {
				if n.parent == nil {
					append(&found, &n)
				}
			}
			roots = found[:]
		}
		add :: proc(m: ^Model_Mesh, node: ^cgltf.node) {
			if node.mesh != nil {
				world: [16]f32
				cgltf.node_transform_world(node, &world[0])
				for &p in node.mesh.primitives {
					append(&m.parts, Model_Part{&p, transmute(matrix[4, 4]f32)world})
				}
			}
			for child in node.children {
				add(m, child)
			}
		}
		for root in roots {
			add(&m, root)
		}
		if len(m.parts) > 0 {
			append(&result, m)
		}
		return result[:]
	}
	used := make(map[string]int, context.temp_allocator)
	for &mesh, i in data.meshes {
		name := string(mesh.name)
		if name == "" {
			for &n in data.nodes {
				if n.mesh == &mesh && n.name != nil {
					name = string(n.name)
					break
				}
			}
		}
		if name == "" {
			name = fmt.tprintf("mesh_%d", i)
		}
		// Names are keys in the .meta file, so they are on one line and have no '='.
		name, _ = strings.replace_all(strings.trim_space(name), "=", "_", context.temp_allocator)
		name, _ = strings.replace_all(name, "\n", " ", context.temp_allocator)
		if n := used[name]; n > 0 {
			used[name] = n + 1
			name = fmt.tprintf("%s_%d", name, n + 1)
		} else {
			used[name] = 1
		}
		m := Model_Mesh{name = name, parts = make([dynamic]Model_Part, context.temp_allocator)}
		for &p in mesh.primitives {
			append(&m.parts, Model_Part{&p, linalg.MATRIX4F32_IDENTITY})
		}
		append(&result, m)
	}
	return result[:]
}

// assign_subassets gives each mesh its GUID: the one in the .meta file for its name, or a new one, which it writes into
// the .meta file. A line whose mesh is gone stays, with a warning, so a mesh renamed back gets its GUID again, until a
// re-import drops it.
@(private = "file")
assign_subassets :: proc(a: ^Asset_Source, meshes: []Model_Mesh, force: bool, problems: ^Problems) -> bool {
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	lines := make([dynamic]format.Meta_Subasset, context.temp_allocator)
	changed := false
	for m in meshes {
		guid, found := format.meta_subasset(a.meta, format.MESH_KIND, m.name)
		if !found {
			_, guid = new_meta(nil)
			changed = true
		}
		append(&lines, format.Meta_Subasset{format.MESH_KIND, m.name, guid})
		append(&a.subassets, Subasset{.Mesh, m.name, guid})
	}
	for s in a.meta.subassets {
		current := false
		for m in meshes {
			current ||= s.kind == format.MESH_KIND && s.name == m.name
		}
		if current {
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
		report_error(problems, meta_path, 0, 0, "cannot write the meshes' GUIDs")
		return false
	}
	return true
}

// model_key covers what the meshes depend on: the cooker, meshoptimizer, the path, the source, the GUID and the
// settings, and the buffer files that a .gltf file names. The sub-asset lines of the .meta file are not in it, because
// the cooker writes them: a mesh's GUID is its blob's name instead.
@(private = "file")
model_key :: proc(options: Cook_Options, a: Asset_Source, data: ^cgltf.data, problems: ^Problems) -> (key: u64, ok: bool) {
	key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%s\x00%x\x00", MODEL_COOK_VERSION, MESHOPTIMIZER_VERSION, a.name, format.mesh_layout()))
	key = hash.fnv64a(a.source, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	for s in a.meta.settings {
		key = hash.fnv64a(transmute([]byte)fmt.tprintf("%s=%s\x00", s.key, s.value), key)
	}
	for b in data.buffers {
		uri := string(b.uri)
		if uri == "" || strings.has_prefix(uri, "data:") {
			continue
		}
		path := fmt.tprintf("%s/%s", filepath.dir(a.path), uri)
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			report_error(problems, a.path, 0, 0, "cannot read its buffer %s: %v", uri, err)
			return 0, false
		}
		key = hash.fnv64a(bytes, key)
	}
	return key, true
}

// build_mesh cooks one mesh into its blob.
@(private = "file")
build_mesh :: proc(a: Asset_Source, m: Model_Mesh, guid: format.Guid, key: u64, problems: ^Problems) -> (blob: []byte, ok: bool) {
	scale := f32(strconv.parse_f64(model_setting(a, "scale")) or_else 1)
	generate := model_setting(a, "tangents") == "generate"
	lod := model_setting(a, "cluster_lod") == "true"
	collision := model_setting(a, "collision") == "true"
	impostor := model_setting(a, "impostor") == "true" ? (strconv.parse_int(model_setting(a, "impostor_size")) or_else 64) : 0
	flags: format.Mesh_Flags

	// The primitives are grouped by material, and each group is a submesh, in the order of their first use.
	materials := make([dynamic]^cgltf.material, context.temp_allocator)
	for part in m.parts {
		if !slice.contains(materials[:], part.primitive.material) {
			append(&materials, part.primitive.material)
		}
	}
	corners := make([dynamic]Vertex, context.temp_allocator)
	ranges := make([][2]int, len(materials), context.temp_allocator)
	for material, s in materials {
		ranges[s].x = len(corners)
		for part in m.parts {
			if part.primitive.material != material {
				continue
			}
			read_primitive(a, part, scale, &corners, &flags, &generate, problems) or_return
		}
		ranges[s].y = len(corners)
	}
	if len(corners) == 0 {
		report_error(problems, a.path, 0, 0, "mesh %s has no triangles", m.name)
		return
	}
	names := make([]string, len(materials), context.temp_allocator)
	for material, s in materials {
		if material != nil && material.name != nil {
			names[s] = string(material.name)
		}
	}
	cook := Cook_Mesh {
		corners           = corners[:],
		ranges            = ranges,
		names             = names,
		flags             = flags,
		generate_tangents = generate,
		lod               = lod,
		collision         = collision,
		impostor_size     = impostor,
		name              = m.name,
		source_path       = a.name,
	}
	return finish_mesh(cook, guid, key), true
}

// Cook_Mesh is a mesh's triangles as corners, three per triangle in submesh order, with each submesh's range of them
// and its material slot's name: what an importer gives finish_mesh, which welds, orders and clusters them.
Cook_Mesh :: struct {
	corners:           []Vertex,
	ranges:            [][2]int,
	names:             []string,
	flags:             format.Mesh_Flags,
	// Make MikkTSpace tangents in place of the corners' own.
	generate_tangents: bool,
	// Build the meshlets' hierarchy of levels of detail, or only level 0.
	lod:               bool,
	// Write the collision data (see collision_of).
	collision:         bool,
	// Bake an impostor with frames of this many texels a side, or none for 0 (see bake_impostor).
	impostor_size:     int,
	name:              string,
	source_path:       string,
}

// finish_mesh is the half of a mesh's cook that every importer shares: it welds identical corners into vertices,
// orders each submesh's triangles for the vertex cache and the vertices for fetching, builds the meshlets, bakes the
// impostor, and writes the blob.
finish_mesh :: proc(m: Cook_Mesh, guid: format.Guid, key: u64) -> []byte {
	corners := m.corners
	ranges := m.ranges
	flags := m.flags
	generate := m.generate_tangents
	lod := m.lod
	stride := c.size_t(size_of(Vertex))
	if generate {
		tangents := make([][4]f32, len(corners), context.temp_allocator)
		meshopt_generateTangents(
			&tangents[0][0], nil, c.size_t(len(corners)),
			&corners[0].position[0], c.size_t(len(corners)), stride,
			&corners[0].normal[0], stride,
			&corners[0].uv0[0], stride,
			MESHOPT_TANGENT_COMPATIBLE,
		)
		for &v, i in corners {
			v.tangent = tangents[i]
		}
	}

	// Weld identical corners into vertices, order each submesh's triangles for the vertex cache, then the vertices
	// for fetching.
	remap := make([]c.uint, len(corners), context.temp_allocator)
	vertex_count := int(meshopt_generateVertexRemap(&remap[0], nil, c.size_t(len(corners)), &corners[0], c.size_t(len(corners)), stride))
	welded := make([]Vertex, vertex_count, context.temp_allocator)
	meshopt_remapVertexBuffer(&welded[0], &corners[0], c.size_t(len(corners)), stride, &remap[0])
	indices := remap
	for r in ranges {
		if r.y > r.x {
			ordered := make([]c.uint, r.y - r.x, context.temp_allocator)
			meshopt_optimizeVertexCache(&ordered[0], &indices[r.x], c.size_t(r.y - r.x), c.size_t(vertex_count))
			copy(indices[r.x:r.y], ordered)
		}
	}
	vertices := make([]Vertex, vertex_count, context.temp_allocator)
	vertex_count = int(meshopt_optimizeVertexFetch(&vertices[0], &indices[0], c.size_t(len(indices)), &welded[0], c.size_t(vertex_count), stride))
	vertices = vertices[:vertex_count]

	meshlets := make([dynamic]format.Meshlet, context.temp_allocator)
	meshlet_vertices := make([dynamic]u32, context.temp_allocator)
	meshlet_triangles := make([dynamic]u32, context.temp_allocator)
	submeshes := make([]format.Submesh_Entry, len(ranges), context.temp_allocator)
	for r, s in ranges {
		first_meshlet := len(meshlets)
		build_meshlets(indices[r.x:r.y], vertices, lod, &meshlets, &meshlet_vertices, &meshlet_triangles)
		submeshes[s] = {
			name          = m.names[s],
			first_index   = u32(r.x),
			index_count   = u32(r.y - r.x),
			first_meshlet = u32(first_meshlet),
			meshlet_count = u32(len(meshlets) - first_meshlet),
			bounds        = bounds_of(vertices, indices[r.x:r.y]),
		}
	}

	bounds := bounds_of(vertices, nil)
	if vertex_count > 65535 {
		flags += {.Index32}
	}
	attribute_stride := int(format.mesh_attribute_stride(flags))
	positions := make([]byte, vertex_count * 12, context.temp_allocator)
	attributes := make([]byte, vertex_count * attribute_stride, context.temp_allocator)
	for v, i in vertices {
		(^[3]f32)(&positions[i * 12])^ = v.position
		record := attributes[i * attribute_stride:]
		(^format.Mesh_Attributes)(&record[0])^ = {
			normal  = encode_normal(v.normal),
			tangent = encode_tangent(v.tangent),
			uv0     = v.uv0,
		}
		offset := size_of(format.Mesh_Attributes)
		if .UV1 in flags {
			(^[2]f32)(&record[offset])^ = v.uv1
			offset += 8
		}
		if .Color in flags {
			for ch in 0 ..< 4 {
				record[offset + ch] = u8(clamp(v.color[ch], 0, 1) * 255 + 0.5)
			}
		}
	}
	index_bytes: []byte
	if .Index32 in flags {
		index_bytes = mem.slice_to_bytes(slice.clone(indices, context.temp_allocator))
	} else {
		narrow := make([]u16, len(indices), context.temp_allocator)
		for index, i in indices {
			narrow[i] = u16(index)
		}
		index_bytes = mem.slice_to_bytes(narrow)
	}
	contents := format.Mesh_Contents {
		guid              = guid,
		key               = key,
		flags             = flags,
		vertex_count      = u32(vertex_count),
		index_count       = u32(len(indices)),
		bounds            = bounds,
		submeshes         = submeshes,
		positions         = positions,
		attributes        = attributes,
		indices           = index_bytes,
		meshlets          = meshlets[:],
		meshlet_vertices  = mem.slice_to_bytes(meshlet_vertices[:]),
		meshlet_triangles = mem.slice_to_bytes(meshlet_triangles[:]),
		name              = m.name,
		source_path       = m.source_path,
	}
	if m.collision {
		contents.collision_positions, contents.collision_triangles, contents.collision_submeshes = collision_of(vertices, indices, submeshes)
	}
	if m.impostor_size > 0 {
		contents.impostor = bake_impostor(vertices, indices, submeshes, bounds, m.impostor_size, context.temp_allocator)
		contents.impostor_size = u32(m.impostor_size)
		contents.impostor_error = impostor_error(meshlets[:], bounds, m.impostor_size)
	}
	return format.mesh_write(contents, context.temp_allocator)
}

// collision_of is a mesh's collision data: its positions welded by position alone, which joins the triangles that the
// render mesh splits at its seams for normals and UVs, so a collider has no internal edges there; its triangles over
// them, without the ones that welding made degenerate; and each triangle's submesh.
@(private)
collision_of :: proc(vertices: []Vertex, indices: []c.uint, submeshes: []format.Submesh_Entry) -> (positions: [][3]f32, triangles: [][3]u32, owners: []u16) {
	if len(vertices) == 0 || len(indices) == 0 {
		return
	}
	all := make([][3]f32, len(vertices), context.temp_allocator)
	for v, i in vertices {
		all[i] = v.position
	}
	remap := make([]c.uint, len(all), context.temp_allocator)
	count := int(meshopt_generateVertexRemap(&remap[0], nil, c.size_t(len(all)), &all[0], c.size_t(len(all)), 12))
	positions = make([][3]f32, count, context.temp_allocator)
	meshopt_remapVertexBuffer(&positions[0], &all[0], c.size_t(len(all)), 12, &remap[0])
	kept := make([dynamic][3]u32, 0, len(indices) / 3, context.temp_allocator)
	kept_owners := make([dynamic]u16, 0, len(indices) / 3, context.temp_allocator)
	for s, owner in submeshes {
		for i := s.first_index; i + 2 < s.first_index + s.index_count; i += 3 {
			t := [3]u32{u32(remap[indices[i]]), u32(remap[indices[i + 1]]), u32(remap[indices[i + 2]])}
			if t.x != t.y && t.y != t.z && t.x != t.z {
				append(&kept, t)
				append(&kept_owners, u16(owner))
			}
		}
	}
	return positions, kept[:], kept_owners[:]
}

// read_primitive appends a primitive's triangles as corners. glTF is right-handed with +z the asset's front, and the
// engine is left-handed with +z forward, so it negates x and reverses each triangle's winding, which leaves front
// faces clockwise on screen, as lib/core/gpu takes them. A primitive without normals gets its faces' normals, as glTF
// says. A primitive without tangents makes generate true.
@(private = "file")
read_primitive :: proc(a: Asset_Source, part: Model_Part, scale: f32, corners: ^[dynamic]Vertex, flags: ^format.Mesh_Flags, generate: ^bool, problems: ^Problems) -> bool {
	p := part.primitive
	if p.type != .triangles {
		report_warning(problems, a.path, 0, 0, "a primitive of %v is not triangles, and is left out", p.type)
		return true
	}
	position, normal, tangent, uv0, uv1, color: ^cgltf.accessor
	for attribute in p.attributes {
		switch {
		case attribute.type == .position:
			position = attribute.data
		case attribute.type == .normal:
			normal = attribute.data
		case attribute.type == .tangent:
			tangent = attribute.data
		case attribute.type == .texcoord && attribute.index == 0:
			uv0 = attribute.data
		case attribute.type == .texcoord && attribute.index == 1:
			uv1 = attribute.data
			flags^ += {.UV1}
		case attribute.type == .color && attribute.index == 0:
			color = attribute.data
			flags^ += {.Color}
		}
	}
	if position == nil {
		report_error(problems, a.path, 0, 0, "a primitive has no positions")
		return false
	}
	if tangent == nil {
		generate^ = true
	}
	m := part.transform
	normal_matrix := linalg.inverse_transpose(linalg.matrix3_from_matrix4(m))
	count := p.indices != nil ? int(p.indices.count) : int(position.count)
	mirror := [3]f32{-1, 1, 1}
	for t in 0 ..< count / 3 {
		triangle: [3]Vertex
		// Reversed, so front faces are clockwise on screen after the mirror, as lib/core/gpu takes them.
		for corner, k in ([3]int{0, 2, 1}) {
			i := uint(t * 3 + corner)
			index := p.indices != nil ? cgltf.accessor_read_index(p.indices, i) : i
			v := Vertex {
				tangent = {1, 0, 0, 1},
				color   = {1, 1, 1, 1},
			}
			_ = cgltf.accessor_read_float(position, index, &v.position[0], 3)
			v.position = (m * [4]f32{v.position.x, v.position.y, v.position.z, 1}).xyz * scale * mirror
			if normal != nil {
				_ = cgltf.accessor_read_float(normal, index, &v.normal[0], 3)
				v.normal = linalg.normalize0(normal_matrix * v.normal) * mirror
			}
			if tangent != nil {
				_ = cgltf.accessor_read_float(tangent, index, &v.tangent[0], 4)
				v.tangent.xyz = linalg.normalize0(linalg.matrix3_from_matrix4(m) * v.tangent.xyz) * mirror
				// The mirror flips the frame's handedness, so the bitangent's sign flips too.
				v.tangent.w = -v.tangent.w
			}
			if uv0 != nil {
				_ = cgltf.accessor_read_float(uv0, index, &v.uv0[0], 2)
			}
			if uv1 != nil {
				_ = cgltf.accessor_read_float(uv1, index, &v.uv1[0], 2)
			}
			if color != nil {
				components := cgltf.num_components(color.type)
				_ = cgltf.accessor_read_float(color, index, &v.color[0], components)
			}
			triangle[k] = v
		}
		if normal == nil {
			face := linalg.normalize0(linalg.cross(triangle[1].position - triangle[0].position, triangle[2].position - triangle[0].position))
			for &v in triangle {
				v.normal = face
			}
		}
		append(corners, ..triangle[:])
	}
	return true
}

// build_meshlets splits a submesh's triangles into meshlets, appended with their offsets into the mesh's arrays. With
// lod, they are clusterlod's hierarchy, level by level: the submesh's own triangles, then each simplification of groups
// of the level below (see docs/content/kinds/meshes.md#meshlets). Without it, they are the submesh's own triangles,
// clustered with a weight on their cones.
@(private = "file")
build_meshlets :: proc(indices: []c.uint, vertices: []Vertex, lod: bool, meshlets: ^[dynamic]format.Meshlet, meshlet_vertices: ^[dynamic]u32, meshlet_triangles: ^[dynamic]u32) {
	if len(indices) == 0 {
		return
	}
	stride := c.size_t(size_of(Vertex))
	if !lod {
		bound := int(meshopt_buildMeshletsBound(c.size_t(len(indices)), format.MESHLET_MAX_VERTICES, format.MESHLET_MAX_TRIANGLES))
		built := make([]Meshopt_Meshlet, bound, context.temp_allocator)
		local_vertices := make([]c.uint, len(indices), context.temp_allocator)
		local_triangles := make([]u8, len(indices), context.temp_allocator)
		count := int(
			meshopt_buildMeshlets(
				&built[0], &local_vertices[0], &local_triangles[0],
				&indices[0], c.size_t(len(indices)),
				&vertices[0].position[0], c.size_t(len(vertices)), stride,
				format.MESHLET_MAX_VERTICES, format.MESHLET_MAX_TRIANGLES, MESHLET_CONE_WEIGHT,
			),
		)
		for m in built[:count] {
			meshopt_optimizeMeshlet(&local_vertices[m.vertex_offset], &local_triangles[m.triangle_offset], c.size_t(m.triangle_count), c.size_t(m.vertex_count))
			top := Clod_Bounds{error = math.F32_MAX}
			append_meshlet(local_vertices[m.vertex_offset:][:m.vertex_count], local_triangles[m.triangle_offset:][:m.triangle_count * 3], vertices, 0, {}, top, meshlets, meshlet_vertices, meshlet_triangles)
		}
		return
	}

	config := clod_default_config(format.MESHLET_MAX_TRIANGLES)
	config.max_vertices = format.MESHLET_MAX_VERTICES
	weights := [3]f32{LOD_NORMAL_WEIGHT, LOD_NORMAL_WEIGHT, LOD_NORMAL_WEIGHT}
	// The attributes are the floats of Vertex from its normal on. The normal weighs in, and the UV sets' seams are
	// protected, which permissive simplification needs.
	first := offset_of(Vertex, normal)
	protect: c.uint
	for field in ([]uintptr{offset_of(Vertex, uv0), offset_of(Vertex, uv1)}) {
		protect |= 3 << ((field - first) / size_of(f32))
	}
	mesh := Clod_Mesh {
		indices                  = &indices[0],
		index_count              = c.size_t(len(indices)),
		vertex_count             = c.size_t(len(vertices)),
		vertex_positions         = &vertices[0].position[0],
		vertex_positions_stride  = stride,
		vertex_attributes        = &vertices[0].normal[0],
		vertex_attributes_stride = stride,
		attribute_weights        = &weights[0],
		attribute_count          = len(weights),
		attribute_protect_mask   = protect,
	}
	output := Lod_Output {
		ctx      = context,
		groups   = make([dynamic]Clod_Group, context.temp_allocator),
		clusters = make([dynamic]Lod_Cluster, context.temp_allocator),
	}
	clod_build(config, mesh, &output, lod_output)
	// clodBuild gives the groups level by level, so the meshlets are in order of depth.
	for cluster in output.clusters {
		local_vertices := make([]c.uint, len(cluster.indices), context.temp_allocator)
		local_triangles := make([]u8, len(cluster.indices), context.temp_allocator)
		vertex_count := int(clod_local_indices(&local_vertices[0], &local_triangles[0], &cluster.indices[0], c.size_t(len(cluster.indices))))
		made := cluster.refined >= 0 ? output.groups[cluster.refined].simplified : Clod_Bounds{}
		group := output.groups[cluster.group]
		append_meshlet(local_vertices[:vertex_count], local_triangles, vertices, int(group.depth), made, group.simplified, meshlets, meshlet_vertices, meshlet_triangles)
	}
}

// Lod_Output is what clodBuild gave: each group, and each cluster with its group and the group it was simplified from.
@(private = "file")
Lod_Output :: struct {
	ctx:      runtime.Context,
	groups:   [dynamic]Clod_Group,
	clusters: [dynamic]Lod_Cluster,
}

@(private = "file")
Lod_Cluster :: struct {
	group:   int,
	refined: int,
	indices: []c.uint,
}

@(private = "file")
lod_output :: proc "c" (output_context: rawptr, group: Clod_Group, clusters: [^]Clod_Cluster, cluster_count: c.size_t) -> c.int {
	output := (^Lod_Output)(output_context)
	context = output.ctx
	id := len(output.groups)
	append(&output.groups, group)
	// The clusters' indices last only until this returns.
	for cluster in clusters[:cluster_count] {
		indices := slice.clone(cluster.indices[:cluster.index_count], context.temp_allocator)
		append(&output.clusters, Lod_Cluster{group = id, refined = int(cluster.refined), indices = indices})
	}
	return c.int(id)
}

// append_meshlet appends a meshlet of local vertices and triangles, with its culling bounds, the simplification that
// made it and its group's, a level up.
@(private = "file")
append_meshlet :: proc(local_vertices: []c.uint, local_triangles: []u8, vertices: []Vertex, depth: int, made, parent: Clod_Bounds, meshlets: ^[dynamic]format.Meshlet, meshlet_vertices: ^[dynamic]u32, meshlet_triangles: ^[dynamic]u32) {
	triangle_count := len(local_triangles) / 3
	b := meshopt_computeMeshletBounds(&local_vertices[0], &local_triangles[0], c.size_t(triangle_count), &vertices[0].position[0], c.size_t(len(vertices)), size_of(Vertex))
	append(
		meshlets,
		format.Meshlet {
			vertex_offset = u32(len(meshlet_vertices)),
			triangle_offset = u32(len(meshlet_triangles)),
			vertex_count = u8(len(local_vertices)),
			triangle_count = u8(triangle_count),
			depth = u16(depth),
			cone_axis = b.cone_axis_s8,
			cone_cutoff = b.cone_cutoff_s8,
			center = b.center,
			radius = b.radius,
			error_center = made.center,
			error_radius = made.radius,
			parent_center = parent.center,
			parent_radius = parent.radius,
			error = made.error,
			parent_error = parent.error,
		},
	)
	for v in local_vertices {
		append(meshlet_vertices, u32(v))
	}
	for i in 0 ..< triangle_count {
		t := local_triangles[i * 3:]
		append(meshlet_triangles, u32(t[0]) | u32(t[1]) << 8 | u32(t[2]) << 16)
	}
}

// bounds_of is the box and the sphere around the vertices that the indices use, or around every vertex without them.
@(private = "file")
bounds_of :: proc(vertices: []Vertex, indices: []c.uint) -> (b: format.Mesh_Bounds) {
	b.min, b.max = math.F32_MAX, -math.F32_MAX
	used := make([dynamic][3]f32, context.temp_allocator)
	if indices == nil {
		for v in vertices {
			append(&used, v.position)
		}
	} else {
		for i in indices {
			append(&used, vertices[i].position)
		}
	}
	if len(used) == 0 {
		return {}
	}
	for p in used {
		b.min = linalg.min(b.min, p)
		b.max = linalg.max(b.max, p)
	}
	sphere := meshopt_computeSphereBounds(&used[0][0], c.size_t(len(used)), size_of([3]f32), nil, 0)
	b.center, b.radius = sphere.center, sphere.radius
	return
}

// The attribute encoders are the format's, so the game's live meshes encode as the cooker does.
octahedral :: format.mesh_octahedral
encode_normal :: format.mesh_encode_normal
encode_tangent :: format.mesh_encode_tangent
