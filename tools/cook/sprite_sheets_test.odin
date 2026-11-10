package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import stbi "vendor:stb/image"

import format "cinnabar:engine/asset/format"

@(private = "file")
write_color :: proc(t: ^testing.T, tree: Tree, path: string, width, height: int, color: [4]u8) {
	pixels := make([][4]u8, width * height, context.temp_allocator)
	for &p in pixels {
		p = color
	}
	full := strings.clone_to_cstring(fmt.tprintf("%s/content/%s", tree.dir, path), context.temp_allocator)
	testing.expectf(t, stbi.write_png(full, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4)) != 0, "cannot write %s", path)
}

@(private = "file")
sheet_blob :: proc(t: ^testing.T, tree: Tree, path: string) -> (data: []byte, blob: ^format.Sprite_Sheet_Blob, ok: bool) {
	data = tree_blob(t, tree, tree_guid(t, tree, path))
	blob, ok = format.sprite_sheet_view(data)
	testing.expectf(t, ok, "%s did not cook into a sprite sheet blob", path)
	return
}

@(private = "file")
frame_named :: proc(t: ^testing.T, data: []byte, blob: ^format.Sprite_Sheet_Blob, name: string) -> format.Sprite_Frame {
	index, found := format.sprite_sheet_find_frame(data, blob, name)
	testing.expectf(t, found, "the sheet has no frame %q", name)
	return found ? format.sprite_sheet_frames(data, blob)[index] : {}
}

@(private = "file")
animation_frames :: proc(t: ^testing.T, data: []byte, blob: ^format.Sprite_Sheet_Blob, name: string) -> (frames: []u16, animation: format.Sprite_Animation) {
	index, found := format.sprite_sheet_find_animation(data, blob, name)
	testing.expectf(t, found, "the sheet has no animation %q", name)
	if !found {
		return
	}
	animation = format.sprite_sheet_animations(data, blob)[index]
	return format.sprite_sheet_frame_indices(data, blob)[animation.first:][:animation.count], animation
}

@(private = "file")
RED :: "00112233445566778899aabbccdd0001"
@(private = "file")
GREEN :: "00112233445566778899aabbccdd0002"
@(private = "file")
BLUE :: "00112233445566778899aabbccdd0003"
@(private = "file")
STRIP :: "00112233445566778899aabbccdd0004"

