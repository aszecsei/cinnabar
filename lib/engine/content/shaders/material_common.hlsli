// What every material's shaders share (see docs/rendering/materials.md#materials): the frame's constants, the GPU scene's
// records, the inputs that a material's evaluate reads, and what a shading model is given.
#ifndef MATERIAL_COMMON_HLSLI
#define MATERIAL_COMMON_HLSLI

#include "cinnabar.hlsli"

// Matches Frame_Constants in lib/engine/render/scene.odin. Positions in the GPU scene are relative to the render
// origin, and the view's are relative to the camera, which is camera_offset from the origin. A shadow view's copy has
// its own view_projection, which also takes positions relative to the camera. The view model's copy has its projection,
// and offsets of 0, because its instances are relative to the camera already.
struct Frame_Constants {
	float4x4 view_projection;
	// Last frame's, and last frame's camera relative to this frame's origin, for the velocities.
	float4x4 previous_view_projection;
	// The camera's projection, whose screen tiles the clusters are, in every view's copy.
	float4x4 cluster_view_projection;
	float4 camera_offset;
	float4 previous_camera_offset;
	// The camera's offset from the render origin in every view's copy, the view model's included, so a point's position
	// relative to the origin is its position relative to the camera plus this (see world_position).
	float4 origin_offset;
	// The ambient light from above and from below, until global illumination.
	float4 sky_color;
	float4 ground_color;
	// The view depth at which each shadow cascade ends.
	float4 cascade_splits;
	// The view's frustum relative to the camera, which the mesh shader path culls meshlets with: a point is inside when
	// dot(plane.xyz, p) + plane.w >= 0 for every one.
	float4 planes[6];
	// Where the view looks from, relative to the camera, which a meshlet's normal cone is tested from: a point when w is
	// 1, or the direction that it looks along when w is 0.
	float4 cull_eye;
	// The camera's right and up in the world, in every view's copy, and last frame's camera's, which billboards face
	// (see billboard_rows), so a shadow view draws a billboard as the camera sees it.
	float4 camera_right;
	float4 camera_up;
	float4 previous_camera_right;
	float4 previous_camera_up;
	// Bindless indices: the GPU scene's instances, this frame's draw records, the mesh records and the material table.
	uint instances;
	uint draws;
	uint meshes;
	uint materials;
	uint sampler_index;
	float time;
	// The mesh records, the material table and the lights are in the upload ring, at these offsets of its buffer.
	uint meshes_offset;
	uint materials_offset;
	// The lights: the directional ones first, then the punctual ones that the clusters index.
	uint lights;
	uint lights_offset;
	uint directional_count;
	// Each cluster's offset and count in the index list, by its tile and its depth slice (see cluster_of).
	uint clusters;
	uint cluster_indices;
	uint cluster_columns;
	uint cluster_rows;
	float slice_scale;
	float slice_bias;
	float near;
	// The shadow maps' comparison sampler and their views.
	uint shadow_sampler;
	uint shadow_views;
	uint shadow_views_offset;
	// Whether the clusters were made this frame; without them, the punctual lights are left out.
	uint clustered;
	// The frame's size in pixels.
	float2 screen_size;
	// The camera's subpixel jitter for temporal AA, as the offset that it adds to positions in normalized device
	// coordinates, which view_projection holds. The velocities leave it out.
	float2 jitter;
	// The exposure that pre-exposes the scene's colors: the float at 0 of this buffer (see
	// docs/rendering/post-processing.md#post-processing).
	uint exposure;
	// Whether the fog volume in Material_Push exists, the bilinear sampler that it is read with, and the share of the
	// volume's width and height that the screen covers (see fog_at).
	uint fog;
	uint fog_sampler;
	float2 fog_scale;
	// Whether Material_Push has the global illumination.
	uint gi;
	// The area lights' lookup tables and their sampler (see ltc.hlsli).
	uint ltc_matrix;
	uint ltc_amplitude;
	uint ltc_sampler;
	// The editor's debug view, a render.Debug_View (see docs/rendering/post-processing.md#debug-views). The forward pass draws the
	// views below; the others come from the frame's textures.
	uint debug_view;
	// The fog volume's depth slices, and how many bilinear comparisons a shadow map lookup takes (see shadow_map).
	uint fog_slices;
	uint shadow_filter;
	// The mesh shader path's level of detail (see lod_selected): the camera's pixels per unit of error at a distance of
	// 1, over the error threshold in pixels, and the nearest distance that an error projects from. Every view has the
	// camera's, so each draws the same levels as the camera does.
	float lod_scale;
	float lod_near;
	// Last frame's time, which a material's displacement takes for the previous pose (see Vertex_Inputs).
	float previous_time;
	// The frame's Surface_Records, in the upload ring at this offset of its buffer (see material_patch.hlsli).
	uint surfaces;
	uint surfaces_offset;
	// The particle ribbons' vertices (see material_ribbon.hlsli).
	uint ribbon_vertices;
};
CN_PASS_CONSTANTS(Frame_Constants, frame);

