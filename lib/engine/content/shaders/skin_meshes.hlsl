// Poses the vertices of each skinned entity's mesh by its skin's joint palette, one job each (see
// docs/rendering/gpu-scene.md#skinned-meshes). The mesh's rest vertices stay as they were cooked; a job writes the
// entity's own copies: the posed positions, last frame's posed positions, which the velocities take, and the posed
// attributes, with the normal and the tangent turned by the palette. Everything after this pass (the prepass, the
// shadow maps, the forward pass, the ray scene's structures and hit shading) reads the copies as a mesh's buffers.
#include "cinnabar.hlsli"
#include "mesh_encoding.hlsli"

// Matches Skin_Constants in lib/engine/render/skinning.odin. The jobs and the palette are in the upload ring, at these
// offsets of its buffer. A group row of a job dispatches stride threads, and each thread poses every stride-th vertex
// of the job's mesh from its own.
struct Skin_Constants {
	uint jobs;
	uint jobs_offset;
	uint palette;
	uint palette_offset;
	uint job_count;
	uint stride;
	uint2 padding;
};
CN_PASS_CONSTANTS(Skin_Constants, constants);

// Matches Skin_Job in lib/engine/render/skinning.odin: the buffers of the mesh's rest vertices and of the entity's
// copies, as bindless indices, the vertices' count and the job's joints, which start at first_joint among the palette's.
// attribute_words is the mesh's attribute stride in words.
static const uint SKIN_RESET = 1;
struct Skin_Job {
	uint rest_positions;
	uint rest_attributes;
	uint skin;
	uint attribute_words;
	uint positions;
	uint previous;
	uint attributes;
	uint vertex_count;
	uint first_joint;
	uint joint_count;
	uint flags;
	uint padding;
};

// Matches Mesh_Skin_Vertex in lib/engine/asset/format/mesh.odin: four joints, then four weights, as 16-bit halves of
// two words each. The weights are unorm16.
struct Skin_Vertex {
	uint2 joints;
	uint2 weights;
};

static const uint SKIN_GROUP_SIZE = 64;

// joint_index is the k-th joint of a vertex, held to the skin's joints.
uint joint_index(uint2 joints, uint k) {
	uint word = k < 2 ? joints.x : joints.y;
	return (k & 1) != 0 ? word >> 16 : word & 0xffff;
}

float joint_weight(uint2 weights, uint k) {
	uint word = k < 2 ? weights.x : weights.y;
	return float((k & 1) != 0 ? word >> 16 : word & 0xffff);
}

// A normal or a tangent turned by the blended palette's rotation and scale, and made a unit vector again. One that
// the palette would collapse keeps its rest direction.
float3 skin_direction(float3x3 m, float3 d) {
	float3 turned = mul(m, d);
	float squared = dot(turned, turned);
	return squared > 1e-20 ? turned * rsqrt(squared) : d;
}

uint pack_snorm16(float2 p) {
	int2 v = int2(round(clamp(p, -1, 1) * 32767.0));
	return uint(v.x & 0xffff) | (uint(v.y & 0xffff) << 16);
}

[numthreads(SKIN_GROUP_SIZE, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID) {
	if (group.y >= constants.job_count) {
		return;
	}
	Skin_Job job = cn_buffer(constants.jobs).Load<Skin_Job>(constants.jobs_offset + group.y * sizeof(Skin_Job));
	ByteAddressBuffer rest_positions = cn_buffer(job.rest_positions);
	ByteAddressBuffer rest_attributes = cn_buffer(job.rest_attributes);
	ByteAddressBuffer skin = cn_buffer(job.skin);
	RWByteAddressBuffer positions = cn_rw_buffer(job.positions);
	RWByteAddressBuffer previous = cn_rw_buffer(job.previous);
	RWByteAddressBuffer attributes = cn_rw_buffer(job.attributes);
	bool reset = (job.flags & SKIN_RESET) != 0;
	for (uint vertex = id.x; vertex < job.vertex_count; vertex += constants.stride) {
		Skin_Vertex sv = skin.Load<Skin_Vertex>(vertex * sizeof(Skin_Vertex));
		// The blended palette: the weights' sum is 1 for a cooked skin, and a vertex without any weight stays at rest.
		float total = 0;
		for (uint k = 0; k < 4; k++) {
			total += joint_weight(sv.weights, k);
		}
		float4 rows[3] = {float4(1, 0, 0, 0), float4(0, 1, 0, 0), float4(0, 0, 1, 0)};
		if (total > 0 && job.joint_count > 0) {
			rows[0] = rows[1] = rows[2] = 0;
			for (uint k = 0; k < 4; k++) {
				float weight = joint_weight(sv.weights, k) / total;
				if (weight == 0) {
					continue;
				}
				uint joint = min(joint_index(sv.joints, k), job.joint_count - 1);
				uint at = constants.palette_offset + (job.first_joint + joint) * 48;
				ByteAddressBuffer palette = cn_buffer(constants.palette);
				rows[0] += weight * palette.Load<float4>(at);
				rows[1] += weight * palette.Load<float4>(at + 16);
				rows[2] += weight * palette.Load<float4>(at + 32);
			}
		}
		float3 rest = rest_positions.Load<float3>(vertex * 12);
		float4 p = float4(rest, 1);
		float3 posed = float3(dot(rows[0], p), dot(rows[1], p), dot(rows[2], p));
		if (reset) {
			previous.Store<float3>(vertex * 12, posed);
		} else {
			previous.Store<float3>(vertex * 12, positions.Load<float3>(vertex * 12));
		}
		positions.Store<float3>(vertex * 12, posed);

		// The attributes: the normal and the tangent are re-folded, the bitangent's sign stays, and the rest copy.
		uint base = vertex * job.attribute_words * 4;
		float3x3 rotation = float3x3(rows[0].xyz, rows[1].xyz, rows[2].xyz);
		uint normal_word = rest_attributes.Load(base);
		uint tangent_word = rest_attributes.Load(base + 4);
		float3 normal = skin_direction(rotation, octahedral(snorm16(normal_word)));
		float3 tangent = skin_direction(rotation, octahedral(unorm16(tangent_word) * 2 - 1));
		float2 folded = saturate(octahedral_encode(tangent) * 0.5 + 0.5);
		uint2 quantized = uint2(round(folded * 65535.0));
		attributes.Store(base, pack_snorm16(octahedral_encode(normal)));
		attributes.Store(base + 4, quantized.x | (((quantized.y & ~1u) | ((tangent_word >> 16) & 1u)) << 16));
		for (uint w = 2; w < job.attribute_words; w++) {
			attributes.Store(base + w * 4, rest_attributes.Load(base + w * 4));
		}
	}
}
