package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Each animation of a glTF file is an Animation sub-asset of its model: a clip of keys for the joints of one of its
// skins (see docs/content/kinds/skins-and-animations.md#animations). ANIMATION_KIND names them in .meta files.
ANIMATION_KIND :: "animation"

Animation_Path :: enum u8 {
	// [3]f32 keys.
	Translation,
	// Unit quaternions, x, y, z, w: [4]f32 keys.
	Rotation,
	// [3]f32 keys.
	Scale,
}

Animation_Interpolation :: enum u8 {
	// Each key holds until the next.
	Step,
	// Translations and scales lerp between keys, and rotations slerp.
	Linear,
}

// animation_path_width is how many floats one key of a path has.
animation_path_width :: proc "contextless" (path: Animation_Path) -> u32 {
	return path == .Rotation ? 4 : 3
}

// Animation_Channel is what a clip does to one part of one joint's pose: key_count keys, with their times from
// first_key in the clip's times and their values from first_value in its values. Before the first key the first
// holds, and after the last the last.
Animation_Channel :: struct {
	joint:         u16,
	path:          Animation_Path,
	interpolation: Animation_Interpolation,
	first_key:     u32,
	key_count:     u32,
	first_value:   u32,
}

#assert(size_of(Animation_Channel) == 16)

// Animation_Blob is the start of an animation blob (see docs/content/blobs-and-loading.md#blob-format).
Animation_Blob :: struct {
	header:      Blob_Header,
	// The Skin sub-asset whose joints the channels index, and its count of joints.
	skin:        Guid,
	joint_count: u32,
	// From 0 to the last key, in seconds.
	duration:    f32,
	padding:     [2]u32,
	// Animation_Channel records, by joint and then by path.
	channels:    Slice,
	// f32 seconds, ascending within each channel.
	times:       Slice,
	// f32s, animation_path_width of them per key, in the engine's axes.
	values:      Slice,
	// The animation's name in its model, and the model's path, prefixed with its root's name.
	name:        Slice,
	source_path: Slice,
}

animation_layout :: proc() -> u64 {
	return layout.hash(Animation_Blob) ~ layout.hash(Animation_Channel) * 31
}

// animation_view checks an animation blob: its header, its layout, its slices, and that each channel's joint is one
// of the skin's and its keys are in the blob.
animation_view :: proc(data: []byte) -> (blob: ^Animation_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Animation || header.layout != animation_layout() || len(data) < size_of(Animation_Blob) {
		return
	}
	blob = (^Animation_Blob)(raw_data(data))
	for s in ([?]Slice{blob.channels, blob.times, blob.values, blob.name, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.channels.size % size_of(Animation_Channel) != 0 || blob.channels.offset % align_of(Animation_Channel) != 0 ||
	   blob.times.size % 4 != 0 || blob.times.offset % 4 != 0 || blob.values.size % 4 != 0 || blob.values.offset % 4 != 0 {
		return nil, false
	}
	times := u64(blob.times.size / 4)
	values := u64(blob.values.size / 4)
	for c in animation_channels(data, blob) {
		if u32(c.joint) >= blob.joint_count || c.path > max(Animation_Path) || c.interpolation > max(Animation_Interpolation) ||
		   c.key_count == 0 || u64(c.first_key) + u64(c.key_count) > times ||
		   u64(c.first_value) + u64(c.key_count) * u64(animation_path_width(c.path)) > values {
			return nil, false
		}
	}
	return blob, true
}

animation_channels :: proc "contextless" (data: []byte, blob: ^Animation_Blob) -> []Animation_Channel {
	bytes := blob_bytes(data, blob.channels)
	return ([^]Animation_Channel)(raw_data(bytes))[:len(bytes) / size_of(Animation_Channel)]
}

animation_times :: proc "contextless" (data: []byte, blob: ^Animation_Blob) -> []f32 {
	bytes := blob_bytes(data, blob.times)
	return ([^]f32)(raw_data(bytes))[:len(bytes) / 4]
}

animation_values :: proc "contextless" (data: []byte, blob: ^Animation_Blob) -> []f32 {
	bytes := blob_bytes(data, blob.values)
	return ([^]f32)(raw_data(bytes))[:len(bytes) / 4]
}

// Animation_Contents is what animation_write builds a blob from: channels whose ranges index times and values.
Animation_Contents :: struct {
	guid:        Guid,
	key:         u64,
	skin:        Guid,
	joint_count: u32,
	duration:    f32,
	channels:    []Animation_Channel,
	times:       []f32,
	values:      []f32,
	name:        string,
	source_path: string,
}

// animation_write builds an animation blob.
animation_write :: proc(contents: Animation_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Animation_Blob), allocator)
	stream :: proc(buffer: ^[dynamic]byte, data: []byte) -> Slice {
		s := reserve_bytes(buffer, len(data), BLOB_ALIGN)
		copy(buffer[s.offset:], data)
		return s
	}
	channels := stream(&buffer, mem.slice_to_bytes(contents.channels))
	times := stream(&buffer, mem.slice_to_bytes(contents.times))
	values := stream(&buffer, mem.slice_to_bytes(contents.values))
	name := append_bytes(&buffer, transmute([]byte)contents.name)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Animation_Blob {
		header = {magic = BLOB_MAGIC, kind = .Animation, layout = animation_layout(), key = contents.key, guid = contents.guid},
		skin = contents.skin,
		joint_count = contents.joint_count,
		duration = contents.duration,
		channels = channels,
		times = times,
		values = values,
		name = name,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
