// The split radiance cascades' merge (see docs/rendering/global-illumination.md#split-cascades): one pass for each
// cascade, from the last to the first, a group for each 64 bins of each active probe, dispatched by the counts that
// the table's arguments phase wrote. Each bin first takes its frame's rays into its history: the share of rays that
// passed through and the mean light that the rest found, blended by the rays against the history's, which decays each
// frame, so a bin that many rays reach follows a change within a few frames. Then it adds what passes through it from
// beyond: the next cascade's light in the four finer directions that it splits into, at the eight probes of the next
// cascade around it, each by its trilinear weight, three to one on each axis, and by its confidence. Where no such
// probe has light, and beyond the last cascade, it is the world probes' light along the direction. The first
// cascade's probes also write their tile of the atlas: the cosine-weighted mean of their merged light around each
// direction, which the gather reads with one bilinear sample.
#include "gi_split.hlsli"

groupshared uint g_parent_slots[8];
groupshared float g_parent_weights[8];
groupshared float3 g_merged[SPLIT_GROUP];

float3 load_merged_rw(uint bin) {
	uint2 m = cn_rw_buffer(push.merged).Load2(bin * SPLIT_MERGED_SIZE);
	return float3(f16tof32(m.x), f16tof32(m.x >> 16), f16tof32(m.y));
}

// confidence_weight is how much a probe's light counts, from the rays that reached it, decayed as its bins' are.
float confidence_weight(Split_Grid g, float confidence) {
	return confidence / (confidence + g.confidence_half);
}

