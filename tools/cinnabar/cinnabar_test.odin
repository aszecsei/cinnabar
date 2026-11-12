package cinnabar

import "core:encoding/endian"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// temp_dir is a new empty folder for one test, which it deletes.
@(private = "file")
temp_dir :: proc(t: ^testing.T, name: string) -> string {
	dir, _ := filepath.join({os.get_env("TEMP", context.temp_allocator), name}, context.temp_allocator)
	os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	return dir
}

// The repository's root, which the tests run in.
@(private = "file")
REPO :: "."

@(test)
the_engine_is_the_first_checkout_named :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, source, ok := find_engine("", "", "", "")
	testing.expect(t, !ok, "nothing named finds nothing")

	root, source, ok = find_engine("", REPO, "", "")
	testing.expect(t, ok)
	testing.expect_value(t, source, Engine_Source.Variable)
	testing.expect(t, is_engine(root))

	// An argument wins, and one that is not the engine's is an error rather than a reason to look further.
	_, source, ok = find_engine("samples", REPO, "", "")
	testing.expect(t, !ok)
	testing.expect_value(t, source, Engine_Source.Argument)

	// The checkout that the executable was built in is two folders up from build/tools.
	tools, _ := filepath.join({absolute(REPO), "build", "tools"}, context.temp_allocator)
	root, source, ok = find_engine("", "", "", tools)
	testing.expect(t, ok)
	testing.expect_value(t, source, Engine_Source.Executable)
}

@(test)
a_project_without_odin_runs_the_standard_game :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	e := engine_paths("E:/engine", context.temp_allocator)
	testing.expect_value(t, e.host, "E:/engine/build/dev/host.exe")
	testing.expect_value(t, e.includes[2], "E:/engine/vendor/smaa")

	intel := project_paths("samples/intel", e, context.temp_allocator)
	testing.expect(t, !intel.has_code)
	testing.expect_value(t, intel.game_dll, e.standard)
	testing.expect_value(t, intel.name, "Intel")
	testing.expect(t, strings.has_suffix(intel.cache, "samples/intel/build/cache"))

	mygame := project_paths("samples/mygame", e, context.temp_allocator)
	testing.expect(t, mygame.has_code)
	testing.expect(t, strings.has_suffix(mygame.game_dll, "samples/mygame/build/dev/game.dll"))

	command := release_command(e, mygame, "out/mygame.exe")
	testing.expect(t, slice.contains(command, "-subsystem:windows"))
	testing.expect(t, slice.contains(command, "-collection:physics_backend=E:/engine/lib/core/physics/jolt"))
	testing.expect(t, slice.contains(command, strings.concatenate({"-collection:project=", mygame.dir}, context.temp_allocator)))
	cook := cook_command(e, intel, "release", intel.release_cache, true)
	testing.expect_value(t, cook[1], "all")
	testing.expect_value(t, cook[len(cook) - 1], "--prune")
	testing.expect(t, slice.contains(cook, "engine=E:/engine/lib/engine/content"))
}

@(test)
names_become_files_and_packages :: proc(t: ^testing.T) {
	testing.expect_value(t, file_name("My Game: Part 2?", context.temp_allocator), "My Game Part 2")
	testing.expect_value(t, file_name("trailing. ", context.temp_allocator), "trailing")
	testing.expect_value(t, package_of("My Game 2"), "my_game_2")
	testing.expect_value(t, package_of("2048"), "game_2048")
	testing.expect_value(t, package_of("Game"), "game_game")
	testing.expect_value(t, package_of("!!"), "my_game")
}

