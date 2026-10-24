package cook

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// Errors captures error logs. The test runner fails a test that logs an error, so tests that expect errors capture
// them. log rewinds the temp allocator after each call, so the messages are kept in their own arena. Release it with
// release_errors.
@(private)
Errors :: struct {
	arena:    virtual.Arena,
	messages: [dynamic]string,
	runner:   log.Logger,
}

@(private)
capture_errors :: proc(e: ^Errors) -> log.Logger {
	_ = virtual.arena_init_growing(&e.arena)
	e.messages = make([dynamic]string, virtual.arena_allocator(&e.arena))
	e.runner = context.logger
	return {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			e := (^Errors)(data)
			// testing.expect reports a failure as an error log from the test file. It must reach the test runner.
			if strings.has_suffix(location.file_path, "_test.odin") {
				e.runner.procedure(e.runner.data, level, text, options, location)
				return
			}
			append(&e.messages, strings.clone(text, virtual.arena_allocator(&e.arena)))
		},
		data = e,
		lowest_level = .Error,
	}
}

@(private)
release_errors :: proc(e: ^Errors) {
	virtual.arena_destroy(&e.arena)
}

@(private)
expect_error :: proc(t: ^testing.T, e: ^Errors, fragment: string, loc := #caller_location) {
	for m in e.messages {
		if strings.contains(m, fragment) {
			return
		}
	}
	testing.expectf(t, false, "no error contains %q: %v", fragment, e.messages, loc = loc)
}

// Tree is a content root in a temporary directory.
@(private)
Tree :: struct {
	dir: string,
}

@(private)
make_tree :: proc(t: ^testing.T, files: []struct {
		path, text: string,
	}) -> Tree {
	temp, err := os.make_directory_temp("", "cook_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	dir, _ := os.get_absolute_path(temp, context.temp_allocator)
	tree := Tree{forward_slashes(dir)}
	for f in files {
		path := fmt.tprintf("%s/%s", tree.dir, f.path)
		if i := strings.last_index_byte(path, '/'); i >= 0 {
			os.make_directory_all(path[:i])
		}
		testing.expect(t, os.write_entire_file(path, transmute([]byte)f.text) == nil)
	}
	return tree
}

@(private)
remove_tree :: proc(tree: Tree) {
	os.remove_all(tree.dir)
}

@(private)
tree_options :: proc(tree: Tree) -> Script_Options {
	roots := make([dynamic]Root, context.temp_allocator)
	append(&roots, Root{"game", fmt.tprintf("%s/content", tree.dir)})
	return {cache = fmt.tprintf("%s/cache", tree.dir), config = .Dev, roots = roots}
}

@(private)
tree_guid :: proc(t: ^testing.T, tree: Tree, path: string) -> format.Guid {
	data, err := os.read_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, path), context.temp_allocator)
	testing.expectf(t, err == nil, "%s has no .meta file", path)
	guid, ok := format.meta_guid(string(data))
	testing.expect(t, ok)
	return guid
}

// tree_blob reads a cooked blob into memory at the runtime's alignment.
@(private)
tree_blob :: proc(t: ^testing.T, tree: Tree, guid: format.Guid) -> []byte {
	buffer: [32]u8
	data, err := os.read_entire_file(fmt.tprintf("%s/cache/dev/%s.blob", tree.dir, format.guid_format(guid, &buffer)), context.temp_allocator)
	testing.expect(t, err == nil)
	aligned, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, data)
	return aligned
}

@(test)
modules_follow_luau_naming :: proc(t: ^testing.T) {
	testing.expect_value(t, module_of("/c/a/b.luau"), "/c/a/b")
	testing.expect_value(t, module_of("/c/a/init.luau"), "/c/a")
}

