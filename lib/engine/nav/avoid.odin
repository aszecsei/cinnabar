package nav

import "core:math"

// Avoidance (see docs/ai/navigation.md#avoidance): an agent picks its velocity by sampling around the one that its path
// asks for, as DetourObstacleAvoidance's adaptive sampling does, and scores each sample by how far it is from the
// desired and the current velocities, which side of the others it passes on, and how soon it would hit another agent
// or a wall. Everything is on the xz plane, in meters and meters per second, relative to the agent.

// The weights of a sample's penalty, and the time ahead that collisions count in, as DetourCrowd's defaults for its
// high quality.
@(private)
Avoid_Params :: struct {
	velocity_bias:  f32,
	weight_desired: f32,
	weight_current: f32,
	weight_side:    f32,
	weight_impact:  f32,
	horizon:        f32,
	divisions:      int,
	rings:          int,
	depth:          int,
}

@(private)
AVOID_PARAMS :: Avoid_Params {
	velocity_bias  = 0.5,
	weight_desired = 2.0,
	weight_current = 0.75,
	weight_side    = 0.75,
	weight_impact  = 2.5,
	horizon        = 2.5,
	divisions      = 7,
	rings          = 2,
	depth          = 5,
}

// Circle is another agent to avoid: where it is relative to the agent, its radius, its velocity and the one that it
// wanted, and the agent's share of the avoidance: 0.5 for an agent of its own priority, which avoids it too, and 1
// for one of a higher priority, which does not.
@(private)
Circle :: struct {
	position: [2]f32,
	radius:   f32,
	velocity: [2]f32,
	desired:  [2]f32,
	share:    f32,
	// The direction to it, and its side's normal, for the side penalty.
	dp, np:   [2]f32,
}

// Wall is a segment to avoid, relative to the agent, and whether the agent already touches it.
@(private)
Wall :: struct {
	a, b:  [2]f32,
	touch: bool,
}

@(private = "file")
dot :: proc "contextless" (a, b: [2]f32) -> f32 {
	return a.x * b.x + a.y * b.y
}

// perp is the 2D cross product of DetourObstacleAvoidance's vperp2D, with y as its z.
@(private = "file")
perp :: proc "contextless" (u, v: [2]f32) -> f32 {
	return u.y * v.x - u.x * v.y
}

@(private = "file")
length :: proc "contextless" (v: [2]f32) -> f32 {
	return math.sqrt(dot(v, v))
}

// prepare_circles fills in the side terms of the circles, as dtObstacleAvoidanceQuery::prepare.
@(private)
prepare_circles :: proc(circles: []Circle, desired: [2]f32) {
	for &c in circles {
		dp := c.position
		if l := length(dp); l > 0.0001 {
			dp /= l
		}
		dv := c.desired - desired
		// dtTriArea2D of the origin, dp and dv.
		if dv.x * dp.y - dp.x * dv.y < 0.01 {
			c.np = {-dp.y, dp.x}
		} else {
			c.np = {dp.y, -dp.x}
		}
		c.dp = dp
	}
}

// sweep_circles is when a circle at the origin moving at v hits a still one, as dtSweepCircleCircle.
@(private = "file")
sweep_circles :: proc "contextless" (radius: f32, v: [2]f32, center: [2]f32, other: f32) -> (tmin, tmax: f32, hit: bool) {
	EPS :: 0.0001
	r := radius + other
	c := dot(center, center) - r * r
	a := dot(v, v)
	if a < EPS {
		return
	}
	b := dot(v, center)
	d := b * b - a * c
	if d < 0 {
		return
	}
	inv := 1 / a
	rd := math.sqrt(d)
	return (b - rd) * inv, (b + rd) * inv, true
}

// ray_segment is when a ray from the origin along u hits segment ab, as dtIsectRaySeg.
@(private = "file")
ray_segment :: proc "contextless" (u, a, b: [2]f32) -> (t: f32, hit: bool) {
	v := b - a
	w := -a
	d := perp(u, v)
	if abs(d) < 1e-6 {
		return
	}
	d = 1 / d
	t = perp(v, w) * d
	if t < 0 || t > 1 {
		return
	}
	s := perp(u, w) * d
	if s < 0 || s > 1 {
		return
	}
	return t, true
}

