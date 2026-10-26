package gpu_d3d12

import "core:log"
import "core:sync"

import d3d "vendor:directx/d3d12"
import "vendor:directx/dxgi"

import "cinnabar:core/gpu"

@(private)
Buffer_Entry :: struct {
	desc:        gpu.Buffer_Desc,
	resource:    ^d3d.IResource,
	address:     d3d.GPU_VIRTUAL_ADDRESS,
	// A Readback buffer stays mapped. read_buffer returns its memory once the graphics fence passes ready_value,
	// which is READBACK_IN_FLIGHT from a copy into it until end_frame stamps the frame's fence value.
	mapped:      [^]byte,
	ready_value: u64,
}

// A Readback buffer's ready_value while a copy into it waits for end_frame.
@(private)
READBACK_IN_FLIGHT :: max(u64)

@(private)
Texture_Entry :: struct {
	desc:     gpu.Texture_Desc,
	resource: ^d3d.IResource,
	// A Streamed texture is streamed once.
	streamed: bool,
	rtv:      d3d.CPU_DESCRIPTOR_HANDLE,
	dsv:      d3d.CPU_DESCRIPTOR_HANDLE,
}

@(private)
Release_Pool :: enum u8 {
	None,
	Buffer,
	Texture,
	Sampler,
	Pipeline,
	Accel,
	Upscaler,
}

// A destroyed object waits here until the GPU passes fence_value. Then the object is released
// and its pool slot, with the slot's descriptors, can be reused.
@(private)
Release :: struct {
	object:      ^d3d.IUnknown,
	// Backend memory, from dev.allocator, that the GPU work may still use.
	memory:      rawptr,
	// An upscaler's FidelityFX context, which the GPU work may still use.
	ffx_context: Ffx_Context,
	pool:        Release_Pool,
	index:       u32,
	// 0 until end_frame stamps it with the fence value of the frame that destroyed it.
	fence_value: u64,
	// The copy fence value that covers every copy recorded before the release: streaming may still use the object.
	copy_value:  u64,
}

@(private)
Resources :: struct {
	buffers:          gpu.Pool(gpu.Buffer, Buffer_Entry),
	textures:         gpu.Pool(gpu.Texture, Texture_Entry),
	samplers:         gpu.Pool(gpu.Sampler, gpu.Sampler_Desc),
	accels:           gpu.Pool(gpu.Accel_Struct, Accel_Entry),
	// Shader-visible heaps, indexed by bindless index.
	resource_heap:    ^d3d.IDescriptorHeap,
	sampler_heap:     ^d3d.IDescriptorHeap,
	// CPU-only heaps, indexed by texture pool index. The RTV heap also holds the back buffers after MAX_TEXTURES.
	rtv_heap:         ^d3d.IDescriptorHeap,
	dsv_heap:         ^d3d.IDescriptorHeap,
	resource_size:    u32,
	sampler_size:     u32,
	rtv_size:         u32,
	dsv_size:         u32,
	releases:         [dynamic]Release,
	releases_mutex:   sync.Mutex,
	// The Readback buffers that the frame's command lists copy into, for end_frame to stamp. Guarded by
	// releases_mutex.
	readbacks:        [dynamic]gpu.Buffer,
	// Only debug validation tracks layouts.
	layouts:          gpu.Layout_Tracker,
}

@(private)
init_resources :: proc() -> bool {
	gpu.pool_init(&dev.buffers, gpu.MAX_BUFFERS, dev.allocator)
	gpu.pool_init(&dev.textures, gpu.MAX_TEXTURES, dev.allocator)
	gpu.pool_init(&dev.samplers, gpu.MAX_SAMPLERS, dev.allocator)
	gpu.pool_init(&dev.accels, gpu.MAX_ACCEL_STRUCTS, dev.allocator)
	dev.releases = make([dynamic]Release, dev.allocator)
	dev.readbacks = make([dynamic]gpu.Buffer, dev.allocator)
	gpu.layout_tracker_init(&dev.layouts, dev.allocator)

	dev.resource_heap = create_descriptor_heap(.CBV_SRV_UAV, gpu.RESOURCE_DESCRIPTOR_COUNT, {.SHADER_VISIBLE}) or_return
	dev.sampler_heap = create_descriptor_heap(.SAMPLER, gpu.MAX_SAMPLERS, {.SHADER_VISIBLE}) or_return
	// After the bindless textures: the back buffers, or in shared mode the shared textures and the scratch target.
	dev.rtv_heap = create_descriptor_heap(.RTV, gpu.MAX_TEXTURES + max(BACK_BUFFER_COUNT, SHARED_RTV_COUNT), {}) or_return
	dev.dsv_heap = create_descriptor_heap(.DSV, gpu.MAX_TEXTURES, {}) or_return
	dev.resource_size = dev.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)
	dev.sampler_size = dev.device->GetDescriptorHandleIncrementSize(.SAMPLER)
	dev.rtv_size = dev.device->GetDescriptorHandleIncrementSize(.RTV)
	dev.dsv_size = dev.device->GetDescriptorHandleIncrementSize(.DSV)
	return true
}

