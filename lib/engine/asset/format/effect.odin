package asset_format

import "core:mem"

import "cinnabar:core/layout"

EFFECT_EXTENSION :: ".effect"

// An effect's curves are baked to this many evenly spaced samples over a particle's life, from its birth to its death.
EFFECT_CURVE_SAMPLES :: 64
// An emitter has at most this many modules.
MAX_EFFECT_MODULES :: 8
// An effect has at most this many emitters.
MAX_EFFECT_EMITTERS :: 8
// An emitter holds at most this many particles at once, and a ribbon emitter this many, which one group of the ribbons'
// build pass takes.
MAX_EMITTER_CAPACITY :: 65536
MAX_RIBBON_CAPACITY :: 1024

// Effect_Render is what an emitter's particles draw as: each a sprite, or together a ribbon through them in the order
// that they spawned, with a material of geometry = ribbon (see docs/rendering/particles.md#ribbons).
Effect_Render :: enum u32 {
	Sprite,
	Ribbon,
}

// Effect_Shape is where an emitter's particles start, in the emitter's space, and which way they leave: from a point
// or a sphere, outward in every direction; from a box, along +y; from a cone's base, within its angle of +y.
Effect_Shape :: enum u32 {
	Point,
	Sphere,
	Box,
	Cone,
}

// Effect_Curve is one of an emitter's curves over a particle's life, each a row of EFFECT_CURVE_SAMPLES samples:
// the color and opacity, the size in x (half a side, in meters), and the emission in rgb.
Effect_Curve :: enum u32 {
	Color,
	Size,
	Emission,
}

// Effect_Module_Kind is what a module does to a particle each step, with its values:
//   Gravity: adds an acceleration, xyz in meters per second squared, in the world.
//   Drag: slows the velocity by x per second, exponentially.
//   Noise: adds a divergence-free swirl of strength x, in meters per second squared, whose features are 1 / y meters.
//   Collide: bounces off the depth that the camera saw last frame, keeping x of the speed into the surface and 1 - y of
//   the speed along it.
Effect_Module_Kind :: enum u32 {
	Gravity,
	Drag,
	Noise,
	Collide,
}

Effect_Module :: struct {
	kind:    Effect_Module_Kind,
	padding: [3]u32,
	values:  [4]f32,
}

// Effect_Emitter is one emitter of an effect blob. Ranges are [low, high], from which each particle picks at random.
Effect_Emitter :: struct {
	name:          Slice,
	// The most particles alive at once.
	capacity:      u32,
	// Particles a second, and a burst of count at the start and then every burst_interval seconds, or once when it is 0.
	rate:          f32,
	burst:         u32,
	burst_interval: f32,
	lifetime:      [2]f32,
	speed:         [2]f32,
	// The turn of each sprite, in radians per second.
	spin:          [2]f32,
	shape:         Effect_Shape,
	// A sphere's radius in x; a box's half extents; a cone's base radius in x and its angle from +y in y, in radians.
	shape_size:    [3]f32,
	render:        Effect_Render,
	// A ribbon's material, or the engine's default ribbon material when zero.
	material:      Guid,
	texture:       Guid,
	// The texture's frames, columns by rows, which play at flipbook_rate frames a second; 1 by 1 is no flipbook.
	flipbook:      [2]u32,
	flipbook_rate: f32,
	softness:      f32,
	// Effect_Module records, in the order that they act.
	modules:       Slice,
	// The first of the emitter's rows in the blob's curves, one for each Effect_Curve.
	curves:        u32,
	padding:       u32,
}

// Effect_Blob is the start of an effect blob (see docs/content/kinds/effects.md#effects).
Effect_Blob :: struct {
	header:      Blob_Header,
	// Effect_Emitter records.
	emitters:    Slice,
	// Rows of EFFECT_CURVE_SAMPLES [4]f32 samples.
	curves:      Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/effects/smoke.effect".
	source_path: Slice,
}

Effect_Curve_Row :: [EFFECT_CURVE_SAMPLES][4]f32

