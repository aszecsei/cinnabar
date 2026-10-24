// Object placement, shared by cull.hlsl and objects.hlsl so that culling tests the positions that drawing uses.
#ifndef OBJECTS_HLSLI
#define OBJECTS_HLSLI

// The object size, in the units of object_center.
static const float OBJECT_RADIUS = 0.03;
// The objects' depth, just short of infinity, so the scene is always in front of them. Depth is reversed, so this is
// the depth of a point 5 km ahead of the camera.
static const float OBJECT_DEPTH = 0.00001;

// object_center is in units where the screen spans -aspect to aspect horizontally and -1 to 1 vertically.
// Objects sit in a grid that covers the screen and sway a little.
float2 object_center(uint object, uint2 grid, float time, float aspect) {
	float2 cell = float2(object % grid.x, object / grid.x);
	float2 center = ((cell + 0.5) / float2(grid) * 2 - 1) * float2(aspect, 1);
	float phase = 0.37 * object;
	return center + 0.02 * float2(sin(time + phase), cos(1.3 * time + phase));
}

// Objects outside a circle around the screen center are culled. The circle pulses so culling is visible: at its
// smallest, the large triangles in front hide the objects that are left.
float cull_radius(float time) {
	return 0.8 + 0.25 * sin(0.6 * time);
}

#endif
