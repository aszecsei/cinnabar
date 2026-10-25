// The fog volume's injection without ray tracing (see fog_inject.hlsli).
#include "fog_inject.hlsli"

[numthreads(4, 4, 4)]
void cs_main(uint3 id : SV_DispatchThreadID) {
	fog_inject(id);
}
