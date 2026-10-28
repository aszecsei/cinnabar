// The impostor path of the opaque material passes (see docs/rendering/gpu-scene.md#impostors): one quad over a mesh's
// bounding sphere, facing the view, whose pixels find the surface in the mesh's impostor atlas and evaluate the
// material there, so the impostor is the material's, lit as the mesh is. Culling draws an item's impostor in place of
// its mesh past the mesh's coarsest level of detail. Each pixel picks one of the three views of the atlas nearest the
// direction it is seen from, at random by their weights, which temporal AA blends. Each draw is a submesh's, and draws
// only the texels of its submesh.
#ifndef MATERIAL_IMPOSTOR_HLSLI
#define MATERIAL_IMPOSTOR_HLSLI

#include "material_forward.hlsli"
#include "material_prepass.hlsli"

// Match IMPOSTOR_FRAMES and IMPOSTOR_TEXEL_FLIP in lib/engine/asset/format/mesh.odin.
static const uint IMPOSTOR_FRAMES = 8;
static const uint IMPOSTOR_TEXEL_FLIP = 0x100;

// Matches Impostor_Texel in lib/engine/asset/format/mesh.odin: the UV as two halves, the depth as a half with the
// flags above it, and the normal and the tangent, octahedral in snorm16 pairs, all in the mesh's space.
struct Impostor_Texel {
	uint uv;
	uint depth_flags;
	uint normal;
	uint tangent;
};

struct Impostor_Varyings {
	float4 position : SV_Position;
	// The point of the quad, relative to the camera.
	float3 world : POSITION1;
	nointerpolation uint draw : DRAW;
};

