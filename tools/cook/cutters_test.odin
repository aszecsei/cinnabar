package cook

import "core:testing"

import format "cinnabar:engine/asset/format"

// The fixture that asset_format's and the editor's scene tests read (see docs/editor/mesh-editing.md#cutters-and-cut-targets).
@(private = "file")
CUTTERS :: #load("../../lib/engine/asset/format/testdata/cutters/cutters.scene", string)

@(test)
cutters_read_over_their_defaults :: proc(t: ^testing.T) {
	scene, problems, ok := format.scene_parse(CUTTERS, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	if !ok {
		return
	}
	target := format.Cut_Target{}
	read_component(scene_component(&scene.entities[0], format.SCENE_CUT_TARGET_ID), &target)
	testing.expect_value(t, target.layer, 2)
	testing.expect_value(
		t,
		target.source,
		format.guid_parse("8c4e3f5d2a6b7c93d0e1f2a3b4c5d6e7") or_else {},
	)
	testing.expect_value(t, target.inputs_hash, 3735928559)

	full := format.DEFAULT_MESH_CUTTER
	read_component(scene_component(&scene.entities[1], format.SCENE_MESH_CUTTER_ID), &full)
	testing.expect_value(
		t,
		full,
		format.Mesh_Cutter {
			shape = .Mesh,
			extents = {0.55, 1.15, 0.5},
			mesh = format.guid_parse("6e2a1d3b0c4f5a71b8d9e0f1a2b3c4d5") or_else {},
			cap_material = format.guid_parse("7f3b2e4c1d5a6b82c9e0f1a2b3c4d5e6") or_else {},
			layers = 4,
			cuts_collision = false,
		},
	)

	bare := format.DEFAULT_MESH_CUTTER
	read_component(scene_component(&scene.entities[2], format.SCENE_MESH_CUTTER_ID), &bare)
	testing.expect_value(t, bare, format.DEFAULT_MESH_CUTTER)
}
