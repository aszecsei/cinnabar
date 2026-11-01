// How a mesh's vertex attributes are folded into words (see docs/content/kinds/meshes.md): a normal or a tangent as a
// point of the octahedron's square, in two 16-bit halves. The material passes read them, and skin_meshes.hlsl writes
// them again once a skin has moved them.
#ifndef MESH_ENCODING_HLSLI
#define MESH_ENCODING_HLSLI

// octahedral unfolds a unit vector from the square [-1, 1]², as the cooker folded it.
float3 octahedral(float2 p) {
	float3 n = float3(p, 1 - abs(p.x) - abs(p.y));
	if (n.z < 0) {
		float2 sign_xy = float2(n.x >= 0 ? 1 : -1, n.y >= 0 ? 1 : -1);
		n.xy = (1 - abs(n.yx)) * sign_xy;
	}
	return normalize(n);
}

// octahedral_encode folds a unit vector into the square [-1, 1]², as octahedral unfolds it.
float2 octahedral_encode(float3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	float2 p = n.xy;
	if (n.z < 0) {
		float2 sign_xy = float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
		p = (1 - abs(p.yx)) * sign_xy;
	}
	return p;
}

float2 snorm16(uint word) {
	int2 v = int2(int(word << 16) >> 16, int(word) >> 16);
	return max(float2(v) / 32767.0, -1.0);
}

float2 unorm16(uint word) {
	return float2(word & 0xffff, word >> 16) / 65535.0;
}

#endif
