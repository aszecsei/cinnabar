package cook

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(test)
mesh_files_cook_to_mesh_blobs_by_slot :: proc(t: ^testing.T) {
	// The template's box, with its top in slot 2 and a material on slot 0.
	text, _ := strings.replace(
		MESH_TEMPLATE,
		"f 0 4 7 6 5",
		"f 2 4 7 6 5",
		1,
		context.temp_allocator,
	)
	text = fmt.tprintf(
		"mesh 1\nmaterial 0 $00112233445566778899aabbccddeeff\n%s",
		strings.trim_prefix(text, "mesh 1\n"),
	)
	tree := make_tree(t, {{"content/meshes/room.mesh", text}})
	defer remove_tree(tree)
	options := tree_options(tree)

	pass := cook(options, {.Mesh})
	testing.expectf(t, pass.ok, "problems: %v", pass.problems.list)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
	guid := tree_guid(t, tree, "meshes/room.mesh")
	data := tree_blob(t, tree, guid)
	blob, ok := format.mesh_view(data)
	testing.expect(t, ok, "a mesh file did not cook into a mesh blob")
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.name), "room")
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/meshes/room.mesh")
	testing.expect_value(t, blob.index_count, 36)
	// Every edge is sharp, so each face has its own vertices.
	testing.expect_value(t, blob.vertex_count, 24)
	testing.expect_value(t, blob.bounds.min, [3]f32{0, 0, 0})
	testing.expect_value(t, blob.bounds.max, [3]f32{1, 1, 1})
	testing.expect_value(t, blob.flags, format.Mesh_Flags{})
	// A submesh for each slot up to the top's, so a submesh's index is its slot, with slot 1 empty.
	submeshes := format.mesh_submeshes(data, blob)
	testing.expect_value(t, len(submeshes), 3)
	if len(submeshes) == 3 {
		testing.expect_value(t, format.blob_string(data, submeshes[0].name), "0")
		testing.expect_value(t, submeshes[0].index_count, 30)
		testing.expect_value(t, submeshes[1].index_count, 0)
		testing.expect_value(t, submeshes[1].meshlet_count, 0)
		testing.expect_value(t, format.blob_string(data, submeshes[2].name), "2")
		testing.expect_value(t, submeshes[2].index_count, 6)
		testing.expect_value(t, submeshes[2].meshlet_count, 1)
		testing.expect_value(t, submeshes[2].bounds.min, [3]f32{0, 1, 0})
	}
	// The tangents come from the mappings: the floor's runs along +x.
	attributes := format.blob_bytes(data, blob.attributes)
	positions := format.blob_bytes(data, blob.positions)
	found_floor := false
	for i in 0 ..< int(blob.vertex_count) {
		p := (^[3]f32)(&positions[i * 12])^
		a := (^format.Mesh_Attributes)(
			&attributes[i * int(format.mesh_attribute_stride(blob.flags))],
		)^
		if a.normal == encode_normal({0, -1, 0}) {
			found_floor = true
			testing.expect_value(t, a.tangent, encode_tangent({1, 0, 0, -1}))
			testing.expect_value(t, a.uv0, [2]f32{p.x, -p.z})
		}
	}
	testing.expect(t, found_floor)

	again := cook(options, {.Mesh})
	testing.expect_value(t, again.current[.Mesh], 1)
	testing.expect_value(t, again.cooked[.Mesh], 0)
}

