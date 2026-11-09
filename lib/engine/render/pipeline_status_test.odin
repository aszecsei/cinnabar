package render

import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"

// The fake backend's pipelines: handle index 1 compiles, 2 is ready and 3 failed.
@(private = "file")
fake_status :: proc(pipeline: gpu.Pipeline) -> gpu.Pipeline_Status {
	switch pipeline.index {
	case 1:
		return .Compiling
	case 2:
		return .Ready
	}
	return .Failed
}

@(private = "file")
COMPILING :: gpu.Pipeline{index = 1, generation = 1}
@(private = "file")
READY :: gpu.Pipeline{index = 2, generation = 1}
@(private = "file")
FAILED :: gpu.Pipeline{index = 3, generation = 1}

@(test)
a_pipeline_that_failed_is_not_one_that_compiles :: proc(t: ^testing.T) {
	platform := core.Platform_API {
		gpu_pipeline_status = fake_status,
	}

	// A shader's pipeline compiles until it is made, unless its shader failed, and then is where its handle is.
	p := Shader_Pipeline{}
	testing.expect_value(t, pipeline_status(&platform, &p), gpu.Pipeline_Status.Compiling)
	p.failed = true
	testing.expect_value(t, pipeline_status(&platform, &p), gpu.Pipeline_Status.Failed)
	testing.expect(t, !pipeline_ready(&platform, &p))
	p = {pipeline = FAILED}
	testing.expect_value(t, pipeline_status(&platform, &p), gpu.Pipeline_Status.Failed)
	p = {pipeline = READY}
	testing.expect(t, pipeline_ready(&platform, &p))
	// A platform that compiles nothing has every pipeline ready.
	none := core.Platform_API{}
	testing.expect(t, pipeline_ready(&none, &p))

	// A material is Failed when any of its pipelines failed, whatever else compiles, then Compiling while any compiles.
	m := Material_Pipeline{}
	testing.expect_value(t, material_status(&platform, &m), gpu.Pipeline_Status.Ready)
	m.pipelines[.Forward] = READY
	m.meshes[.Forward] = COMPILING
	testing.expect_value(t, material_status(&platform, &m), gpu.Pipeline_Status.Compiling)
	testing.expect(t, !material_ready(&platform, &m))
	m.over[0] = FAILED
	testing.expect_value(t, material_status(&platform, &m), gpu.Pipeline_Status.Failed)

	// A reflection probe's capture waits for a material that compiles, not for one that failed, which draws its
	// stand-in until its shader changes.
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.materials.pipeline_count = 1
	f := Frame {
		renderer    = r, state = &r.view,
		scene_frame = &Scene_Frame{items = make([]Cull_Item, 1, context.temp_allocator), bin_pipelines = {0}},
	}
	r.materials.pipelines[0] = {}
	r.materials.pipelines[0].pipelines[.Forward] = COMPILING
	testing.expect(t, !reflection_probe_inputs_complete(&f), "a capture did not wait for a material that compiles")
	r.materials.pipelines[0] = {}
	r.materials.pipelines[0].pipelines[.Forward] = FAILED
	testing.expect(t, reflection_probe_inputs_complete(&f), "a capture waits for a material that failed")
	r.materials.pipelines[0] = {}
	r.materials.pipelines[0].pipelines[.Forward] = READY
	testing.expect(t, reflection_probe_inputs_complete(&f))
}
