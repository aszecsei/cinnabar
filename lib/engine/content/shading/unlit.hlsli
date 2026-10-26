// The Unlit shading model (unlit.shading): its color is what reaches the camera. See docs/rendering/materials.md#shading-models.

float3 shade_emission(Surface s) {
	return s.color;
}

float shade_opacity(Surface s) {
	return s.opacity;
}
