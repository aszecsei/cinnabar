package editor

import "core:log"
import "core:math/linalg"

import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/editor/link"

// Live textures (see docs/editor/landscape.md#live-textures): the height maps and hole masks that the landscape tools
// paint, which the game draws and collides with from memory in place of their cooked blobs. A Live_Texture gives the
// texels, which the game keeps; a Live_Texture_Region replaces a rectangle of them, which is a stroke's step. Each
// builds a blob with its mips, box-filtered, and puts it in the asset runtime in place of the cooked one, as a new
// version: the renderer streams it as it streams a recooked texture, and a height field collider is made again from
// it. A Release_Live_Texture loads the cooked blob again. The table is the session's, so a new connection drops it.

// Live_Texture is one live texture's texels, as the editor last gave them, in the host's heap.
@(private)
Live_Texture :: struct {
	usage:  link.Live_Texture_Usage,
	size:   [2]u32,
	texels: []u16,
}

@(private)
BRUSH_COLOR :: [4]f32{1, 0.75, 0.2, 1}
@(private)
BRUSH_INNER_COLOR :: [4]f32{1, 0.75, 0.2, 0.5}

// handle_live_texture_message handles a live texture's messages and the brush, and reports whether the message was
// one.
@(private)
handle_live_texture_message :: proc(e: ^Editor, message: link.Message) -> bool {
	#partial switch m in message {
	case link.Live_Texture:
		guid := format.Guid(m.guid)
		if m.size.x == 0 || m.size.y == 0 || len(m.texels) != int(m.size.x) * int(m.size.y) {
			buffer: [32]u8
			log.warnf(
				"editor: the live texture %s has %d texels, not %v",
				format.guid_format(guid, &buffer),
				len(m.texels),
				m.size,
			)
			return true
		}
		heap := e.platform.heap_allocator
		if live, found := e.session.live_textures[guid]; found {
			delete(live.texels, heap)
		}
		texels := make([]u16, len(m.texels), heap)
		copy(texels, m.texels)
		e.session.live_textures[guid] = {
			usage  = m.usage,
			size   = m.size,
			texels = texels,
		}
		publish_live_texture(e, guid)
	case link.Live_Texture_Region:
		guid := format.Guid(m.guid)
		buffer: [32]u8
		live, found := e.session.live_textures[guid]
		if !found {
			log.warnf(
				"editor: a stroke's step came for %s, which is not a live texture",
				format.guid_format(guid, &buffer),
			)
			return true
		}
		if !patch_texels(live.texels, live.size, m.origin, m.size, m.texels) {
			log.warnf(
				"editor: a stroke's step for %s, %v texels at %v, is not inside its %v",
				format.guid_format(guid, &buffer),
				m.size,
				m.origin,
				live.size,
			)
			return true
		}
		publish_live_texture(e, guid)
	case link.Release_Live_Texture:
		release_live_texture(e, format.Guid(m.guid))
	case link.Landscape_Overlay:
		e.session.brush = m
	case:
		return false
	}
	return true
}

// patch_texels copies a rectangle of texels, region texels at origin, into an image of size texels, and fails for one
// that is not inside it.
patch_texels :: proc(image: []u16, size, origin, region: [2]u32, texels: []u16) -> bool {
	if u64(origin.x) + u64(region.x) > u64(size.x) ||
	   u64(origin.y) + u64(region.y) > u64(size.y) ||
	   len(texels) != int(region.x) * int(region.y) ||
	   len(image) != int(size.x) * int(size.y) {
		return false
	}
	for y in 0 ..< int(region.y) {
		row := (int(origin.y) + y) * int(size.x) + int(origin.x)
		copy(image[row:][:region.x], texels[y * int(region.x):][:region.x])
	}
	return true
}

// release_live_textures lets every live texture's asset draw again, and hides the brush, for a new editor or the end.
@(private)
release_live_textures :: proc(e: ^Editor) {
	for guid, live in e.session.live_textures {
		delete(live.texels, e.platform.heap_allocator)
		if e.assets != nil {
			asset.clear_live(e.assets, guid)
		}
	}
	clear(&e.session.live_textures)
	e.session.brush = {}
}

@(private = "file")
release_live_texture :: proc(e: ^Editor, guid: format.Guid) {
	if live, found := e.session.live_textures[guid]; found {
		delete(live.texels, e.platform.heap_allocator)
		delete_key(&e.session.live_textures, guid)
	}
	if e.assets != nil {
		asset.clear_live(e.assets, guid)
	}
}

// publish_live_texture builds a live texture's blob in frame memory and puts it in place of its asset's.
@(private = "file")
publish_live_texture :: proc(e: ^Editor, guid: format.Guid) {
	if e.assets == nil {
		return
	}
	live := e.session.live_textures[guid]
	blob := live_texture_blob(guid, live.usage, live.size, live.texels, e.platform.frame_allocator)
	if !asset.set_live(e.assets, guid, blob) {
		buffer: [32]u8
		log.warnf(
			"editor: the live texture %s cannot take its asset's place",
			format.guid_format(guid, &buffer),
		)
	}
}

// live_texture_blob is a texture blob of R16_Unorm texels with their box-filtered mips, clamped, as a height or a mask
// texture, in allocator.
live_texture_blob :: proc(
	guid: format.Guid,
	usage: link.Live_Texture_Usage,
	size: [2]u32,
	texels: []u16,
	allocator := context.allocator,
) -> []byte {
	mips, mip_count := format.texture_box_chain_r16(size, texels, context.temp_allocator)
	return format.texture_write(
		{
			guid = guid,
			format = .R16_Unorm,
			usage = usage == .Height ? .Height : .Mask,
			size = size,
			mip_count = mip_count,
			sampler = {wrap = .Clamp},
			mips = mips,
			source_path = "live",
		},
		allocator,
	)
}

// draw_brush draws the landscape brush: its radius, and inside it, where its strength starts to fall off.
@(private)
draw_brush :: proc(e: ^Editor, d: ^debug.Draw) {
	b := e.session.brush
	if !b.visible || b.radius <= 0 {
		return
	}
	up := linalg.normalize0(b.up)
	if up == {} {
		up = {0, 1, 0}
	}
	across := abs(up.x) < 0.9 ? [3]f32{1, 0, 0} : [3]f32{0, 0, 1}
	u := linalg.normalize0(linalg.cross(up, across))
	v := linalg.cross(up, u)
	center := ecs.World_Position {
		raw = b.center,
	}
	debug.circle(d, center, u, v, b.radius, BRUSH_COLOR)
	inner := b.radius * (1 - clamp(b.falloff, 0, 1))
	if inner > 0 && inner < b.radius {
		debug.circle(d, center, u, v, inner, BRUSH_INNER_COLOR)
	}
	debug.line(d, center, ecs.position_offset(center, up * b.radius * 0.25), BRUSH_COLOR)
}
