package render

import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Compute sprites (see docs/rendering/transparency.md#sprites): camera-facing quads that compute passes rasterize into
// moment-based transparency by screen tiles, in place of drawing them, after Köhler's "Practical Order Independent
// Transparency". A pass finds each tile's farthest opaque depth, one places each sprite on the screen and marks the
// tiles that it covers, and one lights an 8x8 grid of points on each. Then, at each pixel, one pass adds the optical
// depth and moments of its tile's sprites to the moments pass's, and after the transparent pass another adds their
// light, dimmed by the transmittance in front of each, to its sum. The composite then draws them with the
// moment-based surfaces, each in its place, without sorting and without blending a layer at a time.

SPRITE_TILES_SHADER :: #load("../content/shaders/sprite_tiles.hlsl.meta", string)
SPRITE_BIN_SHADER :: #load("../content/shaders/sprite_bin.hlsl.meta", string)
SPRITE_LIGHT_SHADER :: #load("../content/shaders/sprite_light.hlsl.meta", string)
SPRITE_MOMENTS_SHADER :: #load("../content/shaders/sprite_moments.hlsl.meta", string)
SPRITE_SHADE_SHADER :: #load("../content/shaders/sprite_shade.hlsl.meta", string)

// SPRITE_TILE, SPRITE_LIGHT_TEXELS, SPRITE_LIGHT_COLUMNS and SPRITE_NO_TEXTURE match sprites.hlsli. A tile is
// SPRITE_TILE pixels a side, and holds a bit for each sprite. A sprite's light is SPRITE_LIGHT_TEXELS texels a side in
// the light textures, which hold SPRITE_LIGHT_COLUMNS sprites a row.
SPRITE_TILE :: 32
SPRITE_LIGHT_TEXELS :: 8
SPRITE_LIGHT_COLUMNS :: 128
SPRITE_NO_TEXTURE :: max(u32)
// A frame draws at most this many sprites, the first ones of Frame_Desc.sprites.
MAX_SPRITES :: 65536
// The light textures: the light at each point, dimmed by the fog, and the fog's share of it, then the fog's own light.
SPRITE_LIGHT_FORMAT :: gpu.Format.RGBA16_Float
// The size of Screen_Sprite in sprites.hlsli.
SCREEN_SPRITE_SIZE :: 64
SPRITE_BIN_GROUP :: 64

// Sprite is a camera-facing square that the frame draws with the moment-based transparent surfaces (see
// Frame_Desc.sprites).
Sprite :: struct {
	position: ecs.World_Position,
	// Half its side, in meters.
	size:     f32,
	// Its turn about the view direction, in radians.
	rotation: f32,
	// Its linear color, which the light at it shades, and its opacity.
	color:    [4]f32,
	// The light that it gives, as a material's emission, which the opacity scales.
	emission: [3]f32,
	// How far in front of an opaque surface it starts to fade, in meters, so it does not cut a hard line where it
	// meets the surface; 0 cuts the line.
	softness: f32,
	// Its texture, whose colors tint its color and whose alpha scales its opacity, and the part of the texture that it
	// shows: the offset in xy and the size in zw, or all of it when zero, as a flipbook's frame. Without a texture, or
	// until the texture is resident, the sprite is a soft round puff.
	texture:  format.Guid,
	uv_rect:  [4]f32,
}

// Sprite_Record matches Sprite_Record in sprites.hlsli: a sprite, relative to the camera, with its texture's bindless
// index.
@(private)
Sprite_Record :: struct {
	position: [3]f32,
	size:     f32,
	color:    [4]f32,
	emission: [3]f32,
	rotation: f32,
	uv_rect:  [4]f32,
	texture:  u32,
	softness: f32,
	padding:  [2]u32,
}

// Sprites is the sprites' pipelines and the buffers that their passes share, in the Renderer. The buffers grow with
// the frames' sprites and sizes.
Sprites :: struct {
	tiles:           Shader_Pipeline,
	bin:             Shader_Pipeline,
	light:           Shader_Pipeline,
	moments:         Shader_Pipeline,
	shade:           Shader_Pipeline,
	// Where each sprite is on the screen (see Screen_Sprite in sprites.hlsli), each tile's farthest opaque depth, and
	// each tile's bits, a word for every 32 sprites.
	screen:          gpu.Buffer,
	tile_depths:     gpu.Buffer,
	bins:            gpu.Buffer,
	screen_capacity: int,
	tile_capacity:   int,
	bin_capacity:    int,
}

// Tiles_Push matches Push in sprite_tiles.hlsl.
@(private = "file")
Tiles_Push :: struct {
	depth:       u32,
	tile_depths: u32,
	bins:        u32,
	words:       u32,
	size:        [2]u32,
	tiles:       [2]u32,
}

// Bin_Push matches Bin_Push in sprite_bin.hlsl.
@(private = "file")
Bin_Push :: struct {
	records:        u32,
	records_offset: u32,
	count:          u32,
	screen:         u32,
	tile_depths:    u32,
	bins:           u32,
	words:          u32,
	padding:        u32,
	tiles:          [2]u32,
	scale:          [2]f32,
}

// Light_Push matches Light_Push in sprite_light.hlsl.
@(private = "file")
Light_Push :: struct {
	shadow_atlas:   u32,
	shadow_mask:    u32,
	fog:            u32,
	gi_diffuse:     u32,
	records:        u32,
	records_offset: u32,
	count:          u32,
	light:          u32,
	fog_light:      u32,
}

// Raster_Push matches Raster_Push in sprite_raster.hlsli.
@(private = "file")
Raster_Push :: struct {
	depth:          u32,
	screen:         u32,
	bins:           u32,
	words:          u32,
	tile_columns:   u32,
	records:        u32,
	records_offset: u32,
	moments_zeroth: u32,
	moments:        u32,
	accumulated:    u32,
	light:          u32,
	fog_light:      u32,
	light_sampler:  u32,
	padding:        u32,
	size:           [2]u32,
	light_texel:    [2]f32,
}

#assert(size_of(Sprite_Record) == 80 && size_of(Raster_Push) <= 128 && size_of(Bin_Push) <= 128)

// Sprite_Frame is what one frame's sprite passes need, in frame memory.
@(private)
Sprite_Frame :: struct {
	records:     gpu.Upload,
	count:       u32,
	// Each tile's words of bits, and the tiles across and down.
	words:       u32,
	tiles:       [2]u32,
	scale:       [2]f32,
	screen:      Buffer,
	tile_depths: Buffer,
	bins:        Buffer,
	light:       Texture,
	fog_light:   Texture,
	light_size:  [2]u32,
}

sprites_init :: proc(s: ^Sprites) {
	s.tiles = shader_pipeline(SPRITE_TILES_SHADER)
	s.bin = shader_pipeline(SPRITE_BIN_SHADER)
	s.light = shader_pipeline(SPRITE_LIGHT_SHADER)
	s.moments = shader_pipeline(SPRITE_MOMENTS_SHADER)
	s.shade = shader_pipeline(SPRITE_SHADE_SHADER)
}

sprites_destroy :: proc(s: ^Sprites, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&s.tiles, &s.bin, &s.light, &s.moments, &s.shade}) {
		destroy_shader_pipeline(p, platform)
	}
	for b in ([]gpu.Buffer{s.screen, s.tile_depths, s.bins}) {
		if b != {} {
			platform.gpu_destroy_buffer(b)
		}
	}
}

