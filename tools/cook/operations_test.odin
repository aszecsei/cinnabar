package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// Ops is a content tree with the daemon's index of it, which each operation updates as the daemon's pass does.
@(private = "file")
Ops :: struct {
	tree:    Tree,
	options: Cook_Options,
	index:   Index,
	pass:    Pass,
	force:   map[format.Guid]bool,
}

@(private = "file")
ops_open :: proc(t: ^testing.T, files: []struct {
		path, text: string,
	}, typed := false) -> (o: Ops) {
	o.tree = make_tree(t, files)
	o.options = typed ? typed_options(t, o.tree) : tree_options(o.tree)
	ops_pass(&o)
	return
}

@(private = "file")
ops_close :: proc(o: ^Ops) {
	index_destroy(&o.index)
	remove_tree(o.tree)
}

@(private = "file")
ops_pass :: proc(o: ^Ops) {
	o.pass = cook(o.options, ALL_KINDS, log_problems = false, force = o.force)
	o.force = nil
	index_destroy(&o.index)
	index_build(&o.index, o.pass, o.options.roots[:])
}

@(private = "file")
operate :: proc(o: ^Ops, message: cook_link.Message) -> cook_link.Operation_Result {
	force := make(map[format.Guid]bool, context.temp_allocator)
	result, is_operation := run_operation(o.options.roots[:], &o.index, message, &force)
	assert(is_operation)
	o.force = force
	ops_pass(o)
	return result
}

@(private = "file")
guid_at :: proc(o: ^Ops, path: string) -> string {
	for guid, a in o.index.assets {
		if a.path == path {
			// The index's strings go with it at the next pass.
			return strings.clone(guid, context.temp_allocator)
		}
	}
	return ""
}

@(private = "file")
exists :: proc(o: ^Ops, path: string) -> bool {
	return os.exists(fmt.tprintf("%s/content/%s", o.tree.dir, path))
}

@(test)
templates_make_assets_that_cook :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/scripts/keep.luau", "return 1"}}, typed = true)
	defer ops_close(&o)

	module := operate(&o, cook_link.Create_Asset{template = .Script, root = "game", folder = "scripts", name = "util"})
	behaviour := operate(&o, cook_link.Create_Asset{template = .Behaviour, root = "game", folder = "scripts", name = "door bell"})
	scene := operate(&o, cook_link.Create_Asset{template = .Scene, root = "game", folder = "", name = "hall.scene"})
	for r in ([]cook_link.Operation_Result{module, behaviour, scene}) {
		testing.expectf(t, r.error == "" && len(r.guids) == 1, "%v", r)
	}
	testing.expect(t, o.pass.ok)
	testing.expect_value(t, guid_at(&o, "scripts/util.luau"), module.guids[0])
	testing.expect_value(t, o.index.assets[behaviour.guids[0]].behaviour, "Door_Bell")
	testing.expect_value(t, o.index.assets[scene.guids[0]].path, "hall.scene")
	testing.expect_value(t, o.index.assets[scene.guids[0]].kind, cook_link.Asset_Kind.Scene)
}

@(test)
a_failed_operation_changes_nothing :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/a.luau", "return 1"}, {"content/b.luau", "return 2"}, {"content/sub/b.luau", "return 3"}})
	defer ops_close(&o)
	a, b := guid_at(&o, "a.luau"), guid_at(&o, "b.luau")

	for message in ([]cook_link.Message {
			cook_link.Create_Asset{template = .Script, root = "game", name = "a"},
			cook_link.Create_Asset{template = .Script, root = "game", name = "con"},
			cook_link.Create_Asset{template = .Script, root = "game", name = "x/y"},
			cook_link.Create_Asset{template = .Script, root = "game", folder = "../outside", name = "x"},
			cook_link.Create_Asset{template = .Script, root = "nowhere", name = "x"},
			cook_link.Create_Folder{root = "game", path = "sub"},
			cook_link.Create_Folder{root = "game", path = ".hidden"},
			cook_link.Rename_Asset{guid = a, name = "b"},
			cook_link.Rename_Folder{root = "game", path = "", name = "x"},
			cook_link.Move_Assets{guids = {a, b}, root = "game", folder = "sub"},
			cook_link.Move_Assets{guids = {a}, root = "game", folder = "missing"},
			cook_link.Delete_Assets{folders = {{"game", ""}}},
			cook_link.Delete_Assets{guids = {"00000000000000000000000000000000"}},
			cook_link.Set_Import_Settings{guid = a, settings = {{"native", "maybe"}}},
			cook_link.Set_Import_Settings{guid = a, settings = {{"colour", "red"}}},
			cook_link.Reimport{guids = {"nope"}},
		}) {
		result := operate(&o, message)
		testing.expectf(t, result.error != "", "%v succeeded", message)
	}
	testing.expect(t, exists(&o, "a.luau") && exists(&o, "a.luau.meta"))
	testing.expect(t, !exists(&o, "sub/a.luau") && !exists(&o, "sub/a.luau.meta"))
	testing.expect_value(t, len(o.index.assets), 3)
	testing.expect_value(t, guid_at(&o, "a.luau"), a)
}

