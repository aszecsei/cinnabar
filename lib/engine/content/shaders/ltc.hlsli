// The area lights' linearly transformed cosines (see docs/rendering/lighting-and-shadows.md#area-lights). A shading model's shade_area
// integrates a lobe over a light's shape with ltc_integral: the lobe is a clamped cosine transformed by a matrix, so its
// integral over a shape is the cosine's over the shape transformed by the matrix's inverse. ltc_ggx gives the Lit
// specular's inverse from the tables that tools/ltc_fit fits; the identity gives Lambert's diffuse.
//
// Quads and tubes are polygons, clipped to the horizon and integrated edge by edge (Heitz, Dupuy, Hill and Neubelt,
// 2016). A line and a disk are Heitz and Hill's (2017): a line's integral in closed form, and a disk's ellipse as the
// sphere of the same form factor, clipped to the horizon by the second table.
#ifndef LTC_HLSLI
#define LTC_HLSLI

// Matches LTC_SIZE in lib/engine/render/lights.odin.
static const float LTC_SIZE = 64;

// Ltc_Ggx is the Lit specular's lobe at a roughness and a view angle: the inverse of its matrix, in the frame where the
// normal is +z and the view is in the xz plane, and the shares of the light that its magnitude and its Fresnel term
// reflect, so that the specular color is f0 * magnitude + (1 - f0) * fresnel.
struct Ltc_Ggx {
	float3x3 inverse;
	float magnitude;
	float fresnel;
};

// ltc_uv is where the tables keep the value at a point of [0, 1]², whose corners are their corner texels' middles.
float2 ltc_uv(float2 p) {
	return p * ((LTC_SIZE - 1) / LTC_SIZE) + 0.5 / LTC_SIZE;
}

Ltc_Ggx ltc_ggx(float roughness, float nv) {
	float2 uv = ltc_uv(float2(saturate(roughness), sqrt(1 - saturate(nv))));
	SamplerState s = cn_sampler(frame.ltc_sampler);
	float4 m = cn_texture(frame.ltc_matrix).SampleLevel(s, uv, 0);
	float4 a = cn_texture(frame.ltc_amplitude).SampleLevel(s, uv, 0);
	Ltc_Ggx g;
	g.inverse = float3x3(m.x, 0, m.y, 0, 1, 0, m.z, 0, m.w);
	g.magnitude = a.x;
	g.fresnel = a.y;
	return g;
}

// ltc_sphere is the form factor of a sphere whose unclipped form factor is form_factor, with its middle at cos
// elevation z, as the part above the horizon gives it.
float ltc_sphere(float z, float form_factor) {
	float2 uv = ltc_uv(float2(z * 0.5 + 0.5, form_factor));
	return form_factor * cn_texture(frame.ltc_amplitude).SampleLevel(cn_sampler(frame.ltc_sampler), uv, 0).w;
}

// ltc_edge is the z of an edge's vector form factor between two unit directions: cross(a, b) times θ / sin θ / 2π, from
// a rational fit, which acos is not accurate enough for.
float ltc_edge(float3 a, float3 b) {
	float x = dot(a, b);
	float y = abs(x);
	float v = (0.8543985 + (0.4965155 + 0.0145206 * y) * y) / (3.4175940 + (4.1616724 + y) * y);
	float theta_sin_theta = x > 0 ? v : 0.5 * rsqrt(max(1 - x * x, 1e-7)) - v;
	return (a.x * b.y - a.y * b.x) * theta_sin_theta;
}

// Ltc_Polygon sums a polygon's edges as its vertices come, clipped to the horizon, without keeping them.
struct Ltc_Polygon {
	float3 first;
	float3 previous;
	uint count;
	float sum;
};

void ltc_vertex(inout Ltc_Polygon polygon, float3 p) {
	p *= rsqrt(max(dot(p, p), 1e-12));
	if (polygon.count == 0) {
		polygon.first = p;
	} else {
		polygon.sum += ltc_edge(polygon.previous, p);
	}
	polygon.previous = p;
	polygon.count++;
}

