// Thumbnails (see docs/content/daemon-and-operations.md#thumbnails): the picture that the content browser shows of an asset,
// in <cache>/thumbnails, named by the asset's GUID and a key of what it shows, so a changed asset has a new file and a
// reader never sees half of one. The daemon decides which file each asset should have and removes the others. It makes
// a texture's and a sound's itself, from what it has already cooked. A material's, a mesh's and a prefab's need the
// renderer, so the editor asks the host for those, and the index says that they are not ready until it has.
package cook

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"
import stbi "vendor:stb/image"

// Change it to make every thumbnail again.
THUMBNAIL_VERSION :: 1
// A thumbnail's longer side, in pixels.
THUMBNAIL_SIZE :: 256
THUMBNAILS_DIR :: "thumbnails"
// The color of a sound's waveform.
WAVEFORM_COLOR :: [4]u8{0x7f, 0xd4, 0xc8, 0xff}

// Thumbnail_Keys finds what a thumbnail shows, and remembers it, as materials share textures and prefabs share meshes.
@(private)
Thumbnail_Keys :: struct {
	// The sources that depend on other assets, by GUID. A stage's meshes and textures are in no source: their blobs say all.
	sources:  map[string]^Asset_Source,
	blob_key: proc(data: rawptr, guid: string) -> u64,
	data:     rawptr,
	memo:     map[string]u64,
	blobs:    map[string]u64,
}

// thumbnail_blob is an asset's blob's key, read once in a pass, or 0 for one with no blob. A pass reads every one, and a
// daemon's pass should be short.
@(private)
thumbnail_blob :: proc(k: ^Thumbnail_Keys, guid: string) -> u64 {
	if known, found := k.blobs[guid]; found {
		return known
	}
	key := k.blob_key(k.data, guid)
	k.blobs[guid] = key
	return key
}

// thumbnail_key covers what a thumbnail shows: the asset's blob, and the blobs of what it draws with, through what those
// draw with. A material's dependencies are its textures, its parent, its functions and its shading model. A prefab's
// are what its flat entities name, since its dependencies are only its scripts and its prefabs.
@(private)
thumbnail_key :: proc(k: ^Thumbnail_Keys, guid: string) -> u64 {
	if known, found := k.memo[guid]; found {
		return known
	}
	// What refers to itself counts once.
	k.memo[guid] = 0
	value := u64(THUMBNAIL_VERSION)
	key := hash.fnv64a(([^]byte)(&value)[:size_of(value)])
	blob := thumbnail_blob(k, guid)
	key = hash.fnv64a(([^]byte)(&blob)[:size_of(blob)], key)
	if s, found := k.sources[guid]; found {
		list := s.kind == .Prefab || s.kind == .Scene ? s.visual[:] : s.dependencies[:]
		names := make([]string, len(list), context.temp_allocator)
		for d, i in list {
			buffer: [32]u8
			names[i] = strings.clone(format.guid_format(d, &buffer), context.temp_allocator)
		}
		slice.sort(names)
		for name in names {
			dependency := thumbnail_key(k, name)
			key = hash.fnv64a(([^]byte)(&dependency)[:size_of(dependency)], key)
		}
	}
	k.memo[guid] = key
	return key
}

// thumbnail_kind is whether a kind has a thumbnail.
@(private)
thumbnail_kind :: proc(kind: cook_link.Asset_Kind) -> bool {
	#partial switch kind {
	case .Texture, .Audio, .Material, .Material_Instance, .Mesh, .Prefab:
		return true
	}
	return false
}

