// The Texture sky's ambient light and sun (see docs/rendering/sky.md#texture). The ambient light is as sky_ambient in
// lib/engine/render/sky.odin takes the atmosphere's: the average light over the sphere, and twice the average of the
// light times its direction, from every texel of one small mip, weighted by the solid angle that it covers. The sun is
// in the brightest texel of that mip, and is found in a window around it of a finer mip: the direction of the texels
// there within half of the brightest one's luminance, weighted by their light, with the brightest luminance over the
// average. One group does it all, and the result goes to a buffer with the ticket that the CPU asked for, which it reads
// back. The texture is equirectangular or a cube: Sky_Texel reads a texel of either.
#include "sky_texture.hlsli"

#define THREADS 256
// The window around the small mip's brightest texel: this many of its texels on each side.
#define SUN_WINDOW 2

groupshared float4 sums[THREADS][4];

static const float3 LUMINANCE = float3(0.2126, 0.7152, 0.0722);

// reduce sums every thread's four values, and gives the sums to every thread.
void reduce(uint thread, float4 values[4], out float4 total[4]) {
	for (uint k = 0; k < 4; k++) {
		sums[thread][k] = values[k];
	}
	GroupMemoryBarrierWithGroupSync();
	for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
		if (thread < stride) {
			for (uint k = 0; k < 4; k++) {
				sums[thread][k] += sums[thread + stride][k];
			}
		}
		GroupMemoryBarrierWithGroupSync();
	}
	for (uint k = 0; k < 4; k++) {
		total[k] = sums[0][k];
	}
	GroupMemoryBarrierWithGroupSync();
}

// brightest gives every thread the largest of their luminances, with the index that each has with it.
float2 brightest(uint thread, float2 own) {
	sums[thread][0] = float4(own, 0, 0);
	GroupMemoryBarrierWithGroupSync();
	for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
		if (thread < stride && sums[thread + stride][0].x > sums[thread][0].x) {
			sums[thread][0] = sums[thread + stride][0];
		}
		GroupMemoryBarrierWithGroupSync();
	}
	float2 result = sums[0][0].xy;
	GroupMemoryBarrierWithGroupSync();
	return result;
}

// Sky_Texel is a texel's light, the unit direction that it holds, and a weight in proportion to its solid angle.
struct Sky_Texel {
	float3 color;
	float3 direction;
	float weight;
};

// equirect_texel reads a texel of an equirectangular mip of a size. Its solid angle is in proportion to the sine of its
// angle from straight up.
Sky_Texel equirect_texel(uint2 texel, uint mip, uint2 size) {
	float2 uv = (float2(texel) + 0.5) / float2(size);
	Sky_Texel result;
	result.color = cn_texture(push.texture).Load(int3(texel, mip)).rgb;
	result.direction = texture_direction(uv);
	result.weight = sin(uv.y * SKY_TEXTURE_PI);
	return result;
}

// cube_texel reads the texel of a cube's mip at a position on a face of a size. A position past the face's edge is on
// the next face. A cube has no Load, so it reads the texel's middle, where the filter gives the texel itself.
Sky_Texel cube_texel(uint face, int2 at, uint mip, uint size) {
	float2 p = (float2(at) + 0.5) / float(size) * 2 - 1;
	float3 d = cube_direction(face, p);
	Sky_Texel result;
	result.color = cn_texture_cube(push.texture).SampleLevel(cn_sampler(push.sampler_index), d, mip).rgb;
	result.direction = normalize(d);
	result.weight = cube_texel_weight(d);
	return result;
}

