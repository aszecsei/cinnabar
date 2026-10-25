package render

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"

import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

// A game's post effects (see docs/rendering.md#post-effects): passes that the post-processing runs at a point among
// its own, each driven by a settings component on volumes, as the renderer's own settings are.

MAX_POST_EFFECTS :: 16

// Post_Point is where among the post passes an effect runs. The renderer's own passes keep their order.
Post_Point :: enum u8 {
	// Before temporal AA, where the before_post hook runs.
	Before_Temporal_Aa,
	// After temporal AA, before the exposure's histogram and bloom, so an effect changes both.
	After_Temporal_Aa,
	// In linear HDR after bloom, which the scene then holds, just before the output pass tone maps it.
	Before_Tone_Mapping,
}

// Post_Effect_Proc adds an effect's passes. They read Frame.scene, and a pass that makes a new scene color sets
// Frame.scene to it. settings is the effect's component as the volumes at the camera blend it. Frame.data is the
// hooks' data.
Post_Effect_Proc :: #type proc(f: ^Frame, settings: rawptr)

// Post_Effect is a registered effect, in the Renderer. Its procedure is in the game, so renderer_reload clears the
// effects, and the game registers them again.
Post_Effect :: struct {
	name:      string,
	point:     Post_Point,
	order:     i32,
	component: ecs.Component_Id,
	type:      ^runtime.Type_Info,
	defaults:  [ecs.MAX_COMPONENT_SIZE]byte,
	add:       Post_Effect_Proc,
}

// register_post_effect adds an effect that runs at a point, after the effects there with a lower order, and those with
// the same order registered before it. T is its settings component, registered in the world, and defaults its settings
// with the defaults that 0 stands for, which volumes blend from. The effect runs only where a volume with T reaches the
// camera. Call it after renderer_init and after renderer_reload.
register_post_effect :: proc(r: ^Renderer, w: ^ecs.World, name: string, point: Post_Point, $T: typeid, defaults: T, add: Post_Effect_Proc, order: i32 = 0) -> bool {
	d := defaults
	return register_post_effect_raw(r, w, name, point, type_info_of(T), &d, add, order)
}

// register_post_effect_raw is register_post_effect with the settings' type and defaults as runtime values.
register_post_effect_raw :: proc(r: ^Renderer, w: ^ecs.World, name: string, point: Post_Point, type: ^runtime.Type_Info, defaults: rawptr, add: Post_Effect_Proc, order: i32 = 0) -> bool {
	info := ecs.registry_find_type(&w.registry, type.id)
	if info == nil {
		log.errorf("render: the post effect %q's settings %v are not a registered component", name, type.id)
		return false
	}
	if r.effect_count == MAX_POST_EFFECTS {
		log.errorf("render: more than %d post effects; %q is left out", MAX_POST_EFFECTS, name)
		return false
	}
	e := &r.effects[r.effect_count]
	e^ = {name = name, point = point, order = order, component = info.id, type = type, add = add}
	mem.copy(&e.defaults, defaults, type.size)
	r.effect_count += 1
	// Stable, so effects with the same order keep their registration order.
	slice.stable_sort_by(r.effects[:r.effect_count], proc(a, b: Post_Effect) -> bool {
		return a.order < b.order
	})
	return true
}

// Effect_Settings is an effect's settings at the camera, in frame memory, or nil where no volume with them reaches it.
Effect_Settings :: struct {
	settings: rawptr,
}

// resolve_effects blends each effect's settings from the volumes that reach a point.
@(private)
resolve_effects :: proc(r: ^Renderer, w: ^ecs.World, inf: ^volume.Influences) -> []Effect_Settings {
	out := make([]Effect_Settings, r.effect_count, w.platform.frame_allocator)
	for &e, i in r.effects[:r.effect_count] {
		data, err := mem.alloc(e.type.size, e.type.align, w.platform.frame_allocator)
		if err != nil {
			continue
		}
		if volume.blend_raw(w, inf, e.component, e.type, &e.defaults, data) {
			out[i].settings = data
		}
	}
	return out
}

// add_post_effects adds the passes of the effects at a point that run in this frame. Before tone mapping, it first
// adds bloom into the scene, so the effects see the scene as the display will.
@(private)
add_post_effects :: proc(f: ^Frame, point: Post_Point) {
	r := f.renderer
	if !f.post.effects {
		return
	}
	running := false
	for e, i in r.effects[:r.effect_count] {
		running ||= e.point == point && i < len(f.post.effect_settings) && f.post.effect_settings[i].settings != nil
	}
	if !running {
		return
	}
	if point == .Before_Tone_Mapping && f.bloom != 0 {
		add_bloom_composite(f)
	}
	for e, i in r.effects[:r.effect_count] {
		if e.point == point && i < len(f.post.effect_settings) && f.post.effect_settings[i].settings != nil {
			e.add(f, f.post.effect_settings[i].settings)
		}
	}
}

// add_bloom_composite adds bloom into a new scene color, as the output pass would, which then adds none.
@(private = "file")
add_bloom_composite :: proc(f: ^Frame) {
	g := f.graph
	pf := f.post
	pf.composite_in = f.scene
	pf.composite_out = create_texture(g, {size = f.size, format = SCENE_FORMAT, label = "bloom composite"})
	pass := add_compute_pass(g, "bloom composite", run_bloom_composite, f)
	read(g, pass, f.scene)
	read(g, pass, f.bloom)
	write(g, pass, pf.composite_out)
	pf.composite_bloom, pf.composite_scales = f.bloom, {f.scene_scale, f.bloom_scale}
	f.scene, f.bloom, f.scene_scale, f.bloom_scale = pf.composite_out, 0, 1, 0
}

@(private = "file")
run_bloom_composite :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	pf := f.post
	g := ctx.graph
	push := Bloom_Push {
		source        = gpu.read_index(gpu_texture(g, pf.composite_in)),
		base          = gpu.read_index(gpu_texture(g, pf.composite_bloom)),
		output        = gpu.write_index(gpu_texture(g, pf.composite_out)),
		sampler_index = gpu.sampler_index(f.renderer.post.sampler),
		size          = f.size,
		mode          = BLOOM_COMPOSITE,
		scene_scale   = pf.composite_scales[0],
		bloom_scale   = pf.composite_scales[1],
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.bloom.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}
