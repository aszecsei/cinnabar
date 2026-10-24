package script

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"

// The world is ±2^38 m on each axis (see docs/world.md#positions).
WORLD_LIMIT_METERS :: f64(1 << 38)
// Quaternions compare equal when they are this close, like Unity's ==.
QUATERNION_EQUAL_DOT :: 1 - 1e-6

// register_math defines Quaternion and WorldPosition. Angles are in degrees, as in Unity.
@(private)
register_math :: proc(r: ^Runtime) {
	define(r, "Quaternion.new", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, quaternion(
			x = f32(luau.L_checknumber(L, 1)),
			y = f32(luau.L_checknumber(L, 2)),
			z = f32(luau.L_checknumber(L, 3)),
			w = f32(luau.L_checknumber(L, 4)),
		))
		return 1
	})
	define(r, "Quaternion.euler", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, quaternion_euler(check_vector(L, 1)))
		return 1
	})
	define(r, "Quaternion.angle_axis", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, linalg.quaternion_angle_axis_f32(f32(luau.L_checknumber(L, 1)) * math.RAD_PER_DEG, linalg.normalize0(check_vector(L, 2))))
		return 1
	})
	define(r, "Quaternion.look_rotation", proc(L: ^luau.State) -> c.int {
		up := luau.isnoneornil(L, 2) ? UP : check_vector(L, 2)
		push_quaternion(L, look_rotation(check_vector(L, 1), up))
		return 1
	})
	define(r, "Quaternion.slerp", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, linalg.quaternion_slerp_f32(check_quaternion(L, 1), check_quaternion(L, 2), clamp(f32(luau.L_checknumber(L, 3)), 0, 1)))
		return 1
	})
	define(r, "Quaternion.angle", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(quaternion_angle(check_quaternion(L, 1), check_quaternion(L, 2))))
		return 1
	})
	define(r, "Quaternion.rotate_towards", quaternion_rotate_towards)

	userdata_method(r, .Quaternion, "inverse", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, linalg.quaternion_inverse(check_quaternion(L, 1)))
		return 1
	})
	userdata_method(r, .Quaternion, "normalized", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, linalg.normalize0(check_quaternion(L, 1)))
		return 1
	})
	userdata_method(r, .Quaternion, "euler", proc(L: ^luau.State) -> c.int {
		push_vector(L, euler_of(check_quaternion(L, 1)))
		return 1
	})
	userdata_method(r, .Quaternion, "approx", proc(L: ^luau.State) -> c.int {
		luau.pushboolean(L, b32(quaternion_equal(check_quaternion(L, 1), check_quaternion(L, 2))))
		return 1
	})
	userdata_method(r, .Quaternion, "angle_to", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(quaternion_angle(check_quaternion(L, 1), check_quaternion(L, 2))))
		return 1
	})
	userdata_method(r, .Quaternion, "rotate_towards", quaternion_rotate_towards)
	userdata_method(r, .Quaternion, "slerp", proc(L: ^luau.State) -> c.int {
		push_quaternion(L, linalg.quaternion_slerp_f32(check_quaternion(L, 1), check_quaternion(L, 2), clamp(f32(luau.L_checknumber(L, 3)), 0, 1)))
		return 1
	})

	define(r, "WorldPosition.from_meters", proc(L: ^luau.State) -> c.int {
		meters := [3]f64{luau.L_checknumber(L, 1), luau.L_checknumber(L, 2), luau.L_checknumber(L, 3)}
		for m in meters {
			if !(abs(m) < WORLD_LIMIT_METERS) {
				raise(L, "the position is outside the world")
			}
		}
		push_position(L, ecs.position_from_meters(meters))
		return 1
	})
	define(r, "WorldPosition.lerp", position_lerp)
	userdata_method(r, .World_Position, "lerp", position_lerp)
	userdata_method(r, .World_Position, "to_meters", proc(L: ^luau.State) -> c.int {
		m := ecs.position_to_meters(check_position(L, 1))
		luau.pushnumber(L, m.x)
		luau.pushnumber(L, m.y)
		luau.pushnumber(L, m.z)
		return 3
	})
}

// create_math_values sets the constant values of the math libraries. They never change, so init sets them once.
@(private)
create_math_values :: proc(r: ^Runtime) {
	push_quaternion(r.L, 1)
	set_path(r, "Quaternion.identity")
	push_position(r.L, {})
	set_path(r, "WorldPosition.origin")
}

// The metamethods of Quaternion and WorldPosition. Values of both are immutable, so scripts can share them.

@(private)
quaternion_mul :: proc(L: ^luau.State) -> c.int {
	a := check_quaternion(L, 1)
	if b, ok := to_quaternion(L, 2); ok {
		push_quaternion(L, a * b)
	} else {
		push_vector(L, linalg.quaternion_mul_vector3(a, check_vector(L, 2)))
	}
	return 1
}

@(private)
quaternion_eq :: proc(L: ^luau.State) -> c.int {
	a, a_ok := to_quaternion(L, 1)
	b, b_ok := to_quaternion(L, 2)
	luau.pushboolean(L, b32(a_ok && b_ok && quaternion_equal(a, b)))
	return 1
}

@(private)
quaternion_index :: proc(L: ^luau.State) -> c.int {
	q := check_quaternion(L, 1)
	key, _ := key_atom(L, 2)
	switch key {
	case "x":
		luau.pushnumber(L, f64(imag(q)))
	case "y":
		luau.pushnumber(L, f64(jmag(q)))
	case "z":
		luau.pushnumber(L, f64(kmag(q)))
	case "w":
		luau.pushnumber(L, f64(real(q)))
	case:
		raise(L, fmt.aprintf("Quaternion has no field %s", key, allocator = frame(runtime_of(L))))
	}
	return 1
}

