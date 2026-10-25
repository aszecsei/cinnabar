// The fog volume's injection on a device with Ray_Query: the lights that have a channel of the shadow mask are traced
// (see fog_inject.hlsli).
#define FOG_TRACE 1
#include "fog_inject.hlsli"

[numthreads(4, 4, 4)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	fog_inject(id);
}
