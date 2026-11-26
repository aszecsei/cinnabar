// The GI's emitters (see docs/rendering/global-illumination.md#emitters), in phases, a dispatch each:
//   Jobs: a thread for each job writes a hit record at a point of its triangle, seen from the front, for hit shading
//   to evaluate the triangle's material there. Its cone is as wide as the triangle, so the textures give the
//   triangle's mean.
//   Gather: a thread for each job reads its point's emission: a discovery job writes its luminance into the results,
//   which the host reads back, and a refresh job blends it into its triangle's cell of the radiance pool. A point
//   whose material was not evaluated, the fallback's, or a masked material's hole, counts for nothing.
//   Build: a thread for each listed triangle places it relative to the camera, with its emission, its area and its
//   power, the emission's luminance times the area, twice for a two-sided one.
//   Scan: one group sums the powers into the distribution that the hits draw triangles from, each triangle's end of
//   the cumulative share, and the total.
// The pass constants are the camera's frame constants.
#define MATERIAL_PUSH Emitter_Push
// Matches Emitter_Push in lib/engine/render/gi_emitters.odin.
struct Emitter_Push {
	uint phase;
	uint count;
	uint jobs;
	uint jobs_offset;
	uint table;
	uint table_offset;
	uint hits;
	uint surfaces;
	uint pool;
	uint results;
	uint samples;
	uint hit_instances;
	uint hit_instances_offset;
};
#include "material_common.hlsli"
#include "ray_scene.hlsli"
#include "gi_emitter_samples.hlsli"
#include "hash.hlsli"

static const uint PHASE_JOBS = 0;
static const uint PHASE_GATHER = 1;
static const uint PHASE_BUILD = 2;
static const uint PHASE_SCAN = 3;
// Match lib/engine/render/gi_emitters.odin.
static const uint EMITTER_GROUP = 1024;
static const uint EMITTER_DISCOVERY = 0x80000000u;
static const float EMITTER_BLEND = 0.25;
static const uint SCAN_ITEMS = MAX_EMITTER_TRIANGLES / EMITTER_GROUP;

// Matches Emitter_Job in lib/engine/render/gi_emitters.odin.
struct Emitter_Job {
	uint slot;
	uint primitive;
	uint target;
	uint seed;
};

groupshared float g_sums[EMITTER_GROUP];

// Emitter_Corners are a triangle's corners relative to the render origin and its vertices' normal there.
struct Emitter_Corners {
	float3 p[3];
	float3 normal;
};

Emitter_Corners load_corners(uint slot, uint mesh, uint primitive) {
	Mesh_Record m = cn_buffer(frame.meshes).Load<Mesh_Record>(frame.meshes_offset + mesh * sizeof(Mesh_Record));
	Instance_Record instance = cn_buffer(frame.instances).Load<Instance_Record>(slot * sizeof(Instance_Record));
	Emitter_Corners c;
	float3 normal = 0;
	[unroll] for (uint k = 0; k < 3; k++) {
		Mesh_Vertex v = read_vertex(m, mesh_index(m, primitive * 3 + k));
		c.p[k] = transform_point(instance.rows, v.local);
		normal += transform_direction(instance.rows, v.normal);
	}
	c.normal = normal;
	return c;
}

void run_jobs(uint i) {
	Emitter_Job job = cn_buffer(push.jobs).Load<Emitter_Job>(push.jobs_offset + i * sizeof(Emitter_Job));
	Hit_Instance record = cn_buffer(push.hit_instances).Load<Hit_Instance>(push.hit_instances_offset + job.slot * sizeof(Hit_Instance));
	Emitter_Corners c = load_corners(job.slot, record.mesh, job.primitive);
	float3 cross_world = cross(c.p[1] - c.p[0], c.p[2] - c.p[0]);
	float area = 0.5 * length(cross_world);
	// The side that the vertices' normals face is the front.
	float3 front = dot(cross_world, c.normal) < 0 ? -cross_world : cross_world;
	front = area > 0 ? normalize(front) : float3(0, 1, 0);
	// A point uniform over the triangle.
	uint state = job.seed;
	float u1 = random_unit(state);
	float u2 = random_unit(state);
	float s = sqrt(u1);
	float2 b = float2(s * (1 - u2), s * u2);
	Hit_Record hit;
	hit.instance = job.slot | HIT_FRONT;
	hit.primitive = job.primitive;
	hit.barycentrics = uint(round(b.x * 65535)) | (uint(round(b.y * 65535)) << 16);
	hit.direction = hit_pack_unit(-front);
	hit.t = 1;
	hit.cone_width = sqrt(max(2 * area, 0));
	hit.bin = 0;
	hit.entry = 0;
	store_hit(push.hits, i, hit);
}

