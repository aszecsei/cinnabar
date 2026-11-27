// The ray guide's Gi_Probes debug view (see docs/rendering/global-illumination.md#ray-guiding): a thread for each
// pixel, after the build. The screen is cut into blocks of GUIDE_VIEW_BLOCK pixels, and each block draws the walk that
// its center pixel's rays take: the 8 x 8 leaves of the octahedron of its cell, each as hot as the walk's chance of it
// at that pixel's normal, from blue at a sixteenth of an even share to red at sixteen times it, on a log scale, with the
// normal as a white dot. A block's border is its cell in a color of its own, as bright as the rays that the cell has
// learned from. A block whose center has no surface or no cell is grey.
#include "gi_restir_guide.hlsli"

static const int GUIDE_VIEW_BLOCK = 64;
static const int GUIDE_VIEW_BORDER = 4;

// guide_heat is a color for a value from 0 to 1: blue, cyan, green, yellow, red.
float3 guide_heat(float t) {
	t = saturate(t);
	float3 c = saturate(float3(t * 4 - 2, t < 0.5 ? t * 4 : 4 - t * 4, 2 - t * 4));
	return c;
}

[numthreads(8, 8, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	int2 pixel = int2(id.xy);
	if (any(pixel >= int2(constants.size))) {
		return;
	}
	int2 block = pixel / GUIDE_VIEW_BLOCK;
	int2 q = pixel - block * GUIDE_VIEW_BLOCK;
	int2 center = min(block * GUIDE_VIEW_BLOCK + GUIDE_VIEW_BLOCK / 2, int2(constants.size) - 1);
	RWTexture2D<float4> view = cn_rw_texture(push.view_out);
	float3 p;
	float z;
	Restir_Guide gd = restir_guide();
	uint cell;
	if (!surface_at(center, p, z) || gd.level_count == 0 || constants.probes == 0 ||
		!guide_cell(gd, load_probe_grid(constants.probe_grid, constants.probe_grid_offset), p, cell)) {
		view[pixel] = float4(0.1, 0.1, 0.1, 1);
		return;
	}
	float3 n = octahedral_normal(center);
	int inner = GUIDE_VIEW_BLOCK - 2 * GUIDE_VIEW_BORDER;
	int2 m = q - GUIDE_VIEW_BORDER;
	if (any(m < 0) || any(m >= inner)) {
		uint h = lowbias32(cell + 1);
		float3 color = float3(h & 0xff, (h >> 8) & 0xff, (h >> 16) & 0xff) / 255.0 * 0.7 + 0.3;
		float confidence = guide_load(gd.guide, cell, GUIDE_CONFIDENCE);
		view[pixel] = float4(color * (0.15 + 0.85 * saturate(confidence / 256)), 1);
		return;
	}
	float2 uv = (float2(m) + 0.5) / inner;
	uint2 leaf = min(uint2(uv * GUIDE_SIDE), GUIDE_SIDE - 1);
	float share = guide_chance(gd.guide, cell, n, leaf) * GUIDE_LEAVES;
	float3 color = guide_heat((log2(max(share, 1e-6)) + 4) / 8);
	// The leaves' edges, faintly.
	float2 f = frac(uv * GUIDE_SIDE);
	if (any(f < 0.04)) {
		color *= 0.6;
	}
	float2 at = (probe_octahedral(n) * 0.5 + 0.5) * inner;
	if (length(float2(m) + 0.5 - at) < 2.5) {
		color = 1;
	}
	view[pixel] = float4(color, 1);
}
