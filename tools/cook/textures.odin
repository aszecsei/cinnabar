// Textures are .png, .jpg, .tga, .hdr, .tif and .exr files. The cooker decodes them, sizes them, makes their mips in
// floating point, and block-compresses each mip by its usage with Compressonator (see compressonator.odin). See
// docs/content/kinds/textures.md#textures.
package cook

import "core:c"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import stbi "vendor:stb/image"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks textures changes this, which invalidates every cooked texture.
TEXTURE_COOK_VERSION :: "textures 1"
TEXTURE_EXTENSIONS :: []string{".png", ".jpg", ".jpeg", ".tga", ".hdr", ".tif", ".tiff", ".exr"}
// Compressonator's quality, from 0 to 1. Development cooks fast, and release cooks well.
DEV_TEXTURE_QUALITY :: 0.05
RELEASE_TEXTURE_QUALITY :: 0.5
// The resampling filter's radius in its own texels, and the Kaiser window's shape.
FILTER_RADIUS :: 3.0
KAISER_BETA :: 4.0

TEXTURE_SETTINGS := []Setting_Info {
	{
		key = "usage",
		values = {"color", "normal", "mask", "hdr", "data"},
		default = "color",
		description = "What the texture holds, which picks its format: color is BC7 in sRGB, normal is BC5, mask is BC4 (one channel), hdr is BC6H, and data is RGBA8 without compression.",
	},
	{key = "mips", values = {"true", "false"}, default = "true", description = "Make the full mip chain."},
	{
		key = "max_size",
		values = {"256", "512", "1024", "2048", "4096", "8192", "16384"},
		default = "16384",
		description = "Halve the texture until its larger side fits.",
	},
	{
		key = "wrap",
		values = {"repeat", "clamp"},
		default = "repeat",
		description = "How the mip filter treats the edges. The sampler is the material's choice.",
	},
	{
		key = "filter",
		values = {"kaiser", "box"},
		default = "kaiser",
		description = "The mip filter: a Kaiser-windowed sinc, or the plain average of the covered texels, which keeps a mask's mips as the share of its texels that are set.",
	},
}

// texture_usage_for is the usage that a new texture's .meta file gets, from its name: .hdr and .exr files are hdr, a
// name that ends in _n or _normal is normal, one that ends in _r, _rough, _ao, _m, _metal or _mask is mask, and the
// rest are color.
texture_usage_for :: proc(path: string) -> string {
	name := strings.to_lower(filepath.stem(path), context.temp_allocator)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext == ".hdr" || ext == ".exr" {
		return "hdr"
	}
	for suffix in ([]string{"_n", "_normal"}) {
		if strings.has_suffix(name, suffix) {
			return "normal"
		}
	}
	for suffix in ([]string{"_r", "_rough", "_ao", "_m", "_metal", "_mask", "_height", "_hole"}) {
		if strings.has_suffix(name, suffix) {
			return "mask"
		}
	}
	return "color"
}

// Image is a decoded texture in floating point: linear light for color and hdr, and the stored values otherwise.
Image :: struct {
	width, height: int,
	pixels:        [][4]f32,
}

// cook_textures cooks the textures among the assets whose keys changed, at once (see parallel_for), the largest
// sources first. A texture that fails keeps its old blob. It reports every failure, in the assets' order, and returns
// false if any.
cook_textures :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	ok := true
	textures := assets_of(assets, .Texture)
	if len(textures) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	work := Texture_Work {
		options = options,
		assets  = assets,
		out_dir = out_dir,
		jobs    = make([dynamic]Texture_Job, 0, len(textures), context.temp_allocator),
	}
	for i in textures {
		a := &assets[i]
		if !check_settings(a^, problems) {
			a.failed = true
			ok = false
			continue
		}
		append(&work.jobs, Texture_Job{asset = i, force = pass.force[a.meta.guid], scratch = {problems = {log = problems.log}}})
	}
	Sized :: struct {
		size, job: int,
	}
	by_size := make([]Sized, len(work.jobs), context.temp_allocator)
	for job, i in work.jobs {
		by_size[i] = {len(assets[job.asset].source), i}
	}
	slice.stable_sort_by(by_size, proc(x, y: Sized) -> bool {
		return x.size > y.size
	})
	work.order = make([]int, len(work.jobs), context.temp_allocator)
	for s, i in by_size {
		work.order[i] = s.job
	}
	parallel_for(len(work.jobs), &work, cook_texture_job)
	for &job in work.jobs {
		a := &assets[job.asset]
		a.size = job.size
		if !finish_job(job.result, &job.scratch, .Texture, pass) {
			a.failed = true
			ok = false
		}
	}
	return ok
}