// ltc_clip_edge adds the part of an edge from a to b above the horizon: a, if it is above, then where the edge crosses.
void ltc_clip_edge(inout Ltc_Polygon polygon, float3 a, float3 b) {
	if (a.z >= 0) {
		ltc_vertex(polygon, a);
	}
	if ((a.z >= 0) != (b.z >= 0)) {
		ltc_vertex(polygon, a + (b - a) * (a.z / (a.z - b.z)));
	}
}

// ltc_polygon_form_factor closes the polygon. Above the horizon, its winding only signs its form factor.
float ltc_polygon_form_factor(Ltc_Polygon polygon) {
	return polygon.count >= 3 ? abs(polygon.sum + ltc_edge(polygon.previous, polygon.first)) : 0;
}

float ltc_quad(float3x3 m, float3 center, float3 axis_x, float3 axis_y) {
	float3 p0 = mul(m, center - axis_x - axis_y);
	float3 p1 = mul(m, center - axis_x + axis_y);
	float3 p2 = mul(m, center + axis_x + axis_y);
	float3 p3 = mul(m, center + axis_x - axis_y);
	Ltc_Polygon polygon = (Ltc_Polygon)0;
	ltc_clip_edge(polygon, p0, p1);
	ltc_clip_edge(polygon, p1, p2);
	ltc_clip_edge(polygon, p2, p3);
	ltc_clip_edge(polygon, p3, p0);
	return ltc_polygon_form_factor(polygon);
}

// ltc_arc_scale is how far out an arc's three inner vertices go, over its radius, so that its four chords cover the
// arc's sector.
float ltc_arc_scale(float span) {
	return span < 1e-4 ? 1 : (-1 + sqrt(1 + 2 * span / sin(span / 4))) * 0.5;
}

// ltc_tube is a tube's outline from the point: the hull of its ends' spheres, an arc of each joined by the tangents
// between them. The tangents touch the arcs phi from the line toward the far end, where cos phi is the difference of
// the spheres' angular radii over the angle between them; once the near sphere hides the far one, as end on, phi is 0
// and the outline is the near sphere's. A near sphere's outline is wider than its radius.
float ltc_tube(float3x3 m, float3 center, float3 axis, float radius) {
	float3 a = center + axis;
	float3 b = center - axis;
	float distance_a = length(a);
	float distance_b = length(b);
	bool a_near = distance_a <= distance_b;
	float3 ends[2] = {a_near ? b : a, a_near ? a : b};
	float distances[2] = {a_near ? distance_b : distance_a, a_near ? distance_a : distance_b};
	float far_radius = asin(min(radius / distances[0], 1));
	float near_radius = asin(min(radius / distances[1], 1));
	float separation = acos(clamp(dot(ends[0], ends[1]) / (distances[0] * distances[1]), -1, 1));
	float phi = acos(clamp((near_radius - far_radius) / max(separation, 1e-6), -1, 1));
	float3 side = cross(center, axis);
	if (dot(side, side) < 1e-12 * dot(axis, axis) * dot(center, center)) {
		side = cross(center, abs(center.x) < 0.9 * length(center) ? float3(1, 0, 0) : float3(0, 1, 0));
	}
	side = normalize(side);
	float3 toward_far = ends[0] - ends[1];
	// The far arc from -phi to phi, then the near arc from phi around to -phi.
	float starts[2] = {-phi, phi};
	float spans[2] = {2 * phi, 2 * PI - 2 * phi};
	Ltc_Polygon polygon = (Ltc_Polygon)0;
	float3 first = 0;
	float3 previous = 0;
	[unroll] for (uint k = 0; k < 2; k++) {
		float3 u = normalize(cross(side, ends[k]));
		u = dot(u, toward_far) < 0 ? -u : u;
		float outline = radius * rsqrt(max(1 - radius * radius / (distances[k] * distances[k]), 1e-4));
		float inner = ltc_arc_scale(spans[k]);
		[unroll] for (uint i = 0; i < 5; i++) {
			float angle = starts[k] + spans[k] * i / 4;
			float3 v = mul(m, ends[k] + outline * (i == 0 || i == 4 ? 1 : inner) * (cos(angle) * u + sin(angle) * side));
			if (k == 0 && i == 0) {
				first = v;
			} else {
				ltc_clip_edge(polygon, previous, v);
			}
			previous = v;
		}
	}
	ltc_clip_edge(polygon, previous, first);
	return ltc_polygon_form_factor(polygon);
}

