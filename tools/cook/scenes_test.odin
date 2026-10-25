package cook

import "core:fmt"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(test)
a_content_root_cooks_its_scenes :: proc(t: ^testing.T) {
	door_meta := "guid = 9d2e41c0b7a35f6e81c4d2a90b3e7f15\n"
	tree := make_tree(
		t,
		{
			{"content/door.luau", `return 1`},
			{"content/door.luau.meta", door_meta},
			{"content/levels/hall.scene", `scene 1
entity 5f3a9c01e2b47d10
name = "Door"
component 1 Transform
	position = [1, 2, 3]
behaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15
	speed = 2
`},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Scene}).ok)

	guid := tree_guid(t, tree, "levels/hall.scene")
	blob := tree_blob(t, tree, guid)
	scene, ok := format.scene_read(blob, context.temp_allocator)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, len(scene.entities), 1)
	testing.expect_value(t, scene.entities[0].name, "Door")
	testing.expect_value(t, scene.entities[0].components[0].fields[0].value.ints[2], 3)
	testing.expect_value(t, scene.entities[0].behaviours[0].script, format.guid_parse("9d2e41c0b7a35f6e81c4d2a90b3e7f15") or_else {})

	// A second cook finds the scene up to date.
	key := (^format.Blob_Header)(raw_data(blob)).key
	testing.expect(t, cook(options, {.Scene}).ok)
	testing.expect_value(t, cooked_key(fmt.tprintf("%s/cache/dev/%s.blob", tree.dir, guid_text(guid)), .Scene, format.scene_layout()), key)
}

@(test)
a_scene_that_names_a_missing_asset_warns :: proc(t: ^testing.T) {
	kit_meta := "guid = 00112233445566778899aabbccddeeff\nmesh.Wall = 9db8150cc7215ffc2708d20d77cf60bf\n"
	scene := "scene 1\nentity 0000000000000001\ncomponent 7 Renderer\n\tmesh = $9db8150cc7215ffc2708d20d77cf60bf\n\tskin = $ffeeddccbbaa99887766554433221100\n\tnone = $0\n"
	tree := make_tree(t, {{"content/kit.glb", ""}, {"content/kit.glb.meta", kit_meta}, {"content/level.scene", scene}})
	defer remove_tree(tree)

	pass := cook(tree_options(tree), {.Scene})
	testing.expect(t, pass.ok)
	warnings := make([dynamic]string, context.temp_allocator)
	for p in pass.problems.list {
		if strings.contains(p.text, "which is not in the content") {
			append(&warnings, p.text)
		}
	}
	// A sub-asset in a .meta file counts, and so does none.
	testing.expect_value(t, len(warnings), 1)
	if len(warnings) == 1 {
		testing.expect(t, strings.contains(warnings[0], "Renderer.skin"))
	}
}

@(test)
a_broken_scene_names_its_line :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/bad.scene", "scene 1\nentity 0000000000000001\ncomponent x Transform\n"}})
	defer remove_tree(tree)
	errors: Errors
	defer release_errors(&errors)
	context.logger = capture_errors(&errors)

	testing.expect(t, !cook(tree_options(tree), {.Scene}).ok)
	expect_error(t, &errors, "bad.scene:3: a component needs its stable ID")
}
