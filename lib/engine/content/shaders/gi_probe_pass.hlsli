// What the world probes' passes share (see docs/rendering/global-illumination.md#world-probes): their push constants,
// which start with Material_Push's shadow textures, so the light loop's lookups compile, and the probe of a job. The
// passes set the camera's frame constants.
#ifndef GI_PROBE_PASS_HLSLI
#define GI_PROBE_PASS_HLSLI

// Matches Probe_Push in lib/engine/render/gi_probes.odin. lights lists the punctual lights that the hits see, after the
// directional ones. depth is this frame's, and lit the global illumination's lit scene of last frame, when lit_valid.
struct Probe_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint grid;
	uint grid_offset;
	uint hits;
	uint surfaces;
	uint rays;
	uint accel;
	uint lights;
	uint lights_offset;
	uint light_count;
	uint ray_count;
	uint depth;
	uint lit;
	uint lit_valid;
	uint padding;
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
