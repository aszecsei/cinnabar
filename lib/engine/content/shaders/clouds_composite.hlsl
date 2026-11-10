// The clouds over the sky (see docs/rendering/clouds.md#passes): a thread for each pixel of the scene, after the sky
// drew and before the fog over the background. It upsamples the cloud buffer with the four texels around the pixel,
// each weighted by how near its block's depth is to the pixel's, so the clouds stay crisp at the edges of what is in
// front of them, leaves the pixel alone where a surface is nearer than the clouds, and dims the scene by the clouds'
// transmittance and adds their light, pre-exposed. The sky's discs and stars are in the scene already, and are dimmed.
// The air between the camera and the clouds' mean distance dims their light and adds its own over the share of the
// pixel that they cover, from the aerial perspective volume.
#include "clouds_common.hlsli"
#include "aerial.hlsli"

// A pixel whose surface is nearer than this share of the clouds' mean distance keeps its surface.
static const float SURFACE_SHARE = 0.9;
// A texel whose block's depth differs from the pixel's view depth by this share of it has a weight of e^-8.
static const float DEPTH_SHARPNESS = 8;

// depth_weight is how much a cloud texel counts for a pixel: 1 when both show the sky, 0 when one does and the other
// does not, and otherwise falling with the difference of their view depths.
float depth_weight(float z, float zt) {
	if (z == 0 && zt == 0) {
		return 1;
	}
	if (z == 0 || zt == 0) {
		return 0;
	}
	float view = clouds.near / z;
	float view_t = clouds.near / zt;
	return exp(-DEPTH_SHARPNESS * abs(view - view_t) / view);
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= uint2(clouds.screen_size))) {
		return;
	}
	float z = cn_texture(push.depth).Load(int3(id.xy, 0)).r;
	Texture2D<float4> history = cn_texture(push.history);
	Texture2D<float4> distances = cn_texture(push.distance);
	int2 last = int2(clouds.size) - 1;
	float2 c = (float2(id.xy) + 0.5) / float(clouds.divisor) - 0.5;
	int2 c0 = int2(floor(c));
	float2 fr = c - float2(c0);
	float4 sum = 0;
	float mean_sum = 0;
	float w_sum = 0;
	int2 nearest = clamp(c0, 0, last);
	float nearest_difference = 1e30;
	[unroll] for (int i = 0; i < 4; i++) {
		int2 offset = int2(i & 1, i >> 1);
		int2 texel = clamp(c0 + offset, 0, last);
		float2 bilinear = lerp(1 - fr, fr, float2(offset));
		float zt = distances.Load(int3(texel, 0)).g;
		float w = bilinear.x * bilinear.y * depth_weight(z, zt);
		sum += history.Load(int3(texel, 0)) * w;
		mean_sum += distances.Load(int3(texel, 0)).r * w;
		w_sum += w;
		float difference = abs(zt - z);
		if (difference < nearest_difference) {
			nearest_difference = difference;
			nearest = texel;
		}
	}
	float4 cloud;
	float mean;
	if (w_sum < 1e-3) {
		// No texel agrees with the pixel's depth: the one whose block's depth is the closest stands alone.
		cloud = history.Load(int3(nearest, 0));
		mean = distances.Load(int3(nearest, 0)).r;
	} else {
		cloud = sum / w_sum;
		mean = mean_sum / w_sum;
	}
	if (z > 0) {
		float3 d = pixel_direction(id.xy);
		float surface = (clouds.near / z) / max(dot(d, clouds.forward.xyz), 1e-3);
		if (surface < mean * SURFACE_SHARE) {
			return;
		}
	}
	float T = saturate(cloud.a);
	float3 rgb = max(cloud.rgb, 0);
	if (T >= 0.999 && all(rgb == 0)) {
		return;
	}
	if (push.aerial != 0) {
		// What is behind the clouds, the sky's light or a far surface's, holds the air in front of them already, so only
		// the share of the pixel that they cover takes the air's light: scene * T + light * air.a + air.rgb * (1 - T).
		float2 uv = (float2(id.xy) + 0.5) / clouds.screen_size;
		float4 air = aerial_sample(cn_texture3d(push.aerial), cn_sampler(clouds.clamp_sampler), uv, mean);
		rgb = rgb * air.a + air.rgb * (1 - T);
	}
	RWTexture2D<float4> scene = cn_rw_texture(push.output);
	float exposure = cn_buffer(push.exposure).Load<float>(0);
	scene[id.xy] = float4(min(scene[id.xy].rgb * T + rgb * exposure, CLOUD_MAX_SCENE), 1);
}
