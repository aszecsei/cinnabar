package physics

import "core:log"
import "core:math"
import "core:math/linalg"

import core_physics "cinnabar:core/physics"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// MAX_HEIGHT_FIELD_SAMPLES is the most samples that a height field has along a side: a surface finer than that takes
// coarser samples.
MAX_HEIGHT_FIELD_SAMPLES :: 4097

// Texels is one channel of a texture's mip 0, from 0 to 1, row-major with x fastest.
Texels :: struct {
	size:   [2]u32,
	values: []f32,
}

// height_field_shape makes the Height_Field shape of e's Surface_Renderer (see docs/physics/design.md#shapes), at an
// offset and a rotation in its body, with its dimensions scaled. It returns false, with a warning, for a dynamic body,
// or when the entity has no Surface_Renderer or its height map is missing.
@(private)
height_field_shape :: proc(
	s: ^State,
	w: ^ecs.World,
	e: ecs.Entity,
	offset: [3]f32,
	rotation: quaternion128,
	scale: [3]f32,
	dynamic_body: bool,
) -> (
	core_physics.Shape,
	bool,
) {
	if dynamic_body {
		log.warnf(
			"physics: entity %v is dynamic, so its height field collider is left out: a height field has no mass",
			e,
		)
		return {}, false
	}
	sr := ecs.get(w, e, Surface_Renderer)
	if sr == nil {
		log.warnf("physics: entity %v's height field collider has no Surface_Renderer", e)
		return {}, false
	}
	if sr.height_map == {} {
		log.warnf("physics: entity %v's Surface_Renderer has no height_map for its collider", e)
		return {}, false
	}
	height, height_ok := texture_texels(s, sr.height_map)
	if !height_ok {
		log.warnf(
			"physics: entity %v's height map %v is not loaded, or not one channel",
			e,
			sr.height_map,
		)
		return {}, false
	}
	mask, mask_ok := texture_texels(s, sr.hole_mask)
	if sr.hole_mask != {} && !mask_ok {
		log.warnf(
			"physics: entity %v's hole mask %v is not loaded, or not one channel, so its collider has no holes",
			e,
			sr.hole_mask,
		)
	}
	field := height_field(sr^, height, mask, scale, allocator_of(s))
	corner := [3]f32{-sr.size.x * 0.5, 0, -sr.size.y * 0.5} * scale
	desc := core_physics.Height_Field_Desc {
		heights  = raw_data(field.heights),
		count    = field.count,
		spacing  = field.spacing,
		offset   = offset + linalg.quaternion_mul_vector3(rotation, corner),
		rotation = to_rotation(rotation),
	}
	shape := core_physics.Shape(pool_alloc(&s.shapes))
	if !api(s).create_height_field_shape(s.world, shape, &desc) {
		pool_free(&s.shapes, core_physics.Handle(shape))
		return {}, false
	}
	return shape, true
}

// Height_Field is a surface's grid of heights in meters, from its rectangle's least corner, as
// core_physics.Height_Field_Desc takes it.
Height_Field :: struct {
	heights: []f32,
	count:   [2]u32,
	spacing: [2]f32,
}

