// The world probes' update (see docs/rendering/global-illumination.md#world-probes): a group for each probe that the
// frame updates, a thread for each texel of its tile. Each texel blends its direction's share of the probe's rays into
// what it held: the radiance in a narrow lobe around the direction, the cosine-weighted mean radiance, and the mean
// and squared distance in a narrower lobe. A probe new since its reset takes its rays as they are, and then blends
// more slowly with each update, down to the grid's hysteresis. The border texels repeat the interior across the
// octahedron's folds, so bilinear samples at a tile's edge are right. A probe that sees back faces with more than a
// quarter of its rays is inside geometry and counts for nothing.
#include "gi_probe_pass.hlsli"

// Matches the largest rays of GI_PROBE_PARAMS.
static const uint MAX_PROBE_RAYS = 64;
// The lobes are about as wide as a texel, a sixth of the octahedron across, so each texel takes a few of the probe's
// rays at each update.
static const float RADIANCE_SHARPNESS = 8;
static const float DISTANCE_SHARPNESS = 12;
static const float BACKFACE_SHARE = 0.25;

groupshared float4 g_rays[MAX_PROBE_RAYS];
groupshared float3 g_directions[MAX_PROBE_RAYS];

// interior_of is the interior texel that a texel of the tile shows: itself, or for the border, the interior texel
// across the octahedron's fold.
int2 interior_of(int2 t) {
	int last = PROBE_INTERIOR - 1;
	int2 i = t - 1;
	if (i.x < 0 || i.x > last) {
		i.y = last - i.y;
		i.x = clamp(i.x, 0, last);
	}
	if (i.y < 0 || i.y > last) {
		i.x = last - i.x;
		i.y = clamp(i.y, 0, last);
	}
	return clamp(i, 0, last);
}

[numthreads(PROBE_TILE, PROBE_TILE, 1)]
void cs_main(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex) {
	Probe_Grid grid = frame_probe_grid();
	uint job = group.x + group.y * 65535;
	if (job >= grid.job_count) {
		return;
	}
	Probe probe = job_probe(grid, job);
	uint rays = min(grid.rays, MAX_PROBE_RAYS);
	if (index < rays) {
		g_rays[index] = cn_buffer(push.rays).Load<float4>((job * grid.rays + index) * 16);
		g_directions[index] = probe_ray_direction(grid, index);
	}
	GroupMemoryBarrierWithGroupSync();

	int2 interior = interior_of(int2(thread.xy));
	float3 direction = probe_unfold((float2(interior) + 0.5) / PROBE_INTERIOR * 2 - 1);
	float3 radiance = 0;
	float radiance_total = 0;
	float3 irradiance = 0;
	float irradiance_total = 0;
	float2 moments = 0;
	float moments_total = 0;
	uint backfaces = 0;
	for (uint r = 0; r < rays; r++) {
		float4 v = g_rays[r];
		float c = saturate(dot(g_directions[r], direction));
		float distance = min(abs(v.a), probe.distance);
		backfaces += v.a < 0 ? 1 : 0;
		irradiance += v.rgb * c;
		irradiance_total += c;
		float sharp = pow(c, RADIANCE_SHARPNESS);
		radiance += v.rgb * sharp;
		radiance_total += sharp;
		float narrow = pow(c, DISTANCE_SHARPNESS);
		moments += float2(distance, distance * distance) * narrow;
		moments_total += narrow;
	}

	uint state_index = probe_state_index(probe.level, probe.storage);
	uint state = cn_rw_buffer(grid.states_out).Load(state_index);
	uint updates = state & PROBE_UPDATES_MASK;
	float alpha = updates == 0 ? 1 : max(1.0 / (updates + 1), 1 - grid.hysteresis);
	uint2 texel = probe_tile(probe.level, probe.storage) + thread.xy;
	RWTexture2D<float4> radiance_texture = cn_rw_texture(grid.radiance_out);
	RWTexture2D<float4> irradiance_texture = cn_rw_texture(grid.irradiance_out);
	float4 old_radiance = updates == 0 ? 0 : radiance_texture[texel];
	float4 old_irradiance = updates == 0 ? 0 : irradiance_texture[texel];
	// A texel whose lobe took no ray keeps what it had, or until its first update, sees nothing to its far end.
	float2 old_moments = updates == 0 ? float2(probe.distance, probe.distance * probe.distance) : float2(old_radiance.a, old_irradiance.a);
	float2 new_moments = moments_total > 0 ? moments / moments_total : old_moments;
	float4 new_radiance = float4(radiance_total > 0 ? radiance / radiance_total : old_radiance.rgb, new_moments.x);
	float4 new_irradiance = float4(irradiance_total > 0 ? irradiance / irradiance_total : old_irradiance.rgb, new_moments.y);
	radiance_texture[texel] = lerp(old_radiance, new_radiance, alpha);
	irradiance_texture[texel] = lerp(old_irradiance, new_irradiance, alpha);
	if (index == 0) {
		uint inactive = backfaces > BACKFACE_SHARE * rays ? PROBE_INACTIVE : 0;
		cn_rw_buffer(grid.states_out).Store(state_index, min(updates + 1, PROBE_UPDATES_MASK) | inactive);
	}
}