// Match render.Debug_View. The shaded views are exposed and tone mapped as the scene is; the others are colors as they
// are.
static const uint DEBUG_LIT = 0;
static const uint DEBUG_LIGHTING_ONLY = 1;
static const uint DEBUG_DIRECT_LIGHT = 2;
static const uint DEBUG_INDIRECT_LIGHT = 3;
static const uint DEBUG_FOG = 4;
static const uint DEBUG_ALBEDO = 5;
static const uint DEBUG_LIGHT_COMPLEXITY = 6;
static const uint DEBUG_SHADOW_CASCADES = 7;
// From the frame's textures, but the transparent surfaces' moments pass counts their layers for it.
static const uint DEBUG_TRANSPARENT_OVERDRAW = 17;
// The mesh shader path's meshlets, each in a color of its own, and their levels of detail as heat colors.
static const uint DEBUG_MESHLETS = 18;
static const uint DEBUG_LOD_DEPTH = 19;
// The shading model's emission alone, exposed as the scene is.
static const uint DEBUG_EMISSION = 20;

// load_screen reads a screen-sized texture of the frame at a pixel. In its place, a frame without it pushes a 1x1
// default texture, such as the white one without ambient occlusion, which a Load outside it would read as 0; the pixel
// is clamped to the texture, so the default's one texel is read everywhere.
float4 load_screen(uint index, float2 pixel) {
	Texture2D<float4> texture = cn_texture(index);
	uint2 size;
	texture.GetDimensions(size.x, size.y);
	return texture.Load(int3(min(uint2(pixel), size - 1), 0));
}

// heat is a color for a value from 0 to 1: blue, cyan, green, yellow, red.
float3 heat(float t) {
	t = saturate(t);
	return saturate(float3(1.5 - abs(4 * t - 3), 1.5 - abs(4 * t - 2), 1.5 - abs(4 * t - 1)));
}

// hash_color is a bright color for an ID, so neighbouring ones differ. Matches hash_color in debug_view.hlsl.
float3 hash_color(uint id) {
	uint h = id * 2654435761u;
	h ^= h >> 15;
	h *= 2246822519u;
	h ^= h >> 13;
	return float3(h & 0xff, (h >> 8) & 0xff, (h >> 16) & 0xff) / 255.0 * 0.75 + 0.25;
}

// Matches Material_Push in lib/engine/render/scene.odin: the frame's textures, which exist only once the frame's
// passes record, so the forward pass pushes them. The shadow maps' atlas, the ray-traced shadow mask, the ambient
// occlusion in r, the integrated fog volume (see docs/rendering/fog.md#volumetric-fog), and the global illumination's diffuse
// and specular light (see docs/rendering/global-illumination.md#global-illumination). The transparent pass of moment-based transparency
// also has the moments, and transmittance set, so each surface is dimmed by those in front of it (see
// material_transparent.hlsli). A compute pass that includes the light loop defines MATERIAL_PUSH as its own push
// constants, which start with shadow_atlas and shadow_mask.
#ifndef MATERIAL_PUSH
struct Material_Push {
	uint shadow_atlas;
	uint shadow_mask;
	uint ambient_occlusion;
	uint fog;
	uint gi_diffuse;
	uint gi_specular;
	uint moments_zeroth;
	uint moments;
	uint transmittance;
};
#define MATERIAL_PUSH Material_Push
#endif
CN_PUSH_CONSTANTS(MATERIAL_PUSH, push);

// Matches ID_ENTITY_BITS and ID_ENTITY_MASK in lib/engine/render/renderer.odin: an ID buffer value has its entity
// in its low bits and its submesh above them.
static const uint ID_ENTITY_BITS = 25;
static const uint ID_ENTITY_MASK = (1u << ID_ENTITY_BITS) - 1;

