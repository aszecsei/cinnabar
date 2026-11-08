package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

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
	unlock(&held)
	again, third := lock_cache(cache)
	testing.expect_value(t, third, Lock_Result.Locked)
	unlock(&again)
	// The lock deletes itself, so it never looks held after a crash.
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", cache, LOCK_FILE)))
}

// Root_Cook is a cook of scripts on a thread of its own, as another cook process would be, such as a release cook
// while the daemon runs.
@(private = "file")
Root_Cook :: struct {
	options: Cook_Options,
	// The files to find in the pass, by the end of their paths, and the GUID that the pass gave each one, or none.
	names:   []string,
	guids:   []format.Guid,
	ok:      bool,
	errors:  int,
	// Set when the cook starts, so a test can wait for it.
	started: sync.Sema,
}

@(private = "file")
start_root_cook :: proc(c: ^Root_Cook) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(c, proc(c: ^Root_Cook) {
		sync.sema_post(&c.started)
		pass := cook(c.options, {.Script}, log_problems = false)
		c.ok = pass.ok
		for p in pass.problems.list {
			c.errors += int(p.error)
		}
		// The pass is in this thread's temporary allocator, so the GUIDs are copied out.
		for a in pass.assets {
			for name, i in c.names {
				if strings.has_suffix(a.path, name) {
					c.guids[i] = a.meta.guid
				}
			}
		}
	})
}

@(private = "file")
root_cook :: proc(tree: Tree, cache: string, names: []string) -> Root_Cook {
	options := tree_options(tree)
	options.cache = fmt.tprintf("%s/%s", tree.dir, cache)
	return {options = options, names = names, guids = make([]format.Guid, len(names), context.temp_allocator)}
}

@(test)
two_cooks_of_one_root_give_a_new_file_one_guid :: proc(t: ^testing.T) {
	COUNT :: 32
	files := make([]struct {
			path, text: string,
		}, COUNT, context.temp_allocator)
	names := make([]string, COUNT, context.temp_allocator)
	for i in 0 ..< COUNT {
		names[i] = fmt.tprintf("/s%02d.luau", i)
		files[i] = {fmt.tprintf("content%s", names[i]), fmt.tprintf("return %d", i)}
	}
	tree := make_tree(t, files)
	defer remove_tree(tree)

	// Two caches, as the daemon's and a release cook's, and one root, whose files have no .meta files yet.
	cooks := [2]Root_Cook{root_cook(tree, "cache_a", names), root_cook(tree, "cache_b", names)}
	threads: [2]^thread.Thread
	for &c, i in cooks {
		threads[i] = start_root_cook(&c)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for c in cooks {
		testing.expect(t, c.ok)
		testing.expect_value(t, c.errors, 0)
	}
	for name, i in names {
		guid := tree_guid(t, tree, name[1:])
		for c in cooks {
			testing.expectf(t, c.guids[i] == guid, "%s: a cook used %s, and its .meta file has %s", name, guid_text(c.guids[i]), guid_text(guid))
			testing.expectf(t, os.exists(fmt.tprintf("%s/%s.blob", config_dir(c.options), guid_text(guid))), "%s has no blob in %s", name, c.options.cache)
		}
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/content/%s", tree.dir, LOCK_FILE)))
}

@(test)
a_cook_looks_again_under_the_roots_lock_before_it_gives_a_guid :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}})
	defer remove_tree(tree)
	root := fmt.tprintf("%s/content", tree.dir)
	lock, locked := lock_root(root)
	testing.expect(t, locked)

	c := root_cook(tree, "cache", {"/a.luau"})
	th := start_root_cook(&c)
	sync.sema_wait(&c.started)
	time.sleep(100 * time.Millisecond)
	// Another cook gives the file its GUID while this one waits for the lock.
	meta := "guid = 00112233445566778899aabbccddeeff\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.luau.meta", root), transmute([]byte)meta) == nil)
	unlock(&lock)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, c.ok)
	testing.expect_value(t, guid_text(c.guids[0]), "00112233445566778899aabbccddeeff")
	data, err := os.read_entire_file(fmt.tprintf("%s/a.luau.meta", root), context.temp_allocator)
	testing.expect(t, err == nil && string(data) == meta)
}

@(test)
an_asset_that_leaves_during_the_scan_gets_no_meta :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}, {"content/b.luau", "return 2"}})
	defer remove_tree(tree)
	root := fmt.tprintf("%s/content", tree.dir)
	lock, locked := lock_root(root)
	testing.expect(t, locked)

	c := root_cook(tree, "cache", {"/a.luau", "/b.luau"})
	th := start_root_cook(&c)
	sync.sema_wait(&c.started)
	time.sleep(100 * time.Millisecond)
	// An operation moves or deletes the file while the cook waits to give it a GUID.
	testing.expect(t, os.remove(fmt.tprintf("%s/a.luau", root)) == nil)
	unlock(&lock)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, c.ok)
	testing.expect_value(t, c.errors, 0)
	testing.expect_value(t, c.guids[0], format.Guid{})
	testing.expect(t, !os.exists(fmt.tprintf("%s/a.luau.meta", root)))
	testing.expect(t, c.guids[1] == tree_guid(t, tree, "b.luau"))
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