[numthreads(SPLIT_GROUP, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint thread : SV_GroupIndex) {
	Split_Grid g = split_grid();
	uint k = push.cascade;
	Split_Cascade c = g.cascades[k];
	RWByteAddressBuffer slots = cn_rw_buffer(push.slots);
	RWByteAddressBuffer lists = cn_rw_buffer(push.lists);
	RWByteAddressBuffer deposits = cn_rw_buffer(push.deposits);
	uint index = group.y * 65535 + group.x;
	uint active = index / c.chunks;
	uint chunk = index % c.chunks;
	// The whole group leaves together, so its barriers hold.
	if (active >= cn_rw_buffer(push.counters).Load(k * SPLIT_COUNTERS_SIZE + SPLIT_ACTIVE)) {
		return;
	}
	uint slot = lists.Load((g.total_slots + c.first_slot + active) * 4);
	uint4 record = slots.Load4(slot * SPLIT_SLOT_SIZE);
	uint l = split_key_level(record.x);
	int3 u = int3(split_key_cell(record.x));
	Split_Level level = g.levels[l];
	bool fresh = (record.z & SPLIT_FRESH) != 0;
	float confidence = g.decay * (fresh ? 0 : asfloat(record.w)) + float(deposits.Load(slot * 4));

	if (thread < 8) {
		uint parent = SPLIT_NO_SLOT;
		float weight = 0;
		if (k + 1 < g.cascade_count) {
			// The child's center is a quarter of a parent's cell from the nearer parent on each axis.
			int3 offset = int3(thread & 1, (thread >> 1) & 1, thread >> 2);
			int3 near = ~u & 1;
			int3 pu = ((u - 1) >> 1) + offset;
			float3 axis = select(offset == near, (float3)0.75, (float3)0.25);
			if (split_inside(pu, k + 1)) {
				parent = split_find(g.cascades[k + 1], split_key(l, uint3(pu)));
			}
			if (parent != SPLIT_NO_SLOT) {
				weight = axis.x * axis.y * axis.z * confidence_weight(g, asfloat(slots.Load(parent * SPLIT_SLOT_SIZE + 12)));
			}
		}
		g_parent_slots[thread] = parent;
		g_parent_weights[thread] = weight;
	}
	GroupMemoryBarrierWithGroupSync();
	if (thread == 0 && chunk == 0) {
		slots.Store(slot * SPLIT_SLOT_SIZE + 12, asuint(confidence));
		deposits.Store(slot * 4, 0);
	}

	uint b = chunk * SPLIT_GROUP + thread;
	uint bins = c.side * c.side;
	float3 merged = 0;
	if (b < bins) {
		uint bin = split_bin(c, slot, b);
		RWByteAddressBuffer accum = cn_rw_buffer(push.accum);
		RWByteAddressBuffer history = cn_rw_buffer(push.history);
		uint4 counts = accum.Load4(bin * SPLIT_ACCUM_SIZE);
		uint blue = accum.Load(bin * SPLIT_ACCUM_SIZE + 16);
		uint3 h = history.Load3(bin * SPLIT_HISTORY_SIZE);
		float3 mean = fresh ? 0 : float3(f16tof32(h.x), f16tof32(h.x >> 16), f16tof32(h.y));
		float through = fresh ? 1 : f16tof32(h.y >> 16);
		float rays = fresh ? 0 : asfloat(h.z) * g.decay;
		if (counts.x > 0) {
			accum.Store4(bin * SPLIT_ACCUM_SIZE, 0);
			accum.Store(bin * SPLIT_ACCUM_SIZE + 16, 0);
			float count = float(counts.x);
			float exposure = cn_buffer(push.exposure).Load<float>(0);
			float3 frame_mean = float3(counts.z, counts.w, blue) / (g.radiance_scale * count * max(exposure, 1e-10));
			float frame_through = (count - float(counts.y)) / count;
			rays += count;
			float alpha = count / rays;
			mean = lerp(mean, frame_mean, alpha);
			through = lerp(through, frame_through, alpha);
			rays = min(rays, g.max_count);
		}
		history.Store3(bin * SPLIT_HISTORY_SIZE, uint3(f32tof16(mean.r) | (f32tof16(mean.g) << 16), f32tof16(mean.b) | (f32tof16(through) << 16), asuint(rays)));

		float3 beyond = 0;
		if (through > 1e-3) {
			uint2 texel = uint2(b % c.side, b / c.side);
			float total = 0;
			[unroll] for (uint i = 0; i < 8; i++) {
				float weight = g_parent_weights[i];
				if (weight <= 0) {
					continue;
				}
				Split_Cascade pc = g.cascades[k + 1];
				float3 light = 0;
				[unroll] for (uint q = 0; q < 4; q++) {
					uint2 child = texel * 2 + uint2(q & 1, q >> 1);
					light += load_merged_rw(split_bin(pc, g_parent_slots[i], child.y * pc.side + child.x));
				}
				beyond += light * 0.25 * weight;
				total += weight;
			}
			if (total > 1e-4) {
				beyond /= total;
			} else {
				float3 direction = direction_of(texel, c.side, 0.5);
				beyond = beyond_light(split_center(level, u, k), direction, direction);
			}
		}
		merged = mean + through * beyond;
		cn_rw_buffer(push.merged).Store2(bin * SPLIT_MERGED_SIZE, uint2(f32tof16(merged.r) | (f32tof16(merged.g) << 16), f32tof16(merged.b)));
	}

	// The first cascade's probes have at most 64 bins, so a group is a whole probe, and its threads are its tile's texels.
	if (k == 0) {
		g_merged[thread] = merged;
		GroupMemoryBarrierWithGroupSync();
		int2 t = int2(thread % PROBE_TILE, thread / PROBE_TILE);
		float3 n = probe_unfold((float2(interior_of(t)) + 0.5) / PROBE_INTERIOR * 2 - 1);
		float3 sum = 0;
		float total = 0;
		for (uint d = 0; d < bins; d++) {
			float w = direction_weight(uint2(d % c.side, d / c.side), c.side, n);
			sum += g_merged[d] * w;
			total += w;
		}
		uint local = slot - c.first_slot;
		uint2 tile = uint2(local % g.atlas_columns, local / g.atlas_columns) * PROBE_TILE;
		cn_rw_texture(push.atlas)[tile + uint2(t)] = float4(sum / max(total, 1e-5), confidence_weight(g, confidence));
	}
}
