#include "cinnabar.hlsli"

// Matches Reset_Constants in game.odin.
struct Push {
	uint count;
};
CN_PUSH_CONSTANTS(Push, push);

// The cull pass counts visible objects up from zero.
[numthreads(1, 1, 1)]
void cs_main() {
	cn_rw_buffer(push.count).Store(0, 0);
}
