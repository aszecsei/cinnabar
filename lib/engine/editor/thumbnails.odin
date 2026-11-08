package editor

import "core:math/linalg"

import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// Thumbnails (see docs/content/daemon-and-operations.md#thumbnails): a picture of a material, a mesh or a prefab, which the
// content browser asks for one at a time, while it shows. The game draws it with a preview of many meshes into a texture
// of its own, and asks the backend for a copy once the drawing is complete, which the host writes to the file that the
// editor named. It costs the game little: it loads what it needs a few milliseconds a frame, draws at most every other
// frame, and gives back what only thumbnails asked for when they stop.

// How long a frame spends making what a thumbnail needs resident, in seconds. At least one mesh goes each frame.
THUMBNAIL_TOUCH_SECONDS :: 0.004
// How many entries that only thumbnails asked for may stay across bakes, as a screen of them never leaves the time above.
THUMBNAIL_BAKED_MOST :: 512
// How long a thumbnail may take, for an asset that never becomes ready.
THUMBNAIL_TIMEOUT_SECONDS :: 30
// How long after the last thumbnail what only they asked for goes, so that a screen of tiles does not load it again and again.
THUMBNAIL_RELEASE_SECONDS :: 2
// The view of every thumbnail, from above and to the side, so that a solid shows three of its faces.
THUMBNAIL_YAW :: 0.65
THUMBNAIL_PITCH :: 0.45

Thumbnail_Phase :: enum u8 {
	Idle,
	// The cook that made the asset's new blob has not reached the game yet, so its picture would be the old one.
	Waiting,
	Touching,
	Drawing,
}

@(private)
Thumbnail :: struct {
	phase:      Thumbnail_Phase,
	id:         u32,
	kind:       link.Thumbnail_Kind,
	asset:      format.Guid,
	node:       u64,
	size:       [2]u32,
	// In the host's heap.
	items:      []render.Preview_Item,
	touched:    int,
	started:    f64,
	last:       f64,
	baked:      bool,
	complete:   bool,
	captured:   bool,
	draw_turn:  bool,
	target:     gpu.Texture,
	target_size: [2]u32,
	failed_id:  u32,
	failed:     string,
}

// handle_thumbnail_message starts a thumbnail, in place of one that the editor no longer waits for.
@(private)
handle_thumbnail_message :: proc(e: ^Editor, message: link.Message) -> bool {
	m, is_bake := message.(link.Bake_Thumbnail)
	if !is_bake {
		return false
	}
	t := &e.session.thumbnail
	free_thumbnail_items(e, t)
	t.phase = .Waiting
	t.id, t.kind, t.asset, t.node = m.id, m.kind, format.Guid(m.asset), m.node
	t.size = {u32(clamp(m.width, 16, 1024)), u32(clamp(m.height, 16, 1024))}
	t.started = e.platform.time_seconds()
	t.touched, t.complete, t.captured = 0, false, false
	return true
}

@(private = "file")
free_thumbnail_items :: proc(e: ^Editor, t: ^Thumbnail) {
	if t.items != nil {
		delete(t.items, e.platform.heap_allocator)
		t.items = nil
	}
}

@(private = "file")
fail_thumbnail :: proc(e: ^Editor, t: ^Thumbnail, reason: string) {
	t.failed_id, t.failed = t.id, reason
	free_thumbnail_items(e, t)
	t.phase = .Idle
}

@(private = "file")
thumbnail_rotation :: proc() -> quaternion128 {
	yaw := linalg.quaternion_angle_axis_f32(THUMBNAIL_YAW, {0, 1, 0})
	pitch := linalg.quaternion_angle_axis_f32(THUMBNAIL_PITCH, {1, 0, 0})
	return yaw * pitch
}

// face_thumbnail_mesh turns a flat mesh to the camera, once touching it has loaded its blob.
@(private = "file")
face_thumbnail_mesh :: proc(e: ^Editor, t: ^Thumbnail) {
	h, loaded := asset.find(e.assets, t.asset)
	if !loaded {
		return
	}
	data, _ := asset.data(e.assets, h)
	if blob, ok := format.mesh_view(data); ok {
		camera := linalg.quaternion128_mul_vector3(thumbnail_rotation(), [3]f32{0, 0, -1})
		t.items[0].pose.rotation = render.preview_facing(data, blob, camera)
	}
}

// thumbnail_items is what a thumbnail draws: a material on a sphere, a mesh by itself, or what a prefab's cooked entities
// draw. It is false when the asset cannot be read.
@(private = "file")
thumbnail_items :: proc(e: ^Editor, t: ^Thumbnail) -> (items: []render.Preview_Item, ok: bool) {
	heap := e.platform.heap_allocator
	switch t.kind {
	case .Material:
		item := render.Preview_Item {
			mesh = render.preview_mesh(.Sphere),
			pose = {rotation = 1, scale = 1},
		}
		for &slot in item.materials {
			slot = t.asset
		}
		items = make([]render.Preview_Item, 1, heap)
		items[0] = item
		return items, true
	case .Mesh:
		items = make([]render.Preview_Item, 1, heap)
		items[0] = {
			mesh = t.asset,
			pose = {rotation = 1, scale = 1},
		}
		return items, true
	case .Prefab:
		h, loaded := asset.find(e.assets, t.asset)
		if !loaded {
			h = asset.load(e.assets, t.asset) or_return
		}
		// Nothing else holds it, and what the prefab draws is all that a picture needs of it.
		defer if !loaded {
			asset.unload(e.assets, h)
		}
		data, _ := asset.data(e.assets, h)
		scene := format.scene_read(data, context.temp_allocator) or_return
		return render.prefab_preview_items(scene, t.node, heap), true
	}
	return
}