// Matches Draw_Record in lib/engine/render/scene.odin: one indirect draw, by its draw ID. material is the byte offset
// of the draw's parameter block in the material table. mesh has the submesh's index above ID_ENTITY_BITS. first and
// count are the submesh's indices, or on the mesh shader path its meshlets. bound is how far the material's
// displacement may move a vertex, in meters, which the mesh shader path's culling adds to each meshlet's sphere.
struct Draw_Record {
	uint instance;
	uint mesh;
	uint first;
	uint material;
	uint count;
	float bound;
	uint2 padding;
};

// Matches Mesh_Record in lib/engine/render/scene.odin. impostor is the impostor's atlas, impostor_size a frame's side
// in texels, and impostor_sphere the sphere in the mesh's space that the atlas's frames see (see
// material_impostor.hlsli).
static const uint MESH_INDEX32 = 1;
static const uint MESH_UV1 = 2;
static const uint MESH_COLOR = 4;
struct Mesh_Record {
	uint positions;
	uint attributes;
	uint indices;
	uint attribute_stride;
	uint flags;
	uint meshlets;
	uint meshlet_vertices;
	uint meshlet_triangles;
	uint impostor;
	uint impostor_size;
	uint2 padding;
	float4 impostor_sphere;
};

// Matches Instance_Record in lib/engine/render/scene.odin: the pose relative to the render origin as the rows of a
// 3x4 matrix, last frame's, and the entity's value in the editor's ID buffer.
struct Instance_Record {
	float4 rows[3];
	float4 previous_rows[3];
	uint id;
	uint flags;
	uint2 padding;
};

// What a material's evaluate reads. position is relative to the camera, object_position is in the mesh's own space,
// and the directions are in the world.
struct Material_Inputs {
	float3 position;
	float3 object_position;
	float3 normal;
	// The bitangent is cross(normal, tangent.xyz) * tangent.w.
	float4 tangent;
	float2 uv0;
	float2 uv1;
	float4 color;
	// Toward the camera.
	float3 view;
	bool front_facing;
	// The frame's time in seconds, which wraps every hour. A displacement's previous pose takes last frame's.
	float time;
};

// What a material's displace reads (see docs/rendering/materials.md#vertex-displacement): a vertex before its offset, placed
// by its instance's pose. position is relative to the camera and the directions are in the world, as Material_Inputs
// has them. time is the frame's, or last frame's for the previous pose, so an offset that moves with time gives a
// velocity.
struct Vertex_Inputs {
	float3 position;
	float3 object_position;
	float3 normal;
	float4 tangent;
	float2 uv0;
	float2 uv1;
	float4 color;
	float time;
};

// Matches Light_Record in lib/engine/render/lights.odin. position is relative to the camera, and direction is where
// the light travels. A spot light's falloff is saturate(cos * spot_scale + spot_offset), squared. shadow is the light's
// first shadow view, and mask its channel of the shadow mask, or -1 for none. An area light's position is its middle,
// extent is its half size along its +x, and extent_y a quad's half height, a disk's radius along its +y, or a line's
// radius; its color is a point light's that is as bright.
static const uint LIGHT_DIRECTIONAL = 0;
static const uint LIGHT_POINT = 1;
static const uint LIGHT_SPOT = 2;
static const uint LIGHT_QUAD = 3;
static const uint LIGHT_DISK = 4;
static const uint LIGHT_LINE = 5;
// Light_Record's flags.
static const uint LIGHT_TWO_SIDED = 1;
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

// Matches Shadow_View in lib/engine/render/shadows.odin: a shadow map's projection of positions relative to the
// camera, as the rows of its matrix, its rectangle of the atlas in UV (offset, scale), and the size of one of its
// texels: in meters for an orthographic view, at a distance of 1 m for a perspective one (perspective is 1).
struct Shadow_View {
	float4 rows[4];
	float4 rect;
	float texel;
	uint perspective;
	float2 padding;
};

// What a shading model shades: the point, its normal after the material's normal map, and the direction to the camera.
struct Shading_Point {
	float3 position;
	float3 normal;
	float3 view;
};

// A light that reaches the point: the direction toward it, and its light there.
struct Light {
	float3 direction;
	float3 color;
};

