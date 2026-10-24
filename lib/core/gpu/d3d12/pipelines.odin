package gpu_d3d12

import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

// The fixed root signature (see docs/gpu.md#binding-model). Shaders declare these with the macros in
// lib/core/gpu/shaders/cinnabar.hlsli.
ROOT_PUSH_CONSTANTS :: 0
ROOT_PASS_CONSTANTS :: 1

// pso is nil until the pipeline's first compile job finishes. An update replaces it when the new version is
// ready. Read and write it atomically.
@(private)
Pipeline_Entry :: struct {
	info:     gpu.Pipeline_Info,
	pso:      ^d3d.IPipelineState,
	topology: d3d.PRIMITIVE_TOPOLOGY,
	scope:    gpu.Scope,
	// The latest compile. A compile job publishes its result only if no later update started.
	serial:   u32,
}

@(private)
Pipelines :: struct {
	root_signature:   ^d3d.IRootSignature,
	pipeline_pool:    gpu.Pool(gpu.Pipeline, Pipeline_Entry),
	// Orders a compile job's result against the pipeline's destruction.
	pipeline_mutex:   sync.Mutex,
	// The compile jobs that may still write each slot. A slot is not reused until its count is zero.
	compiling:        []int,
	compile_counter:  jobs.Counter,
}

@(private)
init_pipelines :: proc() -> bool {
	gpu.pool_init(&dev.pipeline_pool, gpu.MAX_PIPELINES, dev.allocator)
	dev.compiling = make([]int, gpu.MAX_PIPELINES, dev.allocator)

	params: [2]d3d.ROOT_PARAMETER1
	params[ROOT_PUSH_CONSTANTS].ParameterType = ._32BIT_CONSTANTS
	params[ROOT_PUSH_CONSTANTS].Constants = {
		ShaderRegister = 0,
		Num32BitValues = gpu.MAX_PUSH_CONSTANTS_SIZE / 4,
	}
	params[ROOT_PASS_CONSTANTS].ParameterType = .CBV
	params[ROOT_PASS_CONSTANTS].Descriptor = {
		ShaderRegister = 1,
		Flags          = {.DATA_STATIC_WHILE_SET_AT_EXECUTE},
	}
	desc := d3d.VERSIONED_ROOT_SIGNATURE_DESC {
		Version = ._1_1,
	}
	desc.Desc_1_1 = {
		NumParameters = len(params),
		pParameters   = &params[0],
		Flags         = {.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED},
	}
	blob, error_blob: ^d3d.IBlob
	if !check(d3d.SerializeVersionedRootSignature(&desc, &blob, &error_blob), "SerializeVersionedRootSignature") {
		if error_blob != nil {
			log.errorf("d3d12: %s", cstring(error_blob->GetBufferPointer()))
			error_blob->Release()
		}
		return false
	}
	defer blob->Release()
	check(
		dev.device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), d3d.IRootSignature_UUID, (^rawptr)(&dev.root_signature)),
		"CreateRootSignature",
	) or_return
	return true
}

// wait_compiles waits for the compile jobs. Call it before the GPU device shuts down.
@(private)
wait_compiles :: proc() {
	jobs.wait(&dev.compile_counter)
}

@(private)
shutdown_pipelines :: proc() {
	gpu.pool_each(&dev.pipeline_pool, proc(entry: ^Pipeline_Entry) {release(&entry.pso)})
	gpu.pool_destroy(&dev.pipeline_pool)
	delete(dev.compiling, dev.allocator)
	release(&dev.root_signature)
}

// bind_root_signature binds the descriptor heaps and the root signature at the start of a command list.
@(private)
bind_root_signature :: proc(list: ^d3d.IGraphicsCommandList7) {
	// The heaps must be bound before a root signature that indexes them directly.
	heaps := [?]^d3d.IDescriptorHeap{dev.resource_heap, dev.sampler_heap}
	list->SetDescriptorHeaps(len(heaps), &heaps[0])
	list->SetGraphicsRootSignature(dev.root_signature)
	list->SetComputeRootSignature(dev.root_signature)
}

// A pipeline compiles on a background job. Its handle is valid at once, and draws and dispatches with it are
// skipped until it is ready. See docs/gpu.md#pipelines.
create_graphics_pipeline :: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline {
	task, entry, ok := graphics_task(desc)
	return ok ? start_compile(task, entry) : {}
}

create_compute_pipeline :: proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline {
	task, entry, ok := compute_task(desc)
	return ok ? start_compile(task, entry) : {}
}

// update_graphics_pipeline compiles a new version of a pipeline on a background job. The current version stays in
// use until the new one is ready, and stays if the new one fails to compile. The attachment formats and the topology
// must not change, and the scope stays. It returns false, and changes nothing, if the description is invalid or
// changes the formats or the topology. Create a new pipeline for those.
update_graphics_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) -> bool {
	task, entry := graphics_task(desc) or_return
	return start_update(pipeline, task, entry)
}