@(test)
a_sheet_parses_its_frames_and_animations :: proc(t: ^testing.T) {
	sheet, problems := sprite_sheet_parse(
		"# A hero.\npixels_per_unit = 16\nfilter = nearest\npivot = 0.5 0\nframe a = $" + RED + "\nframe b = $" + GREEN + "\nanimation walk = a b 0..1 rate=8 loop=false\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, sheet.pixels_per_unit, 16)
	testing.expect_value(t, sheet.filter, format.Sprite_Filter.Nearest)
	testing.expect_value(t, sheet.pivot, [2]f32{0.5, 0})
	testing.expect_value(t, len(sheet.images), 2)
	testing.expect_value(t, sheet.images[1].name, "b")
	testing.expect_value(t, len(sheet.animations), 1)
	testing.expect_value(t, sheet.animations[0].rate, 8)
	testing.expect(t, !sheet.animations[0].loop)
	testing.expect_value(t, len(sheet.animations[0].frames), 3)
	testing.expect_value(t, len(sprite_sheet_images("frame a = $" + RED + "\ntexture = $" + BLUE + "\n")), 1)

	// Each mistake is a problem at its line.
	mistakes := []struct {
		text, fragment: string,
		line:           int,
	} {
		{"frame a = $" + RED + "\nframe a = $" + GREEN + "\n", "twice", 2},
		{"frame a = " + RED + "\n", "after $", 1},
		{"frame = $" + RED + "\n", "needs a name", 1},
		{"texture = $" + RED + "\n", "no grid, rect or import", 1},
		{"grid = 4 2\n", "no `texture = $guid`", 0},
		{"frame a = $" + RED + "\ntexture = $" + GREEN + "\ngrid = 1 1\n", "one or the other", 0},
		{"texture = $" + RED + "\ngrid = 0 2\n", "columns rows", 2},
		{"texture = $" + RED + "\nrect a = 0 0 16\n", "x y width height", 2},
		{"texture = $" + RED + "\nimport = a.json\ngrid = 2 2\n", "both an import", 2},
		{"frame a = $" + RED + "\nanimation walk = a speed=2\n", "unknown option", 2},
		{"frame a = $" + RED + "\nanimation walk = rate=2\n", "names no frames", 2},
		{"frame a = $" + RED + "\nfilter = sharp\n", "linear or nearest", 2},
		{"frame a = $" + RED + "\nsize = 2\n", "unknown key", 2},
		{"", "names no frames", 0},
	}
	for m in mistakes {
		_, found := sprite_sheet_parse(m.text, context.temp_allocator)
		matched := false
		for p in found {
			matched ||= strings.contains(p.message, m.fragment) && p.line == m.line
		}
		testing.expectf(t, matched, "%q: no problem with %q at line %d: %v", m.text, m.fragment, m.line, found)
	}
}

@(test)
a_sheet_packs_the_images_that_it_names_into_its_atlas :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/red.png.meta", "guid = " + RED + "\nusage = color\nstandalone = false\n"},
			{"content/green.png.meta", "guid = " + GREEN + "\nusage = color\n"},
			{"content/blue.png.meta", "guid = " + BLUE + "\nusage = color\n"},
			{
				"content/hero.sprite_sheet",
				"pixels_per_unit = 16\nfilter = nearest\npivot = 0.5 0\nframe red = $" + RED + "\nframe green = $" + GREEN + "\nframe blue = $" + BLUE + "\nanimation all = red green blue rate=4\nanimation back = 2..0 loop=false\n",
			},
		},
	)
	defer remove_tree(tree)
	write_color(t, tree, "red.png", 16, 16, {255, 0, 0, 255})
	write_color(t, tree, "green.png", 24, 16, {0, 255, 0, 255})
	write_color(t, tree, "blue.png", 8, 30, {0, 0, 255, 255})
	options := tree_options(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	// The red image turns off its own blob, and warns of nothing, since the sheet names it.
	textures := cook(options, {.Texture})
	testing.expectf(t, textures.ok && len(errors.messages) == 0, "errors: %v", errors.messages)
	testing.expect_value(t, textures.cooked[.Texture], 2)
	pass := cook(options, {.Sprite_Sheet})
	testing.expectf(t, pass.ok, "errors: %v", errors.messages)
	testing.expect_value(t, pass.cooked[.Sprite_Sheet], 1)
	testing.expect_value(t, pass.cooked[.Texture], 1)

	data, blob, ok := sheet_blob(t, tree, "hero.sprite_sheet")
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/hero.sprite_sheet")
	testing.expect_value(t, blob.pixels_per_unit, 16)
	testing.expect_value(t, blob.filter, format.Sprite_Filter.Nearest)
	// The atlas is the sheet's sub-asset, in its .meta file, and a texture of whole blocks without mips.
	meta_text, err := os.read_entire_file(fmt.tprintf("%s/content/hero.sprite_sheet.meta", tree.dir), context.temp_allocator)
	testing.expect(t, err == nil)
	meta, meta_ok := format.meta_parse(string(meta_text), context.temp_allocator)
	atlas_guid, has_atlas := format.meta_subasset(meta, format.TEXTURE_KIND, format.SPRITE_SHEET_ATLAS_NAME)
	testing.expect(t, meta_ok && has_atlas)
	testing.expect_value(t, blob.atlas, atlas_guid)
	atlas_data := tree_blob(t, tree, atlas_guid)
	atlas, atlas_ok := format.texture_view(atlas_data)
	testing.expect(t, atlas_ok)
	if !atlas_ok {
		return
	}
	testing.expect_value(t, atlas.size, blob.atlas_size)
	testing.expect_value(t, atlas.mip_count, 1)
	testing.expect_value(t, atlas.format, format.Texture_Format.BC7_Unorm_Srgb)
	testing.expect(t, atlas.size.x % 4 == 0 && atlas.size.y % 4 == 0)
	// Each frame keeps its image's size, apart from the others by its border, and has its color in the atlas.
	decoded := make([][4]u8, int(atlas.size.x * atlas.size.y), context.temp_allocator)
	testing.expect_value(t, cn_decompress(.BC7, raw_data(format.blob_bytes(atlas_data, atlas.mips)), atlas.size.x, atlas.size.y, raw_data(decoded)), 0)
	wanted := []struct {
		name:  string,
		size:  [2]u16,
		color: [4]u8,
	}{{"red", {16, 16}, {255, 0, 0, 255}}, {"green", {24, 16}, {0, 255, 0, 255}}, {"blue", {8, 30}, {0, 0, 255, 255}}}
	rects: [3][4]u16
	for w, i in wanted {
		f := frame_named(t, data, blob, w.name)
		rects[i] = f.rect
		testing.expect_value(t, f.rect.zw, w.size)
		testing.expect_value(t, f.pivot, [2]f32{0.5, 0})
		for corner in ([][2]int{{0, 0}, {int(f.rect.z) - 1, int(f.rect.w) - 1}, {-1, -1}, {int(f.rect.z), int(f.rect.w)}}) {
			texel := decoded[(int(f.rect.y) + corner.y) * int(atlas.size.x) + int(f.rect.x) + corner.x]
			for channel in 0 ..< 4 {
				testing.expectf(t, abs(int(texel[channel]) - int(w.color[channel])) <= 3, "%s at %v is %v, want %v", w.name, corner, texel, w.color)
			}
		}
	}
	for a, i in rects {
		for b in rects[i + 1:] {
			apart := a.x + a.z + 2 <= b.x || b.x + b.z + 2 <= a.x || a.y + a.w + 2 <= b.y || b.y + b.w + 2 <= a.y
			testing.expectf(t, apart, "the frames %v and %v are not apart by their borders", a, b)
		}
	}
	all, all_animation := animation_frames(t, data, blob, "all")
	testing.expect(t, len(all) == 3 && all[0] == 0 && all[1] == 1 && all[2] == 2)
	testing.expect(t, all_animation.rate == 4 && bool(all_animation.loop))
	back, back_animation := animation_frames(t, data, blob, "back")
	testing.expect(t, len(back) == 3 && back[0] == 2 && back[2] == 0)
	testing.expect(t, back_animation.rate == DEFAULT_SPRITE_RATE && !back_animation.loop)

	// Nothing changed, so nothing cooks. A changed image cooks the sheet again.
	again := cook(options, {.Sprite_Sheet})
	testing.expect(t, again.ok)
	testing.expect_value(t, again.cooked[.Sprite_Sheet], 0)
	testing.expect_value(t, again.current[.Sprite_Sheet], 1)
	write_color(t, tree, "green.png", 20, 20, {0, 255, 0, 255})
	changed := cook(options, {.Sprite_Sheet})
	testing.expect(t, changed.ok)
	testing.expect_value(t, changed.cooked[.Sprite_Sheet], 1)
	data, blob, ok = sheet_blob(t, tree, "hero.sprite_sheet")
	if ok {
		testing.expect_value(t, frame_named(t, data, blob, "green").rect.zw, [2]u16{20, 20})
		testing.expect_value(t, blob.atlas, atlas_guid)
	}
}

