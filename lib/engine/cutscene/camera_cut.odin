package cutscene

import "core:log"
import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/camera"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// Cut is what a cutscene's camera cut track shows (see docs/cinematics/tracks.md#camera-cut-tracks): the shot that it
// claims the view for, and the evaluation's jumps when it last evaluated, so a seek or a skip since then cuts.
Cut :: struct {
	shown: Cut_Shown,
	jumps: u32,
}

// Cut_Shown is the one state of what the cut track shows. nil before its first evaluation, and after end_cut. Change it
// only with change_cut.
Cut_Shown :: union {
	Cut_Gameplay,
	Cut_Shot,
	Cut_Refused,
}

// Cut_Gameplay is a time that no section covers: the track claims nothing, so the view is gameplay's.
Cut_Gameplay :: struct {}

// Cut_Shot is a section that shows: its ID and its camera, the claim that the track holds on the views for it, the views
// that hold it, in Game_State, and how the claim leaves if the player ends now.
Cut_Shot :: struct {
	section: Scoped,
	entity:  ecs.Entity,
	views:   ^camera.Views,
	token:   camera.Claim_Token,
	leave:   camera.Blend,
}

// Cut_Refused is a section whose camera binding is missing or not a live Camera. The track logs it once, and claims
// nothing until another section shows or the binding changes. A claim that fails because the views' entries are all
// taken is not a refusal: the track shows gameplay and claims again at its next evaluation.
Cut_Refused :: struct {
	section: Scoped,
	entity:  ecs.Entity,
}

#assert(int(format.Cutscene_Blend_Curve.Linear) == int(camera.Curve.Linear))
#assert(int(format.Cutscene_Blend_Curve.Smooth) == int(camera.Curve.Smooth))
#assert(int(format.Cutscene_Blend_Curve.Ease_In) == int(camera.Curve.Ease_In))
#assert(int(format.Cutscene_Blend_Curve.Ease_Out) == int(camera.Curve.Ease_Out))

// camera_cut_track is the camera cut kind's evaluate procedure, in the Late phase. The section that covers the time
// decides what the views show: its camera, through a claim at the player's priority, or gameplay where no section
// covers it. A change of section is a new claim, so the stack cuts, even to the same camera. A section blends in from
// gameplay when playback crosses its start, and out to it when playback crosses its end; a seek, a skip and a reload
// cut. A skip that ends the cutscene cuts back to gameplay, or blends out when the last section is marked to. It runs
// once for the tree, with the root's context, after the phase's tracks: the shot that shows is the root's where its
// track has a section over the time, and else a child's (see shown_shot).
camera_cut_track :: proc(ctx: ^Track_Context) {
	s := ctx.cutscenes
	if s == nil || s.views == nil {
		return
	}
	e := ctx.evaluation
	jumped := ctx.skipped || e.cut.jumps != e.jumps
	e.cut.jumps = e.jumps
	shot, showing := shown_shot(s, ctx)
	if ctx.skipped && ctx.time == ctx.range_end {
		// The player finishes in this update, before the views choose again: the last shot is never chosen.
		showing = false
	}

	if !showing {
		change_cut(e, Cut_Gameplay{}, leaving_blend(s, ctx, jumped))
		return
	}
	// A loop of a sub-sequence that wrapped is a jump of the shot's time.
	jumped ||= shot.ctx.wrapped
	at := &shot.ctx
	section := shot.sections[shot.index]
	key := Scoped{at.scope, section.id}
	entity, bound := ctx_binding(at, section.camera)
	leave := shot_leave(at, section)
	switch shown in e.cut.shown {
	case Cut_Shot:
		if !jumped &&
		   shown.section == key &&
		   shown.entity == entity &&
		   camera.is_claimed(s.views, shown.token) {
			next := shown
			next.leave = leave
			change_cut(e, next, camera.CUT)
			return
		}
	case Cut_Refused:
		if shown.section == key && shown.entity == entity {
			return
		}
	case Cut_Gameplay:
	}

	blend_in := camera.CUT
	if !jumped && fires(at, section.start) && section.blend_in > 0 {
		blend_in = cut_blend(at, section.blend_in, section.blend_curves[0])
	}
	leaving := leaving_blend(s, ctx, jumped)
	if !bound || ecs.get_raw(ctx.world, entity, render.CAMERA_ID) == nil {
		log.errorf(
			"cutscene %s: the camera cut section %d shows nothing: its camera binding is missing, or is not a Camera",
			format.blob_string(at.data, at.blob.source_path),
			section.id,
		)
		change_cut(e, Cut_Refused{key, entity}, leaving)
		return
	}
	token, claimed := camera.claim(
		s.views,
		ctx.world,
		entity,
		player_priority(s, e),
		blend_in,
		leave,
	)
	if !claimed {
		// The views' entries are all taken, which camera.claim warns of: gameplay shows until a claim succeeds.
		change_cut(e, Cut_Gameplay{}, leaving)
		return
	}
	change_cut(e, Cut_Shot{key, entity, s.views, token, leave}, leaving)
}

