// What the Texture sky's shaders share (see docs/rendering/sky.md#texture): their push constants, and the mapping
// between a direction and the equirectangular texture.
#ifndef SKY_TEXTURE_HLSLI
#define SKY_TEXTURE_HLSLI

#include "cinnabar.hlsli"

// Matches Sky_Texture_Push in lib/engine/render/sky_texture.odin: the background's frame textures, or the integral's
// mip, its size and its ticket, and the mip that the sun is found in and its size.
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
	uint padding;
};
CN_PUSH_CONSTANTS(Sky_Texture_Push, push);

static const float SKY_TEXTURE_PI = 3.14159265;

// texture_uv is where the texture holds the light from a direction: u is the azimuth from +z toward +x, which is the
// middle column at 0.5, and v is the angle from straight up, 0 at the top row.
float2 texture_uv(float3 d) {
	return float2(0.5 + atan2(d.x, d.z) / (2 * SKY_TEXTURE_PI), acos(clamp(d.y, -1, 1)) / SKY_TEXTURE_PI);
}

// texture_direction is the direction whose light a point of the texture holds.
float3 texture_direction(float2 uv) {
	float azimuth = (uv.x - 0.5) * 2 * SKY_TEXTURE_PI;
	float polar = uv.y * SKY_TEXTURE_PI;
	return float3(sin(polar) * sin(azimuth), cos(polar), sin(polar) * cos(azimuth));
}

#endif
