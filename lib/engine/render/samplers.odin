package render

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"

// The anisotropies that a texture's sampler takes: 1, 2, 4, 8 and 16. A texture that asks for another takes the one
// below it.
@(private = "file")
ANISOTROPY_STEPS :: 5

// Texture_Samplers are the samplers that texture assets ask for (see format.Texture_Sampler and
// docs/content/kinds/textures.md#textures), each made at its first use. The quality's texture_anisotropy caps their
// anisotropy. They are handles only, so a code reload keeps them.
Texture_Samplers :: struct {
	samplers: [format.Texture_Wrap][format.Texture_Filter][format.Texture_Filter][ANISOTROPY_STEPS]gpu.Sampler,
	// The most anisotropy that a sampler takes. 0 is no cap.
	cap:      u8,
}

// sampler_anisotropy is the anisotropy that a texture's sampler takes under a cap, a power of 2 from 1 to 16, and its
// step in ANISOTROPY_STEPS. Nearest filtering takes no anisotropy, which needs linear filtering.
sampler_anisotropy :: proc(s: format.Texture_Sampler, cap: u8) -> (anisotropy: u8, step: int) {
	anisotropy = max(s.anisotropy, 1)
	if cap > 0 {
		anisotropy = min(anisotropy, cap)
	}
	if s.filter == .Nearest {
		anisotropy = 1
	}
	for step < ANISOTROPY_STEPS - 1 && 2 << uint(step) <= int(anisotropy) {
		step += 1
	}
	return u8(1 << uint(step)), step
}

// texture_sampler is the bindless index of the sampler that a texture asks for, under the cap.
texture_sampler :: proc(r: ^Renderer, s: format.Texture_Sampler) -> u32 {
	ts := &r.texture_samplers
	_, step := sampler_anisotropy(s, ts.cap)
	slot := &ts.samplers[s.wrap][s.filter][s.mip_filter][step]
	if slot^ == {} {
		FILTER := [format.Texture_Filter]gpu.Filter {
			.Linear  = .Linear,
			.Nearest = .Nearest,
		}
		ADDRESS := [format.Texture_Wrap]gpu.Address_Mode {
			.Repeat = .Repeat,
			.Clamp  = .Clamp,
			.Mirror = .Mirror,
		}
		slot^ = r.platform.gpu_create_sampler(
			{
				filter = FILTER[s.filter],
				mip_filter = FILTER[s.mip_filter],
				address = ADDRESS[s.wrap],
				anisotropy = u8(1 << uint(step)),
				label = "texture sampler",
			},
		)
	}
	return gpu.sampler_index(slot^)
}

// texture_samplers_set_cap caps the samplers' anisotropy. A new cap destroys the samplers that it made, and the next
// frame's uses make them again: the material table and the sprites' records take their indices every frame.
texture_samplers_set_cap :: proc(r: ^Renderer, cap: u8) {
	if r.texture_samplers.cap == cap {
		return
	}
	texture_samplers_destroy(&r.texture_samplers, r.platform)
	r.texture_samplers.cap = cap
}

texture_samplers_destroy :: proc(ts: ^Texture_Samplers, platform: ^core.Platform_API) {
	for &by_filter in ts.samplers {
		for &by_mip in by_filter {
			for &by_anisotropy in by_mip {
				for &sampler in by_anisotropy {
					if sampler != {} {
						platform.gpu_destroy_sampler(sampler)
						sampler = {}
					}
				}
			}
		}
	}
}