// shutdown_resources releases every object. The GPU must be idle.
@(private)
shutdown_resources :: proc() {
	for r in dev.releases {
		if r.object != nil {
			r.object->Release()
		}
		if r.ffx_context != nil {
			destroy_ffx_context(r.ffx_context)
		}
		free(r.memory, dev.allocator)
	}
	delete(dev.releases)
	delete(dev.readbacks)
	// The back buffers are released with the swapchain.
	if target := gpu.pool_get(&dev.textures, dev.frame_target); target != nil {
		target.resource = nil
	}
	gpu.pool_each(&dev.buffers, proc(entry: ^Buffer_Entry) {release(&entry.resource)})
	gpu.pool_each(&dev.textures, proc(entry: ^Texture_Entry) {release(&entry.resource)})
	gpu.pool_each(&dev.accels, proc(entry: ^Accel_Entry) {release(&entry.resource)})
	gpu.pool_destroy(&dev.accels)
	gpu.pool_destroy(&dev.buffers)
	gpu.pool_destroy(&dev.textures)
	gpu.pool_destroy(&dev.samplers)
	gpu.layout_tracker_destroy(&dev.layouts)
	release(&dev.resource_heap)
	release(&dev.sampler_heap)
	release(&dev.rtv_heap)
	release(&dev.dsv_heap)
}

create_buffer :: proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
	if err := gpu.validate_buffer_desc(desc, data); err != .None {
		log.errorf("gpu: buffer %q: %v", desc.label, err)
		return {}
	}
	readback := .Readback in desc.usage
	resource, ok := create_buffer_resource(desc, .READBACK if readback else .DEFAULT)
	if !ok {
		return {}
	}
	buffer := add_buffer(desc, resource)
	if buffer == {} {
		return {}
	}
	if readback {
		entry := gpu.pool_get(&dev.buffers, buffer)
		if !check(resource->Map(0, nil, (^rawptr)(&entry.mapped)), "IResource.Map(readback)") {
			destroy_buffer(buffer)
			return {}
		}
	}
	if data != nil {
		upload_buffer(resource, data)
	}
	return buffer
}

// add_buffer stores a buffer resource and writes its views. It takes ownership of the resource.
@(private)
add_buffer :: proc(desc: gpu.Buffer_Desc, resource: ^d3d.IResource) -> gpu.Buffer {
	stored := desc
	stored.label = ""
	buffer := gpu.pool_add(&dev.buffers, Buffer_Entry{desc = stored, resource = resource, address = resource->GetGPUVirtualAddress()})
	if buffer == {} {
		log.errorf("gpu: buffer %q: more than %d buffers", desc.label, gpu.MAX_BUFFERS)
		resource->Release()
		return {}
	}
	// The GPU only copies into a readback buffer, so it has no views.
	if .Readback in desc.usage {
		return buffer
	}

	srv := d3d.SHADER_RESOURCE_VIEW_DESC {
		Format                  = .R32_TYPELESS,
		ViewDimension           = .BUFFER,
		Shader4ComponentMapping = d3d.DEFAULT_SHADER_4_COMPONENT_MAPPING,
	}
	srv.Buffer = {
		NumElements = desc.size / 4,
		Flags       = {.RAW},
	}
	dev.device->CreateShaderResourceView(resource, &srv, resource_handle(gpu.buffer_read_index(buffer)))
	if .Storage in desc.usage {
		uav := d3d.UNORDERED_ACCESS_VIEW_DESC {
			Format        = .R32_TYPELESS,
			ViewDimension = .BUFFER,
		}
		uav.Buffer = {
			NumElements = desc.size / 4,
			Flags       = {.RAW},
		}
		dev.device->CreateUnorderedAccessView(resource, nil, &uav, resource_handle(gpu.buffer_write_index(buffer)))
	}
	return buffer
}

