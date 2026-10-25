// Package debug draws shapes for one frame or for a while: lines, boxes, spheres, arrows and axes, in the world, in
// exact colors over the tone-mapped frame (see docs/rendering.md#debug). Any job can draw. Release builds compile the
// calls out (DEBUG_DRAW).
package debug

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:time"

import "cinnabar:engine/ecs"

// The justfile's release build sets this false, which makes every drawing call do nothing.
DEBUG_DRAW :: #config(DEBUG_DRAW, true)
// At most this many lines are drawn at once. Lines past it are dropped.
MAX_LINES :: 65536
// The segments of a circle.
CIRCLE_SEGMENTS :: 32

Mode :: enum u8 {
	// Tested against the scene's depth: the hidden part draws faintly, so a shape inside a wall still shows.
	Tested,
	// Over everything.
	Overlay,
}

// Line is a line in the world, its linear color, and when it stops drawing.
Line :: struct {
	a, b:    ecs.World_Position,
	color:   [4]f32,
	mode:    Mode,
	// The tick after which the line is gone, or 0 for this frame only.
	expires: time.Tick,
}

// Draw holds the lines to draw. It lives in Game_State, and its lines in host memory, so a code reload keeps them.
Draw :: struct {
	lines:     []Line,
	// The next free line, which jobs take with an atomic add. It can pass len(lines), and then the lines are dropped.
	count:     int,
	allocator: runtime.Allocator,
}

init :: proc(d: ^Draw, allocator: runtime.Allocator) {
	d^ = {allocator = allocator}
	when DEBUG_DRAW {
		d.lines = make([]Line, MAX_LINES, allocator)
	}
}

destroy :: proc(d: ^Draw) {
	delete(d.lines, d.allocator)
	d^ = {}
}

// line draws a line for duration seconds, or for this frame only with 0.
line :: proc(d: ^Draw, a, b: ecs.World_Position, color: [4]f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		index := sync.atomic_add(&d.count, 1)
		if index >= len(d.lines) {
			return
		}
		expires: time.Tick
		if duration > 0 {
			expires = time.tick_add(time.tick_now(), time.Duration(f64(duration) * f64(time.Second)))
		}
		d.lines[index] = {a, b, color, mode, expires}
	}
}

// box draws the edges of a box: its center, its half extents along its axes, and its rotation.
box :: proc(d: ^Draw, center: ecs.World_Position, half: [3]f32, rotation: quaternion128, color: [4]f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		corner :: proc(center: ecs.World_Position, half: [3]f32, rotation: quaternion128, i: int) -> ecs.World_Position {
			local := [3]f32{i & 1 != 0 ? half.x : -half.x, i & 2 != 0 ? half.y : -half.y, i & 4 != 0 ? half.z : -half.z}
			return ecs.position_offset(center, linalg.quaternion128_mul_vector3(rotation, local))
		}
		corners: [8]ecs.World_Position
		for &c, i in corners {
			c = corner(center, half, rotation, i)
		}
		// Each edge joins two corners that differ in one axis.
		for i in 0 ..< 8 {
			for bit in ([3]int{1, 2, 4}) {
				if i & bit == 0 {
					line(d, corners[i], corners[i | bit], color, duration, mode)
				}
			}
		}
	}
}

// sphere draws a sphere as three circles, one about each axis of the world.
sphere :: proc(d: ^Draw, center: ecs.World_Position, radius: f32, color: [4]f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		axes := [3][2][3]f32{{{1, 0, 0}, {0, 1, 0}}, {{0, 1, 0}, {0, 0, 1}}, {{0, 0, 1}, {1, 0, 0}}}
		for plane in axes {
			circle(d, center, plane[0], plane[1], radius, color, duration, mode)
		}
	}
}

// circle draws a circle in the plane of two unit axes.
circle :: proc(d: ^Draw, center: ecs.World_Position, u, v: [3]f32, radius: f32, color: [4]f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		point :: proc(center: ecs.World_Position, u, v: [3]f32, radius: f32, k: int) -> ecs.World_Position {
			angle := f32(k) * math.TAU / CIRCLE_SEGMENTS
			return ecs.position_offset(center, (u * math.cos(angle) + v * math.sin(angle)) * radius)
		}
		previous := point(center, u, v, radius, 0)
		for k in 1 ..= CIRCLE_SEGMENTS {
			next := point(center, u, v, radius, k)
			line(d, previous, next, color, duration, mode)
			previous = next
		}
	}
}

// arrow draws a line with a head at its end, a fifth of its length.
arrow :: proc(d: ^Draw, from, to: ecs.World_Position, color: [4]f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		line(d, from, to, color, duration, mode)
		delta := ecs.position_sub(to, from)
		length := linalg.length(delta)
		if length < 1e-6 {
			return
		}
		forward := delta / length
		// Any direction that is not along the arrow gives the head's sides.
		other := abs(forward.y) < 0.9 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
		side := linalg.normalize(linalg.cross(forward, other))
		up := linalg.cross(side, forward)
		head := length * 0.2
		for s in ([4][3]f32{side, -side, up, -up}) {
			line(d, to, ecs.position_offset(to, (-forward + s * 0.5) * head), color, duration, mode)
		}
	}
}

// axes draws a pose's axes, size long: x red, y green and z blue.
axes :: proc(d: ^Draw, pose: ecs.Transform, size: f32, duration: f32 = 0, mode := Mode.Tested) {
	when DEBUG_DRAW {
		colors := [3][4]f32{{1, 0.15, 0.1, 1}, {0.2, 1, 0.2, 1}, {0.15, 0.4, 1, 1}}
		for axis, i in ([3][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}) {
			end := ecs.position_offset(pose.position, linalg.quaternion128_mul_vector3(pose.rotation, axis) * size)
			line(d, pose.position, end, colors[i], duration, mode)
		}
	}
}

// frame_lines gives the lines to draw this frame. Call it while no job draws, then end_frame after.
frame_lines :: proc(d: ^Draw) -> []Line {
	return d.lines[:min(d.count, len(d.lines))]
}

// end_frame drops the lines of this frame only and those that have expired, and keeps the others for the next frames.
// Call it while no job draws.
end_frame :: proc(d: ^Draw) {
	now := time.tick_now()
	kept := 0
	for l in frame_lines(d) {
		if l.expires != {} && time.tick_diff(now, l.expires) > 0 {
			d.lines[kept] = l
			kept += 1
		}
	}
	d.count = kept
}