// Shot is a camera cut section that shows: the context of the cutscene of the tree whose cut track holds it, the
// track's sections, and its index in them.
@(private)
Shot :: struct {
	ctx:      Track_Context,
	sections: []format.Cutscene_Section,
	index:    int,
}

// shown_shot is the camera cut section that shows at a context's time: its own cut track's section over the time, and
// where it has none, the shot of the last of its children, in the tree's order, whose section covers the time and that
// shows one, found the same way. So a parent's cut track wins over its children's where it has a section, and a master
// that has no cut track shows each shot's own cuts (see docs/cinematics/tracks.md#sub-sequence-tracks).
@(private)
shown_shot :: proc(s: ^State, ctx: ^Track_Context) -> (shot: Shot, ok: bool) {
	if cut, live := live_cut_track(ctx.evaluation, ctx.child, ctx.data, ctx.blob); live {
		sections := format.cutscene_track_sections(ctx.data, ctx.blob, cut)
		if i, showing := shown_section(ctx, sections, ctx.time); showing {
			return {ctx^, sections, i}, true
		}
	}
	for c, k in ctx.evaluation.children {
		if c.parent != ctx.child {
			continue
		}
		inner, _, loaded := child_context(s, ctx, k + 1)
		if !loaded || !inner.covered {
			continue
		}
		if found, showing := shown_shot(s, &inner); showing {
			shot, ok = found, true
		}
	}
	return
}

// last_shot is the last section of the cut track that shows at the end of a context's range: its own cut track's, or
// else that of the last child whose section covers the end, found the same way.
@(private)
last_shot :: proc(s: ^State, ctx: ^Track_Context) -> (shot: Shot, ok: bool) {
	if cut, live := live_cut_track(ctx.evaluation, ctx.child, ctx.data, ctx.blob); live {
		sections := format.cutscene_track_sections(ctx.data, ctx.blob, cut)
		if len(sections) > 0 {
			return {ctx^, sections, len(sections) - 1}, true
		}
	}
	for c, k in ctx.evaluation.children {
		if c.parent != ctx.child {
			continue
		}
		inner, _, loaded := child_context(s, ctx, k + 1)
		if !loaded || !inner.covered {
			continue
		}
		if found, showing := last_shot(s, &inner); showing {
			shot, ok = found, true
		}
	}
	return
}

// tree_has_cuts is whether the root or a loaded child has a camera cut track that is not muted.
@(private)
tree_has_cuts :: proc(s: ^State, ctx: ^Track_Context) -> bool {
	if _, live := live_cut_track(ctx.evaluation, ctx.child, ctx.data, ctx.blob); live {
		return true
	}
	for i in 1 ..= len(ctx.evaluation.children) {
		if data, blob, ok := child_blob(s, ctx.evaluation, i); ok {
			if _, live := live_cut_track(ctx.evaluation, i, data, blob); live {
				return true
			}
		}
	}
	return false
}

// end_cut gives the views back: it releases the track's claim, with the blend that the shot leaves with. end_holds
// calls it, so the player hands the view back when it ends.
end_cut :: proc(e: ^Evaluation) {
	shot, held := e.cut.shown.(Cut_Shot)
	change_cut(e, nil, shot.leave if held else camera.CUT)
}

