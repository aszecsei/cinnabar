package gpu_d3d12

import "core:log"
import "core:mem"
import "core:sync"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// D3D12 requires these alignments for acceleration structure data, scratch memory and instance records.
ACCEL_ALIGNMENT :: 256
INSTANCE_ALIGNMENT :: 16

// The size of a scratch pool block. A build that needs more gets a block of its own size.
SCRATCH_BLOCK_SIZE :: 16 * mem.Megabyte

// Accel_Entry is an acceleration structure. A bottom-level structure keeps its geometry, because each build reads it.
// The scratch sizes are for its largest build and update; the memory comes from the frame's scratch pool.
@(private)
Accel_Entry :: struct {
	info:           gpu.Accel_Info,
	scope:          gpu.Scope,
	geometry_count: int,
	geometries:     [gpu.MAX_ACCEL_GEOMETRIES]gpu.Accel_Geometry,
	resource:       ^d3d.IResource,
	address:        d3d.GPU_VIRTUAL_ADDRESS,
	build_scratch:  u64,
	update_scratch: u64,
}

// Scratch_Pool is a frame's build scratch memory. Each build gets its own region, so builds in a frame never share
// scratch memory and need no barrier between them, on either queue. The pool resets when the frame's fence passes,
// like the upload ring. Its blocks stay for later frames.
// The pool never shrinks: it keeps the most memory any frame has needed, even after a burst of builds, such as a
// level load. To give memory back, free the blocks past those that recent frames used, once they have been unused
// for some frames.
@(private)
Scratch_Pool :: struct {
	blocks: [dynamic]Scratch_Block,
	// The block that allocations come from, and the offset in it.
	block:  int,
	offset: u64,
	// Translation jobs allocate concurrently.
	mutex:  sync.Mutex,
}

@(private)
Scratch_Block :: struct {
	resource: ^d3d.IResource,
	address:  d3d.GPU_VIRTUAL_ADDRESS,
	size:     u64,
}

@(private)
reset_scratch_pool :: proc(pool: ^Scratch_Pool) {
	pool.block, pool.offset = 0, 0
}

@(private)
destroy_scratch_pool :: proc(pool: ^Scratch_Pool) {
	for &block in pool.blocks {
		release(&block.resource)
	}
	delete(pool.blocks)
}

// scratch_alloc returns size bytes of the frame's scratch memory. It moves past a block that has no room left and adds
// a block when none has room.
@(private)
scratch_alloc :: proc(pool: ^Scratch_Pool, needed: u64) -> d3d.GPU_VIRTUAL_ADDRESS {
	size := u64(mem.align_forward_int(int(max(needed, 1)), ACCEL_ALIGNMENT))
	sync.guard(&pool.mutex)
	for ; pool.block < len(pool.blocks); pool.block, pool.offset = pool.block + 1, 0 {
		block := pool.blocks[pool.block]
		if pool.offset + size <= block.size {
			address := block.address + d3d.GPU_VIRTUAL_ADDRESS(pool.offset)
			pool.offset += size
			return address
		}
	}
	block_size := max(size, SCRATCH_BLOCK_SIZE)
	resource, ok := create_raw_buffer(block_size, {.ALLOW_UNORDERED_ACCESS}, "acceleration structure scratch")
	if !ok {
		log.panic("d3d12: cannot create acceleration structure scratch memory")
	}
	if pool.blocks == nil {
		pool.blocks = make([dynamic]Scratch_Block, dev.allocator)
	}
	block := Scratch_Block{resource, resource->GetGPUVirtualAddress(), block_size}
	append(&pool.blocks, block)
	log.debugf("d3d12: scratch pool block %d, %d bytes", len(pool.blocks), block_size)
	pool.block, pool.offset = len(pool.blocks) - 1, size
	return block.address
}

