package editor

import "base:runtime"
import "core:hash"
import "core:math/linalg"

import "cinnabar:core/gpu"
import "cinnabar:engine/anim"
import anim_graph "cinnabar:engine/anim/graph"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// Material previews (see docs/rendering/materials.md#material-previews): the editor's material editor shows a material on a mesh,
// which the game draws into a shared target of its own with the renderer. A preview draws when what it shows changes,
// or every frame while its material reads the time, and a frame draws at most one preview, in turn. The same previews
// show effects (see docs/rendering/particles.md#previews), which play, so they draw in every frame that they can, and
// animation graphs on a mesh (see docs/editor/animation-graph-editor.md#preview), which play apart from the world, whatever the
// editor's mode, and UI documents (see docs/editor/ui-editor.md#the-games-side), which draw no mesh.

MAX_PREVIEWS :: gpu.MAX_PREVIEW_TARGETS

// Preview is an open preview, by its ID. Its unsaved blob is in the host's asset allocator.
@(private)
Preview :: struct {
	open:            bool,
	material:        format.Guid,
	unsaved:         bool,
	settings:        link.Preview_Settings,
	has_settings:    bool,
	data:            []byte,
	modified:        i64,
	version:         u32,
	// The cooked blob's version when the preview last looked, which a new cook changes, or 0.
	asset_version:   u32,
	// What the blob shows, which preview_kind finds and forget_kind forgets when the blob changes.
	kind:            Preview_Kind,
	// A UI document's preview (see ui_preview.odin).
	ui_preview:      Ui_Preview,
	// An animation graph's play.
	play:            Graph_Play,
	// Draw at the next chance. The renderer sets complete when a drawing showed everything; until then, it draws again.
	dirty:           bool,
	complete:        bool,
	// The generation of the target that the editor was told of, and one to tell it of.
	told_generation: u32,
	told:            bool,
	announce:        link.Preview_Target,
	prefix:          [128]u8,
}

// Graph_Play is an animation graph's play in a preview, apart from any entity: its instance, when it last moved, and
// the hash of the view that the editor last got, or 0. A graph that could not pose, as with a clip's GUID that the
// content does not have, tries again at retry_at, so it does not report it in every frame. show and Restart_Preview
// start it over.
@(private)
Graph_Play :: struct {
	instance:  anim_graph.Instance,
	last_tick: f64,
	view_sent: u64,
	retry_at:  f64,
}

// Preview_Kind is what a preview's blob shows. Load_Failed is a look that could not load the cooked blob. It lasts
// until the blob changes, so a material that is not cooked is read and reported once, not in every frame.
@(private)
Preview_Kind :: enum u8 {
	Unknown,
	Load_Failed,
	Material,
	Effect,
	Animation_Graph,
	Ui,
}

// handle_preview_message handles a preview's messages, and reports whether the message was one.
@(private)
handle_preview_message :: proc(e: ^Editor, message: link.Message) -> bool {
	#partial switch m in message {
	case link.Open_Preview:
		if m.id >= MAX_PREVIEWS {
			return true
		}
		show(e, &e.session.previews[m.id], format.Guid(m.material), m.unsaved)
	case link.Preview_Settings:
		if m.id >= MAX_PREVIEWS {
			return true
		}
		p := &e.session.previews[m.id]
		p.settings, p.has_settings, p.dirty = m, true, true
	case link.Close_Preview:
		if m.id < MAX_PREVIEWS {
			close_preview(e, int(m.id))
		}
	case link.Set_Preview_Parameter:
		if m.id < MAX_PREVIEWS {
			p := &e.session.previews[m.id]
			if data := preview_graph_data(e, p); data != nil {
				if blob, ok := format.animation_graph_view(data); ok && blob.header.key == p.play.instance.key {
					set_instance_parameter(data, blob, &p.play.instance, m.name, m.value)
				}
			}
		}
	case link.Restart_Preview:
		if m.id < MAX_PREVIEWS {
			e.session.previews[m.id].play = {}
		}
	case link.Ui_Preview_Settings:
		if m.id < MAX_PREVIEWS {
			set_ui_preview_settings(e, &e.session.previews[m.id], m)
		}
	case:
		return false
	}
	return true
}

// show makes a preview show an asset, by its unsaved blob or its cooked one. It is the one place that a preview's
// state of what it shows is reset: another source forgets the blob that it last saw, and another asset also drops its
// UI document and its graph's play. An Open_Preview of what the preview already shows, as when the host links again,
// keeps them.
@(private = "file")
show :: proc(e: ^Editor, p: ^Preview, material: format.Guid, unsaved: bool) {
	if p.material != material {
		drop_ui_document(e, &p.ui_preview)
		p.play = {}
	}
	if !p.open || p.material != material || p.unsaved != unsaved {
		free_preview_data(e, p)
		p.asset_version = 0
	}
	p.open, p.material, p.unsaved, p.dirty = true, material, unsaved, true
}

