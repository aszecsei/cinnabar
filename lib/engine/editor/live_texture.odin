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
		channels := link.live_texture_channels(m.usage)
		if m.size.x == 0 ||
		   m.size.y == 0 ||
		   len(m.texels) != int(m.size.x) * int(m.size.y) * channels {
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
		channels := link.live_texture_channels(live.usage)
		if !patch_texels(live.texels, live.size, m.origin, m.size, m.texels, channels) {
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
	case link.Live_Instances:
		guid := format.Guid(m.guid)
		buffer: [32]u8
		blob, ok := live_instances_blob(guid, m, e.platform.frame_allocator)
		if !ok {
			log.warnf(
				"editor: the live instance set %s has %d positions, %d rotations and %d scales, which are not of the same instances",
				format.guid_format(guid, &buffer),
				len(m.positions),
				len(m.rotations),
				len(m.scales),
			)
			return true
		}
		if e.assets != nil && !asset.set_live(e.assets, guid, blob) {
			log.warnf(
				"editor: the live instance set %s cannot take its asset's place",
				format.guid_format(guid, &buffer),
			)
		}
	case link.Release_Live_Instances:
		if e.assets != nil {
			asset.clear_live(e.assets, format.Guid(m.guid))
		}
	case link.Landscape_Overlay:
		e.session.brush = m
	case:
		return false
	}
	return true
}

// patch_texels copies a rectangle of texels, region texels at origin, into an image of size texels, each of channels
// values, and fails for one that is not inside it.
patch_texels :: proc(
	image: []u16,
	size, origin, region: [2]u32,
	texels: []u16,
	channels := 1,
) -> bool {
	if u64(origin.x) + u64(region.x) > u64(size.x) ||
	   u64(origin.y) + u64(region.y) > u64(size.y) ||
	   len(texels) != int(region.x) * int(region.y) * channels ||
	   len(image) != int(size.x) * int(size.y) * channels {
		return false
	}
	width := int(region.x) * channels
	for y in 0 ..< int(region.y) {
		row := ((int(origin.y) + y) * int(size.x) + int(origin.x)) * channels
		copy(image[row:][:width], texels[y * width:][:width])
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

// live_texture_blob is a texture blob of the texels with their box-filtered mips, clamped, in allocator: R16_Unorm for a
// height or a mask texture, and RGBA8_Unorm, a data texture, for a layer map.
live_texture_blob :: proc(
	guid: format.Guid,
	usage: link.Live_Texture_Usage,
	size: [2]u32,
	texels: []u16,
	allocator := context.allocator,
) -> []byte {
	mips: []byte
	mip_count: u32
	texture_format := format.Texture_Format.R16_Unorm
	texture_usage := format.Texture_Usage.Height
	switch usage {
	case .Height:
		mips, mip_count = format.texture_box_chain_r16(size, texels, context.temp_allocator)
	case .Mask:
		mips, mip_count = format.texture_box_chain_r16(size, texels, context.temp_allocator)
		texture_usage = .Mask
	case .Layers:
		rgba := make([]u8, len(texels), context.temp_allocator)
		for v, i in texels {
			rgba[i] = u8(v >> 8)
		}
		mips, mip_count = format.texture_box_chain_rgba8(size, rgba, context.temp_allocator)
		texture_format, texture_usage = .RGBA8_Unorm, .Data
	}
	return format.texture_write(
		{
			guid = guid,
			format = texture_format,
			usage = texture_usage,
			size = size,
			mip_count = mip_count,
			sampler = {wrap = .Clamp},
			mips = mips,
			source_path = "live",
		},
		allocator,
	)
}

// live_instances_blob is an instance set blob of a Live_Instances' poses, in their cells, as the cooker cooks an
// .instances file, in allocator. It fails when the poses' arrays are not of the same instances.
live_instances_blob :: proc(
	guid: format.Guid,
	m: link.Live_Instances,
	allocator := context.allocator,
) -> (
	blob: []byte,
	ok: bool,
) {
	count := len(m.positions) / 3
	if len(m.positions) != count * 3 ||
	   len(m.rotations) != count * 4 ||
	   len(m.scales) != count * 3 {
		return
	}
	instances := make([]format.Instance, count, context.temp_allocator)
	for &instance, i in instances {
		r := m.rotations[i * 4:][:4]
		rotation := linalg.normalize0(quaternion(x = r[0], y = r[1], z = r[2], w = r[3]))
		if rotation == {} {
			rotation = 1
		}
		instance = format.instance_pack(
			{
				position = {m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]},
				rotation = rotation,
				scale = {m.scales[i * 3], m.scales[i * 3 + 1], m.scales[i * 3 + 2]},
			},
			u32(i),
		)
	}
	contents := format.instance_cells(instances, context.temp_allocator)
	contents.guid = guid
	contents.name = "live"
	contents.source_path = "live"
	return format.instance_set_write(contents, allocator), true
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
