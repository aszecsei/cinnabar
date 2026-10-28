package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// fake_sprite_pipelines gives the sprites' passes pipelines of fake bytecode, which the null backend takes.
@(private)
fake_sprite_pipelines :: proc(r: ^Renderer) {
	s := &r.sprites
	for p in ([]^Shader_Pipeline{&s.arguments, &s.tiles, &s.bin, &s.light, &s.moments, &s.shade}) {
		p.pipeline = r.platform.gpu_create_compute_pipeline({compute = {1}, label = "test sprite pass"})
	}
}

// Sprite_Case is a frame of sprite_frames_match_their_sprites: the CPU's sprites, and the room that a GPU pass reserves.
@(private = "file")
Sprite_Case :: struct {
	cpu:      bool,
	reserved: int,
}

@(test)
sprite_frames_match_their_sprites :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator             = virtual.arena_allocator(&arena),
		heap_allocator              = runtime.heap_allocator(),
		jobs_run                    = jobs.run,
		jobs_wait                   = jobs.wait,
		gpu_frame_target            = null.frame_target,
		gpu_submit                  = null.submit,
		gpu_upload                  = null.upload,
		gpu_create_texture          = null.create_texture,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_buffer           = null.create_buffer,
		gpu_destroy_buffer          = null.destroy_buffer,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.materials.defaults[.White] = platform.gpu_create_texture({size = {1, 1}, format = .RGBA8_Unorm, usage = {.Sampled}, label = "white"}, {255, 255, 255, 255})
	defer platform.gpu_destroy_texture(r.materials.defaults[.White])
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	defer sprites_destroy(&r.sprites, &platform)

	// A meter along x.
	camera := ecs.World_Position{{1 << 24, 0, 0}}
	sprites := []Sprite {
		{position = {}, size = 0.5, color = {1, 0.5, 0.25, 0.75}, softness = 0.1},
		{position = camera, size = 1, rotation = 0.5, uv_rect = {0.5, 0, 0.5, 0.5}},
	}
	cases := []Sprite_Case{{cpu = true}, {reserved = 100}, {cpu = true, reserved = 200}, {reserved = MAX_SPRITES}}
	for c in cases {
		for view in ([]Debug_View{.Lit, .Transparent_Overdraw}) {
			cache: Texture_Cache
			defer cache_destroy(&cache, &platform)
			g := begin(&platform, &cache)
			f := new(Frame, platform.frame_allocator)
			f^ = {renderer = r, graph = &g, size = {64, 32}, debug_view = view}
			f.view.position = camera
			f.lights = new(Light_Frame, platform.frame_allocator)
			f.shadows = new(Shadow_Frame, platform.frame_allocator)
			sf := new(Scene_Frame, platform.frame_allocator)
			f.scene_frame = sf
			sf.view_count = 1
			sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
			sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
			f.exposure = import_buffer(&g, exposure)
			frame_sprites := c.cpu ? sprites : nil

			// Until every sprite pipeline compiles, the frame has no sprites, and a GPU pass can reserve none.
			begin_sprites(f, frame_sprites)
			testing.expect(t, f.sprites == nil)
			_, reserved := reserve_sprites(f, 10)
			testing.expect(t, !reserved)
			r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test composite"})
			fake_sprite_pipelines(r)
			begin_sprites(f, frame_sprites)
			testing.expect(t, f.sprites != nil)
			testing.expect_value(t, has_sprites(f), c.cpu)
			sp := f.sprites
			if c.cpu {
				testing.expect_value(t, sp.cpu_count, 2)
				records := ([^]Sprite_Record)(raw_data(sp.cpu.data))[:2]
				// Relative to the camera, with the whole texture by default, and no texture until it is resident.
				testing.expect_value(t, records[0].position, [3]f32{-1, 0, 0})
				testing.expect_value(t, records[0].uv_rect, [4]f32{0, 0, 1, 1})
				testing.expect_value(t, records[0].texture, SPRITE_NO_TEXTURE)
				testing.expect_value(t, records[0].softness, 0.1)
				testing.expect_value(t, records[0].color, [4]f32{1, 0.5, 0.25, 0.75})
				testing.expect_value(t, records[0].size, 0.5)
				testing.expect_value(t, records[1].position, [3]f32{0, 0, 0})
				testing.expect_value(t, records[1].uv_rect, [4]f32{0.5, 0, 0.5, 0.5})
				testing.expect_value(t, records[1].texture, SPRITE_NO_TEXTURE)
			}

			f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
			f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
			if c.reserved > 0 {
				// A GPU pass appends its sprites after the CPU's, before the world pass.
				target, ok := reserve_sprites(f, c.reserved)
				testing.expect(t, ok)
				p := add_compute_pass(&g, "test particles", proc(_: ^Pass_Context) {}, f)
				write(&g, p, target.records)
				write(&g, p, target.count)
			}
			capacity := u32(min((c.cpu ? 2 : 0) + c.reserved, MAX_SPRITES))
			testing.expect_value(t, sp.capacity, capacity)
			p := add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, f)
			color(&g, p, f.scene, .Clear)
			depth(&g, p, f.depth, .Clear)
			add_transparency_passes(f)
			// Without transparent surfaces, the sprites still have the moments, the transparent pass's sum and the
			// composite, and the capacity sizes their bits, their buffers and their light.
			testing.expect(t, f.moments_zeroth != 0 && f.moments != 0)
			testing.expect_value(t, sp.words, (capacity + 31) / 32)
			testing.expect_value(t, sp.tiles, [2]u32{2, 1})
			rows := (capacity + SPRITE_LIGHT_COLUMNS - 1) / SPRITE_LIGHT_COLUMNS
			testing.expect(t, sp.light_size.x == SPRITE_LIGHT_COLUMNS * SPRITE_LIGHT_TEXELS && sp.light_size.y >= rows * SPRITE_LIGHT_TEXELS)
			testing.expect(t, r.sprites.screen_capacity >= int(capacity) && r.sprites.bin_capacity >= 2 * int(sp.words))
			p = add_render_pass(&g, "output", proc(_: ^Pass_Context) {}, f)
			read(&g, p, f.scene)
			if view == .Transparent_Overdraw {
				read(&g, p, f.moments_zeroth)
			}
			color(&g, p, import_texture(&g, null.frame_target(), .Color), .Discard)
			// The null backend checks every pipeline and barrier, and the indirect dispatches' arguments.
			testing.expectf(t, execute(&g), "the %v frame of %v did not execute", view, c)
			null.begin_frame({64, 32})
			destroy_shader_pipeline(&r.transparency_composite, &platform)
			s := &r.sprites
			for p in ([]^Shader_Pipeline{&s.arguments, &s.tiles, &s.bin, &s.light, &s.moments, &s.shade}) {
				destroy_shader_pipeline(p, &platform)
			}
		}
	}
}
