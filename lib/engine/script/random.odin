package script

import "core:c"
import "core:math"
import "core:time"

import "cinnabar:core/luau"
import "cinnabar:engine/random"

// Random_State is the world's generator for scripts (see docs/scripting/api.md#random): the engine's generator,
// which lives in the Runtime, so a code reload keeps it.
Random_State :: random.State

// Seeds that scripts give and get are integers that a Luau number holds exactly.
@(private = "file")
SEED_LIMIT :: f64(1 << 53)

// seed_random makes seed the world's seed and starts its sequence, as Random.seed does. Seeds beyond ±2^53 work, but
// Random.get_seed cannot give them exactly.
seed_random :: proc(r: ^Runtime, seed: u64) {
	r.random_seed = seed
	restart_random(r)
}

// restart_random starts the world's seed's sequence again. The editor calls it when Play starts from Edit, so each
// Play draws the same numbers.
restart_random :: proc(r: ^Runtime) {
	random.seed(&r.random, r.random_seed)
}

// clock_seed is the seed that init gives a world, as Unity seeds from the clock: different on each run, and below
// 2^53, so Random.get_seed gives it exactly.
@(private)
clock_seed :: proc() -> u64 {
	x := u64(time.time_to_unix_nano(time.now()))
	return random.splitmix64(&x) & (1 << 53 - 1)
}

// check_whole is argument n, which must be an integer that a Luau number holds exactly.
@(private = "file")
check_whole :: proc(L: ^luau.State, n: c.int, what: string) -> i64 {
	v := luau.L_checknumber(L, n)
	if v != math.trunc(v) || !(abs(v) <= SEED_LIMIT) {
		raise(L, what)
	}
	return i64(v)
}

// register_random defines Random. Every member is a function, so the library is not a mutable global.
@(private)
register_random :: proc(r: ^Runtime) {
	define(r, "Random.value", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, random.float64(&runtime_of(L).random))
		return 1
	})
	define(r, "Random.range", proc(L: ^luau.State) -> c.int {
		lo, hi := luau.L_checknumber(L, 1), luau.L_checknumber(L, 2)
		luau.pushnumber(L, lo + (hi - lo) * random.float64(&runtime_of(L).random))
		return 1
	})
	define(r, "Random.integer", proc(L: ^luau.State) -> c.int {
		lo := check_whole(L, 1, "Random.integer: min must be an integer")
		hi := check_whole(L, 2, "Random.integer: max must be an integer")
		if hi < lo {
			raise(L, "Random.integer: max is less than min")
		}
		luau.pushnumber(L, f64(lo + i64(random.below(&runtime_of(L).random, u64(hi - lo) + 1))))
		return 1
	})
	define(r, "Random.seed", proc(L: ^luau.State) -> c.int {
		seed_random(runtime_of(L), u64(check_whole(L, 1, "Random.seed: the seed must be an integer from -2^53 to 2^53")))
		return 0
	})
	define(r, "Random.get_seed", proc(L: ^luau.State) -> c.int {
		luau.pushnumber(L, f64(i64(runtime_of(L).random_seed)))
		return 1
	})
	define(r, "Random.inside_unit_sphere", proc(L: ^luau.State) -> c.int {
		g := &runtime_of(L).random
		for {
			p := [3]f64{2 * random.float64(g) - 1, 2 * random.float64(g) - 1, 2 * random.float64(g) - 1}
			if p.x * p.x + p.y * p.y + p.z * p.z <= 1 {
				push_vector(L, [3]f32{f32(p.x), f32(p.y), f32(p.z)})
				return 1
			}
		}
	})
	define(r, "Random.on_unit_sphere", proc(L: ^luau.State) -> c.int {
		// A uniform height and angle give a uniform point on the sphere (Archimedes).
		g := &runtime_of(L).random
		z := 2 * random.float64(g) - 1
		angle := math.TAU * random.float64(g)
		ring := math.sqrt(1 - z * z)
		push_vector(L, [3]f32{f32(ring * math.cos(angle)), f32(ring * math.sin(angle)), f32(z)})
		return 1
	})
	define(r, "Random.inside_unit_circle", proc(L: ^luau.State) -> c.int {
		g := &runtime_of(L).random
		for {
			x, y := 2 * random.float64(g) - 1, 2 * random.float64(g) - 1
			if x * x + y * y <= 1 {
				push_vector(L, [3]f32{f32(x), f32(y), 0})
				return 1
			}
		}
	})
	define(r, "Random.rotation", proc(L: ^luau.State) -> c.int {
		// A uniform rotation from three uniform numbers (Shoemake 1992).
		g := &runtime_of(L).random
		u1, u2, u3 := random.float64(g), math.TAU * random.float64(g), math.TAU * random.float64(g)
		a, b := math.sqrt(1 - u1), math.sqrt(u1)
		push_quaternion(L, quaternion(x = f32(a * math.sin(u2)), y = f32(a * math.cos(u2)), z = f32(b * math.sin(u3)), w = f32(b * math.cos(u3))))
		return 1
	})
}