// thumbnails_update gives each asset in the index its thumbnail's path, removes the files that no asset wants, and makes
// the textures' and the sounds' that are missing.
thumbnails_update :: proc(index: ^Index, pass: Pass, options: Cook_Options) {
	allocator := virtual.arena_allocator(&index.arena)
	dir := fmt.tprintf("%s/%s", config_dir(options), THUMBNAILS_DIR)
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		log.warnf("cook: cannot make %s: %v", dir, err)
		return
	}
	sources := make(map[string]^Asset_Source, len(pass.assets), context.temp_allocator)
	for &a in pass.assets {
		buffer: [32]u8
		sources[strings.clone(format.guid_format(a.meta.guid, &buffer), context.temp_allocator)] = &a
	}
	settled := options
	keys := Thumbnail_Keys {
		sources = sources,
		data = &settled,
		blob_key = proc(data: rawptr, guid: string) -> u64 {
			return blob_header_key(fmt.tprintf("%s/%s.blob", config_dir((^Cook_Options)(data)^), guid))
		},
		memo = make(map[string]u64, len(index.assets), context.temp_allocator),
		blobs = make(map[string]u64, len(index.assets), context.temp_allocator),
	}
	present := make(map[string]bool, context.temp_allocator)
	if infos, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for info in infos {
			present[info.name] = true
		}
	}
	wanted := make(map[string]bool, len(index.assets), context.temp_allocator)
	pending := make([dynamic]Thumbnail_Job, context.temp_allocator)
	for guid, &entry in index.assets {
		if !thumbnail_kind(entry.kind) || thumbnail_blob(&keys, guid) == 0 {
			continue
		}
		name := fmt.tprintf("%s.%16x", guid, thumbnail_key(&keys, guid))
		wanted[name] = true
		file := fmt.tprintf("%s.png", name)
		entry.thumbnail = strings.clone(fmt.tprintf("%s/%s", dir, file), allocator)
		entry.thumbnail_ready = present[file]
		if !entry.thumbnail_ready && (entry.kind == .Texture || entry.kind == .Audio) {
			append(&pending, Thumbnail_Job{guid = guid, kind = entry.kind, output = entry.thumbnail, source = sources[guid] or_else nil, blob = fmt.tprintf("%s/%s.blob", config_dir(options), guid)})
		}
	}
	// A file goes when nothing wants its GUID and key, whatever comes after them, as a part of a prefab's picture.
	for name in present {
		parts := strings.split_n(name, ".", 3, context.temp_allocator)
		if len(parts) < 3 || fmt.tprintf("%s.%s", parts[0], parts[1]) not_in wanted {
			if err := os.remove(fmt.tprintf("%s/%s", dir, name)); err != nil && err != .Not_Exist {
				log.warnf("cook: cannot delete %s/%s: %v", dir, name, err)
			}
		}
	}
	parallel_for(len(pending), &pending, proc(data: rawptr, i: int) {
		jobs := (^[dynamic]Thumbnail_Job)(data)
		jobs[i].ok = thumbnail_make(jobs[i])
	})
	for job in pending {
		if job.ok {
			if entry, found := &index.assets[job.guid]; found {
				entry.thumbnail_ready = true
			}
		}
	}
}

@(private = "file")
Thumbnail_Job :: struct {
	guid:   string,
	kind:   cook_link.Asset_Kind,
	output: string,
	blob:   string,
	source: ^Asset_Source,
	ok:     bool,
}

@(private = "file")
thumbnail_make :: proc(job: Thumbnail_Job) -> bool {
	pixels: []u8
	size: [2]int
	ok: bool
	if job.kind == .Texture {
		data, err := os.read_entire_file(job.blob, context.temp_allocator)
		if err != nil {
			return false
		}
		pixels, size, ok = texture_thumbnail(data, context.temp_allocator)
	} else if job.source != nil {
		samples, channels, decoded := decode_sound(job.source.source, audio_setting(job.source^, "channels"))
		defer delete(samples)
		if decoded {
			pixels, size, ok = waveform_thumbnail(samples[:], int(channels), context.temp_allocator)
		}
	}
	if !ok {
		log.warnf("cook: cannot make the thumbnail of %s", job.guid)
		return false
	}
	return write_blob(job.output, png_encode(pixels, size, context.temp_allocator))
}

