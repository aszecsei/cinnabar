// What the global illumination's shaders share (see docs/rendering/global-illumination.md#global-illumination): their constants, the
// cascades' layout and the probes' positions. The cascades are screen-space radiance cascades. Cascade k has a probe
// every spacing << k pixels, each with (directions << k)^2 directions over the sphere, folded into an octahedron, so
// every cascade has about as many texels as the others. Its rays trace one interval of distance, four times as long
// as the cascade before's, and its texels hold the light that they found and the share of light from beyond that gets
// through. The cascades are one texture, each in its own rows. With the world probes, what lies beyond the screen and
// beyond the last cascade is the probes' light, not the ambient light's.
#ifndef GI_COMMON_HLSLI
#define GI_COMMON_HLSLI

#include "ambient.hlsli"
#include "cinnabar.hlsli"
#include "gi_probes.hlsli"

// Matches Gi_Constants in lib/engine/render/gi.odin. previous maps a position relative to the camera to last frame's
// clip space, the camera's motion included. right, up and forward are the view's axes in the world; projection holds
// the camera's x and y scales and its near plane. region is the size of one cascade's rows, and cascade the cascade
// that a merge pass writes.
struct Gi_Constants {
	float4x4 previous;
	float4 right;
	float4 up;
	float4 forward;
	float4 projection;
	float4 ambient[4];
	uint depth;
	uint stencil;
	uint normals;
	uint velocity;
	uint lit;
	uint lit_valid;
	uint cascades;
	uint sampler_index;
	uint history_diffuse;
	uint history_specular;
	uint out_diffuse;
	uint out_specular;
	uint valid;
	uint frame;
	uint cascade;
	uint cascade_count;
	uint2 size;
	uint2 lit_size;
	uint2 region;
	uint scene;
	uint exposure;
	float interval_scale;
	float max_frames;
	// The level's probe spacing, and each ray's steps (see GI_PARAMS).
	uint spacing;
	uint steps;
	// Whether the world probes are on, and their Probe_Grid in the upload ring.
	uint probes;
	uint probe_grid;
	uint probe_grid_offset;
	// The level's directions across the first cascade's octahedron.
	uint directions;
};
CN_PASS_CONSTANTS(Gi_Constants, constants);

// Matches VIEW_MODEL_STENCIL in lib/engine/render/renderer.odin.
static const uint VIEW_MODEL_STENCIL = 1;

uint cascade_spacing(uint k) {
	return constants.spacing << k;
}

uint cascade_directions(uint k) {
	return constants.directions << k;
}

uint2 cascade_probes(uint k) {
	uint spacing = cascade_spacing(k);
	return (constants.size + spacing - 1) / spacing;
}

// The texel of a cascade's probe and direction, in the cascades' texture.
uint2 cascade_texel(uint k, uint2 probe, uint2 direction) {
	return probe * cascade_directions(k) + direction + uint2(0, k * constants.region.y);
}

// octahedral_point is the point on the octahedron |x| + |y| + |z| = 1 at a place in the folded square, before it is
// normalized into a direction.
float3 octahedral_point(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return n;
}

float3 octahedral(float2 p) {
	return normalize(octahedral_point(p));
}

float2 octahedral_encode(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	return p;
}

// direction_of is the direction in the world at a place in a direction texel, each coordinate in [0, 1).
float3 direction_of(uint2 texel, uint directions, float2 within) {
	return octahedral((float2(texel) + within) / directions * 2 - 1);
}

// direction_weight is how much a direction texel's light counts in the cosine-weighted mean around a normal, up to a
// factor that every texel shares. With 6 or more directions across, it is the cosine at the texel's center times the
// solid angle there, which is the square's area over |p|^3. With 4, the cosine alone is nearer the true mean: the
// texels are so large that the cosine and the light vary across each, and the solid angle makes the error larger
// (see gi_test.odin).
float direction_weight(uint2 texel, uint directions, float3 normal) {
	float3 p = octahedral_point((float2(texel) + 0.5) / directions * 2 - 1);
	if (directions < 6) {
		return saturate(dot(normalize(p), normal));
	}
	float l2 = dot(p, p);
	return max(dot(p, normal), 0) / (l2 * l2);
}