// sample_penalty is a sample's penalty, as dtObstacleAvoidanceQuery::processSample. It stops early once the sample
// cannot beat the best so far.
@(private = "file")
sample_penalty :: proc(p: Avoid_Params, candidate, velocity, desired: [2]f32, radius, max_speed: f32, circles: []Circle, walls: []Wall, best: f32) -> f32 {
	inv_speed := 1 / max_speed
	inv_horizon := 1 / p.horizon
	desired_penalty := p.weight_desired * (length(candidate - desired) * inv_speed)
	current_penalty := p.weight_current * (length(candidate - velocity) * inv_speed)
	threshold := (p.weight_impact / max(best - desired_penalty - current_penalty, 1e-6) - 0.1) * p.horizon
	if threshold - p.horizon > -math.F32_EPSILON {
		return best
	}
	impact := p.horizon
	side: f32
	sides := 0
	for c in circles {
		// The velocity that the agent's share makes relative to the other's: twice its own less both current ones for a
		// half share, as DetourCrowd's reciprocal avoidance, and its own less the other's for all of it.
		relative := (candidate - (1 - c.share) * velocity) / c.share - c.velocity
		side += clamp(min(dot(c.dp, relative) * 0.5 + 0.5, dot(c.np, relative) * 2), 0, 1)
		sides += 1
		tmin, tmax, hit := sweep_circles(radius, relative, c.position, c.radius)
		if !hit {
			continue
		}
		// Already overlapping: the sooner it gets out, the better.
		if tmin < 0 && tmax > 0 {
			tmin = -tmin * 0.5
		}
		if tmin >= 0 && tmin < impact {
			impact = tmin
			if impact < threshold {
				return best
			}
		}
	}
	for w in walls {
		t: f32
		if w.touch {
			// Touching a wall, only a move away from it counts.
			s := w.b - w.a
			normal := [2]f32{-s.y, s.x}
			if dot(normal, candidate) < 0 {
				continue
			}
		} else {
			hit: bool
			t, hit = ray_segment(candidate, w.a, w.b)
			if !hit {
				continue
			}
		}
		// Walls are avoided less than agents, as they do not move.
		t *= 2
		if t < impact {
			impact = t
			if impact < threshold {
				return best
			}
		}
	}
	if sides > 0 {
		side /= f32(sides)
	}
	side_penalty := p.weight_side * side
	impact_penalty := p.weight_impact * (1 / (0.1 + impact * inv_horizon))
	return desired_penalty + current_penalty + side_penalty + impact_penalty
}

// choose_velocity is the velocity of the best sample around desired, as dtObstacleAvoidanceQuery::
// sampleVelocityAdaptive: a pattern of rings around the desired direction, at a scale that halves at each level of
// depth, around the best sample of the level before.
@(private)
choose_velocity :: proc(p: Avoid_Params, velocity, desired: [2]f32, radius, max_speed: f32, circles: []Circle, walls: []Wall) -> [2]f32 {
	if max_speed <= 0 {
		return {}
	}
	MAX_PATTERN :: 1 + 2 * 32 * 4
	pattern: [MAX_PATTERN][2]f32
	count := 0
	divisions := clamp(p.divisions, 1, 32)
	rings := clamp(p.rings, 1, 4)
	angle := 1 / f32(divisions) * math.PI * 2
	ca, sa := math.cos(angle), math.sin(angle)
	direction: [2][2]f32
	direction[0] = desired
	if l := length(desired); l > 0.0001 {
		direction[0] /= l
	} else {
		direction[0] = {1, 0}
	}
	half_c, half_s := math.cos(angle * 0.5), math.sin(angle * 0.5)
	direction[1] = {direction[0].x * half_c - direction[0].y * half_s, direction[0].x * half_s + direction[0].y * half_c}
	pattern[0] = {}
	count = 1
	for j in 0 ..< rings {
		r := f32(rings - j) / f32(rings)
		first := direction[j % 2] * r
		pattern[count] = first
		count += 1
		right, left := first, first
		for i := 1; i < divisions - 1; i += 2 {
			right = {right.x * ca + right.y * sa, -right.x * sa + right.y * ca}
			left = {left.x * ca - left.y * sa, left.x * sa + left.y * ca}
			pattern[count] = right
			pattern[count + 1] = left
			count += 2
		}
		if divisions & 1 == 0 {
			pattern[count] = {left.x * ca - left.y * sa, left.x * sa + left.y * ca}
			count += 1
		}
	}
	scale := max_speed * (1 - p.velocity_bias)
	result := desired * p.velocity_bias
	for _ in 0 ..< max(p.depth, 1) {
		best := max(f32)
		chosen := [2]f32{}
		for k in 0 ..< count {
			candidate := result + pattern[k] * scale
			if dot(candidate, candidate) > (max_speed + 0.001) * (max_speed + 0.001) {
				continue
			}
			penalty := sample_penalty(p, candidate, velocity, desired, radius, max_speed, circles, walls, best)
			if penalty < best {
				best, chosen = penalty, candidate
			}
		}
		result = chosen
		scale *= 0.5
	}
	return result
}
