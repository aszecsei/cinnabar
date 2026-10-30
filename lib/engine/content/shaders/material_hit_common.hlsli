// What hit shading's shaders share (see docs/rendering/ray-scene.md#hit-shading): a material's hit pass and the
// fallback bin each shade the rays of one bin, a thread each, and rebuild the triangle that a ray hit from its record.
// They include material_common.hlsli with MATERIAL_HIT 1 first, so push is the bin's Hit_Push.
#ifndef MATERIAL_HIT_COMMON_HLSLI
#define MATERIAL_HIT_COMMON_HLSLI

// hit_ray is the ray that a thread of the bin's dispatch shades, and false past the bin's rays.
bool hit_ray(uint thread, out uint ray) {
	ByteAddressBuffer bins = cn_buffer(push.bins);
	ray = 0;
	if (thread >= bins.Load(HIT_BIN_COUNTS + push.bin * 4)) {
		return false;
	}
	ray = cn_buffer(push.order).Load((bins.Load(HIT_BIN_OFFSETS + push.bin * 4) + thread) * 4);
	return true;
}

// A ray's hit as a point of its triangle. position is relative to the render origin, and the directions are in the
// world. geometric is the triangle's normal by its winding, and facing it turned toward the ray's origin. lod is the
// level that a texture of one texel would be sampled at (see cn_hit_lod).
struct Hit_Triangle {
	Hit_Record hit;
	Hit_Submesh submesh;
	float3 position;
	float3 local;
	float3 normal;
	float4 tangent;
	float2 uv0;
	float2 uv1;
	float4 color;
	float3 direction;
	float3 geometric;
	float3 facing;
	bool front;
	float lod;
};

// load_hit_triangle reads a ray's hit, and interpolates its triangle's corners by its barycentrics. A texture's level
// follows the ray's cone (Akenine-Möller et al., "Texture Level of Detail Strategies for Real-Time Ray Tracing"): the
// cone's width over the triangle's texels per meter, wider where the ray meets the triangle edge on.
Hit_Triangle load_hit_triangle(uint ray) {
	Hit_Triangle tri;
	Hit_Record hit = load_hit(push.hits, ray);
	tri.hit = hit;
	uint slot = hit.instance & HIT_SLOT_MASK;
	Hit_Instance record = cn_buffer(push.hit_instances).Load<Hit_Instance>(push.hit_instances_offset + slot * sizeof(Hit_Instance));
	Mesh_Record m = cn_buffer(frame.meshes).Load<Mesh_Record>(frame.meshes_offset + record.mesh * sizeof(Mesh_Record));
	Instance_Record instance = cn_buffer(frame.instances).Load<Instance_Record>(slot * sizeof(Instance_Record));
	tri.submesh = (Hit_Submesh)0;
	if (hit.entry != ~0u) {
		tri.submesh = cn_buffer(push.hit_submeshes).Load<Hit_Submesh>(push.hit_submeshes_offset + hit.entry * sizeof(Hit_Submesh));
	}
	float2 b = float2(hit.barycentrics & 0xffff, hit.barycentrics >> 16) / 65535.0;
	float3 w = float3(1 - b.x - b.y, b.x, b.y);
	Mesh_Vertex v[3];
	float3 corners[3];
	[unroll] for (uint k = 0; k < 3; k++) {
		v[k] = read_vertex(m, mesh_index(m, hit.primitive * 3 + k));
		corners[k] = transform_point(instance.rows, v[k].local);
	}
	tri.local = v[0].local * w.x + v[1].local * w.y + v[2].local * w.z;
	tri.position = corners[0] * w.x + corners[1] * w.y + corners[2] * w.z;
	tri.normal = normalize(transform_direction(instance.rows, v[0].normal * w.x + v[1].normal * w.y + v[2].normal * w.z));
	float3 tangent = transform_direction(instance.rows, v[0].tangent * w.x + v[1].tangent * w.y + v[2].tangent * w.z);
	tri.tangent = float4(normalize(tangent), v[0].bitangent_sign);
	tri.uv0 = v[0].uv0 * w.x + v[1].uv0 * w.y + v[2].uv0 * w.z;
	tri.uv1 = v[0].uv1 * w.x + v[1].uv1 * w.y + v[2].uv1 * w.z;
	tri.color = v[0].color * w.x + v[1].color * w.y + v[2].color * w.z;
	tri.direction = hit_unpack_unit(hit.direction);
	tri.front = (hit.instance & HIT_FRONT) != 0;
	float3 cross_world = cross(corners[1] - corners[0], corners[2] - corners[0]);
	float world_area = length(cross_world);
	tri.geometric = world_area > 0 ? cross_world / world_area : tri.normal;
	tri.facing = dot(tri.geometric, tri.direction) < 0 ? tri.geometric : -tri.geometric;
	float2 t1 = v[1].uv0 - v[0].uv0;
	float2 t2 = v[2].uv0 - v[0].uv0;
	float uv_area = abs(t1.x * t2.y - t1.y * t2.x);
	float incidence = max(abs(dot(tri.geometric, tri.direction)), 0.1);
	tri.lod = 0.5 * log2(max(uv_area, 1e-20) / max(world_area, 1e-20)) + log2(max(hit.cone_width, 1e-12) / incidence);
	return tri;
}

// store_hit_surface writes a ray's surface.
void store_hit_surface(uint ray, Hit_Surface s) {
	cn_rw_buffer(push.surfaces).Store<Hit_Surface>(ray * sizeof(Hit_Surface), s);
}

#endif
