package cook

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"

import format "cinnabar:engine/asset/format"

// skinned_gltf is a bar of two quads up the y axis, skinned to Hip at its bottom and Knee at its top, with the middle
// row between them. The skin lists Knee before Hip, and their parent Armature is not a joint. Bend turns Knee 90° about
// z, linearly over a second; Sway moves Hip from 1 m to 2 m along x as a cubic spline, and moves the Bar node too.
@(private = "file")
skinned_gltf :: proc() -> string {
	positions := [6][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0}, {0, 2, 0}, {1, 2, 0}}
	indices := [12]u16{0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4}
	// Joint 0 is Knee and joint 1 is Hip, as the skin lists them.
	joints := [6][4]u8{{1, 0, 0, 0}, {1, 0, 0, 0}, {0, 1, 0, 0}, {0, 1, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}
	weights := [6][4]f32{{1, 0, 0, 0}, {1, 0, 0, 0}, {0.5, 0.5, 0, 0}, {0.5, 0.5, 0, 0}, {1, 0, 0, 0}, {1, 0, 0, 0}}
	// Column-major: Knee's world is at (1, 1, 3) and Hip's at (1, 0, 3).
	inverse_binds := [2][16]f32{{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, -1, -3, 1}, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0, -3, 1}}
	times := [2]f32{0, 1}
	bend := [2][4]f32{{0, 0, 0, 1}, {0, 0, math.SQRT_TWO / 2, math.SQRT_TWO / 2}}
	sway := [6][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 0, 0}, {0, 0, 0}, {2, 0, 0}, {0, 0, 0}}
	buffer := make([dynamic]byte, context.temp_allocator)
	views := make([dynamic]string, context.temp_allocator)
	add :: proc(buffer: ^[dynamic]byte, views: ^[dynamic]string, data: []byte) {
		append(views, fmt.tprintf(`{{"buffer": 0, "byteOffset": %d, "byteLength": %d}}`, len(buffer), len(data)))
		append(buffer, ..data)
	}
	add(&buffer, &views, mem.slice_to_bytes(positions[:]))
	add(&buffer, &views, mem.slice_to_bytes(indices[:]))
	add(&buffer, &views, mem.slice_to_bytes(joints[:]))
	add(&buffer, &views, mem.slice_to_bytes(weights[:]))
	add(&buffer, &views, mem.slice_to_bytes(inverse_binds[:]))
	add(&buffer, &views, mem.slice_to_bytes(times[:]))
	add(&buffer, &views, mem.slice_to_bytes(bend[:]))
	add(&buffer, &views, mem.slice_to_bytes(sway[:]))
	encoded := base64.encode(buffer[:], allocator = context.temp_allocator)
	return fmt.tprintf(
		`{{
  "asset": {{"version": "2.0"}},
  "buffers": [{{"byteLength": %d, "uri": "data:application/octet-stream;base64,%s"}}],
  "bufferViews": [%s, %s, %s, %s, %s, %s, %s, %s],
  "accessors": [
    {{"bufferView": 0, "componentType": 5126, "count": 6, "type": "VEC3", "min": [0, 0, 0], "max": [1, 2, 0]}},
    {{"bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"}},
    {{"bufferView": 2, "componentType": 5121, "count": 6, "type": "VEC4"}},
    {{"bufferView": 3, "componentType": 5126, "count": 6, "type": "VEC4"}},
    {{"bufferView": 4, "componentType": 5126, "count": 2, "type": "MAT4"}},
    {{"bufferView": 5, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]}},
    {{"bufferView": 6, "componentType": 5126, "count": 2, "type": "VEC4"}},
    {{"bufferView": 7, "componentType": 5126, "count": 6, "type": "VEC3"}}
  ],
  "meshes": [{{"name": "Bar", "primitives": [{{"attributes": {{"POSITION": 0, "JOINTS_0": 2, "WEIGHTS_0": 3}}, "indices": 1}}]}}],
  "skins": [{{"name": "Rig", "joints": [3, 2], "inverseBindMatrices": 4}}],
  "animations": [
    {{"name": "Bend", "samplers": [{{"input": 5, "output": 6}}], "channels": [{{"sampler": 0, "target": {{"node": 3, "path": "rotation"}}}}]}},
    {{"name": "Sway", "samplers": [{{"input": 5, "output": 7, "interpolation": "CUBICSPLINE"}}], "channels": [
      {{"sampler": 0, "target": {{"node": 2, "path": "translation"}}}},
      {{"sampler": 0, "target": {{"node": 0, "path": "translation"}}}}
    ]}}
  ],
  "nodes": [
    {{"name": "Bar", "mesh": 0, "skin": 0, "translation": [9, 0, 0]}},
    {{"name": "Armature", "translation": [0, 0, 3], "children": [2]}},
    {{"name": "Hip", "translation": [1, 0, 0], "children": [3]}},
    {{"name": "Knee", "translation": [0, 1, 0]}}
  ],
  "scenes": [{{"nodes": [0, 1]}}],
  "scene": 0
}}`,
		len(buffer),
		encoded,
		views[0], views[1], views[2], views[3], views[4], views[5], views[6], views[7],
	)
}

@(private = "file")
skinned_meta :: proc(t: ^testing.T, tree: Tree) -> format.Meta {
	text, err := os.read_entire_file(fmt.tprintf("%s/content/rig.gltf.meta", tree.dir), context.temp_allocator)
	testing.expect(t, err == nil)
	meta, ok := format.meta_parse(string(text), context.temp_allocator)
	testing.expect(t, ok)
	return meta
}

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