// change_cut is the one writer of what the cut track shows. It releases the old shot's claim, leaving with a blend, when
// the next state does not hold the same claim.
@(private)
change_cut :: proc(e: ^Evaluation, next: Cut_Shown, leaving: camera.Blend) {
	if old, held := e.cut.shown.(Cut_Shot); held {
		new, keeps := next.(Cut_Shot)
		if !keeps || new.token != old.token {
			camera.release(old.views, old.token, leaving)
		}
	}
	e.cut.shown = next
}

// live_cut_track is the camera cut track of one cutscene of the tree, by its child index (0 for the root), while it is
// not muted or silenced (see track_silent).
@(private)
live_cut_track :: proc(
	e: ^Evaluation,
	child: int,
	data: []byte,
	blob: ^format.Cutscene_Blob,
) -> (
	track: format.Cutscene_Track,
	ok: bool,
) {
	track = format.cutscene_cut_track(data, blob) or_return
	return track, !track_silent(e, child, track)
}

// shown_section is the cut section that covers a time on the scope's time: [start, end), and its end too at the range's
// end, and none while a sub-sequence section above it does not cover the time.
@(private)
shown_section :: proc(
	ctx: ^Track_Context,
	sections: []format.Cutscene_Section,
	t: i32,
) -> (
	index: int,
	ok: bool,
) {
	for section, i in sections {
		if _, covers := sample_section(ctx, section, t); covers {
			return i, true
		}
	}
	return
}

// shot_leave is how a shot's claim leaves if the player ends at this time: with the section's blend out at its end, and
// with a cut before it, as when the player stops.
@(private)
shot_leave :: proc(ctx: ^Track_Context, section: format.Cutscene_Section) -> camera.Blend {
	if ctx.time >= section.end && section.blend_out > 0 {
		return cut_blend(ctx, section.blend_out, section.blend_curves[1])
	}
	return camera.CUT
}

// leaving_blend is how the shot that shows leaves now that another section, or gameplay, takes its place: with its blend
// out when playback passed its end, on its own cutscene's time, or when a skip ended the cutscene and the last section
// is marked to blend on a skip, and with a cut otherwise. ctx is the root's.
@(private)
leaving_blend :: proc(s: ^State, ctx: ^Track_Context, jumped: bool) -> camera.Blend {
	shot, held := ctx.evaluation.cut.shown.(Cut_Shot)
	if !held {
		return camera.CUT
	}
	if ctx.skipped && ctx.time == ctx.range_end {
		last, found := last_shot(s, ctx)
		if !found {
			return camera.CUT
		}
		section := last.sections[last.index]
		if .Blend_On_Skip in section.flags {
			return cut_blend(&last.ctx, section.blend_out, section.blend_curves[1])
		}
		return camera.CUT
	}
	if jumped {
		return camera.CUT
	}
	for i in 0 ..= len(ctx.evaluation.children) {
		if i > 0 && ctx.evaluation.children[i - 1].scope != shot.section.scope {
			continue
		}
		if i == 0 && shot.section.scope != 0 {
			continue
		}
		at, found := scope_context(s, ctx, i)
		cut, live := live_cut_track(at.evaluation, at.child, at.data, at.blob)
		if !found || !live {
			continue
		}
		for section in format.cutscene_track_sections(at.data, at.blob, cut) {
			if shot.section.id == section.id && section.blend_out > 0 && fires(&at, section.end) {
				return cut_blend(&at, section.blend_out, section.blend_curves[1])
			}
		}
	}
	return camera.CUT
}

// cut_blend is a camera blend of a number of ticks on the scope's time, on the stack's clock that is the cutscene's. In a
// sub-sequence that plays at a scale, the blend takes the root's time that the ticks take.
@(private)
cut_blend :: proc(
	ctx: ^Track_Context,
	ticks: i32,
	curve: format.Cutscene_Blend_Curve,
) -> camera.Blend {
	rate := ctx.rate if ctx.rate > 0 else 1
	return {
		duration = f32(f64(ticks) / format.CUTSCENE_TICKS_PER_SECOND / rate),
		curve = camera.Curve(curve),
		clock = .Real if ctx.clock == .Real else .Game,
	}
}

