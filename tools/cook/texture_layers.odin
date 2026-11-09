// Where a cube map's or an array's layers come from: one image, by its layout setting, or the images that a .texture_set
// names by GUID. See docs/content/kinds/textures.md#cube-maps-and-arrays.
package cook

import "core:fmt"
import "core:math"
import "core:strings"

import format "cinnabar:engine/asset/format"

// Source_Layout is how one image holds its layers, by its layout setting.
Source_Layout :: enum u8 {
	D2,
	Cube_Cross,
	Cube_Equirect,
	Array_Strip,
}

// A .texture_set's keys for a cube's faces, in the order of its layers.
TEXTURE_SET_FACES := [6]string{"px", "nx", "py", "ny", "pz", "nz"}

// Texture_Set is what a .texture_set names: the indices of its images' assets, one for each layer in order. A texture
// that is not a set has none.
Texture_Set :: struct {
	dimension: format.Texture_Dimension,
	children:  []int,
}

is_texture_set :: proc(a: Asset_Source) -> bool {
	return strings.has_suffix(strings.to_lower(a.path, context.temp_allocator), format.TEXTURE_SET_EXTENSION)
}

// parse_texture_set reads a .texture_set: lines of `px = $guid` for each of a cube's faces, or of `layer = $guid` for
// each of an array's layers in order, and # comments. It adds the images that it finds to named, also when it fails, so
// that a mistake in a set does not also warn of its images. A set's image must be a plain image texture, and one whose
// usage is not the set's is a warning, since the set's is the one that it cooks with.
parse_texture_set :: proc(a: Asset_Source, assets: []Asset_Source, by_guid: map[format.Guid]int, named: ^map[int]bool, problems: ^Problems) -> (set: Texture_Set, ok: bool) {
	meta_path := fmt.tprintf("%s%s", a.path, format.META_EXTENSION)
	ok = true
	if texture_setting(a, "standalone") == "false" {
		report_error(problems, meta_path, 0, 0, "standalone cannot be false for a .texture_set, which has no other way to cook")
		ok = false
	}
	if texture_setting(a, "layout") != "2d" {
		report_error(problems, meta_path, 0, 0, "layout is for one image: a .texture_set's layers are the images that it names")
		ok = false
	}
	usage := texture_setting(a, "usage")
	faces: [6]int
	face_seen: [6]bool
	has_faces := false
	layers := make([dynamic]int, context.temp_allocator)
	text := string(source_of(a))
	line_number := 0
	for raw_line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		equals := strings.index_byte(line, '=')
		if equals < 0 {
			report_error(problems, a.path, line_number, 1, "needs `key = $guid`, where the key is px, nx, py, ny, pz, nz or layer")
			ok = false
			continue
		}
		key := strings.trim_space(line[:equals])
		value := strings.trim_space(line[equals + 1:])
		face := -1
		for name, i in TEXTURE_SET_FACES {
			if key == name {
				face = i
			}
		}
		if face < 0 && key != "layer" {
			report_error(problems, a.path, line_number, 1, "unknown key %q: a set's keys are px, nx, py, ny, pz, nz or layer", key)
			ok = false
			continue
		}
		if face >= 0 {
			if face_seen[face] {
				report_error(problems, a.path, line_number, 1, "has %s twice", key)
				ok = false
				continue
			}
			face_seen[face], has_faces = true, true
		}
		if !strings.has_prefix(value, "$") {
			report_error(problems, a.path, line_number, equals + 2, "an image is a texture asset's GUID after $")
			ok = false
			continue
		}
		guid, guid_ok := format.guid_parse(value[1:])
		if !guid_ok {
			report_error(problems, a.path, line_number, equals + 2, "an image is 32 hex digits after $")
			ok = false
			continue
		}
		child, found := by_guid[guid]
		if !found {
			report_error(problems, a.path, line_number, equals + 2, "no asset has the GUID %s", value)
			ok = false
			continue
		}
		c := assets[child]
		named[child] = true
		switch {
		case c.kind != .Texture || is_texture_set(c):
			report_error(problems, a.path, line_number, equals + 2, "%s is not an image", c.name)
			ok = false
			continue
		case texture_setting(c, "layout") != "2d":
			report_error(problems, a.path, line_number, equals + 2, "%s has a layout of %s, and a set's image is one layer", c.name, texture_setting(c, "layout"))
			ok = false
			continue
		}
		if child_usage := texture_setting(c, "usage"); child_usage != usage {
			report_warning(problems, a.path, line_number, equals + 2, "%s has the usage %s, and this set cooks it as %s", c.name, child_usage, usage)
		}
		if face >= 0 {
			faces[face] = child
		} else {
			append(&layers, child)
		}
	}
	if has_faces && len(layers) > 0 {
		report_error(problems, a.path, 0, 0, "has both a cube's faces and an array's layers")
		ok = false
	}
	if !has_faces && len(layers) == 0 {
		report_error(problems, a.path, 0, 0, "names no images: it needs px, nx, py, ny, pz and nz, or layer lines")
		ok = false
	}
	if len(layers) > format.MAX_TEXTURE_LAYERS {
		report_error(problems, a.path, 0, 0, "has %d layers, and an array has at most %d", len(layers), format.MAX_TEXTURE_LAYERS)
		ok = false
	}
	if !ok {
		return
	}
	if has_faces {
		for seen, i in face_seen {
			if !seen {
				report_error(problems, a.path, 0, 0, "has no %s: a cube names all six faces", TEXTURE_SET_FACES[i])
				ok = false
			}
		}
		if !ok {
			return
		}
		children := make([]int, 6, context.temp_allocator)
		copy(children, faces[:])
		return {.Cube, children}, true
	}
	return {.D2_Array, layers[:]}, true
}

