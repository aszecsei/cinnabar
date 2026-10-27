package cook

import "core:fmt"
import "core:os"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private)
has_blob :: proc(t: ^testing.T, tree: Tree, path: string) -> bool {
	return os.exists(fmt.tprintf("%s/cache/%s.blob", tree.dir, guid_text(tree_guid(t, tree, path))))
}

@(test)
a_broken_script_fails_with_its_dependents_alone :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/broken.luau", "return require('./nothing')"},
			{"content/user.luau", "return require('./broken')"},
			{"content/indirect.luau", "return require('./user')"},
			{"content/a.luau", "return require('./b')"},
			{"content/b.luau", "return require('./a')"},
			{"content/fine.luau", "return require('./helper')"},
			{"content/helper.luau", "return 1"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)

	pass := cook(tree_options(tree), {.Script})
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Script], 2)
	expect_error(t, &errors, `broken.luau:1: cannot require "./nothing"`)
	expect_error(t, &errors, "user.luau: not cooked, because it requires game/broken.luau")
	expect_error(t, &errors, "indirect.luau: not cooked, because it requires game/user.luau")
	expect_error(t, &errors, "require cycle")
	for path in ([]string{"broken.luau", "user.luau", "indirect.luau", "a.luau", "b.luau"}) {
		testing.expectf(t, !has_blob(t, tree, path), "%s cooked", path)
	}
	testing.expect(t, has_blob(t, tree, "fine.luau"))
	testing.expect(t, has_blob(t, tree, "helper.luau"))
}

@(test)
assets_of_any_kind_that_share_a_guid_do_not_cook :: proc(t: ^testing.T) {
	meta := "guid = 00112233445566778899aabbccddeeff\n"
	tree := make_tree(
		t,
		{
			{"content/a.luau", "return 1"},
			{"content/a.luau.meta", meta},
			{"content/b.scene", "scene 1\n"},
			{"content/b.scene.meta", meta},
			{"content/c.luau", "return 2"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)

	pass := cook(tree_options(tree), ALL_KINDS)
	testing.expect(t, !pass.ok)
	expect_error(t, &errors, "has the same GUID as")
	testing.expect(t, !has_blob(t, tree, "a.luau"))
	testing.expect(t, has_blob(t, tree, "c.luau"))
}

@(test)
a_cook_that_writes_blobs_moves_the_generation :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}, {"content/b.scene", "scene 1\n"}})
	defer remove_tree(tree)
	options := tree_options(tree)

	first := cook(options, ALL_KINDS)
	testing.expect(t, first.ok)
	testing.expect_value(t, first.generation, 1)
	testing.expect_value(t, read_generation(config_dir(options)), 1)

	// Nothing changed, so nothing was written and the running game has nothing to check.
	again := cook(options, ALL_KINDS)
	testing.expect_value(t, again.generation, 1)
	testing.expect_value(t, again.current[.Script], 1)
	testing.expect_value(t, again.current[.Scene], 1)

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/a.luau", tree.dir), transmute([]byte)string("return 2")) == nil)
	changed := cook(options, ALL_KINDS)
	testing.expect_value(t, changed.cooked[.Script], 1)
	testing.expect_value(t, changed.cooked[.Scene], 0)
	testing.expect_value(t, changed.generation, 2)
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", config_dir(options), format.GENERATION_FILE), context.temp_allocator)
	testing.expect(t, err == nil && string(data) == "2\n")
}

@(test)
one_cook_at_a_time_uses_a_cache :: proc(t: ^testing.T) {
	tree := make_tree(t, {})
	defer remove_tree(tree)
	cache := fmt.tprintf("%s/cache", tree.dir)
	held, first := lock_cache(cache)
	testing.expect_value(t, first, Lock_Result.Locked)
	_, second := lock_cache(cache)
	testing.expect_value(t, second, Lock_Result.Held)
	unlock_cache(&held)
	again, third := lock_cache(cache)
	testing.expect_value(t, third, Lock_Result.Locked)
	unlock_cache(&again)
	// The lock deletes itself, so it never looks held after a crash.
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", cache, LOCK_FILE)))
}

@(test)
the_watcher_sees_changes_under_its_directories :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/scripts/a.luau", "return 1"}})
	defer remove_tree(tree)
	dirs := []string{fmt.tprintf("%s/content", tree.dir)}
	watcher: Watcher
	testing.expect(t, watcher_open(&watcher, dirs))
	defer watcher_close(&watcher)

	testing.expect_value(t, watcher_wait(&watcher, 0), Wait_Result.Timeout)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/scripts/a.luau", tree.dir), transmute([]byte)string("return 2")) == nil)
	testing.expect_value(t, watcher_wait(&watcher, 5000), Wait_Result.Changed)
	// Another thread wakes the wait, as the cook link does when a message arrives.
	for watcher_wait(&watcher, 100) == .Changed {
	}
	watcher_wake(&watcher)
	testing.expect_value(t, watcher_wait(&watcher, 5000), Wait_Result.Woken)
}
