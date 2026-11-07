// What the Texture sky's shaders share (see docs/rendering/sky.md#texture): their push constants, and the mappings
// between a direction and the texture, equirectangular or a cube (sky_directions.hlsli).
#ifndef SKY_TEXTURE_HLSLI
#define SKY_TEXTURE_HLSLI

#include "cinnabar.hlsli"
#include "sky_directions.hlsli"

// Matches Sky_Texture_Push in lib/engine/render/sky_texture.odin: the background's frame textures, or the integral's
// mip, its size and its ticket, the mip that the sun is found in and its size, and for a cube, the flag and the sampler
// that reads it. A cube's sizes are a face's.
struct Sky_Texture_Push {
	uint texture;
	uint depth;
	uint output;
	uint exposure;
	uint mip;
	uint ticket;
	uint width;
	uint height;
	uint sun_mip;
	uint sun_width;
	uint sun_height;
	uint cube;
	uint sampler_index;
};
CN_PUSH_CONSTANTS(Sky_Texture_Push, push);

#endif