// texture_layers decodes a texture's source into its layers, all of one size, and says what they make.
texture_layers :: proc(a: Asset_Source, assets: []Asset_Source, set: Texture_Set, t: Texture_Cook, problems: ^Problems) -> (layers: []Image, dimension: format.Texture_Dimension, ok: bool) {
	if len(set.children) > 0 {
		layers = make([]Image, len(set.children), context.temp_allocator)
		for child, i in set.children {
			c := assets[child]
			layers[i] = decode_image_bytes(source_of(c), c.path, t, problems) or_return
			if layers[i].width != layers[0].width || layers[i].height != layers[0].height {
				report_error(problems, a.path, 0, 0, "%s is %dx%d, and %s is %dx%d: a set's images are one size", c.name, layers[i].width, layers[i].height, assets[set.children[0]].name, layers[0].width, layers[0].height)
				return
			}
		}
		if set.dimension == .Cube && layers[0].width != layers[0].height {
			report_error(problems, a.path, 0, 0, "a cube's faces are square, and %s is %dx%d", assets[set.children[0]].name, layers[0].width, layers[0].height)
			return
		}
		return layers, set.dimension, true
	}
	image := decode_image_bytes(source_of(a), a.path, t, problems) or_return
	switch t.layout {
	case .D2:
		layers = make([]Image, 1, context.temp_allocator)
		layers[0] = image
		return layers, .D2, true
	case .Cube_Cross:
		layers = cube_from_cross(image)
		if layers == nil {
			report_error(problems, a.path, 0, 0, "a cross is 4 faces across and 3 down, or 3 across and 4 down, of square faces, and this image is %dx%d", image.width, image.height)
			return
		}
		return layers, .Cube, true
	case .Cube_Equirect:
		if image.width != image.height * 2 {
			report_error(problems, a.path, 0, 0, "an equirectangular image is twice as wide as it is tall, and this image is %dx%d", image.width, image.height)
			return
		}
		return cube_from_equirect(image), .Cube, true
	case .Array_Strip:
		layers = array_from_strip(image)
		if layers == nil {
			report_error(problems, a.path, 0, 0, "a strip is square layers one above the other, at most %d, and this image is %dx%d", format.MAX_TEXTURE_LAYERS, image.width, image.height)
			return
		}
		return layers, .D2_Array, true
	}
	return
}

// cube_direction is the direction of a point of a cube's face, as a TextureCube reads it: u and v from -1 to 1, with v
// down the face. It matches cube_direction in sky_texture.hlsli.
cube_direction :: proc(face: int, u, v: f32) -> [3]f32 {
	switch face {
	case 0:
		return {1, -v, -u}
	case 1:
		return {-1, -v, u}
	case 2:
		return {u, 1, v}
	case 3:
		return {u, -1, -v}
	case 4:
		return {u, -v, 1}
	}
	return {-u, -v, -1}
}