@(test)
requires_resolve_like_luau :: proc(t: ^testing.T) {
	by_path := make(map[string]int, context.temp_allocator)
	by_path["/c/a/b.luau"] = 0
	by_path["/c/a/init.luau"] = 1
	by_path["/c/a/sibling.luau"] = 2
	by_path["/c/top.luau"] = 3
	by_path["/c/a/sub/init.luau"] = 4
	by_path["/c/twice.luau"] = 5
	by_path["/c/twice/init.luau"] = 6

	Case :: struct {
		requirer, path: string,
		target:         int,
	}
	cases := []Case {
		// A file's ./ is its directory.
		{"/c/a/b.luau", "./sibling", 2},
		{"/c/a/b.luau", "../top", 3},
		{"/c/a/b.luau", "./sub", 4},
		// init.luau is its directory's module, so its ./ is the directory's parent, and @self is the directory.
		{"/c/a/init.luau", "./top", 3},
		{"/c/a/init.luau", "@self/sibling", 2},
		{"/c/a/init.luau", "@SELF/b", 0},
		{"/c/a/sub/init.luau", "./b", 0},
		{"/c/top.luau", "./a", 1},
	}
	for c in cases {
		target, message := resolve_require(by_path, c.requirer, c.path)
		testing.expectf(t, message == "" && target == c.target, "%s requires %s: got %d %q, want %d", c.requirer, c.path, target, message, c.target)
	}

	_, message := resolve_require(by_path, "/c/top.luau", "./missing")
	testing.expect(t, strings.contains(message, "no module at /c/missing"), message)
	_, message = resolve_require(by_path, "/c/top.luau", "./twice")
	testing.expect(t, strings.contains(message, "both"), message)
	_, message = resolve_require(by_path, "/c/top.luau", "top")
	testing.expect(t, strings.contains(message, "must start with"), message)
}

@(test)
requires_come_from_the_parser :: proc(t: ^testing.T) {
	s := Script_Source {
		path     = "test.luau",
		requires = make([dynamic]Found_Require, context.temp_allocator),
	}
	s.source = transmute([]byte)string(
		`-- require("./commented")
local a = require("./a")
local text = "require('./quoted')"
local b = require('@game/b')
local c = [[require("./long")]]
return function() return require("./inner") end`,
	)
	testing.expect(t, find_requires(&s))
	testing.expect_value(t, len(s.requires), 3)
	if len(s.requires) == 3 {
		testing.expect_value(t, s.requires[0], Found_Require{"./a", 2})
		testing.expect_value(t, s.requires[1], Found_Require{"@game/b", 4})
		testing.expect_value(t, s.requires[2], Found_Require{"./inner", 6})
	}

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	dynamic_require := Script_Source {
		path     = "dynamic.luau",
		source   = transmute([]byte)string("local name = './a'\nreturn require(name)"),
		requires = make([dynamic]Found_Require, context.temp_allocator),
	}
	testing.expect(t, !find_requires(&dynamic_require))
	expect_error(t, &errors, "dynamic.luau:2: require takes one string literal")
	broken := Script_Source {
		path     = "broken.luau",
		source   = transmute([]byte)string("local = 1"),
		requires = make([dynamic]Found_Require, context.temp_allocator),
	}
	testing.expect(t, !find_requires(&broken))
	expect_error(t, &errors, "broken.luau:1:")
}

@(test)
a_content_root_cooks_with_aliases :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{".luaurc", `{"aliases": {"Lib": "./content/lib"}}`},
			{"content/main.luau", `local util = require("./util"); local thing = require("@lib/thing"); return util.x + thing.y`},
			{"content/util.luau", `return {x = 1}`},
			{"content/lib/thing/init.luau", `return {y = require("@self/part")}`},
			{"content/lib/thing/part.luau", `return 2`},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook_scripts(options))

	main := tree_blob(t, tree, tree_guid(t, tree, "main.luau"))
	blob, ok := format.script_view(main)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(main, blob.source_path), "game/main.luau")
	util, util_found := format.script_find_require(main, blob, "./util")
	testing.expect(t, util_found && util == tree_guid(t, tree, "util.luau"))
	thing, thing_found := format.script_find_require(main, blob, "@lib/thing")
	testing.expect(t, thing_found && thing == tree_guid(t, tree, "lib/thing/init.luau"))

	// A second cook finds everything up to date and keeps the GUIDs.
	key := blob.header.key
	guid := tree_guid(t, tree, "main.luau")
	testing.expect(t, cook_scripts(options))
	testing.expect_value(t, tree_guid(t, tree, "main.luau"), guid)
	testing.expect_value(t, cooked_script_key(fmt.tprintf("%s/cache/dev/%s.blob", tree.dir, guid_text(guid))), key)
}