// player_priority is the priority of the player whose evaluation this is, or 0 for an evaluation outside a player.
@(private)
player_priority :: proc(s: ^State, e: ^Evaluation) -> i32 {
	for &p in s.players {
		if live := live_of(&p.state); live != nil && &live.evaluation == e {
			return p.priority
		}
	}
	return 0
}

// cut_fires is whether this evaluation crosses a cut of the camera cut tracks of the tree, which run_phase finds once
// (see tree_cut_fires). Transform tracks teleport on it, so nothing interpolates across the cut.
@(private)
cut_fires :: proc(ctx: ^Track_Context) -> bool {
	return ctx.cut
}

// tree_cut_fires is whether the root's event range crosses a cut of the tree: of the root's cut track or a child's (see
// scope_cut_fires), or the start or the end, before the parent's range's end, of a sub-sequence section whose child has
// a cut track. It reads only the blobs, so it is the same in either phase.
@(private)
tree_cut_fires :: proc(s: ^State, ctx: ^Track_Context) -> bool {
	if scope_cut_fires(ctx) {
		return true
	}
	e := ctx.evaluation
	for c, k in e.children {
		inner, ok := scope_context(s, ctx, k + 1)
		if !ok {
			continue
		}
		if scope_cut_fires(&inner) {
			return true
		}
		if _, live := live_cut_track(inner.evaluation, inner.child, inner.data, inner.blob);
		   !live {
			continue
		}
		parent := scope_context(s, ctx, c.parent) or_continue
		section := child_section(parent.data, parent.blob, c) or_continue
		if fires(&parent, section.start) ||
		   (section.end != parent.range_end && fires(&parent, section.end)) {
			return true
		}
	}
	return false
}

// scope_cut_fires is whether a context's event range crosses a cut of its own cutscene's camera cut track: a section's
// start that does not blend in from gameplay, or a section's end that cuts back to gameplay, before the range's end.
@(private)
scope_cut_fires :: proc(ctx: ^Track_Context) -> bool {
	cut, live := live_cut_track(ctx.evaluation, ctx.child, ctx.data, ctx.blob)

	if !live {
		return false
	}
	sections := format.cutscene_track_sections(ctx.data, ctx.blob, cut)
	for section, i in sections {
		after_gap := i == 0 || sections[i - 1].end < section.start
		before_gap := i == len(sections) - 1 || sections[i + 1].start > section.end
		if fires(ctx, section.start) && !(after_gap && section.blend_in > 0) {
			return true
		}
		if section.end != ctx.range_end &&
		   before_gap &&
		   section.blend_out == 0 &&
		   fires(ctx, section.end) {
			return true
		}
	}
	return false
}

// constrain applies the camera constraints at the end of the Fixed phase, after every track that moves a binding, so
// they see this tick's poses (see docs/cinematics/tracks.md#camera-cut-tracks). It writes, for each camera that a
// constraint of the blob names, every part that a constraint of the blob can write: the constrained value while a
// constraint applies, and the unconstrained one otherwise. So the camera at a time does not depend on what came before.
// It writes as the cut track, whose when_finished restores or keeps the parts.
@(private)
constrain :: proc(ctx: ^Track_Context) {
	cut, live := live_cut_track(ctx.evaluation, ctx.child, ctx.data, ctx.blob)
	constraints := format.cutscene_constraints(ctx.data, ctx.blob)
	if !live || len(constraints) == 0 {
		return
	}
	ctx.track = cut
	ctx.user = nil
	sections := format.cutscene_sections(ctx.data, ctx.blob)
	cut_sections := format.cutscene_track_sections(ctx.data, ctx.blob, cut)
	shown: Maybe(format.Cutscene_Section)
	shown_index := format.CUTSCENE_NONE
	if i, ok := shown_section(ctx, cut_sections, ctx.time); ok {
		shown = cut_sections[i]
		shown_index = cut.first_section + u32(i)
	}
	done := make(map[u32]bool, ctx.world.platform.frame_allocator)
	for c in constraints {
		camera_binding := c.binding
		if c.section != format.CUTSCENE_NONE {
			camera_binding = sections[c.section].camera
		}
		if done[camera_binding] {
			continue
		}
		done[camera_binding] = true
		constrain_camera(ctx, constraints, sections, camera_binding, shown, shown_index)
	}
}