// copy_rect copies a rectangle out of an image, turned by half a turn if asked.
@(private = "file")
copy_rect :: proc(image: Image, x, y, width, height: int, half_turn := false) -> Image {
	result := Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
	for row in 0 ..< height {
		for column in 0 ..< width {
			to := half_turn ? (height - 1 - row) * width + (width - 1 - column) : row * width + column
			result.pixels[to] = image.pixels[(y + row) * image.width + x + column]
		}
	}
	return result
}

// cube_from_cross cuts a cross into a cube's faces, or gives nil for an image that is not one. +z is in the middle, with
// -x and +x beside it and +y and -y above and below it, so the faces meet as they do on the cube. -z is right of +x in a
// horizontal cross. In a vertical one it is below -y, which turns it by half a turn.
cube_from_cross :: proc(image: Image) -> []Image {
	faces := make([]Image, 6, context.temp_allocator)
	if image.width * 3 == image.height * 4 && image.width % 4 == 0 {
		size := image.width / 4
		faces[0] = copy_rect(image, size * 2, size, size, size)
		faces[1] = copy_rect(image, 0, size, size, size)
		faces[2] = copy_rect(image, size, 0, size, size)
		faces[3] = copy_rect(image, size, size * 2, size, size)
		faces[4] = copy_rect(image, size, size, size, size)
		faces[5] = copy_rect(image, size * 3, size, size, size)
		return faces
	}
	if image.width * 4 == image.height * 3 && image.width % 3 == 0 {
		size := image.width / 3
		faces[0] = copy_rect(image, size * 2, size, size, size)
		faces[1] = copy_rect(image, 0, size, size, size)
		faces[2] = copy_rect(image, size, 0, size, size)
		faces[3] = copy_rect(image, size, size * 2, size, size)
		faces[4] = copy_rect(image, size, size, size, size)
		faces[5] = copy_rect(image, size, size * 3, size, size, true)
		return faces
	}
	return nil
}

// cube_from_equirect samples a cube's faces, each a quarter of the image's width, from an equirectangular image in the
// Texture sky's mapping (texture_uv in sky_texture.hlsli), so that a sky is the same in either form. It wraps across and
// clamps at the poles.
cube_from_equirect :: proc(image: Image) -> []Image {
	size := max(image.width / 4, 1)
	faces := make([]Image, 6, context.temp_allocator)
	for &face, f in faces {
		face = {size, size, make([][4]f32, size * size, context.temp_allocator)}
		for &p, i in face.pixels {
			u := (f32(i % size) + 0.5) / f32(size) * 2 - 1
			v := (f32(i / size) + 0.5) / f32(size) * 2 - 1
			d := cube_direction(f, u, v)
			length := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			across := 0.5 + math.atan2(d.x, d.z) / (2 * math.PI)
			down := math.acos(clamp(d.y / length, -1, 1)) / math.PI
			p = sample_wrapped(image, across, down)
		}
	}
	return faces
}

// sample_wrapped reads an image bilinearly, wrapping across and clamping down.
@(private = "file")
sample_wrapped :: proc(image: Image, u, v: f32) -> [4]f32 {
	x := u * f32(image.width) - 0.5
	y := v * f32(image.height) - 0.5
	x0, y0 := int(math.floor(x)), int(math.floor(y))
	tx, ty := x - f32(x0), y - f32(y0)
	at :: proc(image: Image, x, y: int) -> [4]f32 {
		wrapped := ((x % image.width) + image.width) % image.width
		return image.pixels[clamp(y, 0, image.height - 1) * image.width + wrapped]
	}
	top := at(image, x0, y0) * (1 - tx) + at(image, x0 + 1, y0) * tx
	bottom := at(image, x0, y0 + 1) * (1 - tx) + at(image, x0 + 1, y0 + 1) * tx
	return top * (1 - ty) + bottom * ty
}

// array_from_strip cuts a vertical strip of square layers into its layers, or gives nil for an image that is not one.
array_from_strip :: proc(image: Image) -> []Image {
	if image.height % image.width != 0 || image.height / image.width > format.MAX_TEXTURE_LAYERS {
		return nil
	}
	layers := make([]Image, image.height / image.width, context.temp_allocator)
	area := image.width * image.width
	for &layer, i in layers {
		layer = {image.width, image.width, image.pixels[i * area:][:area]}
	}
	return layers
}