// blob_header_key is the key in a blob's header, or 0 for a blob that is missing or is not one.
@(private = "file")
blob_header_key :: proc(path: string) -> u64 {
	f, err := os.open(path)
	if err != nil {
		return 0
	}
	defer os.close(f)
	header: format.Blob_Header
	n, read_err := os.read(f, ([^]byte)(&header)[:size_of(header)])
	if read_err != nil || n < size_of(header) || header.magic != format.BLOB_MAGIC {
		return 0
	}
	return header.key
}

// texture_thumbnail is a picture of a texture blob's first layer, RGBA8, at most THUMBNAIL_SIZE on its longer side, from
// its smallest mip that is at least that large. Color keeps its sRGB bytes, a mask is gray, a normal map shows its
// normals, and HDR is tone mapped.
@(private)
texture_thumbnail :: proc(data: []byte, allocator: runtime.Allocator) -> (pixels: []u8, size: [2]int, ok: bool) {
	blob := format.texture_view(data) or_return
	mips := format.blob_bytes(data, blob.mips)
	offset := 0
	mip := u32(0)
	for mip + 1 < blob.mip_count && max(max(blob.size.x >> (mip + 1), 1), max(blob.size.y >> (mip + 1), 1)) >= THUMBNAIL_SIZE {
		offset += format.texture_mip_size(blob.format, max(blob.size.x >> mip, 1), max(blob.size.y >> mip, 1))
		mip += 1
	}
	width, height := max(blob.size.x >> mip, 1), max(blob.size.y >> mip, 1)
	decoded := make([]u8, int(width) * int(height) * 4, context.temp_allocator)
	texels := mips[offset:]
	compressed: Compressed_Format
	switch blob.format {
	case .RGBA8_Unorm:
		copy(decoded, texels)
	case .BC1_Unorm, .BC1_Unorm_Srgb:
		compressed = .BC1
	case .BC4_Unorm:
		compressed = .BC4
	case .BC5_Unorm:
		compressed = .BC5
	case .BC6H_Ufloat:
		compressed = .BC6H
	case .BC7_Unorm, .BC7_Unorm_Srgb:
		compressed = .BC7
	}
	if compressed == .BC6H {
		// Half floats, RGBA.
		halves := make([]u8, int(width) * int(height) * 8, context.temp_allocator)
		if cn_decompress(.BC6H, raw_data(texels), c.uint(width), c.uint(height), raw_data(halves)) != 0 {
			return
		}
		for i in 0 ..< int(width) * int(height) {
			for channel in 0 ..< 3 {
				value, _ := endian.get_f16(halves[i * 8 + channel * 2:], .Little)
				linear := max(f32(value), 0)
				decoded[i * 4 + channel] = srgb_byte(linear / (1 + linear))
			}
			decoded[i * 4 + 3] = 255
		}
	} else if compressed != {} {
		if cn_decompress(compressed, raw_data(texels), c.uint(width), c.uint(height), raw_data(decoded)) != 0 {
			return
		}
	}
	#partial switch blob.format {
	case .BC4_Unorm:
		for i in 0 ..< int(width) * int(height) {
			decoded[i * 4 + 1], decoded[i * 4 + 2], decoded[i * 4 + 3] = decoded[i * 4], decoded[i * 4], 255
		}
	case .BC5_Unorm:
		for i in 0 ..< int(width) * int(height) {
			x, y := f32(decoded[i * 4]) / 255 * 2 - 1, f32(decoded[i * 4 + 1]) / 255 * 2 - 1
			z := math.sqrt(max(1 - x * x - y * y, 0))
			decoded[i * 4 + 2], decoded[i * 4 + 3] = u8((z * 0.5 + 0.5) * 255), 255
		}
	}
	pixels, size = fit_thumbnail(decoded, {int(width), int(height)}, allocator)
	return pixels, size, true
}

