package cutscene

import "core:math"
import "core:math/linalg"
import "core:slice"

import "cinnabar:engine/anim"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// ROOT_MOTION_STEP is the step, in ticks, by which an animation track sums its root motion from the first section that
// applies it: 1/60 s, on a grid from the cutscene's 0, so a seek and playback sum the same steps.
ROOT_MOTION_STEP :: 1000

// MAX_MARKER_LOOPS is the most loops of a clip whose markers one evaluation raises, so a long frame of a short loop
// raises each marker a bounded number of times.
MAX_MARKER_LOOPS :: 16

// Clip_Section is an animation section at a time: the sample that it gives the driver, and the section.
@(private)
Clip_Section :: struct {
	sample:  anim.Driven_Sample,
	section: format.Cutscene_Section,
}

// animation_track is the animation kind's evaluate procedure. It drives its binding's Animator with the clips of the
// sections that cover the time, each at its clip's time and by its weight, the heaviest MAX_DRIVEN of them. It moves
// the binding by the root motion of the sections that apply it, and raises the markers that the heaviest section's
// clip passes (see docs/cinematics/tracks.md#animation-tracks).
animation_track :: proc(ctx: ^Track_Context) {
	animation := ctx.cutscenes.animation if ctx.cutscenes != nil else nil
	if animation == nil {
		return
	}
	entity, bound := track_entity(ctx)
	if !bound || !ecs.has(ctx.world, entity, anim.Animator) {
		return
	}
	clips := clip_sections(ctx, animation)
	drive_clips(ctx, animation, entity, clips)
	apply_root_motion(ctx, animation, entity)
	if ctx.skipped {
		return
	}
	if section, found := marker_section(ctx, animation); found {
		raise_markers(ctx, animation, entity, section)
	}
}

// marker_section is the section whose clip raises the markers of the evaluation's event range: of those whose span meets
// (from, to] with a loaded clip, the heaviest at the range's end, or at its own end when it ends first, the earlier in
// the track among equals. So the tick that passes a section's end, and the tick at its start where its ease in weighs
// nothing, still raise its markers.
@(private)
marker_section :: proc(
	ctx: ^Track_Context,
	animation: ^anim.State,
) -> (
	found: format.Cutscene_Section,
	ok: bool,
) {
	heaviest: f32 = -1
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		if i64(section.end) <= ctx.from || i64(section.start) > ctx.to {
			continue
		}
		if _, loaded := anim.clip_length(animation, section.asset); !loaded {
			continue
		}
		local := i32(min(ctx.to, i64(section.end))) - section.start
		weight := section.weight
		if section.ease_in > 0 {
			weight *= ease(f64(local) / f64(section.ease_in))
		}
		if section.ease_out > 0 {
			weight *= ease(f64(section.end - section.start - local) / f64(section.ease_out))
		}
		if weight > heaviest {
			found, heaviest, ok = section, weight, true
		}
	}
	return
}

// clip_sections is the sections that cover the time with a weight and a loaded clip, heaviest first, the earlier in the
// track among equals, in frame memory.
@(private)
clip_sections :: proc(ctx: ^Track_Context, animation: ^anim.State) -> []Clip_Section {
	found := make([dynamic]Clip_Section, ctx.world.platform.frame_allocator)
	for section in format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track) {
		at := sample(ctx, section, ctx.time) or_continue
		if at.weight <= 0 {
			continue
		}
		length := anim.clip_length(animation, section.asset) or_continue
		append(
			&found,
			Clip_Section {
				sample = {
					clip = section.asset,
					time = f32(clip_time(section, at.local, length)),
					weight = at.weight,
					root_motion = .In_Pose if section.root_motion == .Bake else .In_Place,
				},
				section = section,
			},
		)
	}
	slice.stable_sort_by(found[:], proc(a, b: Clip_Section) -> bool {
		return a.sample.weight > b.sample.weight
	})
	return found[:]
}

