package cook

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import format "cinnabar:engine/asset/format"

// The content of the saved index's tests: a scene that instantiates a door, which instantiates a lamp, a yard that
// names an asset that is not there, and a script.
@(private = "file")
LAMP :: `scene 2
entity 1000000000000001
name = "Lamp"
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
`

@(private = "file")
YARD :: `scene 2
entity 6000000000000001
component 7 Renderer
	mesh = $ffeeddccbbaa99887766554433221100
`

@(private = "file")
saved_tree :: proc(t: ^testing.T) -> Tree {
	return make_tree(
		t,
		{
			{"content/lamp.prefab", LAMP},
			{"content/lamp.prefab.meta", "guid = 11111111111111111111111111111111\n"},
			{"content/door.prefab", DOOR},
			{"content/door.prefab.meta", "guid = 22222222222222222222222222222222\n"},
			{"content/levels/hall.scene", HALL},
			{"content/levels/yard.scene", YARD},
			{"content/a.luau", "return 1"},
		},
	)
}

// read_paths is what a pass read, relative to the tree's content root, in order.
@(private = "file")
read_paths :: proc(tree: Tree, pass: Pass_Report) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	for path in pass.read {
		append(&paths, strings.trim_prefix(path, fmt.tprintf("%s/content/", tree.dir)))
	}
	slice.sort(paths[:])
	return paths[:]
}

// checked_paths is what a pass looked at, relative to the tree's content root, in order.
@(private = "file")
checked_paths :: proc(tree: Tree, pass: Pass_Report) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	for path in pass.checked {
		append(&paths, strings.trim_prefix(path, fmt.tprintf("%s/content/", tree.dir)))
	}
	slice.sort(paths[:])
	return paths[:]
}

@(private = "file")
content_path :: proc(tree: Tree, path: string) -> string {
	return fmt.tprintf("%s/content/%s", tree.dir, path)
}

// write_later writes a file with a modification time that differs from the one that it had, as an edit does.
@(private = "file")
write_later :: proc(t: ^testing.T, path, text: string) {
	before, _ := os.stat(path, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)text) == nil)
	later := time.time_add(before.modification_time, time.Second)
	testing.expect(t, os.chtimes(path, later, later) == nil)
}

@(private = "file")
problems_of :: proc(index: ^Index, tree: Tree, path: string) -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	full := content_path(tree, path)
	for _, list in index.problems {
		for p in list {
			if p.file == full {
				// The next pass frees the index that it is in.
				append(&texts, strings.clone(p.text, context.temp_allocator))
			}
		}
	}
	slice.sort(texts[:])
	return texts[:]
}

@(test)
a_pass_after_one_change_looks_at_that_file_and_what_depends_on_it :: proc(t: ^testing.T) {
	tree := saved_tree(t)
	defer remove_tree(tree)
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	first := daemon_pass(&d, Changed_Everything{})
	testing.expect_value(t, len(first.read), 5)
	yard_problems := problems_of(&d.index, tree, "levels/yard.scene")
	testing.expect_value(t, len(yard_problems), 1)

	// The lamp changes: the door instantiates it, and the hall the door, so the pass looks at those three, and reads
	// no other source.
	write_later(t, content_path(tree, "lamp.prefab"), strings.concatenate({LAMP, "\tradius = 4.0\n"}, context.temp_allocator))
	pass := daemon_pass(&d, Changed_Paths{{content_path(tree, "lamp.prefab")}})
	testing.expect(t, pass.ok)
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"door.prefab", "lamp.prefab", "levels/hall.scene"}), fmt.tprint(checked_paths(tree, pass)))
	testing.expect(t, slice.equal(read_paths(tree, pass), []string{"door.prefab", "lamp.prefab", "levels/hall.scene"}), fmt.tprint(read_paths(tree, pass)))
	testing.expect_value(t, pass.cooked[.Prefab], 2)
	testing.expect_value(t, pass.cooked[.Scene], 1)
	testing.expect_value(t, pass.current[.Scene], 1)
	testing.expect_value(t, pass.current[.Script], 1)
	// The yard was not parsed, and keeps its warning, and its entry.
	testing.expect(t, slice.equal(problems_of(&d.index, tree, "levels/yard.scene"), yard_problems))
	yard := guid_text(tree_guid(t, tree, "levels/yard.scene"))
	testing.expect_value(t, d.index.assets[yard].status, .Current)

	// A full cook agrees with the keys that the pass wrote.
	full := cook(d.options, ALL_KINDS, log_problems = false)
	testing.expect_value(t, full.cooked[.Scene] + full.cooked[.Prefab], 0)
	testing.expect_value(t, full.current[.Scene], 2)
}

