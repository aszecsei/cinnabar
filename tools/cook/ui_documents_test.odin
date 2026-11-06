package cook

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
FONT_GUID :: "0123456789abcdef0123456789abcdef"
@(private = "file")
IMAGE_GUID :: "fedcba9876543210fedcba9876543210"

@(private = "file")
ui_tree :: proc(t: ^testing.T, document: string) -> Tree {
	return make_tree(
		t,
		{
			{"content/fonts/sans.ttf", TEST_FONT},
			{"content/fonts/sans.ttf.meta", "guid = " + FONT_GUID + "\n"},
			{"content/textures/frame.png", string(#load("testdata/2x2.png"))},
			{"content/textures/frame.png.meta", "guid = " + IMAGE_GUID + "\nusage = color\n"},
			{"content/ui/hud.ui", document},
		},
	)
}

@(test)
ui_documents_cook_to_blobs_that_depend_on_their_fonts_and_images :: proc(t: ^testing.T) {
	tree := ui_tree(t, fmt.tprintf("ui 1\n<ui font=$%s>\n\t<style name=\"frame\" image=$%s slice=\"1\"/>\n\t<box style=\"frame\"><text>Hi</text></box>\n</ui>\n", FONT_GUID, IMAGE_GUID))
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Ui}, log_problems = false)
	testing.expectf(t, pass.ok, "%v", pass.problems.list)
	testing.expect_value(t, pass.cooked[.Ui], 1)
	data := tree_blob(t, tree, tree_guid(t, tree, "ui/hud.ui"))
	blob, ok := format.ui_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.ui_nodes(data, blob)), 3)
		testing.expect_value(t, format.blob_string(data, blob.source_path), "game/ui/hud.ui")
	}
	for a in pass.assets {
		if a.kind == .Ui {
			font, _ := format.guid_parse(FONT_GUID)
			image, _ := format.guid_parse(IMAGE_GUID)
			testing.expect(t, slice.contains(a.dependencies[:], font) && slice.contains(a.dependencies[:], image))
		}
	}
	// A second cook finds it up to date.
	pass = cook(options, {.Ui}, log_problems = false)
	testing.expect_value(t, pass.current[.Ui], 1)
	testing.expect_value(t, pass.cooked[.Ui], 0)
}

@(test)
ui_documents_name_fonts_as_fonts_and_images_as_textures :: proc(t: ^testing.T) {
	tree := ui_tree(t, fmt.tprintf("ui 1\n<ui font=$%s>\n\t<box image=$%s/>\n\t<text font=$00000000000000000000000000000001>a</text>\n</ui>\n", IMAGE_GUID, FONT_GUID))
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Ui}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Ui], 0)
	lines := make([dynamic]string, context.temp_allocator)
	for p in pass.problems.list {
		if strings.has_suffix(p.file, "hud.ui") {
			append(&lines, fmt.tprintf("%d %v %s", p.line, p.error, p.text))
		}
	}
	testing.expectf(t, len(lines) == 3, "%v", lines)
	expected := []string {
		fmt.tprintf("2 true font $%s is a Texture, not a Font", IMAGE_GUID),
		fmt.tprintf("3 true image $%s is a Font, not a Texture", FONT_GUID),
		"4 false font $00000000000000000000000000000001 is not an asset in the content roots",
	}
	for e in expected {
		testing.expectf(t, slice.contains(lines[:], e), "no problem %q in %v", e, lines)
	}
}

@(test)
ui_documents_from_the_template_cook_and_broken_ones_keep_their_blobs :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/ui/new.ui", UI_TEMPLATE}, {"content/ui/broken.ui", "ui 1\n<ui><box width=\"wide\"/></ui>\n"}})
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Ui}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Ui], 1)
	for p in pass.problems.list {
		testing.expectf(t, strings.has_suffix(p.file, "broken.ui"), "the template has a problem: %v", p)
		testing.expect_value(t, p.line, 2)
		testing.expect_value(t, p.column, 10)
	}
}

@(test)
an_unsaved_ui_documents_problems_keep_their_columns_and_its_preview_its_last_good_text :: proc(t: ^testing.T) {
	cache, err := os.make_directory_temp("", "ui_check_*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(cache)
	defer os.remove_all(cache)
	options := Cook_Options {
		cache  = cache,
		config = .Dev,
	}
	guid, _ := format.guid_parse("00112233445566778899aabbccddeeff")
	font, _ := format.guid_parse(FONT_GUID)
	kinds := make(map[format.Guid]format.Asset_Kind, context.temp_allocator)
	kinds[font] = .Font
	blob := fmt.tprintf("%s/preview/00112233445566778899aabbccddeeff.blob", config_dir(options))
	read_blob :: proc(path: string) -> (^format.Blob_Header, bool) {
		read, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return nil, false
		}
		aligned, _ := mem.alloc_bytes(len(read), format.BLOB_ALIGN, context.temp_allocator)
		copy(aligned, read)
		return format.blob_header(aligned)
	}

	// A warning does not stop it.
	text := fmt.tprintf("ui 1\n<ui font=$%s>\n\t<text cross=\"center\">Hi</text>\n</ui>\n", FONT_GUID)
	problems, ok := check_ui(options, guid, text, kinds)
	testing.expect(t, ok)
	testing.expect_value(t, len(problems.list), 1)
	if len(problems.list) == 1 {
		testing.expect(t, !problems.list[0].error)
		testing.expect_value(t, problems.list[0].line, 3)
		testing.expect_value(t, problems.list[0].column, 8)
	}
	delete(problems.list)
	header, valid := read_blob(blob)
	testing.expect(t, valid && header.guid == guid && header.kind == .Ui)
	if valid {
		// Its key is its text's, which the editor compares a layout with.
		testing.expect_value(t, header.key, hash.fnv64a(transmute([]byte)text))
	}

	// An error leaves the last good one, at its column.
	problems, ok = check_ui(options, guid, "ui 1\n<ui>\n\t<box gap=\"wide\"/>\n</ui>\n", kinds)
	defer delete(problems.list)
	testing.expect(t, !ok)
	testing.expect_value(t, len(problems.list), 1)
	if len(problems.list) == 1 {
		testing.expect(t, problems.list[0].error)
		testing.expect_value(t, problems.list[0].file, "C:/game/ui/menu.ui")
		testing.expect_value(t, problems.list[0].line, 3)
		testing.expect_value(t, problems.list[0].column, 7)
	}
	after, still := read_blob(blob)
	testing.expect(t, still)
	if valid && still {
		testing.expect_value(t, after.key, hash.fnv64a(transmute([]byte)text))
	}

	// A font that is a texture is an error, as in a cook.
	kinds[font] = .Texture
	problems2, ok2 := check_ui(options, guid, text, kinds)
	defer delete(problems2.list)
	testing.expect(t, !ok2)
}

@(private = "file")
check_ui :: proc(options: Cook_Options, guid: format.Guid, text: string, kinds: map[format.Guid]format.Asset_Kind) -> (Problems, bool) {
	return ui_check(options, guid, text, "C:/game/ui/menu.ui", "game/ui/menu.ui", kinds)
}

@(test)
the_ui_attributes_go_to_the_editor_by_their_names :: proc(t: ^testing.T) {
	infos := ui_attribute_infos()
	testing.expect_value(t, len(infos), len(format.UI_ATTRS))
	found := false
	for info in infos {
		if info.name == "text_align" {
			found = true
			testing.expect_value(t, info.kind, "text_align")
			testing.expect(t, info.inherited)
			testing.expect(t, slice.contains(info.elements, "ui") && slice.contains(info.elements, "button"))
		}
	}
	testing.expect(t, found)
}
