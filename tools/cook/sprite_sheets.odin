package cook

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Sprite sheets are .sprite_sheet text files: the frames of a texture and the animations that play them, which a
// Sprite_Renderer draws (see docs/content/kinds/sprite-sheets.md#sprite-sheets). A sheet names its frames in one of
// three ways: images that the cooker packs into an atlas of the sheet's own, a texture with a grid or rectangles, or a
// texture with the JSON description that Aseprite or TexturePacker exports.
SPRITE_SHEET_COOK_VERSION :: "sprite sheets 1"

// A packed atlas's sides are at most this many texels.
MAX_SPRITE_ATLAS :: 4096
// Each packed frame has this many texels of its own edge around it, so a filtered lookup at its edge reads no
// neighbour.
SPRITE_ATLAS_BORDER :: 1
// What a sheet has when its text does not say: its texels to a meter, and an animation's frames a second.
DEFAULT_PIXELS_PER_UNIT :: 100
DEFAULT_SPRITE_RATE :: 10

// SPRITE_SHEET_TEMPLATE is a new sprite sheet's text: comments that show the three ways to name frames.
SPRITE_SHEET_TEMPLATE :: `# The frames are the images that the cooker packs into one atlas:
#   frame idle_0 = $<an image's GUID>
#   frame idle_1 = $<an image's GUID>
# or a texture with a grid of frames, named 0, 1, 2 and on, or with rectangles of x y width height:
#   texture = $<a texture's GUID>
#   grid = 4 2
#   rect jump = 0 32 16 16
# or a texture with the JSON file that Aseprite or TexturePacker exported beside this file:
#   texture = $<a texture's GUID>
#   import = hero.json
# An animation is frames by name, or a range of them by index:
#   animation idle = idle_0 idle_1 rate=8
#   animation run = 0..3 rate=12 loop=false
pixels_per_unit = 100
filter = linear
pivot = 0.5 0.5
`

// Sheet_Problem is an error in a sprite sheet's text, at a line from 1, or 0 for the whole file.
Sheet_Problem :: struct {
	line:    int,
	message: string,
}

// Sheet_Image is an image that a sheet packs: `frame <name> = $guid`.
Sheet_Image :: struct {
	name: string,
	guid: format.Guid,
	line: int,
}

// Sheet_Rect is a frame that a sheet names in its texture: `rect <name> = x y width height`.
Sheet_Rect :: struct {
	name: string,
	rect: [4]int,
	line: int,
}

// Sheet_Animation is an animation as a sheet's text gives it: its frames are names, indices or ranges of indices.
Sheet_Animation :: struct {
	name:   string,
	frames: []string,
	rate:   f32,
	loop:   bool,
	line:   int,
}

// Sheet_Text is what a .sprite_sheet says, before its images are read.
Sheet_Text :: struct {
	pixels_per_unit: f32,
	filter:          format.Sprite_Filter,
	pivot:           [2]f32,
	images:          []Sheet_Image,
	texture:         format.Guid,
	texture_line:    int,
	// columns, rows, margin and spacing, when it has a grid.
	grid:            [4]int,
	grid_line:       int,
	rects:           []Sheet_Rect,
	// The JSON description's path, relative to the sheet's directory.
	import_path:     string,
	import_line:     int,
	animations:      []Sheet_Animation,
}