// Texture_Work is the textures that cook_textures cooks: a job for each, in the assets' order, and the order that
// parallel_for takes them in.
@(private = "file")
Texture_Work :: struct {
	options: Cook_Options,
	assets:  []Asset_Source,
	out_dir: string,
	jobs:    [dynamic]Texture_Job,
	order:   []int,
}

// Texture_Job is one texture's cook: its asset's index, whether it cooks also when its blob is up to date, what came
// of it, the size of the blob that the cache ends up with, cooked now or kept, which the index carries, and the
// scratch that holds its problems until finish_job.
@(private = "file")
Texture_Job :: struct {
	asset:   int,
	force:   bool,
	result:  Cook_Result,
	size:    [2]u32,
	scratch: Scratch,
}

@(private = "file")
cook_texture_job :: proc(data: rawptr, index: int) {
	w := (^Texture_Work)(data)
	job := &w.jobs[w.order[index]]
	defer scratch_keep(&job.scratch)
	a := w.assets[job.asset]
	key := texture_key(w.options, a)
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", w.out_dir, format.guid_format(a.meta.guid, &buffer))
	defer job.size = texture_blob_size(output)
	if cooked_key(output, .Texture, format.texture_layout()) == key && !job.force {
		job.result = .Current
		return
	}
	blob, cooked := cook_texture(w.options, a, key, &job.scratch.problems)
	if cooked && write_blob(output, blob) {
		job.result = .Cooked
	}
}

// texture_blob_size is the size of a cooked texture blob, from its header, or zero for a file that is not one.
texture_blob_size :: proc(path: string) -> (size: [2]u32) {
	f, open_err := os.open(path)
	if open_err != nil {
		return
	}
	defer os.close(f)
	blob: format.Texture_Blob
	n, read_err := os.read(f, ([^]byte)(&blob)[:size_of(blob)])
	if read_err != nil || n < size_of(blob) || blob.header.magic != format.BLOB_MAGIC || blob.header.kind != .Texture || blob.header.layout != format.texture_layout() {
		return
	}
	return blob.size
}

// texture_key covers what the blob depends on: the cooker, Compressonator, the configuration, the path, the source and
// the settings.
texture_key :: proc(options: Cook_Options, a: Asset_Source) -> u64 {
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf("%s\x00%s\x00%v\x00%s\x00%x\x00", TEXTURE_COOK_VERSION, COMPRESSONATOR_VERSION, options.config, a.name, format.texture_layout()),
	)
	key = hash.fnv64a(a.source, key)
	return hash.fnv64a(transmute([]byte)a.meta_text, key)
}

// texture_setting is an import setting's value, or its default.
texture_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(TEXTURE_SETTINGS, key)
	return info.default
}

// Texture_Cook is how a texture cooks: what a texture asset's settings say, or what a stage's material asks of a texture
// that it reads (see stages.odin).
Texture_Cook :: struct {
	usage:    format.Texture_Usage,
	// Filter the mips with the edges wrapping, and with a box instead of the Kaiser filter.
	wrap:     bool,
	box:      bool,
	mips:     bool,
	max_size: int,
	// For a mask, the source's channel that it keeps, 0 to 3, in red. 0 keeps red as it is.
	channel:  int,
	// For a mask, decode the source from sRGB first, as a channel of a color texture is.
	srgb:     bool,
	// For a normal map, negate y: one made for the other convention.
	flip_y:   bool,
}

// texture_cook_of is how a texture asset cooks, by its settings.
texture_cook_of :: proc(a: Asset_Source) -> Texture_Cook {
	usage: format.Texture_Usage
	switch texture_setting(a, "usage") {
	case "normal":
		usage = .Normal
	case "mask":
		usage = .Mask
	case "hdr":
		usage = .HDR
	case "data":
		usage = .Data
	case:
		usage = .Color
	}
	return {
		usage = usage,
		wrap = texture_setting(a, "wrap") == "repeat",
		box = texture_setting(a, "filter") == "box",
		mips = texture_setting(a, "mips") == "true",
		max_size = strconv.parse_int(texture_setting(a, "max_size")) or_else 16384,
	}
}

