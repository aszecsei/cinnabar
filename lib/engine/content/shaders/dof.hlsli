#ifndef CN_DOF_HLSLI
#define CN_DOF_HLSLI

// The depth of field's circle of confusion (see docs/rendering/post-processing.md#depth-of-field), which the depth of
// field and its debug view share. dof_lens in lib/engine/render/depth_of_field.odin gives the scale and the focus from
// the view's lens.

// coc is the signed circle of confusion in pixels at a view-space z: negative in front of the focus, positive behind
// it, and 0 on the focus plane. Matches circle_of_confusion in lib/engine/render/depth_of_field.odin.
float coc(float scale, float focus, float z) {
	return scale * (1 - focus / max(z, 1e-4));
}

#endif
