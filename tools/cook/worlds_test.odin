package cook

import "core:fmt"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
TOWN_GUID :: "0123456789abcdef0123456789abcdef"
@(private = "file")
FOREST_GUID :: "fedcba9876543210fedcba9876543210"

@(private = "file")
WORLD ::
	`world 1
# A town that always loads, and a forest that streams.
scene $` +
	TOWN_GUID +
	`
	persistent = true
	load_distance = 3
scene $` +
	FOREST_GUID +
	`
	min = [150000000000, -10, -20]
	max = [150000000040, 10, 20]
	load_distance = 25
`

@(test)
worlds_parse_their_scenes :: proc(t: ^testing.T) {
	scenes, problems := world_parse(WORLD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(scenes), 2)
	if len(scenes) != 2 {
		return
	}
	town, forest := scenes[0].record, scenes[1].record
	testing.expect_value(t, town.flags, format.World_Scene_Flags{.Persistent})
	testing.expect_value(t, town.load_distance, 0)
	testing.expect_value(t, scenes[0].line, 3)
	testing.expect_value(t, forest.flags, format.World_Scene_Flags{})
	testing.expect_value(t, forest.min, [3]i64{150_000_000_000 << 24, -10 << 24, -20 << 24})
	testing.expect_value(t, forest.max, [3]i64{150_000_000_040 << 24, 10 << 24, 20 << 24})
	testing.expect_value(t, forest.load_distance, 25)
	// An unload_distance that the text leaves out is a quarter more than the load distance.
	testing.expect_value(t, forest.unload_distance, 31.25)
	testing.expect_value(t, scenes[1].line, 6)

	scenes, problems = world_parse(
		"world 1\nscene $" +
		FOREST_GUID +
		"\nmin = [0, 0, 0]\nmax = [1, 1, 1]\nload_distance = 10\nunload_distance = 12\n",
		context.temp_allocator,
	)
	testing.expect(t, len(problems) == 0 && len(scenes) == 1)
	testing.expect_value(t, scenes[0].record.unload_distance, 12)
}

@(test)
world_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	HEAD :: "world 1\nscene $" + FOREST_GUID + "\n"
	BOUNDS :: "min = [0, 0, 0]\nmax = [1, 1, 1]\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"scene $" + FOREST_GUID + "\n", 1},
		{"world 2\n", 1},
		{"world 1\nmin = [0, 0, 0]\n", 2},
		{"world 1\nscene forest\n", 2},
		{"world 1\nscene $0123\n", 2},
		{HEAD + BOUNDS, 2},
		{HEAD + "max = [1, 1, 1]\nload_distance = 5\n", 2},
		{HEAD + "min = [0, 0, 0]\nload_distance = 5\n", 2},
		{HEAD + BOUNDS + "load_distance = 0\n", 2},
		{HEAD + BOUNDS + "load_distance = -4\n", 2},
		{HEAD + BOUNDS + "load_distance = 10\nunload_distance = 9\n", 2},
		{HEAD + "min = [2, 0, 0]\nmax = [1, 1, 1]\nload_distance = 5\n", 2},
		{HEAD + "min = [0, 2, 0]\nmax = [1, 1, 1]\nload_distance = 5\n", 2},
		{HEAD + BOUNDS + "load_distance = 5\nload_distance = 6\n", 6},
		{HEAD + BOUNDS + "load_distance = 5\nweight = 6\n", 6},
		{HEAD + "min = [0, 0]\nmax = [1, 1, 1]\nload_distance = 5\n", 3},
		{HEAD + "min = [1e30, 0, 0]\nmax = [1, 1, 1]\nload_distance = 5\n", 3},
		{HEAD + "persistent = maybe\n", 3},
		{HEAD + "persistent\n", 3},
		{HEAD + "persistent = true\nscene $" + FOREST_GUID + "\npersistent = true\n", 4},
	}
	for c in cases {
		_, problems := world_parse(c.text, context.temp_allocator)
		testing.expectf(
			t,
			len(problems) > 0 && problems[0].line == c.line,
			"%q: %v",
			c.text,
			problems,
		)
	}
}

@(test)
a_world_has_at_most_the_most_scenes :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "world 1\n")
	for i in 0 ..< format.MAX_WORLD_SCENES + 1 {
		fmt.sbprintf(&b, "scene $%032x\npersistent = true\n", i)
	}
	_, problems := world_parse(strings.to_string(b), context.temp_allocator)
	testing.expectf(t, len(problems) == 1, "problems: %v", problems)
	testing.expect_value(t, problems[0].line, 2 + 2 * format.MAX_WORLD_SCENES)
}

@(test)
worlds_cook_into_blobs :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/town.scene", "scene 1\n"},
			{"content/town.scene.meta", "guid = " + TOWN_GUID + "\n"},
			{"content/forest.scene", "scene 1\n"},
			{"content/forest.scene.meta", "guid = " + FOREST_GUID + "\n"},
			{"content/a.world", WORLD},
			{
				"content/broken.world",
				"world 1\nscene $" + "00000000000000000000000000000001" + "\npersistent = true\n",
			},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Scene, .World}, log_problems = false)
	// The world that names no asset fails, and the other cooks.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.World], 1)
	town, _ := format.guid_parse(TOWN_GUID)
	forest, _ := format.guid_parse(FOREST_GUID)
	data := tree_blob(t, tree, tree_guid(t, tree, "a.world"))
	blob, ok := format.world_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/a.world")
	scenes := format.world_scenes(data, blob)
	testing.expect_value(t, len(scenes), 2)
	testing.expect_value(t, scenes[0].guid, town)
	testing.expect_value(t, scenes[0].flags, format.World_Scene_Flags{.Persistent})
	testing.expect_value(t, scenes[1].guid, forest)
	testing.expect_value(t, scenes[1].min.x, 150_000_000_000 << 24)
	testing.expect_value(t, scenes[1].max.z, 20 << 24)
	testing.expect_value(t, scenes[1].unload_distance, 31.25)
	refs, refs_ok := format.blob_references(data, context.temp_allocator)
	testing.expect(t, refs_ok && len(refs) == 2 && refs[0] == town && refs[1] == forest)
	for a in pass.assets {
		if a.name == "game/a.world" {
			testing.expect_value(t, len(a.dependencies), 2)
		}
	}
	found := false
	for p in pass.problems.list {
		found ||= strings.contains(p.text, "no asset has the GUID")
	}
	testing.expect(t, found, "the broken world's problem")
}

@(test)
a_world_names_scenes_and_nothing_else :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/town.scene", "scene 1\n"},
			{"content/town.scene.meta", "guid = " + TOWN_GUID + "\n"},
			{"content/wall.world", "world 1\nscene $" + FOREST_GUID + "\npersistent = true\n"},
			{"content/notes.world.meta", "guid = " + FOREST_GUID + "\n"},
			{"content/notes.world", "world 1\n"},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Scene, .World}, log_problems = false)
	// wall.world names notes.world, which is a world.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.World], 1)
	found := false
	for p in pass.problems.list {
		found ||= strings.contains(p.text, "is not a scene") && p.line == 2
	}
	testing.expect(t, found, "the problem names the line of the scene")
}
