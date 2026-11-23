package editor

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// A scene view that looks through a camera of the cutscene preview (see docs/editor/cutscene-editor.md#cameras). The
// editor names the camera by its binding, because it has no entity for a spawned binding: the preview resolves it.
// frame_viewports draws the view from that camera's entity, and send_viewport_looks tells the editor what it drew.

// look_camera is the camera entity that a scene view looks through, and its binding's ID: the entity of the look's
// binding, or of the cut track's shot at the preview's time. It fails for the Editor_Camera, for a preview that is not
// the look's, and for an entity that is not a live Camera.
@(private)
look_camera :: proc(
	e: ^Editor,
	w: ^ecs.World,
	v: ^Viewport,
) -> (
	entity: ecs.Entity,
	binding: u32,
	ok: bool,
) {
	if v.look.source == .Editor_Camera {
		return
	}
	p := current_preview(e, v.look.ticket) or_return
	ev := &p.live.evaluation
	data, blob := cutscene.cutscene_data(e.cutscenes, ev) or_return
	bindings := format.cutscene_bindings(data, blob)
	switch v.look.source {
	case .Editor_Camera:
		return
	case .Binding:
		index := cutscene.binding_index(data, blob, cutscene.Binding_Id(v.look.binding)) or_return
		entity = cutscene.binding_entity(&ev.bindings, w, index) or_return
		binding = v.look.binding
	case .Cuts:
		shot := ev.cut.shown.(cutscene.Cut_Shot) or_return
		entity = shot.entity
		found := false
		for i in 0 ..< len(ev.bindings.states) {
			if bound, alive := cutscene.binding_entity(&ev.bindings, w, i);
			   alive && bound == entity && i < len(bindings) {
				binding, found = bindings[i].id, true
				break
			}
		}
		if !found || !ecs.is_alive(w, entity) {
			return
		}
	}
	if ecs.get(w, entity, render.Camera) == nil {
		return
	}
	return entity, binding, true
}

// look_shown is what a scene view that looks through a camera shows now: the camera's pose and lens, as the world
// shows them, or camera false when it draws its Editor_Camera.
@(private)
look_shown :: proc(e: ^Editor, w: ^ecs.World, i: int) -> link.Viewport_Look_Shown {
	v := &e.session.view.viewports[i]
	shown := link.Viewport_Look_Shown {
		viewport = u32(i),
		serial   = v.look.serial,
	}
	entity, binding, looks := look_camera(e, w, v)
	if !looks {
		return shown
	}
	view, ok := render.camera_view(w, entity)
	if !ok {
		return shown
	}
	shown.camera = true
	shown.binding = binding
	shown.position = view.position.raw
	r := view.rotation
	shown.rotation = {r.x, r.y, r.z, r.w}
	if p, perspective := view.projection.(render.Perspective); perspective {
		shown.vertical_fov = p.vertical_fov
	}
	if c := ecs.get(w, entity, render.Cinematic_Camera); c != nil {
		shown.focal_length = c.focal_length > 0 ? c.focal_length : render.DEFAULT_FOCAL_LENGTH
		shown.sensor = {
			c.sensor_width > 0 ? c.sensor_width : render.DEFAULT_SENSOR_WIDTH,
			c.sensor_height > 0 ? c.sensor_height : render.DEFAULT_SENSOR_HEIGHT,
		}
	}
	return shown
}

// Looks_Shown is what each scene view that looks through a camera showed, taken while the world is laid, before a poll
// lifts it, so the report carries the preview's pose and not the document's.
@(private)
Looks_Shown :: struct {
	views:   [MAX_VIEWPORTS]Maybe(link.Viewport_Look_Shown),
	preview: Maybe(link.Shown_Preview),
}

// capture_looks takes what the looking scene views and the preview show. Call it while the overrides are laid.
@(private)
capture_looks :: proc(e: ^Editor, w: ^ecs.World) -> (looks: Looks_Shown) {
	if e.session.overrides.layer != .Laid {
		return
	}
	for &v, i in e.session.view.viewports {
		if v.look.source != .Editor_Camera {
			looks.views[i] = look_shown(e, w, i)
		}
	}
	if p, open := &e.session.cutscene_previews.open.?; open {
		looks.preview = link.Shown_Preview {
			ticket = p.ticket,
			tick   = p.live.evaluation.time,
			blob   = p.modified if p.unsaved else 0,
			values = preview_values_serial(p),
		}
	}
	return
}

// send_viewport_looks tells the editor what each looking scene view drew, and what the world shows of the preview, when
// either changed since it last did.
@(private)
send_viewport_looks :: proc(e: ^Editor, looks: Looks_Shown, out: ^[dynamic]byte) {
	for &v, i in e.session.view.viewports {
		shown, has := looks.views[i].?
		if !has {
			continue
		}
		if sent, was := v.look_sent.?; was && sent == shown {
			continue
		}
		v.look_sent = shown
		link.write_message(out, shown)
	}
	p := &e.session.cutscene_previews
	if shown, has := looks.preview.?; has && shown != p.shown_sent {
		p.shown_sent = shown
		link.write_message(out, link.Cutscene_Preview_Shown{shown})
	}
}