// drive_clips hands the heaviest clips to the driver. The track takes the Animator when a section first covers the
// time, and holds it until the cutscene ends: with hold for restore, so the graph resumes where it was, and without
// for keep, so the graph plays on under the clips. A driver that took the Animator from the track loses it again at
// the track's next evaluation, so the later of two players wins it, as it wins a field.
@(private)
drive_clips :: proc(
	ctx: ^Track_Context,
	animation: ^anim.State,
	entity: ecs.Entity,
	clips: []Clip_Section,
) {
	samples: [anim.MAX_DRIVEN]anim.Driven_Sample
	count := min(len(clips), anim.MAX_DRIVEN)
	for c, i in clips[:count] {
		samples[i] = c.sample
	}
	drives := &ctx.evaluation.drives
	token, held := drives[entity]
	if !held || !anim.is_driving(ctx.world, token) {
		if count == 0 {
			delete_key(drives, entity)
			return
		}
		begun: bool
		token, begun = anim.begin_drive(
			animation,
			ctx.world,
			entity,
			hold = ctx.track.finish == .Restore,
		)
		if !begun {
			return
		}
		drives[entity] = token
	}
	anim.drive(ctx.world, token, samples[:count])
}

// end_drives gives back every Animator that the evaluation's animation tracks hold, so their graphs' poses show again.
@(private)
end_drives :: proc(e: ^Evaluation, w: ^ecs.World) {
	for _, token in e.drives {
		anim.end_drive(w, token)
	}
	clear(&e.drives)
}

// clip_time is a section's clip's time, in seconds, at a time in the section in ticks: from its offset, at its speed,
// wrapped when it loops and held at the clip's end when it does not.
@(private)
clip_time :: proc(section: format.Cutscene_Section, local: i32, length: f32) -> f64 {
	t := unwrapped_time(section, i64(local))
	if length <= 0 {
		return 0
	}
	if .Loop in section.flags {
		return math.mod(t, f64(length))
	}
	return min(t, f64(length))
}

// unwrapped_time is a section's clip's time, in seconds, at a time in the section in ticks, as if the clip went on
// past its end.
@(private)
unwrapped_time :: proc(section: format.Cutscene_Section, local: i64) -> f64 {
	return(
		(f64(section.offset) + f64(local) * f64(section.speed)) /
		f64(format.CUTSCENE_TICKS_PER_SECOND) \
	)
}

// apply_root_motion moves the binding by the root motion of the sections that apply it, from its own pose: their
// clips' moves, summed from the first such section's start to the time in steps of ROOT_MOTION_STEP, each step's by
// the sections' weights at its middle. It writes the position and the rotation in every evaluation, the own pose where
// no section has moved it yet, and teleports as a transform track does.
@(private)
apply_root_motion :: proc(ctx: ^Track_Context, animation: ^anim.State, entity: ecs.Entity) {
	sections := format.cutscene_track_sections(ctx.data, ctx.blob, ctx.track)
	// The motion is summed from the first applying section's start to its last one's end: after that it moves no more.
	first, last := i64(max(i32)), i64(0)
	for section in sections {
		if section.root_motion == .Apply {
			first = min(first, i64(section.start))
			last = max(last, i64(section.end))
		}
	}
	if first == i64(max(i32)) {
		return
	}
	target, targeted := pose_target(ctx.world, entity)
	if !targeted {
		return
	}
	own, has_own := own_pose(ctx, target)
	if !has_own {
		return
	}
	motions := make([]Maybe(anim.Clip_Motion), len(sections), ctx.world.platform.frame_allocator)
	for section, i in sections {
		if section.root_motion == .Apply {
			if m, ok := anim.clip_motion_of(
				animation,
				ctx.world,
				entity,
				section.asset,
				ctx.world.platform.frame_allocator,
			); ok {
				motions[i] = m
			}
		}
	}
	moved: [3]f32
	yaw: f32
	until := min(i64(ctx.time), last)
	for a := first; a < until; {
		b := min((a / ROOT_MOTION_STEP + 1) * ROOT_MOTION_STEP, until)
		middle := i32(a + (b - a) / 2)
		weight: f32
		step: [3]f32
		turn: f32
		for section, i in sections {
			m, has_motion := &motions[i].?
			if !has_motion {
				continue
			}
			at := sample(ctx, section, middle) or_continue
			if at.weight <= 0 {
				continue
			}
			duration := i64(section.end - section.start)
			from := clamp(a - i64(section.start), 0, duration)
			to := clamp(b - i64(section.start), 0, duration)
			if to <= from {
				continue
			}
			delta, delta_turn := section_motion(m, section, from, to)
			weight += at.weight
			step += delta * at.weight
			turn += delta_turn * at.weight
		}
		if weight > 1 {
			step /= weight
			turn /= weight
		}
		moved += turn_y(step, yaw)
		yaw += turn
		a = b
	}
	out := own
	offset := linalg.quaternion_mul_vector3(own.rotation, moved * own.scale)
	switch p in own.position {
	case ecs.World_Position:
		out.position = ecs.position_offset(p, offset)
	case [3]f32:
		out.position = p + offset
	}
	out.rotation = linalg.normalize(
		own.rotation * linalg.quaternion_angle_axis_f32(yaw, {0, 1, 0}),
	)
	write_pose(ctx, target, {.Position, .Rotation}, out)
	settle_pose(ctx.world, entity, teleports(ctx))
}

