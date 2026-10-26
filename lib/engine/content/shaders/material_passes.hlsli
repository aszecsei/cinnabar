// Every pass of a material, which the cooker compiles from one generated source by their entry points: vs_forward and
// ps_forward, vs_prepass and ps_prepass, and vs_depth, with ps_depth for a masked material. On the mesh shader path,
// as_cluster with ms_forward, ms_prepass and ms_depth take the vertex shaders' places. A transparent or additive
// material has ps_transparent and ps_transparent_ids instead, and a transparent one ps_moments, all with vs_forward.
#include "material_forward.hlsli"
#include "material_prepass.hlsli"
#include "material_depth.hlsli"
#if MATERIAL_TRANSPARENT
#include "material_transparent.hlsli"
#endif
