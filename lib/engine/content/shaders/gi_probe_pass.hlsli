// What the world probes' passes share (see docs/rendering/global-illumination.md#world-probes): their push constants,
// which start with Material_Push's shadow textures, so the light loop's lookups compile, and the probe of a job. The
// passes set the camera's frame constants.
#ifndef GI_PROBE_PASS_HLSLI
#define GI_PROBE_PASS_HLSLI

#include "gi_translucency.hlsli"

// Matches Probe_Push in lib/engine/render/gi_probes.odin. light_grid is the frame's light grid, whose punctual lights the
// hits pick from after the directional ones, candidates the lights that each hit weighs, and seed that of its choices.
// depth is this frame's, and lit the global illumination's lit scene of last frame, when lit_valid. exposure is the
// frame's, which the update reads. translucency is what the rays and the hits' shadow rays pass through glass by, with
// the GI's emitters' table and pool, which the update takes their light out of the hits' irradiance with.
// emitter_samples are the GI's emitters' triangles, emitter_count of them, or 0 without them, which the hits sample.
// transmit holds each ray's transmittance, the glass that it crossed, when transmit_valid is 1.
struct Probe_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint grid;
	uint grid_offset;
	uint hits;
	uint surfaces;
	uint rays;
	uint accel;
	uint light_grid;
	uint light_grid_offset;
	uint candidates;
	uint ray_count;
	uint depth;
	uint lit;
	uint lit_valid;
	uint exposure;
	// A nested struct starts on 16 bytes in a constant buffer: this one is at 64.
	Translucency translucency;
	uint seed;
	uint emitter_samples;
	uint emitter_count;
	uint transmit;
	uint transmit_valid;
};
#define MATERIAL_PUSH Probe_Push
// No shading model: the hits need only the light loop's lookups.
#define SHADING_NO_LIGHTING 1
#include "material_lighting.hlsli"
#include "ray_scene.hlsli"
#include "gi_probes.hlsli"
#include "gi_guide.hlsli"

Probe_Grid frame_probe_grid() {
	return load_probe_grid(push.grid, push.grid_offset);
}

// A probe that a job updates.
struct Probe {
	uint level;
	uint storage;
	float3 position;
	float distance;
};

Probe job_probe(Probe_Grid grid, uint job_index) {
	uint job = cn_buffer(grid.jobs).Load(grid.jobs_offset + job_index * 4);
	Probe probe;
	probe.level = job >> 24;
	probe.storage = job & 0xffffff;
	Probe_Level level = grid.levels[probe.level];
	probe.position = probe_position(level, probe_cell(level, probe.storage));
	probe.distance = probe_distance(level);
	return probe;
}

// Probe_Rays is how a probe's rays are drawn this update: the first fibonacci of them a spherical Fibonacci set of that
// many points, which alone give the distances and the back faces, so the probes' visibility sees every direction alike,
// and the rest from the guide's cell, where its light is (see docs/rendering/global-illumination.md#guided-probe-rays).
struct Probe_Rays {
	uint fibonacci;
	uint guided;
	uint cell;
};

// probe_rays is a probe's split of its rays: guided rays only where its level has a guide, and its cell there was built
// for the probe's world cell with light in it, so a cell that the box moved over takes the Fibonacci set alone.
Probe_Rays probe_rays(Probe_Grid grid, Probe probe) {
	Probe_Rays r;
	r.fibonacci = grid.rays;
	r.guided = 0;
	r.cell = probe.level * PROBE_COUNT + probe.storage;
	if (grid.guide == 0 || grid.guide_rays == 0 || probe.level >= grid.guide_levels) {
		return r;
	}
	int3 key = grid.guide_keys[probe.level].xyz + probe_cell(grid.levels[probe.level], probe.storage);
	if (guide_cell_valid(grid.guide, r.cell, key)) {
		r.guided = min(grid.guide_rays, grid.rays);
		r.fibonacci = grid.rays - r.guided;
	}
	return r;
}

// probe_ray is the direction of a probe's ray, the same in the trace and the update. A guided ray is a point of the R2
// sequence, shifted for each probe and update, warped down the guide's quadtree, so the guided rays are stratified too.
float3 probe_ray(Probe_Grid grid, Probe probe, Probe_Rays r, uint ray) {
	if (ray < r.fibonacci) {
		return probe_fibonacci_direction(grid, ray, r.fibonacci);
	}
	uint state = lowbias32(r.cell * 0x9e3779b9u ^ lowbias32(grid.guide_seed));
	float2 offset = float2(random_unit(state), random_unit(state));
	float2 u = frac(offset + float(ray - r.fibonacci) * float2(0.75487766, 0.56984029));
	return guide_sphere_warp(grid.guide, r.cell, u);
}

// probe_ray_weight is a ray's weight in the update's sums, against a ray of a Fibonacci set of all of the probe's rays:
// by the maximum heuristic, each direction counts from the set that is denser there, by that set's own density, so the
// Fibonacci rays carry the dim sky and the guided rays the bright light, and the sums are the light's in expectation.
// It is 1 without guided rays.
float probe_ray_weight(Probe_Grid grid, Probe_Rays r, uint ray, float3 d) {
	if (r.guided == 0) {
		return 1;
	}
	float n = r.fibonacci + r.guided;
	float fibonacci = r.fibonacci / (4 * GUIDE_PI);
	float guided = r.guided * guide_sphere_pdf(grid.guide, r.cell, d);
	if (ray < r.fibonacci) {
		return fibonacci >= guided ? n / r.fibonacci : 0;
	}
	return guided > fibonacci ? n / (4 * GUIDE_PI * guided) : 0;
}

#endif