float ltc_line_po(float d, float l) {
	return l / (d * (d * d + l * l)) + atan(l / d) / (d * d);
}

float ltc_line_wt(float d, float l) {
	return l * l / (d * (d * d + l * l));
}

// ltc_line is a line's form factor per meter of its width: the cosine's integral along the transformed line, which is
// a thin cylinder's, clipped to the horizon, times how much the transform widens it.
float ltc_line(float3x3 m, float3 p1, float3 p2) {
	float3 q1 = mul(m, p1);
	float3 q2 = mul(m, p2);
	if (q1.z <= 0 && q2.z <= 0) {
		return 0;
	}
	float3 tangent = normalize(q2 - q1);
	if (q1.z < 0) {
		q1 = (q1 * q2.z - q2 * q1.z) / (q2.z - q1.z);
	}
	if (q2.z < 0) {
		q2 = (-q1 * q2.z + q2 * q1.z) / (-q2.z + q1.z);
	}
	float l1 = dot(q1, tangent);
	float l2 = dot(q2, tangent);
	float3 closest = q1 - l1 * tangent;
	float d = max(length(closest), 1e-6);
	float integral = ((ltc_line_po(d, l2) - ltc_line_po(d, l1)) * closest.z + (ltc_line_wt(d, l2) - ltc_line_wt(d, l1)) * tangent.z) / PI;
	// The width scales by det(m) / |cofactor(m) * ortho|, where ortho is across the line, the way normals transform.
	float3x3 columns = transpose(m);
	float3 ortho = normalize(cross(p1, p2));
	float3 cofactor = ortho.x * cross(columns[1], columns[2]) + ortho.y * cross(columns[2], columns[0]) + ortho.z * cross(columns[0], columns[1]);
	float width = abs(dot(columns[0], cross(columns[1], columns[2]))) / max(length(cofactor), 1e-12);
	return 0.5 * width * integral;
}

// ltc_cubic_roots are the roots of c.x + c.y t + c.z t² + c.w t³, which has three real ones, the middle one second, by
// Blinn's method.
float3 ltc_cubic_roots(float4 c) {
	c.xyz /= c.w;
	c.yz /= 3;
	float a = c.w;
	float b = c.z;
	float cc = c.y;
	float d = c.x;
	float3 delta = float3(-c.z * c.z + c.y, -c.y * c.z + c.x, dot(float2(c.z, -c.y), c.xy));
	float discriminant = dot(float2(4 * delta.x, -delta.y), delta.zy);
	float2 large;
	{
		float c_a = delta.x;
		float d_a = -2 * b * delta.x + delta.y;
		float theta = atan2(sqrt(discriminant), -d_a) / 3;
		float x1 = 2 * sqrt(-c_a) * cos(theta);
		float x3 = 2 * sqrt(-c_a) * cos(theta + (2.0 / 3.0) * PI);
		large = float2((x1 + x3 > 2 * b ? x1 : x3) - b, a);
	}
	float2 small;
	{
		float c_d = delta.z;
		float d_d = -d * delta.y + 2 * cc * delta.z;
		float theta = atan2(d * sqrt(discriminant), -d_d) / 3;
		float x1 = 2 * sqrt(-c_d) * cos(theta);
		float x3 = 2 * sqrt(-c_d) * cos(theta + (2.0 / 3.0) * PI);
		small = float2(-d, (x1 + x3 < 2 * cc ? x1 : x3) + cc);
	}
	float e = large.y * small.y;
	float f = -large.x * small.y - large.y * small.x;
	float g = large.x * small.x;
	float2 middle = float2(cc * f - b * g, -b * f + cc * e);
	float3 roots = float3(small.x / small.y, middle.x / middle.y, large.x / large.y);
	if (roots.x < roots.y && roots.x < roots.z) {
		roots = roots.yxz;
	} else if (roots.z < roots.x && roots.z < roots.y) {
		roots = roots.xzy;
	}
	return roots;
}

