package render

// Reflections: their quality's techniques and levels (see docs/rendering/quality.md#quality). A technique runs after
// the prepass, as the ambient occlusion and the global illumination do, and reads its roughness (Frame.roughness).
// Off is the only technique, so a frame has no reflections.

// Reflection_Params are a technique's parameters at a level. Each technique adds the fields that it reads.
Reflection_Params :: struct {}

@(rodata)
REFLECTION_PARAMS := [Reflection_Technique][Quality_Level]Reflection_Params {
	.Off = {},
}

// Reflection_Settings are a frame's reflections, in Frame_Settings. No volume sets them yet: apply_quality gives them
// the quality's technique and level, and turns them off for Off.
Reflection_Settings :: struct {
	off:       bool,
	// The technique, and its REFLECTION_PARAMS.
	technique: Reflection_Technique,
	level:     Quality_Level,
}
