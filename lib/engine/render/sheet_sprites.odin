package render

import "core:log"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The sprite renderers (see docs/rendering/2d.md#sprite-renderers): a Sprite_Renderer draws a frame of a sprite sheet
// as a quad that faces the camera. Each view extracts the visible ones, sorts them by layer, by order and from the
// farthest to the nearest, and draws them in that order in one draw, over the world and the transparent surfaces. The
// compute sprites of sprites.odin, which the particles append, are another thing: squares that moment-based transparency
// orders.

@(private)
SHEET_SPRITE_SHADER :: #load("../content/shaders/sheet_sprite.hlsl.meta", string)
@(private)
SHEET_SPRITE_IDS_SHADER :: #load("../content/shaders/sheet_sprite_ids.hlsl.meta", string)

SPRITE_RENDERER_ID :: ecs.Component_Id(56)

// A view draws at most this many sprite renderers. The rest are left out, with a warning.
MAX_SHEET_SPRITES :: 65536

// Sprite_Renderer draws a frame of a sprite sheet at its entity's Transform, as a quad that faces the camera (see
// docs/rendering/2d.md#sprite-renderers). The frame is as large as its texels over the sheet's pixels_per_unit, times
// the Transform's x and y scales, and turns about the view's axis by the Transform's turn about its z.
Sprite_Renderer :: struct {
	sheet:      format.Guid `asset:"sprite_sheet"`,
	// The frame that shows while no animation plays: an index of the sheet's frames.
	frame:      u16,
	// The animation that plays: an index of the sheet's animations plus 1, and 0 for none. A script names it (see
	// Sprites.play in lib/engine/sprite).
	animation:  u16,
	// How far into the animation it is, in seconds, which the animate sprites system moves on while it plays.
	time:       f32 `editor:"read"`,
	// How fast the animation plays: 1 is its own rate.
	speed:      f32 `editor:"range=0,10"`,
	playing:    bool,
	// Multiplies the texture's color and its opacity.
	color:      [3]f32 `editor:"color"`,
	opacity:    f32 `editor:"range=0,1"`,
	// What it draws over: a sprite of a higher layer draws over one of a lower layer, then one of a higher order over
	// one of a lower order, then the nearer over the farther.
	layer:      i16,
	order:      i16,
	// Whether the scene's lights light it. An unlit sprite shows its colors as they are.
	lit:        bool,
	// Draw it with its pivot on a corner of the screen's pixels, which keeps pixel art's texels whole.
	pixel_snap: bool,
	flip_x:     bool,
	flip_y:     bool,
}

DEFAULT_SPRITE_RENDERER :: Sprite_Renderer {
	speed   = 1,
	playing = true,
	color   = 1,
	opacity = 1,
}

// Match SHEET_SPRITE_LIT and SHEET_SPRITE_SNAP in sheet_sprite.hlsli.
@(private)
SHEET_SPRITE_LIT :: 1
@(private)
SHEET_SPRITE_SNAP :: 2

// Sheet_Sprite_Record matches Sheet_Sprite_Record in sheet_sprite.hlsli: a sprite's quad relative to the camera, its
// frame of its texture, and its entity's ID.
@(private)
Sheet_Sprite_Record :: struct {
	center:  [3]f32,
	texture: u32,
	right:   [3]f32,
	sampler: u32,
	up:      [3]f32,
	id:      u32,
	uv_rect: [4]f32,
	color:   [4]f32,
	pivot:   [2]f32,
	flags:   u32,
	padding: u32,
}

// Sheet_Sprite_Push matches Sheet_Sprite_Push in sheet_sprite.hlsli.
@(private = "file")
Sheet_Sprite_Push :: struct {
	shadow_atlas:   u32,
	shadow_mask:    u32,
	fog:            u32,
	records:        u32,
	records_offset: u32,
	padding:        u32,
}

#assert(size_of(Sheet_Sprite_Record) == 96 && size_of(Sheet_Sprite_Push) <= 128)

// Sprite_Sheets is the sprite sheets that a reader has loaded, by GUID. The renderer has one, and so does what plays the
// sprites' animations (see lib/engine/sprite).
Sprite_Sheets :: struct {
	handles: map[format.Guid]asset.Handle,
}

// Sheet_Sprites is the sprite renderers' state between frames, in the Renderer: their extractor, their pipelines, the
// samplers of the sheets' filters, and the sheets that were drawn.
Sheet_Sprites :: struct {
	extract:  Extractor,
	pipeline: Shader_Pipeline,
	ids:      Shader_Pipeline,
	samplers: [format.Sprite_Filter]gpu.Sampler,
	sheets:   Sprite_Sheets,
}

// Sheet_Sprite_Frame is a view's sprites, in frame memory: their records in the upload ring, in the order that they
// draw.
@(private)
Sheet_Sprite_Frame :: struct {
	records: gpu.Upload,
	count:   u32,
}

// Sorted_Sheet_Sprite is a sprite with what it sorts by.
@(private)
Sorted_Sheet_Sprite :: struct {
	record: Sheet_Sprite_Record,
	layer:  i16,
	order:  i16,
	// Its distance along the view's axis.
	depth:  f32,
}

@(private)
SHEET_SPRITE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = {{format = SCENE_FORMAT, blend = .Premultiplied}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Greater_Equal,
	label         = "sheet sprites",
}

@(private)
SHEET_SPRITE_IDS_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors        = {{format = ID_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Greater_Equal,
	depth_write   = true,
	label         = "sheet sprite ids",
}

sheet_sprites_init :: proc(s: ^Sheet_Sprites, platform: ^core.Platform_API, w: ^ecs.World) {
	s.pipeline = shader_pipeline(SHEET_SPRITE_SHADER)
	s.ids = shader_pipeline(SHEET_SPRITE_IDS_SHADER)
	s.samplers[.Linear] = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, label = "sprite sampler"})
	s.samplers[.Nearest] = platform.gpu_create_sampler({filter = .Nearest, address = .Clamp, label = "sprite nearest sampler"})
	sprite_sheets_init(&s.sheets, platform)
	sheet_sprites_register(s, w)
}