@(private)
guid_text :: proc(guid: format.Guid) -> string {
	buffer := new([32]u8, context.temp_allocator)
	return format.guid_format(guid, buffer)
}

@(test)
a_changed_dependency_changes_the_key :: proc(t: ^testing.T) {
	a := Script_Source{name = "game/a.luau", source = transmute([]byte)string("return 1")}
	before := script_key(.Dev, a, 0)
	a.resolved = make([dynamic]Resolved_Require, context.temp_allocator)
	append(&a.resolved, Resolved_Require{entry = {"./b", {1 = 1}}})
	testing.expect(t, script_key(.Dev, a, 0) != before, "a require did not change the key")
	testing.expect(t, script_key(.Release, a, 0) != script_key(.Dev, a, 0), "the configuration did not change the key")
	testing.expect(t, script_key(.Dev, a, 1) != script_key(.Dev, a, 0), "a dependency's source did not change the key")
}

@(test)
require_cycles_are_errors :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", `return require("./b")`}, {"content/b.luau", `return require("./a")`}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(tree_options(tree)))
	expect_error(t, &errors, "require cycle: game/a.luau -> game/b.luau -> game/a.luau")
}

@(test)
copied_meta_files_are_errors :: proc(t: ^testing.T) {
	meta := "guid = 00112233445566778899aabbccddeeff\n"
	tree := make_tree(t, {{"content/a.luau", "return 1"}, {"content/a.luau.meta", meta}, {"content/b.luau", "return 2"}, {"content/b.luau.meta", meta}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(tree_options(tree)))
	expect_error(t, &errors, "have the same GUID")
}

@(test)
missing_modules_are_errors :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return require('./nothing')"}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(tree_options(tree)))
	expect_error(t, &errors, `a.luau:1: cannot require "./nothing": no module at`)
}

@(test)
behaviours_get_their_fields_in_the_blob :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/door.luau", `
local defaults = require("./defaults")
local Door = Behaviour.define("Door", {
	speed = Field.number(defaults.speed),
	open = Field.boolean(true),
	label = Field.string("front"),
	offset = Field.vector(vector.create(1, 2, 3)),
	target = Field.entity(),
})
function Door:start() World.spawn() end
return Door`},
			{"content/defaults.luau", "return {speed = 4}"},
			// A script that runs as a coroutine is never run by the cooker: it would not return.
			{"content/main.luau", "while true do coroutine.yield() end"},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook_scripts(options))

	data := tree_blob(t, tree, tree_guid(t, tree, "door.luau"))
	blob, ok := format.script_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.flags, format.Script_Flags{.Behaviour})
	testing.expect_value(t, format.blob_string(data, blob.class_name), "Door")
	fields := format.script_fields(data, blob)
	testing.expect_value(t, len(fields), 5)
	if len(fields) == 5 {
		// Sorted by name: label, offset, open, speed, target.
		testing.expect_value(t, format.blob_string(data, fields[0].name), "label")
		testing.expect_value(t, format.blob_string(data, fields[0].text), "front")
		testing.expect_value(t, fields[1].vector, [3]f32{1, 2, 3})
		testing.expect_value(t, fields[2].kind, format.Script_Field_Kind.Boolean)
		testing.expect_value(t, fields[2].number, 1)
		testing.expect_value(t, fields[3].number, 4)
		testing.expect_value(t, fields[4].kind, format.Script_Field_Kind.Entity)
	}
	main := tree_blob(t, tree, tree_guid(t, tree, "main.luau"))
	main_blob, _ := format.script_view(main)
	testing.expect_value(t, main_blob.flags, format.Script_Flags{})

	// A field default that comes from a dependency changes with it.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/defaults.luau", tree.dir), transmute([]byte)string("return {speed = 9}")) == nil)
	testing.expect(t, cook_scripts(options))
	data = tree_blob(t, tree, tree_guid(t, tree, "door.luau"))
	blob, _ = format.script_view(data)
	fields = format.script_fields(data, blob)
	testing.expect(t, len(fields) == 5 && fields[3].number == 9)
}

@(test)
a_behaviour_top_level_that_calls_the_engine_is_an_error :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/eager.luau", `local Eager = Behaviour.define("Eager") World.spawn() return Eager`},
			{"content/stuck.luau", `local Stuck = Behaviour.define("Stuck") while true do end`},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(tree_options(tree)))
	expect_error(t, &errors, "eager.luau: a behaviour script's top level runs when it is cooked")
	expect_error(t, &errors, "game/eager.luau:1: World is not available when the cooker reads a behaviour's fields")
	expect_error(t, &errors, "the top level ran for more than 2 seconds")
}

// The engine's definitions, with the parts that host.exe --emit-script-types generates cut down to what the tests
// use.
@(private)
TEST_DEFINITIONS :: #load("../../lib/engine/script/engine.d.luau", string) + `
declare extern type Entity with
	function is_alive(self): boolean