// sprite_sheet_parse reads a .sprite_sheet: lines of `key = value`, and # comments. It gives every problem that it
// finds, and the sheet is good only without any.
sprite_sheet_parse :: proc(text: string, allocator := context.allocator) -> (sheet: Sheet_Text, problems: []Sheet_Problem) {
	context.allocator = allocator
	found := make([dynamic]Sheet_Problem)
	problem :: proc(found: ^[dynamic]Sheet_Problem, line: int, f: string, args: ..any) {
		append(found, Sheet_Problem{line, fmt.aprintf(f, ..args)})
	}
	guid_of :: proc(found: ^[dynamic]Sheet_Problem, line: int, value: string) -> (guid: format.Guid, ok: bool) {
		if !strings.has_prefix(value, "$") {
			problem(found, line, "an image or a texture is an asset's GUID after $")
			return
		}
		guid, ok = format.guid_parse(value[1:])
		if !ok {
			problem(found, line, "a GUID is 32 hex digits after $")
		}
		return
	}
	sheet = {
		pixels_per_unit = DEFAULT_PIXELS_PER_UNIT,
		pivot           = {0.5, 0.5},
	}
	images := make([dynamic]Sheet_Image)
	rects := make([dynamic]Sheet_Rect)
	animations := make([dynamic]Sheet_Animation)
	names := make(map[string]bool)
	rest := text
	line_number := 0
	for raw_line in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		equals := strings.index_byte(line, '=')
		if equals < 0 {
			problem(&found, line_number, "needs `key = value`")
			continue
		}
		key_fields := strings.fields(line[:equals])
		value := strings.trim_space(line[equals + 1:])
		if len(key_fields) == 0 || len(key_fields) > 2 {
			problem(&found, line_number, "needs `key = value`, where the key is one word, or frame, rect or animation and a name")
			continue
		}
		key := key_fields[0]
		name := len(key_fields) == 2 ? key_fields[1] : ""
		named := key == "frame" || key == "rect" || key == "animation"
		if named != (name != "") {
			problem(&found, line_number, named ? "%s needs a name: `%s <name> = ...`" : "%s takes no name", key, key)
			continue
		}
		fields := strings.fields(value)
		switch key {
		case "pixels_per_unit":
			v, ok := strconv.parse_f32(value)
			if !ok || v <= 0 {
				problem(&found, line_number, "pixels_per_unit is a number above 0")
				continue
			}
			sheet.pixels_per_unit = v
		case "filter":
			switch value {
			case "linear":
				sheet.filter = .Linear
			case "nearest":
				sheet.filter = .Nearest
			case:
				problem(&found, line_number, "filter is linear or nearest")
			}
		case "pivot":
			x, x_ok := strconv.parse_f32(len(fields) == 2 ? fields[0] : "")
			y, y_ok := strconv.parse_f32(len(fields) == 2 ? fields[1] : "")
			if !x_ok || !y_ok {
				problem(&found, line_number, "pivot is two numbers: the share of a frame's width and of its height, from its bottom left")
				continue
			}
			sheet.pivot = {x, y}
		case "texture":
			if sheet.texture_line != 0 {
				problem(&found, line_number, "has texture twice")
				continue
			}
			guid := guid_of(&found, line_number, value) or_continue
			sheet.texture, sheet.texture_line = guid, line_number
		case "import":
			if sheet.import_line != 0 || value == "" {
				problem(&found, line_number, sheet.import_line != 0 ? "has import twice" : "import is a JSON file's path from this file's directory")
				continue
			}
			sheet.import_path, sheet.import_line = strings.clone(value), line_number
		case "grid":
			numbers: [4]int
			ok := len(fields) >= 2 && len(fields) <= 4 && sheet.grid_line == 0
			for f, i in fields[:min(len(fields), 4)] {
				n, n_ok := strconv.parse_int(f)
				numbers[i] = n
				ok &&= n_ok && n >= 0
			}
			if !ok || numbers[0] == 0 || numbers[1] == 0 {
				problem(&found, line_number, sheet.grid_line != 0 ? "has grid twice" : "grid is `columns rows`, then a margin and a spacing in texels if it has them")
				continue
			}
			sheet.grid, sheet.grid_line = numbers, line_number
		case "frame":
			guid := guid_of(&found, line_number, value) or_continue
			if names[name] {
				problem(&found, line_number, "has the frame %q twice", name)
				continue
			}
			names[name] = true
			append(&images, Sheet_Image{strings.clone(name), guid, line_number})
		case "rect":
			r: [4]int
			ok := len(fields) == 4
			for f, i in fields[:min(len(fields), 4)] {
				n, n_ok := strconv.parse_int(f)
				r[i] = n
				ok &&= n_ok && n >= 0
			}
			if !ok || r.z == 0 || r.w == 0 {
				problem(&found, line_number, "a rect is `x y width height` in texels from the texture's top left")
				continue
			}
			if names[name] {
				problem(&found, line_number, "has the frame %q twice", name)
				continue
			}
			names[name] = true
			append(&rects, Sheet_Rect{strings.clone(name), r, line_number})
		case "animation":
			a := Sheet_Animation {
				name = strings.clone(name),
				rate = DEFAULT_SPRITE_RATE,
				loop = true,
				line = line_number,
			}
			frames := make([dynamic]string)
			ok := true
			for f in fields {
				option := strings.index_byte(f, '=')
				if option < 0 {
					append(&frames, strings.clone(f))
					continue
				}
				switch f[:option] {
				case "rate":
					rate, rate_ok := strconv.parse_f32(f[option + 1:])
					if !rate_ok || rate <= 0 {
						problem(&found, line_number, "rate is frames a second, above 0")
						ok = false
					}
					a.rate = rate
				case "loop":
					if f[option + 1:] != "true" && f[option + 1:] != "false" {
						problem(&found, line_number, "loop is true or false")
						ok = false
					}
					a.loop = f[option + 1:] == "true"
				case:
					problem(&found, line_number, "unknown option %q: an animation takes rate and loop", f[:option])
					ok = false
				}
			}
			for other in animations {
				if other.name == name {
					problem(&found, line_number, "has the animation %q twice", name)
					ok = false
				}
			}
			if len(frames) == 0 {
				problem(&found, line_number, "the animation %q names no frames", name)
				ok = false
			}
			if ok {
				a.frames = frames[:]
				append(&animations, a)
			}
		case:
			problem(&found, line_number, "unknown key %q: a sheet's keys are pixels_per_unit, filter, pivot, frame, texture, grid, rect, import and animation", key)
		}
	}
	sheet.images, sheet.rects, sheet.animations = images[:], rects[:], animations[:]
	described := sheet.grid_line != 0 || len(sheet.rects) > 0 || sheet.import_line != 0
	switch {
	case len(sheet.images) > 0 && (sheet.texture_line != 0 || described):
		problem(&found, 0, "has both frame lines, which the cooker packs, and a texture's frames: a sheet has one or the other")
	case len(sheet.images) == 0 && sheet.texture_line == 0:
		problem(&found, 0, described ? "has frames of a texture, but no `texture = $guid`" : "names no frames: it needs frame lines, or a texture with a grid, rect lines or an import")
	case sheet.texture_line != 0 && !described:
		problem(&found, sheet.texture_line, "has a texture, but no grid, rect or import to say where its frames are")
	case sheet.import_line != 0 && (sheet.grid_line != 0 || len(sheet.rects) > 0):
		problem(&found, sheet.import_line, "has both an import and a grid or rects: the imported file says where the frames are")
	}
	return sheet, found[:]
}

