package render

import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Made_Samplers is what a fake platform's samplers were made with, and how many it destroyed.
@(private = "file")
Made_Samplers :: struct {
	descs:     [dynamic]gpu.Sampler_Desc,
	destroyed: int,
}

@(test)
texture_samplers_are_shared_and_capped :: proc(t: ^testing.T) {
	made: Made_Samplers
	made.descs = make([dynamic]gpu.Sampler_Desc, context.temp_allocator)
	context.user_ptr = &made
	platform := core.Platform_API {
		gpu_create_sampler = proc(desc: gpu.Sampler_Desc) -> gpu.Sampler {
			m := (^Made_Samplers)(context.user_ptr)
			append(&m.descs, desc)
			return {index = u32(len(m.descs)), generation = 1}
		},
		gpu_destroy_sampler = proc(sampler: gpu.Sampler) {
			(^Made_Samplers)(context.user_ptr).destroyed += 1
		},
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform

	// Textures that ask for the same sampler share it.
	first := texture_sampler(r, {wrap = .Clamp, anisotropy = 8})
	testing.expect_value(t, texture_sampler(r, {wrap = .Clamp, anisotropy = 8}), first)
	testing.expect_value(t, len(made.descs), 1)
	testing.expect_value(
		t,
		made.descs[0],
		gpu.Sampler_Desc {
			filter = .Linear,
			mip_filter = .Linear,
			address = .Clamp,
			anisotropy = 8,
			label = "texture sampler",
		},
	)

	// Nearest filtering takes no anisotropy, and an anisotropy between steps takes the one below.
	texture_sampler(r, {filter = .Nearest, mip_filter = .Nearest, wrap = .Mirror, anisotropy = 16})
	testing.expect_value(t, made.descs[1].anisotropy, 1)
	testing.expect_value(t, made.descs[1].filter, gpu.Filter.Nearest)
	testing.expect_value(t, made.descs[1].address, gpu.Address_Mode.Mirror)
	texture_sampler(r, {anisotropy = 6})
	testing.expect_value(t, made.descs[2].anisotropy, 4)

	// A cap makes them again under it.
	texture_samplers_set_cap(r, 2)
	testing.expect_value(t, made.destroyed, 3)
	texture_sampler(r, {wrap = .Clamp, anisotropy = 8})
	testing.expect_value(t, made.descs[3].anisotropy, 2)
	texture_samplers_set_cap(r, 2)
	testing.expect_value(t, made.destroyed, 3)
	texture_samplers_destroy(&r.texture_samplers, &platform)
	testing.expect_value(t, made.destroyed, 4)
}
