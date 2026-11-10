package asset_format

import "core:math"
import "core:mem"

import "cinnabar:core/layout"

// A sprite sheet's source: a text file that names its images, or a texture with its frames (see
// docs/content/kinds/sprite-sheets.md#sprite-sheets).
SPRITE_SHEET_EXTENSION :: ".sprite_sheet"

// The name of a packed sheet's atlas, its Texture sub-asset, in its .meta file: texture.atlas.
SPRITE_SHEET_ATLAS_NAME :: "atlas"

// A sheet has at most this many frames and animations, so a Sprite_Renderer names one in 16 bits.
MAX_SPRITE_FRAMES :: 65535
MAX_SPRITE_ANIMATIONS :: 65534

// Sprite_Filter is how a sheet's texture is sampled: Nearest keeps pixel art's texels sharp.
Sprite_Filter :: enum u32 {
	Linear,
	Nearest,
}

// Sprite_Frame is one image of a sheet.
Sprite_Frame :: struct {
	// Its rectangle in the atlas, in texels from the top left: x, y, width and height.
	rect:     [4]u16,
	// The point of the frame that is at its entity's position, as a share of its width and height from its bottom
	// left: {0.5, 0.5} is its middle.
	pivot:    [2]f32,
	// How long an animation shows it, in seconds. 0 takes the animation's rate.
	duration: f32,
	name:     Slice,
}

// Sprite_Animation is frames of a sheet in order, which a Sprite_Renderer plays by name.
Sprite_Animation :: struct {
	name:  Slice,
	// Its range of the blob's frame indices.
	first: u32,
	count: u32,
	// Frames a second, for the frames that have no duration of their own.
	rate:  f32,
	// Whether it starts again after its last frame, or stays on it.
	loop:  b32,
}

// Sprite_Sheet_Blob is the start of a sprite sheet blob (see docs/content/kinds/sprite-sheets.md#the-blob).
Sprite_Sheet_Blob :: struct {
	header:          Blob_Header,
	// The texture that holds the frames: the sheet's own Texture sub-asset when the cooker packed it, or the texture
	// that the sheet names.
	atlas:           Guid,
	// The size that the frames' rectangles are in: the atlas's source image's. The texture may cook smaller.
	atlas_size:      [2]u32,
	// The atlas's texels to a meter.
	pixels_per_unit: f32,
	filter:          Sprite_Filter,
	// Sprite_Frame records.
	frames:          Slice,
	// Sprite_Animation records.
	animations:      Slice,
	// The animations' frames: u16 indices of frames.
	frame_indices:   Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/sprites/hero.sprite_sheet".
	source_path:     Slice,
}

sprite_sheet_layout :: proc() -> u64 {
	return layout.hash(Sprite_Sheet_Blob) ~ layout.hash(Sprite_Frame) * 31 ~ layout.hash(Sprite_Animation) * 131
}

// sprite_sheet_view checks a sprite sheet blob: its header, its layout, that its slices are inside it, that each frame
// is inside the atlas, and that each animation's frames are frames of the sheet.
sprite_sheet_view :: proc(data: []byte) -> (blob: ^Sprite_Sheet_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Sprite_Sheet || header.layout != sprite_sheet_layout() || len(data) < size_of(Sprite_Sheet_Blob) {
		return
	}
	blob = (^Sprite_Sheet_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.frames, size_of(Sprite_Frame), align_of(Sprite_Frame)) ||
	   !inside(data, blob.animations, size_of(Sprite_Animation), align_of(Sprite_Animation)) ||
	   !inside(data, blob.frame_indices, size_of(u16), align_of(u16)) ||
	   !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	if blob.pixels_per_unit <= 0 || blob.atlas_size.x == 0 || blob.atlas_size.y == 0 {
		return nil, false
	}
	frames := sprite_sheet_frames(data, blob)
	animations := sprite_sheet_animations(data, blob)
	indices := sprite_sheet_frame_indices(data, blob)
	if len(frames) > MAX_SPRITE_FRAMES || len(animations) > MAX_SPRITE_ANIMATIONS {
		return nil, false
	}
	for f in frames {
		if u32(f.rect.x) + u32(f.rect.z) > blob.atlas_size.x || u32(f.rect.y) + u32(f.rect.w) > blob.atlas_size.y || f.duration < 0 || !inside(data, f.name, 1, 1) {
			return nil, false
		}
	}
	for a in animations {
		if u64(a.first) + u64(a.count) > u64(len(indices)) || a.count == 0 || a.rate < 0 || !inside(data, a.name, 1, 1) {
			return nil, false
		}
	}
	for i in indices {
		if int(i) >= len(frames) {
			return nil, false
		}
	}
	return blob, true
}

sprite_sheet_frames :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob) -> []Sprite_Frame {
	bytes := blob_bytes(data, blob.frames)
	return ([^]Sprite_Frame)(raw_data(bytes))[:len(bytes) / size_of(Sprite_Frame)]
}

sprite_sheet_animations :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob) -> []Sprite_Animation {
	bytes := blob_bytes(data, blob.animations)
	return ([^]Sprite_Animation)(raw_data(bytes))[:len(bytes) / size_of(Sprite_Animation)]
}