// sprite_sheet_images are the GUIDs of the images that a sheet's text packs, which the texture pass reads before the
// sheets cook, so an image that only a sheet uses can turn off its own blob (see cook_textures).
sprite_sheet_images :: proc(text: string, allocator := context.temp_allocator) -> []format.Guid {
	guids := make([dynamic]format.Guid, allocator)
	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw_line)
		if !strings.has_prefix(line, "frame") {
			continue
		}
		if dollar := strings.index_byte(line, '$'); dollar >= 0 {
			if guid, ok := format.guid_parse(strings.trim_space(line[dollar + 1:])); ok {
				append(&guids, guid)
			}
		}
	}
	return guids[:]
}

// Imported_Sheet is what a JSON description gives: frames in the file's order, with their durations, and its tags as
// animations of frame indices.
Imported_Sheet :: struct {
	frames:     []format.Sprite_Frame_Contents,
	// Whether each frame gave a pivot of its own.
	has_pivot:  []bool,
	animations: []format.Sprite_Animation_Contents,
}

// sprite_sheet_import reads the JSON that Aseprite exports beside a sheet's image, with its frames as a hash or as an
// array, or TexturePacker's, which has the same shape. A frame's name is its key or its filename, its duration is in
// milliseconds, and its pivot, if it has one, is a share of the frame from its top left. meta.frameTags are the
// animations: a range of frames, forward, reverse or pingpong. Rotated frames are not read.
sprite_sheet_import :: proc(data: []byte, allocator := context.allocator) -> (sheet: Imported_Sheet, problem: string) {
	context.allocator = allocator
	root, err := json.parse(data, parse_integers = true, allocator = allocator)
	if err != .None {
		return {}, fmt.aprintf("is not JSON: %v", err)
	}
	number :: proc(v: json.Value) -> (f64, bool) {
		#partial switch n in v {
		case json.Integer:
			return f64(n), true
		case json.Float:
			return n, true
		}
		return 0, false
	}
	Named :: struct {
		name:  string,
		value: json.Value,
		at:    int,
	}
	object, is_object := root.(json.Object)
	if !is_object {
		return {}, "is not a JSON object with frames"
	}
	entries := make([dynamic]Named)
	#partial switch frames in object["frames"] {
	case json.Array:
		for v in frames {
			o, _ := v.(json.Object)
			name, _ := o["filename"].(json.String)
			append(&entries, Named{name, v, 0})
		}
	case json.Object:
		// A JSON object's keys have an order in the file, which the parser's map does not keep: the frames are in the
		// order of their keys in the text.
		text := string(data)
		for name, v in frames {
			append(&entries, Named{name, v, strings.index(text, fmt.tprintf("%q", name))})
		}
		slice.sort_by(entries[:], proc(a, b: Named) -> bool {
			return a.at != b.at ? a.at < b.at : a.name < b.name
		})
	case:
		return {}, "has no frames"
	}
	if len(entries) == 0 || len(entries) > format.MAX_SPRITE_FRAMES {
		return {}, fmt.aprintf("has %d frames, and a sheet has from 1 to %d", len(entries), format.MAX_SPRITE_FRAMES)
	}
	frames := make([]format.Sprite_Frame_Contents, len(entries))
	has_pivot := make([]bool, len(entries))
	for e, i in entries {
		o, _ := e.value.(json.Object)
		rect, has_rect := o["frame"].(json.Object)
		if e.name == "" || !has_rect {
			return {}, fmt.aprintf("frame %d has no name or no frame rectangle", i)
		}
		if rotated, _ := o["rotated"].(json.Boolean); rotated {
			return {}, fmt.aprintf("the frame %q is rotated, which a sheet does not read. Export without rotation.", e.name)
		}
		r: [4]u16
		for field, k in ([4]string{"x", "y", "w", "h"}) {
			n, ok := number(rect[field])
			if !ok || n < 0 || n > 65535 {
				return {}, fmt.aprintf("the frame %q has no %s from 0 to 65535", e.name, field)
			}
			r[k] = u16(n)
		}
		frames[i] = {name = strings.clone(e.name), rect = r}
		if ms, ok := number(o["duration"]); ok && ms > 0 {
			frames[i].duration = f32(ms / 1000)
		}
		if pivot, ok := o["pivot"].(json.Object); ok {
			x, x_ok := number(pivot["x"])
			y, y_ok := number(pivot["y"])
			if x_ok && y_ok {
				frames[i].pivot, has_pivot[i] = {f32(x), 1 - f32(y)}, true
			}
		}
	}
	animations := make([dynamic]format.Sprite_Animation_Contents)
	meta, _ := object["meta"].(json.Object)
	tags, _ := meta["frameTags"].(json.Array)
	for tag in tags {
		t, _ := tag.(json.Object)
		name, _ := t["name"].(json.String)
		from, from_ok := number(t["from"])
		to, to_ok := number(t["to"])
		if name == "" || !from_ok || !to_ok || from < 0 || to < from || int(to) >= len(frames) {
			return {}, fmt.aprintf("the tag %q has no range of frames from 0 to %d", name, len(frames) - 1)
		}
		for other in animations {
			if other.name == name {
				return {}, fmt.aprintf("has the tag %q twice", name)
			}
		}
		indices := make([dynamic]u16)
		for i in int(from) ..= int(to) {
			append(&indices, u16(i))
		}
		direction, _ := t["direction"].(json.String)
		switch direction {
		case "reverse":
			slice.reverse(indices[:])
		case "pingpong":
			for i := int(to) - 1; i > int(from); i -= 1 {
				append(&indices, u16(i))
			}
		}
		append(&animations, format.Sprite_Animation_Contents{name = strings.clone(name), frames = indices[:], rate = DEFAULT_SPRITE_RATE, loop = true})
	}
	return {frames, has_pivot, animations[:]}, ""
}

