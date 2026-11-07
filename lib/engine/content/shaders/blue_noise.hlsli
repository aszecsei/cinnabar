// The spatiotemporal blue noise that tools/stbn makes (see docs/rendering/lighting-and-shadows.md#screen-space-reflections),
// which the ambient occlusion's searches and the screen-space reflections' rays sample: BLUE_NOISE_SLICES layers of
// BLUE_NOISE_SIZE x BLUE_NOISE_SIZE uniform 2D values. Each slice is blue noise over the screen, and each pixel's values
// are blue noise over the slices, so a frame's error is spread evenly over the screen and a pixel's error from frame to
// frame cancels out quickly in an average over time.
#ifndef BLUE_NOISE_HLSLI
#define BLUE_NOISE_HLSLI

#include "cinnabar.hlsli"

// Match BLUE_NOISE_SIZE and BLUE_NOISE_SLICES in lib/engine/render/blue_noise.odin.
static const uint BLUE_NOISE_SIZE = 128;
static const uint BLUE_NOISE_SLICES = 32;

// blue_noise is the noise texture's value at a pixel, which the texture repeats over the screen, in a slice: a frame
// takes the next slice to move the noise. Each value is in (0, 1).
float2 blue_noise(uint texture, uint2 pixel, uint slice) {
	return cn_texture_array(texture).Load(int4(pixel % BLUE_NOISE_SIZE, slice % BLUE_NOISE_SLICES, 0)).rg;
}

#endif
