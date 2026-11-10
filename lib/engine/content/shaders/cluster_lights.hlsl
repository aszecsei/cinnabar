// Assigns the punctual lights to clusters (see docs/rendering/lighting-and-shadows.md#lights-and-clusters): a thread for each cluster, a
// tile of the screen and a depth slice, finds the lights whose spheres reach its box in view space, and writes their
// indices into one list, at an offset that it takes with an atomic add. Then it finds the reflection probes whose
// influence boxes reach its box, and writes the first MAX_CLUSTER_PROBES of them, in their records' order, which is
// their priority's, into its own fixed list (see docs/rendering/lighting-and-shadows.md#reflection-probes).
#include "cinnabar.hlsli"
#include "view_projection.hlsli"

// Matches Cluster_Constants in lib/engine/render/lights.odin. The view's axes in the world turn positions relative to
// its eye, which is relative to the camera, into view space. projection holds the projection's x and y scales, the
// near plane, and the slices' scale.
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
	float eye_x;
	float eye_y;
	float eye_z;
	uint probes;
	uint probes_offset;
	uint probe_count;
	uint probe_clusters;
	// The view's far plane when it is orthographic, and 0 otherwise.
	float far;
};
CN_PASS_CONSTANTS(Cluster_Constants, constants);

// Match REFLECTION_PROBE_CLUSTER_STRIDE and MAX_CLUSTER_PROBES in lib/engine/render/reflection_probes.odin.
static const uint REFLECTION_PROBE_CLUSTER_STRIDE = 32;
static const uint MAX_CLUSTER_PROBES = 7;

// Matches Reflection_Probe_Record in lib/engine/render/reflection_probes.odin; only its box matters here.
struct Reflection_Probe_Record {
	float3 center;
	uint cube;
	float4 axes[3];
	float3 extent;
	float blend;
	float4 rest;
};

// to_view turns a point relative to the camera into the view's space.
float3 to_view(float3 p) {
	p -= float3(constants.eye_x, constants.eye_y, constants.eye_z);
	return float3(dot(p, constants.right.xyz), dot(p, constants.up.xyz), dot(p, constants.forward.xyz));
}

// probe_reaches is whether a probe's influence box reaches a box in view space: the box in view space that holds the
// probe's turned box overlaps it. Matches probe_reaches_box in lib/engine/render/reflection_probes.odin.
bool probe_reaches(uint index, float3 box_min, float3 box_max) {
	Reflection_Probe_Record p = cn_buffer(constants.probes).Load<Reflection_Probe_Record>(constants.probes_offset + index * sizeof(Reflection_Probe_Record));
	float3 center = to_view(p.center);
	float3 half_size = 0;
	[unroll] for (uint a = 0; a < 3; a++) {
		float3 axis = float3(dot(p.axes[a].xyz, constants.right.xyz), dot(p.axes[a].xyz, constants.up.xyz), dot(p.axes[a].xyz, constants.forward.xyz));
		half_size += abs(axis) * p.extent[a];
	}
	return all(center - half_size <= box_max) && all(center + half_size >= box_min);
}

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
	float3 v = to_view(l.position);
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

	// The slice's depths, from slice = log2(z / near) * scale, or (z - near) * scale for an orthographic view, whose
	// last slice ends at its far plane.
	float near = constants.projection.z;
	float scale = constants.projection.w;
	float4 projection = float4(constants.projection.xyz, constants.far);
	bool orthographic = is_orthographic(projection);
	float z0 = orthographic ? near + slice / scale : near * exp2(slice / scale);
	float z1 = orthographic ? near + (slice + 1) / scale : (slice + 1 == CLUSTER_SLICES ? LAST_SLICE_FAR : near * exp2((slice + 1) / scale));
	// The tile in normalized device coordinates, then its box in view space between the two depths.
	float2 low_px = float2(x, y) * CLUSTER_TILE;
	float2 high_px = min(low_px + CLUSTER_TILE, constants.size);
	float2 ndc_a = float2(low_px.x / constants.size.x * 2 - 1, 1 - high_px.y / constants.size.y * 2);
	float2 ndc_b = float2(high_px.x / constants.size.x * 2 - 1, 1 - low_px.y / constants.size.y * 2);
	float2 a0 = view_position(projection, ndc_a, z0).xy, a1 = view_position(projection, ndc_a, z1).xy;
	float2 b0 = view_position(projection, ndc_b, z0).xy, b1 = view_position(projection, ndc_b, z1).xy;
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

	if (constants.probe_clusters == 0) {
		return;
	}
	RWByteAddressBuffer probe_list = cn_rw_buffer(constants.probe_clusters);
	uint at = id.x * REFLECTION_PROBE_CLUSTER_STRIDE;
	uint probes = 0;
	for (uint k = 0; k < constants.probe_count && probes < MAX_CLUSTER_PROBES; k++) {
		if (probe_reaches(k, box_min, box_max)) {
			probe_list.Store(at + 4 + probes * 4, k);
			probes++;
		}
	}
	probe_list.Store(at, probes);
}
