#include "cinnabar.hlsli"

// The editor's icons for lights, volumes, cameras and reflection probes (see docs/editor/viewport.md#viewport): a disc that
// faces the camera, a fixed size on screen, with a glyph for its kind in its light's color, or for a reflection probe a
// sphere that reflects its cube. It draws into the debug layer, and its entity's ID and depth into the ID buffer and
// the scene's depth, so the pick and the outline find it as they find a mesh.

// Matches Icons_Constants in icons.odin.
struct Push {
	float4x4 view_projection;
	uint instances;
	uint instances_offset;
	float2 viewport;
	// The icon's diameter in pixels.
	float size;
	// The reflection probes' cube array, 0 without it, and the sampler that it is read with.
	uint cubes;
	uint cube_sampler;
	uint padding;
};
CN_PUSH_CONSTANTS(Push, push);

// Matches Icon_Instance in icons.odin: a position relative to the view, the kind, the color, the ID, and a reflection
// probe's cube of the array, -1 for none.
struct Instance {
	float3 position;
	uint kind;
	float3 color;
	uint id;
	int cube;
	uint3 padding;
};

// Match editor.Icon_Kind.
static const uint ICON_POINT = 0;
static const uint ICON_SPOT = 1;
static const uint ICON_DIRECTIONAL = 2;
static const uint ICON_AREA = 3;
static const uint ICON_VOLUME = 4;
static const uint ICON_CAMERA = 5;
static const uint ICON_REFLECTION_PROBE = 6;

struct Varyings {
	float4 position : SV_Position;
	float2 uv : TEXCOORD0;
	nointerpolation float3 color : COLOR0;
	nointerpolation uint kind : KIND;
	nointerpolation uint id : ID;
	nointerpolation int cube : CUBE;
	// The direction from the eye to the icon, which a probe's sphere reflects.
	nointerpolation float3 toward : TOWARD;
};

struct Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
};

static const float2 CORNERS[6] = {float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1)};

Varyings vs_main(uint vertex_id : SV_VertexID) {
	Instance instance = cn_buffer(push.instances).Load<Instance>(push.instances_offset + (vertex_id / 6) * sizeof(Instance));
	float2 corner = CORNERS[vertex_id % 6];
	float4 clip = mul(push.view_projection, float4(instance.position, 1));
	Varyings o;
	// Behind the camera, the icon falls outside the clip volume.
	o.position = clip.w > 0 ? clip + float4(corner * push.size / push.viewport * clip.w, 0, 0) : float4(0, 0, -1, 1);
	// A little nearer than its middle, so an icon on a surface wins the depth test. The depth is reversed.
	o.position.z = min(o.position.z * 1.01, o.position.w);
	o.uv = corner * float2(1, -1);
	o.color = instance.color;
	o.kind = instance.kind;
	o.id = instance.id;
	o.cube = instance.cube;
	o.toward = normalize(instance.position);
	return o;
}

// probe_sphere is a reflection probe's icon: a mirror ball, its normal from the disc's uv about the direction to the
// icon and the world's up, reflecting the probe's cube at its sharpest mip. Before its first capture, it is grey and
// lit from above.
float3 probe_sphere(Varyings i) {
	float2 p = i.uv / 0.95;
	float z = sqrt(saturate(1 - dot(p, p)));
	float3 forward = i.toward;
	float3 side = abs(forward.y) < 0.99 ? float3(0, 1, 0) : float3(1, 0, 0);
	float3 right = normalize(cross(side, forward));
	float3 up = cross(forward, right);
	float3 n = right * p.x + up * p.y - forward * z;
	if (i.cube < 0 || push.cubes == 0) {
		return float3(0.35, 0.35, 0.38) * (0.6 + 0.4 * n.y);
	}
	float3 r = reflect(forward, n);
	TextureCubeArray<float4> cubes = cn_texture_cube_array(push.cubes);
	return cubes.SampleLevel(cn_sampler(push.cube_sampler), float4(r, i.cube), 0).rgb;
}

float box(float2 p, float2 half_size) {
	float2 d = abs(p) - half_size;
	return length(max(d, 0)) + min(max(d.x, d.y), 0);
}

float segment(float2 p, float2 a, float2 b) {
	float2 pa = p - a;
	float2 ba = b - a;
	return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

// glyph is the distance from the kind's glyph, negative inside.
float glyph(uint kind, float2 p) {
	switch (kind) {
	case ICON_POINT:
		return length(p) - 0.32;
	case ICON_SPOT: {
		// A cone that opens downward from a bulb.
		float cone = max(box(p - float2(0, -0.05), float2(0.45, 0.35)), abs(p.x) - (0.1 + (0.3 - p.y) * 0.6));
		return min(cone, length(p - float2(0, 0.38)) - 0.14);
	}
	case ICON_DIRECTIONAL: {
		float d = length(p) - 0.22;
		[unroll] for (uint k = 0; k < 8; k++) {
			float angle = k * 0.785398;
			float2 direction = float2(cos(angle), sin(angle));
			d = min(d, segment(p, direction * 0.36, direction * 0.58) - 0.05);
		}
		return d;
	}
	case ICON_AREA:
		return box(p, float2(0.38, 0.38));
	case ICON_VOLUME:
		return abs(box(p, float2(0.42, 0.42))) - 0.06;
	default: {
		// A camera: a body and a lens.
		float body = box(p - float2(-0.1, 0), float2(0.32, 0.24));
		float lens = max(box(p - float2(0.36, 0), float2(0.14, 0.24)), abs(p.y) - (0.08 + (p.x - 0.22) * 0.9));
		return min(body, lens);
	}
	}
}

Targets ps_main(Varyings i) {
	float pixel = 2 / push.size;
	float disc = length(i.uv) - 0.95;
	clip(-disc + pixel * 0.5);
	float edge = saturate(0.5 - disc / pixel);
	float3 color;
	if (i.kind == ICON_REFLECTION_PROBE) {
		color = probe_sphere(i);
	} else {
		float inside = saturate(0.5 - glyph(i.kind, i.uv) / pixel);
		float3 background = float3(0.08, 0.08, 0.1);
		color = lerp(background, i.color, inside);
	}
	// A thin light rim, so the icon shows on a dark scene.
	color = lerp(color, float3(0.7, 0.7, 0.75), saturate(1 - abs(disc + pixel) / pixel) * 0.6);
	Targets o;
	o.color = float4(color, 0.9 * edge);
	o.id = i.id;
	return o;
}
