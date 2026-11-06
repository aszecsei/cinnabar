package cook

import "core:fmt"
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