// height_field samples a surface's height map at the corners of its finest cells, as the vertex shader samples it at
// its finest level: bilinearly, clamped, at mip 0, where uv0 is 0 to 1 across the rectangle. A height is
// height_range.x where the map reads 0 and height_range.y where it reads 1, times scale.y. A sample is a hole when
// the mask reads 0 at each of the four cells around it, or the cell is past the rectangle, so the collision's holes are
// a cell smaller than the drawn ones, and the ground that is drawn always collides. A mask with no values has no holes.
height_field :: proc(
	sr: Surface_Renderer,
	height, mask: Texels,
	scale: [3]f32,
	allocator := context.allocator,
) -> (
	field: Height_Field,
) {
	cell := sr.cell > 0 ? sr.cell : format.DEFAULT_SURFACE_CELL
	size := linalg.max(sr.size, 1e-3)
	cells := [2]u32 {
		u32(clamp(math.ceil(size.x / cell), 1, MAX_HEIGHT_FIELD_SAMPLES - 1)),
		u32(clamp(math.ceil(size.y / cell), 1, MAX_HEIGHT_FIELD_SAMPLES - 1)),
	}
	field.count = cells + 1
	field.spacing = size / [2]f32{f32(cells.x), f32(cells.y)} * [2]f32{abs(scale.x), abs(scale.z)}
	field.heights = make([]f32, int(field.count.x * field.count.y), allocator)
	low, high := sr.height_range.x, sr.height_range.y
	for j in 0 ..< field.count.y {
		for i in 0 ..< field.count.x {
			uv := [2]f32{f32(i) / f32(cells.x), f32(j) / f32(cells.y)}
			h := low + sample_bilinear(height, uv) * (high - low)
			field.heights[j * field.count.x + i] = h * scale.y
		}
	}
	if len(mask.values) == 0 {
		return
	}
	solid :: proc(mask: Texels, cells: [2]u32, ci, cj: i64) -> bool {
		if ci < 0 || cj < 0 || ci >= i64(cells.x) || cj >= i64(cells.y) {
			return false
		}
		uv := [2]f32{(f32(ci) + 0.5) / f32(cells.x), (f32(cj) + 0.5) / f32(cells.y)}
		return sample_nearest(mask, uv) > 0
	}
	for j in 0 ..< i64(field.count.y) {
		for i in 0 ..< i64(field.count.x) {
			if !solid(mask, cells, i - 1, j - 1) &&
			   !solid(mask, cells, i, j - 1) &&
			   !solid(mask, cells, i - 1, j) &&
			   !solid(mask, cells, i, j) {
				field.heights[j * i64(field.count.x) + i] = core_physics.HEIGHT_FIELD_HOLE
			}
		}
	}
	return
}

// sample_bilinear reads texels at uv as a linear, clamped sampler does.
@(private)
sample_bilinear :: proc(t: Texels, uv: [2]f32) -> f32 {
	p := uv * [2]f32{f32(t.size.x), f32(t.size.y)} - 0.5
	base := linalg.floor(p)
	f := p - base
	at :: proc(t: Texels, x, y: i64) -> f32 {
		cx := clamp(x, 0, i64(t.size.x) - 1)
		cy := clamp(y, 0, i64(t.size.y) - 1)
		return t.values[cy * i64(t.size.x) + cx]
	}
	x, y := i64(base.x), i64(base.y)
	top := math.lerp(at(t, x, y), at(t, x + 1, y), f.x)
	bottom := math.lerp(at(t, x, y + 1), at(t, x + 1, y + 1), f.x)
	return math.lerp(top, bottom, f.y)
}

// sample_nearest reads the texel at uv, as a Load of floor(uv * size) does.
@(private)
sample_nearest :: proc(t: Texels, uv: [2]f32) -> f32 {
	x := clamp(i64(uv.x * f32(t.size.x)), 0, i64(t.size.x) - 1)
	y := clamp(i64(uv.y * f32(t.size.y)), 0, i64(t.size.y) - 1)
	return t.values[y * i64(t.size.x) + x]
}

// texture_texels is a 2D texture asset's mip 0, its first channel, which it loads if it is not loaded: R16_Unorm,
// RGBA8_Unorm's red or BC4_Unorm, a height or a mask texture. It fails for another format.
@(private)
texture_texels :: proc(s: ^State, guid: format.Guid) -> (t: Texels, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data := asset.data(s.assets, h) or_return
	blob := format.texture_view(data) or_return
	if blob.dimension != .D2 {
		return
	}
	mip := data[blob.mips.offset:][:format.texture_mip_size(blob.format, blob.size.x, blob.size.y)]
	values := format.texture_channel(blob.format, blob.size, mip, allocator_of(s)) or_return
	return {blob.size, values}, true
}
