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

#endif