// Windows drops what changed when more changes than its buffer holds, and the watcher then says that everything
// changed. The pass after lists every directory, and reads only what changed.
@(test)
a_dropped_buffer_makes_a_full_scan :: proc(t: ^testing.T) {
	tree := saved_tree(t)
	defer remove_tree(tree)
	dir := fmt.tprintf("%s/content", tree.dir)
	watcher: Watcher
	testing.expect(t, watcher_open(&watcher, {dir}))
	defer watcher_close(&watcher)
	// The first change completes the read. What changes before the next read waits in Windows's buffer, which this
	// overfills.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/first.txt", dir), transmute([]byte)string("1")) == nil)
	time.sleep(100 * time.Millisecond)
	for i in 0 ..< 200 {
		name := fmt.tprintf("%s/%s_%03d.txt", dir, strings.repeat("long_name_", 8, context.temp_allocator), i)
		testing.expect(t, os.write_entire_file(name, transmute([]byte)string("x")) == nil)
	}
	for watcher_wait(&watcher, 500) == .Changed {
	}
	_, everything := watcher_take(&watcher, context.temp_allocator).(Changed_Everything)
	testing.expect(t, everything, "an overfilled buffer is a change of everything")
	testing.expect(t, watcher_take(&watcher, context.temp_allocator) == nil, "a take forgets what it handed over")

	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	daemon_pass(&d, Changed_Everything{})
	// The change that Windows dropped is found, as the scan compares every file with the saved index.
	write_later(t, content_path(tree, "levels/yard.scene"), strings.concatenate({YARD, "\tcast_shadows = true\n"}, context.temp_allocator))
	pass := daemon_pass(&d, Changed_Everything{})
	testing.expect(t, slice.equal(read_paths(tree, pass), []string{"levels/yard.scene"}), fmt.tprint(read_paths(tree, pass)))
	testing.expect_value(t, pass.cooked[.Scene], 1)
}

@(test)
the_watcher_says_which_paths_changed :: proc(t: ^testing.T) {
	// Two records: "a.txt", then "sub\b.txt", as ReadDirectoryChangesW writes them.
	buffer: [64]u32
	bytes := ([^]byte)(&buffer)[:size_of(buffer)]
	put :: proc(bytes: []byte, offset, next: int, name: string) {
		info := (^struct {
				next, action, length: u32,
			})(raw_data(bytes[offset:]))
		info^ = {u32(next), 1, u32(len(name) * 2)}
		chars := ([^]u16)(raw_data(bytes[offset + 12:]))
		for c, i in transmute([]byte)name {
			chars[i] = u16(c)
		}
	}
	put(bytes, 0, 32, "a.txt")
	put(bytes, 32, 0, "sub\\b.txt")
	paths := make([dynamic]string, context.temp_allocator)
	notify_paths("C:/root", bytes, &paths, context.temp_allocator)
	testing.expect(t, slice.equal(paths[:], []string{"C:/root/a.txt", "C:/root/sub/b.txt"}), fmt.tprint(paths[:]))

	tree := make_tree(t, {{"content/scripts/a.luau", "return 1"}})
	defer remove_tree(tree)
	watcher: Watcher
	testing.expect(t, watcher_open(&watcher, {fmt.tprintf("%s/content", tree.dir)}))
	defer watcher_close(&watcher)
	path := fmt.tprintf("%s/content/scripts/a.luau", tree.dir)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("return 2")) == nil)
	for watcher_wait(&watcher, 200) == .Changed {
	}
	changed, is_paths := watcher_take(&watcher, context.temp_allocator).(Changed_Paths)
	testing.expect(t, is_paths && slice.contains(changed.paths, path), fmt.tprint(changed))
}