@(test)
a_sheet_takes_a_textures_grid_and_rects :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/strip.png.meta", "guid = " + STRIP + "\nusage = color\n"},
			{"content/grid.sprite_sheet", "texture = $" + STRIP + "\ngrid = 4 2\nrect whole = 0 0 64 32\nanimation top = 0..3 rate=12\nanimation one = 5 whole\n"},
			{"content/spaced.sprite_sheet", "texture = $" + STRIP + "\ngrid = 3 1 2 6\n"},
		},
	)
	defer remove_tree(tree)
	write_color(t, tree, "strip.png", 64, 32, {200, 100, 50, 255})
	options := tree_options(tree)
	pass := cook(options, {.Sprite_Sheet})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Sprite_Sheet], 2)
	// A sheet of a texture has no atlas of its own.
	testing.expect_value(t, pass.cooked[.Texture], 0)
	data, blob, ok := sheet_blob(t, tree, "grid.sprite_sheet")
	if !ok {
		return
	}
	strip, _ := format.guid_parse(STRIP)
	testing.expect_value(t, blob.atlas, strip)
	testing.expect_value(t, blob.atlas_size, [2]u32{64, 32})
	testing.expect_value(t, blob.pixels_per_unit, DEFAULT_PIXELS_PER_UNIT)
	testing.expect_value(t, len(format.sprite_sheet_frames(data, blob)), 9)
	testing.expect_value(t, frame_named(t, data, blob, "0").rect, [4]u16{0, 0, 16, 16})
	testing.expect_value(t, frame_named(t, data, blob, "6").rect, [4]u16{32, 16, 16, 16})
	testing.expect_value(t, frame_named(t, data, blob, "whole").rect, [4]u16{0, 0, 64, 32})
	testing.expect_value(t, frame_named(t, data, blob, "whole").pivot, [2]f32{0.5, 0.5})
	top, _ := animation_frames(t, data, blob, "top")
	testing.expect(t, len(top) == 4 && top[0] == 0 && top[3] == 3)
	one, _ := animation_frames(t, data, blob, "one")
	testing.expect(t, len(one) == 2 && one[0] == 5 && one[1] == 8)
	// A margin of 2 and a spacing of 6: three cells of 16 by 28.
	data, blob, ok = sheet_blob(t, tree, "spaced.sprite_sheet")
	if ok {
		testing.expect_value(t, frame_named(t, data, blob, "0").rect, [4]u16{2, 2, 16, 28})
		testing.expect_value(t, frame_named(t, data, blob, "2").rect, [4]u16{46, 2, 16, 28})
	}
}

