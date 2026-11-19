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
draw_frame :: proc(
	e: ^Editor,
	r: ^render.Renderer,
	w: ^ecs.World,
	desc: render.Frame_Desc,
) -> bool {
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
// A game that draws several views in rects of its window (see docs/rendering/frame.md#views-in-rects) shows them all in
// the Game view when it is the own view: its own view at its rect, scaled to the viewport, then its views in rects, before
// the scene views. Without a Game view first, they are dropped, and the own view fills its viewport. The game's extra
// views with targets of their own follow the viewports'. Without an editor, desc is returned as it is.
@(private)
plan_frame :: proc(
	e: ^Editor,
	w: ^ecs.World,
	desc: render.Frame_Desc,
	views: []Frame_Viewport,
	base: render.Quality,
	caps: render.Caps,
) -> (
	out: render.Frame_Desc,
) {
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
		if i > 0 {
			append(&extras, view)
			continue
		}
		// The Game view shows the game's whole layout: the game's own view in its rect, and the game's views in rects
		// first among the extra views, so that a scene view, not one of them, is what the views' limit leaves out.
		game_rect, in_rect := desc.rect.?
		if v.kind == .Game {
			view.cut = desc.cut
			if in_rect {
				view.rect, view.size = scale_rect(game_rect, desc.size, v.size)
			}
		}
		render.use_view(&out, view)
		out.shading_stats = desc.shading_stats || render_overrides(e, v.viewport).shading_stats
		if v.kind != .Game || !in_rect {
			continue
		}
		for ev in desc.extra_views {
			if ev.rect != nil {
				append(&extras, plan_game_extra(e, ev, game_rect.target_size, v, base, caps, desc.quality))
			}
		}
	}
	// The game's views in rects of its own view's target draw in the Game view alone: without it, they have no target.
	for ev in desc.extra_views {
		if ev.rect == nil {
			append(&extras, ev)
		}
	}
	out.extra_views = extras[:]
	return
}

// scale_rect gives a view's rect, and its size, in a viewport of size, for a game whose rect is of a target of the game's
// size. The game's window is the Game view's size (see docs/editor/viewport.md#views), so this is the same rect
// but for a frame in which the two differ. Each edge scales, so the game's views that share an edge still share it.
@(private = "file")
scale_rect :: proc(
	rect: render.Target_Rect,
	size, viewport: [2]u32,
) -> (
	scaled: render.Target_Rect,
	scaled_size: [2]u32,
) {
	target := [2]u64{u64(max(rect.target_size.x, 1)), u64(max(rect.target_size.y, 1))}
	edge :: proc(at: u32, target: u64, viewport: u32) -> u32 {
		return u32(u64(at) * u64(viewport) / target)
	}
	near := [2]u32{edge(rect.origin.x, target.x, viewport.x), edge(rect.origin.y, target.y, viewport.y)}
	far := rect.origin + size
	far = {edge(far.x, target.x, viewport.x), edge(far.y, target.y, viewport.y)}
	return {target_size = viewport, origin = near}, far - near
}

// plan_game_extra describes one of the game's views in a rect for the Game view: in the Game view's target, at its rect
// scaled to the viewport, with the viewport's debug view, features, exposure and quality over the view's own, as the Game
// view itself takes them.
@(private = "file")
plan_game_extra :: proc(
	e: ^Editor,
	ev: render.Extra_View,
	game_size: [2]u32,
	v: Frame_Viewport,
	base: render.Quality,
	caps: render.Caps,
	game_quality: ^render.Quality,
) -> render.Extra_View {
	overrides := render_overrides(e, v.viewport)
	view := ev
	view.target = {}
	game_rect := ev.rect.? or_else {}
	game_rect.target_size = game_size
	view.rect, view.size = scale_rect(game_rect, ev.size, v.size)
	view.no_debug = true
	if overrides.debug_view != .Lit {
		view.debug_view = overrides.debug_view
	}
	view.disable += overrides.disable
	view.exposure_offset += overrides.exposure_offset
	from := ev.quality != nil ? ev.quality^ : (game_quality != nil ? game_quality^ : base)
	quality, _ := viewport_quality(e, from, caps, v.viewport)
	view.quality = new_clone(quality, e.platform.frame_allocator)
	return view
}

// plan_view describes a viewport's view of the game's frame.
@(private = "file")
plan_view :: proc(
	e: ^Editor,
	w: ^ecs.World,
	desc: render.Frame_Desc,
	v: Frame_Viewport,
	base: render.Quality,
	caps: render.Caps,
) -> render.Extra_View {
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
	add_viewport_passes(
		t.e,
		f.graph,
		t.w,
		{
			viewport = t.viewport,
			view = f.view,
			size = f.size,
			output_size = f.output_size,
			target = f.debug,
			ids = f.ids,
			depth = f.depth,
		},
	)
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