// The daemon saves its index, and the next one checks every file's stamp against it, and reads and cooks nothing on
// content that did not change. What it carries is what the last daemon found, its warnings included.
@(test)
a_daemon_that_starts_again_reads_nothing_that_did_not_change :: proc(t: ^testing.T) {
	tree := saved_tree(t)
	defer remove_tree(tree)
	options := tree_options(tree)
	first := Daemon {
		options = options,
	}
	daemon_pass(&first, Changed_Everything{})
	defer index_destroy(&first.index)

	again := Daemon {
		options = options,
	}
	defer index_destroy(&again.index)
	testing.expect(t, index_load(&again.index, options))
	pass := daemon_pass(&again, Changed_Everything{})
	testing.expect(t, pass.ok)
	testing.expect_value(t, len(pass.read), 0)
	cooked := 0
	for n in pass.cooked {
		cooked += n
	}
	testing.expect_value(t, cooked, 0)
	testing.expect_value(t, len(again.index.assets), len(first.index.assets))
	testing.expect(t, !index_changed(index_diff(&first.index, &again.index)))
	testing.expect(t, slice.equal(problems_of(&again.index, tree, "levels/yard.scene"), problems_of(&first.index, tree, "levels/yard.scene")))

	// Another cooker, other options or another generation of the cache make the saved index stand for nothing.
	other: Index
	other_options := options
	includes := make([dynamic]string, context.temp_allocator)
	append(&includes, tree.dir)
	other_options.includes = includes
	testing.expect(t, !index_load(&other, other_options))
	_, written := write_generation(config_dir(options))
	testing.expect(t, written)
	testing.expect(t, !index_load(&other, options))
}

// A pass also looks at what the change takes away from, at what failed at the last pass, and, for scripts, at every
// one.
@(test)
a_pass_looks_at_what_a_change_reaches :: proc(t: ^testing.T) {
	tree := saved_tree(t)
	defer remove_tree(tree)
	testing.expect(t, os.write_entire_file(content_path(tree, "b.luau"), transmute([]byte)string("return require('./a')")) == nil)
	testing.expect(t, os.write_entire_file(content_path(tree, "broken.scene"), transmute([]byte)string("scene 2\nnonsense\n")) == nil)
	errors: Errors
	defer release_errors(&errors)
	context.logger = capture_errors(&errors)
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	daemon_pass(&d, Changed_Everything{})
	expect_error(t, &errors, "broken.scene:2")

	// Nothing changed, but the broken scene failed, so it is tried again.
	pass := daemon_pass(&d, Changed_Paths{})
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"broken.scene"}), fmt.tprint(checked_paths(tree, pass)))

	// A script that changes makes the pass look at every script.
	write_later(t, content_path(tree, "a.luau"), "return 2")
	pass = daemon_pass(&d, Changed_Paths{{content_path(tree, "a.luau")}})
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"a.luau", "b.luau", "broken.scene"}), fmt.tprint(checked_paths(tree, pass)))
	testing.expect_value(t, pass.cooked[.Script], 2)

	// The door goes: the hall that instantiates it is looked at, and warns that it is missing.
	testing.expect(t, os.remove(content_path(tree, "door.prefab")) == nil)
	testing.expect(t, os.remove(content_path(tree, "door.prefab.meta")) == nil)
	pass = daemon_pass(&d, Changed_Paths{{content_path(tree, "door.prefab"), content_path(tree, "door.prefab.meta")}})
	checked := checked_paths(tree, pass)
	testing.expect(t, slice.contains(checked, "levels/hall.scene") && !slice.contains(checked, "lamp.prefab"), fmt.tprint(checked))
	hall := problems_of(&d.index, tree, "levels/hall.scene")
	testing.expect(t, len(hall) == 1 && strings.contains(hall[0], "is missing"), fmt.tprint(hall))
	testing.expect(t, guid_text(format.guid_parse("22222222222222222222222222222222") or_else {}) not_in d.index.assets)

	// A new folder with a scene in it is listed whole.
	testing.expect(t, os.make_directory(content_path(tree, "new")) == nil)
	testing.expect(t, os.write_entire_file(content_path(tree, "new/court.scene"), transmute([]byte)string(YARD)) == nil)
	pass = daemon_pass(&d, Changed_Paths{{content_path(tree, "new")}})
	testing.expect(t, slice.contains(read_paths(tree, pass), "new/court.scene"), fmt.tprint(read_paths(tree, pass)))
	found := false
	for f in d.index.folders {
		found ||= f.path == "new"
	}
	testing.expect(t, found)
}