@(test)
mesh_file_problems_name_their_lines_and_errors_keep_the_old_blob :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/room.mesh", MESH_TEMPLATE}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Mesh}).ok)
	guid := tree_guid(t, tree, "room.mesh")
	path := fmt.tprintf("%s/content/room.mesh", tree.dir)

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)

	// A face that cannot bake is a warning at its line, and the mesh cooks without it.
	bent := fmt.tprintf("%sf 0 0 1 0 1\nmap 1 0 0 0 0 -1 1 1 0 0 0\n", MESH_TEMPLATE)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)bent) == nil)
	pass := cook(options, {.Mesh})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
	found := false
	for p in pass.problems.list {
		if strings.has_suffix(p.file, "room.mesh") && p.line == 34 && !p.error {
			found = true
			testing.expect(t, strings.contains(p.text, "fewer than three distinct vertices"))
		}
	}
	testing.expectf(t, found, "problems: %v", pass.problems.list)
	data := tree_blob(t, tree, guid)
	blob, ok := format.mesh_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, blob.index_count, 36)
	}

	// A malformed line is an error at its line, and the blob stays as it was.
	broken, _ := strings.replace(MESH_TEMPLATE, "v 1 1 1\n", "v 1 1\n", 1, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)broken) == nil)
	pass = cook(options, {.Mesh})
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 0)
	found = false
	for p in pass.problems.list {
		found ||= strings.has_suffix(p.file, "room.mesh") && p.line == 8 && p.error
	}
	testing.expectf(t, found, "problems: %v", pass.problems.list)
	for a in pass.assets {
		if a.kind == .Mesh {
			testing.expect(t, a.failed)
		}
	}
	data = tree_blob(t, tree, guid)
	blob, ok = format.mesh_view(data)
	testing.expect(t, ok && blob.index_count == 36)

	// A setting the importer does not take is an error.
	testing.expect(t, os.write_entire_file(path, string(MESH_TEMPLATE)) == nil)
	meta_path := fmt.tprintf("%s.meta", path)
	buffer: [32]u8
	meta := fmt.tprintf("guid = %s\ntangents = file\n", format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(meta_path, transmute([]byte)meta) == nil)
	testing.expect(t, !cook(options, {.Mesh}).ok)
	meta = fmt.tprintf(
		"guid = %s\ntangents = mikk\ncluster_lod = false\n",
		format.guid_format(guid, &buffer),
	)
	testing.expect(t, os.write_entire_file(meta_path, transmute([]byte)meta) == nil)
	pass = cook(options, {.Mesh})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
}

@(test)
the_mesh_template_is_a_box :: proc(t: ^testing.T) {
	mesh, problems, ok := format.mesh_text_parse(
		template_text(.Mesh, "block"),
		context.temp_allocator,
	)
	testing.expectf(t, ok, "problems: %v", problems)
	testing.expect_value(t, len(mesh.vertices), 8)
	testing.expect_value(t, len(mesh.faces), 6)
	testing.expect_value(t, len(mesh.sharp), 12)
	// The text is what the writer writes, so the editor's save of an unchanged box changes nothing.
	testing.expect_value(t, format.mesh_text_write(mesh, context.temp_allocator), MESH_TEMPLATE)
	bake := format.mesh_bake(mesh, context.temp_allocator)
	testing.expect_value(t, len(bake.problems), 0)
	testing.expect_value(t, len(bake.indices), 36)
	for f in mesh.faces {
		normal := format.mesh_face_normal(mesh.vertices, f.corners)
		// Each face fronts out of the box, and its mapping is the world-aligned one for its normal.
		center: [3]f32
		for c in f.corners {
			center += mesh.vertices[c] / 4
		}
		testing.expect(
			t,
			(center.x - 0.5) * normal.x +
				(center.y - 0.5) * normal.y +
				(center.z - 0.5) * normal.z >
			0.4,
		)
		testing.expect_value(t, f.mapping, format.mesh_world_mapping(normal, 1))
	}
}