@(private)
sync_sprite_pipelines :: proc(r: ^Renderer, force: bool) {
	s := &r.sprites
	assets := r.residency.assets
	sync_compute_pipeline(&s.tiles, r.platform, assets, {label = "sprite tiles"}, force)
	sync_compute_pipeline(&s.bin, r.platform, assets, {label = "sprite bin"}, force)
	sync_compute_pipeline(&s.light, r.platform, assets, {label = "sprite light"}, force)
	sync_compute_pipeline(&s.moments, r.platform, assets, {label = "sprite moments"}, force)
	sync_compute_pipeline(&s.shade, r.platform, assets, {label = "sprite shade"}, force)
}

// sprites_ready is whether every pipeline that draws sprites is compiled, the transparency composite's included.
@(private)
sprites_ready :: proc(r: ^Renderer) -> bool {
	s := &r.sprites
	for p in ([]^Shader_Pipeline{&s.tiles, &s.bin, &s.light, &s.moments, &s.shade, &r.transparency_composite}) {
		if !pipeline_ready(r.platform, p) {
			return false
		}
	}
	return true
}

// begin_sprites uploads the frame's sprites, relative to the camera, and grows the buffers that their passes share. It
// runs after add_scene_passes, whose camera constants the passes read. Without sprites, or before their pipelines
// compile, Frame.sprites stays nil and the frame draws none.
@(private)
begin_sprites :: proc(f: ^Frame, sprites: []Sprite) {
	r := f.renderer
	if len(sprites) == 0 || f.scene_frame == nil || len(f.scene_frame.view_constants) == 0 || !sprites_ready(r) {
		return
	}
	platform := r.platform
	sprites := sprites
	if len(sprites) > MAX_SPRITES {
		log.warnf("render: %d sprites, of which only the first %d draw", len(sprites), MAX_SPRITES)
		sprites = sprites[:MAX_SPRITES]
	}
	upload, ok := platform.gpu_upload(len(sprites) * size_of(Sprite_Record), 16)
	if !ok {
		return
	}
	records := ([^]Sprite_Record)(raw_data(upload.data))[:len(sprites)]
	// Sprites come in runs that share a texture, such as an emitter's, so its lookup is kept from one to the next.
	texture: format.Guid
	index := u32(SPRITE_NO_TEXTURE)
	for s, i in sprites {
		if s.texture != texture {
			texture, index = s.texture, SPRITE_NO_TEXTURE
			if t, ready := resident_texture(&r.residency, s.texture); ready {
				index = gpu.read_index(t.texture)
			}
		}
		records[i] = {
			position = ecs.position_sub(s.position, f.view.position),
			size     = s.size,
			color    = s.color,
			emission = s.emission,
			rotation = s.rotation,
			uv_rect  = s.uv_rect != {} ? s.uv_rect : {0, 0, 1, 1},
			texture  = index,
			softness = s.softness,
		}
	}

	sf := new(Sprite_Frame, platform.frame_allocator)
	sf.records = upload
	sf.count = u32(len(sprites))
	sf.words = (sf.count + 31) / 32
	sf.tiles = (f.size + SPRITE_TILE - 1) / SPRITE_TILE
	sf.scale = projection_scale(f.view_projection)
	rows := (sf.count + SPRITE_LIGHT_COLUMNS - 1) / SPRITE_LIGHT_COLUMNS
	// The rows round up to a power of two, so the transient cache keeps the textures while the count changes.
	sf.light_size = {SPRITE_LIGHT_COLUMNS * SPRITE_LIGHT_TEXELS, next_power_of_two(rows) * SPRITE_LIGHT_TEXELS}

	s := &r.sprites
	tile_count := int(sf.tiles.x * sf.tiles.y)
	bin_count := tile_count * int(sf.words)
	if int(sf.count) > s.screen_capacity {
		platform.gpu_destroy_buffer(s.screen)
		s.screen_capacity = int(next_power_of_two(sf.count))
		s.screen = platform.gpu_create_buffer({size = u32(s.screen_capacity * SCREEN_SPRITE_SIZE), usage = {.Storage}, label = "screen sprites"}, nil)
	}
	if tile_count > s.tile_capacity {
		platform.gpu_destroy_buffer(s.tile_depths)
		s.tile_capacity = tile_count
		s.tile_depths = platform.gpu_create_buffer({size = u32(tile_count * 4), usage = {.Storage}, label = "sprite tile depths"}, nil)
	}
	if bin_count > s.bin_capacity {
		platform.gpu_destroy_buffer(s.bins)
		s.bin_capacity = bin_count
		s.bins = platform.gpu_create_buffer({size = u32(bin_count * 4), usage = {.Storage}, label = "sprite bins"}, nil)
	}
	f.sprites = sf
}

