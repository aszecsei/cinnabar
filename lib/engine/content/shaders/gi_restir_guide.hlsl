// ReSTIR GI's ray guide's build (see docs/rendering/global-illumination.md#ray-guiding): a group for each cell of the
// guide's levels, a thread for each leaf, before the rays' trace. A cell whose key is not its probe's world cell this
// frame, as one that its level's box moved over, starts again, and last frame's sums in it are dropped. Otherwise each
// leaf's sum over the cell's count of rays is an estimate of the light through it, which blends into the leaf's learned
// light as a running mean of at most GUIDE_MAX_CONFIDENCE rays. The leaf that the walk sees is that light, blended with
// the world probe's radiance through the leaf by how few rays the cell has learned from, and floored by a share of the
// cell's light, so no leaf is unlikely. A cell with no light at all takes each leaf's solid angle: uniform over the
// sphere. Then the threads sum the leaves into the quadtree, and empty the sums for this frame's rays.
#include "gi_restir_guide.hlsli"

// The rays that a cell's running mean holds at most, so the guide follows a change in the light.
static const float GUIDE_MAX_CONFIDENCE = 256;

groupshared float g_nodes[GUIDE_LEAVES];

[numthreads(GUIDE_LEAVES, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint leaf : SV_GroupIndex) {
	Restir_Guide gd = restir_guide();
	Probe_Grid grid = load_probe_grid(constants.probe_grid, constants.probe_grid_offset);
	uint cell = group.x + group.y * 65535;
	uint levels = min(gd.level_count, grid.level_count);
	if (cell >= levels * PROBE_COUNT) {
		return;
	}
	uint l = cell / PROBE_COUNT;
	uint storage = cell % PROBE_COUNT;
	Probe_Level level = grid.levels[l];
	int3 key = gd.keys[l].xyz + probe_cell(level, storage);
	RWByteAddressBuffer guide = cn_rw_buffer(gd.guide_out);
	RWByteAddressBuffer accum = cn_rw_buffer(gd.accum_out);
	uint base = cell * GUIDE_STRIDE * 4;
	uint sums = cell * GUIDE_ACCUM_STRIDE * 4;
	int3 stored = int3(guide.Load3(base + GUIDE_KEY * 4));
	bool same = guide.Load(base + GUIDE_TAG_AT * 4) == GUIDE_TAG && all(stored == key);

	// This frame's rays, into the learned light.
	float count = float(accum.Load(sums + GUIDE_LEAVES * 4));
	float sum = float(accum.Load(sums + leaf * 4)) / GUIDE_UNITS;
	float learned = same ? asfloat(guide.Load(base + (GUIDE_LEARNED + leaf) * 4)) : 0;
	float confidence = same ? asfloat(guide.Load(base + GUIDE_CONFIDENCE * 4)) : 0;
	learned = isfinite(learned) ? max(learned, 0) : 0;
	confidence = isfinite(confidence) ? clamp(confidence, 0, GUIDE_MAX_CONFIDENCE) : 0;
	if (same && count > 0) {
		learned = lerp(learned, sum / count, count / (confidence + count));
		confidence = min(confidence + count, GUIDE_MAX_CONFIDENCE);
	}
	GroupMemoryBarrierWithGroupSync();
	accum.Store(sums + leaf * 4, 0);
	if (leaf == 0) {
		accum.Store(sums + GUIDE_LEAVES * 4, 0);
	}

	// The world probe's radiance through the leaf, pre-exposed, where the probe has light.
	uint2 xy = uint2(leaf % GUIDE_SIDE, leaf / GUIDE_SIDE);
	float3 center = probe_unfold((float2(xy) + 0.5) / GUIDE_SIDE * 2 - 1);
	float solid_angle = 4.0 / (GUIDE_SIDE * GUIDE_SIDE) * guide_jacobian(center);
	uint state = cn_buffer(grid.states).Load(probe_state_index(l, storage));
	bool lit = (state & PROBE_UPDATES_MASK) != 0 && (state & PROBE_INACTIVE) == 0;
	float trust = confidence / (confidence + gd.prior_rays);
	float value = learned;
	if (lit) {
		float exposure = cn_buffer(push.exposure).Load<float>(0);
		float3 radiance = cn_texture(grid.radiance).SampleLevel(cn_sampler(grid.sampler_index), probe_uv(grid, l, storage, center), 0).rgb;
		float prior = restir_luminance(max(radiance, 0)) * exposure * solid_angle;
		value = lerp(isfinite(prior) ? prior : 0, learned, trust);
	}

	// The floor, then the quadtree, from the leaves up.
	g_nodes[leaf] = value;
	GroupMemoryBarrierWithGroupSync();
	float total = 0;
	for (uint i = 0; i < GUIDE_LEAVES; i++) {
		total += g_nodes[i];
	}
	value = total > 0 ? value + gd.floor_share * total / GUIDE_LEAVES : solid_angle;
	GroupMemoryBarrierWithGroupSync();
	g_nodes[leaf] = value;
	guide.Store(base + (guide_level_offset(3) + leaf) * 4, asuint(value));
	for (uint k = 3; k > 0; k--) {
		GroupMemoryBarrierWithGroupSync();
		uint side = 1u << (k - 1);
		float node = 0;
		if (leaf < side * side) {
			uint2 at = uint2(leaf % side, leaf / side) * 2;
			uint child = 1u << k;
			node = g_nodes[at.y * child + at.x] + g_nodes[at.y * child + at.x + 1] + g_nodes[(at.y + 1) * child + at.x] + g_nodes[(at.y + 1) * child + at.x + 1];
		}
		GroupMemoryBarrierWithGroupSync();
		if (leaf < side * side) {
			g_nodes[leaf] = node;
			guide.Store(base + (guide_level_offset(k - 1) + leaf) * 4, asuint(node));
		}
	}

	guide.Store(base + (GUIDE_LEARNED + leaf) * 4, asuint(learned));
	if (leaf == 0) {
		guide.Store(base + GUIDE_CONFIDENCE * 4, asuint(confidence));
		guide.Store3(base + GUIDE_KEY * 4, uint3(key));
		guide.Store(base + GUIDE_TAG_AT * 4, GUIDE_TAG);
	}
}
