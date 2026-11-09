// The forward pass of every material (see docs/rendering/materials.md#materials). It draws after the prepass with an Equal depth
// test, so each pixel shades once. The cooker includes it after the shading model, the Params struct and the
// material's evaluate, with these defined:
//   MATERIAL_TWO_SIDED, MATERIAL_MASKED and MATERIAL_CUTOFF: the material's settings.
//   MATERIAL_TRANSPARENT: a transparent or additive material, which has no forward pass of its own; its passes shade
//   with forward_color (see material_transparent.hlsli).
//   SHADING_NO_LIGHTING: the shading model only emits.
//   SHADING_HAS_NORMAL: the shading model's Surface has a tangent-space normal, which the passes map to the world.
#ifndef MATERIAL_FORWARD_HLSLI
#define MATERIAL_FORWARD_HLSLI

#include "material_vertex.hlsli"
#include "material_mesh.hlsli"
#include "material_lighting.hlsli"
#include "fog_at.hlsli"
#include "material_reflections.hlsli"
#include "gi_probes.hlsli"

// The scene's HDR colors, pre-exposed, and the entity IDs that the editor picks from.
struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

Varyings vs_forward(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
	return vertex_varyings(load_vertex(vertex_id, instance_id));
}

[outputtopology("triangle")]
[numthreads(MESHLET_THREADS, 1, 1)]
void ms_forward(
	uint thread : SV_GroupIndex,
	uint group : SV_GroupID,
	in payload Cluster_Payload clusters,
	out vertices Varyings vertices[MESHLET_MAX_VERTICES],
	out indices uint3 triangles[MESHLET_MAX_TRIANGLES]
) {
	Cluster c = LOAD_CLUSTER(clusters, group);
	SetMeshOutputCounts(c.vertex_count, c.triangle_count);
	if (thread < c.vertex_count) {
		vertices[thread] = vertex_varyings(cluster_vertex(c, thread));
	}
	if (thread < c.triangle_count) {
		triangles[thread] = cluster_triangle(c, thread);
	}
}

// capture_indirect is a reflection probe's capture's indirect light without the voxel cones (see
// docs/rendering/lighting-and-shadows.md#reflection-probes): the world probes' where they run, and otherwise the ambient
// light along the normal and the sky's cubemap along the reflection, which the face's own ambient occlusion scales. With
// the voxel cones, the face's gather gives its light as the camera's gather does, through frame.gi.
Indirect capture_indirect(float3 p, float3 normal, float3 reflected, float roughness) {
	Indirect indirect;
	indirect.diffuse = ambient_light(frame.ambient, normal);
	indirect.specular = frame_sky_specular(reflected, roughness);
	if (frame.world_probes != 0) {
		Probe_Grid grid = load_probe_grid(frame.world_probe_grid, frame.world_probe_grid_offset);
		float3 light;
		if (sample_probes(grid, p, normal, normal, false, light)) {
			indirect.diffuse = light;
		}
		if (sample_probes(grid, p, normal, reflected, true, light)) {
			indirect.specular = light;
		}
	}
	return indirect;
}

// The colors of the directional lights' cascades, and beyond the last.
static const float3 CASCADE_COLORS[5] = {float3(1, 0.3, 0.3), float3(0.3, 1, 0.3), float3(0.3, 0.5, 1), float3(1, 1, 0.3), float3(0.4, 0.4, 0.4)};