// cook_texture decodes, sizes, filters and compresses one texture, and gives its blob.
cook_texture :: proc(options: Cook_Options, a: Asset_Source, key: u64, problems: ^Problems) -> (blob: []byte, ok: bool) {
	t := texture_cook_of(a)
	image := decode_image_bytes(a.source, a.path, t, problems) or_return
	return cook_texture_image(options, image, t, a.meta.guid, key, a.name, a.path, problems)
}

// cook_texture_image sizes, filters and compresses a decoded texture, and gives its blob. source_path is the name that
// the blob keeps, and path the file that its problems name.
cook_texture_image :: proc(
	options: Cook_Options,
	decoded: Image,
	t: Texture_Cook,
	guid: format.Guid,
	key: u64,
	source_path, path: string,
	problems: ^Problems,
) -> (
	blob: []byte,
	ok: bool,
) {
	usage, wrap, box := t.usage, t.wrap, t.box
	image := decoded
	for max(image.width, image.height) > t.max_size {
		image = resample(image, max(image.width / 2, 1), max(image.height / 2, 1), wrap, box)
	}
	tex_format := texture_format_of(usage)
	// Mip 0 of a block-compressed texture is whole blocks, so a texture that is not is resized up to the next one.
	if format.texture_format_block(tex_format) != 0 && (image.width % 4 != 0 || image.height % 4 != 0) {
		image = resample(image, (image.width + 3) / 4 * 4, (image.height + 3) / 4 * 4, wrap, box)
	}
	if usage == .Normal {
		normalize(&image)
	}

	mip_count := 1
	if t.mips {
		mip_count = int(math.floor(math.log2(f32(max(image.width, image.height))))) + 1
	}
	size := [2]u32{u32(image.width), u32(image.height)}
	mips := make([]byte, format.texture_chain_size(tex_format, size, u32(mip_count)), context.temp_allocator)
	quality: f32 = options.config == .Dev ? DEV_TEXTURE_QUALITY : RELEASE_TEXTURE_QUALITY
	offset := 0
	level := image
	for mip in 0 ..< mip_count {
		if mip > 0 {
			level = resample(level, max(level.width / 2, 1), max(level.height / 2, 1), wrap, box)
			if usage == .Normal {
				normalize(&level)
			}
		}
		mip_size := format.texture_mip_size(tex_format, u32(level.width), u32(level.height))
		if !encode_mip(level, usage, quality, mips[offset:][:mip_size]) {
			report_error(problems, path, 0, 0, "cannot compress mip %d", mip)
			return
		}
		offset += mip_size
	}
	contents := format.Texture_Contents {
		guid        = guid,
		key         = key,
		format      = tex_format,
		usage       = usage,
		size        = size,
		mip_count   = u32(mip_count),
		mips        = mips,
		source_path = source_path,
	}
	return format.texture_write(contents, context.temp_allocator), true
}

texture_format_of :: proc(usage: format.Texture_Usage) -> format.Texture_Format {
	switch usage {
	case .Color:
		return .BC7_Unorm_Srgb
	case .Normal:
		return .BC5_Unorm
	case .Mask:
		return .BC4_Unorm
	case .HDR:
		return .BC6H_Ufloat
	case .Data:
		return .RGBA8_Unorm
	}
	return .RGBA8_Unorm
}