// What Aseprite exports with its frames as a hash, in an order that sorting their names would not keep.
@(private = "file")
ASEPRITE_HASH :: `{ "frames": {
   "hero 10.aseprite": { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 }, "rotated": false, "trimmed": false, "duration": 100 },
   "hero 2.aseprite": { "frame": { "x": 16, "y": 0, "w": 16, "h": 16 }, "rotated": false, "trimmed": false, "duration": 250 },
   "hero 1.aseprite": { "frame": { "x": 32, "y": 0, "w": 16, "h": 16 }, "rotated": false, "trimmed": false, "duration": 100 },
   "hero 3.aseprite": { "frame": { "x": 48, "y": 0, "w": 16, "h": 16 }, "rotated": false, "trimmed": false, "duration": 100 }
 },
 "meta": { "app": "https://www.aseprite.org/", "image": "strip.png", "size": { "w": 64, "h": 32 },
  "frameTags": [
   { "name": "walk", "from": 0, "to": 2, "direction": "forward" },
   { "name": "back", "from": 1, "to": 3, "direction": "reverse" },
   { "name": "sway", "from": 0, "to": 3, "direction": "pingpong" }
  ] }
}`

// The same as an array, and TexturePacker's, which has pivots from the top left and no tags.
@(private = "file")
ASEPRITE_ARRAY :: `{ "frames": [
   { "filename": "a", "frame": { "x": 0, "y": 16, "w": 32, "h": 16 }, "duration": 50 },
   { "filename": "b", "frame": { "x": 32, "y": 16, "w": 32, "h": 16 }, "duration": 50 }
 ],
 "meta": { "frameTags": [ { "name": "both", "from": 0, "to": 1, "direction": "forward" } ] }
}`
@(private = "file")
TEXTURE_PACKER :: `{"frames": {
"coin.png": {"frame": {"x":0,"y":0,"w":20,"h":20}, "rotated": false, "trimmed": false, "spriteSourceSize": {"x":0,"y":0,"w":20,"h":20}, "sourceSize": {"w":20,"h":20}, "pivot": {"x":0.5,"y":1}},
"gem.png": {"frame": {"x":20,"y":0,"w":12.0,"h":20}, "rotated": false, "trimmed": false, "spriteSourceSize": {"x":0,"y":0,"w":12,"h":20}, "sourceSize": {"w":12,"h":20}}},
"meta": {"app": "https://www.codeandweb.com/texturepacker", "image": "strip.png", "format": "RGBA8888", "size": {"w":64,"h":32}, "scale": "1"}
}`

