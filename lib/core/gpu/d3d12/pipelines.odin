package gpu_d3d12

import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

import d3d "vendor:directx/d3d12"
import "vendor:directx/dxgi"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

// The fixed root signature (see docs/gpu.md#binding-model). Shaders declare these with the macros in
// lib/core/gpu/shaders/cinnabar.hlsli.
ROOT_PUSH_CONSTANTS :: 0
ROOT_PASS_CONSTANTS :: 1
// One root constant at b2: the draw ID. An indirect draw's command signature sets it from each argument record.
// Every other draw sees 0.
ROOT_DRAW_ID :: 2

// pso, or program for a ray tracing pipeline, is nil until the pipeline's first compile job finishes. An update
// replaces it when the new version is ready. Read and write them atomically.
@(private)
Pipeline_Entry :: struct {
	info:     gpu.Pipeline_Info,
	pso:      ^d3d.IPipelineState,
	program:  ^Ray_Program,
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
	// Command signatures for the indirect commands. The draw signatures set ROOT_DRAW_ID from each record.
	draw_signature:     ^d3d.ICommandSignature,
	indexed_signature:  ^d3d.ICommandSignature,
	dispatch_signature: ^d3d.ICommandSignature,
	// Nil without Features.Mesh_Shaders.
	mesh_signature:     ^d3d.ICommandSignature,
}

