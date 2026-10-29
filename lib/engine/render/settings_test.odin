package render

import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"
import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

@(test)
the_frame_takes_its_settings_from_the_volumes_at_the_camera :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := core.Platform_API {
		frame_allocator = virtual.arena_allocator(&arena),
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	volume.register_components(&w.registry)
	register_components(&w.registry)
	r := new(Renderer)
	defer free(r)
	volume.register(&r.volumes, w)

	// Without volumes, every setting has its default, as a zero Frame_Desc had.
	s := resolve_settings(r, w, {})
	testing.expect_value(t, s.post.bloom_intensity, DEFAULT_BLOOM_INTENSITY)
	testing.expect_value(t, s.post.contrast, 1)
	testing.expect_value(t, s.sky.mode, Sky_Mode.Flat)
	testing.expect_value(t, s.sky.sky, DEFAULT_SKY_COLOR)
	testing.expect_value(t, s.sky.ground, DEFAULT_GROUND_COLOR)
	testing.expect_value(t, s.sky.ambient_intensity, 1)
	testing.expect_value(t, s.fog.density, 0)
	testing.expect_value(t, s.post.paper_white, 0)
	testing.expect_value(t, s.shadows, Shadow_Settings{distance = SHADOW_DISTANCE, split_lambda = SHADOW_SPLIT_LAMBDA})

	base := ecs.spawn(w)
	ecs.add(w, base, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, base, volume.Volume{shape = .Global})
	ecs.add(w, base, Environment{background = {true, {0.02, 0.02, 0.035}}})
	ecs.add(w, base, Fog{density = {true, 0.1}, base_height = {true, 2}})
	ecs.add(w, base, Shadows{distance = {true, 30}})
	// A box over part of the world turns bloom off and fogs less, and leaves the rest to the global volume.
	local := ecs.spawn(w)
	ecs.add(w, local, ecs.Transform{position = ecs.position_offset({}, {10, 0, 0}), rotation = 1, scale = 1})
	ecs.add(w, local, volume.Volume{shape = .Box, extents = {1, 1, 1}})
	ecs.add(w, local, Bloom{off = {true, true}})
	ecs.add(w, local, Fog{density = {true, 0.02}})

	s = resolve_settings(r, w, {})
	testing.expect_value(t, s.sky.background, [3]f32{0.02, 0.02, 0.035})
	testing.expect_value(t, s.fog.density, 0.1)
	testing.expect_value(t, s.shadows, Shadow_Settings{distance = 30, split_lambda = SHADOW_SPLIT_LAMBDA})
	testing.expect(t, !s.post.no_bloom)

	s = resolve_settings(r, w, ecs.position_offset({}, {10, 0, 0}))
	testing.expect(t, s.post.no_bloom)
	testing.expect_value(t, s.fog.density, 0.02)
	testing.expect_value(t, s.fog.base_height, 2)
	testing.expect_value(t, s.fog.albedo, [3]f32{1, 1, 1})

	// The editor's hidden entities give nothing.
	hidden := [1]u32{1 << ecs.entity_index(local)}
	s = resolve_settings(r, w, ecs.position_offset({}, {10, 0, 0}), hidden[:])
	testing.expect(t, !s.post.no_bloom)
}