update_compute_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) -> bool {
	task, entry := compute_task(desc) or_return
	return start_update(pipeline, task, entry)
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	sync.guard(&dev.pipeline_mutex)
	if entry, ok := gpu.pool_remove(&dev.pipeline_pool, pipeline); ok {
		defer_release(sync.atomic_load(&entry.pso), .Pipeline, pipeline.index)
	}
}

// graphics_task builds the compile task and the pool entry for a description.
@(private = "file")
graphics_task :: proc(desc: gpu.Graphics_Pipeline_Desc) -> (task: ^Compile_Task, entry: Pipeline_Entry, ok: bool) {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return
	}

	// The job outlives the call, and the blobs may be in the game DLL's image, so they are copied.
	task = new_task(desc.label, desc.vertex, desc.pixel)
	task.graphics = {
		pRootSignature = dev.root_signature,
		VS = bytecode(task.blobs[0]),
		PS = bytecode(task.blobs[1]),
		SampleMask = max(u32),
		RasterizerState = {
			FillMode = .SOLID,
			CullMode = CULL[desc.cull],
			DepthClipEnable = true,
		},
		DepthStencilState = {
			DepthEnable = d3d.BOOL(desc.depth_format != .Unknown && (desc.depth_compare != .Always || desc.depth_write)),
			DepthWriteMask = desc.depth_write ? .ALL : .ZERO,
			DepthFunc = COMPARE[desc.depth_compare],
		},
		PrimitiveTopologyType = TOPOLOGY_TYPE[desc.topology],
		NumRenderTargets = u32(len(desc.colors)),
		DSVFormat = view_format(desc.depth_format),
		SampleDesc = {Count = 1},
	}
	task.graphics.BlendState.IndependentBlendEnable = true
	for color, i in desc.colors {
		task.graphics.RTVFormats[i] = view_format(color.format)
		task.graphics.BlendState.RenderTarget[i] = BLEND[color.blend]
	}
	return task, {info = gpu.pipeline_info(desc), topology = TOPOLOGY[desc.topology], scope = desc.scope}, true
}

@(private = "file")
compute_task :: proc(desc: gpu.Compute_Pipeline_Desc) -> (task: ^Compile_Task, entry: Pipeline_Entry, ok: bool) {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return
	}
	task = new_task(desc.label, desc.compute)
	task.is_compute = true
	task.compute = {
		pRootSignature = dev.root_signature,
		CS             = bytecode(task.blobs[0]),
	}
	return task, {info = {kind = .Compute}, scope = desc.scope}, true
}

// pipeline_compiling reports whether a compile job may still write a pipeline slot.
@(private)
pipeline_compiling :: proc(index: u32) -> bool {
	return sync.atomic_load(&dev.compiling[index]) > 0
}

// Compile_Task owns copies of everything the compile job reads.
@(private = "file")
Compile_Task :: struct {
	pipeline:   gpu.Pipeline,
	serial:     u32,
	label:      string,
	blobs:      [][]byte,
	is_compute: bool,
	graphics:   d3d.GRAPHICS_PIPELINE_STATE_DESC,
	compute:    d3d.COMPUTE_PIPELINE_STATE_DESC,
}

@(private = "file")
new_task :: proc(label: string, blobs: ..[]byte) -> ^Compile_Task {
	task := new(Compile_Task, dev.allocator)
	task.label = strings.clone(label, dev.allocator)
	task.blobs = make([][]byte, len(blobs), dev.allocator)
	for blob, i in blobs {
		task.blobs[i] = slice.clone(blob, dev.allocator)
	}
	return task
}

@(private = "file")
free_task :: proc(task: ^Compile_Task) {
	for blob in task.blobs {
		delete(blob, dev.allocator)
	}
	delete(task.blobs, dev.allocator)
	delete(task.label, dev.allocator)
	free(task, dev.allocator)
}

@(private = "file")
start_compile :: proc(task: ^Compile_Task, entry: Pipeline_Entry) -> gpu.Pipeline {
	pipeline := gpu.pool_add(&dev.pipeline_pool, entry)
	if pipeline == {} {
		log.errorf("gpu: pipeline %q: more than %d pipelines", task.label, gpu.MAX_PIPELINES)
		free_task(task)
		return {}
	}
	task.pipeline = pipeline
	sync.atomic_add(&dev.compiling[pipeline.index], 1)
	jobs.run_background({{compile_job, task}}, &dev.compile_counter)
	return pipeline
}