// sheet_sprites_register makes the sprite renderers' extractor, in init and after a code reload.
sheet_sprites_register :: proc(s: ^Sheet_Sprites, w: ^ecs.World) {
	s.extract = extractor(w, {ecs.read(w, Sprite_Renderer)})
}

sheet_sprites_destroy :: proc(s: ^Sheet_Sprites, platform: ^core.Platform_API, assets: ^asset.Assets) {
	destroy_shader_pipeline(&s.pipeline, platform)
	destroy_shader_pipeline(&s.ids, platform)
	for sampler in s.samplers {
		platform.gpu_destroy_sampler(sampler)
	}
	sprite_sheets_destroy(&s.sheets, assets)
	s^ = {}
}

sprite_sheets_init :: proc(s: ^Sprite_Sheets, platform: ^core.Platform_API) {
	s.handles = make(map[format.Guid]asset.Handle, platform.heap_allocator)
}

// sprite_sheets_destroy gives back the sheets that were loaded.
sprite_sheets_destroy :: proc(s: ^Sprite_Sheets, assets: ^asset.Assets) {
	if assets != nil {
		for _, handle in s.handles {
			asset.unload(assets, handle)
		}
	}
	delete(s.handles)
	s^ = {}
}

@(private)
sync_sheet_sprite_pipelines :: proc(r: ^Renderer, force: bool) {
	s := &r.sheet_sprites
	assets := r.residency.assets
	sync_graphics_pipeline(&s.pipeline, r.platform, assets, {.Vertex, .Pixel}, SHEET_SPRITE_PIPELINE, force)
	sync_graphics_pipeline(&s.ids, r.platform, assets, {.Vertex, .Pixel}, SHEET_SPRITE_IDS_PIPELINE, force)
}

// any_sprite_renderers is whether the world has a Sprite_Renderer, and the pipeline to draw it with: a scene of sprites
// alone has no other draws, and still needs the camera's constants.
@(private)
any_sprite_renderers :: proc(r: ^Renderer, w: ^ecs.World) -> bool {
	s := &r.sheet_sprites
	if s.extract.query == {} || !pipeline_ready(r.platform, &s.pipeline) {
		return false
	}
	it := ecs.query_iter(w, s.extract.query)
	for view in ecs.query_next(&it) {
		if len(ecs.entities(view)) > 0 {
			return true
		}
	}
	return false
}

// has_sheet_sprites is whether the view draws sprite renderers, which test against the scene's depth.
@(private)
has_sheet_sprites :: proc(f: ^Frame) -> bool {
	return f.sheet_sprites != nil && f.sheet_sprites.count > 0
}

// sprite_sheet_blob gives a sheet's blob, which the first call loads. It is not ok when the sheet is not cooked, which
// the load says once, or when its blob is not a sprite sheet's.
sprite_sheet_blob :: proc(s: ^Sprite_Sheets, assets: ^asset.Assets, guid: format.Guid) -> (data: []byte, blob: ^format.Sprite_Sheet_Blob, ok: bool) {
	if guid == {} || assets == nil {
		return
	}
	handle, known := s.handles[guid]
	if !known {
		// A sheet that is not cooked is asked for once, as its load logs an error.
		handle, _ = asset.load(assets, guid)
		s.handles[guid] = handle
	}
	data = asset.data(assets, handle) or_return
	blob, ok = format.sprite_sheet_view(data)
	return
}