// A mesh's collision data welds by position: the box's 24 vertices, split at every sharp edge, are its 8 corners, its
// 12 triangles face out, and each says its submesh. collision = false leaves it out.
@(test)
meshes_cook_welded_collision_data :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/room.mesh", MESH_TEMPLATE}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Mesh}).ok)
	guid := tree_guid(t, tree, "room.mesh")
	data := tree_blob(t, tree, guid)
	blob, ok := format.mesh_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.vertex_count, 24)
	positions := format.mesh_collision_positions(data, blob)
	triangles := format.mesh_collision_triangles(data, blob)
	testing.expect_value(t, len(positions), 8)
	testing.expect_value(t, len(triangles), 12)
	testing.expect_value(t, len(format.mesh_collision_submeshes(data, blob)), 12)
	for tri in triangles {
		a, b, c := positions[tri.x], positions[tri.y], positions[tri.z]
		normal := linalg.cross(b - a, c - a)
		outward := (a + b + c) / 3 - [3]f32{0.5, 0.5, 0.5}
		testing.expectf(t, linalg.dot(normal, outward) > 0, "triangle %v faces out", tri)
	}

	meta := fmt.tprintf("%s/content/room.mesh.meta", tree.dir)
	text, _ := os.read_entire_file(meta, context.temp_allocator)
	testing.expect(t, os.write_entire_file(meta, transmute([]byte)fmt.tprintf("%scollision = false\n", string(text))) == nil)
	testing.expect(t, cook(options, {.Mesh}).ok)
	data = tree_blob(t, tree, guid)
	blob, ok = format.mesh_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.mesh_collision_triangles(data, blob)), 0)
	}
}

// impostor = true bakes the box's views: from -z, the corner frame's view, its middle is the box's -z face, a third
// of the sphere's radius toward the view from its center, facing the view, and its corner sees nothing. The impostor
// takes over where a texel is too small to show, since the box has no coarser level.
@(test)
impostors_bake_the_mesh_seen_from_each_frame :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/box.mesh", MESH_TEMPLATE}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Mesh}).ok)
	guid := tree_guid(t, tree, "box.mesh")
	data := tree_blob(t, tree, guid)
	blob, ok := format.mesh_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.mesh_impostor(data, blob)), 0)
	}

	meta := fmt.tprintf("%s/content/box.mesh.meta", tree.dir)
	text, _ := os.read_entire_file(meta, context.temp_allocator)
	testing.expect(t, os.write_entire_file(meta, transmute([]byte)fmt.tprintf("%simpostor = true\nimpostor_size = 32\n", string(text))) == nil)
	testing.expect(t, cook(options, {.Mesh}).ok)
	data = tree_blob(t, tree, guid)
	blob, ok = format.mesh_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	size :: 32
	texels := format.mesh_impostor(data, blob)
	testing.expect_value(t, len(texels), format.IMPOSTOR_FRAMES * format.IMPOSTOR_FRAMES * size * size)
	testing.expect_value(t, blob.impostor_size, size)
	radius := blob.bounds.radius
	testing.expectf(t, abs(blob.impostor_error - 2 * radius / size) < 1e-6, "the error %v is a texel", blob.impostor_error)
	if len(texels) != format.IMPOSTOR_FRAMES * format.IMPOSTOR_FRAMES * size * size {
		return
	}
	testing.expect(t, linalg.length(impostor_direction(0, 0) - [3]f32{0, 0, -1}) < 1e-6)
	middle := texels[size / 2 * size + size / 2]
	testing.expect_value(t, middle.flags & 0xff, 1)
	testing.expectf(t, abs(f32(middle.depth) - 0.5 / radius) < 1e-2, "the face's depth %v", f32(middle.depth))
	p := [2]f32{f32(middle.normal.x), f32(middle.normal.y)} / 32767
	normal := [3]f32{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if normal.z < 0 {
		normal.xy = (1 - [2]f32{abs(normal.y), abs(normal.x)}) * [2]f32{normal.x >= 0 ? 1 : -1, normal.y >= 0 ? 1 : -1}
	}
	testing.expectf(t, linalg.length(linalg.normalize(normal) - [3]f32{0, 0, -1}) < 1e-3, "the face's normal %v is -z", normal)
	testing.expect_value(t, texels[0].flags & 0xff, 0)
	// Every frame sees the box in its middle.
	for frame in 0 ..< format.IMPOSTOR_FRAMES * format.IMPOSTOR_FRAMES {
		testing.expect(t, texels[frame * size * size + size / 2 * size + size / 2].flags & 0xff == 1)
	}
}
