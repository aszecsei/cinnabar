// The voxelization of every opaque and masked material (see docs/rendering/global-illumination.md#voxel-cones): each
// level of the clipmap draws the scene in three orthographic views, one along each axis, with the prepass's vertex or
// mesh stages and no attachments, at twice its voxels across, so that each pixel is half a voxel. Each fragment offers its
// surface's albedo, normal and emission to the voxel that holds it, each a single InterlockedMax that keeps the same
// fragment's whatever the order (see voxel_key), and marks which of the voxel's eight half-size cubes it is in. Each
// fragment counts only in the view along its triangle's dominant axis, where the triangle covers the most pixels and
// its depth changes by less than a voxel across a pixel: a conservative rasterizer's fragments past a triangle's edges
// extrapolate its position, which in a view that sees it edge-on lands far from it. The triangle's normal comes from
// the position's derivatives, so no triangle needs a projection of its own.
#ifndef MATERIAL_VOXELIZE_HLSLI
#define MATERIAL_VOXELIZE_HLSLI

#include "material_prepass.hlsli"
#include "gi_voxel.hlsli"

void ps_voxelize(Prepass_Varyings i, bool front : SV_IsFrontFace) {
	if (frame.voxel_draw == 0) {
		return;
	}
	Material_Inputs inputs = material_inputs(i.v, front);
	float3 face = abs(cross(ddx(inputs.position), ddy(inputs.position)));
	uint dominant = face.x >= face.y ? (face.x >= face.z ? 0 : 2) : (face.y >= face.z ? 1 : 2);
	// The view's axis is the one that its projection takes depth along (see voxel_view_projection).
	float3 depth = abs(frame.view_projection[2].xyz);
	uint axis = depth.x > depth.y ? (depth.x > depth.z ? 0 : 2) : (depth.y > depth.z ? 1 : 2);
	if (dominant != axis) {
		return;
	}
	float3 corner = float3(frame.voxel_min_x, frame.voxel_min_y, frame.voxel_min_z);
	float3 local = (inputs.position - corner) / frame.voxel_size;
	if (any(local < 0) || any(local >= float(frame.voxel_res))) {
		return;
	}
	int res = int(frame.voxel_res);
	int3 phase = int3(frame.voxel_phase_x, frame.voxel_phase_y, frame.voxel_phase_z);
	uint3 texel = uint3((int3(local) + phase) % res);
	uint3 half_cube = uint3(frac(local) >= 0.5);
	uint bit = 1u << (half_cube.x | (half_cube.y << 1) | (half_cube.z << 2));
	Surface s = evaluate(inputs);
#if MATERIAL_MASKED
	clip(shade_opacity(s) - MATERIAL_CUTOFF);
#endif
	float3 normal = shading_normal(inputs, s);
	// The diffuse albedo is the shading model's indirect light from a white surrounding, as hit shading takes it.
#if SHADING_NO_LIGHTING
	float3 albedo = 0;
#else
	Shading_Point p;
	p.position = inputs.position;
	p.normal = normal;
	p.view = inputs.view;
	Indirect white;
	white.diffuse = 1;
	white.specular = 0;
	float3 albedo = shade_indirect(s, p, white);
#endif
	float3 emission = shade_emission(s);
	uint key = voxel_key(local);
	InterlockedOr(cn_rw_uint_texture3d(frame.voxel_mask)[texel], bit);
	InterlockedMax(cn_rw_uint_texture3d(frame.voxel_albedo)[texel], voxel_pack_albedo(albedo, key));
	InterlockedMax(cn_rw_uint_texture3d(frame.voxel_normal)[texel], voxel_pack_normal(normal, key));
	if (any(emission > 0)) {
		InterlockedMax(cn_rw_uint_texture3d(frame.voxel_emission)[texel], voxel_pack_emission(emission));
	}
}

#endif