// Active_Constraint is a constraint that applies to a camera now, and the weight that its damping gives it.
@(private)
Active_Constraint :: struct {
	constraint: format.Cutscene_Constraint,
	weight:     f32,
}

// constrain_camera writes one camera's constrained parts. Of each kind, the shown section's constraint on it applies,
// else its binding's. A section's damping counts from its start; a binding's constraint counts from the start of the
// section that shows the camera, and applies in full while none does.
@(private)
constrain_camera :: proc(
	ctx: ^Track_Context,
	constraints: []format.Cutscene_Constraint,
	sections: []format.Cutscene_Section,
	camera_binding: u32,
	shown: Maybe(format.Cutscene_Section),
	shown_index: u32,
) {
	entity, bound := ctx_binding(ctx, camera_binding)
	if !bound {
		return
	}
	held: bit_set[format.Cutscene_Constraint_Kind]
	active: [format.Cutscene_Constraint_Kind]Maybe(Active_Constraint)
	since: Maybe(i32)
	if section, ok := shown.?; ok && section.camera == camera_binding {
		since = ctx.time - section.start
	}
	for c in constraints {
		on_camera := c.binding == camera_binding
		on_shot :=
			c.section != format.CUTSCENE_NONE && sections[c.section].camera == camera_binding
		if !on_camera && !on_shot {
			continue
		}
		held += {c.kind}
		if on_shot && c.section != shown_index {
			continue
		}
		if on_camera && active[c.kind] != nil {
			// The shown section's constraint of this kind replaces the binding's.
			continue
		}
		weight := f32(1)
		if elapsed, counted := since.?; counted && c.damping > 0 {
			weight = f32(1 - math.exp(-f64(elapsed) / f64(c.damping)))
		}
		active[c.kind] = Active_Constraint{c, weight}
	}
	if held & {.Follow, .Look_At} != {} {
		constrain_pose(ctx, entity, held, active)
	}
	if .Focus in held && ecs.get_raw(ctx.world, entity, render.CINEMATIC_CAMERA_ID) != nil {
		focus, has_focus := active[.Focus].?
		target: ecs.Entity
		if has_focus {
			target, _ = ctx_binding(ctx, focus.constraint.target)
		} else {
			target, _ = base(
				ctx,
				entity,
				render.CINEMATIC_CAMERA_ID,
				offset_of(render.Cinematic_Camera, focus),
				ecs.Entity,
			)
		}
		write(
			ctx,
			entity,
			render.CINEMATIC_CAMERA_ID,
			offset_of(render.Cinematic_Camera, focus),
			target,
		)
	}
}

// constrain_pose writes a camera's position when a constraint of the blob follows with it, and its rotation when one
// looks with it. Follow moves it first, so a look at aims from where it follows to. The unconstrained pose is what this
// tick's tracks wrote, or the camera's own.
@(private)
constrain_pose :: proc(
	ctx: ^Track_Context,
	entity: ecs.Entity,
	held: bit_set[format.Cutscene_Constraint_Kind],
	active: [format.Cutscene_Constraint_Kind]Maybe(Active_Constraint),
) {
	target, ok := pose_target(ctx.world, entity)
	if !ok {
		return
	}
	pose, has_pose := unconstrained_pose(ctx, target)
	if !has_pose {
		return
	}
	world := own_world(ctx.world, target, pose)
	if follow, following := active[.Follow].?; following {
		if anchor, found := constraint_anchor(ctx, follow.constraint); found {
			world.position = ecs.position_lerp(world.position, anchor, follow.weight)
		}
	}
	if look, looking := active[.Look_At].?; looking {
		if aim, found := constraint_anchor(ctx, look.constraint); found {
			if facing, faces := look_rotation(ecs.position_sub(aim, world.position)); faces {
				if linalg.dot(world.rotation, facing) < 0 {
					facing = -facing
				}
				world.rotation = linalg.normalize(
					linalg.quaternion_slerp_f32(world.rotation, facing, look.weight),
				)
			}
		}
	}
	out := to_target(ctx.world, target, world)
	if .Follow in held {
		switch p in out.position {
		case ecs.World_Position:
			write(ctx, entity, target.component, target.offsets[.Position], p)
		case [3]f32:
			write(ctx, entity, target.component, target.offsets[.Position], p)
		}
	}
	if .Look_At in held {
		write(ctx, entity, target.component, target.offsets[.Rotation], out.rotation)
	}
	settle_pose(ctx.world, entity, jumps(ctx) || cut_fires(ctx))
}

