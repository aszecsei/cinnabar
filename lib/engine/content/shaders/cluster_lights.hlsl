// Assigns the punctual lights to clusters (see docs/rendering/lighting-and-shadows.md#lights-and-clusters): a thread for each cluster, a
// tile of the screen and a depth slice, finds the lights whose spheres reach its box in view space, and writes their
// indices into one list, at an offset that it takes with an atomic add.
#include "cinnabar.hlsli"

// Matches Cluster_Constants in lib/engine/render/lights.odin. The view's axes in the world turn positions relative to
// the camera into view space. projection holds the projection's x and y scales, the near plane, and the slices' scale.
struct Cluster_Constants {
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float2 size;
	uint columns;
	uint rows;
	uint lights;
	uint lights_offset;
	uint first_light;
	uint light_count;
	uint clusters;
	uint indices;
	uint counter;
	uint capacity;
};
CN_PASS_CONSTANTS(Cluster_Constants, constants);

// Match CLUSTER_TILE and CLUSTER_SLICES in lib/engine/render/lights.odin. The last slice reaches to infinity, which
// its box ends at LAST_SLICE_FAR for.
static const uint CLUSTER_TILE = 64;
static const uint CLUSTER_SLICES = 32;
static const float LAST_SLICE_FAR = 1e6;

// Matches Light_Record in lib/engine/render/lights.odin; only the position and the range matter here.
struct Light_Record {
	float3 position;
	float range;
	float4 rest[4];
};

// reaches is whether a light's sphere reaches a box in view space.
bool reaches(uint index, float3 box_min, float3 box_max) {
	Light_Record l = cn_buffer(constants.lights).Load<Light_Record>(constants.lights_offset + index * sizeof(Light_Record));
	float3 v = float3(dot(l.position, constants.right.xyz), dot(l.position, constants.up.xyz), dot(l.position, constants.forward.xyz));
	float3 d = v - clamp(v, box_min, box_max);
	return dot(d, d) <= l.range * l.range;
}

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	uint tiles = constants.columns * constants.rows;
	if (id.x >= tiles * CLUSTER_SLICES) {
		return;
	}
	uint slice = id.x / tiles;
	uint x = id.x % constants.columns;
	uint y = (id.x / constants.columns) % constants.rows;

	// The slice's depths, from slice = log2(z / near) * scale.
	float near = constants.projection.z;
	float scale = constants.projection.w;
	float z0 = near * exp2(slice / scale);
	float z1 = slice + 1 == CLUSTER_SLICES ? LAST_SLICE_FAR : near * exp2((slice + 1) / scale);
	// The tile in normalized device coordinates, then its box in view space between the two depths.
	float2 low_px = float2(x, y) * CLUSTER_TILE;
	float2 high_px = min(low_px + CLUSTER_TILE, constants.size);
	float2 ndc_a = float2(low_px.x / constants.size.x * 2 - 1, 1 - high_px.y / constants.size.y * 2);
	float2 ndc_b = float2(high_px.x / constants.size.x * 2 - 1, 1 - low_px.y / constants.size.y * 2);
	float2 inverse_scale = 1 / constants.projection.xy;
	float2 a0 = ndc_a * inverse_scale * z0, a1 = ndc_a * inverse_scale * z1;
	float2 b0 = ndc_b * inverse_scale * z0, b1 = ndc_b * inverse_scale * z1;
	float3 box_min = float3(min(min(a0, a1), min(b0, b1)), z0);
	float3 box_max = float3(max(max(a0, a1), max(b0, b1)), z1);

	// Count the lights that reach the box, take room for them, then write them.
	uint count = 0;
	for (uint i = 0; i < constants.light_count; i++) {
		count += reaches(constants.first_light + i, box_min, box_max) ? 1 : 0;
	}
	uint offset = 0;
	if (count > 0) {
		cn_rw_buffer(constants.counter).InterlockedAdd(0, count, offset);
		count = offset < constants.capacity ? min(count, constants.capacity - offset) : 0;
	}
	uint written = 0;
	for (uint j = 0; j < constants.light_count && written < count; j++) {
		uint index = constants.first_light + j;
		if (reaches(index, box_min, box_max)) {
			cn_rw_buffer(constants.indices).Store((offset + written) * 4, index);
			written++;
		}
	}
	cn_rw_buffer(constants.clusters).Store2(id.x * 8, uint2(offset, count));
}