@(test)
moves_and_renames_keep_the_guid :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/a.luau", "return 1"}, {"content/sub/keep.luau", "return 2"}})
	defer ops_close(&o)
	a := guid_at(&o, "a.luau")

	testing.expect_value(t, operate(&o, cook_link.Move_Assets{guids = {a}, root = "game", folder = "sub"}).error, "")
	testing.expect_value(t, guid_at(&o, "sub/a.luau"), a)
	testing.expect(t, !exists(&o, "a.luau.meta") && exists(&o, "sub/a.luau.meta"))

	testing.expect_value(t, operate(&o, cook_link.Rename_Asset{guid = a, name = "b"}).error, "")
	testing.expect_value(t, guid_at(&o, "sub/b.luau"), a)
	// Only the case changes, and the file is its own destination.
	testing.expect_value(t, operate(&o, cook_link.Rename_Asset{guid = a, name = "B"}).error, "")
	testing.expect_value(t, guid_at(&o, "sub/B.luau"), a)

	testing.expect_value(t, operate(&o, cook_link.Create_Folder{root = "game", path = "sub/deep"}).error, "")
	testing.expect_value(t, operate(&o, cook_link.Rename_Folder{root = "game", path = "sub", name = "moved"}).error, "")
	testing.expect_value(t, guid_at(&o, "moved/B.luau"), a)
	testing.expect(t, slice_has_folder(o.index.folders, {"game", "moved/deep"}))
	testing.expect_value(t, len(o.pass.problems.list), 0)
}

@(private = "file")
slice_has_folder :: proc(folders: []cook_link.Folder, f: cook_link.Folder) -> bool {
	for g in folders {
		if g == f {
			return true
		}
	}
	return false
}

@(test)
a_duplicate_has_a_new_guid_and_the_settings :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/a.luau", "return 1"}, {"content/a.luau.meta", "guid = 00112233445566778899aabbccddee01\nnative = true\n"}})
	defer ops_close(&o)
	a := guid_at(&o, "a.luau")

	first := operate(&o, cook_link.Duplicate_Assets{guids = {a}})
	second := operate(&o, cook_link.Duplicate_Assets{guids = {a}})
	testing.expect(t, first.error == "" && second.error == "")
	testing.expect_value(t, guid_at(&o, "a_copy.luau"), first.guids[0])
	testing.expect_value(t, guid_at(&o, "a_copy_2.luau"), second.guids[0])
	testing.expect(t, first.guids[0] != a)
	copy := o.index.assets[first.guids[0]]
	testing.expect(t, len(copy.settings) == 1 && copy.settings[0] == cook_link.Setting{"native", "true"})
	testing.expect(t, o.pass.ok)
}

@(test)
import_settings_are_checked_and_cook_again :: proc(t: ^testing.T) {
	meta := "# a comment that stays\nguid = 00112233445566778899aabbccddee01\nold = 1\n"
	o := ops_open(t, {{"content/a.luau", "return 1"}, {"content/a.luau.meta", meta}})
	defer ops_close(&o)
	a := guid_at(&o, "a.luau")

	// A setting that the importer does not know stays as the file has it.
	result := operate(&o, cook_link.Set_Import_Settings{guid = a, settings = {{"old", "1"}, {"native", "true"}}})
	testing.expect_value(t, result.error, "")
	testing.expect_value(t, o.pass.cooked[.Script], 1)
	text, _ := os.read_entire_file(fmt.tprintf("%s/content/a.luau.meta", o.tree.dir), context.temp_allocator)
	testing.expect_value(t, string(text), "# a comment that stays\nguid = 00112233445566778899aabbccddee01\nold = 1\nnative = true\n")

	testing.expect_value(t, operate(&o, cook_link.Set_Import_Settings{guid = a, settings = {}}).error, "")
	testing.expect_value(t, len(o.index.assets[a].settings), 0)
}

@(test)
a_reimport_cooks_an_up_to_date_asset :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/a.luau", "return 1"}, {"content/b.scene", "scene 1\n"}})
	defer ops_close(&o)
	ops_pass(&o)
	testing.expect_value(t, o.pass.cooked[.Script] + o.pass.cooked[.Scene], 0)

	result := operate(&o, cook_link.Reimport{guids = {guid_at(&o, "a.luau"), guid_at(&o, "b.scene")}})
	testing.expect_value(t, result.error, "")
	testing.expect_value(t, o.pass.cooked[.Script], 1)
	testing.expect_value(t, o.pass.cooked[.Scene], 1)
}

@(test)
a_meta_file_without_its_asset_is_a_warning :: proc(t: ^testing.T) {
	o := ops_open(t, {{"content/moved.luau.meta", "guid = 00112233445566778899aabbccddee01\n"}})
	defer ops_close(&o)
	testing.expect(t, o.pass.ok)
	problems := o.index.problems[""]
	testing.expect(t, len(problems) == 1 && !problems[0].error && strings.has_suffix(problems[0].file, "moved.luau.meta"))
}

@(test)
names_follow_windows_and_luau :: proc(t: ^testing.T) {
	for name in ([]string{"door", "door bell", "a.b", "com10"}) {
		testing.expectf(t, valid_name(name), "%q is a name", name)
	}
	for name in ([]string{"", ".hidden", "trailing.", " lead", "a/b", "a:b", "CON", "nul.txt", "com1", "LPT9"}) {
		testing.expectf(t, !valid_name(name), "%q is not a name", name)
	}
	testing.expect_value(t, class_name("door bell"), "Door_Bell")
	testing.expect_value(t, class_name("player_controller"), "Player_Controller")
	testing.expect_value(t, class_name("2d-camera"), "B2d_Camera")
	testing.expect_value(t, class_name("..."), "Behaviour")
}
