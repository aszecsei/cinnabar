// SMAA 1x (see docs/rendering/anti-aliasing.md#smaa): the reference implementation, vendor/smaa/SMAA.hlsl, as it is,
// with the bindless textures and samplers of the constants below. Each of its three passes is a pixel shader over a
// triangle that covers the screen, as the reference draws them: the edge pass discards the pixels without an edge,
// over a cleared target.
#ifndef SMAA_HLSLI
#define SMAA_HLSLI

#include "cinnabar.hlsli"

// Matches Smaa_Push in lib/engine/render/spatial_aa.odin. metrics is the size's inverse, then the size.
struct Push {
	uint color;
	uint edges;
	uint weights;
	uint area;
	uint search;
	uint linear_sampler;
	uint point_sampler;
	uint padding;
	float4 metrics;
};
CN_PUSH_CONSTANTS(Push, push);

#define SMAA_RT_METRICS push.metrics
#define SMAA_PRESET_HIGH
#define SMAA_CUSTOM_SL
#define SMAATexture2D(tex) Texture2D<float4> tex
#define SMAATexturePass2D(tex) tex
#define SMAASampleLevelZero(tex, coord) tex.SampleLevel(cn_sampler(push.linear_sampler), coord, 0)
#define SMAASampleLevelZeroPoint(tex, coord) tex.SampleLevel(cn_sampler(push.point_sampler), coord, 0)
#define SMAASampleLevelZeroOffset(tex, coord, offset) tex.SampleLevel(cn_sampler(push.linear_sampler), coord, 0, offset)
#define SMAASample(tex, coord) SMAASampleLevelZero(tex, coord)
#define SMAASamplePoint(tex, coord) SMAASampleLevelZeroPoint(tex, coord)
#define SMAASampleOffset(tex, coord, offset) SMAASampleLevelZeroOffset(tex, coord, offset)
#define SMAA_FLATTEN [flatten]
#define SMAA_BRANCH [branch]
#define SMAATexture2DMS2(tex) Texture2DMS<float4, 2> tex
#define SMAALoad(tex, pos, sample) tex.Load(pos, sample)
#include "SMAA.hlsl"

struct Varyings {
	float4 position : SV_Position;
};

// smaa_vertex is a vertex of the triangle that covers the screen, of three.
Varyings smaa_vertex(uint vertex_id) {
	float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
	Varyings o;
	o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	return o;
}

// smaa_uv is a pixel's center in UV.
float2 smaa_uv(Varyings i) {
	return i.position.xy * SMAA_RT_METRICS.xy;
}

#endif