// section_motion is a section's clip's root motion from one time in the section to a later one, in ticks: in the
// model's space turned to the root's heading at the first, and its turn about y. A looping clip's move goes on across
// its wraps, each part turned by what the parts before it turned.
@(private)
section_motion :: proc(
	m: ^anim.Clip_Motion,
	section: format.Cutscene_Section,
	from, to: i64,
) -> (
	delta: [3]f32,
	turn: f32,
) {
	length := f64(m.clip.blob.duration)
	u0, u1 := unwrapped_time(section, from), unwrapped_time(section, to)
	if .Loop not_in section.flags || length <= 0 {
		return anim.clip_motion(m, f32(min(u0, length)), f32(min(u1, length)))
	}
	cycle := math.floor(u0 / length)
	for u := u0; u < u1; {
		end := min((cycle + 1) * length, u1)
		part, part_turn := anim.clip_motion(m, f32(u - cycle * length), f32(end - cycle * length))
		delta += turn_y(part, turn)
		turn += part_turn
		u = end
		cycle += 1
	}
	return
}

// turn_y turns a vector about y by an angle, as a rotation of that angle about +y does.
@(private)
turn_y :: proc "contextless" (v: [3]f32, angle: f32) -> [3]f32 {
	s, c := math.sin(angle), math.cos(angle)
	return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z}
}

// raise_markers raises the markers that the heaviest section's clip passes in the evaluation's event range, as the
// graph raises its heaviest clip's: those after the clip's time at the range's start, up to and at its time at the
// range's end, or from the section's offset when the section starts in the range. A looping clip raises them in each
// loop that the range passes. A seek, a backwards scrub and a skip raise none.
@(private)
raise_markers :: proc(
	ctx: ^Track_Context,
	animation: ^anim.State,
	entity: ecs.Entity,
	section: format.Cutscene_Section,
) {
	if ctx.to <= ctx.from {
		return
	}
	markers := anim.clip_markers(animation, ctx.world, entity, section.asset)
	length, loaded := anim.clip_length(animation, section.asset)
	if len(markers) == 0 || !loaded || length <= 0 {
		return
	}
	lo := max(ctx.from, i64(section.start))
	hi := min(ctx.to, i64(section.end))
	closed := ctx.from < i64(section.start)
	if hi < lo || (hi == lo && !closed) {
		return
	}
	u0 := unwrapped_time(section, lo - i64(section.start))
	u1 := unwrapped_time(section, hi - i64(section.start))
	first_cycle, last_cycle: f64
	if .Loop in section.flags {
		first_cycle = math.floor(u0 / f64(length))
		last_cycle = min(math.floor(u1 / f64(length)), first_cycle + MAX_MARKER_LOOPS - 1)
	} else {
		u0, u1 = min(u0, f64(length)), min(u1, f64(length))
	}
	for cycle := first_cycle; cycle <= last_cycle; cycle += 1 {
		for marker in markers {
			u := cycle * f64(length) + f64(marker.time)
			if (u > u0 || (closed && u == u0)) && u <= u1 {
				anim.raise_marker(animation, ctx.world, entity, marker)
			}
		}
	}
}
