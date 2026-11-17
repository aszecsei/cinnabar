package asset_format

import "core:math"
import "core:mem"

import "cinnabar:core/layout"

// A world is a .world text file: the scenes that stream in and out as the camera moves, each with its bounds and its
// load and unload distances, or the mark that it is always loaded (see docs/content/kinds/worlds.md).
WORLD_EXTENSION :: ".world"

// A world has at most this many scenes.
MAX_WORLD_SCENES :: 1024
// A scene that gives no unload_distance unloads at its load_distance times this.
DEFAULT_UNLOAD_FACTOR :: 1.25

// A World_Position unit is 2^-24 m, and each raw axis value is at most WORLD_POSITION_LIMIT. These are
// ecs.POSITION_FRACTION_BITS and ecs.POSITION_LIMIT, which the cooker cannot import: the ecs package needs the
// platform backends.
WORLD_POSITION_FRACTION_BITS :: 24
WORLD_POSITION_LIMIT :: i64(1) << 62 - 1

// world_raw_from_meters is a coordinate in meters as World_Position units, rounded to the nearest unit. Scaling by a
// power of two is exact, so the result is as exact as the f64 that holds the meters. ok is false for a coordinate
// outside the bounds of a World_Position, and for NaN.
world_raw_from_meters :: proc "contextless" (meters: f64) -> (raw: i64, ok: bool) {
	scaled := math.round(meters * f64(i64(1) << WORLD_POSITION_FRACTION_BITS))
	if !(abs(scaled) <= f64(WORLD_POSITION_LIMIT)) {
		return 0, false
	}
	return i64(scaled), true
}

World_Scene_Flag :: enum u32 {
	// The scene is loaded with the world and never unloads. Its bounds and distances are zero.
	Persistent,
}
World_Scene_Flags :: bit_set[World_Scene_Flag;u32]

// World_Scene_Record is a scene of a world. min and max are the corners of its bounds in World_Position units (2^-24 m,
// see lib/engine/ecs/position.odin). The distances are in meters from the bounds: the scene loads when the camera is
// within load_distance of them, and unloads when it is farther than unload_distance.
World_Scene_Record :: struct {
	guid:            Guid,
	min:             [3]i64,
	max:             [3]i64,
	load_distance:   f32,
	unload_distance: f32,
	flags:           World_Scene_Flags,
	reserved:        u32,
}
#assert(size_of(World_Scene_Record) == 80)

// World_Blob is the start of a world blob (see docs/content/blobs-and-loading.md#blob-format).
World_Blob :: struct {
	header:      Blob_Header,
	// World_Scene_Record records, in the order of the text.
	scenes:      Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/levels/town.world".
	source_path: Slice,
}
#assert(size_of(World_Blob) % align_of(World_Scene_Record) == 0)

world_layout :: proc() -> u64 {
	return layout.hash(World_Blob) ~ layout.hash(World_Scene_Record) * 31
}

// world_view checks a world blob: its header, its layout, and that its slices are inside it.
world_view :: proc(data: []byte) -> (blob: ^World_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .World ||
	   header.layout != world_layout() ||
	   len(data) < size_of(World_Blob) {
		return
	}
	blob = (^World_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return(
			u64(s.offset) + u64(s.size) <= u64(len(data)) &&
			int(s.size) % size == 0 &&
			int(s.offset) % align == 0 \
		)
	}
	if !inside(data, blob.scenes, size_of(World_Scene_Record), align_of(World_Scene_Record)) ||
	   !inside(data, blob.source_path, 1, 1) ||
	   int(blob.scenes.size) / size_of(World_Scene_Record) > MAX_WORLD_SCENES {
		return nil, false
	}
	return blob, true
}

world_scenes :: proc "contextless" (data: []byte, blob: ^World_Blob) -> []World_Scene_Record {
	bytes := blob_bytes(data, blob.scenes)
	return ([^]World_Scene_Record)(raw_data(bytes))[:len(bytes) / size_of(World_Scene_Record)]
}

World_Contents :: struct {
	guid:        Guid,
	key:         u64,
	scenes:      []World_Scene_Record,
	source_path: string,
}

// world_write builds a world blob.
world_write :: proc(contents: World_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(World_Blob), allocator)
	scenes := reserve_bytes(
		&buffer,
		len(contents.scenes) * size_of(World_Scene_Record),
		align_of(World_Scene_Record),
	)
	if len(contents.scenes) > 0 {
		mem.copy(
			&buffer[scenes.offset],
			raw_data(contents.scenes),
			len(contents.scenes) * size_of(World_Scene_Record),
		)
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := World_Blob {
		header = {
			magic = BLOB_MAGIC,
			kind = .World,
			layout = world_layout(),
			key = contents.key,
			guid = contents.guid,
		},
		scenes = scenes,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
