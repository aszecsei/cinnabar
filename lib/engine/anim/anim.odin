// Package anim plays imported animation clips on skinned meshes: an Animator's clock advances in fixed ticks, and each
// presented frame samples its clip between the last two ticks into a palette of joint matrices, which the renderer
// skins the entity's mesh with. See docs/content/kinds/skins-and-animations.md#playback.
package anim

import "core:math"
import "core:math/linalg"
import "core:mem"

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
			palette := make([][3][4]f32, len(joints), allocator)
			sphere := pose(joints, clip_bytes, clip, presented_time(a, w.clock.alpha), palette, allocator)
			append(&poses, render.Skin_Pose{entity = entities[i], palette = palette, sphere = sphere})
		}
	}
	return poses[:]
}

// Joint_Pose is a joint's pose relative to its parent.
Joint_Pose :: struct {
	translation: [3]f32,
	rotation:    quaternion128,
	scale:       [3]f32,
}

// pose samples a clip at a time over its skin's rest pose, and writes each joint's matrix, from the mesh's bind pose
// to its posed place, into palette. It returns a sphere about the posed mesh: the union of the joints' bind spheres,
// each posed by its joint. Its scratch memory is from allocator.
pose :: proc(joints: []format.Skin_Joint, clip_bytes: []byte, clip: ^format.Animation_Blob, time: f32, palette: [][3][4]f32, allocator := context.temp_allocator) -> (sphere: [4]f32) {
	locals := make([]Joint_Pose, len(joints), allocator)
	for j, i in joints {
		locals[i] = {j.translation, quaternion(real = j.rotation.w, imag = j.rotation.x, jmag = j.rotation.y, kmag = j.rotation.z), j.scale}
	}
	sample(clip_bytes, clip, time, locals)
	models := make([]matrix[4, 4]f32, len(joints), allocator)
	sphere.w = -1
	for j, i in joints {
		local := linalg.matrix4_from_trs_f32(locals[i].translation, locals[i].rotation, locals[i].scale)
		models[i] = j.parent < 0 ? local : models[j.parent] * local
		m := models[i] * rows_matrix(j.inverse_bind)
		palette[i] = {{m[0, 0], m[0, 1], m[0, 2], m[0, 3]}, {m[1, 0], m[1, 1], m[1, 2], m[1, 3]}, {m[2, 0], m[2, 1], m[2, 2], m[2, 3]}}
		if j.sphere.w >= 0 {
			center := (models[i] * [4]f32{j.sphere.x, j.sphere.y, j.sphere.z, 1}).xyz
			scale := max(linalg.length(models[i][0].xyz), linalg.length(models[i][1].xyz), linalg.length(models[i][2].xyz))
			sphere = merge_spheres(sphere, {center.x, center.y, center.z, j.sphere.w * scale})
		}
	}
	if sphere.w < 0 {
		sphere = {}
	}
	return
}

// sample replaces the parts of the joints' poses that the clip's channels animate with their values at a time. Before
// a channel's first key the first holds, and after its last the last.
sample :: proc(clip_bytes: []byte, clip: ^format.Animation_Blob, time: f32, locals: []Joint_Pose) {
	times := format.animation_times(clip_bytes, clip)
	values := format.animation_values(clip_bytes, clip)
	for c in format.animation_channels(clip_bytes, clip) {
		if int(c.joint) >= len(locals) {
			continue
		}
		keys := times[c.first_key:][:c.key_count]
		width := int(format.animation_path_width(c.path))
		k, u := find_key(keys, time)
		if c.interpolation == .Step {
			u = 0
		}
		next := min(k + 1, len(keys) - 1)
		a := values[int(c.first_value) + k * width:][:width]
		b := values[int(c.first_value) + next * width:][:width]
		l := &locals[c.joint]
		switch c.path {
		case .Translation:
			l.translation = linalg.lerp([3]f32{a[0], a[1], a[2]}, [3]f32{b[0], b[1], b[2]}, u)
		case .Scale:
			l.scale = linalg.lerp([3]f32{a[0], a[1], a[2]}, [3]f32{b[0], b[1], b[2]}, u)
		case .Rotation:
			qa := quaternion(real = a[3], imag = a[0], jmag = a[1], kmag = a[2])
			qb := quaternion(real = b[3], imag = b[0], jmag = b[1], kmag = b[2])
			l.rotation = linalg.normalize(linalg.quaternion_slerp_f32(qa, qb, u))
		}
	}
}

// find_key is the key at or before a time and how far the time is toward the next, from 0 to 1.
find_key :: proc "contextless" (keys: []f32, time: f32) -> (key: int, u: f32) {
	if len(keys) < 2 || time <= keys[0] {
		return 0, 0
	}
	if time >= keys[len(keys) - 1] {
		return len(keys) - 1, 0
	}
	low, high := 0, len(keys) - 1
	for high - low > 1 {
		mid := (low + high) / 2
		if keys[mid] <= time {
			low = mid
		} else {
			high = mid
		}
	}
	span := keys[high] - keys[low]
	return low, span > 0 ? (time - keys[low]) / span : 0
}

// merge_spheres is a sphere about two spheres; one with a negative radius is none.
merge_spheres :: proc "contextless" (a, b: [4]f32) -> [4]f32 {
	if a.w < 0 {
		return b
	}
	if b.w < 0 {
		return a
	}
	d := linalg.length(b.xyz - a.xyz)
	if d + b.w <= a.w {
		return a
	}
	if d + a.w <= b.w {
		return b
	}
	radius := (d + a.w + b.w) / 2
	center := a.xyz + (b.xyz - a.xyz) * ((radius - a.w) / d)
	return {center.x, center.y, center.z, radius}
}

@(private)
rows_matrix :: proc "contextless" (rows: [3][4]f32) -> matrix[4, 4]f32 {
	return {
		rows[0][0], rows[0][1], rows[0][2], rows[0][3],
		rows[1][0], rows[1][1], rows[1][2], rows[1][3],
		rows[2][0], rows[2][1], rows[2][2], rows[2][3],
		0, 0, 0, 1,
	}
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
