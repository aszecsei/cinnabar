package render

import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"

// The spatiotemporal blue noise that the ambient occlusion's searches and the screen-space reflections' rays sample,
// which tools/stbn makes (see docs/rendering/lighting-and-shadows.md#screen-space-reflections): BLUE_NOISE_SLICES layers
// of BLUE_NOISE_SIZE x BLUE_NOISE_SIZE uniform 2D values, each slice blue noise over space and each pixel's values blue
// noise over the slices. Match BLUE_NOISE_SIZE and BLUE_NOISE_SLICES in blue_noise.hlsli.
BLUE_NOISE_TEXTURE :: #load("../content/textures/stbn_vec2.png.meta", string)
BLUE_NOISE_SIZE :: 128
BLUE_NOISE_SLICES :: 32

// Blue_Noise is the noise texture, in the Renderer.
Blue_Noise :: struct {
	guid:    format.Guid,
	// The texture once it is resident, which the tests set.
	texture: gpu.Texture,
}

blue_noise_init :: proc(n: ^Blue_Noise) {
	n.guid, _ = format.meta_guid(BLUE_NOISE_TEXTURE)
}

// blue_noise is the noise texture, or 0 until it is resident. The texture is requested only by the frames whose passes
// sample it, and they skip those passes until it is resident.
@(private)
blue_noise :: proc(r: ^Renderer) -> gpu.Texture {
	n := &r.blue_noise
	if t, ready := resident_texture(&r.residency, n.guid, .D2_Array); ready {
		if t.size == {BLUE_NOISE_SIZE, BLUE_NOISE_SIZE} && t.layer_count == BLUE_NOISE_SLICES {
			n.texture = t.texture
		}
	}
	return n.texture
}