[numthreads(THREADS, 1, 1)]
void cs_main(uint thread : SV_GroupIndex) {
	bool is_cube = push.cube != 0;
	uint count = push.width * push.height * (is_cube ? 6 : 1);

	// The ambient light, and the small mip's brightest texel. A cube's index is across its faces, one after the other.
	float4 own[4] = {float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0)};
	float2 peak = float2(-1, 0);
	uint face_texels = push.width * push.height;
	for (uint i = thread; i < count; i += THREADS) {
		uint in_face = i % face_texels;
		int2 at = int2(in_face % push.width, in_face / push.width);
		// Not a ternary, which reads both sides: each reads the texture through the type of its own dimension.
		Sky_Texel texel;
		if (is_cube) {
			texel = cube_texel(i / face_texels, at, push.mip, push.width);
		} else {
			texel = equirect_texel(uint2(at), push.mip, uint2(push.width, push.height));
		}
		float3 light = texel.color * texel.weight;
		own[0] += float4(light, texel.weight);
		own[1].rgb += light * texel.direction.x;
		own[2].rgb += light * texel.direction.y;
		own[3].rgb += light * texel.direction.z;
		float luminance = dot(texel.color, LUMINANCE);
		if (luminance > peak.x) {
			peak = float2(luminance, i);
		}
	}
	float4 ambient[4];
	reduce(thread, own, ambient);
	uint coarse = uint(brightest(thread, peak).y);

	// The window of the finer mip around the brightest texel. On an equirectangular texture, it wraps across and stops
	// at the poles. On a cube, it stays on the brightest texel's face's plane, whose points past the edge are on the next
	// face.
	uint scale = max(push.sun_width / push.width, 1);
	uint coarse_face = coarse / face_texels;
	uint coarse_in_face = coarse % face_texels;
	int2 first = int2(int(coarse_in_face % push.width) - SUN_WINDOW, int(coarse_in_face / push.width) - SUN_WINDOW) * int(scale);
	uint side = (2 * SUN_WINDOW + 1) * scale;
	uint window = side * side;
	float sun_peak = 0;
	for (uint j = thread; j < window; j += THREADS) {
		int2 at = first + int2(j % side, j / side);
		if (is_cube) {
			sun_peak = max(sun_peak, dot(cube_texel(coarse_face, at, push.sun_mip, push.sun_width).color, LUMINANCE));
		} else if (at.y >= 0 && at.y < int(push.sun_height)) {
			uint2 wrapped = uint2((at.x + int(push.sun_width)) % int(push.sun_width), at.y);
			sun_peak = max(sun_peak, dot(equirect_texel(wrapped, push.sun_mip, uint2(push.sun_width, push.sun_height)).color, LUMINANCE));
		}
	}
	sun_peak = brightest(thread, float2(sun_peak, 0)).x;
	float4 sun[4] = {float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0)};
	for (uint k = thread; k < window; k += THREADS) {
		int2 at = first + int2(k % side, k / side);
		Sky_Texel texel;
		if (is_cube) {
			texel = cube_texel(coarse_face, at, push.sun_mip, push.sun_width);
		} else if (at.y >= 0 && at.y < int(push.sun_height)) {
			uint2 wrapped = uint2((at.x + int(push.sun_width)) % int(push.sun_width), at.y);
			texel = equirect_texel(wrapped, push.sun_mip, uint2(push.sun_width, push.sun_height));
		} else {
			continue;
		}
		float luminance = dot(texel.color, LUMINANCE);
		if (luminance >= sun_peak * 0.5) {
			sun[0].xyz += texel.direction * luminance * texel.weight;
		}
	}
	float4 sun_total[4];
	reduce(thread, sun, sun_total);

	if (thread == 0) {
		float weight = max(ambient[0].w, 1e-6);
		RWByteAddressBuffer output = cn_rw_buffer(push.output);
		output.Store4(0, asuint(float4(ambient[0].rgb / weight, 0)));
		for (uint axis = 1; axis < 4; axis++) {
			output.Store4(axis * 16, asuint(float4(ambient[axis].rgb * 2 / weight, 0)));
		}
		float average = max(dot(ambient[0].rgb / weight, LUMINANCE), 1e-6);
		float3 toward = sun_total[0].xyz;
		output.Store4(64, asuint(float4(dot(toward, toward) > 0 ? normalize(toward) : float3(0, 1, 0), sun_peak / average)));
		output.Store(80, push.ticket);
	}
}
