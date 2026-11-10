#ifndef CN_VIEW_PROJECTION_HLSLI
#define CN_VIEW_PROJECTION_HLSLI

// A view's projection, as View_Projection in lib/engine/render/view.odin gives it in a float4: the scales of a
// view-space x and y, the near plane and the far plane. A far plane of 0 is a perspective projection, whose depth is
// near / z and whose scales are over the view-space z. An orthographic projection's depth is (far - z) / (far - near)
// (see docs/rendering/frame.md#orthographic-views).

// is_orthographic is whether a projection is orthographic.
bool is_orthographic(float4 projection) {
	return projection.w != 0;
}

// view_z is the view-space z of a depth.
float view_z(float4 projection, float depth) {
	return is_orthographic(projection) ? projection.w - depth * (projection.w - projection.z) : projection.z / max(depth, 1e-7);
}

// clip_view_z is the view-space z of a clip-space position that the projection gave.
float clip_view_z(float4 projection, float4 clip) {
	return is_orthographic(projection) ? projection.w - clip.z * (projection.w - projection.z) : clip.w;
}

// view_position is the view-space position at a normalized device x and y and a view-space z.
float3 view_position(float4 projection, float2 ndc, float z) {
	return float3(ndc / projection.xy * (is_orthographic(projection) ? 1 : z), z);
}

// view_ndc is the normalized device x and y of a view-space position.
float2 view_ndc(float4 projection, float3 v) {
	return v.xy * projection.xy / (is_orthographic(projection) ? 1 : v.z);
}

// view_pixel_meters is the height of a pixel at a view-space z, for a view of a height in pixels.
float view_pixel_meters(float4 projection, float z, float height) {
	return 2 * (is_orthographic(projection) ? 1 : z) / (projection.y * height);
}

// view_to_camera is the view-space direction from a view-space position to where the view looks from.
float3 view_to_camera(float4 projection, float3 v) {
	return is_orthographic(projection) ? float3(0, 0, -1) : normalize(-v);
}

// slice_of is the depth slice of a view-space z: the light clusters' slices and the fog's are exponential from the
// near plane in perspective, and even between the near and the far plane in orthographic (see slice_constants in
// lib/engine/render/lights.odin).
float slice_of(float4 projection, float z, float scale, float bias) {
	return (is_orthographic(projection) ? z : log2(z)) * scale + bias;
}

// slice_z is the view-space z at which a depth slice starts.
float slice_z(float4 projection, float slice, float scale, float bias) {
	float t = (slice - bias) / scale;
	return is_orthographic(projection) ? t : exp2(t);
}

#endif
