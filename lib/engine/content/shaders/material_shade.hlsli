// A material's shading from the visibility buffer (see docs/rendering/lighting-and-shadows.md#visibility-buffer):
// cs_shade shades the 2x2 quads of its bin, which visibility_bin.hlsl gave it, a thread for each pixel. A pixel is its
// material's when its stencil has VISIBILITY_STENCIL and its triangle was drawn with the material's pipeline. Each
// rebuilds its triangle from its draw, instance and meshlet, placed as the mesh shaders place it, takes its barycentrics from the camera's
// ray through the pixel, and fills Material_Inputs as the forward pass does. Then it shades as the forward pass does
// (see forward_color_at), and writes the scene's color and the entity's ID. The quad's threads give the derivatives
// that the material's samples take (see cn_sample): a pixel that is not the material's takes one of the quad's
// triangles of the material, so the quad's derivatives are its triangle's.
#include "material_forward.hlsli"

// Match visibility.odin: the bins' words, a bin for each pipeline, and the quads of a group.
static const uint SHADE_BINS = 256;
static const uint SHADE_BIN_COUNTS = 0;
static const uint SHADE_BIN_OFFSETS = 2 * SHADE_BINS * 4;
static const uint SHADE_GROUP_QUADS = 64;

// pixel_ray is the direction from the camera through a point of the screen, in pixels, relative to the camera: the
// point on the near plane, by the camera's inverse projection, with its jitter, whose columns are in the upload ring.
float3 pixel_ray(float4 inverse[4], float2 pixel) {
	float2 ndc = float2(pixel.x / frame.screen_size.x * 2 - 1, 1 - pixel.y / frame.screen_size.y * 2);
	// Reversed depth: the near plane is at 1.
	float4 p = inverse[0] * ndc.x + inverse[1] * ndc.y + inverse[2] + inverse[3];
	return p.xyz / p.w;
}

// ray_barycentrics are the barycentrics of where a ray from the camera meets a triangle's plane, which is the
// perspective-correct interpolation that rasterizing it gives.
float3 ray_barycentrics(float3 direction, float3 a, float3 b, float3 c) {
	float3 e1 = b - a;
	float3 e2 = c - a;
	float3 p = cross(direction, e2);
	float det = dot(e1, p);
	det = abs(det) > 1e-30 ? det : 1e-30;
	float3 t = -a;
	float u = dot(t, p) / det;
	float v = dot(direction, cross(t, e1)) / det;
	return float3(1 - u - v, u, v);
}