// sprite_frame is the frame of its sheet that a Sprite_Renderer shows: its animation's at its time, or its own. now, when
// it is given, is the time that the animation is at instead, for a sprite that plays while the world stands still.
sprite_frame :: proc(data: []byte, blob: ^format.Sprite_Sheet_Blob, sprite: Sprite_Renderer, now: Maybe(f32) = nil) -> (frame: format.Sprite_Frame, ok: bool) {
	frames := format.sprite_sheet_frames(data, blob)
	if len(frames) == 0 {
		return
	}
	index := int(sprite.frame)
	if sprite.animation != 0 {
		index, _ = format.sprite_sheet_frame_at(data, blob, int(sprite.animation) - 1, now.? or_else sprite.time)
	}
	return frames[min(index, len(frames) - 1)], true
}

// sheet_sprite_before orders the sprites: the layers from the lowest, then the orders from the lowest, then the depths from
// the farthest, so each draws over those before it.
@(private)
sheet_sprite_before :: proc(a, b: Sorted_Sheet_Sprite) -> bool {
	if a.layer != b.layer {
		return a.layer < b.layer
	}
	if a.order != b.order {
		return a.order < b.order
	}
	return a.depth > b.depth
}

// sheet_sprite_record is a sprite's record: its quad about its pivot, as large as its frame, turned to face the camera
// and about the view's axis as its pose turns about its own z, with its frame's part of the texture, flipped if it
// asks.
@(private)
sheet_sprite_record :: proc(sprite: Sprite_Renderer, pose: ecs.Transform, frame: format.Sprite_Frame, blob: ^format.Sprite_Sheet_Blob, view: View, texture, sampler, id: u32) -> Sheet_Sprite_Record {
	right, up, _ := view_axes(view)
	// The pose's own x, as the camera sees it, gives the turn.
	x := linalg.quaternion128_mul_vector3(pose.rotation, [3]f32{1, 0, 0})
	turn := [2]f32{linalg.dot(x, right), linalg.dot(x, up)}
	turn = linalg.length(turn) > 1e-6 ? linalg.normalize(turn) : {1, 0}
	size := [2]f32{f32(frame.rect.z), f32(frame.rect.w)} / blob.pixels_per_unit * [2]f32{abs(pose.scale.x), abs(pose.scale.y)}
	atlas := [2]f32{f32(blob.atlas_size.x), f32(blob.atlas_size.y)}
	uv := [4]f32{f32(frame.rect.x) / atlas.x, f32(frame.rect.y) / atlas.y, f32(frame.rect.z) / atlas.x, f32(frame.rect.w) / atlas.y}
	pivot := frame.pivot
	if sprite.flip_x {
		uv.x, uv.z, pivot.x = uv.x + uv.z, -uv.z, 1 - pivot.x
	}
	if sprite.flip_y {
		uv.y, uv.w, pivot.y = uv.y + uv.w, -uv.w, 1 - pivot.y
	}
	flags: u32
	if sprite.lit {
		flags |= SHEET_SPRITE_LIT
	}
	if sprite.pixel_snap {
		flags |= SHEET_SPRITE_SNAP
	}
	return {
		center  = ecs.position_sub(pose.position, view.position),
		texture = texture,
		right   = (right * turn.x + up * turn.y) * size.x,
		sampler = sampler,
		up      = (up * turn.x - right * turn.y) * size.y,
		id      = id,
		uv_rect = uv,
		color   = {sprite.color.r, sprite.color.g, sprite.color.b, clamp(sprite.opacity, 0, 1)},
		pivot   = pivot,
		flags   = flags,
	}
}

