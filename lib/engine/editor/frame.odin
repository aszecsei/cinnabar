package editor

import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// The game's frame with an editor (see docs/rendering/frame.md#views). A game describes its one frame as it would without
// an editor, and calls draw_frame. The editor decides how many views that frame is drawn in: the Game view from the
// frame's own description, and each scene view from the editor's camera, with the game's own hooks in every view and the
// editor's tools in the scene views. The game knows nothing of the viewports, their sizes or their kinds.

// draw_frame draws the game's frame. Without a linked editor, it is render.draw_frame(r, w, desc). With one, desc is what
// the Game view shows, and each scene view is the same frame from the editor's camera (see plan_frame for what changes in
// each). When no viewport is open, or none can draw this frame because the editor is still reading their targets, desc is
// drawn into the frame target with the editor's previews, as without a viewport. It returns whether the frame's own view
// executed. Call it once a frame, in place of render.draw_frame, with the renderer that init was given.
draw_frame :: proc(e: ^Editor, r: ^render.Renderer, w: ^ecs.World, desc: render.Frame_Desc) -> bool {
	if !active(e) {
		return render.draw_frame(r, w, desc)
	}
	draw_helpers(e, w, &r.debug)
	return render.draw_frame(r, w, plan_frame(e, w, desc, frame_viewports(e), r.quality, r.caps))
}

// Tools is the data of a scene view's overlay: what the editor's tools need to add their passes to that view.
@(private)
Tools :: struct {
	e:        ^Editor,
	w:        ^ecs.World,
	viewport: int,
}

// plan_frame turns the game's frame and the viewports that draw into the frame that the renderer draws: the own view,
// which is the first viewport, and the rest as extra views. A linked editor with no viewport to draw keeps desc as it is,
// with the editor's additions below. base and caps are the renderer's quality and device, which the viewports' quality
// choices start from; the game's Frame_Desc.quality is the base when it has one.
//
// Every view keeps the game's hooks, with the same data, its settings, sprites, skins and time. What changes:
//   - A viewport's size and target replace desc.size, and each viewport has the View_State of its own.
//   - A scene view draws from its editor camera, keeps the IDs for the picks, has the debug layer in every mode, so a
//     selected perceiver shows what it perceives while the game plays, has no UI hook, and has the tools as its overlay. The Game view draws from desc.view, keeps the game's
//     keep_ids, has no debug layer and no overlay.
//   - Each takes its debug view, the features it turns off, its exposure offset and its quality choices from the
//     editor's settings for the viewport, over the game's: the debug view replaces a Lit one, the features join, the
//     offsets add.
//   - The frame's hidden entities are the game's and the editor's hidden ones together, in every view.
//   - The editor's previews and thumbnail join the game's, and draw in the own view, as the particle systems that the
//     editor plays join the game's.
//   - The own view's shading_stats is the game's or its viewport's.
// The game's extra views follow the viewports'. Without an editor, desc is returned as it is.
@(private)
plan_frame :: proc(e: ^Editor, w: ^ecs.World, desc: render.Frame_Desc, views: []Frame_Viewport, base: render.Quality, caps: render.Caps) -> (out: render.Frame_Desc) {
	out = desc
	if !active(e) {
		return
	}
	out.hidden = hidden_together(e, w, desc.hidden)
	out.previews = joined(e, desc.previews, previews(e))
	out.playing = joined(e, desc.playing, playing(e))
	if len(views) == 0 {
		out.no_debug = desc.no_debug || !debug_shown(e)
		return
	}
	extras := make([dynamic]render.Extra_View, e.platform.frame_allocator)
	for v, i in views {
		view := plan_view(e, w, desc, v, base, caps)
		if i == 0 {
			render.use_view(&out, view)
			out.shading_stats = desc.shading_stats || render_overrides(e, v.viewport).shading_stats
		} else {
			append(&extras, view)
		}
	}
	append(&extras, ..desc.extra_views)
	out.extra_views = extras[:]
	return
}

// plan_view describes a viewport's view of the game's frame.
@(private = "file")
plan_view :: proc(e: ^Editor, w: ^ecs.World, desc: render.Frame_Desc, v: Frame_Viewport, base: render.Quality, caps: render.Caps) -> render.Extra_View {
	allocator := e.platform.frame_allocator
	overrides := render_overrides(e, v.viewport)
	scene := v.kind == .Scene
	view := render.Extra_View {
		view            = v.view.? or_else desc.view,
		size            = v.size,
		target          = v.target,
		state           = v.state,
		settings        = desc.settings,
		keep_ids        = scene || desc.keep_ids,
		no_debug        = !scene || desc.no_debug,
		debug_view      = overrides.debug_view != .Lit ? overrides.debug_view : desc.debug_view,
		disable         = desc.disable + overrides.disable,
		exposure_offset = desc.exposure_offset + overrides.exposure_offset,
		hooks           = desc.hooks,
		overlay         = desc.overlay,
	}
	// Always the quality itself, as a view without one takes the own view's, which is another viewport's.
	game := desc.quality != nil ? desc.quality^ : base
	quality, _ := viewport_quality(e, game, caps, v.viewport)
	view.quality = new_clone(quality, allocator)
	if scene {
		view.hooks.ui = nil
		view.overlay = {new_clone(Tools{e, w, v.viewport}, allocator), tools_overlay}
		// An orthographic scene view's camera stands back from what it shows, by a distance that means nothing, so the
		// fog between them would hide the scene.
		if render.is_orthographic(view.view) {
			view.disable += {.Fog}
		}
	}
	return view
}

// tools_overlay adds the editor's tools to a scene view: its pick, and while editing its icons, outline and gizmo.
@(private = "file")
tools_overlay :: proc(f: ^render.Frame, data: rawptr) {
	t := (^Tools)(data)
	add_viewport_passes(t.e, f.graph, t.w, {viewport = t.viewport, view = f.view, size = f.size, output_size = f.output_size, target = f.debug, ids = f.ids, depth = f.depth})
}

// hidden_together is the game's hidden entities and the editor's, a bit for each slot. With only one, it is that one.
@(private = "file")
hidden_together :: proc(e: ^Editor, w: ^ecs.World, game: []u32) -> []u32 {
	editors := visibility(e, w).hidden
	if len(editors) == 0 {
		return game
	}
	if len(game) == 0 {
		return editors
	}
	bits := make([]u32, max(len(game), len(editors)), e.platform.frame_allocator)
	for word, i in game {
		bits[i] |= word
	}
	for word, i in editors {
		bits[i] |= word
	}
	return bits
}

// joined is the game's list and the editor's, the game's first, in frame memory unless one is empty.
@(private = "file")
joined :: proc(e: ^Editor, game: []$T, editors: []T) -> []T {
	if len(editors) == 0 {
		return game
	}
	if len(game) == 0 {
		return editors
	}
	list := make([]T, len(game) + len(editors), e.platform.frame_allocator)
	copy(list, game)
	copy(list[len(game):], editors)
	return list
}