[numthreads(16, 16, 1)]
void cs_shade(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
	ByteAddressBuffer bins = cn_buffer(push.bins);
	uint quad = group.x * SHADE_GROUP_QUADS + (local.y / 2) * 8 + local.x / 2;
	// A whole quad leaves, so the quads left keep their four threads.
	if (quad >= bins.Load(SHADE_BIN_COUNTS + push.pipeline * 4)) {
		return;
	}
	uint packed = cn_buffer(push.order).Load((bins.Load(SHADE_BIN_OFFSETS + push.pipeline * 4) + quad) * 4);
	uint2 pixel = uint2(packed & 0xffff, packed >> 16) * 2 + (local.xy & 1);
	// The pixel is the material's when the visibility buffer shades it and its triangle is the pipeline's.
	uint4 value = 0;
	if (all(pixel < uint2(frame.screen_size))) {
		Texture2D<uint4> visibility = ResourceDescriptorHeap[push.visibility];
		uint4 vis = visibility.Load(int3(pixel, 0));
		uint stencil = cn_stencil_texture(push.stencil).Load(int3(pixel, 0)).g;
		if ((stencil & VISIBILITY_STENCIL) != 0 && vis.x != 0 && (vis.w >> VIS_PIPELINE_SHIFT) == push.pipeline) {
			value = vis;
		}
	}
	bool owned = value.x != 0;
	// The quad's first triangle of the material, which its other pixels take. Two triangles of the material in the quad
	// mix it, and its pixels' samples take the analytic derivatives of uv0.
	uint4 values[4] = {QuadReadLaneAt(value, 0), QuadReadLaneAt(value, 1), QuadReadLaneAt(value, 2), QuadReadLaneAt(value, 3)};
	uint4 first = 0;
	bool mixed = false;
	for (uint k = 0; k < 4; k++) {
		if (values[k].x != 0) {
			mixed = mixed || (first.x != 0 && any(values[k] != first));
			first = first.x == 0 ? values[k] : first;
		}
	}
	if (first.x == 0) {
		return;
	}
	value = owned ? value : first;

	// The triangle, placed as the mesh shaders place it (see cluster_vertex).
	Draw_Record d = cn_buffer(frame.draws).Load<Draw_Record>((value.x - 1) * sizeof(Draw_Record));
	Mesh_Record m = load_mesh(d);
	Instance_Record instance = draw_instance(d, value.y);
	Meshlet c = cn_buffer(m.meshlets).Load<Meshlet>(value.z * sizeof(Meshlet));
	uint corners = cn_buffer(m.meshlet_triangles).Load((c.triangle_offset + (value.w & VIS_TRIANGLE_MASK)) * 4);
	Material_Vertex v[3];
	for (uint i = 0; i < 3; i++) {
		uint index = cn_buffer(m.meshlet_vertices).Load((c.vertex_offset + ((corners >> (8 * i)) & 0xff)) * 4);
		v[i] = place_vertex(d, m, instance, index);
	}

	// The barycentrics at the pixel's center, and how they change a pixel to the right and a pixel down.
	ByteAddressBuffer inverse_buffer = cn_buffer(push.inverse);
	float4 inverse[4];
	for (uint j = 0; j < 4; j++) {
		inverse[j] = inverse_buffer.Load<float4>(push.inverse_offset + j * 16);
	}
	float2 center = float2(pixel) + 0.5;
	float3 b = ray_barycentrics(pixel_ray(inverse, center), v[0].world, v[1].world, v[2].world);
	float3 b_dx = ray_barycentrics(pixel_ray(inverse, center + float2(1, 0)), v[0].world, v[1].world, v[2].world) - b;
	float3 b_dy = ray_barycentrics(pixel_ray(inverse, center + float2(0, 1)), v[0].world, v[1].world, v[2].world) - b;
	cn_quad_exact = !mixed;
	cn_uv_dx = b_dx.x * v[0].uv0 + b_dx.y * v[1].uv0 + b_dx.z * v[2].uv0;
	cn_uv_dy = b_dy.x * v[0].uv0 + b_dy.y * v[1].uv0 + b_dy.z * v[2].uv0;

	// Material_Inputs as material_inputs gives them.
	params = cn_buffer(frame.materials).Load<Params>(frame.materials_offset + d.material);
	bool front = (value.w & VIS_FRONT) != 0;
	float3 world = b.x * v[0].world + b.y * v[1].world + b.z * v[2].world;
	Material_Inputs inputs;
	inputs.position = world;
	inputs.object_position = b.x * v[0].local + b.y * v[1].local + b.z * v[2].local;
	inputs.normal = normalize(b.x * v[0].normal + b.y * v[1].normal + b.z * v[2].normal);
	inputs.tangent = float4(normalize(b.x * v[0].tangent.xyz + b.y * v[1].tangent.xyz + b.z * v[2].tangent.xyz), v[0].tangent.w);
	inputs.uv0 = b.x * v[0].uv0 + b.y * v[1].uv0 + b.z * v[2].uv0;
	inputs.uv1 = b.x * v[0].uv1 + b.y * v[1].uv1 + b.z * v[2].uv1;
	inputs.color = b.x * v[0].color + b.y * v[1].color + b.z * v[2].color;
	inputs.view = normalize(-world);
	inputs.front_facing = front;
	inputs.time = frame.time;
#if MATERIAL_TWO_SIDED
	// A back face shades as the other side of the surface.
	if (!front) {
		inputs.normal = -inputs.normal;
	}
#endif
	Surface s = evaluate(inputs);
	// The prepass's depth, so the lighting's clusters and cascades are the forward pass's.
	float depth = cn_texture(push.depth).Load(int3(pixel, 0)).r;
	uint cluster = value.z | (c.counts >> 16) << MESHLET_DEPTH_SHIFT;
	float3 color = forward_color_at(world, float4(center, depth, 1), cluster, inputs, s, 1);

	if (owned) {
		RWTexture2D<float4> scene = cn_rw_texture(push.scene);
		scene[pixel] = float4(color, 1);
		RWTexture2D<uint> ids = ResourceDescriptorHeap[push.ids];
		ids[pixel] = v[0].id;
	}
	// The measurements, as the forward pass counts them (see count_quad): the quad's first pixel of the material
	// counts it, and its quads with two triangles in the high half.
	if (push.quad_counts != 0) {
		uint lane = (local.x & 1) | (local.y & 1) << 1;
		uint bit = owned ? 1u << lane : 0;
		uint live = bit | QuadReadAcrossX(bit) | QuadReadAcrossY(bit) | QuadReadAcrossDiagonal(bit);
		bool leader = bit != 0 && (live & (bit - 1)) == 0;
		if (leader) {
			RWTexture2D<uint> counts = ResourceDescriptorHeap[push.quad_counts - 1];
			InterlockedAdd(counts[pixel / 2], mixed ? 0x10001u : 1u);
		}
		if (push.shading_stats != 0) {
			uint quads = WaveActiveCountBits(leader);
			uint pixels = WaveActiveCountBits(owned);
			uint mixed_quads = WaveActiveCountBits(leader && mixed);
			if (WaveIsFirstLane()) {
				RWByteAddressBuffer stats = cn_rw_buffer(push.shading_stats - 1);
				stats.InterlockedAdd(SHADING_STATS_VISIBILITY_QUADS, quads);
				stats.InterlockedAdd(SHADING_STATS_VISIBILITY_PIXELS, pixels);
				stats.InterlockedAdd(SHADING_STATS_VISIBILITY_MIXED, mixed_quads);
			}
		}
	}
}