// ltc_disk is an ellipse's form factor: the transformed ellipse's principal axes, the cone it subtends, and the sphere
// with that cone's form factor, in the cone's average direction.
float ltc_disk(float3x3 m, float3 center, float3 axis_x, float3 axis_y) {
	float3 c = mul(m, center);
	float3 v1 = mul(m, axis_x);
	float3 v2 = mul(m, axis_y);
	float d11 = dot(v1, v1);
	float d22 = dot(v2, v2);
	float d12 = dot(v1, v2);
	float a;
	float b;
	if (abs(d12) / sqrt(d11 * d22) > 1e-4) {
		float trace = d11 + d22;
		float determinant = sqrt(max(d11 * d22 - d12 * d12, 0));
		float u = 0.5 * sqrt(max(trace - 2 * determinant, 0));
		float v = 0.5 * sqrt(trace + 2 * determinant);
		float e_max = (u + v) * (u + v);
		float e_min = max((u - v) * (u - v), 1e-12);
		float3 major = d11 > d22 ? d12 * v1 + (e_max - d11) * v2 : d12 * v2 + (e_max - d22) * v1;
		float3 minor = d11 > d22 ? d12 * v1 + (e_min - d11) * v2 : d12 * v2 + (e_min - d22) * v1;
		a = 1 / e_max;
		b = 1 / e_min;
		v1 = normalize(major);
		v2 = normalize(minor);
	} else {
		a = 1 / d11;
		b = 1 / d22;
		v1 *= sqrt(a);
		v2 *= sqrt(b);
	}
	float3 v3 = cross(v1, v2);
	v3 = dot(c, v3) < 0 ? -v3 : v3;
	float l = dot(v3, c);
	float x0 = dot(v1, c) / l;
	float y0 = dot(v2, c) / l;
	a *= l * l;
	b *= l * l;
	float c0 = a * b;
	float c1 = a * b * (1 + x0 * x0 + y0 * y0) - a - b;
	float c2 = 1 - a * (1 + x0 * x0) - b * (1 + y0 * y0);
	float3 roots = ltc_cubic_roots(float4(c0, c1, c2, 1));
	float3 direction = float3(a * x0 / (a - roots.y), b * y0 / (b - roots.y), 1);
	direction = normalize(direction.x * v1 + direction.y * v2 + direction.z * v3);
	float l1 = sqrt(-roots.y / roots.z);
	float l2 = sqrt(-roots.y / roots.x);
	float form_factor = l1 * l2 * rsqrt((1 + l1 * l1) * (1 + l2 * l2));
	return ltc_sphere(direction.z, form_factor);
}

// ltc_integral is the integral over an area light's shape of the lobe whose inverse matrix is given, in the frame of
// the normal n and the view v: its form factor, or a line's per meter of its width. A light that shines from one face
// gives nothing behind it.
float ltc_integral(Area_Light light, float3 n, float3 v, float3x3 inverse) {
	if (light.shape != LIGHT_LINE && !light.two_sided && dot(light.normal, light.center) >= 0) {
		return 0;
	}
	float3 t1 = v - n * dot(v, n);
	t1 = dot(t1, t1) > 1e-8 ? normalize(t1) : normalize(cross(n, abs(n.x) < 0.9 ? float3(1, 0, 0) : float3(0, 1, 0)));
	float3 t2 = cross(n, t1);
	float3x3 m = mul(inverse, float3x3(t1, t2, n));
	switch (light.shape) {
	case LIGHT_QUAD:
		return ltc_quad(m, light.center, light.axis_x, light.axis_y);
	case LIGHT_DISK:
		return ltc_disk(m, light.center, light.axis_x, light.axis_y);
	default:
		return light.radius > 0 ? ltc_tube(m, light.center, light.axis_x, light.radius) : ltc_line(m, light.center - light.axis_x, light.center + light.axis_x);
	}
}

#endif
