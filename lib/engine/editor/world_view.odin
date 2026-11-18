package editor

import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/scene"
import "cinnabar:engine/streaming"

// The world view (see docs/editor/world-view.md#the-viewport): the bounds of the scenes of the world that the editor
// shows, each with a fainter box at its load distance, and the preview's position. The editor works out what each
// scene is, so these only draw.

// A scene's bounds: the editor's active scene, a scene that the preview or the game loads, and any other scene.
@(private = "file")
WORLD_ACTIVE_COLOR :: [4]f32{1, 0.55, 0.15, 1}
@(private = "file")
WORLD_LOADED_COLOR :: [4]f32{0.35, 1, 0.45, 1}
@(private = "file")
WORLD_SCENE_COLOR :: [4]f32{0.6, 0.6, 0.6, 0.5}
// The load distance's box is the bounds' color, this much as opaque.
@(private = "file")
WORLD_LOAD_ALPHA :: 0.35
// The preview's position, as a small sphere.
@(private = "file")
WORLD_PREVIEW_COLOR :: [4]f32{1, 1, 1, 1}
@(private = "file")
WORLD_PREVIEW_RADIUS :: 0.5

// handle_world_view keeps a World_View's scenes and its preview until the next one.
@(private)
handle_world_view :: proc(v: ^View, m: link.World_View) {
	clear(&v.world_scenes)
	append(&v.world_scenes, ..m.scenes)
	v.world_preview = nil
	if len(m.preview) > 0 {
		v.world_preview = ecs.World_Position {
			raw = m.preview[0].position,
		}
	}
}

// draw_world_view draws each scene that is not persistent as its bounds and a fainter box grown by its load distance.
// The policy measures the distance to the bounds, so the region that loads has round corners, inside that box.
@(private)
draw_world_view :: proc(e: ^Editor, d: ^debug.Draw) {
	v := &e.session.view
	for s in v.world_scenes {
		if s.persistent {
			continue
		}
		color := WORLD_SCENE_COLOR
		if s.previewed || s.loaded {
			color = WORLD_LOADED_COLOR
		}
		if s.active {
			color = WORLD_ACTIVE_COLOR
		}
		// The midpoint in raw units, so a scene far from the origin stays exact, and the half extents from it in f32.
		center: ecs.World_Position
		for axis in 0 ..< 3 {
			center.raw[axis] = s.min[axis] + (s.max[axis] - s.min[axis]) / 2
		}
		half := ecs.position_sub({raw = s.max}, center)
		debug.box(d, center, half, 1, color)
		if s.load_distance > 0 {
			faint := color
			faint.a *= WORLD_LOAD_ALPHA
			debug.box(d, center, half + s.load_distance, 1, faint)
		}
	}
	if at, ok := v.world_preview.?; ok {
		debug.sphere(d, at, WORLD_PREVIEW_RADIUS, WORLD_PREVIEW_COLOR)
	}
}

// send_streamed_scenes sends the scenes that the streaming policy has in when they changed since the session last sent
// them. A new session sends them at its first change, or at once when the policy has changed anything.
@(private)
send_streamed_scenes :: proc(e: ^Editor, out: ^[dynamic]byte) {
	if e.streaming == nil {
		return
	}
	changes := streaming.changes(e.streaming)
	if changes == e.session.streamed_sent {
		return
	}
	e.session.streamed_sent = changes
	world, loaded := streaming.loaded(e.streaming)
	scenes := make([]link.Streamed_Scene, len(loaded), e.platform.frame_allocator)
	for s, i in loaded {
		ready := false
		if e.scenes != nil {
			kind, found := scene.stage_of(e.scenes, s.number)
			ready = found && kind == .Ready
		}
		scenes[i] = link.Streamed_Scene {
			guid   = ([16]u8)(s.guid),
			number = s.number,
			ready  = ready,
		}
	}
	link.write_message(out, link.Streamed_Scenes{world = ([16]u8)(world), scenes = scenes})
}
