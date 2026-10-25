// Every pass of a material, which the cooker compiles from one generated source by their entry points: vs_forward and
// ps_forward, vs_prepass and ps_prepass, and vs_depth, with ps_depth for a masked material.
#include "material_forward.hlsli"
#include "material_prepass.hlsli"
#include "material_depth.hlsli"