// unconstrained_pose is a camera's pose without the constraints: each part as this tick's tracks wrote it when another
// track writes it, and the camera's own otherwise. The constraints' write of the last tick is never read back.
@(private)
unconstrained_pose :: proc(
	ctx: ^Track_Context,
	target: Pose_Target,
) -> (
	pose: Field_Pose,
	ok: bool,
) {
	pose = own_pose(ctx, target) or_return
	if written_elsewhere(ctx, target, .Position) {
		if _, child := target.parent.?; child {
			pose.position =
				(^ecs.Local_Transform)(ecs.get_raw(ctx.world, target.entity, target.component)).offset
		} else {
			pose.position =
				(^ecs.Transform)(ecs.get_raw(ctx.world, target.entity, target.component)).position
		}
	}
	if written_elsewhere(ctx, target, .Rotation) {
		if _, child := target.parent.?; child {
			pose.rotation =
				(^ecs.Local_Transform)(ecs.get_raw(ctx.world, target.entity, target.component)).rotation
		} else {
			pose.rotation =
				(^ecs.Transform)(ecs.get_raw(ctx.world, target.entity, target.component)).rotation
		}
	}
	return pose, true
}

// written_elsewhere is whether a track other than the context's wrote a part of a pose. Such a track writes the part in
// each evaluation, so the part holds its value at this tick.
@(private)
written_elsewhere :: proc(ctx: ^Track_Context, target: Pose_Target, part: Pose_Part) -> bool {
	size: u32 = size_of(quaternion128)
	if part == .Position {
		_, child := target.parent.?
		size = size_of([3]f32) if child else size_of(ecs.World_Position)
	}
	field := Field{target.entity, target.component, u32(target.offsets[part]), size}
	snapshot := &ctx.evaluation.snapshot
	index, saved := snapshot.index[field]
	if !saved {
		return false
	}
	for writer in snapshot.writers {
		if writer.saved == index && writer.track != (Scoped{ctx.scope, ctx.track.id}) {
			return true
		}
	}
	return false
}

// constraint_anchor is the point that a constraint follows or looks at: its offset in its target binding's space, from
// the target's Transform at this tick.
@(private)
constraint_anchor :: proc(
	ctx: ^Track_Context,
	c: format.Cutscene_Constraint,
) -> (
	anchor: ecs.World_Position,
	ok: bool,
) {
	target := ctx_binding(ctx, c.target) or_return
	pose := (^ecs.Transform)(ecs.get_raw(ctx.world, target, ecs.TRANSFORM_ID))
	if pose == nil {
		return
	}
	return ecs.position_offset(
			pose.position,
			linalg.quaternion_mul_vector3(pose.rotation, c.offset),
		),
		true
}

// look_rotation is the rotation whose +z, a camera's forward, points along a direction, with +y up. False for a
// direction too short, or too near straight up or down, to give one.
@(private)
look_rotation :: proc(direction: [3]f32) -> (rotation: quaternion128, ok: bool) {
	length := linalg.length(direction)
	if length < 1e-4 {
		return 1, false
	}
	forward := direction / length
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(forward, up)) > 0.9999 {
		return 1, false
	}
	right := linalg.normalize(linalg.cross(up, forward))
	true_up := linalg.cross(forward, right)
	m := matrix[3, 3]f32{
		right.x, true_up.x, forward.x,
		right.y, true_up.y, forward.y,
		right.z, true_up.z, forward.z,
	}
	return linalg.normalize(linalg.quaternion_from_matrix3_f32(m)), true
}
