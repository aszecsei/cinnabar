// A light as the shaders take it, which every pass that lights or shadows reads (see
// docs/rendering/lighting-and-shadows.md#lights-and-clusters).
#ifndef LIGHT_RECORD_HLSLI
#define LIGHT_RECORD_HLSLI

static const uint LIGHT_DIRECTIONAL = 0;
static const uint LIGHT_POINT = 1;
static const uint LIGHT_SPOT = 2;
static const uint LIGHT_QUAD = 3;
static const uint LIGHT_DISK = 4;
static const uint LIGHT_LINE = 5;
// Light_Record's flags.
static const uint LIGHT_TWO_SIDED = 1;
// The light's shadow is the virtual shadow map (see virtual_shadow.hlsli).
static const uint LIGHT_VIRTUAL_SHADOW = 2;
// The clouds shadow the light (see cloud_shadow.hlsli).
static const uint LIGHT_CLOUD_SHADOW = 4;
// The forward pass darkens the light by the contact shadows too (see light_shadow in material_lighting.hlsli).
static const uint LIGHT_CONTACT_SHADOW = 8;

// Matches Light_Record in lib/engine/render/lights.odin. position is relative to the camera, and direction is where
// the light travels. A spot light's falloff is saturate(cos * spot_scale + spot_offset), squared. shadow is the light's
// first shadow view, and mask its channel of the shadow mask, or -1 for none. An area light's position is its middle,
// extent is its half size along its +x, and extent_y a quad's half height, a disk's radius along its +y, or a line's
// radius; its color is a point light's that is as bright. A directional light's extent.x is the tangent of its angular
// radius, and a point or a spot light's its source radius in meters (see light_size).
struct Light_Record {
	float3 position;
	float range;
	float3 color;
	uint type;
	float3 direction;
	float spot_scale;
	float spot_offset;
	int shadow;
	int mask;
	uint flags;
	float3 extent;
	float extent_y;
};

// light_size is how big a light is to its shadows (see docs/rendering/lighting-and-shadows.md#soft-shadows): a directional
// light's angular radius as its tangent, which is its disk's radius 1 m away, and any other light's radius in meters. An
// area light's is the radius of a sphere with its quad's or its disk's area, or its line's half length. A size of 0 is
// a point, whose shadows are hard. Matches light_size in lib/engine/render/lights.odin.
float light_size(Light_Record l) {
	switch (l.type) {
	case LIGHT_QUAD:
		// sqrt(4 * half_x * half_y / pi)
		return sqrt(1.2732395 * length(l.extent) * l.extent_y);
	case LIGHT_DISK:
		return sqrt(length(l.extent) * l.extent_y);
	case LIGHT_LINE:
		return length(l.extent);
	default:
		return l.extent.x;
	}
}

#endif
