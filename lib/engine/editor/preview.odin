package editor

import "core:math/linalg"

import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

// Material previews (see docs/rendering/materials.md#material-previews): the editor's material editor shows a material on a mesh,
// which the game draws into a shared target of its own with the renderer. A preview draws when what it shows changes,
// or every frame while its material reads the time, and a frame draws at most one preview, in turn. The same previews
// show effects (see docs/rendering/particles.md#previews), which play, so they draw in every frame that they can.

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
	// The cooked blob's version when the preview last looked, which a new cook changes.
	asset_version:   u32,
	// Whether the blob is an effect, once a look found it, and whether the look could not load it. Both last until
	// the blob changes, so a material that is not cooked is read and reported once, not in every frame.
	kind_known:      bool,
	effect:          bool,
	load_failed:     bool,
	// Draw at the next chance. The renderer sets complete when a drawing showed everything; until then, it draws again.
	dirty:           bool,
	complete:        bool,
	// The generation of the target that the editor was told of, and one to tell it of.
	told_generation: u32,
	told:            bool,
	announce:        link.Preview_Target,
	prefix:          [128]u8,
}

// handle_preview_message handles a preview's messages, and reports whether the message was one.
@(private)
handle_preview_message :: proc(e: ^Editor, message: link.Message) -> bool {
	#partial switch m in message {
	case link.Open_Preview:
		if m.id >= MAX_PREVIEWS {
			return true
		}
		p := &e.previews[m.id]
		material := format.Guid(m.material)
		if !p.open || p.material != material || p.unsaved != m.unsaved {
			free_preview_data(e, p)
		}
		p.open, p.material, p.unsaved, p.dirty = true, material, m.unsaved, true
	case link.Preview_Settings:
		if m.id >= MAX_PREVIEWS {
			return true
		}
		p := &e.previews[m.id]
		p.settings, p.has_settings, p.dirty = m, true, true
	case link.Close_Preview:
		if m.id < MAX_PREVIEWS {
			close_preview(e, int(m.id))
		}
	case:
		return false
	}
	return true
}

@(private)
close_preview :: proc(e: ^Editor, id: int) {
	p := &e.previews[id]
	if !p.open && p.data == nil {
		return
	}
	free_preview_data(e, p)
	p^ = {}
	e.platform.gpu_release_preview_target(id)
}

@(private = "file")
free_preview_data :: proc(e: ^Editor, p: ^Preview) {
	if p.data != nil {
		delete(p.data, e.platform.asset_allocator)
	}
	p.data, p.modified = nil, 0
	p.kind_known, p.load_failed = false, false
}

// close_previews closes every preview, as when the editor leaves.
@(private)
close_previews :: proc(e: ^Editor) {
	for id in 0 ..< MAX_PREVIEWS {
		close_preview(e, id)
	}
}

// previews gives the previews that this frame draws, for render.Frame_Desc.previews, in frame memory: at most one, the
// next in turn that needs drawing and whose target the editor is not still reading.
previews :: proc(e: ^Editor) -> []render.Preview_Desc {
	if !active(e) || e.assets == nil {
		return nil
	}
	for id in 0 ..< MAX_PREVIEWS {
		refresh_preview(e, &e.previews[id])
	}
	for n in 0 ..< MAX_PREVIEWS {
		id := (e.next_preview + n) % MAX_PREVIEWS
		p := &e.previews[id]
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
		e.next_preview = (id + 1) % MAX_PREVIEWS
		p.dirty, p.complete = false, false
		descs := make([]render.Preview_Desc, 1, e.platform.frame_allocator)
		descs[0] = preview_desc(p, id, target)
		descs[0].effect = is_effect(e, p)
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
			p.kind_known, p.load_failed = false, false
		}
	}
}

// is_effect is whether a preview shows an effect, by its blob's kind. The first look loads the cooked blob, which the
// renderer would load anyway. A blob that does not load is not tried again until refresh_preview sees it change,
// which it does once the renderer, which retries, loads it.
@(private = "file")
is_effect :: proc(e: ^Editor, p: ^Preview) -> bool {
	if p.kind_known {
		return p.effect
	}
	data := p.data
	if data == nil {
		h, loaded := asset.find(e.assets, p.material)
		if !loaded && !p.load_failed {
			h, loaded = asset.load(e.assets, p.material)
			p.load_failed = !loaded
		}
		if !loaded {
			return false
		}
		data, _ = asset.data(e.assets, h)
	}
	header, ok := format.blob_header(data)
	p.kind_known, p.effect = ok, ok && header.kind == .Effect
	return p.effect
}

// reads_time is whether the preview changes every frame: an effect, or a material that reads the frame's time.
@(private = "file")
reads_time :: proc(e: ^Editor, p: ^Preview) -> bool {
	if is_effect(e, p) {
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
	for &p in e.previews {
		if p.announce.prefix != "" {
			link.write_message(out, p.announce)
			p.announce = {}
		}
	}
}