// forward_color is a surface's shaded color: its emission, its lights' light and its indirect light, fogged and
// pre-exposed, or a debug view's color as it is, without the exposure or the fog. The fog dims the color, and adds the
// light that it scatters toward the camera times scatter: an additive surface adds none, since the fog's light is
// already in front of what it adds to.
float3 forward_color(Varyings i, Material_Inputs inputs, Surface s, float scatter) {
	// The debug views (see docs/rendering/post-processing.md#debug-views). A dynamic branch on the frame's constant, so they need no
	// permutations.
	uint debug_view = frame.debug_view;
	if (debug_view == DEBUG_ALBEDO) {
#if SHADING_HAS_BASE_COLOR
		return s.base_color;
#else
		return shade_emission(s);
#endif
	}
	if (debug_view == DEBUG_EMISSION) {
		return shade_emission(s) * frame_exposure();
	}
	// Lit in grey where the light comes from a cluster, so the light count shows over the shapes.
	float lambert = 0.5 + 0.5 * saturate(dot(inputs.normal, normalize(float3(0.3, 1, 0.5))));
	if (debug_view == DEBUG_LIGHT_COMPLEXITY) {
		return heat(light_count(i.world, i.position) / 16.0) * lambert;
	}
	if (debug_view == DEBUG_SHADOW_CASCADES) {
		return CASCADE_COLORS[cascade_at(frame.near / max(i.position.z, 1e-7))] * lambert;
	}
	if (debug_view == DEBUG_SHADOW_VIRTUAL) {
		return virtual_debug_color(i.world) * lambert;
	}
	// Vertex pulling draws no meshlets, so its surfaces are all one color, at level 0.
	if (debug_view == DEBUG_MESHLETS) {
		return hash_color(i.cluster & ((1u << MESHLET_DEPTH_SHIFT) - 1)) * lambert;
	}
	if (debug_view == DEBUG_LOD_DEPTH) {
		return heat((i.cluster >> MESHLET_DEPTH_SHIFT) / 8.0) * lambert;
	}
	if (debug_view == DEBUG_REFLECTION_PROBES) {
		float weight;
		int strongest;
		float3 reflected = reflect(-inputs.view, inputs.normal);
		reflection_probe_specular(i.world, i.position, reflected, 0, weight, strongest);
		return (strongest < 0 ? float3(1, 0.1, 0.1) : hash_color(uint(strongest) + 1)) * lambert;
	}
#if SHADING_HAS_BASE_COLOR
	if (debug_view == DEBUG_LIGHTING_ONLY) {
		s.base_color = 0.5;
	}
#endif
	bool direct_only = debug_view == DEBUG_DIRECT_LIGHT;
	bool indirect_only = debug_view == DEBUG_INDIRECT_LIGHT;
	bool fog_only = debug_view == DEBUG_FOG;
	float3 color = debug_view == DEBUG_LIT ? shade_emission(s) : 0;
#if !SHADING_NO_LIGHTING
	Shading_Point p;
	p.position = i.world;
	p.view = inputs.view;
	p.normal = shading_normal(inputs, s);
	if (!indirect_only && !fog_only) {
		color += direct_light(s, p, inputs.normal, i.position);
	}
	// The global illumination's diffuse light, or without it the Environment's ambient light along the normal. The
	// specular light along the reflection is the reflection probes', where they count, over the sky's cubemap's at the
	// surface's roughness, or with the global illumination over its specular light, which keeps its dynamic occlusion on
	// rough surfaces, where the probes fade out. The ambient occlusion takes away from both. The occlusion is the opaque
	// surfaces', from the prepass, so a transparent surface has none, and the global illumination's specular light is
	// theirs too, so a transparent surface reflects the probes and the sky along its own normal.
#if MATERIAL_TRANSPARENT
	float occlusion = 1;
#else
	float occlusion = saturate(load_screen(push.ambient_occlusion, i.position.xy).r);
#endif
	float3 reflected = reflect(-p.view, p.normal);
	float roughness = shading_roughness(s);
	Indirect indirect;
	if (frame.capture != 0 && frame.gi == 0) {
		indirect = capture_indirect(p.position, p.normal, reflected, roughness);
	} else {
		float probe_weight;
		int strongest;
		float3 probes = reflection_probe_specular(p.position, i.position, reflected, roughness, probe_weight, strongest);
#if MATERIAL_TRANSPARENT
		bool gi_specular = false;
#else
		bool gi_specular = frame.gi != 0;
#endif
		indirect.diffuse = frame.gi != 0 ? cn_texture(push.gi_diffuse).Load(int3(i.position.xy, 0)).rgb : ambient_light(frame.ambient, p.normal);
		if (gi_specular) {
			float fade = 1 - smoothstep(frame.reflection_probe_rough_start, frame.reflection_probe_rough_end, roughness);
			indirect.specular = probes * fade + cn_texture(push.gi_specular).Load(int3(i.position.xy, 0)).rgb * (1 - probe_weight * fade);
		} else {
			indirect.specular = probes + frame_sky_specular(reflected, roughness) * (1 - probe_weight);
		}
	}
	indirect.diffuse *= occlusion;
	indirect.specular *= occlusion;
#if !MATERIAL_TRANSPARENT
	// The screen-space or traced reflections in front of the rest, by their weight. They are pre-exposed and filtered for the
	// roughness already, and a hit on the screen is occluded already, so the occlusion scales only what is below them.
	if (frame.reflections != 0) {
		float4 screen = load_screen(push.reflections, i.position.xy);
		indirect.specular = lerp(indirect.specular, screen.rgb / max(frame_exposure(), 1e-10), saturate(screen.a));
	}
#endif
	if (!direct_only && !fog_only) {
		color += shade_indirect(s, p, indirect);
	}
#endif
	if (frame.fog != 0) {
		float4 fog = fog_at(i.world);
		color = color * fog.a + fog.rgb * scatter;
	}
	return color * frame_exposure();
}

#if !MATERIAL_TRANSPARENT
// count_quad counts the pixel shader's 2x2 quad and its lanes that cover a pixel, when the frame measures them (see
// docs/rendering/lighting-and-shadows.md#quad-overdraw): one lane of each quad adds 1 to the quad's count, for the
// Quad_Overdraw view, and each wave adds its quads and pixels to the stats. The wave's operations leave helper lanes
// out, but the quad's reads take them, so the quad's lanes that cover a pixel are found with quad reads.
void count_quad(float4 position) {
	if (push.quad_counts == 0) {
		return;
	}
	uint2 pixel = uint2(position.xy);
	uint lane = (pixel.x & 1) | (pixel.y & 1) << 1;
	uint bit = IsHelperLane() ? 0 : 1u << lane;
	uint live = bit | QuadReadAcrossX(bit) | QuadReadAcrossY(bit) | QuadReadAcrossDiagonal(bit);
	// The quad's first lane that covers a pixel counts it.
	bool leader = bit != 0 && (live & (bit - 1)) == 0;
	if (leader) {
		RWTexture2D<uint> counts = ResourceDescriptorHeap[push.quad_counts - 1];
		InterlockedAdd(counts[pixel / 2], 1);
	}
	if (push.shading_stats != 0) {
		uint quads = WaveActiveCountBits(leader);
		uint pixels = WaveActiveCountBits(bit != 0);
		if (WaveIsFirstLane()) {
			RWByteAddressBuffer stats = cn_rw_buffer(push.shading_stats - 1);
			stats.InterlockedAdd(SHADING_STATS_FORWARD_QUADS, quads);
			stats.InterlockedAdd(SHADING_STATS_FORWARD_PIXELS, pixels);
		}
	}
}

// The prepass's depth decides what shows, and the pass writes none, so its depth test can come first although it
// writes the measurements: only the pixels that it shades count.
[earlydepthstencil]
Targets ps_forward(Varyings i, bool front : SV_IsFrontFace) {
	count_quad(i.position);
	Material_Inputs inputs = material_inputs(i, front);
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	Targets o;
	o.color = float4(forward_color(i, inputs, s, 1), 1);
	o.id = i.id;
	return o;
}
#endif

#endif