// thumbnail_preview moves the thumbnail on, and gives what the frame draws of it, if it is the thumbnail's turn.
@(private)
thumbnail_preview :: proc(e: ^Editor, others_waiting: bool) -> (desc: render.Preview_Desc, draw: bool) {
	t := &e.session.thumbnail
	now := e.platform.time_seconds()
	if t.phase == .Idle {
		if t.baked && now - t.last >= THUMBNAIL_RELEASE_SECONDS && e.renderer != nil {
			render.residency_release_baked(&e.renderer.residency)
			t.baked = false
		}
		return
	}
	if e.renderer == nil || e.assets == nil {
		return
	}
	t.last = now
	t.baked = true
	if now - t.started >= THUMBNAIL_TIMEOUT_SECONDS {
		fail_thumbnail(e, t, "it was not ready in time")
		return
	}
	switch t.phase {
	case .Idle:
	case .Waiting:
		if !asset.current(e.assets) {
			return
		}
		items, ok := thumbnail_items(e, t)
		if !ok {
			fail_thumbnail(e, t, "its blob cannot be read")
			return
		}
		if len(items) == 0 {
			if items != nil {
				delete(items, e.platform.heap_allocator)
			}
			fail_thumbnail(e, t, "it draws nothing")
			return
		}
		for &item in items {
			if render.is_live(&e.renderer.residency, item.mesh) {
				delete(items, e.platform.heap_allocator)
				// Its picture would show what is not saved, under the name of what is.
				fail_thumbnail(e, t, "a mesh that it draws is being edited")
				return
			}
		}
		if render.residency_baked_count(&e.renderer.residency) > THUMBNAIL_BAKED_MOST {
			render.residency_release_baked(&e.renderer.residency)
		}
		t.items = items
		t.phase = .Touching
		fallthrough
	case .Touching:
		// Loading a blob holds up the frame, so a large prefab's take many frames.
		for t.touched < len(t.items) {
			if !render.preview_has_room(e.renderer) {
				fail_thumbnail(e, t, "the renderer's tables are nearly full")
				return
			}
			render.preview_touch(e.renderer, &t.items[t.touched])
			t.touched += 1
			if e.platform.time_seconds() - now >= THUMBNAIL_TOUCH_SECONDS {
				break
			}
		}
		if t.touched < len(t.items) {
			return
		}
		if t.kind == .Mesh {
			face_thumbnail_mesh(e, t)
		}
		t.phase = .Drawing
		fallthrough
	case .Drawing:
		if t.complete && t.captured {
			free_thumbnail_items(e, t)
			t.phase = .Idle
			return
		}
		if render.resident_streaming(&e.renderer.residency) > 0 {
			return
		}
		// A mesh that failed does not hold up what else there is, but with nothing to draw there is no picture to keep.
		drawable := false
		for &item in t.items {
			if !render.resident_failed(&e.renderer.residency, item.mesh) {
				drawable = true
				break
			}
		}
		if !drawable {
			fail_thumbnail(e, t, "what it draws could not be loaded")
			return
		}
		// Previews that play every frame share the frame with it.
		t.draw_turn = !t.draw_turn
		if others_waiting && !t.draw_turn {
			return
		}
		if t.target == {} || t.target_size != t.size {
			if t.target != {} {
				e.platform.gpu_destroy_texture(t.target)
			}
			t.target = e.platform.gpu_create_texture({size = t.size, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "thumbnail"}, nil)
			t.target_size = t.size
		}
		return render.Preview_Desc {
				target = t.target,
				size = t.size,
				rotation = thumbnail_rotation(),
				items = t.items,
				capture = t.id,
				complete = &t.complete,
				captured = &t.captured,
			},
			true
	}
	return
}

// send_thumbnail_failed tells the editor of a thumbnail that cannot be made.
@(private)
send_thumbnail_failed :: proc(e: ^Editor, out: ^[dynamic]byte) {
	t := &e.session.thumbnail
	if t.failed != "" {
		link.write_message(out, link.Thumbnail_Failed{id = t.failed_id, reason = t.failed})
		t.failed = ""
	}
}

// close_thumbnail lets go of the thumbnail and its texture, as when the editor leaves.
@(private)
close_thumbnail :: proc(e: ^Editor) {
	t := &e.session.thumbnail
	free_thumbnail_items(e, t)
	t.phase = .Idle
	t.failed = ""
	if t.target != {} {
		e.platform.gpu_destroy_texture(t.target)
		t.target = {}
		t.target_size = {}
	}
	if t.baked && e.renderer != nil {
		render.residency_release_baked(&e.renderer.residency)
		t.baked = false
	}
}