@(private = "file")
next_power_of_two :: proc(n: u32) -> u32 {
	p := u32(1)
	for p < n {
		p <<= 1
	}
	return p
}

// add_sprite_bin_passes adds the passes that place the sprites on the screen: each tile's farthest opaque depth and
// its cleared bits, then the bits of the sprites in front of it.
@(private)
add_sprite_bin_passes :: proc(f: ^Frame) {
	sf := f.sprites
	g := f.graph
	s := &f.renderer.sprites
	sf.screen = import_buffer(g, s.screen)
	sf.tile_depths = import_buffer(g, s.tile_depths)
	sf.bins = import_buffer(g, s.bins)
	p := add_compute_pass(g, "sprite tiles", run_sprite_tiles, f)
	read(g, p, f.depth)
	write(g, p, sf.tile_depths)
	write(g, p, sf.bins)
	p = add_compute_pass(g, "sprite bin", run_sprite_bin, f)
	read(g, p, sf.tile_depths)
	write(g, p, sf.screen)
	write(g, p, sf.bins)
}

// add_sprite_moments_pass adds the sprites' optical depth and moments to the moments pass's.
@(private)
add_sprite_moments_pass :: proc(f: ^Frame) {
	sf := f.sprites
	g := f.graph
	p := add_compute_pass(g, "sprite moments", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		run_sprite_raster(ctx, f.renderer.sprites.moments.pipeline, 0)
	}, f)
	read(g, p, f.depth)
	read(g, p, sf.screen)
	read(g, p, sf.bins)
	write(g, p, f.moments_zeroth)
	write(g, p, f.moments)
}