// decode_image_bytes decodes a source into floating point, by its first bytes: OpenEXR, TIFF, Radiance .hdr, or what
// stb_image reads. Color decodes from sRGB into linear light, a normal map maps to -1..1, and a mask keeps its channel
// in red. Float images (.exr, .hdr and a TIFF of floats) are linear already, so they skip the sRGB step.
decode_image_bytes :: proc(source: []byte, path: string, t: Texture_Cook, problems: ^Problems) -> (image: Image, ok: bool) {
	if len(source) == 0 {
		report_error(problems, path, 0, 0, "is empty")
		return
	}
	linear: bool
	switch {
	case len(source) >= 4 && [4]u8{source[0], source[1], source[2], source[3]} == EXR_MAGIC:
		width, height, pixels, err := decode_exr(source)
		if err != "" {
			report_error(problems, path, 0, 0, "cannot decode: %s", err)
			return
		}
		image, linear = {width, height, pixels}, true
	case len(source) >= 4 && (string(source[:4]) == "II*\x00" || string(source[:4]) == "MM\x00*"):
		tiff, err := decode_tiff(source)
		if err != "" {
			report_error(problems, path, 0, 0, "cannot decode: the TIFF %s", err)
			return
		}
		image, linear = {tiff.width, tiff.height, tiff.pixels}, tiff.linear
	case:
		width, height, channels: c.int
		if stbi.is_hdr_from_memory(raw_data(source), c.int(len(source))) != 0 {
			data := stbi.loadf_from_memory(raw_data(source), c.int(len(source)), &width, &height, &channels, 4)
			if data == nil {
				report_error(problems, path, 0, 0, "cannot decode: %s", stbi.failure_reason())
				return
			}
			defer stbi.image_free(data)
			image, linear = {int(width), int(height), make([][4]f32, int(width * height), context.temp_allocator)}, true
			for &p, i in image.pixels {
				p = {data[i * 4], data[i * 4 + 1], data[i * 4 + 2], data[i * 4 + 3]}
			}
		} else {
			data := stbi.load_from_memory(raw_data(source), c.int(len(source)), &width, &height, &channels, 4)
			if data == nil {
				report_error(problems, path, 0, 0, "cannot decode: %s", stbi.failure_reason())
				return
			}
			defer stbi.image_free(data)
			image = {int(width), int(height), make([][4]f32, int(width * height), context.temp_allocator)}
			for &p, i in image.pixels {
				p = {f32(data[i * 4]), f32(data[i * 4 + 1]), f32(data[i * 4 + 2]), f32(data[i * 4 + 3])} / 255
			}
		}
	}
	convert_image(&image, t, linear)
	return image, true
}

// convert_image turns decoded values into what a usage cooks from: color from sRGB into linear light, unless the image
// is linear already, a normal map to -1..1, and a mask's channel into red. An hdr or data texture keeps its values.
convert_image :: proc(image: ^Image, t: Texture_Cook, linear: bool) {
	usage := t.usage
	for &p in image.pixels {
		for ch in 0 ..< 3 {
			switch {
			case (usage == .Color || (usage == .Mask && t.srgb)) && !linear:
				p[ch] = srgb_to_linear(p[ch])
			case usage == .Normal:
				p[ch] = p[ch] * 2 - 1
			}
		}
		if usage == .Mask && t.channel != 0 {
			p.r = p[t.channel]
		}
		if usage == .Normal && t.flip_y {
			p.y = -p.y
		}
	}
}

// image_undecodable gives why the cooker cannot decode an image file, or "" when it can: its extension is not a
// texture's, or it is an OpenEXR image in a compression that TinyEXR does not have, which its header's start says.
image_undecodable :: proc(path: string) -> string {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if !slice.contains(TEXTURE_EXTENSIONS, ext) {
		return "its format"
	}
	if ext != ".exr" {
		return ""
	}
	f, err := os.open(path)
	if err != nil {
		return "it cannot be opened"
	}
	defer os.close(f)
	head := make([]byte, 64 * 1024, context.temp_allocator)
	n, _ := os.read(f, head)
	return exr_undecodable(head[:max(n, 0)])
}

srgb_to_linear :: proc(v: f32) -> f32 {
	return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4)
}

linear_to_srgb :: proc(v: f32) -> f32 {
	return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055
}

// normalize makes each pixel of a normal map unit length again after filtering.
normalize :: proc(image: ^Image) {
	for &p in image.pixels {
		length := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if length > 1e-6 {
			p.xyz /= length
		} else {
			p.xyz = {0, 0, 1}
		}
	}
}

// resample resizes an image with a Kaiser-windowed sinc filter, one axis after the other. When it shrinks, the filter
// widens by the scale, so it averages every source texel that a destination texel covers. wrap repeats the edges
// instead of clamping them. box takes the plain average of the texels that a destination texel covers instead, whose
// weights are never negative, so a mask's mips are the share of its texels that are set (see
// docs/rendering/surfaces.md#holes).
resample :: proc(image: Image, width, height: int, wrap: bool, box := false) -> Image {
	if width == image.width && height == image.height {
		return image
	}
	// Horizontal, then vertical.
	across := Image{width, image.height, make([][4]f32, width * image.height, context.temp_allocator)}
	resample_axis(image.pixels, image.width, image.height, across.pixels, width, true, wrap, box)
	result := Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
	resample_axis(across.pixels, width, image.height, result.pixels, height, false, wrap, box)
	return result
}

