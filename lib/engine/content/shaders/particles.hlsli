// GPU particles (see docs/rendering/particles.md#particles): the pool's particles, the frame's emitters, and the
// update pass's constants, which particle_update.hlsl reads.
#ifndef PARTICLES_HLSLI
#define PARTICLES_HLSLI

#include "cinnabar.hlsli"

// Matches format.Effect_Shape, format.Effect_Module_Kind and format.Effect_Curve.
static const uint SHAPE_POINT = 0;
static const uint SHAPE_SPHERE = 1;
static const uint SHAPE_BOX = 2;
static const uint SHAPE_CONE = 3;
static const uint MODULE_GRAVITY = 0;
static const uint MODULE_DRAG = 1;
static const uint MODULE_NOISE = 2;
static const uint MODULE_COLLIDE = 3;
static const uint CURVE_COLOR = 0;
static const uint CURVE_SIZE = 1;
static const uint CURVE_EMISSION = 2;
// Matches format.EFFECT_CURVE_SAMPLES.
static const uint CURVE_SAMPLES = 64;
// Matches EMITTER_RIBBON in lib/engine/render/particles.odin.
static const uint EMITTER_RIBBON = 1;

// Matches PARTICLE_SIZE in lib/engine/render/particles.odin: a particle of the pool, relative to its system's anchor.
// A lifetime of 0 is a dead particle.
struct Particle {
	float3 position;
	float age;
	float3 velocity;
	float lifetime;
	float rotation;
	float spin;
	uint seed;
	float padding;
};

// Matches Emitter_Record in lib/engine/render/particles.odin: an emitter of a system this frame. row0 to row2 are the
// system's pose relative to its anchor; anchor and previous_anchor are the anchor relative to this frame's and last
// frame's camera. modules and curves are the first of its modules and curve rows in the frame's. delta is the time
// that the system steps this frame, and time its age, which the noise moves with.
struct Emitter_Record {
	uint first;
	uint capacity;
	uint spawn;
	uint reset;
	float4 row0;
	float4 row1;
	float4 row2;
	float3 anchor;
	uint seed;
	float3 previous_anchor;
	uint module_count;
	float2 lifetime;
	float2 speed;
	float2 spin;
	uint shape;
	float3 shape_size;
	uint texture;
	uint2 flipbook;
	float flipbook_rate;
	float softness;
	uint modules;
	uint curves;
	float delta;
	float time;
	// A ribbon's emitter spawns in its range's order, from head, so its particles stay in the order that they spawned.
	uint head;
	uint flags;
};

// Matches format.Effect_Module.
struct Effect_Module {
	uint kind;
	uint3 padding;
	float4 values;
};

// Matches Particle_Constants in lib/engine/render/particles.odin. history is last frame's view depth in w and world
// normal in xyz, from last frame's camera, whose projection previous_view_projection is.
struct Particle_Constants {
	float4x4 previous_view_projection;
	uint emitters;
	uint emitters_offset;
	uint modules;
	uint modules_offset;
	uint curves;
	uint curves_offset;
	uint pool;
	uint counters;
	uint sprites;
	uint sprite_count;
	uint history;
	uint has_history;
	uint2 history_size;
	float near;
	uint3 padding;
};
CN_PASS_CONSTANTS(Particle_Constants, constants);

// random is a hash of a state, which it steps, as a float in [0, 1) (PCG).
float random(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967296.0;
}

Emitter_Record load_emitter(uint index) {
	return cn_buffer(constants.emitters).Load<Emitter_Record>(constants.emitters_offset + index * sizeof(Emitter_Record));
}

Effect_Module load_module(uint index) {
	return cn_buffer(constants.modules).Load<Effect_Module>(constants.modules_offset + index * sizeof(Effect_Module));
}

// curve_at is a curve's value at a point of a particle's life, from 0 to 1, between its baked samples.
float4 curve_at(uint row, float t) {
	ByteAddressBuffer curves = cn_buffer(constants.curves);
	float x = saturate(t) * (CURVE_SAMPLES - 1);
	uint i = min(uint(x), CURVE_SAMPLES - 2);
	uint base = constants.curves_offset + row * CURVE_SAMPLES * 16;
	return lerp(curves.Load<float4>(base + i * 16), curves.Load<float4>(base + (i + 1) * 16), x - i);
}

#endif