@(private)
init_pipelines :: proc() -> bool {
	gpu.pool_init(&dev.pipeline_pool, gpu.MAX_PIPELINES, dev.allocator)
	dev.compiling = make([]int, gpu.MAX_PIPELINES, dev.allocator)

	params := root_parameters()
	desc := d3d.VERSIONED_ROOT_SIGNATURE_DESC {
		Version = ._1_1,
	}
	desc.Desc_1_1 = {
		NumParameters = len(params),
		pParameters   = &params[0],
		Flags         = ROOT_SIGNATURE_FLAGS,
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

	draw_id := d3d.INDIRECT_ARGUMENT_DESC {
		Type = .CONSTANT,
	}
	draw_id.Constant = {
		RootParameterIndex = ROOT_DRAW_ID,
		Num32BitValuesToSet = 1,
	}
	draw := [2]d3d.INDIRECT_ARGUMENT_DESC{draw_id, {Type = .DRAW}}
	indexed := [2]d3d.INDIRECT_ARGUMENT_DESC{draw_id, {Type = .DRAW_INDEXED}}
	dispatch := [1]d3d.INDIRECT_ARGUMENT_DESC{{Type = .DISPATCH}}
	dev.draw_signature = create_signature(draw[:], size_of(gpu.Draw_Indirect_Args), dev.root_signature) or_return
	dev.indexed_signature = create_signature(indexed[:], size_of(gpu.Draw_Indexed_Indirect_Args), dev.root_signature) or_return
	// A signature that sets no root arguments takes no root signature.
	dev.dispatch_signature = create_signature(dispatch[:], size_of(gpu.Dispatch_Indirect_Args), nil) or_return
	if .Mesh_Shaders in dev.features {
		mesh := [2]d3d.INDIRECT_ARGUMENT_DESC{draw_id, {Type = .DISPATCH_MESH}}
		dev.mesh_signature = create_signature(mesh[:], size_of(gpu.Draw_Mesh_Indirect_Args), dev.root_signature) or_return
	}
	return true
}

@(private = "file")
create_signature :: proc(
	args: []d3d.INDIRECT_ARGUMENT_DESC,
	stride: u32,
	root_signature: ^d3d.IRootSignature,
) -> (
	signature: ^d3d.ICommandSignature,
	ok: bool,
) {
	desc := d3d.COMMAND_SIGNATURE_DESC {
		ByteStride       = stride,
		NumArgumentDescs = u32(len(args)),
		pArgumentDescs   = raw_data(args),
	}
	check(dev.device->CreateCommandSignature(&desc, root_signature, d3d.ICommandSignature_UUID, (^rawptr)(&signature)), "CreateCommandSignature") or_return
	return signature, true
}

// The fixed root signature. CN_ROOT_SIGNATURE in lib/core/gpu/shaders/cinnabar.hlsli describes the same one, and
// tools/cook embeds it in every shader stage.
@(private = "file")
ROOT_SIGNATURE_FLAGS :: d3d.ROOT_SIGNATURE_FLAGS{.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED}

// D3D12_ROOT_DESCRIPTOR_FLAG_DATA_STATIC_WHILE_SET_AT_EXECUTE. vendor:directx/d3d12 numbers ROOT_DESCRIPTOR_FLAG's bits
// from 2 instead of 1, so its .DATA_STATIC_WHILE_SET_AT_EXECUTE is 0x8, which is DATA_STATIC.
@(private = "file")
DATA_STATIC_WHILE_SET_AT_EXECUTE :: 0x4

@(private = "file")
root_parameters :: proc() -> (params: [3]d3d.ROOT_PARAMETER1) {
	params[ROOT_PUSH_CONSTANTS].ParameterType = ._32BIT_CONSTANTS
	params[ROOT_PUSH_CONSTANTS].Constants = {
		ShaderRegister = 0,
		Num32BitValues = gpu.MAX_PUSH_CONSTANTS_SIZE / 4,
	}
	params[ROOT_PASS_CONSTANTS].ParameterType = .CBV
	params[ROOT_PASS_CONSTANTS].Descriptor = {
		ShaderRegister = 1,
		Flags          = transmute(d3d.ROOT_DESCRIPTOR_FLAGS)u32(DATA_STATIC_WHILE_SET_AT_EXECUTE),
	}
	params[ROOT_DRAW_ID].ParameterType = ._32BIT_CONSTANTS
	params[ROOT_DRAW_ID].Constants = {
		ShaderRegister = 2,
		Num32BitValues = 1,
	}
	return
}

// embedded_root_signature_matches compares a shader's embedded root signature with the backend's. A pipeline passes its
// root signature to D3D12, which then ignores the embedded one, so only this check catches CN_ROOT_SIGNATURE drifting
// from root_parameters. A shader without an embedded root signature passes.
@(private = "file")
embedded_root_signature_matches :: proc(blob: []byte) -> bool {
	if len(blob) == 0 {
		return true
	}
	deserializer: ^d3d.IVersionedRootSignatureDeserializer
	iid := d3d.IVersionedRootSignatureDeserializer_UUID
	if win.FAILED(d3d.CreateVersionedRootSignatureDeserializer(raw_data(blob), uint(len(blob)), iid, (^rawptr)(&deserializer))) {
		return true
	}
	defer deserializer->Release()
	desc: ^d3d.VERSIONED_ROOT_SIGNATURE_DESC
	if win.FAILED(deserializer->GetRootSignatureDescAtVersion(._1_1, &desc)) {
		return false
	}
	got := desc.Desc_1_1
	expected := root_parameters()
	if got.NumParameters != len(expected) || got.NumStaticSamplers != 0 || got.Flags != ROOT_SIGNATURE_FLAGS {
		return false
	}
	for e, i in expected {
		p := ([^]d3d.ROOT_PARAMETER1)(got.pParameters)[i]
		if p.ParameterType != e.ParameterType || p.ShaderVisibility != e.ShaderVisibility {
			return false
		}
		#partial switch e.ParameterType {
		case ._32BIT_CONSTANTS:
			if p.Constants != e.Constants {
				return false
			}
		case .CBV:
			if p.Descriptor != e.Descriptor {
				return false
			}
		}
	}
	return true
}

// check_root_signatures logs and returns false if a shader's embedded root signature differs from the backend's.
@(private = "file")
check_root_signatures :: proc(label: string, blobs: ..[]byte) -> bool {
	for blob in blobs {
		if !embedded_root_signature_matches(blob) {
			log.errorf(
				"gpu: pipeline %q: a shader's embedded root signature differs from the backend's. Keep CN_ROOT_SIGNATURE in cinnabar.hlsli equal to root_parameters in pipelines.odin.",
				label,
			)
			return false
		}
	}
	return true
}

// wait_compiles waits for the compile jobs. Call it before the GPU device shuts down.
@(private)
wait_compiles :: proc() {
	jobs.wait(&dev.compile_counter)
}

