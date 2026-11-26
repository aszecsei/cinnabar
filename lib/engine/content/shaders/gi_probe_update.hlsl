// The world probes' update (see docs/rendering/global-illumination.md#world-probes): a group for each probe that the
// frame updates, a thread for each texel of its tile. Each ray's light is clamped by its luminance at the frame's
// exposure (clamp_hit_light), so one bright hit does not stay in the probe for many updates. Each texel blends its
// direction's share of the probe's rays into what it held: the radiance in a narrow lobe around the direction, the
// cosine-weighted mean radiance, and the mean and squared distance in a narrower lobe. A probe new since its reset
// takes its rays as they are, and then blends more slowly with each update, down to the grid's hysteresis. The border
// texels repeat the interior across the octahedron's folds, so bilinear samples at a tile's edge are right. A probe
// that sees back faces with more than a quarter of its rays is inside geometry and counts for nothing. The hits'
// irradiance is the same mean without the light of the GI's listed emitters that the rays hit: the hits sample those
// emitters themselves, so their light through the probes would count twice. It takes out the radiance in the pool, the
// same that the hits sample, so the two agree while the pool still learns a triangle's emission.
#include "gi_probe_pass.hlsli"
#include "hit_clamp.hlsli"
#include "gi_emitter_samples.hlsli"

// Matches the largest rays of GI_PROBE_PARAMS.
static const uint MAX_PROBE_RAYS = 64;
// The lobes are about as wide as a texel, a sixth of the octahedron across, so each texel takes a few of the probe's
// rays at each update.
static const float RADIANCE_SHARPNESS = 8;
static const float DISTANCE_SHARPNESS = 12;
static const float BACKFACE_SHARE = 0.25;

groupshared float4 g_rays[MAX_PROBE_RAYS];
groupshared float3 g_rays_hit[MAX_PROBE_RAYS];
groupshared float3 g_directions[MAX_PROBE_RAYS];

// listed_emission is the radiance of the listed emitter that a ray hit, or 0: none where its hit was a back face,
// which sends out no light, or the frame has no emitters.
float3 listed_emission(uint ray, float distance) {
	if (push.emitter_count == 0 || distance < 0) {
		return 0;
	}
	Hit_Record hit = load_hit(push.hits, ray);
	if (hit_missed(hit) || hit.entry == ~0u) {
		return 0;
	}
	Emitter_Table_Header header = load_emitter_header(push.emitter_table, push.emitter_table_offset);
	if (hit.entry >= header.entries) {
		return 0;
	}
	uint listed = cn_buffer(push.emitter_table).Load(push.emitter_table_offset + header.hit_emitters + hit.entry * 4);
	if (listed >= header.count) {
		return 0;
	}
	Emitter_Submesh sub = load_emitter_submesh(push.emitter_table, push.emitter_table_offset, listed);
	uint local = hit.primitive - sub.first_primitive;
	if (local >= sub.primitive_count) {
		return 0;
	}
	float4 cell = cn_buffer(push.emitter_pool).Load<float4>((sub.radiance_base + local) * 16);
	return cell.w > 0 ? unpack_rgb9e5(pack_rgb9e5(cell.rgb)) : 0;
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
		uint at = job * grid.rays + index;
		float4 ray = cn_buffer(push.rays).Load<float4>(at * 16);
		float exposure = cn_buffer(push.exposure).Load<float>(0);
		g_rays[index] = float4(clamp_hit_light(ray.rgb, exposure, grid.radiance_max), ray.a);
		g_rays_hit[index] = clamp_hit_light(max(ray.rgb - listed_emission(at, ray.a), 0), exposure, grid.radiance_max);
		g_directions[index] = probe_ray_direction(grid, index);
	}
	GroupMemoryBarrierWithGroupSync();

	int2 interior = interior_of(int2(thread.xy));
	float3 direction = probe_unfold((float2(interior) + 0.5) / PROBE_INTERIOR * 2 - 1);
	float3 radiance = 0;
	float radiance_total = 0;
	float3 irradiance = 0;
	float3 irradiance_hit = 0;
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
		irradiance_hit += g_rays_hit[r] * c;
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
	RWTexture2D<float4> irradiance_hit_texture = cn_rw_texture(grid.irradiance_hit_out);
	float4 old_radiance = updates == 0 ? 0 : radiance_texture[texel];
	float4 old_irradiance = updates == 0 ? 0 : irradiance_texture[texel];
	float4 old_irradiance_hit = updates == 0 ? 0 : irradiance_hit_texture[texel];
	// A texel whose lobe took no ray keeps what it had, or until its first update, sees nothing to its far end.
	float2 old_moments = updates == 0 ? float2(probe.distance, probe.distance * probe.distance) : float2(old_radiance.a, old_irradiance.a);
	float2 new_moments = moments_total > 0 ? moments / moments_total : old_moments;
	float4 new_radiance = float4(radiance_total > 0 ? radiance / radiance_total : old_radiance.rgb, new_moments.x);
	float4 new_irradiance = float4(irradiance_total > 0 ? irradiance / irradiance_total : old_irradiance.rgb, new_moments.y);
	float4 new_irradiance_hit = float4(irradiance_total > 0 ? irradiance_hit / irradiance_total : old_irradiance_hit.rgb, new_moments.y);
	radiance_texture[texel] = lerp(old_radiance, new_radiance, alpha);
	irradiance_texture[texel] = lerp(old_irradiance, new_irradiance, alpha);
	irradiance_hit_texture[texel] = lerp(old_irradiance_hit, new_irradiance_hit, alpha);
	if (index == 0) {
		uint inactive = backfaces > BACKFACE_SHARE * rays ? PROBE_INACTIVE : 0;
		cn_rw_buffer(grid.states_out).Store(state_index, min(updates + 1, PROBE_UPDATES_MASK) | inactive);
	}
}
