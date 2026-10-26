// Moment-based order-independent transparency with four power moments (Muenstermann, Krumpen, Klein and Peters,
// "Moment-Based Order-Independent Transparency", 2018; see docs/rendering.md#transparency). The moments pass adds up,
// at each pixel, the optical depth of every transparent surface, b0 = sum of -ln(1 - alpha), and the moments of their
// depths weighted by it, b0 * (z, z^2, z^3, z^4). The transparent pass then reconstructs, from those, how much light
// gets through the surfaces in front of each one.
#ifndef MOMENTS_HLSLI
#define MOMENTS_HLSLI

// The depths on a log scale span the near plane to this, in meters: the clusters' far end. Surfaces beyond it share
// its depth.
static const float MOMENTS_FAR = 500;
// How far the moments are pulled toward those of an even spread of depths, so that the reconstruction stays stable in
// 32-bit floats: the paper's bias for four power moments in single precision, with its vector.
static const float MOMENT_BIAS = 5e-7;
static const float4 MOMENT_BIAS_VECTOR = float4(0, 0.375, 0, 0.375);
// The share of a surface's own optical depth that dims it: between 0, for none, and 1, for all of it. The paper's 0.25
// keeps a surface from darkening itself while it still sorts against those very near it.
static const float MOMENT_OVERESTIMATION = 0.25;
// The optical depth of an opacity of 0.001, below which a pixel has no transparent surfaces.
static const float MOMENT_MIN_DEPTH = 0.00100050033;
// The opacity is at most this, so its optical depth is finite.
static const float MOMENT_MAX_ALPHA = 0.9999;

// warp_depth maps a view depth to [-1, 1], on a log scale from the near plane to MOMENTS_FAR, so the moments spend
// their precision evenly near and far.
float warp_depth(float view_depth, float near) {
	float t = log(max(view_depth, near) / near) / log(MOMENTS_FAR / near);
	return saturate(t) * 2 - 1;
}

// optical_depth is a surface's share of b0.
float optical_depth(float alpha) {
	return -log(1 - min(alpha, MOMENT_MAX_ALPHA));
}

// depth_moments are a surface's moments at its warped depth z, weighted by its optical depth.
float4 depth_moments(float z, float depth) {
	float z2 = z * z;
	return float4(z, z2, z2 * z, z2 * z2) * depth;
}

// transmittance_at is the share of light that gets through the surfaces in front of warped depth z, from the
// moments: the Hamburger moment problem's bound for four power moments, with a share of the surface's own optical
// depth (the paper's computeTransmittanceAtDepthFrom4PowerMoments).
float transmittance_at(float b0, float4 moments, float z) {
	if (b0 < MOMENT_MIN_DEPTH) {
		return 1;
	}
	float4 b = lerp(moments / b0, MOMENT_BIAS_VECTOR, MOMENT_BIAS);
	// A Cholesky factorization of the Hankel matrix of (1, b1, b2), with only its nontrivial entries.
	float l21_d11 = mad(-b.x, b.y, b.z);
	float d11 = mad(-b.x, b.x, b.y);
	float inverse_d11 = 1 / d11;
	float l21 = l21_d11 * inverse_d11;
	float squared_variance = mad(-b.y, b.y, b.w);
	float d22 = mad(-l21_d11, l21, squared_variance);
	// Solve B c = (1, z, z^2) by substitution, for the polynomial whose other two roots are where the bound's weight
	// sits.
	float3 c = float3(1, z, z * z);
	c.y -= b.x;
	c.z -= b.y + l21 * c.y;
	c.y *= inverse_d11;
	c.z /= d22;
	c.y -= l21 * c.z;
	c.x -= dot(c.yz, b.xy);
	float p = c.y / c.z;
	float q = c.x / c.z;
	float r = sqrt(max(p * p * 0.25 - q, 0));
	float3 roots = float3(z, -p * 0.5 - r, -p * 0.5 + r);
	// The weights of the roots in front of z sum to the absorbance there, by divided differences.
	float3 weight = float3(MOMENT_OVERESTIMATION, roots.y < z ? 1 : 0, roots.z < z ? 1 : 0);
	float f01 = (weight.y - weight.x) / (roots.y - roots.x);
	float f12 = (weight.z - weight.y) / (roots.z - roots.y);
	float f012 = (f12 - f01) / (roots.z - roots.x);
	// Newton's form, expanded into the coefficients of 1, z and z^2.
	float newton = f01 - f012 * roots.y;
	float3 polynomial = float3(weight.x - newton * roots.x, newton - f012 * roots.x, f012);
	float absorbance = polynomial.x + dot(b.xy, polynomial.yz);
	return saturate(exp(-b0 * absorbance));
}

#endif