cook_sprite_sheets :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	sheets := carry_kind(pass, {.Sprite_Sheet})
	if len(sheets) > 0 && !make_output_dir(pass, out_dir, {.Sprite_Sheet}) {
		return false
	}
	by_guid := make(map[format.Guid]int, len(assets), context.temp_allocator)
	for a, i in assets {
		by_guid[a.meta.guid] = i
	}
	ok := true
	step_begin(pass, .Sprite_Sheet, "", len(sheets))
	for i in sheets {
		defer step_advance(pass)
		asset_source(pass, i)
		result := cook_sprite_sheet(options, i, assets, by_guid, out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

// sheet_image is the index of the image asset that a sheet names, with its source read.
@(private = "file")
sheet_image :: proc(pass: ^Pass, a: ^Asset_Source, assets: []Asset_Source, by_guid: map[format.Guid]int, guid: format.Guid, line: int) -> (child: int, ok: bool) {
	problems := &pass.problems
	child, ok = by_guid[guid]
	if !ok {
		report_error(problems, a.path, line, 0, "no asset has the GUID $%s", guid_text(guid))
		return
	}
	if c := assets[child]; c.kind != .Texture || is_texture_set(c) || texture_setting(c, "layout") != "2d" {
		report_error(problems, a.path, line, 0, "%s is not an image", c.name)
		return child, false
	}
	asset_source(pass, child)
	return child, true
}

@(private = "file")
cook_sprite_sheet :: proc(options: Cook_Options, index: int, assets: []Asset_Source, by_guid: map[format.Guid]int, out_dir: string, pass: ^Pass) -> Asset_Result {
	a := &assets[index]
	problems := &pass.problems
	settings_ok := check_settings(a^, problems)
	sheet, parse_problems := sprite_sheet_parse(string(source_of(a^)), context.temp_allocator)
	for p in parse_problems {
		report_error(problems, a.path, p.line, 0, "%s", p.message)
	}
	// A sheet with errors keeps its old blob, so the running game keeps the last good version.
	if len(parse_problems) > 0 || !settings_ok {
		return .Failed
	}
	guid := a.meta.guid
	packed := len(sheet.images) > 0
	// What it names is known whether it cooks or not, so the index has it either way.
	children := make([]int, len(sheet.images), context.temp_allocator)
	found := true
	for image, i in sheet.images {
		child, ok := sheet_image(pass, a, assets, by_guid, image.guid, image.line)
		children[i] = child
		found &&= ok
		append(&a.dependencies, image.guid)
	}
	texture := -1
	if !packed {
		child, ok := sheet_image(pass, a, assets, by_guid, sheet.texture, sheet.texture_line)
		texture = child
		found &&= ok
		append(&a.dependencies, sheet.texture)
	}
	if !found {
		return .Failed
	}
	atlas_guid := sheet.texture
	if packed {
		if !assign_subassets(options.roots[a.root].dir, a, {{kind = .Texture, name = format.SPRITE_SHEET_ATLAS_NAME}}, pass.force[guid], problems) {
			return .Failed
		}
		for s in a.subassets {
			if s.kind == .Texture && s.name == format.SPRITE_SHEET_ATLAS_NAME {
				atlas_guid = s.guid
			}
		}
	}
	imported: []byte
	if sheet.import_line != 0 {
		path := fmt.tprintf("%s/%s", filepath.dir(a.path), sheet.import_path)
		if size, modified, stamped := file_stamp(path); stamped {
			append(&a.inputs, Input_Stamp{strings.clone(path, context.temp_allocator), size, modified})
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			report_error(problems, a.path, sheet.import_line, 0, "cannot read %s: %v", sheet.import_path, err)
			return .Failed
		}
		imported = data
	}

	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00%x\x00%x\x00", SPRITE_SHEET_COOK_VERSION, TEXTURE_COOK_VERSION, options.config, a.name, format.sprite_sheet_layout(), format.texture_layout()),
	)
	key = hash.fnv64a(source_of(a^), key)
	key = hash.fnv64a(guid[:], key)
	key = hash.fnv64a(atlas_guid[:], key)
	for child in children {
		key = hash.fnv64a(source_of(assets[child]), key)
	}
	if texture >= 0 {
		key = hash.fnv64a(source_of(assets[texture]), key)
	}
	key = hash.fnv64a(imported, key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	atlas_output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(atlas_guid))
	if cooked_key(output, .Sprite_Sheet, format.sprite_sheet_layout()) == key && (!packed || cooked_key(atlas_output, .Texture, format.texture_layout()) == key) && !pass.force[guid] {
		return .Current
	}

	frames := make([dynamic]format.Sprite_Frame_Contents, context.temp_allocator)
	animations := make([dynamic]format.Sprite_Animation_Contents, context.temp_allocator)
	atlas_size: [2]u32
	atlas_blob: []byte
	color := Texture_Cook{usage = .Color, max_size = 16384}
	if packed {
		images := make([]Image, len(children), context.temp_allocator)
		sizes := make([][2]int, len(children), context.temp_allocator)
		for child, i in children {
			image, ok := decode_image_bytes(source_of(assets[child]), assets[child].path, color, problems)
			if !ok {
				return .Failed
			}
			if image.width > 65535 || image.height > 65535 {
				report_error(problems, a.path, sheet.images[i].line, 0, "%s is larger than a frame can be", assets[child].name)
				return .Failed
			}
			images[i] = image
			sizes[i] = {image.width + 2 * SPRITE_ATLAS_BORDER, image.height + 2 * SPRITE_ATLAS_BORDER}
		}
		corners, size, fits := pack_rects(sizes, MAX_SPRITE_ATLAS)
		if !fits {
			report_error(problems, a.path, 0, 0, "has %d frames, which do not fit in an atlas of %d texels a side. Use smaller images, or more than one sheet.", len(images), MAX_SPRITE_ATLAS)
			return .Failed
		}
		// The atlas compresses in blocks of 4 texels, and a size that is not whole blocks would be resampled.
		size = {(size.x + 3) / 4 * 4, (size.y + 3) / 4 * 4}
		atlas := Image{size.x, size.y, make([][4]f32, size.x * size.y, context.temp_allocator)}
		for image, i in images {
			origin := corners[i] + SPRITE_ATLAS_BORDER
			// The frame, with its edge's texels again around it.
			for y in -SPRITE_ATLAS_BORDER ..< image.height + SPRITE_ATLAS_BORDER {
				for x in -SPRITE_ATLAS_BORDER ..< image.width + SPRITE_ATLAS_BORDER {
					source := image.pixels[clamp(y, 0, image.height - 1) * image.width + clamp(x, 0, image.width - 1)]
					atlas.pixels[(origin.y + y) * atlas.width + origin.x + x] = source
				}
			}
			append(&frames, format.Sprite_Frame_Contents{name = sheet.images[i].name, rect = {u16(origin.x), u16(origin.y), u16(image.width), u16(image.height)}, pivot = sheet.pivot})
		}
		atlas_size = {u32(size.x), u32(size.y)}
		blob, ok := cook_texture_image(options, atlas, color, atlas_guid, key, fmt.tprintf("%s#%s", a.name, format.SPRITE_SHEET_ATLAS_NAME), a.path, problems)
		if !ok {
			return .Failed
		}
		atlas_blob = blob
	} else {
		image, ok := decode_image_bytes(source_of(assets[texture]), assets[texture].path, color, problems)
		if !ok {
			return .Failed
		}
		atlas_size = {u32(image.width), u32(image.height)}
		if sheet.import_line != 0 {
			described, message := sprite_sheet_import(imported, context.temp_allocator)
			if message != "" {
				report_error(problems, a.path, sheet.import_line, 0, "%s %s", sheet.import_path, message)
				return .Failed
			}
			for f, i in described.frames {
				frame := f
				if !described.has_pivot[i] {
					frame.pivot = sheet.pivot
				}
				append(&frames, frame)
			}
			append(&animations, ..described.animations)
		}
		if sheet.grid_line != 0 {
			columns, rows, margin, spacing := sheet.grid[0], sheet.grid[1], sheet.grid[2], sheet.grid[3]
			inner := [2]int{image.width - 2 * margin - (columns - 1) * spacing, image.height - 2 * margin - (rows - 1) * spacing}
			if inner.x <= 0 || inner.y <= 0 || inner.x % columns != 0 || inner.y % rows != 0 {
				report_error(problems, a.path, sheet.grid_line, 0, "%s is %d by %d texels, which a grid of %d by %d does not divide evenly", assets[texture].name, image.width, image.height, columns, rows)
				return .Failed
			}
			cell := [2]int{inner.x / columns, inner.y / rows}
			for row in 0 ..< rows {
				for column in 0 ..< columns {
					x, y := margin + column * (cell.x + spacing), margin + row * (cell.y + spacing)
					append(&frames, format.Sprite_Frame_Contents{name = fmt.tprintf("%d", row * columns + column), rect = {u16(x), u16(y), u16(cell.x), u16(cell.y)}, pivot = sheet.pivot})
				}
			}
		}
		for r in sheet.rects {
			append(&frames, format.Sprite_Frame_Contents{name = r.name, rect = {u16(r.rect.x), u16(r.rect.y), u16(r.rect.z), u16(r.rect.w)}, pivot = sheet.pivot})
		}
		good := true
		for f in frames {
			if int(f.rect.x) + int(f.rect.z) > image.width || int(f.rect.y) + int(f.rect.w) > image.height {
				report_error(problems, a.path, 0, 0, "the frame %q reaches outside %s, which is %d by %d texels", f.name, assets[texture].name, image.width, image.height)
				good = false
			}
		}
		if !good {
			return .Failed
		}
	}
	if len(frames) > format.MAX_SPRITE_FRAMES {
		report_error(problems, a.path, 0, 0, "has %d frames, and a sheet has at most %d", len(frames), format.MAX_SPRITE_FRAMES)
		return .Failed
	}
	names := make(map[string]int, len(frames), context.temp_allocator)
	for f, i in frames {
		if f.name in names {
			report_error(problems, a.path, 0, 0, "has the frame %q twice", f.name)
			return .Failed
		}
		names[f.name] = i
	}
	good := true
	for animation in sheet.animations {
		for other in animations {
			if other.name == animation.name {
				report_error(problems, a.path, animation.line, 0, "has the animation %q twice", animation.name)
				good = false
			}
		}
		indices := make([dynamic]u16, context.temp_allocator)
		for token in animation.frames {
			if i, named := names[token]; named {
				append(&indices, u16(i))
				continue
			}
			from, to := token, token
			if dots := strings.index(token, ".."); dots >= 0 {
				from, to = token[:dots], token[dots + 2:]
			}
			first, first_ok := strconv.parse_int(from)
			last, last_ok := strconv.parse_int(to)
			if !first_ok || !last_ok || first < 0 || last < 0 || max(first, last) >= len(frames) {
				report_error(problems, a.path, animation.line, 0, "%q is not a frame's name, nor an index or a range of indices from 0 to %d", token, len(frames) - 1)
				good = false
				continue
			}
			// A range runs either way.
			for i := first; ; i += first <= last ? 1 : -1 {
				append(&indices, u16(i))
				if i == last {
					break
				}
			}
		}
		append(&animations, format.Sprite_Animation_Contents{name = animation.name, frames = indices[:], rate = animation.rate, loop = animation.loop})
	}
	if len(animations) > format.MAX_SPRITE_ANIMATIONS {
		report_error(problems, a.path, 0, 0, "has %d animations, and a sheet has at most %d", len(animations), format.MAX_SPRITE_ANIMATIONS)
		good = false
	}
	if !good {
		return .Failed
	}
	blob := format.sprite_sheet_write(
		{
			guid = guid,
			key = key,
			atlas = atlas_guid,
			atlas_size = atlas_size,
			pixels_per_unit = sheet.pixels_per_unit,
			filter = sheet.filter,
			frames = frames[:],
			animations = animations[:],
			source_path = a.name,
		},
		context.temp_allocator,
	)
	// The atlas goes first, so a sheet's blob never names an atlas that its cook did not write.
	if packed && !write_blob(atlas_output, atlas_blob) {
		return .Failed
	}
	if !write_blob(output, blob) {
		return .Failed
	}
	a.size = atlas_size
	if packed {
		count_subassets(pass, .Texture, .Cooked)
	}
	return .Cooked
}