@(private)
create_buffer_resource :: proc(desc: gpu.Buffer_Desc, heap: d3d.HEAP_TYPE) -> (resource: ^d3d.IResource, ok: bool) {
	heap_props := d3d.HEAP_PROPERTIES {
		Type = heap,
	}
	resource_desc := d3d.RESOURCE_DESC1 {
		Dimension        = .BUFFER,
		Width            = u64(desc.size),
		Height           = 1,
		DepthOrArraySize = 1,
		MipLevels        = 1,
		SampleDesc       = {Count = 1},
		Layout           = .ROW_MAJOR,
	}
	if .Storage in desc.usage {
		resource_desc.Flags += {.ALLOW_UNORDERED_ACCESS}
	}
	// Buffers have no layout, so they start UNDEFINED.
	hr := dev.device->CreateCommittedResource3(&heap_props, {}, &resource_desc, .UNDEFINED, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&resource))
	if !check(hr, "CreateCommittedResource3(buffer)") {
		return nil, false
	}
	set_name(resource, desc.label)
	return resource, true
}

create_texture :: proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
	if err := gpu.validate_texture_desc(desc, data); err != .None {
		log.errorf("gpu: texture %q: %v", desc.label, err)
		return {}
	}
	stored := desc
	stored.label = ""
	stored.mip_count = max(desc.mip_count, 1)

	heap_props := d3d.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	resource_desc := d3d.RESOURCE_DESC1 {
		Dimension        = desc.depth > 0 ? .TEXTURE3D : .TEXTURE2D,
		Width            = u64(desc.size.x),
		Height           = desc.size.y,
		DepthOrArraySize = u16(max(desc.depth, 1)),
		MipLevels        = u16(stored.mip_count),
		Format           = resource_format(desc.format),
		SampleDesc       = {Count = 1},
	}
	if .Render_Target in desc.usage {
		resource_desc.Flags += {.ALLOW_RENDER_TARGET}
	}
	if .Depth_Stencil in desc.usage {
		resource_desc.Flags += {.ALLOW_DEPTH_STENCIL}
		if .Sampled not_in desc.usage {
			resource_desc.Flags += {.DENY_SHADER_RESOURCE}
		}
	}
	if .Storage in desc.usage {
		resource_desc.Flags += {.ALLOW_UNORDERED_ACCESS}
	}

	// Data arrives through a copy, and the copy moves the texture to the sampled layout.
	// Data arrives through a copy that moves the texture to the sampled layout. A streamed texture starts in the
	// common layout, because the copy queue writes it (see streaming.odin).
	layout := LAYOUT[gpu.initial_layout(desc.usage, false)]
	if data != nil {
		layout = .COPY_DEST
	} else if .Streamed in desc.usage {
		layout = .COMMON
	}
	resource: ^d3d.IResource
	hr := dev.device->CreateCommittedResource3(&heap_props, {}, &resource_desc, layout, nil, nil, 0, nil, d3d.IResource_UUID, (^rawptr)(&resource))
	if !check(hr, "CreateCommittedResource3(texture)") {
		return {}
	}
	set_name(resource, desc.label)

	texture := gpu.pool_add(&dev.textures, Texture_Entry{desc = stored, resource = resource})
	if texture == {} {
		log.errorf("gpu: texture %q: more than %d textures", desc.label, gpu.MAX_TEXTURES)
		resource->Release()
		return {}
	}
	entry := gpu.pool_get(&dev.textures, texture)
	write_texture_views(texture, entry)
	when ODIN_DEBUG {
		gpu.track_layout(&dev.layouts, texture, gpu.initial_layout(desc.usage, data != nil))
	}
	if data != nil {
		upload_texture(resource, &resource_desc, data)
	}
	return texture
}