@(private)
shutdown_pipelines :: proc() {
	gpu.pool_each(&dev.pipeline_pool, proc(entry: ^Pipeline_Entry) {
		release(&entry.pso)
		if entry.program != nil {
			release(&entry.program.state)
			release(&entry.program.table)
			free(entry.program, dev.allocator)
		}
	})
	gpu.pool_destroy(&dev.pipeline_pool)
	delete(dev.compiling, dev.allocator)
	release(&dev.draw_signature)
	release(&dev.indexed_signature)
	release(&dev.dispatch_signature)
	release(&dev.mesh_signature)
	release(&dev.root_signature)
}

// bind_root_signature binds the descriptor heaps and the root signature at the start of a command list.
// A compute list has only the compute root signature.
@(private)
bind_root_signature :: proc(list: ^d3d.IGraphicsCommandList7, queue := gpu.Queue.Graphics) {
	// The heaps must be bound before a root signature that indexes them directly.
	heaps := [?]^d3d.IDescriptorHeap{dev.resource_heap, dev.sampler_heap}
	list->SetDescriptorHeaps(len(heaps), &heaps[0])
	if queue == .Graphics {
		list->SetGraphicsRootSignature(dev.root_signature)
	}
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

create_ray_tracing_pipeline :: proc(desc: gpu.Ray_Tracing_Pipeline_Desc) -> gpu.Pipeline {
	task, ok := ray_tracing_task(desc)
	return ok ? start_compile(task, {info = {kind = .Ray_Tracing}, scope = desc.scope}) : {}
}

update_ray_tracing_pipeline :: proc(pipeline: gpu.Pipeline, desc: gpu.Ray_Tracing_Pipeline_Desc) -> bool {
	task := ray_tracing_task(desc) or_return
	return start_update(pipeline, task, {info = {kind = .Ray_Tracing}})
}

destroy_pipeline :: proc(pipeline: gpu.Pipeline) {
	sync.guard(&dev.pipeline_mutex)
	if entry, ok := gpu.pool_remove(&dev.pipeline_pool, pipeline); ok {
		defer_release(sync.atomic_load(&entry.pso), .Pipeline, pipeline.index)
		if program := sync.atomic_load(&entry.program); program != nil {
			release_program(program)
		}
	}
}

// The shader table layout that D3D12 requires.
SHADER_IDENTIFIER_SIZE :: 32
SHADER_RECORD_ALIGNMENT :: 32
SHADER_TABLE_ALIGNMENT :: 64

// Ray_Program is a compiled ray tracing pipeline: its state object, and its shader table in an upload heap.
// A new version replaces the whole program, which stays alive until the frames that use it finish.
@(private)
Ray_Program :: struct {
	state:  ^d3d.IStateObject,
	table:  ^d3d.IResource,
	rays:   d3d.DISPATCH_RAYS_DESC,
}

// release_program releases a program after the GPU finishes the current frame.
@(private = "file")
release_program :: proc(program: ^Ray_Program) {
	defer_release(program.state, .None, 0)
	defer_release(program.table, .None, 0)
	defer_free(program)
}

// ray_tracing_task copies the library and the export names, as wide strings, into a compile task.
@(private = "file")
ray_tracing_task :: proc(desc: gpu.Ray_Tracing_Pipeline_Desc) -> (task: ^Compile_Task, ok: bool) {
	if err := gpu.validate_ray_tracing_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return
	}
	if .Ray_Tracing_Pipeline not_in dev.features {
		log.errorf("gpu: pipeline %q: the device has no ray tracing pipelines. Check gpu_features.", desc.label)
		return
	}
	task = new_task(desc.label, desc.library)
	task.is_ray_tracing = true
	task.payload_size = desc.max_payload_size
	task.attribute_size = desc.max_attribute_size > 0 ? desc.max_attribute_size : 8
	task.recursion = desc.max_recursion > 0 ? desc.max_recursion : 1
	task.miss_count = len(desc.miss)
	task.hit_count = len(desc.hit_groups)
	task.names = make([dynamic]win.wstring, dev.allocator)
	append(&task.names, wide(desc.ray_generation))
	for name in desc.miss {
		append(&task.names, wide(name))
	}
	for group in desc.hit_groups {
		append(&task.names, wide(group.name), wide(group.closest_hit), wide(group.any_hit))
	}
	return task, true
}