@(private = "file")
start_update :: proc(pipeline: gpu.Pipeline, task: ^Compile_Task, entry: Pipeline_Entry) -> bool {
	sync.guard(&dev.pipeline_mutex)
	current := gpu.pool_get(&dev.pipeline_pool, pipeline)
	if current == nil {
		log.errorf("gpu: pipeline %q: update of an invalid handle", task.label)
		free_task(task)
		return false
	}
	if current.info != entry.info || current.topology != entry.topology {
		log.errorf("gpu: pipeline %q: an update must keep the attachment formats and the topology. Create a new pipeline instead.", task.label)
		free_task(task)
		return false
	}
	current.serial += 1
	task.pipeline, task.serial = pipeline, current.serial
	sync.atomic_add(&dev.compiling[pipeline.index], 1)
	jobs.run_background({{compile_job, task}}, &dev.compile_counter)
	return true
}

// compile_job runs only backend code on copied data, so it may continue across frames and reloads.
@(private = "file")
compile_job :: proc(data: rawptr) {
	task := (^Compile_Task)(data)
	defer free_task(task)
	pso: ^d3d.IPipelineState
	hr: d3d.HRESULT
	if task.is_compute {
		hr = dev.device->CreateComputePipelineState(&task.compute, d3d.IPipelineState_UUID, (^rawptr)(&pso))
	} else {
		hr = dev.device->CreateGraphicsPipelineState(&task.graphics, d3d.IPipelineState_UUID, (^rawptr)(&pso))
	}
	if !check(hr, "CreatePipelineState") {
		pso = nil
		if task.serial == 0 {
			log.errorf("gpu: pipeline %q was not created. Draws with it are skipped.", task.label)
		} else {
			log.errorf("gpu: pipeline %q was not updated. The previous version stays in use.", task.label)
		}
	} else {
		set_name(pso, task.label)
	}

	sync.guard(&dev.pipeline_mutex)
	defer sync.atomic_sub(&dev.compiling[task.pipeline.index], 1)
	entry := gpu.pool_get(&dev.pipeline_pool, task.pipeline)
	if entry == nil || entry.serial != task.serial {
		// The pipeline was destroyed, or a later update replaced this compile.
		if pso != nil {
			pso->Release()
		}
		return
	}
	if pso == nil {
		return
	}
	// Command lists of the frames in flight may still use the previous version.
	if previous := sync.atomic_exchange(&entry.pso, pso); previous != nil {
		defer_release(previous, .None, 0)
	}
}

@(private = "file")
bytecode :: proc(blob: []byte) -> d3d.SHADER_BYTECODE {
	return {pShaderBytecode = raw_data(blob), BytecodeLength = uint(len(blob))}
}

@(private = "file")
CULL := [gpu.Cull_Mode]d3d.CULL_MODE {
	.None  = .NONE,
	.Back  = .BACK,
	.Front = .FRONT,
}

@(private = "file")
COMPARE := [gpu.Compare_Op]d3d.COMPARISON_FUNC {
	.Always        = .ALWAYS,
	.Never         = .NEVER,
	.Less          = .LESS,
	.Less_Equal    = .LESS_EQUAL,
	.Equal         = .EQUAL,
	.Greater       = .GREATER,
	.Greater_Equal = .GREATER_EQUAL,
	.Not_Equal     = .NOT_EQUAL,
}

@(private = "file")
TOPOLOGY_TYPE := [gpu.Topology]d3d.PRIMITIVE_TOPOLOGY_TYPE {
	.Triangle_List  = .TRIANGLE,
	.Triangle_Strip = .TRIANGLE,
	.Line_List      = .LINE,
	.Point_List     = .POINT,
}

@(private = "file")
TOPOLOGY := [gpu.Topology]d3d.PRIMITIVE_TOPOLOGY {
	.Triangle_List  = .TRIANGLELIST,
	.Triangle_Strip = .TRIANGLESTRIP,
	.Line_List      = .LINELIST,
	.Point_List     = .POINTLIST,
}

@(private = "file")
WRITE_ALL :: 0xf

@(private = "file")
BLEND := [gpu.Blend]d3d.RENDER_TARGET_BLEND_DESC {
	.Opaque = {SrcBlend = .ONE, DestBlend = .ZERO, BlendOp = .ADD, SrcBlendAlpha = .ONE, DestBlendAlpha = .ZERO, BlendOpAlpha = .ADD, RenderTargetWriteMask = WRITE_ALL},
	.Alpha = {
		BlendEnable = true,
		SrcBlend = .SRC_ALPHA,
		DestBlend = .INV_SRC_ALPHA,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .INV_SRC_ALPHA,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = WRITE_ALL,
	},
	.Premultiplied = {
		BlendEnable = true,
		SrcBlend = .ONE,
		DestBlend = .INV_SRC_ALPHA,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .INV_SRC_ALPHA,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = WRITE_ALL,
	},
	.Additive = {
		BlendEnable = true,
		SrcBlend = .ONE,
		DestBlend = .ONE,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .ONE,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = WRITE_ALL,
	},
}
