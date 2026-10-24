package cook

import "core:fmt"
import "core:os"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"

@(private = "file")
find_asset :: proc(index: ^Index, path: string) -> (cook_link.Asset, bool) {
	for _, a in index.assets {
		if a.path == path {
			return a, true
		}
	}
	return {}, false
}

@(test)
the_index_knows_each_asset_and_its_problems :: proc(t: ^testing.T) {
	door_meta := "guid = 9d2e41c0b7a35f6e81c4d2a90b3e7f15\nnative = true\n"
	tree := make_tree(
		t,
		{
			{"content/scripts/door.luau", "local util = require('./util')\nreturn Behaviour.define('Door', {speed = Field.number(util.speed)})"},
			{"content/scripts/door.luau.meta", door_meta},
			{"content/scripts/util.luau", "return {speed = 1}"},
			{"content/scripts/broken.luau", "return require('./nothing')"},
			{"content/levels/hall.scene", "scene 1\nentity 5f3a9c01e2b47d10\nbehaviour 9d2e41c0b7a35f6e81c4d2a90b3e7f15\nbehaviour 00000000000000000000000000000001\n"},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, ALL_KINDS, log_problems = false)
	index: Index
	index_build(&index, pass, options.roots[:])
	defer index_destroy(&index)

	testing.expect_value(t, len(index.assets), 4)
	door, door_found := find_asset(&index, "scripts/door.luau")
	testing.expect(t, door_found)
	testing.expect_value(t, door.guid, "9d2e41c0b7a35f6e81c4d2a90b3e7f15")
	testing.expect_value(t, door.kind, cook_link.Asset_Kind.Script)
	testing.expect_value(t, door.root, "game")
	testing.expect_value(t, door.status, cook_link.Asset_Status.Current)
	testing.expect_value(t, door.behaviour, "Door")
	testing.expect(t, len(door.settings) == 1 && door.settings[0] == cook_link.Setting{"native", "true"})
	util, _ := find_asset(&index, "scripts/util.luau")
	testing.expect(t, len(door.dependencies) == 1 && door.dependencies[0] == util.guid)

	broken, _ := find_asset(&index, "scripts/broken.luau")
	testing.expect_value(t, broken.status, cook_link.Asset_Status.Failed)
	testing.expect_value(t, broken.errors, 1)
	problems := index.problems[broken.guid]
	testing.expect(t, len(problems) == 1 && problems[0].line == 1 && problems[0].error)
	testing.expect_value(t, problems[0].file, fmt.tprintf("%s/content/scripts/broken.luau", tree.dir))

	// A scene depends on the scripts that its behaviours name, and warns of a missing one.
	hall, _ := find_asset(&index, "levels/hall.scene")
	testing.expect_value(t, hall.kind, cook_link.Asset_Kind.Scene)
	testing.expect_value(t, len(hall.dependencies), 2)
	testing.expect_value(t, hall.warnings, 1)
	testing.expect_value(t, len(index.folders), 2)
}

@(test)
the_diff_says_what_a_pass_changed :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}, {"content/b.luau", "return 2"}, {"content/old/c.luau", "return require('./missing')"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	first: Index
	index_build(&first, cook(options, ALL_KINDS, log_problems = false), options.roots[:])
	defer index_destroy(&first)

	// Nothing changed, so nothing differs.
	same: Index
	index_build(&same, cook(options, ALL_KINDS, log_problems = false), options.roots[:])
	testing.expect(t, !index_changed(index_diff(&first, &same)))
	index_destroy(&same)

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/a.luau", tree.dir), transmute([]byte)string("return require('./gone')")) == nil)
	os.remove_all(fmt.tprintf("%s/content/old", tree.dir))
	os.make_directory(fmt.tprintf("%s/content/new", tree.dir))
	next: Index
	index_build(&next, cook(options, ALL_KINDS, log_problems = false), options.roots[:])
	defer index_destroy(&next)
	changes := index_diff(&first, &next)
	testing.expect(t, len(changes.delta.changed) == 1 && changes.delta.changed[0].path == "a.luau")
	testing.expect_value(t, len(changes.delta.removed), 1)
	testing.expect(t, len(changes.delta.added_folders) == 1 && changes.delta.added_folders[0].path == "new")
	testing.expect(t, len(changes.delta.removed_folders) == 1 && changes.delta.removed_folders[0].path == "old")
	// a.luau has a problem now, and c.luau's went with it.
	testing.expect_value(t, len(changes.problems), 2)
	for p in changes.problems {
		testing.expect(t, (p.guid == changes.delta.changed[0].guid) == (len(p.problems) == 1))
	}
}
