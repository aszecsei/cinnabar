package cook

import "core:fmt"
import "core:os"
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
			{"content/levels/hall.scene", `scene 2
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
	testing.expect_value(t, cooked_key(fmt.tprintf("%s/cache/%s.blob", tree.dir, guid_text(guid)), .Scene, format.scene_layout()), key)
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

@(private = "file")
LAMP_META :: "guid = 11111111111111111111111111111111\n"
@(private = "file")
DOOR_META :: "guid = 22222222222222222222222222222222\n"

@(private = "file")
LAMP :: `scene 2
entity 1000000000000001
name = "Lamp"
entity 1000000000000002
name = "Bulb"
parent = @1000000000000001
component 35 Point_Light
	intensity = 1.0
`

@(private = "file")
DOOR :: `scene 2
entity 2000000000000001
name = "Door"
entity 2000000000000002
parent = @2000000000000001
prefab = $11111111111111111111111111111111
`

@(private = "file")
HALL :: `scene 2
entity 5000000000000001
prefab = $22222222222222222222222222222222
component 1 Transform
	position = [1, 2, 3]
entity 5000000000000001#2000000000000002#1000000000000002
component 35 Point_Light
	intensity = 0.25
`

@(private = "file")
source_of :: proc(pass: Pass, path: string) -> (Asset_Source, bool) {
	for a in pass.assets {
		if strings.has_suffix(a.path, path) {
			return a, true
		}
	}
	return {}, false
}

@(test)
scenes_cook_their_prefabs_flat :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/lamp.prefab", LAMP},
			{"content/lamp.prefab.meta", LAMP_META},
			{"content/door.prefab", DOOR},
			{"content/door.prefab.meta", DOOR_META},
			{"content/hall.scene", HALL},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Scene})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Prefab], 2)
	testing.expect_value(t, pass.cooked[.Scene], 1)

	// The scene's blob is flat: the door's root, the lamp's root and the bulb, with the scene's intensity.
	hall_guid := tree_guid(t, tree, "hall.scene")
	hall, ok := format.scene_read(tree_blob(t, tree, hall_guid), context.temp_allocator)
	testing.expect(t, ok && len(hall.entities) == 3)
	if len(hall.entities) == 3 {
		bulb := hall.entities[2]
		testing.expect_value(t, bulb.id, format.scene_path_id_of({0x5000000000000001, 0x2000000000000002, 0x1000000000000002}))
		testing.expect_value(t, bulb.name, "Bulb")
		testing.expect_value(t, bulb.components[0].fields[0].value.floats[0], 0.25)
		testing.expect_value(t, hall.entities[0].components[0].fields[0].value.ints[2], 3)
	}

	// A prefab's blob is a flat scene under its own kind.
	door_guid := format.guid_parse("22222222222222222222222222222222") or_else {}
	door_blob := tree_blob(t, tree, door_guid)
	testing.expect_value(t, (^format.Blob_Header)(raw_data(door_blob)).kind, format.Asset_Kind.Prefab)
	door, door_ok := format.scene_read(door_blob, context.temp_allocator)
	testing.expect(t, door_ok && len(door.entities) == 3)

	// A scene depends on the prefabs that it instantiates, and a prefab on the ones inside it.
	hall_source, _ := source_of(pass, "hall.scene")
	testing.expect(t, len(hall_source.dependencies) == 1 && hall_source.dependencies[0] == door_guid)
	door_source, _ := source_of(pass, "door.prefab")
	testing.expect(t, len(door_source.dependencies) == 1 && door_source.dependencies[0] == (format.guid_parse("11111111111111111111111111111111") or_else {}))

	// Editing the nested prefab cooks the scene again, through the door.
	key := (^format.Blob_Header)(raw_data(tree_blob(t, tree, hall_guid))).key
	testing.expect(t, cook(options, {.Scene}).current[.Scene] == 1)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/lamp.prefab", tree.dir), transmute([]byte)strings.concatenate({LAMP, "\tradius = 4.0\n"}, context.temp_allocator)) == nil)
	again := cook(options, {.Scene})
	testing.expect_value(t, again.cooked[.Scene], 1)
	testing.expect_value(t, again.cooked[.Prefab], 2)
	testing.expect(t, (^format.Blob_Header)(raw_data(tree_blob(t, tree, hall_guid))).key != key)
}

@(test)
a_missing_prefab_warns_and_the_scene_cooks :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/hall.scene", HALL}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Scene})
	testing.expect(t, pass.ok)
	found := false
	for p in pass.problems.list {
		found ||= strings.contains(p.text, "22222222222222222222222222222222 is missing")
	}
	testing.expect(t, found)
	hall, ok := format.scene_read(tree_blob(t, tree, tree_guid(t, tree, "hall.scene")), context.temp_allocator)
	testing.expect(t, ok && len(hall.entities) == 1)
}

@(test)
broken_prefabs_keep_their_blobs :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:     string,
		files:    []struct {
			path, text: string,
		},
		fragment: string,
	} {
		{
			"two roots",
			{{"content/door.prefab", "scene 2\nentity 0000000000000001\nentity 0000000000000002\n"}, {"content/door.prefab.meta", DOOR_META}},
			"door.prefab: a prefab has one root, an entity without a parent, not 2",
		},
		{
			"a direct cycle",
			{{"content/door.prefab", "scene 2\nentity 0000000000000001\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $22222222222222222222222222222222\n"}, {"content/door.prefab.meta", DOOR_META}},
			"contains itself",
		},
		{
			"a cycle through another prefab",
			{
				{"content/door.prefab", DOOR},
				{"content/door.prefab.meta", DOOR_META},
				{"content/lamp.prefab", "scene 2\nentity 0000000000000001\nentity 0000000000000002\nparent = @0000000000000001\nprefab = $22222222222222222222222222222222\n"},
				{"content/lamp.prefab.meta", LAMP_META},
				{"content/hall.scene", HALL},
			},
			"hall.scene: instance 5000000000000001: the prefab 22222222222222222222222222222222 contains itself: 22222222222222222222222222222222 contains 11111111111111111111111111111111 contains 22222222222222222222222222222222",
		},
		{
			"an instance of a script",
			{{"content/door.luau", "return 1"}, {"content/door.luau.meta", DOOR_META}, {"content/hall.scene", HALL}},
			"hall.scene: entity 5000000000000001: the asset 22222222222222222222222222222222 is not a prefab",
		},
	}
	for c in cases {
		tree := make_tree(t, c.files)
		defer remove_tree(tree)
		errors: Errors
		defer release_errors(&errors)
		context.logger = capture_errors(&errors)
		pass := cook(tree_options(tree), {.Scene})
		testing.expectf(t, !pass.ok, "%s cooked", c.name)
		testing.expectf(t, pass.cooked[.Scene] + pass.cooked[.Prefab] == 0, "%s wrote a blob", c.name)
		expect_error(t, &errors, c.fragment)
	}
}

@(test)
a_new_prefab_has_one_root_named_for_its_file :: proc(t: ^testing.T) {
	text := template_text(.Prefab, "front door")
	scene, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "problems: %v", problems)
	root, roots := format.prefab_root(scene)
	testing.expect_value(t, roots, 1)
	if roots == 1 {
		testing.expect_value(t, root.name, "front door")
		testing.expect(t, root.id != 0 && len(root.components) == 1 && root.components[0].id == format.SCENE_TRANSFORM_ID)
	}
}