@(test)
a_new_project_has_new_guids_that_its_files_name :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	e := engine_paths(REPO, context.temp_allocator)
	dir := temp_dir(t, "cinnabar_new_test")
	defer os.remove_all(dir)
	testing.expect(t, is_empty_or_new(dir))
	testing.expect(t, new_project(e, dir, "Demo Game", "odin"))
	testing.expect(t, !is_empty_or_new(dir), "a folder that is not empty is refused")

	read :: proc(dir, path: string) -> string {
		full, _ := filepath.join({dir, path}, context.temp_allocator)
		data, _ := os.read_entire_file(full, context.temp_allocator)
		return string(data)
	}
	settings := read(dir, "project.settings")
	testing.expect_value(t, format.settings_value(settings, NAME_KEY), "Demo Game")
	scene_meta, _ := format.meta_guid(read(dir, "content/scenes/main.scene.meta"))
	main_scene, _ := format.guid_parse(format.settings_value(settings, MAIN_SCENE_KEY))
	testing.expect(t, main_scene != {})
	testing.expect_value(t, main_scene, scene_meta)

	// The scene names the script by its new GUID, and no placeholder is left.
	script, _ := format.meta_guid(read(dir, "content/scripts/spinner.luau.meta"))
	buffer: [32]u8
	scene := read(dir, "content/scenes/main.scene")
	testing.expect(t, strings.contains(scene, strings.concatenate({"behaviour ", format.guid_format(script, &buffer)}, context.temp_allocator)))
	testing.expect(t, strings.contains(scene, "Spinning Cube"), "the odin template's scene replaces the basic one")
	code := read(dir, "game/game.odin")
	testing.expect(t, strings.has_prefix(code, "// Demo Game's Odin"))
	testing.expect(t, has_line(code, "package demo_game"), "the package is the name as a package's")
	for text in ([]string{settings, scene, code}) {
		testing.expect(t, !strings.contains(text, "{{"), "a placeholder is left")
	}
	testing.expect(t, !os.exists(strings.concatenate({dir, "/content/.luaurc.meta"}, context.temp_allocator)), "hidden files are not assets")

	// Another project from the same template gets GUIDs of its own.
	other := temp_dir(t, "cinnabar_new_test_2")
	defer os.remove_all(other)
	testing.expect(t, new_project(e, other, "", "basic"))
	other_scene, _ := format.meta_guid(read(other, "content/scenes/main.scene.meta"))
	testing.expect(t, other_scene != scene_meta)
	testing.expect_value(t, format.settings_value(read(other, "project.settings"), NAME_KEY), "cinnabar_new_test_2")
	testing.expect(t, !os.exists(strings.concatenate({other, "/game"}, context.temp_allocator)))
}

@(test)
an_icon_files_images_become_resources :: proc(t: ^testing.T) {
	// An icon file of two images, of 3 and 2 bytes.
	ico := make([]byte, ICON_HEADER + 2 * ICON_ENTRY + 5, context.temp_allocator)
	endian.put_u16(ico[2:], .Little, 1)
	endian.put_u16(ico[4:], .Little, 2)
	for i in 0 ..< 2 {
		entry := ico[ICON_HEADER + i * ICON_ENTRY:]
		entry[0] = u8(16 * (i + 1))
		endian.put_u16(entry[6:], .Little, 32)
		endian.put_u32(entry[8:], .Little, u32(3 - i))
		endian.put_u32(entry[12:], .Little, u32(ICON_HEADER + 2 * ICON_ENTRY + 3 * i))
	}
	copy(ico[ICON_HEADER + 2 * ICON_ENTRY:], []byte{1, 2, 3, 4, 5})
	r, ok := icon_resources(ico, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(r.images), 2)
	testing.expect(t, slice.equal(r.images[1], []byte{4, 5}))
	testing.expect_value(t, len(r.group), ICON_HEADER + 2 * GROUP_ENTRY)
	second := r.group[ICON_HEADER + GROUP_ENTRY:]
	testing.expect_value(t, second[0], 32)
	id, _ := endian.get_u16(second[12:], .Little)
	testing.expect_value(t, id, 2)

	_, ok = icon_resources(ico[:10], context.temp_allocator)
	testing.expect(t, !ok, "a cut file is refused")
}

// has_line says whether text has a line that is exactly line, with either line ending: a checkout with core.autocrlf
// gives the templates CRLF.
@(private = "file")
has_line :: proc(text, line: string) -> bool {
	text := text
	for l in strings.split_lines_iterator(&text) {
		if strings.trim_right(l, "\r") == line {
			return true
		}
	}
	return false
}
