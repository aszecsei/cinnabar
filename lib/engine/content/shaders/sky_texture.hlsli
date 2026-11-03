// What the Texture sky's shaders share (see docs/rendering/sky.md#texture): their push constants, and the mappings
// between a direction and the texture, equirectangular or a cube.
#ifndef SKY_TEXTURE_HLSLI
#define SKY_TEXTURE_HLSLI

#include "cinnabar.hlsli"

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

// cube_direction is the direction, not of unit length, of a point of a cube's face, with x and y from -1 to 1 and y down
// the face. Past 1, it goes on to the direction past the face's edge, which is on the next face. It matches
// cube_direction in tools/cook/texture_layers.odin.
float3 cube_direction(uint face, float2 p) {
	switch (face) {
	case 0:
		return float3(1, -p.y, -p.x);
	case 1:
		return float3(-1, -p.y, p.x);
	case 2:
		return float3(p.x, 1, p.y);
	case 3:
		return float3(p.x, -1, -p.y);
	case 4:
		return float3(p.x, -p.y, 1);
	}
	return float3(-p.x, -p.y, -1);
}

// cube_texel_weight is in proportion to the solid angle of a cube's texel at a point of its face, whose direction is d:
// a texel farther from the face's middle is farther away and more slanted.
float cube_texel_weight(float3 d) {
	float length_squared = dot(d, d);
	return 1 / (length_squared * sqrt(length_squared));
}

#endif