// The ambient light from a direction.
float3 sky_light(float3 direction) {
	return ambient_light(constants.ambient, direction);
}

// beyond_light is the light from a direction that reaches a point relative to the camera, with its surface's normal,
// from beyond what the cascades trace: the world probes' radiance, or the ambient light without them.
float3 beyond_light(float3 p, float3 normal, float3 direction) {
	float3 light;
	if (constants.probes != 0 && sample_probes(load_probe_grid(constants.probe_grid, constants.probe_grid_offset), p, normal, direction, true, light)) {
		return light;
	}
	return sky_light(direction);
}

// surrounding_light is the cosine-weighted mean light around a normal at a point relative to the camera: the world
// probes', or the ambient light's along the normal without them.
float3 surrounding_light(float3 p, float3 normal) {
	float3 light;
	if (constants.probes != 0 && sample_probes(load_probe_grid(constants.probe_grid, constants.probe_grid_offset), p, normal, normal, false, light)) {
		return light;
	}
	return sky_light(normal);
}

float interleaved_noise(float2 pixel) {
	return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

// A pixel's surface: its position relative to the camera and its view depth. It has none where nothing drew, and the
// view model's pixels have none either: the view model is not where it seems to be in the world.
bool surface_at(int2 pixel, out float3 position, out float z) {
	float depth = cn_texture(constants.depth).Load(int3(pixel, 0)).r;
	bool view_model = (cn_stencil_texture(constants.stencil).Load(int3(pixel, 0)).g & VIEW_MODEL_STENCIL) != 0;
	z = constants.projection.z / max(depth, 1e-7);
	float2 ndc = float2((pixel.x + 0.5) / constants.size.x * 2 - 1, 1 - (pixel.y + 0.5) / constants.size.y * 2);
	float2 xy = ndc / constants.projection.xy * z;
	position = constants.right.xyz * xy.x + constants.up.xyz * xy.y + constants.forward.xyz * z;
	return depth > 0 && !view_model;
}

// probe_pixel is the pixel that a cascade's probe sits on: its tile's center, inside the screen.
int2 probe_pixel(uint k, uint2 probe) {
	uint spacing = cascade_spacing(k);
	return min(int2(probe * spacing + spacing / 2), int2(constants.size) - 1);
}

// PLANE_TOLERANCE is how far from a surface's tangent plane, as a share of its view depth, another probe's surface can
// be and still count as the same surface, so probes on a slanted face count as fully as those on one facing the camera.
static const float PLANE_TOLERANCE = 0.03;

// probe_weight is how much a probe's light counts at a surface: fully on the same surface, and very little elsewhere,
// so a surface where no probe matches still takes its nearest probes' light rather than none.
float probe_weight(float3 position, float3 normal, float z, int2 probe_pixel) {
	float3 probe_position;
	float probe_z;
	if (!surface_at(probe_pixel, probe_position, probe_z)) {
		return 0;
	}
	return abs(dot(probe_position - position, normal)) <= PLANE_TOLERANCE * z ? 1 : 1e-4;
}

// pixel_meters is the size of a pixel at a view depth.
float pixel_meters(float z) {
	return 2 * z / (constants.size.y * constants.projection.y);
}

// The distance at which cascade k's interval starts: they grow four times longer each, from a length that scales
// with the probe's depth, so a cascade covers about as many pixels at every depth.
float interval_start(uint k, float z) {
	float base = constants.interval_scale * constants.spacing * pixel_meters(z);
	return base * ((float)(1u << (2 * k)) - 1) / 3;
}

float3 octahedral_normal(int2 pixel) {
	return octahedral(cn_texture(constants.normals).Load(int3(pixel, 0)).xy);
}

#endif