@(test)
a_sheet_imports_the_json_of_aseprite_and_texturepacker :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/strip.png.meta", "guid = " + STRIP + "\nusage = color\n"},
			{"content/hash.json", ASEPRITE_HASH},
			{"content/hash.sprite_sheet", "texture = $" + STRIP + "\nimport = hash.json\npivot = 0.5 0\nanimation first = 0 rate=2\n"},
			{"content/sub/array.json", ASEPRITE_ARRAY},
			{"content/array.sprite_sheet", "texture = $" + STRIP + "\nimport = sub/array.json\n"},
			{"content/packer.json", TEXTURE_PACKER},
			{"content/packer.sprite_sheet", "texture = $" + STRIP + "\nimport = packer.json\nanimation spin = coin.png gem.png\n"},
		},
	)
	defer remove_tree(tree)
	write_color(t, tree, "strip.png", 64, 32, {200, 100, 50, 255})
	options := tree_options(tree)
	pass := cook(options, {.Sprite_Sheet})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Sprite_Sheet], 3)
	// A JSON file is not an asset.
	_, json_meta := os.read_entire_file(fmt.tprintf("%s/content/hash.json.meta", tree.dir), context.temp_allocator)
	testing.expect(t, json_meta != nil)

	data, blob, ok := sheet_blob(t, tree, "hash.sprite_sheet")
	if !ok {
		return
	}
	// The frames are in the file's order, with their durations in seconds and the sheet's pivot.
	frames := format.sprite_sheet_frames(data, blob)
	testing.expect_value(t, len(frames), 4)
	testing.expect_value(t, format.blob_string(data, frames[0].name), "hero 10.aseprite")
	testing.expect_value(t, format.blob_string(data, frames[1].name), "hero 2.aseprite")
	testing.expect_value(t, frames[1].rect, [4]u16{16, 0, 16, 16})
	testing.expect(t, abs(frames[1].duration - 0.25) < 1e-6 && abs(frames[0].duration - 0.1) < 1e-6)
	testing.expect_value(t, frames[2].pivot, [2]f32{0.5, 0})
	walk, _ := animation_frames(t, data, blob, "walk")
	testing.expect(t, len(walk) == 3 && walk[0] == 0 && walk[2] == 2)
	back, _ := animation_frames(t, data, blob, "back")
	testing.expect(t, len(back) == 3 && back[0] == 3 && back[2] == 1)
	sway, _ := animation_frames(t, data, blob, "sway")
	testing.expect(t, len(sway) == 6 && sway[3] == 3 && sway[4] == 2 && sway[5] == 1)
	// The sheet's own animations come after the tags.
	first, first_animation := animation_frames(t, data, blob, "first")
	testing.expect(t, len(first) == 1 && first[0] == 0 && first_animation.rate == 2)
	frame, _ := format.sprite_sheet_frame_at(data, blob, 0, 0.3)
	testing.expect_value(t, frame, 1)

	data, blob, ok = sheet_blob(t, tree, "array.sprite_sheet")
	if ok {
		testing.expect_value(t, frame_named(t, data, blob, "b").rect, [4]u16{32, 16, 32, 16})
		both, _ := animation_frames(t, data, blob, "both")
		testing.expect_value(t, len(both), 2)
	}
	data, blob, ok = sheet_blob(t, tree, "packer.sprite_sheet")
	if ok {
		// TexturePacker's pivot is from the top, and a frame without one takes the sheet's.
		testing.expect_value(t, frame_named(t, data, blob, "coin.png").pivot, [2]f32{0.5, 0})
		testing.expect_value(t, frame_named(t, data, blob, "gem.png").pivot, [2]f32{0.5, 0.5})
		testing.expect_value(t, frame_named(t, data, blob, "gem.png").rect, [4]u16{20, 0, 12, 20})
		spin, spin_animation := animation_frames(t, data, blob, "spin")
		testing.expect(t, len(spin) == 2 && spin_animation.rate == DEFAULT_SPRITE_RATE)
	}

	// A change to the JSON file cooks its sheet again, and only that one.
	changed := strings.concatenate({ASEPRITE_ARRAY[:len(ASEPRITE_ARRAY) - 2], " }"}, context.temp_allocator)
	changed, _ = strings.replace(changed, `"w": 32, "h": 16 }, "duration": 50 },`, `"w": 16, "h": 16 }, "duration": 50 },`, 1, context.temp_allocator)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/sub/array.json", tree.dir), transmute([]byte)changed) == nil)
	again := cook(options, {.Sprite_Sheet})
	testing.expect(t, again.ok)
	testing.expect_value(t, again.cooked[.Sprite_Sheet], 1)
	testing.expect_value(t, again.current[.Sprite_Sheet], 2)
}