@(private)
close_preview :: proc(e: ^Editor, id: int) {
	p := &e.session.previews[id]
	if !p.open && p.data == nil {
		return
	}
	free_preview_data(e, p)
	close_ui_preview(e, p)
	p^ = {}
	e.platform.gpu_release_preview_target(id)
	if e.renderer != nil {
		render.preview_release(e.renderer, id)
	}
}

@(private)
free_preview_data :: proc(e: ^Editor, p: ^Preview) {
	if p.data != nil {
		delete(p.data, e.platform.asset_allocator)
	}
	p.data, p.modified = nil, 0
	forget_kind(p)
}

// forget_kind forgets what a preview's blob shows, when the blob changes, so the next look finds it again.
@(private = "file")
forget_kind :: proc(p: ^Preview) {
	p.kind = .Unknown
}

// close_previews closes every preview, as when the editor leaves.
@(private)
close_previews :: proc(e: ^Editor) {
	for id in 0 ..< MAX_PREVIEWS {
		close_preview(e, id)
	}
	close_thumbnail(e)
}

// previews gives the previews that this frame draws, for render.Frame_Desc.previews, in frame memory: at most one, the
// next in turn that needs drawing and whose target the editor is not still reading.
previews :: proc(e: ^Editor) -> []render.Preview_Desc {
	if !active(e) || e.assets == nil {
		return nil
	}
	for id in 0 ..< MAX_PREVIEWS {
		refresh_preview(e, &e.session.previews[id])
	}
	// A preview that the user looks at comes first, but one that plays in every frame shares them with a thumbnail.
	playing := false
	for &p in e.session.previews {
		playing ||= p.open && p.has_settings && (p.dirty || !p.complete || reads_time(e, p = &p))
	}
	if thumbnail, draw := thumbnail_preview(e, playing); draw {
		descs := make([]render.Preview_Desc, 1, e.platform.frame_allocator)
		descs[0] = thumbnail
		return descs
	}
	for n in 0 ..< MAX_PREVIEWS {
		id := (e.session.next_preview + n) % MAX_PREVIEWS
		p := &e.session.previews[id]
		if !p.open || !p.has_settings || !(p.dirty || !p.complete || reads_time(e, p)) {
			continue
		}
		size := [2]u32{u32(max(p.settings.width, 1)), u32(max(p.settings.height, 1))}
		target, ok := e.platform.gpu_preview_target(id, size)
		if !ok {
			continue
		}
		if !p.told || target.generation != p.told_generation {
			copied := copy(p.prefix[:], target.prefix)
			p.announce = {id = u32(id), prefix = string(p.prefix[:copied]), generation = target.generation, width = i32(target.size.x), height = i32(target.size.y)}
			p.told, p.told_generation = true, target.generation
		}
		e.session.next_preview = (id + 1) % MAX_PREVIEWS
		p.dirty, p.complete = false, false
		descs := make([]render.Preview_Desc, 1, e.platform.frame_allocator)
		kind := preview_kind(e, p)
		descs[0] = kind == .Ui ? ui_preview_desc(e, p, id, target) : preview_desc(p, id, target)
		descs[0].effect = kind == .Effect
		if kind == .Animation_Graph {
			descs[0].animated = true
			descs[0].palette = play_animation_graph(e, p)
		}
		return descs
	}
	return nil
}

// refresh_preview notices a new unsaved blob in the cache's preview area, or a new cooked blob of the material.
@(private = "file")
refresh_preview :: proc(e: ^Editor, p: ^Preview) {
	if !p.open {
		return
	}
	if p.unsaved {
		if data, modified, changed := asset.preview_blob(e.assets, p.material, p.modified); changed {
			free_preview_data(e, p)
			p.data, p.modified = data, modified
			p.version += 1
			p.dirty = true
		}
		return
	}
	if h, loaded := asset.find(e.assets, p.material); loaded {
		if version := asset.version(e.assets, h); version != p.asset_version {
			p.asset_version, p.dirty = version, true
			forget_kind(p)
		}
	}
}

// preview_graph_data is the blob of the animation graph that a preview shows: its unsaved one, or its cooked one.
@(private = "file")
preview_graph_data :: proc(e: ^Editor, p: ^Preview) -> []byte {
	if !p.open || e.assets == nil {
		return nil
	}
	if preview_kind(e, p) != .Animation_Graph {
		return nil
	}
	if p.data != nil {
		return p.data
	}
	h, loaded := asset.find(e.assets, p.material)
	if !loaded {
		return nil
	}
	data, _ := asset.data(e.assets, h)
	return data
}

