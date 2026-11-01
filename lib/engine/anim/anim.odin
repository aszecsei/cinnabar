// Package anim plays imported animation clips on skinned meshes: an Animator's clock advances in fixed ticks, and each
// presented frame samples its clip between the last two ticks into a palette of joint matrices, which the renderer
// skins the entity's mesh with. See docs/content/kinds/skins-and-animations.md#playback.
package anim

import "core:math"
import "core:mem"

import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// The animation components' stable IDs (see docs/world/ecs.md#component-registry). 80 to 95 are animation's.
ANIMATOR_ID :: ecs.Component_Id(80)

// Animator plays an Animation clip on its entity's skinned Mesh_Renderer, whose mesh is skinned by the clip's skin.
// Its clock advances in fixed ticks, by speed times the tick, and wraps at the clip's end, or holds there without loop.
Animator :: struct {
	clip:     format.Guid `asset:"animation"`,
	speed:    f32 `editor:"range=0,4"`,
	loop:     bool,
	playing:  bool,
	// Seconds into the clip after the last tick.
	time:     f32 `editor:"read"`,
	// How far the last tick moved time, which presentation interpolates back from.
	step:     f32 `editor:"-"`,
	// The clip's duration, which prepare reads from its blob, or 0 while it is not loaded.
	duration: f32 `editor:"-"`,
}

DEFAULT_ANIMATOR :: Animator {
	speed   = 1,
	loop    = true,
	playing = true,
}

// State is the animation's queries and the assets that it reads clips from. It lives in Game_State.
State :: struct {
	assets:    ^asset.Assets,
	animators: ecs.Query,
}

register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Animator, ANIMATOR_ID, DEFAULT_ANIMATOR)
}

// register makes the queries and the animate system. Call it after the world's components are registered, in init
// and in on_reload.
register :: proc(s: ^State, w: ^ecs.World, assets: ^asset.Assets) {
	s.assets = assets
	s.animators = ecs.query(w, {ecs.write(w, Animator)})
	ecs.register_system(w, {name = "animate", stage = .Fixed, procedure = animate, terms = {ecs.write(w, Animator)}})
}

// prepare loads each Animator's clip and gives it the clip's duration, so the animate system's jobs read no assets.
// Call it in the frame code before the ticks.
prepare :: proc(s: ^State, w: ^ecs.World) {
	it := ecs.query_iter(w, s.animators)
	for view in ecs.query_next(&it) {
		for &a in ecs.column(view, 0, Animator) {
			a.duration = 0
			if _, blob, ok := clip_data(s, a.clip); ok {
				a.duration = blob.duration
			}
		}
	}
}

// animate advances each playing Animator by a tick.
animate :: proc(ctx: ^ecs.System_Context) {
	it := ecs.query_iter(ctx.world, ctx.query, ctx.first_chunk, ctx.chunk_count)
	for view in ecs.query_next(&it) {
		for &a in ecs.column(view, 0, Animator) {
			advance(&a, ctx.dt)
		}
	}
}

// advance moves an Animator's clock by a tick of dt seconds, and keeps how far it went for interpolation. Its time
// wraps into the clip with loop, and otherwise holds at either end.
advance :: proc "contextless" (a: ^Animator, dt: f32) {
	step := a.playing && a.duration > 0 ? dt * a.speed : 0
	if a.loop {
		// The step is the distance before the wrap, so presentation moves forward across it.
		a.time = wrap(a.time + step, a.duration, true)
		a.step = step
	} else {
		held := wrap(a.time + step, a.duration, false)
		a.step = held - a.time
		a.time = held
	}
}

// presented_time is where presentation samples an Animator's clip: between the last two ticks by the clock's alpha,
// so up to one tick late, as every presented pose is (see docs/world/time.md#fixed-and-variable-rate).
presented_time :: proc "contextless" (a: Animator, alpha: f32) -> f32 {
	if a.duration <= 0 {
		return 0
	}
	return wrap(a.time - a.step * (1 - alpha), a.duration, a.loop)
}

@(private)
wrap :: proc "contextless" (t, duration: f32, loop: bool) -> f32 {
	if duration <= 0 {
		return 0
	}
	if !loop {
		return clamp(t, 0, duration)
	}
	wrapped := math.mod(t, duration)
	return wrapped + duration if wrapped < 0 else wrapped
}

// present samples every Animator whose clip and skin are loaded, at its presented time, into a pose for the renderer.
// The poses and their palettes are in allocator, which is frame memory.
present :: proc(s: ^State, w: ^ecs.World, allocator: mem.Allocator) -> []render.Skin_Pose {
	poses := make([dynamic]render.Skin_Pose, allocator)
	it := ecs.query_iter(w, s.animators)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		for a, i in ecs.column(view, 0, Animator) {
			clip_bytes, clip := clip_data(s, a.clip) or_continue
			skin_bytes, skin := skin_data(s, clip.skin) or_continue
			joints := format.skin_joints(skin_bytes, skin)
			if clip.joint_count != u32(len(joints)) {
				continue
			}
			locals := make([]anim_graph.Joint_Pose, len(joints), allocator)
			models := make([]matrix[4, 4]f32, len(joints), allocator)
			palette := make([][3][4]f32, len(joints), allocator)
			anim_graph.rest_pose(joints, locals)
			anim_graph.sample(clip_bytes, clip, presented_time(a, w.clock.alpha), locals)
			sphere := anim_graph.compose(joints, locals, models, palette)
			append(&poses, render.Skin_Pose{entity = entities[i], palette = palette, sphere = sphere})
		}
	}
	return poses[:]
}

// clip_data is an animation clip's blob, which it loads if it is not loaded.
clip_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Animation_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.animation_view(data) or_return
	return data, blob, true
}

// skin_data is a skin's blob, which it loads if it is not loaded.
skin_data :: proc(s: ^State, guid: format.Guid) -> (data: []byte, blob: ^format.Skin_Blob, ok: bool) {
	if s.assets == nil || guid == {} {
		return
	}
	h := asset.load(s.assets, guid) or_return
	data = asset.data(s.assets, h) or_return
	blob = format.skin_view(data) or_return
	return data, blob, true
}