void run_gather(uint i) {
	Emitter_Job job = cn_buffer(push.jobs).Load<Emitter_Job>(push.jobs_offset + i * sizeof(Emitter_Job));
	Hit_Record hit = load_hit(push.hits, i);
	Hit_Surface s = load_hit_surface(push.surfaces, i);
	bool evaluated = hit.bin != 0 && (hit_flags(s) & (HIT_SURFACE_FALLBACK | HIT_SURFACE_CUTOUT)) == 0;
	float3 emission = hit_emission(s);
	if ((job.target & EMITTER_DISCOVERY) != 0) {
		float luminance = evaluated ? dot(emission, float3(0.2126, 0.7152, 0.0722)) : -1;
		cn_rw_buffer(push.results).Store((job.target & ~EMITTER_DISCOVERY) * 4, asuint(luminance));
		return;
	}
	if (!evaluated) {
		return;
	}
	RWByteAddressBuffer pool = cn_rw_buffer(push.pool);
	float4 cell = pool.Load<float4>(job.target * 16);
	float alpha = max(1 / (cell.w + 1), EMITTER_BLEND);
	pool.Store<float4>(job.target * 16, float4(lerp(cell.rgb, emission, alpha), min(cell.w + 1, 1 / EMITTER_BLEND)));
}

void run_build(uint t) {
	Emitter_Table_Header header = load_emitter_header(push.table, push.table_offset);
	// The listed submesh that holds the triangle: the last whose first triangle is at most t.
	uint lo = 0;
	uint hi = header.count;
	for (uint step = 0; step < 9 && hi - lo > 1; step++) {
		uint mid = (lo + hi) / 2;
		if (load_emitter_submesh(push.table, push.table_offset, mid).first_triangle <= t) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	Emitter_Submesh sub = load_emitter_submesh(push.table, push.table_offset, lo);
	uint local = t - sub.first_triangle;
	Emitter_Corners c = load_corners(sub.slot, sub.mesh, sub.first_primitive + local);
	float4 cell = cn_buffer(push.pool).Load<float4>((sub.radiance_base + local) * 16);
	float3 radiance = cell.w > 0 ? cell.rgb : 0;
	Emitter_Triangle tri;
	tri.p0 = c.p[0] - frame.camera_offset.xyz;
	tri.e1 = c.p[1] - c.p[0];
	tri.e2 = c.p[2] - c.p[0];
	float3 cross_world = cross(tri.e1, tri.e2);
	tri.area = 0.5 * length(cross_world);
	tri.radiance = pack_rgb9e5(radiance);
	tri.flags = (sub.flags & EMITTER_TWO_SIDED) | (dot(cross_world, c.normal) < 0 ? EMITTER_FLIPPED : 0);
	bool two_sided = (sub.flags & EMITTER_TWO_SIDED) != 0;
	float power = dot(unpack_rgb9e5(tri.radiance), float3(0.2126, 0.7152, 0.0722)) * tri.area * (two_sided ? 2 : 1);
	RWByteAddressBuffer samples = cn_rw_buffer(push.samples);
	samples.Store<Emitter_Triangle>(EMITTER_TRIANGLES_FIRST + t * sizeof(Emitter_Triangle), tri);
	samples.Store(EMITTER_SAMPLES_HEADER + t * 4, asuint(max(power, 0)));
}

void run_scan(uint thread) {
	RWByteAddressBuffer samples = cn_rw_buffer(push.samples);
	uint n = min(push.count, MAX_EMITTER_TRIANGLES);
	uint first = thread * SCAN_ITEMS;
	float sum = 0;
	for (uint k = 0; k < SCAN_ITEMS; k++) {
		uint t = first + k;
		if (t < n) {
			sum += asfloat(samples.Load(EMITTER_SAMPLES_HEADER + t * 4));
		}
	}
	g_sums[thread] = sum;
	GroupMemoryBarrierWithGroupSync();
	// An inclusive scan of the threads' sums, Hillis and Steele.
	for (uint offset = 1; offset < EMITTER_GROUP; offset <<= 1) {
		float add = thread >= offset ? g_sums[thread - offset] : 0;
		GroupMemoryBarrierWithGroupSync();
		g_sums[thread] += add;
		GroupMemoryBarrierWithGroupSync();
	}
	float total = g_sums[EMITTER_GROUP - 1];
	float running = g_sums[thread] - sum;
	float scale = total > 0 ? 1 / total : 0;
	for (uint j = 0; j < SCAN_ITEMS; j++) {
		uint t = first + j;
		if (t < n) {
			running += asfloat(samples.Load(EMITTER_SAMPLES_HEADER + t * 4));
			// The last triangle ends at 1 exactly, so a draw below 1 always finds one.
			float end = t == n - 1 ? 1 : running * scale;
			samples.Store(EMITTER_SAMPLES_HEADER + t * 4, asuint(end));
		}
	}
	if (thread == 0) {
		samples.Store2(0, uint2(total > 0 ? n : 0, asuint(total)));
	}
}

[numthreads(EMITTER_GROUP, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID, uint thread : SV_GroupIndex) {
	if (push.phase == PHASE_SCAN) {
		run_scan(thread);
		return;
	}
	if (id.x >= push.count) {
		return;
	}
	switch (push.phase) {
	case PHASE_JOBS:
		run_jobs(id.x);
		break;
	case PHASE_GATHER:
		run_gather(id.x);
		break;
	case PHASE_BUILD:
		run_build(id.x);
		break;
	}
}