// wide copies a name for D3D12. An empty name is nil, which D3D12 reads as no shader.
@(private = "file")
wide :: proc(name: string) -> win.wstring {
	return name == "" ? nil : win.utf8_to_wstring(name, dev.allocator)
}

// build_program creates the state object and fills the shader table: the ray generation record, the miss records,
// then the hit group records, each table aligned as D3D12 requires. It runs on the compile job.
@(private = "file")
build_program :: proc(task: ^Compile_Task) -> (program: ^Ray_Program, ok: bool) {
	subobjects := make([dynamic]d3d.STATE_SUBOBJECT, context.temp_allocator)
	library := d3d.DXIL_LIBRARY_DESC {
		DXILLibrary = bytecode(task.blobs[0]),
	}
	append(&subobjects, d3d.STATE_SUBOBJECT{.DXIL_LIBRARY, &library})
	groups := make([]d3d.HIT_GROUP_DESC, task.hit_count, context.temp_allocator)
	first_group := 1 + task.miss_count
	for &group, i in groups {
		names := task.names[first_group + 3 * i:]
		group = {
			HitGroupExport         = names[0],
			Type                   = .TRIANGLES,
			ClosestHitShaderImport = names[1],
			AnyHitShaderImport     = names[2],
		}
		append(&subobjects, d3d.STATE_SUBOBJECT{.HIT_GROUP, &group})
	}
	shader_config := d3d.RAYTRACING_SHADER_CONFIG {
		MaxPayloadSizeInBytes   = task.payload_size,
		MaxAttributeSizeInBytes = task.attribute_size,
	}
	append(&subobjects, d3d.STATE_SUBOBJECT{.RAYTRACING_SHADER_CONFIG, &shader_config})
	root := d3d.GLOBAL_ROOT_SIGNATURE {
		pGlobalRootSignature = dev.root_signature,
	}
	append(&subobjects, d3d.STATE_SUBOBJECT{.GLOBAL_ROOT_SIGNATURE, &root})
	pipeline_config := d3d.RAYTRACING_PIPELINE_CONFIG {
		MaxTraceRecursionDepth = task.recursion,
	}
	append(&subobjects, d3d.STATE_SUBOBJECT{.RAYTRACING_PIPELINE_CONFIG, &pipeline_config})

	desc := d3d.STATE_OBJECT_DESC {
		Type          = .RAYTRACING_PIPELINE,
		NumSubobjects = u32(len(subobjects)),
		pSubobjects   = raw_data(subobjects),
	}
	state: ^d3d.IStateObject
	check(dev.device->CreateStateObject(&desc, d3d.IStateObject_UUID, (^rawptr)(&state)), "CreateStateObject") or_return
	properties: ^d3d.IStateObjectProperties
	if !check(state->QueryInterface(d3d.IStateObjectProperties_IID, (^rawptr)(&properties)), "QueryInterface(IStateObjectProperties)") {
		state->Release()
		return
	}
	defer properties->Release()

	miss_start := mem.align_forward_int(SHADER_IDENTIFIER_SIZE, SHADER_TABLE_ALIGNMENT)
	hit_start := mem.align_forward_int(miss_start + task.miss_count * SHADER_RECORD_ALIGNMENT, SHADER_TABLE_ALIGNMENT)
	size := hit_start + task.hit_count * SHADER_RECORD_ALIGNMENT
	table, table_ok := create_buffer_resource({size = u32(size), label = "shader table"}, .UPLOAD)
	if !table_ok {
		state->Release()
		return
	}
	mapped: [^]byte
	check(table->Map(0, &d3d.RANGE{}, (^rawptr)(&mapped)), "Map(shader table)")
	write_record :: proc(properties: ^d3d.IStateObjectProperties, name: win.wstring, record: [^]byte) -> bool {
		identifier := properties->GetShaderIdentifier(name)
		if identifier == nil {
			return false
		}
		mem.copy(record, identifier, SHADER_IDENTIFIER_SIZE)
		return true
	}
	ok = write_record(properties, task.names[0], mapped)
	for i in 0 ..< task.miss_count {
		ok &&= write_record(properties, task.names[1 + i], mapped[miss_start + i * SHADER_RECORD_ALIGNMENT:])
	}
	for i in 0 ..< task.hit_count {
		ok &&= write_record(properties, task.names[first_group + 3 * i], mapped[hit_start + i * SHADER_RECORD_ALIGNMENT:])
	}
	table->Unmap(0, nil)
	if !ok {
		log.errorf("gpu: pipeline %q: the library does not export a named shader or hit group", task.label)
		state->Release()
		table->Release()
		return nil, false
	}

	address := table->GetGPUVirtualAddress()
	program = new(Ray_Program, dev.allocator)
	program^ = {
		state = state,
		table = table,
	}
	program.rays.RayGenerationShaderRecord = {address, SHADER_IDENTIFIER_SIZE}
	program.rays.MissShaderTable = {
		address + d3d.GPU_VIRTUAL_ADDRESS(miss_start),
		u64(task.miss_count * SHADER_RECORD_ALIGNMENT),
		SHADER_RECORD_ALIGNMENT,
	}
	program.rays.HitGroupTable = {
		address + d3d.GPU_VIRTUAL_ADDRESS(hit_start),
		u64(task.hit_count * SHADER_RECORD_ALIGNMENT),
		SHADER_RECORD_ALIGNMENT,
	}
	return program, true
}