// create_accel sizes the structure for its largest build: a bottom-level structure's geometry, or a top-level
// structure's max_instances. Only a top-level structure gets a view at its bindless index.
create_accel :: proc(desc: gpu.Accel_Struct_Desc) -> gpu.Accel_Struct {
	if dev.features & {.Ray_Query, .Ray_Tracing_Pipeline} == {} {
		log.errorf("gpu: acceleration structure %q: the device has no ray tracing. Check gpu_features.", desc.label)
		return {}
	}
	if err := gpu.validate_accel_desc(desc); err != .None {
		log.errorf("gpu: acceleration structure %q: %v", desc.label, err)
		return {}
	}
	entry := Accel_Entry {
		info           = gpu.accel_info(desc),
		scope          = desc.scope,
		geometry_count = len(desc.geometries),
	}
	copy(entry.geometries[:], desc.geometries)

	geometry_descs: [gpu.MAX_ACCEL_GEOMETRIES]d3d.RAYTRACING_GEOMETRY_DESC
	inputs, ok := accel_inputs(&entry, &geometry_descs, 0, desc.max_instances)
	if !ok {
		log.errorf("gpu: acceleration structure %q: a geometry has an invalid buffer", desc.label)
		return {}
	}
	sizes: d3d.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
	dev.device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &sizes)

	result_size := u64(mem.align_forward_int(int(sizes.ResultDataMaxSizeInBytes), ACCEL_ALIGNMENT))
	entry.resource = create_raw_buffer(result_size, {.ALLOW_UNORDERED_ACCESS, .RAYTRACING_ACCELERATION_STRUCTURE}, desc.label) or_else nil
	if entry.resource == nil {
		return {}
	}
	entry.address = entry.resource->GetGPUVirtualAddress()
	entry.build_scratch = sizes.ScratchDataSizeInBytes
	entry.update_scratch = sizes.UpdateScratchDataSizeInBytes

	accel := gpu.pool_add(&dev.accels, entry)
	if accel == {} {
		log.errorf("gpu: acceleration structure %q: more than %d acceleration structures", desc.label, gpu.MAX_ACCEL_STRUCTS)
		release(&entry.resource)
		return {}
	}
	if desc.kind == .Top {
		srv := d3d.SHADER_RESOURCE_VIEW_DESC {
			ViewDimension           = .RAYTRACING_ACCELERATION_STRUCTURE,
			Shader4ComponentMapping = d3d.DEFAULT_SHADER_4_COMPONENT_MAPPING,
		}
		srv.RaytracingAccelerationStructure.Location = entry.address
		dev.device->CreateShaderResourceView(nil, &srv, resource_handle(gpu.accel_read_index(accel)))
	}
	return accel
}

destroy_accel :: proc(accel: gpu.Accel_Struct) {
	if entry, ok := gpu.pool_remove(&dev.accels, accel); ok {
		defer_release(entry.resource, .Accel, accel.index)
	}
}

// accel_reference is the structure's GPU address, which D3D12 instance records hold. 0 for an invalid handle.
accel_reference :: proc(accel: gpu.Accel_Struct) -> u64 {
	entry := gpu.pool_get(&dev.accels, accel)
	return entry != nil ? u64(entry.address) : 0
}

// build_accel records a build with scratch memory from the current frame's pool. Validation has checked the inputs.
@(private)
build_accel :: proc(list: ^d3d.IGraphicsCommandList7, build: ^gpu.Build_Accel) {
	entry := gpu.pool_get(&dev.accels, build.accel)
	assert(entry != nil, "gpu: invalid acceleration structure handle")
	instances: d3d.GPU_VIRTUAL_ADDRESS
	if build.instances != {} {
		buffer := gpu.pool_get(&dev.buffers, build.instances)
		assert(buffer != nil, "gpu: invalid buffer handle")
		instances = buffer.address + d3d.GPU_VIRTUAL_ADDRESS(build.offset)
	}
	geometry_descs: [gpu.MAX_ACCEL_GEOMETRIES]d3d.RAYTRACING_GEOMETRY_DESC
	inputs, ok := accel_inputs(entry, &geometry_descs, instances, build.count)
	assert(ok, "gpu: an acceleration structure's geometry buffer was destroyed")

	scratch := &dev.frames[dev.frame_index % FRAMES_IN_FLIGHT].scratch
	desc := d3d.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC {
		DestAccelerationStructureData    = entry.address,
		Inputs                           = inputs,
		ScratchAccelerationStructureData = scratch_alloc(scratch, build.update ? entry.update_scratch : entry.build_scratch),
	}
	if build.update {
		desc.Inputs.Flags += {.PERFORM_UPDATE}
		desc.SourceAccelerationStructureData = entry.address
	}
	list->BuildRaytracingAccelerationStructure(&desc, 0, nil)
}

