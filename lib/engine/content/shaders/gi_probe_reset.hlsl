// The world probes' reset (see docs/rendering/global-illumination.md#world-probes): a thread for each probe of each
// level. A probe whose cell was outside its level's box before the box moved this frame holds another cell's light, so
// its state goes back to no updates, and it counts for nothing until its first update.
#include "gi_probe_pass.hlsli"

[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	Probe_Grid grid = frame_probe_grid();
	uint l = id.x / PROBE_COUNT;
	uint storage = id.x % PROBE_COUNT;
	if (l >= grid.level_count) {
		return;
	}
	Probe_Level level = grid.levels[l];
	int3 before = probe_cell(level, storage) + level.delta.xyz;
	if (any(before < 0) || any(before >= PROBE_GRID)) {
		cn_rw_buffer(grid.states_out).Store(probe_state_index(l, storage), 0);
	}
}