@(private = "file")
write_texture_views :: proc(texture: gpu.Texture, entry: ^Texture_Entry) {
	desc := entry.desc
	if .Sampled in desc.usage {
		srv := d3d.SHADER_RESOURCE_VIEW_DESC {
			Format                  = srv_format(desc.format),
			ViewDimension           = .TEXTURE2D,
			Shader4ComponentMapping = d3d.DEFAULT_SHADER_4_COMPONENT_MAPPING,
		}
		srv.Texture2D.MipLevels = desc.mip_count
		if desc.depth > 0 {
			srv.ViewDimension = .TEXTURE3D
			srv.Texture3D = {MipLevels = 1}
		}
		dev.device->CreateShaderResourceView(entry.resource, &srv, resource_handle(gpu.texture_read_index(texture)))
		// The stencil plane's view takes the write slot, which a depth texture does not use (see gpu.stencil_index).
		if gpu.has_stencil(desc.format) {
			srv.Format = .X32_TYPELESS_G8X24_UINT
			srv.Texture2D.PlaneSlice = 1
			dev.device->CreateShaderResourceView(entry.resource, &srv, resource_handle(gpu.stencil_index(texture)))
		}
	}
	if .Storage in desc.usage {
		uav := d3d.UNORDERED_ACCESS_VIEW_DESC {
			Format        = view_format(desc.format),
			ViewDimension = .TEXTURE2D,
		}
		if desc.depth > 0 {
			uav.ViewDimension = .TEXTURE3D
			uav.Texture3D = {WSize = desc.depth}
		}
		dev.device->CreateUnorderedAccessView(entry.resource, nil, &uav, resource_handle(gpu.texture_write_index(texture)))
	}
	if .Render_Target in desc.usage {
		rtv := d3d.RENDER_TARGET_VIEW_DESC {
			Format        = view_format(desc.format),
			ViewDimension = .TEXTURE2D,
		}
		entry.rtv = rtv_handle(texture.index)
		dev.device->CreateRenderTargetView(entry.resource, &rtv, entry.rtv)
	}
	if .Depth_Stencil in desc.usage {
		dsv := d3d.DEPTH_STENCIL_VIEW_DESC {
			Format        = view_format(desc.format),
			ViewDimension = .TEXTURE2D,
		}
		entry.dsv = dsv_handle(texture.index)
		dev.device->CreateDepthStencilView(entry.resource, &dsv, entry.dsv)
	}
}

create_sampler :: proc(desc: gpu.Sampler_Desc) -> gpu.Sampler {
	stored := desc
	stored.label = ""
	sampler := gpu.pool_add(&dev.samplers, stored)
	if sampler == {} {
		log.errorf("gpu: sampler %q: more than %d samplers", desc.label, gpu.MAX_SAMPLERS)
		return {}
	}

	ADDRESS := [gpu.Address_Mode]d3d.TEXTURE_ADDRESS_MODE {
		.Repeat = .WRAP,
		.Mirror = .MIRROR,
		.Clamp  = .CLAMP,
	}
	FILTER := [gpu.Filter][gpu.Filter]d3d.FILTER {
		.Nearest = {.Nearest = .MIN_MAG_MIP_POINT, .Linear = .MIN_MAG_POINT_MIP_LINEAR},
		.Linear = {.Nearest = .MIN_MAG_LINEAR_MIP_POINT, .Linear = .MIN_MAG_MIP_LINEAR},
	}
	sampler_desc := d3d.SAMPLER_DESC {
		Filter         = FILTER[desc.filter][desc.mip_filter],
		AddressU       = ADDRESS[desc.address],
		AddressV       = ADDRESS[desc.address],
		AddressW       = ADDRESS[desc.address],
		MaxAnisotropy  = 1,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d.FLOAT32_MAX,
	}
	if desc.anisotropy > 1 {
		sampler_desc.Filter = .ANISOTROPIC
		sampler_desc.MaxAnisotropy = u32(min(desc.anisotropy, 16))
	}
	if desc.compare != .Always {
		COMPARISON_FILTER := [gpu.Filter][gpu.Filter]d3d.FILTER {
			.Nearest = {.Nearest = .COMPARISON_MIN_MAG_MIP_POINT, .Linear = .COMPARISON_MIN_MAG_POINT_MIP_LINEAR},
			.Linear = {.Nearest = .COMPARISON_MIN_MAG_LINEAR_MIP_POINT, .Linear = .COMPARISON_MIN_MAG_MIP_LINEAR},
		}
		sampler_desc.Filter = COMPARISON_FILTER[desc.filter][desc.mip_filter]
		sampler_desc.ComparisonFunc = COMPARE[desc.compare]
	}
	dev.device->CreateSampler(&sampler_desc, sampler_handle(gpu.sampler_index(sampler)))
	return sampler
}

