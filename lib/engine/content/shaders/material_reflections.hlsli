// The reflection probes' lookup in the forward pass (see docs/rendering/lighting-and-shadows.md#reflection-probes): the
// probes of a point's light cluster, highest priority first, each weighted by its influence box's fade, until their
// weights reach 1. Each samples its prefiltered cube along the reflection, turned toward where the reflection meets its
// projection box when it has one, at the mip of the surface's roughness.
#ifndef MATERIAL_REFLECTIONS_HLSLI
#define MATERIAL_REFLECTIONS_HLSLI

#include "material_lighting.hlsli"

// Match REFLECTION_PROBE_CLUSTER_STRIDE and MAX_CLUSTER_PROBES in lib/engine/render/reflection_probes.odin: a cluster's
// list is its count, then its probes' indices.
static const uint REFLECTION_PROBE_CLUSTER_STRIDE = 32;
static const uint MAX_CLUSTER_PROBES = 7;

// Matches Reflection_Probe_Record in lib/engine/render/reflection_probes.odin: the probe's position relative to the
// camera and its cube in the array, its axes in the world, which turn a point relative to it into its own space, its
// influence box's half size and its fade's distance, and its projection box's half size, 0 without box projection, and
// its intensity.
struct Reflection_Probe_Record {
	float3 center;
	uint cube;
	float4 axes[3];
	float3 extent;
	float blend;
	float3 projection;
	float intensity;
};

Reflection_Probe_Record load_reflection_probe(uint index) {
	return cn_buffer(frame.reflection_probes).Load<Reflection_Probe_Record>(frame.reflection_probes_offset + index * sizeof(Reflection_Probe_Record));
}

// reflection_probe_fade is how much a probe counts at a point in its own space: 1 deep inside its box, falling to 0 at
// its faces over its blend distance.
float reflection_probe_fade(Reflection_Probe_Record probe, float3 local) {
	float3 inside = (probe.extent - abs(local)) / max(probe.blend, 1e-4);
	return saturate(min(inside.x, min(inside.y, inside.z)));
}

// reflection_probe_direction is the direction to sample a probe's cube along for a reflection from a point, both in the
// probe's space: with a projection box, from the probe toward where the reflection leaves the box, so that what the
// probe saw at the box's faces lines up with the point's view of them.
float3 reflection_probe_direction(Reflection_Probe_Record probe, float3 local, float3 d) {
	if (all(probe.projection <= 0)) {
		return d;
	}
	float3 safe = select(abs(d) < 1e-6, 1e-6, d);
	float3 far = (sign(safe) * probe.projection - local) / safe;
	float t = max(min(far.x, min(far.y, far.z)), 0);
	return local + d * t;
}

// reflection_probe_specular is the probes' light along a reflection at a point relative to the camera, and how much of
// the point they cover, from 0 to 1. strongest is the cube of the probe that counts the most, which stays the probe's
// while it keeps its slot, or -1 where none counts.
float3 reflection_probe_specular(float3 p, float4 position, float3 reflected, float roughness, out float weight, out int strongest) {
	weight = 0;
	strongest = -1;
	if (frame.reflection_probe_count == 0 || frame.reflection_probe_clusters == 0) {
		return 0;
	}
	ByteAddressBuffer clusters = cn_buffer(frame.reflection_probe_clusters);
	uint at = cluster_of(p, position) * REFLECTION_PROBE_CLUSTER_STRIDE;
	uint count = min(clusters.Load(at), MAX_CLUSTER_PROBES);
	TextureCubeArray<float4> cubes = cn_texture_cube_array(frame.reflection_probe_cubes);
	SamplerState s = cn_sampler(frame.sky_cube_sampler);
	float lod = saturate(roughness) * max(frame.reflection_probe_mips - 1, 0);
	float3 light = 0;
	float best = 0;
	for (uint j = 0; j < count && weight < 0.999; j++) {
		uint index = clusters.Load(at + 4 + j * 4);
		Reflection_Probe_Record probe = load_reflection_probe(index);
		float3 offset = p - probe.center;
		float3 local = float3(dot(probe.axes[0].xyz, offset), dot(probe.axes[1].xyz, offset), dot(probe.axes[2].xyz, offset));
		float fade = reflection_probe_fade(probe, local);
		if (fade <= 0) {
			continue;
		}
		float w = fade * (1 - weight);
		float3 d = float3(dot(probe.axes[0].xyz, reflected), dot(probe.axes[1].xyz, reflected), dot(probe.axes[2].xyz, reflected));
		float3 local_d = reflection_probe_direction(probe, local, d);
		// The cube faces the world's axes, as the capture drew it, so the direction goes back to the world.
		float3 world_d = probe.axes[0].xyz * local_d.x + probe.axes[1].xyz * local_d.y + probe.axes[2].xyz * local_d.z;
		light += cubes.SampleLevel(s, float4(world_d, probe.cube), lod).rgb * (probe.intensity * w);
		if (w > best) {
			best = w;
			strongest = int(probe.cube);
		}
		weight += w;
	}
	return light;
}

#endif