@(private)
quaternion_tostring :: proc(L: ^luau.State) -> c.int {
	q := check_quaternion(L, 1)
	luau.pushodinstring(L, fmt.aprintf("Quaternion(%g, %g, %g, %g)", imag(q), jmag(q), kmag(q), real(q), allocator = frame(runtime_of(L))))
	return 1
}

// position_add gives WorldPosition + vector, in either order.
@(private)
position_add :: proc(L: ^luau.State) -> c.int {
	if p, ok := to_position(L, 1); ok {
		push_position(L, offset_checked(L, p, check_vector(L, 2)))
	} else {
		push_position(L, offset_checked(L, check_position(L, 2), check_vector(L, 1)))
	}
	return 1
}

// position_sub gives a vector for WorldPosition - WorldPosition, and a WorldPosition for WorldPosition - vector.
@(private)
position_sub :: proc(L: ^luau.State) -> c.int {
	a := check_position(L, 1)
	if b, ok := to_position(L, 2); ok {
		push_vector(L, ecs.position_sub(a, b))
	} else {
		push_position(L, offset_checked(L, a, -check_vector(L, 2)))
	}
	return 1
}

@(private)
position_eq :: proc(L: ^luau.State) -> c.int {
	a, a_ok := to_position(L, 1)
	b, b_ok := to_position(L, 2)
	luau.pushboolean(L, b32(a_ok && b_ok && a == b))
	return 1
}

@(private)
position_tostring :: proc(L: ^luau.State) -> c.int {
	m := ecs.position_to_meters(check_position(L, 1))
	luau.pushodinstring(L, fmt.aprintf("WorldPosition(%.3f, %.3f, %.3f)", m.x, m.y, m.z, allocator = frame(runtime_of(L))))
	return 1
}

@(private = "file")
position_lerp :: proc(L: ^luau.State) -> c.int {
	push_position(L, ecs.position_lerp(check_position(L, 1), check_position(L, 2), clamp(f32(luau.L_checknumber(L, 3)), 0, 1)))
	return 1
}

// offset_checked is ecs.position_offset with a script error instead of an assertion for a delta that is not finite
// or leaves the world.
@(private = "file")
offset_checked :: proc(L: ^luau.State, p: ecs.World_Position, delta: [3]f32) -> ecs.World_Position {
	for i in 0 ..< 3 {
		target := f64(p.raw[i]) + f64(delta[i]) * (1 << ecs.POSITION_FRACTION_BITS)
		if !(abs(target) < f64(ecs.POSITION_LIMIT)) {
			raise(L, "the position is outside the world")
		}
	}
	return ecs.position_offset(p, delta)
}

@(private = "file")
quaternion_rotate_towards :: proc(L: ^luau.State) -> c.int {
	from, to := check_quaternion(L, 1), check_quaternion(L, 2)
	max_degrees := f32(luau.L_checknumber(L, 3))
	angle := quaternion_angle(from, to)
	if angle <= max_degrees || angle == 0 {
		push_quaternion(L, to)
	} else {
		push_quaternion(L, linalg.quaternion_slerp_f32(from, to, max_degrees / angle))
	}
	return 1
}

quaternion_equal :: proc "contextless" (a, b: quaternion128) -> bool {
	return abs(linalg.dot(a, b)) > QUATERNION_EQUAL_DOT
}

// quaternion_angle is the angle between two rotations, in degrees.
quaternion_angle :: proc "contextless" (a, b: quaternion128) -> f32 {
	d := min(abs(linalg.dot(a, b)), 1)
	return d > QUATERNION_EQUAL_DOT ? 0 : 2 * math.acos(d) * math.DEG_PER_RAD
}

// quaternion_euler makes a rotation from Euler angles in degrees, in Unity's order: z, then x, then y.
quaternion_euler :: proc "contextless" (degrees: [3]f32) -> quaternion128 {
	r := degrees * math.RAD_PER_DEG
	qx := linalg.quaternion_angle_axis_f32(r.x, RIGHT)
	qy := linalg.quaternion_angle_axis_f32(r.y, UP)
	qz := linalg.quaternion_angle_axis_f32(r.z, FORWARD)
	return qy * qx * qz
}

// euler_of inverts quaternion_euler. Each angle is in (-180, 180], and x is in [-90, 90].
euler_of :: proc "contextless" (q: quaternion128) -> [3]f32 {
	m := linalg.matrix3_from_quaternion_f32(q)
	// For Ry * Rx * Rz, m[1, 2] = -sin(x).
	sx := clamp(-m[1, 2], -1, 1)
	x := math.asin(sx)
	y, z: f32
	if abs(sx) < 0.99999 {
		y = math.atan2(m[0, 2], m[2, 2])
		z = math.atan2(m[1, 0], m[1, 1])
	} else {
		// Gimbal lock: only y + z or y - z is known, so z is 0.
		y = math.atan2(-m[2, 0], m[0, 0])
	}
	return [3]f32{x, y, z} * math.DEG_PER_RAD
}

// look_rotation turns +Z toward forward, with +Y as close to up as it can be.
look_rotation :: proc "contextless" (forward, up: [3]f32) -> quaternion128 {
	z := linalg.normalize0(forward)
	if z == 0 {
		return 1
	}
	x := linalg.cross(up, z)
	if linalg.length2(x) < 1e-12 {
		// up is parallel to forward, so any perpendicular will do.
		x = linalg.cross(abs(z.y) < 0.9 ? UP : RIGHT, z)
	}
	x = linalg.normalize(x)
	y := linalg.cross(z, x)
	return linalg.normalize(linalg.quaternion_from_matrix3_f32(matrix[3, 3]f32{
		x.x, y.x, z.x,
		x.y, y.y, z.y,
		x.z, y.z, z.z,
	}))
}