// play_animation_graph moves a preview's graph by the time since it last drew, and gives its pose. A graph can stand
// still for as long as another preview draws, and it does not leap when it comes back.
@(private = "file")
play_animation_graph :: proc(e: ^Editor, p: ^Preview) -> [][3][4]f32 {
	MAX_STEP :: 0.1
	data := preview_graph_data(e, p)
	if data == nil {
		return nil
	}
	now := e.platform.time_seconds()
	g := &p.play
	if now < g.retry_at {
		return nil
	}
	step := g.last_tick == 0 ? 0 : min(f32(now - g.last_tick), MAX_STEP)
	g.last_tick = now
	palette, _, ok := anim.preview_pose(e.assets, data, &g.instance, step, e.platform.frame_allocator)
	if !ok {
		g.retry_at = now + 1
		return nil
	}
	return palette
}

// send_preview_views tells the editor what each animation graph's preview plays, when it changed.
@(private)
send_preview_views :: proc(e: ^Editor, out: ^[dynamic]byte, allocator: runtime.Allocator) {
	for &p in e.session.previews {
		data := preview_graph_data(e, &p)
		if data == nil {
			continue
		}
		blob, ok := format.animation_graph_view(data)
		if !ok || blob.header.key != p.play.instance.key {
			continue
		}
		view: link.Animator_View
		instance_view(data, blob, &p.play.instance, p.material, &view, allocator)
		encoded := make([dynamic]byte, allocator)
		link.write_message(&encoded, view)
		h := max(hash.fnv64a(encoded[link.HEADER_SIZE:]), 1)
		if h != p.play.view_sent {
			p.play.view_sent = h
			append(out, ..encoded[:])
		}
	}
}

// preview_kind is what a preview's blob shows, by its kind. The first look loads the cooked blob, which the renderer
// would load anyway. A blob that does not load is not loaded again until refresh_preview sees it change, which it does
// once the renderer, which retries, loads it.
@(private)
preview_kind :: proc(e: ^Editor, p: ^Preview) -> Preview_Kind {
	if p.kind != .Unknown && p.kind != .Load_Failed {
		return p.kind
	}
	data := p.data
	if data == nil {
		h, loaded := asset.find(e.assets, p.material)
		if !loaded && p.kind != .Load_Failed {
			h, loaded = asset.load(e.assets, p.material)
			if !loaded {
				p.kind = .Load_Failed
			}
		}
		if !loaded {
			return p.kind
		}
		data, _ = asset.data(e.assets, h)
	}
	header, ok := format.blob_header(data)
	if !ok {
		return p.kind
	}
	#partial switch header.kind {
	case .Effect:
		p.kind = .Effect
	case .Animation_Graph:
		p.kind = .Animation_Graph
	case .Ui:
		p.kind = .Ui
	case:
		p.kind = .Material
	}
	return p.kind
}

// reads_time is whether the preview changes every frame: an effect, an animation graph, or a material that reads the
// frame's time.
@(private = "file")
reads_time :: proc(e: ^Editor, p: ^Preview) -> bool {
	if kind := preview_kind(e, p); kind == .Effect || kind == .Animation_Graph {
		return true
	}
	data := p.data
	if data == nil {
		h, loaded := asset.find(e.assets, p.material)
		if !loaded {
			return false
		}
		data, _ = asset.data(e.assets, h)
		if instance, is_instance := format.material_instance_view(data); is_instance {
			parent, parent_loaded := asset.find(e.assets, instance.material)
			if !parent_loaded {
				return false
			}
			data, _ = asset.data(e.assets, parent)
		}
	}
	blob, ok := format.material_view(data)
	return ok && .Reads_Time in blob.flags
}

// preview_desc is what the renderer draws of a preview. The camera orbits the mesh's middle: it turns about the
// world's up axis by the yaw, then tilts down by the pitch.
@(private = "file")
preview_desc :: proc(p: ^Preview, id: int, target: gpu.Preview_Target) -> render.Preview_Desc {
	s := p.settings
	yaw := linalg.quaternion_angle_axis_f32(s.yaw, {0, 1, 0})
	pitch := linalg.quaternion_angle_axis_f32(s.pitch, {1, 0, 0})
	mesh: format.Guid
	switch s.mesh {
	case .Sphere:
		mesh = render.preview_mesh(.Sphere)
	case .Cube:
		mesh = render.preview_mesh(.Cube)
	case .Plane:
		mesh = render.preview_mesh(.Plane)
	case .Asset:
		mesh = format.Guid(s.mesh_asset)
	}
	return {
		target = target.texture,
		size = target.size,
		id = id,
		material = p.material,
		data = p.data,
		version = p.version,
		mesh = mesh,
		rotation = yaw * pitch,
		distance = max(s.distance, 0.1),
		complete = &p.complete,
	}
}

// send_preview_targets tells the editor of each preview target that is new, or of a new generation.
@(private)
send_preview_targets :: proc(e: ^Editor, out: ^[dynamic]byte) {
	for &p in e.session.previews {
		if p.announce.prefix != "" {
			link.write_message(out, p.announce)
			p.announce = {}
		}
	}
}
