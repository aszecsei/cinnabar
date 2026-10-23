package gpu_d3d12

import "core:log"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// The fixed root signature (see docs/gpu.md#binding-model). Shaders declare these with the macros in
// lib/core/gpu/shaders/cinnabar.hlsli.
ROOT_PUSH_CONSTANTS :: 0
ROOT_PASS_CONSTANTS :: 1

@(private)
Pipeline_Entry :: struct {
	info:     gpu.Pipeline_Info,
	pso:      ^d3d.IPipelineState,
	topology: d3d.PRIMITIVE_TOPOLOGY,
}

@(private)
Pipelines :: struct {
	root_signature: ^d3d.IRootSignature,
	pipeline_pool:  gpu.Pool(gpu.Pipeline, Pipeline_Entry),
}

@(private)
init_pipelines :: proc() -> bool {
	gpu.pool_init(&dev.pipeline_pool, gpu.MAX_PIPELINES, dev.allocator)

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

@(private)
shutdown_pipelines :: proc() {
	gpu.pool_each(&dev.pipeline_pool, proc(entry: ^Pipeline_Entry) {release(&entry.pso)})
	gpu.pool_destroy(&dev.pipeline_pool)
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

// Pipelines are compiled on the calling thread. See docs/gpu.md#pipelines.
create_graphics_pipeline :: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}

	pso_desc := d3d.GRAPHICS_PIPELINE_STATE_DESC {
		pRootSignature = dev.root_signature,
		VS = bytecode(desc.vertex),
		PS = bytecode(desc.pixel),
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
	pso_desc.BlendState.IndependentBlendEnable = true
	for color, i in desc.colors {
		pso_desc.RTVFormats[i] = view_format(color.format)
		pso_desc.BlendState.RenderTarget[i] = BLEND[color.blend]
	}

	pso: ^d3d.IPipelineState
	if !check(dev.device->CreateGraphicsPipelineState(&pso_desc, d3d.IPipelineState_UUID, (^rawptr)(&pso)), "CreateGraphicsPipelineState") {
		log.errorf("gpu: pipeline %q was not created", desc.label)
		return {}
	}
	set_name(pso, desc.label)
	return add_pipeline({info = gpu.pipeline_info(desc), pso = pso, topology = TOPOLOGY[desc.topology]}, desc.label)
}

create_compute_pipeline :: proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline {
	if err := gpu.validate_compute_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return {}
	}
	pso_desc := d3d.COMPUTE_PIPELINE_STATE_DESC {
		pRootSignature = dev.root_signature,
		CS             = bytecode(desc.compute),
	}
	pso: ^d3d.IPipelineState
	if !check(dev.device->CreateComputePipelineState(&pso_desc, d3d.IPipelineState_UUID, (^rawptr)(&pso)), "CreateComputePipelineState") {
		log.errorf("gpu: pipeline %q was not created", desc.label)
		return {}
	}
	set_name(pso, desc.label)
	return add_pipeline({info = {kind = .Compute}, pso = pso}, desc.label)
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	if entry, ok := gpu.pool_remove(&dev.pipeline_pool, pipeline); ok {
		defer_release(entry.pso, .Pipeline, pipeline.index)
	}
}

@(private = "file")
add_pipeline :: proc(entry: Pipeline_Entry, label: string) -> gpu.Pipeline {
	pipeline := gpu.pool_add(&dev.pipeline_pool, entry)
	if pipeline == {} {
		log.errorf("gpu: pipeline %q: more than %d pipelines", label, gpu.MAX_PIPELINES)
		entry.pso->Release()
	}
	return pipeline
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