end
`

@(private)
typed_options :: proc(t: ^testing.T, tree: Tree, definitions := TEST_DEFINITIONS) -> Script_Options {
	options := tree_options(tree)
	options.definitions = fmt.tprintf("%s/types.d.luau", tree.dir)
	testing.expect(t, os.write_entire_file(options.definitions, transmute([]byte)definitions) == nil)
	return options
}

@(test)
type_errors_fail_the_cook :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			// A nonstrict module's exports are loosely typed, so this one is strict.
			{"content/m.luau", "--!strict\nreturn {x = 1}"},
			{"content/a.luau", "--!strict\nlocal alive: number = World.spawn():is_alive()\nreturn alive"},
			{"content/b.luau", "--!strict\nlocal m = require('./m')\nlocal s: string = m.x\nreturn s"},
			{"content/fine.luau", "--!strict\nlocal q = Quaternion.euler(vector.create(0, 90, 0)) * vector.create(0, 0, 1)\nreturn q.x"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(typed_options(t, tree)))
	expect_error(t, &errors, "a.luau:2:")
	expect_error(t, &errors, "Expected this to be 'number', but got 'boolean'")
	// Types flow through require.
	expect_error(t, &errors, "b.luau:3:")
	testing.expect_value(t, len(errors.messages), 2)
	// A script with type errors gets no blob.
	buffer: [32]u8
	testing.expect(t, !os.exists(fmt.tprintf("%s/cache/dev/%s.blob", tree.dir, format.guid_format(tree_guid(t, tree, "a.luau"), &buffer))))
	testing.expect(t, os.exists(fmt.tprintf("%s/cache/dev/%s.blob", tree.dir, format.guid_format(tree_guid(t, tree, "fine.luau"), &buffer))))
}

@(test)
luaurc_sets_the_default_mode :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/.luaurc", `{"languageMode": "nocheck"}`},
			{"content/unchecked.luau", "local n: number = 'text'\nreturn n"},
			{"content/checked.luau", "--!strict\nlocal n: number = 'text'\nreturn n"},
		},
	)
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(typed_options(t, tree)))
	testing.expect_value(t, len(errors.messages), 1)
	expect_error(t, &errors, "checked.luau:2:")
}

@(test)
without_definitions_the_cook_does_not_type_check :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "--!strict\nlocal n: number = 'text'\nreturn n"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	options.definitions = fmt.tprintf("%s/missing.d.luau", tree.dir)
	testing.expect(t, cook_scripts(options))
	// The definition file's hash is in the key, so the script is checked once the file exists.
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(typed_options(t, tree)))
	expect_error(t, &errors, "a.luau:2:")
}

@(test)
a_broken_definition_file_fails_the_cook :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.luau", "return 1"}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook_scripts(typed_options(t, tree, "declare World: {")))
	expect_error(t, &errors, "is not a valid definition file")
}