// read_buffer returns a Readback buffer's mapped memory, once the GPU has finished every frame that copies into it.
read_buffer :: proc(buffer: gpu.Buffer) -> ([]byte, bool) {
	entry := gpu.pool_get(&dev.buffers, buffer)
	if entry == nil || entry.mapped == nil {
		return nil, false
	}
	if sync.atomic_load(&entry.ready_value) > dev.fence->GetCompletedValue() {
		return nil, false
	}
	return entry.mapped[:entry.desc.size], true
}

// mark_readback records a copy into a Readback buffer, which is in flight until its frame's fence passes. The
// translation jobs call it.
@(private)
mark_readback :: proc(buffer: gpu.Buffer, entry: ^Buffer_Entry) {
	sync.atomic_store(&entry.ready_value, READBACK_IN_FLIGHT)
	sync.guard(&dev.releases_mutex)
	append(&dev.readbacks, buffer)
}

// stamp_readbacks gives the frame's Readback buffers the fence value that the frame's work signals.
@(private)
stamp_readbacks :: proc(fence_value: u64) {
	sync.guard(&dev.releases_mutex)
	for buffer in dev.readbacks {
		if entry := gpu.pool_get(&dev.buffers, buffer); entry != nil {
			sync.atomic_store(&entry.ready_value, fence_value)
		}
	}
	clear(&dev.readbacks)
}

destroy_buffer :: proc(buffer: gpu.Buffer) {
	if entry, ok := gpu.pool_remove(&dev.buffers, buffer); ok {
		defer_release(entry.resource, .Buffer, buffer.index)
	}
}

destroy_texture :: proc(texture: gpu.Texture) {
	assert(texture != dev.frame_target, "gpu: the frame target cannot be destroyed")
	if entry, ok := gpu.pool_remove(&dev.textures, texture); ok {
		defer_release(entry.resource, .Texture, texture.index)
		when ODIN_DEBUG {
			gpu.untrack_layout(&dev.layouts, texture)
		}
	}
}

destroy_sampler :: proc(sampler: gpu.Sampler) {
	if _, ok := gpu.pool_remove(&dev.samplers, sampler); ok {
		defer_release(nil, .Sampler, sampler.index)
	}
}

destroy_scope :: proc(scope: gpu.Scope) -> (count: int) {
	assert(scope != .Permanent, "gpu: the Permanent scope belongs to core")
	for i in 0 ..< dev.buffers.count {
		if buffer, ok := gpu.pool_handle(&dev.buffers, i); ok && dev.buffers.items[i].desc.scope == scope {
			destroy_buffer(buffer)
			count += 1
		}
	}
	for i in 0 ..< dev.textures.count {
		if texture, ok := gpu.pool_handle(&dev.textures, i); ok && dev.textures.items[i].desc.scope == scope {
			destroy_texture(texture)
			count += 1
		}
	}
	for i in 0 ..< dev.samplers.count {
		if sampler, ok := gpu.pool_handle(&dev.samplers, i); ok && dev.samplers.items[i].scope == scope {
			destroy_sampler(sampler)
			count += 1
		}
	}
	for i in 0 ..< dev.accels.count {
		if accel, ok := gpu.pool_handle(&dev.accels, i); ok && dev.accels.items[i].scope == scope {
			destroy_accel(accel)
			count += 1
		}
	}
	for i in 0 ..< dev.upscaler_pool.count {
		if upscaler, ok := gpu.pool_handle(&dev.upscaler_pool, i); ok && dev.upscaler_pool.items[i].desc.scope == scope {
			destroy_upscaler(upscaler)
			count += 1
		}
	}
	for i in 0 ..< dev.pipeline_pool.count {
		if pipeline, ok := gpu.pool_handle(&dev.pipeline_pool, i); ok && dev.pipeline_pool.items[i].scope == scope {
			destroy_pipeline(pipeline)
			count += 1
		}
	}
	return
}

