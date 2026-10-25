// Ambient occlusion's temporal denoiser (see docs/rendering.md#ambient-occlusion): it averages gtao.hlsl's noisy
// result over the pixel's 3x3 neighbors at a similar depth, then blends that into the history, found by the velocity.
// The history holds the occlusion, the view depth it was found at and how many frames it averages; a history whose
// depth is not where this frame's point was last frame is discarded, so a surface that comes into view starts over.
#include "cinnabar.hlsli"

// Matches Denoise_Constants in lib/engine/render/ambient_occlusion.odin. previous maps a position relative to the
// camera, moved by the camera's motion, to last frame's clip space; its w is last frame's view depth.
struct Denoise_Constants {
	float4x4 previous;
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float4 view_model;
	uint raw;
	uint depth;
	uint stencil;
	uint velocity;
	uint history;
	uint output;
	uint valid;
	float max_frames;
	uint2 size;
	uint2 padding;
};
CN_PASS_CONSTANTS(Denoise_Constants, constants);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;
// A neighbor or a history counts while its view depth is within this share of the pixel's.
static const float DEPTH_TOLERANCE = 0.05;

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	if (any(id.xy >= constants.size)) {
		return;
	}
	int2 pixel = int2(id.xy);
	Texture2D<float4> depth_texture = cn_texture(constants.depth);
	float depth = depth_texture.Load(int3(pixel, 0)).r;
	if (depth <= 0) {
		cn_rw_texture(constants.output)[pixel] = float4(1, 0, 0, 1);
		return;
	}
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	float3 projection = view_model ? constants.view_model.xyz : constants.projection.xyz;
	float z = projection.z / depth;

	// The neighbors at a similar depth, weighted by a 3x3 tent.
	Texture2D<float4> raw = cn_texture(constants.raw);
	int2 last = int2(constants.size) - 1;
	float sum = 0;
	float total = 0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int2 p = clamp(pixel + int2(x, y), 0, last);
			float d = depth_texture.Load(int3(p, 0)).r;
			float near_enough = abs(projection.z / max(d, 1e-7) - z) <= DEPTH_TOLERANCE * z ? 1 : 0;
			float w = (x == 0 ? 2 : 1) * (y == 0 ? 2 : 1) * near_enough;
			sum += raw.Load(int3(p, 0)).r * w;
			total += w;
		}
	}
	float current = sum / max(total, 1e-5);

	float4 result = float4(current, z, 1, 1);
	if (constants.valid != 0) {
		float2 uv = (float2(pixel) + 0.5) / float2(constants.size);
		float2 previous_uv = uv - cn_texture(constants.velocity).Load(int3(pixel, 0)).rg;
		// Where this point was last frame, at what depth: the view model moves with the camera, so its depth stays.
		float expected = z;
		if (!view_model) {
			float2 ndc = uv * float2(2, -2) + float2(-1, 1);
			float2 xy = ndc / projection.xy * z;
			float3 p = constants.right.xyz * xy.x + constants.up.xyz * xy.y + constants.forward.xyz * z;
			expected = mul(constants.previous, float4(p, 1)).w;
		}
		if (all(previous_uv == saturate(previous_uv))) {
			int2 previous_pixel = min(int2(previous_uv * float2(constants.size)), last);
			float4 history = cn_texture(constants.history).Load(int3(previous_pixel, 0));
			if (abs(history.g - expected) <= DEPTH_TOLERANCE * expected) {
				float frames = min(history.b + 1, constants.max_frames);
				result = float4(lerp(history.r, current, 1 / frames), z, frames, 1);
			}
		}
	}
	cn_rw_texture(constants.output)[pixel] = result;
}