// accel_inputs describes a build. It returns false if a geometry buffer is invalid.
@(private)
accel_inputs :: proc(
	entry: ^Accel_Entry,
	geometry_descs: ^[gpu.MAX_ACCEL_GEOMETRIES]d3d.RAYTRACING_GEOMETRY_DESC,
	instances: d3d.GPU_VIRTUAL_ADDRESS,
	instance_count: u32,
) -> (
	inputs: d3d.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS,
	ok: bool,
) {
	inputs.DescsLayout = .ARRAY
	inputs.Flags = .Prefer_Fast_Build in entry.info.flags ? {.PREFER_FAST_BUILD} : {.PREFER_FAST_TRACE}
	if .Allow_Update in entry.info.flags {
		inputs.Flags += {.ALLOW_UPDATE}
	}
	switch entry.info.kind {
	case .Top:
		inputs.Type = .TOP_LEVEL
		inputs.NumDescs = instance_count
		inputs.InstanceDescs = instances
	case .Bottom:
		for g, i in entry.geometries[:entry.geometry_count] {
			vertices := gpu.pool_get(&dev.buffers, g.vertices)
			if vertices == nil {
				return
			}
			triangles := d3d.RAYTRACING_GEOMETRY_TRIANGLES_DESC {
				VertexFormat = g.vertex_format == .RG32_Float ? .R32G32_FLOAT : .R32G32B32_FLOAT,
				VertexCount = g.vertex_count,
				VertexBuffer = {StartAddress = vertices.address + d3d.GPU_VIRTUAL_ADDRESS(g.vertex_offset), StrideInBytes = u64(g.vertex_stride)},
			}
			if g.indices != {} {
				indices := gpu.pool_get(&dev.buffers, g.indices)
				if indices == nil {
					return
				}
				triangles.IndexFormat = g.index_format == .U16 ? .R16_UINT : .R32_UINT
				triangles.IndexCount = g.index_count
				triangles.IndexBuffer = indices.address + d3d.GPU_VIRTUAL_ADDRESS(g.index_offset)
			}
			geometry_descs[i] = {
				Type  = .TRIANGLES,
				Flags = g.opaque ? {.OPAQUE} : {},
			}
			geometry_descs[i].Triangles = triangles
		}
		inputs.Type = .BOTTOM_LEVEL
		inputs.NumDescs = u32(entry.geometry_count)
		inputs.pGeometryDescs = &geometry_descs[0]
	}
	return inputs, true
}

// accel_inputs_valid reports whether a bottom-level structure's geometry buffers still exist.
@(private)
accel_inputs_valid :: proc(entry: ^Accel_Entry) -> bool {
	for g in entry.geometries[:entry.geometry_count] {
		if gpu.pool_get(&dev.buffers, g.vertices) == nil || (g.indices != {} && gpu.pool_get(&dev.buffers, g.indices) == nil) {
			return false
		}
	}
	return true
}

@(private = "file")
create_raw_buffer :: proc(size: u64, flags: d3d.RESOURCE_FLAGS, label: string) -> (resource: ^d3d.IResource, ok: bool) {
	heap_props := d3d.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	desc := d3d.RESOURCE_DESC1 {
		Dimension        = .BUFFER,
		Width            = size,
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		SampleDesc       = {Count = 1},
		Layout           = .ROW_MAJOR,
		Flags            = flags,
	}
	hr := dev.device->CreateCommittedResource3(&heap_props, {}, &desc, .UNDEFINED, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&resource))
	check(hr, "CreateCommittedResource3(acceleration structure)") or_return
	set_name(resource, label)
	return resource, true
}