// defer_release releases the object and frees the pool slot after the GPU finishes the current frame.
@(private)
defer_release :: proc(object: ^d3d.IUnknown, pool: Release_Pool, index: u32) {
	sync.guard(&dev.releases_mutex)
	append(&dev.releases, Release{object = object, pool = pool, index = index, copy_value = sync.atomic_load(&dev.copy_horizon)})
}

// defer_free frees backend memory after the GPU finishes the current frame.
@(private)
defer_free :: proc(memory: rawptr) {
	sync.guard(&dev.releases_mutex)
	append(&dev.releases, Release{memory = memory, copy_value = sync.atomic_load(&dev.copy_horizon)})
}

// defer_release_upscaler destroys an upscaler's context and frees its pool slot after the GPU finishes the current
// frame.
@(private)
defer_release_upscaler :: proc(ctx: Ffx_Context, index: u32) {
	sync.guard(&dev.releases_mutex)
	append(&dev.releases, Release{ffx_context = ctx, pool = .Upscaler, index = index, copy_value = sync.atomic_load(&dev.copy_horizon)})
}

// stamp_releases assigns the fence value that the frame's work signals to the releases queued during the frame.
@(private)
stamp_releases :: proc(fence_value: u64) {
	sync.guard(&dev.releases_mutex)
	for &r in dev.releases {
		if r.fence_value == 0 {
			r.fence_value = fence_value
		}
	}
}

@(private)
collect_releases :: proc() {
	sync.guard(&dev.releases_mutex)
	completed := dev.fence->GetCompletedValue()
	copies := copy_completed()
	for i := 0; i < len(dev.releases); {
		r := dev.releases[i]
		// A pipeline slot waits for its compile job too, which writes the slot when it finishes.
		waiting := r.fence_value == 0 || r.fence_value > completed || r.copy_value > copies
		if waiting || (r.pool == .Pipeline && pipeline_compiling(r.index)) {
			i += 1
			continue
		}
		if r.object != nil {
			r.object->Release()
		}
		if r.ffx_context != nil {
			destroy_ffx_context(r.ffx_context)
		}
		free(r.memory, dev.allocator)
		switch r.pool {
		case .None:
		case .Buffer:
			gpu.pool_free(&dev.buffers, r.index)
		case .Texture:
			gpu.pool_free(&dev.textures, r.index)
		case .Sampler:
			gpu.pool_free(&dev.samplers, r.index)
		case .Pipeline:
			gpu.pool_free(&dev.pipeline_pool, r.index)
		case .Accel:
			gpu.pool_free(&dev.accels, r.index)
		case .Upscaler:
			gpu.pool_free(&dev.upscaler_pool, r.index)
		}
		unordered_remove(&dev.releases, i)
	}
}

@(private)
create_descriptor_heap :: proc(
	type: d3d.DESCRIPTOR_HEAP_TYPE,
	count: u32,
	flags: d3d.DESCRIPTOR_HEAP_FLAGS,
) -> (
	heap: ^d3d.IDescriptorHeap,
	ok: bool,
) {
	desc := d3d.DESCRIPTOR_HEAP_DESC {
		Type           = type,
		NumDescriptors = count,
		Flags          = flags,
	}
	check(dev.device->CreateDescriptorHeap(&desc, d3d.IDescriptorHeap_UUID, (^rawptr)(&heap)), "CreateDescriptorHeap") or_return
	return heap, true
}

@(private)
resource_handle :: proc(index: u32) -> (handle: d3d.CPU_DESCRIPTOR_HANDLE) {
	dev.resource_heap->GetCPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += uint(index * dev.resource_size)
	return
}

@(private)
sampler_handle :: proc(index: u32) -> (handle: d3d.CPU_DESCRIPTOR_HANDLE) {
	dev.sampler_heap->GetCPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += uint(index * dev.sampler_size)
	return
}

@(private)
rtv_handle :: proc(index: u32) -> (handle: d3d.CPU_DESCRIPTOR_HANDLE) {
	dev.rtv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += uint(index * dev.rtv_size)
	return
}