// resample_axis resizes along x (horizontal) or y. src is src_width x src_height, and dst has the other axis's size
// unchanged and dst_length along this one.
@(private = "file")
resample_axis :: proc(src: [][4]f32, src_width, src_height: int, dst: [][4]f32, dst_length: int, horizontal, wrap, box: bool) {
	src_length := horizontal ? src_width : src_height
	lines := horizontal ? src_height : src_width
	scale := f32(src_length) / f32(dst_length)
	support := max(scale, 1)
	radius := FILTER_RADIUS * support
	weights := make([dynamic]f32, context.temp_allocator)
	indices := make([dynamic]int, context.temp_allocator)
	for d in 0 ..< dst_length {
		center := (f32(d) + 0.5) * scale - 0.5
		first, last := int(math.floor(center - radius)), int(math.ceil(center + radius))
		if box {
			// The source texels whose middles the destination texel covers.
			first, last = int(math.floor(f32(d) * scale)), max(int(math.ceil(f32(d + 1) * scale)) - 1, int(math.floor(f32(d) * scale)))
		}
		clear(&weights)
		clear(&indices)
		total: f32
		for s in first ..= last {
			x := (f32(s) - center) / support
			w := box ? 1 : kaiser_sinc(x)
			if w == 0 {
				continue
			}
			append(&weights, w)
			append(&indices, edge(s, src_length, wrap))
			total += w
		}
		for line in 0 ..< lines {
			sum: [4]f32
			for w, k in weights {
				i := indices[k]
				sum += src[horizontal ? line * src_width + i : i * src_width + line] * w
			}
			dst[horizontal ? line * dst_length + d : d * src_width + line] = sum / total
		}
	}
}

@(private = "file")
edge :: proc(i, length: int, wrap: bool) -> int {
	if wrap {
		return ((i % length) + length) % length
	}
	return clamp(i, 0, length - 1)
}

// kaiser_sinc is the filter's weight at a distance, in its own texels: a sinc under a Kaiser window of FILTER_RADIUS.
@(private = "file")
kaiser_sinc :: proc(x: f32) -> f32 {
	if abs(x) >= FILTER_RADIUS {
		return 0
	}
	sinc: f32 = 1
	if x != 0 {
		sinc = math.sin(math.PI * x) / (math.PI * x)
	}
	t := x / FILTER_RADIUS
	return sinc * bessel_i0(KAISER_BETA * math.sqrt(1 - t * t)) / bessel_i0(KAISER_BETA)
}

// bessel_i0 is the modified Bessel function of the first kind, of order 0, as a series.
@(private = "file")
bessel_i0 :: proc(x: f32) -> f32 {
	sum, term: f32 = 1, 1
	for k in 1 ..< 20 {
		term *= (x / (2 * f32(k))) * (x / (2 * f32(k)))
		sum += term
	}
	return sum
}

// encode_mip writes one mip in its usage's format into out.
encode_mip :: proc(image: Image, usage: format.Texture_Usage, quality: f32, out: []byte) -> bool {
	count := len(image.pixels)
	unorm :: proc(v: f32) -> u8 {
		return u8(clamp(v, 0, 1) * 255 + 0.5)
	}
	if usage == .HDR {
		halves := make([][4]f16, count, context.temp_allocator)
		for p, i in image.pixels {
			for ch in 0 ..< 4 {
				halves[i][ch] = f16(clamp(p[ch], 0, 65504))
			}
		}
		return cn_compress(.BC6H, quality, false, raw_data(halves), c.uint(image.width), c.uint(image.height), raw_data(out)) == 0
	}
	bytes := make([][4]u8, count, context.temp_allocator)
	for p, i in image.pixels {
		switch usage {
		case .Color:
			bytes[i] = {unorm(linear_to_srgb(p.r)), unorm(linear_to_srgb(p.g)), unorm(linear_to_srgb(p.b)), unorm(p.a)}
		case .Normal:
			bytes[i] = {unorm(p.x * 0.5 + 0.5), unorm(p.y * 0.5 + 0.5), 0, 255}
		case .Mask, .Data, .HDR:
			bytes[i] = {unorm(p.r), unorm(p.g), unorm(p.b), unorm(p.a)}
		}
	}
	compressed: Compressed_Format
	switch usage {
	case .Color:
		compressed = .BC7
	case .Normal:
		compressed = .BC5
	case .Mask:
		compressed = .BC4
	case .Data, .HDR:
		copy(out, ([^]byte)(raw_data(bytes))[:count * 4])
		return true
	}
	return cn_compress(compressed, quality, usage == .Color, raw_data(bytes), c.uint(image.width), c.uint(image.height), raw_data(out)) == 0
}
