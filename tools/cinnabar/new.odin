package cinnabar

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode"

import format "cinnabar:engine/asset/format"

// The template that every project starts from, and the suffix of a template's files that would otherwise be read as
// the engine's own source, such as game.odin.template.
BASE_TEMPLATE :: "basic"
TEMPLATE_SUFFIX :: ".template"

// Template_File is a file that a new project gets: its path in the project, with forward slashes, and its text.
Template_File :: struct {
	path: string,
	text: string,
}

// new_project makes a project in an empty or new folder from a template (see
// docs/overview/getting-started.md#a-new-project): the basic template's files, and then the named template's over them.
// Each content file gets a .meta file with a new GUID, and {{guid:<path>}} in the templates' text is that file's GUID,
// so the scene names its scripts and the settings name the main scene. {{name}} is the game's name, and {{package}}
// a name of it that Odin takes as a package's.
new_project :: proc(e: Engine, dir, name, template: string) -> bool {
	if !is_empty_or_new(dir) {
		log.errorf("cinnabar: %s is not empty. A new project goes in a new or empty folder.", dir)
		return false
	}
	files, ok := read_template(e.templates, template)
	if !ok {
		return false
	}
	name := name
	if name == "" {
		name = filepath.base(slashes(absolute(dir)))
	}
	made := make_project_files(files, name)
	for f in made {
		path, _ := filepath.join({dir, f.path}, context.temp_allocator)
		if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
			log.errorf("cinnabar: %s: %v", path, err)
			return false
		}
		if err := os.write_entire_file(path, transmute([]byte)f.text); err != nil {
			log.errorf("cinnabar: %s: %v", path, err)
			return false
		}
	}
	log.infof("cinnabar: made %s in %s from the %s template. Open it with `cinnabar edit %s`.", name, dir, template, dir)
	return true
}

// is_empty_or_new is whether a folder has nothing in it, or is not there.
is_empty_or_new :: proc(dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	return err != nil || len(entries) == 0
}

// read_template reads the basic template's files, and then the named template's, which replace those at the same path.
read_template :: proc(templates, template: string) -> (files: []Template_File, ok: bool) {
	by_path := make(map[string]string, context.temp_allocator)
	names := []string{BASE_TEMPLATE} if template == BASE_TEMPLATE else []string{BASE_TEMPLATE, template}
	for t in names {
		root := strings.concatenate({templates, "/", t}, context.temp_allocator)
		if !os.is_dir(root) {
			log.errorf("cinnabar: there is no template %q in %s", t, templates)
			return nil, false
		}
		if !read_tree(root, "", &by_path) {
			return nil, false
		}
	}
	list := make([dynamic]Template_File, context.temp_allocator)
	for path, text in by_path {
		append(&list, Template_File{path, text})
	}
	slice.sort_by(list[:], proc(a, b: Template_File) -> bool {return a.path < b.path})
	return list[:], true
}

@(private = "file")
read_tree :: proc(root, prefix: string, files: ^map[string]string) -> bool {
	dir := root if prefix == "" else strings.concatenate({root, "/", prefix}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		log.errorf("cinnabar: %s: %v", dir, err)
		return false
	}
	for e in entries {
		path := e.name if prefix == "" else strings.concatenate({prefix, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !read_tree(root, path, files) {
				return false
			}
			continue
		}
		data, read_err := os.read_entire_file(e.fullpath, context.temp_allocator)
		if read_err != nil {
			log.errorf("cinnabar: %s: %v", e.fullpath, read_err)
			return false
		}
		files[strings.trim_suffix(path, TEMPLATE_SUFFIX)] = string(data)
	}
	return true
}

// make_project_files are a project's files from a template's: each content file with a .meta file of a new GUID, and
// the placeholders in every text replaced.
make_project_files :: proc(files: []Template_File, name: string) -> []Template_File {
	guids := make(map[string]string, context.temp_allocator)
	made := make([dynamic]Template_File, context.temp_allocator)
	for f in files {
		if !is_content_asset(f.path) {
			continue
		}
		buffer := new([32]u8, context.temp_allocator)
		guid := format.guid_new()
		guids[f.path] = format.guid_format(guid, buffer)
		append(&made, Template_File{strings.concatenate({f.path, format.META_EXTENSION}, context.temp_allocator), format.meta_text(guid, "", nil, allocator = context.temp_allocator)})
	}
	package_name := package_of(name)
	for f in files {
		text, _ := strings.replace_all(f.text, "{{name}}", name, context.temp_allocator)
		text, _ = strings.replace_all(text, "{{package}}", package_name, context.temp_allocator)
		for path, guid in guids {
			token := strings.concatenate({"{{guid:", path, "}}"}, context.temp_allocator)
			text, _ = strings.replace_all(text, token, guid, context.temp_allocator)
		}
		append(&made, Template_File{f.path, text})
	}
	return made[:]
}

// is_content_asset is whether a template's file is an asset of the content root, which a .meta file gives a GUID: a
// file under content/ that is not hidden, such as .luaurc.
is_content_asset :: proc(path: string) -> bool {
	if !strings.has_prefix(path, "content/") {
		return false
	}
	return !strings.has_prefix(filepath.base(path), ".")
}

// package_of is a name that Odin takes as a package's: the name's letters and digits in lower case, with _ between
// words, a letter first, and none of the template's imports' names.
package_of :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	gap := false
	for r in name {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			if gap && strings.builder_len(b) > 0 {
				strings.write_byte(&b, '_')
			}
			gap = false
			if r < 128 {
				strings.write_rune(&b, unicode.to_lower(r))
			}
		} else {
			gap = true
		}
	}
	s := strings.to_string(b)
	switch {
	case s == "":
		return "my_game"
	case !unicode.is_letter(rune(s[0])):
		return strings.concatenate({"game_", s}, context.temp_allocator)
	case slice.contains(TEMPLATE_IMPORTS, s):
		// The template's game.odin imports these packages by their names.
		return strings.concatenate({s, "_game"}, context.temp_allocator)
	}
	return s
}

// The packages that the Odin template's game.odin imports, whose names a project's package cannot take.
TEMPLATE_IMPORTS :: []string{"game", "core", "ecs", "script", "linalg"}