// A prefab that the pass carries, but that a scene that it looks at instantiates, parses for the scene, and its
// problems are the carried ones, once.
@(test)
a_carried_prefab_keeps_its_problems_once :: proc(t: ^testing.T) {
	tree := saved_tree(t)
	defer remove_tree(tree)
	write_later(t, content_path(tree, "door.prefab"), strings.concatenate({DOOR, "component 1 Transform\n\tpivot = @7000000000000001\n"}, context.temp_allocator))
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	daemon_pass(&d, Changed_Everything{})
	door := problems_of(&d.index, tree, "door.prefab")
	testing.expect_value(t, len(door), 1)

	write_later(t, content_path(tree, "levels/hall.scene"), strings.concatenate({HALL, "name = \"Hall\"\n"}, context.temp_allocator))
	pass := daemon_pass(&d, Changed_Paths{{content_path(tree, "levels/hall.scene")}})
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"levels/hall.scene"}), fmt.tprint(checked_paths(tree, pass)))
	testing.expect(t, slice.contains(read_paths(tree, pass), "door.prefab"))
	testing.expect_value(t, pass.cooked[.Scene], 1)
	testing.expect(t, slice.equal(problems_of(&d.index, tree, "door.prefab"), door))
}

// A pass that carries every material parses no shading model, and the index keeps the last pass's.
@(test)
the_shading_models_stay_when_the_materials_are_carried :: proc(t: ^testing.T) {
	lit, _ := os.read_entire_file("lib/engine/content/shading/lit.shading", context.temp_allocator)
	hlsli, _ := os.read_entire_file("lib/engine/content/shading/lit.hlsli", context.temp_allocator)
	tree := make_tree(t, {{"content/shading/lit.shading", string(lit)}, {"content/shading/lit.hlsli", string(hlsli)}, {"content/a.luau", "return 1"}})
	defer remove_tree(tree)
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	daemon_pass(&d, Changed_Everything{})
	testing.expect_value(t, len(d.index.shading.models), 1)

	write_later(t, content_path(tree, "a.luau"), "return 2")
	pass := daemon_pass(&d, Changed_Paths{{content_path(tree, "a.luau")}})
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"a.luau"}), fmt.tprint(checked_paths(tree, pass)))
	testing.expect_value(t, len(d.index.shading.models), 1)

	// The include is not an asset, so its change looks at the shading models, and every material.
	write_later(t, content_path(tree, "shading/lit.hlsli"), strings.concatenate({string(hlsli), "\n"}, context.temp_allocator))
	pass = daemon_pass(&d, Changed_Paths{{content_path(tree, "shading/lit.hlsli")}})
	testing.expect(t, slice.equal(checked_paths(tree, pass), []string{"shading/lit.shading"}), fmt.tprint(checked_paths(tree, pass)))
}
