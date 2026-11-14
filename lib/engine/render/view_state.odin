package render

import "core:log"

import "cinnabar:engine/ecs"

// View_State is what the renderer keeps for one camera from frame to frame (see docs/rendering/frame.md#views): the
// histories that its temporal passes read, its last frame's camera, its exposure, its occlusion culling's visibility, the
// storage of its global illumination, and its stats. The renderer keeps the rest once for the world, whatever the views.
// The caller owns the View_State of each extra view (see Extra_View); the renderer has one built in, Renderer.view, which
// the frame's own view uses.
//
// A view draws exactly as it would if it were the only one: the same state, the same level. A view that is not drawn in a
// frame has no valid history in the next. It holds handles and values only, so it lives in Game_State across a code
// reload. Make it with view_state_init, and free it with view_state_destroy, which frees its GPU objects at once.
View_State :: struct {
	// The history textures of the view's graphs (see history_texture).
	histories:       History_Set,
	// The frames that the view drew, whose parity says which of the occlusion culling's visibility bits it reads.
	frames:          u64,
	previous:        Previous_Camera,
	occlusion:       Occlusion_State,
	post:            Post_State,
	// Count the frames with the feature, for the noise.
	ao_frame:        u32,
	fog_frame:       u32,
	ssr:             Ssr_State,
	clouds:          Cloud_State,
	sky:             Sky_State,
	gi:              Gi_State,
	virtual_shadows: Virtual_State,
	mask_history:    Mask_History,
	shading:         Shading_State,
}

// Previous_Camera is a view's last frame's camera and projections, for the velocities.
@(private)
Previous_Camera :: struct {
	position:        ecs.World_Position,
	rotation:        quaternion128,
	view_projection: matrix[4, 4]f32,
	view_model:      matrix[4, 4]f32,
	// The time of the frame, which a displacement's previous pose takes.
	time:            f32,
	valid:           bool,
}

// view_state_init makes what a view's state needs at once: its exposure. A zero View_State is not ready to draw.
view_state_init :: proc(v: ^View_State, r: ^Renderer) {
	if v.post.exposure != {} {
		log.error("render: view_state_init on a view state that was made already")
		return
	}
	post_state_init(&v.post, r.platform)
}

// view_state_destroy frees a view's GPU objects, its histories too, at once. It is safe on a zero value, and leaves one.
view_state_destroy :: proc(v: ^View_State, r: ^Renderer) {
	platform := r.platform
	if r.stats_view == v {
		r.stats_view = nil
	}
	history_set_destroy(&v.histories, platform)
	occlusion_state_destroy(&v.occlusion, platform)
	post_state_destroy(&v.post, platform)
	cloud_state_destroy(&v.clouds, platform)
	gi_state_destroy(&v.gi, platform)
	virtual_state_destroy(&v.virtual_shadows, platform)
	shading_state_destroy(&v.shading, platform)
	v^ = {}
}

// stats_state is the state that the stats getters read: the last frame's own view's.
@(private)
stats_state :: proc(r: ^Renderer) -> ^View_State {
	return r.stats_view != nil ? r.stats_view : &r.view
}

// read_view_stats takes the stats of a view that have come back.
@(private)
read_view_stats :: proc(r: ^Renderer, v: ^View_State) {
	read_cull_stats(r, v)
	read_gi_split_stats(r, v)
	read_shading_stats(r, v)
	read_virtual_stats(r, v)
}