// The quad's two triangles, which cull no faces.
static const float2 IMPOSTOR_CORNERS[6] = {float2(-1, -1), float2(-1, 1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(1, -1)};

// impostor_direction is the direction toward the viewer of a frame of the atlas. Matches impostor_direction in
// tools/cook/impostors.odin.
float3 impostor_direction(uint2 frame) {
	return octahedral(float2(frame) / (IMPOSTOR_FRAMES - 1) * 2 - 1);
}

// impostor_basis is a frame's right and up, for the direction toward its viewer. Matches impostor_basis in
// tools/cook/impostors.odin.
void impostor_basis(float3 direction, out float3 right, out float3 up) {
	float3 forward = -direction;
	float3 reference = abs(direction.y) > 0.999 ? float3(0, 0, 1) : float3(0, 1, 0);
	right = normalize(cross(reference, forward));
	up = cross(forward, right);
}

// view_ray is the view's ray through a point relative to the camera: from the view's eye, or for a view along a
// direction (a cascade's), along it through the point.
void view_ray(float3 p, out float3 origin, out float3 direction) {
	if (frame.cull_eye.w != 0) {
		origin = frame.cull_eye.xyz;
		direction = p - origin;
	} else {
		origin = p;
		direction = frame.cull_eye.xyz;
	}
}

// impostor_vertex is a corner of the quad: in front of the sphere, toward the view, as wide as the sphere, so it covers
// the sphere's outline from a point outside it.
Impostor_Varyings impostor_vertex(uint vertex_id) {
	Draw_Record d = load_draw();
	Mesh_Record m = load_mesh(d);
	Instance_Record instance = load_instance(d);
	float3 scales = axis_scales(instance.rows);
	float radius = m.impostor_sphere.w * max(scales.x, max(scales.y, scales.z));
	float3 center = transform_point(instance.rows, m.impostor_sphere.xyz) - frame.camera_offset.xyz;
	float3 origin, toward;
	view_ray(center, origin, toward);
	float3 direction = -normalize(toward);
	float3 right, up;
	impostor_basis(direction, right, up);
	float2 corner = IMPOSTOR_CORNERS[vertex_id];
	Impostor_Varyings o;
	o.world = center + (right * corner.x + up * corner.y + direction) * radius;
	o.position = clip_position(o.world);
	o.draw = CN_DRAW_ID;
	return o;
}

Impostor_Varyings vs_impostor_forward(uint vertex_id : SV_VertexID) {
	return impostor_vertex(vertex_id);
}

Impostor_Varyings vs_impostor_prepass(uint vertex_id : SV_VertexID) {
	return impostor_vertex(vertex_id);
}

Impostor_Varyings vs_impostor_depth(uint vertex_id : SV_VertexID) {
	return impostor_vertex(vertex_id);
}

// inverse3 is the inverse of the rows' rotation and scale: its columns are the cross products of the rows.
float3x3 inverse3(float3x3 m) {
	float3 r0 = cross(m[1], m[2]);
	float3 r1 = cross(m[2], m[0]);
	float3 r2 = cross(m[0], m[1]);
	return transpose(float3x3(r0, r1, r2)) / dot(m[0], r0);
}

// impostor_texel reads a frame's texel at a point of its plane, in the sphere's radii from its center.
Impostor_Texel impostor_texel(Mesh_Record m, uint2 frame_index, float2 p) {
	uint size = m.impostor_size;
	uint2 texel = min(uint2(saturate(float2(p.x, -p.y) * 0.5 + 0.5) * size), size - 1);
	uint index = ((frame_index.y * IMPOSTOR_FRAMES + frame_index.x) * size + texel.y) * size + texel.x;
	return cn_buffer(m.impostor).Load<Impostor_Texel>(index * sizeof(Impostor_Texel));
}

// impostor_noise is a number from 0 to 1 for a pixel, different in each frame: interleaved gradient noise.
float impostor_noise(float2 pixel) {
	pixel += frac(frame.time * 7.71) * float2(47, 17);
	return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

// The surface that an impostor's pixel sees, as the passes shade it: v as the vertex paths interpolate it, the
// inputs that evaluate reads, the point last frame, relative to last frame's camera, and the depth.
struct Impostor_Surface {
	Varyings v;
	Material_Inputs inputs;
	float3 previous;
	float depth;
};

// impostor_surface finds the surface that a pixel of an impostor sees, or fails where it sees none of its submesh.
// The pixel's ray meets the chosen frame's plane through the sphere's center, then the plane at the depth found there,
// twice, so the texel is where the ray meets the surface that the frame saw. bias moves the point away from the view
// along the ray, in the frame's texels, which a shadow map's depth takes.
bool impostor_surface(Impostor_Varyings i, float bias, out Impostor_Surface hit) {
	hit = (Impostor_Surface)0;
	Draw_Record d = cn_buffer(frame.draws).Load<Draw_Record>(i.draw * sizeof(Draw_Record));
	Mesh_Record m = load_mesh(d);
	Instance_Record instance = load_instance(d);
	float3x3 rotation = float3x3(instance.rows[0].xyz, instance.rows[1].xyz, instance.rows[2].xyz);
	float3x3 inverse = inverse3(rotation);
	float3 translation = float3(instance.rows[0].w, instance.rows[1].w, instance.rows[2].w) - frame.camera_offset.xyz;
	float3 origin, toward;
	view_ray(i.world, origin, toward);
	// The ray in the sphere's space: from its center, in its radii.
	float4 sphere = m.impostor_sphere;
	float3 q = (mul(inverse, origin - translation) - sphere.xyz) / sphere.w;
	float3 ray = normalize(mul(inverse, toward));
	float3 seen = frame.cull_eye.w != 0 ? normalize(q) : -ray;

	// The three frames nearest the direction that the pixel is seen from, and their weights.
	float2 g = (octahedral_encode(seen) * 0.5 + 0.5) * (IMPOSTOR_FRAMES - 1);
	float2 cell = min(floor(g), IMPOSTOR_FRAMES - 2);
	float2 f = g - cell;
	uint2 frames[3];
	float3 weights;
	if (f.x + f.y < 1) {
		frames[0] = uint2(cell);
		frames[1] = uint2(cell) + uint2(1, 0);
		frames[2] = uint2(cell) + uint2(0, 1);
		weights = float3(1 - f.x - f.y, f.x, f.y);
	} else {
		frames[0] = uint2(cell) + uint2(1, 1);
		frames[1] = uint2(cell) + uint2(0, 1);
		frames[2] = uint2(cell) + uint2(1, 0);
		weights = float3(f.x + f.y - 1, 1 - f.x, 1 - f.y);
	}
	float noise = impostor_noise(i.position.xy);
	uint k = noise < weights.x ? 0 : (noise < weights.x + weights.y ? 1 : 2);

	float3 direction = impostor_direction(frames[k]);
	float3 right, up;
	impostor_basis(direction, right, up);
	float facing = dot(ray, direction);
	if (abs(facing) < 1e-4) {
		return false;
	}
	float depth = 0;
	float2 p = 0;
	Impostor_Texel texel = (Impostor_Texel)0;
	for (uint step = 0; step < 3; step++) {
		float3 at = q + ray * ((depth - dot(q, direction)) / facing);
		p = float2(dot(at, right), dot(at, up));
		if (any(abs(p) > 1)) {
			return false;
		}
		texel = impostor_texel(m, frames[k], p);
		if ((texel.depth_flags >> 16 & 0xff) == 0) {
			return false;
		}
		depth = f16tof32(texel.depth_flags);
	}
	uint submesh = d.mesh >> ID_ENTITY_BITS;
	if ((texel.depth_flags >> 16 & 0xff) != submesh + 1) {
		return false;
	}
	float3 local = sphere.xyz + sphere.w * (right * p.x + up * p.y + direction * depth);
	local += ray * (bias * 2 * sphere.w / m.impostor_size);
	float3 normal = octahedral(snorm16(texel.normal));
	float3 tangent = octahedral(snorm16(texel.tangent));
	float sign = (texel.depth_flags >> 16 & IMPOSTOR_TEXEL_FLIP) != 0 ? -1 : 1;

	Varyings v;
	v.world = transform_point(instance.rows, local) - frame.camera_offset.xyz;
	float4 clip = clip_position(v.world);
	hit.depth = clip.z / clip.w;
	v.position = float4(i.position.xy, hit.depth, 1);
	v.local = local;
	v.normal = normalize(transform_direction(instance.rows, normal));
	v.tangent = float4(normalize(transform_direction(instance.rows, tangent)), sign);
	v.uv0 = float2(f16tof32(texel.uv), f16tof32(texel.uv >> 16));
	v.uv1 = 0;
	v.color = 1;
	v.material = d.material;
	v.id = instance.id | (d.mesh & ~ID_ENTITY_MASK);
	// Past the coarsest level: the Lod_Depth debug view shows it as the deepest.
	v.cluster = 8u << MESHLET_DEPTH_SHIFT;
	hit.v = v;
	hit.inputs = material_inputs(v, true);
	hit.previous = transform_point(instance.previous_rows, local) - frame.previous_camera_offset.xyz;
	return true;
}

struct Impostor_Targets {
	float4 color : SV_Target0;
	uint id : SV_Target1;
	float depth : SV_Depth;
};

Impostor_Targets ps_impostor_forward(Impostor_Varyings i) {
	Impostor_Surface hit;
	if (!impostor_surface(i, 0, hit)) {
		discard;
	}
	Surface s = evaluate(hit.inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	Impostor_Targets o;
	o.color = float4(forward_color(hit.v, hit.inputs, s, 1), 1);
	o.id = hit.v.id;
	o.depth = hit.depth;
	return o;
}

struct Impostor_Prepass_Targets {
	float2 normal : SV_Target0;
	float2 velocity : SV_Target1;
	float depth : SV_Depth;
};

Impostor_Prepass_Targets ps_impostor_prepass(Impostor_Varyings i) {
	Impostor_Surface hit;
	if (!impostor_surface(i, 0, hit)) {
		discard;
	}
	Surface s = evaluate(hit.inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	Impostor_Prepass_Targets o;
	o.normal = octahedral_encode(shading_normal(hit.inputs, s));
	float4 current = clip_position(hit.v.world);
	float4 previous = mul(frame.previous_view_projection, float4(hit.previous, 1));
	o.velocity = (current.xy / current.w - frame.jitter - previous.xy / previous.w) * float2(0.5, -0.5);
	o.depth = hit.depth;
	return o;
}

// A shadow map's depth is a texel farther from the light, since a pixel writes its depth itself, which the pipeline's
// depth bias does not move.
float ps_impostor_depth(Impostor_Varyings i) : SV_Depth {
	Impostor_Surface hit;
	if (!impostor_surface(i, 1, hit)) {
		discard;
	}
#if MATERIAL_MASKED
	Surface s = evaluate(hit.inputs);
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	return hit.depth;
}

#endif