// add_sprite_shade_passes adds the sprites' light, then their colors, dimmed by what is in front of them, to the
// transparent pass's sum.
@(private)
add_sprite_shade_passes :: proc(f: ^Frame, accumulated: Texture) {
	sf := f.sprites
	g := f.graph
	sf.light = create_texture(g, {size = sf.light_size, format = SPRITE_LIGHT_FORMAT, label = "sprite light"})
	sf.fog_light = create_texture(g, {size = sf.light_size, format = SPRITE_LIGHT_FORMAT, label = "sprite fog light"})
	p := add_compute_pass(g, "sprite light", run_sprite_light, f)
	declare_lighting(f, p, opaque = false)
	write(g, p, sf.light)
	write(g, p, sf.fog_light)
	sh := new(Shade_Frame, f.renderer.platform.frame_allocator)
	sh^ = {frame = f, accumulated = accumulated}
	p = add_compute_pass(g, "sprite shade", proc(ctx: ^Pass_Context) {
		sh := (^Shade_Frame)(ctx.data)
		run_sprite_raster(ctx, sh.frame.renderer.sprites.shade.pipeline, sh.accumulated, sh.frame)
	}, sh)
	read(g, p, f.depth)
	read(g, p, f.exposure)
	read(g, p, sf.screen)
	read(g, p, sf.bins)
	read(g, p, f.moments_zeroth)
	read(g, p, f.moments)
	read(g, p, sf.light)
	read(g, p, sf.fog_light)
	write(g, p, accumulated)
}

// Shade_Frame is the shade pass's data: the frame and the transparent pass's sum, in frame memory.
@(private = "file")
Shade_Frame :: struct {
	frame:       ^Frame,
	accumulated: Texture,
}

@(private = "file")
run_sprite_tiles :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.sprites
	g := ctx.graph
	push := Tiles_Push {
		depth       = gpu.read_index(gpu_texture(g, f.depth)),
		tile_depths = gpu.write_index(gpu_buffer(g, sf.tile_depths)),
		bins        = gpu.write_index(gpu_buffer(g, sf.bins)),
		words       = sf.words,
		size        = f.size,
		tiles       = sf.tiles,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sprites.tiles.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {sf.tiles.x, sf.tiles.y, 1})
}