sprite_sheet_frame_indices :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob) -> []u16 {
	bytes := blob_bytes(data, blob.frame_indices)
	return ([^]u16)(raw_data(bytes))[:len(bytes) / size_of(u16)]
}

// sprite_sheet_find_frame is the index of the frame of a name.
sprite_sheet_find_frame :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob, name: string) -> (index: int, ok: bool) {
	for f, i in sprite_sheet_frames(data, blob) {
		if string(blob_bytes(data, f.name)) == name {
			return i, true
		}
	}
	return
}

// sprite_sheet_find_animation is the index of the animation of a name.
sprite_sheet_find_animation :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob, name: string) -> (index: int, ok: bool) {
	for a, i in sprite_sheet_animations(data, blob) {
		if string(blob_bytes(data, a.name)) == name {
			return i, true
		}
	}
	return
}

// sprite_sheet_frame_at is the frame that an animation shows at a time in seconds from its start, and whether the
// animation is over: one that does not loop stays on its last frame. Each frame shows for its own duration, or for a
// share of a second by the animation's rate. An animation whose frames have no time shows its first.
sprite_sheet_frame_at :: proc "contextless" (data: []byte, blob: ^Sprite_Sheet_Blob, animation: int, time: f32) -> (frame: int, over: bool) {
	animations := sprite_sheet_animations(data, blob)
	if animation < 0 || animation >= len(animations) {
		return 0, true
	}
	a := animations[animation]
	frames := sprite_sheet_frames(data, blob)
	indices := sprite_sheet_frame_indices(data, blob)[a.first:][:a.count]
	step: f32 = a.rate > 0 ? 1 / a.rate : 0
	total: f32
	for i in indices {
		d := frames[i].duration
		total += d > 0 ? d : step
	}
	if total <= 0 {
		return int(indices[0]), true
	}
	t := max(time, 0)
	if t >= total {
		if !a.loop {
			return int(indices[len(indices) - 1]), true
		}
		t = math.mod(t, total)
	}
	for i in indices {
		d := frames[i].duration
		d = d > 0 ? d : step
		if t < d {
			return int(i), false
		}
		t -= d
	}
	return int(indices[len(indices) - 1]), false
}

// Sprite_Frame_Contents is a frame for sprite_sheet_write.
Sprite_Frame_Contents :: struct {
	name:     string,
	rect:     [4]u16,
	pivot:    [2]f32,
	duration: f32,
}

// Sprite_Animation_Contents is an animation for sprite_sheet_write: its frames are indices of the sheet's frames.
Sprite_Animation_Contents :: struct {
	name:   string,
	frames: []u16,
	rate:   f32,
	loop:   bool,
}

Sprite_Sheet_Contents :: struct {
	guid:            Guid,
	key:             u64,
	atlas:           Guid,
	atlas_size:      [2]u32,
	pixels_per_unit: f32,
	filter:          Sprite_Filter,
	frames:          []Sprite_Frame_Contents,
	animations:      []Sprite_Animation_Contents,
	source_path:     string,
}

// sprite_sheet_write builds a sprite sheet blob.
sprite_sheet_write :: proc(contents: Sprite_Sheet_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Sprite_Sheet_Blob), allocator)
	frames := reserve_bytes(&buffer, len(contents.frames) * size_of(Sprite_Frame), align_of(Sprite_Frame))
	animations := reserve_bytes(&buffer, len(contents.animations) * size_of(Sprite_Animation), align_of(Sprite_Animation))
	index_count := 0
	for a in contents.animations {
		index_count += len(a.frames)
	}
	frame_indices := reserve_bytes(&buffer, index_count * size_of(u16), align_of(u16))
	for f, i in contents.frames {
		name := append_bytes(&buffer, transmute([]byte)f.name)
		record := Sprite_Frame{rect = f.rect, pivot = f.pivot, duration = f.duration, name = name}
		mem.copy(&buffer[int(frames.offset) + i * size_of(Sprite_Frame)], &record, size_of(record))
	}
	first := 0
	for a, i in contents.animations {
		name := append_bytes(&buffer, transmute([]byte)a.name)
		record := Sprite_Animation{name = name, first = u32(first), count = u32(len(a.frames)), rate = a.rate, loop = b32(a.loop)}
		mem.copy(&buffer[int(animations.offset) + i * size_of(Sprite_Animation)], &record, size_of(record))
		if len(a.frames) > 0 {
			mem.copy(&buffer[int(frame_indices.offset) + first * size_of(u16)], raw_data(a.frames), len(a.frames) * size_of(u16))
		}
		first += len(a.frames)
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Sprite_Sheet_Blob {
		header = {magic = BLOB_MAGIC, kind = .Sprite_Sheet, layout = sprite_sheet_layout(), key = contents.key, guid = contents.guid},
		atlas = contents.atlas,
		atlas_size = contents.atlas_size,
		pixels_per_unit = contents.pixels_per_unit,
		filter = contents.filter,
		frames = frames,
		animations = animations,
		frame_indices = frame_indices,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