effect_layout :: proc() -> u64 {
	return layout.hash(Effect_Blob) ~ layout.hash(Effect_Emitter) * 31 ~ layout.hash(Effect_Module) * 961
}

// effect_view checks an effect blob: its header, its layout, and that its slices and records are inside it.
effect_view :: proc(data: []byte) -> (blob: ^Effect_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Effect || header.layout != effect_layout() || len(data) < size_of(Effect_Blob) {
		return
	}
	blob = (^Effect_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.emitters, size_of(Effect_Emitter), align_of(Effect_Emitter)) ||
	   !inside(data, blob.curves, size_of(Effect_Curve_Row), align_of(Effect_Curve_Row)) ||
	   !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	rows := u32(len(effect_curves(data, blob)))
	for e in effect_emitters(data, blob) {
		if !inside(data, e.name, 1, 1) || !inside(data, e.modules, size_of(Effect_Module), align_of(Effect_Module)) {
			return nil, false
		}
		if e.curves + len(Effect_Curve) > rows || e.capacity == 0 || e.capacity > MAX_EMITTER_CAPACITY {
			return nil, false
		}
		if e.render == .Ribbon && e.capacity > MAX_RIBBON_CAPACITY {
			return nil, false
		}
	}
	return blob, true
}

effect_emitters :: proc "contextless" (data: []byte, blob: ^Effect_Blob) -> []Effect_Emitter {
	bytes := blob_bytes(data, blob.emitters)
	return ([^]Effect_Emitter)(raw_data(bytes))[:len(bytes) / size_of(Effect_Emitter)]
}

effect_modules :: proc "contextless" (data: []byte, e: Effect_Emitter) -> []Effect_Module {
	bytes := blob_bytes(data, e.modules)
	return ([^]Effect_Module)(raw_data(bytes))[:len(bytes) / size_of(Effect_Module)]
}

effect_curves :: proc "contextless" (data: []byte, blob: ^Effect_Blob) -> []Effect_Curve_Row {
	bytes := blob_bytes(data, blob.curves)
	return ([^]Effect_Curve_Row)(raw_data(bytes))[:len(bytes) / size_of(Effect_Curve_Row)]
}

// Effect_Emitter_Contents is an emitter as effect_write takes it: its record, whose name, modules and curves come from
// the other fields.
Effect_Emitter_Contents :: struct {
	emitter: Effect_Emitter,
	name:    string,
	modules: []Effect_Module,
	curves:  [Effect_Curve]Effect_Curve_Row,
}

Effect_Contents :: struct {
	guid:        Guid,
	key:         u64,
	emitters:    []Effect_Emitter_Contents,
	source_path: string,
}

// effect_write builds an effect blob.
effect_write :: proc(contents: Effect_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Effect_Blob), allocator)
	emitters := reserve_bytes(&buffer, len(contents.emitters) * size_of(Effect_Emitter), align_of(Effect_Emitter))
	curves := reserve_bytes(&buffer, len(contents.emitters) * len(Effect_Curve) * size_of(Effect_Curve_Row), BLOB_ALIGN)
	for e, i in contents.emitters {
		record := e.emitter
		record.name = append_bytes(&buffer, transmute([]byte)e.name)
		record.modules = reserve_bytes(&buffer, len(e.modules) * size_of(Effect_Module), align_of(Effect_Module))
		if len(e.modules) > 0 {
			mem.copy(&buffer[record.modules.offset], raw_data(e.modules), len(e.modules) * size_of(Effect_Module))
		}
		record.curves = u32(i * len(Effect_Curve))
		for curve in Effect_Curve {
			row := e.curves[curve]
			offset := curves.offset + (record.curves + u32(curve)) * size_of(Effect_Curve_Row)
			mem.copy(&buffer[offset], &row, size_of(row))
		}
		mem.copy(&buffer[emitters.offset + u32(i * size_of(Effect_Emitter))], &record, size_of(record))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Effect_Blob {
		header = {magic = BLOB_MAGIC, kind = .Effect, layout = effect_layout(), key = contents.key, guid = contents.guid},
		emitters = emitters,
		curves = curves,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
