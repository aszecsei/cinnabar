// The sprites' dispatches (see docs/rendering/transparency.md#sprites): one thread turns the frame's count of sprites,
// the CPU's and those that GPU passes appended, up to its capacity, into the arguments of the indirect dispatches that
// run a thread or a group for each sprite: sprite_bin.hlsl's groups of 64, and sprite_light.hlsl's group for each sprite
// in rows of SPRITE_LIGHT_COLUMNS.
#include "cinnabar.hlsli"
#include "sprites.hlsli"

// Matches Arguments_Push in lib/engine/render/sprites.odin. arguments holds a Sprite_Arguments.
struct Push {
	uint count;
	uint capacity;
	uint arguments;
	uint padding;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches Sprite_Arguments in lib/engine/render/sprites.odin: two Dispatch_Indirect_Args.
struct Sprite_Arguments {
	uint3 bin;
	uint3 light;
	uint2 padding;
};

[numthreads(1, 1, 1)]
void cs_main() {
	uint count = sprite_count(push.count, push.capacity);
	Sprite_Arguments a;
	a.bin = uint3((count + 63) / 64, 1, 1);
	a.light = uint3(min(count, SPRITE_LIGHT_COLUMNS), (count + SPRITE_LIGHT_COLUMNS - 1) / SPRITE_LIGHT_COLUMNS, 1);
	a.padding = 0;
	cn_rw_buffer(push.arguments).Store<Sprite_Arguments>(0, a);
}