@(private)
dsv_handle :: proc(index: u32) -> (handle: d3d.CPU_DESCRIPTOR_HANDLE) {
	dev.dsv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += uint(index * dev.dsv_size)
	return
}

@(private)
VALIDATION_RESOURCES :: gpu.Resources {
	texture = proc(texture: gpu.Texture) -> (gpu.Texture_Desc, bool) {
		entry, ok := gpu.pool_lookup(&dev.textures, texture)
		return entry.desc, ok
	},
	buffer = proc(buffer: gpu.Buffer) -> (gpu.Buffer_Desc, bool) {
		entry, ok := gpu.pool_lookup(&dev.buffers, buffer)
		return entry.desc, ok
	},
	pipeline = proc(pipeline: gpu.Pipeline) -> (gpu.Pipeline_Info, bool) {
		entry, ok := gpu.pool_lookup(&dev.pipeline_pool, pipeline)
		return entry.info, ok
	},
	accel = proc(accel: gpu.Accel_Struct) -> (gpu.Accel_Info, bool) {
		entry, ok := gpu.pool_lookup(&dev.accels, accel)
		entry.info.inputs_valid = ok && accel_inputs_valid(&entry)
		return entry.info, ok
	},
	upscaler = proc(upscaler: gpu.Upscaler) -> (gpu.Upscaler_Desc, bool) {
		entry, ok := gpu.pool_lookup(&dev.upscaler_pool, upscaler)
		return entry.desc, ok
	},
}

// view_format is the format of render target, depth stencil and storage views.
@(private)
view_format :: proc(format: gpu.Format) -> dxgi.FORMAT {
	switch format {
	case .Unknown:
		return .UNKNOWN
	case .R8_Unorm:
		return .R8_UNORM
	case .RG8_Unorm:
		return .R8G8_UNORM
	case .RGBA8_Unorm:
		return .R8G8B8A8_UNORM
	case .RGBA8_Unorm_Srgb:
		return .R8G8B8A8_UNORM_SRGB
	case .BGRA8_Unorm:
		return .B8G8R8A8_UNORM
	case .BGRA8_Unorm_Srgb:
		return .B8G8R8A8_UNORM_SRGB
	case .RGB10A2_Unorm:
		return .R10G10B10A2_UNORM
	case .RG11B10_Float:
		return .R11G11B10_FLOAT
	case .R16_Float:
		return .R16_FLOAT
	case .RG16_Float:
		return .R16G16_FLOAT
	case .RGBA16_Float:
		return .R16G16B16A16_FLOAT
	case .R32_Uint:
		return .R32_UINT
	case .R32_Float:
		return .R32_FLOAT
	case .RG32_Float:
		return .R32G32_FLOAT
	case .RGBA32_Float:
		return .R32G32B32A32_FLOAT
	case .D32_Float:
		return .D32_FLOAT
	case .D32_Float_S8_Uint:
		return .D32_FLOAT_S8X24_UINT
	case .BC1_Unorm:
		return .BC1_UNORM
	case .BC1_Unorm_Srgb:
		return .BC1_UNORM_SRGB
	case .BC4_Unorm:
		return .BC4_UNORM
	case .BC5_Unorm:
		return .BC5_UNORM
	case .BC6H_Ufloat:
		return .BC6H_UF16
	case .BC7_Unorm:
		return .BC7_UNORM
	case .BC7_Unorm_Srgb:
		return .BC7_UNORM_SRGB
	}
	return .UNKNOWN
}

// Depth textures are typeless, so they can have both a depth view and a sampled view.
@(private = "file")
resource_format :: proc(format: gpu.Format) -> dxgi.FORMAT {
	#partial switch format {
	case .D32_Float:
		return .R32_TYPELESS
	case .D32_Float_S8_Uint:
		return .R32G8X24_TYPELESS
	}
	return view_format(format)
}

@(private = "file")
srv_format :: proc(format: gpu.Format) -> dxgi.FORMAT {
	#partial switch format {
	case .D32_Float:
		return .R32_FLOAT
	case .D32_Float_S8_Uint:
		return .R32_FLOAT_X8X24_TYPELESS
	}
	return view_format(format)
}