// graphics_task builds the compile task and the pool entry for a description.
@(private = "file")
graphics_task :: proc(desc: gpu.Graphics_Pipeline_Desc) -> (task: ^Compile_Task, entry: Pipeline_Entry, ok: bool) {
	if err := gpu.validate_graphics_pipeline_desc(desc); err != .None {
		log.errorf("gpu: pipeline %q: %v", desc.label, err)
		return
	}

	when ODIN_DEBUG {
		check_root_signatures(desc.label, desc.vertex, desc.amplification, desc.mesh, desc.pixel) or_return
	}
	is_mesh := len(desc.mesh) > 0
	if is_mesh && .Mesh_Shaders not_in dev.features {
		log.errorf("gpu: pipeline %q: the device has no mesh shaders. Check gpu_features and use a vertex pipeline.", desc.label)
		return
	}

	// The job outlives the call, and the blobs may be in the game DLL's image, so they are copied.
	// A mesh pipeline keeps its fixed-function state in task.graphics too, and compiles through a stream.
	if is_mesh {
		task = new_task(desc.label, desc.pixel, desc.amplification, desc.mesh)
		task.is_mesh = true
	} else {
		task = new_task(desc.label, desc.pixel, desc.vertex)
	}
	task.graphics = {
		pRootSignature = dev.root_signature,
		VS = is_mesh ? {} : bytecode(task.blobs[1]),
		PS = bytecode(task.blobs[0]),
		SampleMask = max(u32),
		RasterizerState = {
			FillMode = .SOLID,
			CullMode = CULL[desc.cull],
			DepthBias = desc.depth_bias,
			SlopeScaledDepthBias = desc.slope_bias,
			DepthClipEnable = d3d.BOOL(!desc.depth_clamp),
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
	when ODIN_DEBUG {
		check_root_signatures(desc.label, desc.compute) or_return
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
	// blobs holds the pixel, amplification and mesh shaders.
	is_mesh:    bool,
	// blobs holds the library, and names the ray generation shader, the miss shaders, then each hit group's
	// name, closest hit and any hit.
	is_ray_tracing: bool,
	names:          [dynamic]win.wstring,
	miss_count:     int,
	hit_count:      int,
	payload_size:   u32,
	attribute_size: u32,
	recursion:      u32,
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
	for name in task.names {
		free(rawptr(name), dev.allocator)
	}
	delete(task.names)
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
	if task.is_ray_tracing {
		program, ok := build_program(task)
		if !ok {
			log.errorf(task.serial == 0 ? "gpu: pipeline %q was not created. Dispatches with it are skipped." : "gpu: pipeline %q was not updated. The previous version stays in use.", task.label)
		}
		publish_program(task, program)
		return
	}
	pso: ^d3d.IPipelineState
	hr: d3d.HRESULT
	if task.is_compute {
		hr = dev.device->CreateComputePipelineState(&task.compute, d3d.IPipelineState_UUID, (^rawptr)(&pso))
	} else if task.is_mesh {
		stream := mesh_stream(task)
		stream_desc := d3d.PIPELINE_STATE_STREAM_DESC {
			SizeInBytes                   = size_of(stream),
			pPipelineStateSubobjectStream = &stream,
		}
		hr = dev.device->CreatePipelineState(&stream_desc, d3d.IPipelineState_UUID, (^rawptr)(&pso))
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

// A pipeline state stream subobject. Like CD3DX12_PIPELINE_STATE_STREAM_SUBOBJECT, each one is aligned to a pointer.
@(private = "file")
Subobject :: struct($T: typeid) #align(8) {
	type:  d3d.PIPELINE_STATE_SUBOBJECT_TYPE,
	value: T,
}

#assert(size_of(Subobject(u32)) == 8 && offset_of(Subobject(u32), value) == 4)
#assert(size_of(Subobject(d3d.SHADER_BYTECODE)) == 24 && offset_of(Subobject(d3d.SHADER_BYTECODE), value) == 8)

@(private = "file")
Mesh_Stream :: struct {
	root_signature: Subobject(^d3d.IRootSignature),
	amplification:  Subobject(d3d.SHADER_BYTECODE),
	mesh:           Subobject(d3d.SHADER_BYTECODE),
	pixel:          Subobject(d3d.SHADER_BYTECODE),
	blend:          Subobject(d3d.BLEND_DESC),
	sample_mask:    Subobject(u32),
	rasterizer:     Subobject(d3d.RASTERIZER_DESC),
	depth_stencil:  Subobject(d3d.DEPTH_STENCIL_DESC),
	topology:       Subobject(d3d.PRIMITIVE_TOPOLOGY_TYPE),
	rt_formats:     Subobject(d3d.RT_FORMAT_ARRAY),
	dsv_format:     Subobject(dxgi.FORMAT),
	sample_desc:    Subobject(dxgi.SAMPLE_DESC),
}

// mesh_stream builds a mesh pipeline's stream from the fixed-function state in task.graphics. An empty
// amplification blob means no amplification shader.
@(private = "file")
mesh_stream :: proc(task: ^Compile_Task) -> Mesh_Stream {
	g := &task.graphics
	return {
		root_signature = {.ROOT_SIGNATURE, g.pRootSignature},
		amplification = {.AS, bytecode(task.blobs[1])},
		mesh = {.MS, bytecode(task.blobs[2])},
		pixel = {.PS, g.PS},
		blend = {.BLEND, g.BlendState},
		sample_mask = {.SAMPLE_MASK, g.SampleMask},
		rasterizer = {.RASTERIZER, g.RasterizerState},
		depth_stencil = {.DEPTH_STENCIL, g.DepthStencilState},
		topology = {.PRIMITIVE_TOPOLOGY, g.PrimitiveTopologyType},
		rt_formats = {.RENDER_TARGET_FORMATS, {RTFormats = g.RTVFormats, NumRenderTargets = g.NumRenderTargets}},
		dsv_format = {.DEPTH_STENCIL_FORMAT, g.DSVFormat},
		sample_desc = {.SAMPLE_DESC, g.SampleDesc},
	}
}

// publish_program makes a compiled program the pipeline's current version, as compile_job does for a PSO.
@(private = "file")
publish_program :: proc(task: ^Compile_Task, program: ^Ray_Program) {
	sync.guard(&dev.pipeline_mutex)
	defer sync.atomic_sub(&dev.compiling[task.pipeline.index], 1)
	entry := gpu.pool_get(&dev.pipeline_pool, task.pipeline)
	if entry == nil || entry.serial != task.serial {
		if program != nil {
			release_program(program)
		}
		return
	}
	if program == nil {
		return
	}
	if previous := sync.atomic_exchange(&entry.program, program); previous != nil {
		release_program(previous)
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

@(private)
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