// An area light that reaches the point (see docs/rendering/lighting-and-shadows.md#area-lights): its shape relative to the point, and its
// radiance after its range's window and its shadow, which a shading model multiplies by ltc_integral of its lobes.
// shape is LIGHT_QUAD, LIGHT_DISK or LIGHT_LINE. axis_x and axis_y are a quad's or a disk's half sizes, and axis_x a
// line's half length, with radius its radius, 0 for an ideal line, whose radiance is per meter of its width.
struct Area_Light {
	uint shape;
	float3 center;
	float3 axis_x;
	float3 axis_y;
	// Where a quad or a disk shines, unless it is two-sided.
	float3 normal;
	float radius;
	bool two_sided;
	float3 color;
};

// The light from everything else: diffuse, and along the reflection.
struct Indirect {
	float3 diffuse;
	float3 specular;
};

static const float PI = 3.14159265;

// world_position is a point's position relative to the render origin, which snaps to a grid of 1024 m, from its
// position relative to the camera. It stays where it is while the camera moves, and a pattern whose period divides
// 1024 m goes on without a seam when the origin moves (see docs/rendering/gpu-scene.md#gpu-scene).
float3 world_position(Material_Inputs inputs) {
	return inputs.position + frame.origin_offset.xyz;
}

float3 world_position(Vertex_Inputs v) {
	return v.position + frame.origin_offset.xyz;
}

// vertex_material_inputs gives a vertex as Material_Inputs, so that the nodes, custom HLSL and material functions of a
// graph's vertex offset read what they read in evaluate. There is no face yet, so it is the front, and the view is
// the direction from the vertex to the camera.
Material_Inputs vertex_material_inputs(Vertex_Inputs v) {
	Material_Inputs inputs;
	inputs.position = v.position;
	inputs.object_position = v.object_position;
	inputs.normal = v.normal;
	inputs.tangent = v.tangent;
	inputs.uv0 = v.uv0;
	inputs.uv1 = v.uv1;
	inputs.color = v.color;
	inputs.view = normalize(-v.position);
	inputs.front_facing = true;
	inputs.time = v.time;
	return inputs;
}

// frame_exposure scales the colors that the forward pass writes, so the scene is pre-exposed.
float frame_exposure() {
	return cn_buffer(frame.exposure).Load<float>(0);
}

// cn_sample samples a material's texture with the frame's sampler. A material samples through it, so a later path that
// shades without derivatives (a visibility buffer) can give its own.
float4 cn_sample(uint texture_index, float2 uv) {
	return cn_texture(texture_index).Sample(cn_sampler(frame.sampler_index), uv);
}

// cn_sample_grad samples with the derivatives given, for a sample inside a loop or a branch, where the pixel shader's
// own derivatives are not defined.
float4 cn_sample_grad(uint texture_index, float2 uv, float2 uv_dx, float2 uv_dy) {
	return cn_texture(texture_index).SampleGrad(cn_sampler(frame.sampler_index), uv, uv_dx, uv_dy);
}

// cn_sample_level samples one mip, for a vertex shader, which has no derivatives, or a sample whose level the material
// chooses.
float4 cn_sample_level(uint texture_index, float2 uv, float level) {
	return cn_texture(texture_index).SampleLevel(cn_sampler(frame.sampler_index), uv, level);
}

// cn_normal_map reads a tangent-space normal from a two-channel normal map (BC5), which keeps x and y.
float3 cn_normal_map(uint texture_index, float2 uv) {
	float2 xy = cn_sample(texture_index, uv).xy * 2 - 1;
	return float3(xy, sqrt(saturate(1 - dot(xy, xy))));
}

float3 cn_normal_map_level(uint texture_index, float2 uv, float level) {
	float2 xy = cn_sample_level(texture_index, uv, level).xy * 2 - 1;
	return float3(xy, sqrt(saturate(1 - dot(xy, xy))));
}

// octahedral unfolds a unit vector from the square [-1, 1]², as the cooker folded it.
float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// octahedral_encode folds a unit vector into the square [-1, 1]², as octahedral unfolds it.
float2 octahedral_encode(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	return p;
}

float2 snorm16(uint word) {
	int2 v = int2(int(word << 16) >> 16, int(word) >> 16);
	return max(float2(v) / 32767.0, -1.0);
}

float2 unorm16(uint word) {
	return float2(word & 0xffff, word >> 16) / 65535.0;
}

float4 unpack_unorm8(uint c) {
	return float4(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, c >> 24) / 255.0;
}

#include "ltc.hlsli"
#include "material_parallax.hlsli"

#endif