@(test)
a_skinned_model_imports_its_skin_and_animations :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/rig.gltf", skinned_gltf()}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Model})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Mesh], 1)
	testing.expect_value(t, pass.cooked[.Skin], 1)
	testing.expect_value(t, pass.cooked[.Animation], 2)

	meta := skinned_meta(t, tree)
	mesh_guid, mesh_found := format.meta_subasset(meta, format.MESH_KIND, "Bar")
	skin_guid, skin_found := format.meta_subasset(meta, format.SKIN_KIND, "Rig")
	bend_guid, bend_found := format.meta_subasset(meta, format.ANIMATION_KIND, "Bend")
	sway_guid, sway_found := format.meta_subasset(meta, format.ANIMATION_KIND, "Sway")
	testing.expect(t, mesh_found && skin_found && bend_found && sway_found)

	// The skin's joints are Knee and Hip and their parent, each parent first, in the engine's axes.
	skin_data := tree_blob(t, tree, skin_guid)
	skin, skin_ok := format.skin_view(skin_data)
	testing.expect(t, skin_ok)
	if !skin_ok {
		return
	}
	joints := format.skin_joints(skin_data, skin)
	testing.expect_value(t, len(joints), 3)
	if len(joints) != 3 {
		return
	}
	names := [3]string{"Armature", "Hip", "Knee"}
	for j, i in joints {
		testing.expect_value(t, format.blob_string(skin_data, j.name), names[i])
		testing.expect_value(t, j.parent, i32(i) - 1)
	}
	testing.expect_value(t, joints[1].translation, [3]f32{-1, 0, 0})
	testing.expect_value(t, joints[0].translation, [3]f32{0, 0, 3})
	// Hip's inverse bind takes its world position, (-1, 0, 3) in the engine's axes, to the origin.
	testing.expect_value(t, joints[1].inverse_bind[0], [4]f32{1, 0, 0, 1})
	testing.expect_value(t, joints[1].inverse_bind[2], [4]f32{0, 0, 1, -3})
	// Armature influences no vertex; Hip and Knee each hold theirs.
	testing.expect(t, joints[0].sphere.w < 0 && joints[1].sphere.w > 0 && joints[2].sphere.w > 0)

	// The mesh's skin stream has every vertex's joints in the skin's order, with weights that add up to 65535.
	data := tree_blob(t, tree, mesh_guid)
	blob, mesh_ok := format.mesh_view(data)
	testing.expect(t, mesh_ok)
	if !mesh_ok {
		return
	}
	testing.expect(t, .Skinned in blob.flags)
	testing.expect_value(t, blob.skin.offset % format.BLOB_ALIGN, 0)
	vertices := format.mesh_skin(data, blob)
	testing.expect_value(t, len(vertices), int(blob.vertex_count))
	positions := ([^][3]f32)(raw_data(format.blob_bytes(data, blob.positions)))[:blob.vertex_count]
	for v, i in vertices {
		sum := u32(v.weights[0]) + u32(v.weights[1]) + u32(v.weights[2]) + u32(v.weights[3])
		testing.expect_value(t, sum, 65535)
		switch positions[i].y {
		case 0:
			testing.expect(t, v.joints[0] == 1 && v.weights[0] == 65535, "the bottom row is Hip's")
		case 2:
			testing.expect(t, v.joints[0] == 2 && v.weights[0] == 65535, "the top row is Knee's")
		case:
			testing.expect(t, v.weights[0] > 32000 && v.weights[1] > 32000, "the middle row is shared")
		}
	}

	// Bend turns Knee about z, mirrored: the rotation about z reverses.
	bend_data := tree_blob(t, tree, bend_guid)
	bend, bend_ok := format.animation_view(bend_data)
	testing.expect(t, bend_ok)
	if bend_ok {
		testing.expect_value(t, bend.skin, skin_guid)
		testing.expect_value(t, bend.joint_count, 3)
		testing.expect_value(t, bend.duration, 1)
		channels := format.animation_channels(bend_data, bend)
		testing.expect_value(t, len(channels), 1)
		if len(channels) == 1 {
			c := channels[0]
			testing.expect(t, c.joint == 2 && c.path == .Rotation && c.interpolation == .Linear && c.key_count == 2)
			values := format.animation_values(bend_data, bend)[c.first_value:]
			testing.expect(t, near(values[6], -math.SQRT_TWO / 2) && near(values[7], math.SQRT_TWO / 2))
		}
	}

	// Sway's cubic spline is sampled into linear keys, mirrored, and its channel on Bar, which is no joint, is left out.
	sway_data := tree_blob(t, tree, sway_guid)
	sway, sway_ok := format.animation_view(sway_data)
	testing.expect(t, sway_ok)
	if sway_ok {
		channels := format.animation_channels(sway_data, sway)
		testing.expect_value(t, len(channels), 1)
		if len(channels) == 1 {
			c := channels[0]
			testing.expect(t, c.joint == 1 && c.path == .Translation && c.interpolation == .Linear)
			testing.expect_value(t, c.key_count, ANIMATION_RESAMPLE_RATE + 1)
			times := format.animation_times(sway_data, sway)[c.first_key:][:c.key_count]
			values := format.animation_values(sway_data, sway)[c.first_value:]
			testing.expect(t, near(times[0], 0) && near(times[c.key_count - 1], 1))
			testing.expect(t, near(values[0], -1) && near(values[3 * (c.key_count - 1)], -2))
			// With flat tangents the spline is at its middle halfway.
			testing.expect(t, near(values[3 * 15], -1.5))
		}
	}

	again := cook(options, {.Model})
	testing.expect_value(t, again.current[.Model], 1)
	testing.expect_value(t, again.cooked[.Skin], 0)
}