@(test)
a_sheet_that_is_wrong_fails_with_its_reason :: proc(t: ^testing.T) {
	NONE :: "00112233445566778899aabbccdd00ff"
	tree := make_tree(
		t,
		{
			{"content/strip.png.meta", "guid = " + STRIP + "\nusage = color\n"},
			{"content/missing.sprite_sheet", "frame a = $" + NONE + "\n"},
			{"content/uneven.sprite_sheet", "texture = $" + STRIP + "\ngrid = 5 1\n"},
			{"content/outside.sprite_sheet", "texture = $" + STRIP + "\nrect a = 60 0 16 16\n"},
			{"content/unnamed.sprite_sheet", "texture = $" + STRIP + "\ngrid = 2 1\nanimation walk = 0 run 7\n"},
			{"content/nojson.sprite_sheet", "texture = $" + STRIP + "\nimport = gone.json\n"},
			{"content/rotated.json", `{"frames": [{"filename": "a", "frame": {"x":0,"y":0,"w":8,"h":8}, "rotated": true}]}`},
			{"content/rotated.sprite_sheet", "texture = $" + STRIP + "\nimport = rotated.json\n"},
			{"content/tags.json", `{"frames": [{"filename": "a", "frame": {"x":0,"y":0,"w":8,"h":8}}], "meta": {"frameTags": [{"name": "t", "from": 0, "to": 4}]}}`},
			{"content/tags.sprite_sheet", "texture = $" + STRIP + "\nimport = tags.json\n"},
			{"content/self.sprite_sheet", "texture = $" + STRIP + "\ngrid = 1 1\n"},
			{"content/nested.sprite_sheet", "frame a = $00112233445566778899aabbccdd00aa\n"},
			{"content/self.sprite_sheet.meta", "guid = 00112233445566778899aabbccdd00aa\n"},
			{"content/text.sprite_sheet", "frame a\n"},
		},
	)
	defer remove_tree(tree)
	write_color(t, tree, "strip.png", 64, 32, {200, 100, 50, 255})
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	pass := cook(tree_options(tree), {.Sprite_Sheet})
	testing.expect(t, !pass.ok)
	// The one good sheet cooks beside the others.
	testing.expect_value(t, pass.cooked[.Sprite_Sheet], 1)
	expect_error(t, &errors, "no asset has the GUID $" + NONE)
	expect_error(t, &errors, "a grid of 5 by 1 does not divide evenly")
	expect_error(t, &errors, `the frame "a" reaches outside game/strip.png`)
	expect_error(t, &errors, `"run" is not a frame's name`)
	expect_error(t, &errors, `"7" is not a frame's name`)
	expect_error(t, &errors, "cannot read gone.json")
	expect_error(t, &errors, "is rotated")
	expect_error(t, &errors, `the tag "t" has no range of frames`)
	expect_error(t, &errors, "game/self.sprite_sheet is not an image")
	expect_error(t, &errors, "needs `key = value`")
}
