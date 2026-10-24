// Package ecs is the native ECS: entities, components, systems and fixed-point positions. See docs/world.md.
package ecs

import "core:math"

// A World_Position unit is 2^-24 m (Q39.24).
POSITION_FRACTION_BITS :: 24
// The bound on each raw axis value. Inside it, the difference of two positions always fits in an i64.
POSITION_LIMIT :: i64(1) << 62 - 1

@(private)
POSITION_SCALE :: f32(1 << POSITION_FRACTION_BITS)

// World_Position is a fixed-point position. It is a struct so that Odin allows no arithmetic on it: subtract two
// positions with position_sub, and add a delta with position_offset. See docs/world.md#positions.
World_Position :: struct {
	raw: [3]i64,
}

// position_sub gives a - b in meters. Each axis converts to f32 once, so the result is correctly rounded.
position_sub :: proc "contextless" (a, b: World_Position) -> [3]f32 {
	d := a.raw - b.raw
	return {f32(d.x), f32(d.y), f32(d.z)} * (1 / POSITION_SCALE)
}

// position_offset adds a delta in meters, rounded to the nearest unit.
position_offset :: proc(p: World_Position, delta: [3]f32) -> World_Position {
	result := p
	for i in 0 ..< 3 {
		// The scale is a power of two, so the product is exact.
		step := math.round(delta[i] * POSITION_SCALE)
		// This also rejects NaN.
		assert(abs(step) < f32(POSITION_LIMIT), "ecs: position delta out of range")
		result.raw[i] += i64(step)
		assert(abs(result.raw[i]) <= POSITION_LIMIT, "ecs: position out of range")
	}
	return result
}

// position_lerp interpolates from a to b. It is exact at t = 0 and t = 1.
position_lerp :: proc(a, b: World_Position, t: f32) -> World_Position {
	if t == 1 {
		return b
	}
	return position_offset(a, position_sub(b, a) * t)
}

// position_from_meters is for authoring and tests. Simulation code moves positions with position_offset.
position_from_meters :: proc(meters: [3]f64) -> World_Position {
	result: World_Position
	for i in 0 ..< 3 {
		raw := math.round(meters[i] * f64(POSITION_SCALE))
		assert(abs(raw) <= f64(POSITION_LIMIT), "ecs: position out of range")
		result.raw[i] = i64(raw)
	}
	return result
}

// position_to_meters is for display. Above 2^29 m from the origin, an f64 cannot hold every position.
position_to_meters :: proc "contextless" (p: World_Position) -> [3]f64 {
	return {f64(p.raw.x), f64(p.raw.y), f64(p.raw.z)} * (1 / f64(POSITION_SCALE))
}