@(private = "file")
run_sprite_bin :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.sprites
	g := ctx.graph
	push := Bin_Push {
		records        = gpu.read_index(sf.records.buffer),
		records_offset = sf.records.offset,
		count          = sf.count,
		screen         = gpu.write_index(gpu_buffer(g, sf.screen)),
		tile_depths    = gpu.read_index(gpu_buffer(g, sf.tile_depths)),
		bins           = gpu.write_index(gpu_buffer(g, sf.bins)),
		words          = sf.words,
		tiles          = sf.tiles,
		scale          = sf.scale,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sprites.bin.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {(sf.count + SPRITE_BIN_GROUP - 1) / SPRITE_BIN_GROUP, 1, 1})
}

@(private = "file")
run_sprite_light :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.sprites
	g := ctx.graph
	r := f.renderer
	white := gpu.read_index(r.materials.defaults[.White])
	push := Light_Push {
		shadow_atlas   = white,
		shadow_mask    = white,
		fog            = white,
		gi_diffuse     = white,
		records        = gpu.read_index(sf.records.buffer),
		records_offset = sf.records.offset,
		count          = sf.count,
		light          = gpu.write_index(gpu_texture(g, sf.light)),
		fog_light      = gpu.write_index(gpu_texture(g, sf.fog_light)),
	}
	if f.shadows.atlas != 0 {
		push.shadow_atlas = gpu.read_index(gpu_texture(g, f.shadows.atlas))
	}
	if f.fog_volume != 0 {
		push.fog = gpu.read_index(gpu_texture(g, f.fog_volume))
	}
	if f.gi_diffuse != 0 {
		push.gi_diffuse = gpu.read_index(gpu_texture(g, f.gi_diffuse))
	}
	gpu.cmd_set_pipeline(ctx.cb, r.sprites.light.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {min(sf.count, SPRITE_LIGHT_COLUMNS), (sf.count + SPRITE_LIGHT_COLUMNS - 1) / SPRITE_LIGHT_COLUMNS, 1})
}

// run_sprite_raster records the moments pass, without accumulated, or the shade pass, which adds to it. Both visit
// each pixel's sprites, with the camera's constants.
@(private = "file")
run_sprite_raster :: proc(ctx: ^Pass_Context, pipeline: gpu.Pipeline, accumulated: Texture, frame: ^Frame = nil) {
	f := frame != nil ? frame : (^Frame)(ctx.data)
	sf := f.sprites
	g := ctx.graph
	push := Raster_Push {
		depth          = gpu.read_index(gpu_texture(g, f.depth)),
		screen         = gpu.read_index(gpu_buffer(g, sf.screen)),
		bins           = gpu.read_index(gpu_buffer(g, sf.bins)),
		words          = sf.words,
		tile_columns   = sf.tiles.x,
		records        = gpu.read_index(sf.records.buffer),
		records_offset = sf.records.offset,
		size           = f.size,
	}
	if accumulated == 0 {
		push.moments_zeroth = gpu.write_index(gpu_texture(g, f.moments_zeroth))
		push.moments = gpu.write_index(gpu_texture(g, f.moments))
	} else {
		push.moments_zeroth = gpu.read_index(gpu_texture(g, f.moments_zeroth))
		push.moments = gpu.read_index(gpu_texture(g, f.moments))
		push.accumulated = gpu.write_index(gpu_texture(g, accumulated))
		push.light = gpu.read_index(gpu_texture(g, sf.light))
		push.fog_light = gpu.read_index(gpu_texture(g, sf.fog_light))
		push.light_sampler = gpu.sampler_index(f.renderer.post.sampler)
		push.light_texel = {1 / f32(sf.light_size.x), 1 / f32(sf.light_size.y)}
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, 8))
}