// begin_sheet_sprites extracts the view's sprite renderers into records in the upload ring, in the order that they draw,
// and leaves out those of hidden entities, those whose sheet or texture is not ready, and those that are clear. A
// sprite in playing plays its animation by the host's time while delta is 0, as the editor plays what it has selected.
// It runs after add_scene_passes, whose camera constants the pass reads.
@(private)
begin_sheet_sprites :: proc(f: ^Frame, w: ^ecs.World, hidden: []u32, playing: []ecs.Entity, delta: f32) {
	r := f.renderer
	s := &r.sheet_sprites
	platform := r.platform
	if !f.wants_sheet_sprites || f.scene_frame == nil || len(f.scene_frame.view_constants) <= VIEW_CAMERA {
		return
	}
	sorted := make([dynamic]Sorted_Sheet_Sprite, platform.frame_allocator)
	// Each sheet is looked up and checked once a view, however many sprites show it.
	Sheet :: struct {
		data: []byte,
		blob: ^format.Sprite_Sheet_Blob,
		ok:   bool,
	}
	sheets := make(map[format.Guid]Sheet, platform.frame_allocator)
	_, _, forward := view_axes(f.view)
	now := frame_time(r)
	left_out := 0
	it := ecs.query_iter(w, s.extract.query)
	for view in ecs.query_next(&it) {
		entities := ecs.entities(view)
		sprites := ecs.column(view, EXTRACT_TERMS, Sprite_Renderer)
		for e, i in entities {
			sprite := sprites[i]
			pose, shown := light_pose(w, view, i, hidden, e)
			if !shown || sprite.opacity <= 0 {
				continue
			}
			sheet, seen := sheets[sprite.sheet]
			if !seen {
				sheet.data, sheet.blob, sheet.ok = sprite_sheet_blob(&s.sheets, r.residency.assets, sprite.sheet)
				sheets[sprite.sheet] = sheet
			}
			if !sheet.ok {
				continue
			}
			data, blob := sheet.data, sheet.blob
			texture, ready := resident_texture(&r.residency, blob.atlas)
			if !ready {
				continue
			}
			at: Maybe(f32)
			if delta == 0 && slice_has(playing, e) {
				at = now * sprite.speed
			}
			frame, has_frame := sprite_frame(data, blob, sprite, at)
			if !has_frame {
				continue
			}
			if len(sorted) == MAX_SHEET_SPRITES {
				left_out += 1
				continue
			}
			record := sheet_sprite_record(sprite, pose, frame, blob, f.view, gpu.read_index(texture.texture), gpu.sampler_index(s.samplers[blob.filter]), entity_id(e))
			append(&sorted, Sorted_Sheet_Sprite{record = record, layer = sprite.layer, order = sprite.order, depth = linalg.dot(record.center, forward)})
		}
	}
	if left_out > 0 {
		log.warnf("render: %d sprite renderers, of which only the first %d draw", len(sorted) + left_out, MAX_SHEET_SPRITES)
	}
	if len(sorted) == 0 {
		return
	}
	slice.stable_sort_by(sorted[:], sheet_sprite_before)
	upload, ok := platform.gpu_upload(len(sorted) * size_of(Sheet_Sprite_Record), 16)
	if !ok {
		return
	}
	records := ([^]Sheet_Sprite_Record)(raw_data(upload.data))[:len(sorted)]
	for sprite, i in sorted {
		records[i] = sprite.record
	}
	sf := new(Sheet_Sprite_Frame, platform.frame_allocator)
	sf^ = {
		records = upload,
		count   = u32(len(sorted)),
	}
	f.sheet_sprites = sf
}

// add_sheet_sprite_pass adds the pass that draws the view's sprite renderers over the scene, after the transparent
// surfaces, tested against the scene's depth without writing it, so they cover each other in their own order.
@(private)
add_sheet_sprite_pass :: proc(f: ^Frame) {
	if !has_sheet_sprites(f) {
		return
	}
	g := f.graph
	p := add_render_pass(g, "sheet sprites", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		draw_sheet_sprites(ctx, f, f.renderer.sheet_sprites.pipeline.pipeline)
	}, f)
	color(g, p, f.scene, .Load)
	depth(g, p, f.depth, .Load)
	declare_lighting(f, p, opaque = false)
}

// add_sheet_sprite_id_pass adds the editor's pass of the sprite renderers' IDs and depth, wherever they are not clear,
// so its picking and its tools see them. It runs after post-processing, as the transparent surfaces' does.
@(private)
add_sheet_sprite_id_pass :: proc(f: ^Frame, keep_ids: bool) {
	if !keep_ids || !has_sheet_sprites(f) || !pipeline_ready(f.renderer.platform, &f.renderer.sheet_sprites.ids) {
		return
	}
	g := f.graph
	p := add_render_pass(g, "sheet sprite ids", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		draw_sheet_sprites(ctx, f, f.renderer.sheet_sprites.ids.pipeline)
	}, f)
	color(g, p, f.ids, .Load)
	depth(g, p, f.depth, .Load)
}

@(private = "file")
draw_sheet_sprites :: proc(ctx: ^Pass_Context, f: ^Frame, pipeline: gpu.Pipeline) {
	sf := f.sheet_sprites
	g := ctx.graph
	white := gpu.read_index(f.renderer.materials.defaults[.White])
	push := Sheet_Sprite_Push {
		shadow_atlas   = white,
		shadow_mask    = white,
		fog            = white,
		records        = gpu.read_index(sf.records.buffer),
		records_offset = sf.records.offset,
	}
	if f.shadows.atlas != 0 {
		push.shadow_atlas = gpu.read_index(gpu_texture(g, f.shadows.atlas))
	}
	if f.fog_volume != 0 {
		push.fog = gpu.read_index(gpu_texture(g, f.fog_volume))
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, sf.count * 6)
}