// fit_thumbnail is RGBA8 pixels with their longer side at most THUMBNAIL_SIZE: each new pixel is the average of the old
// ones that it covers.
@(private)
fit_thumbnail :: proc(pixels: []u8, size: [2]int, allocator: runtime.Allocator) -> (fitted: []u8, fitted_size: [2]int) {
	longest := max(size.x, size.y)
	if longest <= THUMBNAIL_SIZE {
		return slice.clone(pixels, allocator), size
	}
	fitted_size = {max(size.x * THUMBNAIL_SIZE / longest, 1), max(size.y * THUMBNAIL_SIZE / longest, 1)}
	fitted = make([]u8, fitted_size.x * fitted_size.y * 4, allocator)
	for y in 0 ..< fitted_size.y {
		y0, y1 := y * size.y / fitted_size.y, max((y + 1) * size.y / fitted_size.y, y * size.y / fitted_size.y + 1)
		for x in 0 ..< fitted_size.x {
			x0, x1 := x * size.x / fitted_size.x, max((x + 1) * size.x / fitted_size.x, x * size.x / fitted_size.x + 1)
			sum: [4]int
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					at := (sy * size.x + sx) * 4
					for channel in 0 ..< 4 {
						sum[channel] += int(pixels[at + channel])
					}
				}
			}
			count := (y1 - y0) * (x1 - x0)
			at := (y * fitted_size.x + x) * 4
			for channel in 0 ..< 4 {
				fitted[at + channel] = u8(sum[channel] / count)
			}
		}
	}
	return
}

// waveform_thumbnail is a picture of a sound, RGBA8 on nothing: for each column, the lowest and highest sample of any
// channel in that part of the sound.
@(private)
waveform_thumbnail :: proc(samples: []i16, channels: int, allocator: runtime.Allocator) -> (pixels: []u8, size: [2]int, ok: bool) {
	if channels <= 0 {
		return
	}
	size = {THUMBNAIL_SIZE, THUMBNAIL_SIZE / 2}
	pixels = make([]u8, size.x * size.y * 4, allocator)
	frames := len(samples) / channels
	for x in 0 ..< size.x {
		low, high := i16(0), i16(0)
		first, last := x * frames / size.x, (x + 1) * frames / size.x
		for frame in first ..< max(last, first + 1) {
			if frame >= frames {
				break
			}
			for channel in 0 ..< channels {
				sample := samples[frame * channels + channel]
				low, high = min(low, sample), max(high, sample)
			}
		}
		middle := f32(size.y - 1) / 2
		top := int(middle - f32(high) / 32768 * middle)
		bottom := int(math.ceil(middle - f32(low) / 32768 * middle))
		for y in clamp(top, 0, size.y - 1) ..= clamp(bottom, 0, size.y - 1) {
			at := (y * size.x + x) * 4
			pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = WAVEFORM_COLOR.r, WAVEFORM_COLOR.g, WAVEFORM_COLOR.b, WAVEFORM_COLOR.a
		}
	}
	return pixels, size, true
}

@(private = "file")
srgb_byte :: proc(linear: f32) -> u8 {
	encoded := linear <= 0.0031308 ? linear * 12.92 : 1.055 * math.pow(linear, 1 / f32(2.4)) - 0.055
	return u8(clamp(encoded, 0, 1) * 255 + 0.5)
}

// png_encode is RGBA8 pixels as a PNG file.
@(private)
png_encode :: proc(pixels: []u8, size: [2]int, allocator: runtime.Allocator) -> []byte {
	Sink :: struct {
		out:     [dynamic]byte,
		context_: runtime.Context,
	}
	sink := Sink{make([dynamic]byte, allocator), context}
	stbi.write_png_to_func(proc "c" (data: rawptr, bytes: rawptr, count: c.int) {
		sink := (^Sink)(data)
		context = sink.context_
		append(&sink.out, ..([^]byte)(bytes)[:count])
	}, &sink, c.int(size.x), c.int(size.y), 4, raw_data(pixels), c.int(size.x * 4))
	return sink.out[:]
}
