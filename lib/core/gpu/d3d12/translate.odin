package gpu_d3d12

import "core:sync"

import d3d "vendor:directx/d3d12"

import "cinnabar:core/gpu"

// translate records a command buffer into a command list. Release builds do not validate, so an
// invalid handle stops at an assert.
@(private)
translate :: proc(list: ^d3d.IGraphicsCommandList7, cb: gpu.Command_Buffer) {
	in_pass := false
	// False while the bound pipeline is still compiling: its draws and dispatches are skipped.
	pipeline_ready := false
	// The bound ray tracing pipeline's program, for Dispatch_Rays.
	program: ^Ray_Program
	it := gpu.packet_iterator(cb)
	for p in gpu.next_packet(&it) {
		switch p.kind {
		case .Begin_Pass:
			begin_pass(list, gpu.payload(p, gpu.Begin_Pass))
			in_pass = true
		case .End_Pass:
			list->EndRenderPass()
			in_pass = false
		case .Begin_Marker:
			label: [gpu.MAX_LABEL_LENGTH + 1]byte
			n := copy(label[:], gpu.marker_label(p))
			list->BeginEvent(PIX_EVENT_ANSI_VERSION, &label[0], u32(n + 1))
		case .End_Marker:
			list->EndEvent()
		case .Set_Pipeline:
			entry := gpu.pool_get(&dev.pipeline_pool, gpu.payload(p, gpu.Set_Pipeline).pipeline)
			assert(entry != nil, "gpu: invalid pipeline handle")
			if entry.info.kind == .Ray_Tracing {
				program = sync.atomic_load(&entry.program)
				pipeline_ready = program != nil
				if pipeline_ready {
					list->SetPipelineState1(program.state)
				}
				continue
			}
			pso := sync.atomic_load(&entry.pso)
			pipeline_ready = pso != nil
			if !pipeline_ready {
				continue
			}
			list->SetPipelineState(pso)
			if entry.info.kind == .Graphics {
				list->IASetPrimitiveTopology(entry.topology)
			}
		case .Push_Constants:
			data := gpu.push_constants_data(p)
			if in_pass {
				list->SetGraphicsRoot32BitConstants(ROOT_PUSH_CONSTANTS, u32(len(data) / 4), raw_data(data), 0)
			} else {
				list->SetComputeRoot32BitConstants(ROOT_PUSH_CONSTANTS, u32(len(data) / 4), raw_data(data), 0)
			}
		case .Set_Pass_Constants:
			constants := gpu.payload(p, gpu.Set_Pass_Constants)
			address := buffer_entry(constants.buffer).address + d3d.GPU_VIRTUAL_ADDRESS(constants.offset)
			if in_pass {
				list->SetGraphicsRootConstantBufferView(ROOT_PASS_CONSTANTS, address)
			} else {
				list->SetComputeRootConstantBufferView(ROOT_PASS_CONSTANTS, address)
			}
		case .Set_Index_Buffer:
			index := gpu.payload(p, gpu.Set_Index_Buffer)
			entry := buffer_entry(index.buffer)
			view := d3d.INDEX_BUFFER_VIEW {
				BufferLocation = entry.address + d3d.GPU_VIRTUAL_ADDRESS(index.offset),
				SizeInBytes    = entry.desc.size - index.offset,
				Format         = index.format == .U16 ? .R16_UINT : .R32_UINT,
			}
			list->IASetIndexBuffer(&view)
		case .Set_Viewport:
			v := gpu.payload(p, gpu.Set_Viewport)
			viewport := d3d.VIEWPORT{v.position.x, v.position.y, v.size.x, v.size.y, v.min_depth, v.max_depth}
			list->RSSetViewports(1, &viewport)
		case .Set_Stencil_Reference:
			list->OMSetStencilRef(gpu.payload(p, gpu.Set_Stencil_Reference).reference)
		case .Set_Scissor:
			s := gpu.payload(p, gpu.Set_Scissor)
			rect := d3d.RECT{s.position.x, s.position.y, s.position.x + s.size.x, s.position.y + s.size.y}
			list->RSSetScissorRects(1, &rect)
		case .Draw:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Draw)
			list->DrawInstanced(d.vertex_count, d.instance_count, d.first_vertex, d.first_instance)
		case .Draw_Indexed:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Draw_Indexed)
			list->DrawIndexedInstanced(d.index_count, d.instance_count, d.first_index, d.vertex_offset, d.first_instance)
		case .Dispatch:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Dispatch)
			list->Dispatch(d.groups.x, d.groups.y, d.groups.z)
		case .Barriers:
			barriers(list, p)
		case .Draw_Indirect, .Draw_Indexed_Indirect:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Draw_Indirect)
			signature := p.kind == .Draw_Indirect ? dev.draw_signature : dev.indexed_signature
			execute_indirect(list, signature, d.arguments, d.offset, d.max_count, d.count, d.count_offset)
			// The draws set the draw ID, and ExecuteIndirect leaves it undefined afterward.
			list->SetGraphicsRoot32BitConstant(ROOT_DRAW_ID, 0, 0)
		case .Draw_Mesh:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Draw_Mesh)
			list->DispatchMesh(d.groups.x, d.groups.y, d.groups.z)
		case .Draw_Mesh_Indirect:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Draw_Indirect)
			execute_indirect(list, dev.mesh_signature, d.arguments, d.offset, d.max_count, d.count, d.count_offset)
			list->SetGraphicsRoot32BitConstant(ROOT_DRAW_ID, 0, 0)
		case .Build_Accel:
			build_accel(list, gpu.payload(p, gpu.Build_Accel))
		case .Copy_Buffer:
			c := gpu.payload(p, gpu.Copy_Buffer)
			dest, source := buffer_entry(c.dest), buffer_entry(c.source)
			list->CopyBufferRegion(dest.resource, u64(c.dest_offset), source.resource, u64(c.source_offset), u64(c.size))
			if dest.mapped != nil {
				mark_readback(c.dest, dest)
			}
		case .Dispatch_Rays:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Dispatch_Rays)
			rays := program.rays
			rays.Width, rays.Height, rays.Depth = d.size.x, d.size.y, d.size.z
			list->DispatchRays(&rays)
		case .Dispatch_Indirect:
			if !pipeline_ready {
				continue
			}
			d := gpu.payload(p, gpu.Dispatch_Indirect)
			execute_indirect(list, dev.dispatch_signature, d.arguments, d.offset, 1, {}, 0)
		}
	}
}

@(private = "file")
begin_pass :: proc(list: ^d3d.IGraphicsCommandList7, pass: ^gpu.Begin_Pass) {
	size: [2]u32
	targets: [gpu.MAX_COLOR_ATTACHMENTS]d3d.RENDER_PASS_RENDER_TARGET_DESC
	for color, i in pass.colors[:pass.color_count] {
		entry := texture_entry(color.texture)
		size = entry.desc.size
		target := &targets[i]
		target.cpuDescriptor = entry.rtv
		target.BeginningAccess = beginning_access(color.load, entry.desc.format, {Color = color.clear})
		target.EndingAccess.Type = ending_access(color.store)
	}

	depth: d3d.RENDER_PASS_DEPTH_STENCIL_DESC
	depth_ptr: ^d3d.RENDER_PASS_DEPTH_STENCIL_DESC
	if pass.depth.texture != {} {
		entry := texture_entry(pass.depth.texture)
		size = entry.desc.size
		clear: d3d.CLEAR_VALUE
		clear.DepthStencil = {Depth = pass.depth.clear, Stencil = pass.depth.stencil_clear}
		depth = {
			cpuDescriptor = entry.dsv,
			DepthBeginningAccess = beginning_access(pass.depth.load, entry.desc.format, clear),
			DepthEndingAccess = {Type = ending_access(pass.depth.store)},
			StencilBeginningAccess = {Type = .NO_ACCESS},
			StencilEndingAccess = {Type = .NO_ACCESS},
		}
		if gpu.has_stencil(entry.desc.format) {
			depth.StencilBeginningAccess = beginning_access(pass.depth.load, entry.desc.format, clear)
			depth.StencilEndingAccess = {Type = ending_access(pass.depth.store)}
		}
		depth_ptr = &depth
	}
	// The pieces of a split pass are in consecutive command lists of one ExecuteCommandLists call, because submit
	// keeps the order and each frame executes in one call.
	flags: d3d.RENDER_PASS_FLAGS
	if .Suspending in pass.flags {
		flags += {.SUSPENDING_PASS}
	}
	if .Resuming in pass.flags {
		flags += {.RESUMING_PASS}
	}
	list->BeginRenderPass(pass.color_count, &targets[0], depth_ptr, flags)

	viewport := d3d.VIEWPORT {
		Width    = f32(size.x),
		Height   = f32(size.y),
		MaxDepth = 1,
	}
	scissor := d3d.RECT {
		right  = i32(size.x),
		bottom = i32(size.y),
	}
	list->RSSetViewports(1, &viewport)
	list->RSSetScissorRects(1, &scissor)
	list->SetGraphicsRoot32BitConstant(ROOT_DRAW_ID, 0, 0)
	list->OMSetStencilRef(0)
}

@(private = "file")
beginning_access :: proc(load: gpu.Load_Op, format: gpu.Format, clear: d3d.CLEAR_VALUE) -> (access: d3d.RENDER_PASS_BEGINNING_ACCESS) {
	switch load {
	case .Load:
		access.Type = .PRESERVE
	case .Clear:
		access.Type = .CLEAR
		access.Clear.ClearValue = clear
		access.Clear.ClearValue.Format = view_format(format)
	case .Discard:
		access.Type = .DISCARD
	}
	return
}

@(private = "file")
ending_access :: proc(store: gpu.Store_Op) -> d3d.RENDER_PASS_ENDING_ACCESS_TYPE {
	return store == .Store ? .PRESERVE : .DISCARD
}

@(private = "file")
execute_indirect :: proc(
	list: ^d3d.IGraphicsCommandList7,
	signature: ^d3d.ICommandSignature,
	arguments: gpu.Buffer,
	offset, max_count: u32,
	count: gpu.Buffer,
	count_offset: u32,
) {
	count_resource: ^d3d.IResource
	if count != {} {
		count_resource = buffer_entry(count).resource
	}
	list->ExecuteIndirect(signature, max_count, buffer_entry(arguments).resource, u64(offset), count_resource, u64(count_offset))
}

@(private = "file")
barriers :: proc(list: ^d3d.IGraphicsCommandList7, packet: gpu.Packet) {
	buffers, textures, accels := gpu.barrier_data(packet)
	buffer_barriers: [gpu.MAX_PACKET_BARRIERS]d3d.BUFFER_BARRIER
	texture_barriers: [gpu.MAX_PACKET_BARRIERS]d3d.TEXTURE_BARRIER
	for b, i in buffers {
		buffer_barriers[i] = {
			SyncBefore   = sync_flags(b.sync_before),
			SyncAfter    = sync_flags(b.sync_after),
			AccessBefore = access_flags(b.access_before),
			AccessAfter  = access_flags(b.access_after),
			pRessource   = buffer_entry(b.buffer).resource,
			Size         = max(u64),
		}
	}
	// An acceleration structure is a buffer to D3D12.
	for b, i in accels {
		entry := gpu.pool_get(&dev.accels, b.accel)
		assert(entry != nil, "gpu: invalid acceleration structure handle")
		buffer_barriers[len(buffers) + i] = {
			SyncBefore   = sync_flags(b.sync_before),
			SyncAfter    = sync_flags(b.sync_after),
			AccessBefore = access_flags(b.access_before),
			AccessAfter  = access_flags(b.access_after),
			pRessource   = entry.resource,
			Size         = max(u64),
		}
	}
	for b, i in textures {
		texture_barriers[i] = {
			SyncBefore = sync_flags(b.sync_before),
			SyncAfter = sync_flags(b.sync_after),
			AccessBefore = access_flags(b.access_before),
			AccessAfter = access_flags(b.access_after),
			LayoutBefore = LAYOUT[b.layout_before],
			LayoutAfter = LAYOUT[b.layout_after],
			pResource = texture_entry(b.texture).resource,
			// 0xffffffff selects all subresources.
			Subresources = {IndexOrFirstMipLevel = 0xffffffff},
		}
	}

	groups: [2]d3d.BARRIER_GROUP
	count: u32
	if len(buffers) + len(accels) > 0 {
		groups[count] = {
			Type            = .BUFFER,
			NumBarriers     = u32(len(buffers) + len(accels)),
			pBufferBarriers = &buffer_barriers[0],
		}
		count += 1
	}
	if len(textures) > 0 {
		groups[count] = {
			Type             = .TEXTURE,
			NumBarriers      = u32(len(textures)),
			pTextureBarriers = &texture_barriers[0],
		}
		count += 1
	}
	list->Barrier(count, &groups[0])
}

@(private = "file")
sync_flags :: proc(syncs: gpu.Syncs) -> (flags: d3d.BARRIER_SYNC_FLAGS) {
	for s in syncs {
		flags += {SYNC[s]}
	}
	return
}

// An empty gpu.Accesses is NO_ACCESS. D3D12's empty access set means COMMON, which the interface does not use.
@(private = "file")
access_flags :: proc(accesses: gpu.Accesses) -> (flags: d3d.BARRIER_ACCESS_FLAGS) {
	if accesses == {} {
		return {.NO_ACCESS}
	}
	for a in accesses {
		flags += {ACCESS[a]}
	}
	return
}

@(private = "file")
SYNC := [gpu.Sync]d3d.BARRIER_SYNC_FLAG {
	.All             = .ALL,
	.Index_Input     = .INDEX_INPUT,
	.Vertex_Shading  = .VERTEX_SHADING,
	.Pixel_Shading   = .PIXEL_SHADING,
	.Depth_Stencil   = .DEPTH_STENCIL,
	.Render_Target   = .RENDER_TARGET,
	.Compute_Shading = .COMPUTE_SHADING,
	.Execute_Indirect = .EXECUTE_INDIRECT,
	.Build_Accel      = .BUILD_RAYTRACING_ACCELERATION_STRUCTURE,
	.Ray_Tracing      = .RAYTRACING,
	.Copy             = .COPY,
}

@(private = "file")
ACCESS := [gpu.Access]d3d.BARRIER_ACCESS_FLAG {
	.Index_Buffer        = .INDEX_BUFFER,
	.Render_Target       = .RENDER_TARGET,
	.Depth_Stencil_Write = .DEPTH_STENCIL_WRITE,
	.Shader_Resource     = .SHADER_RESOURCE,
	.Unordered_Access    = .UNORDERED_ACCESS,
	.Indirect_Argument   = .INDIRECT_ARGUMENT,
	.Accel_Read          = .RAYTRACING_ACCELERATION_STRUCTURE_READ,
	.Accel_Write         = .RAYTRACING_ACCELERATION_STRUCTURE_WRITE,
	.Copy_Source         = .COPY_SOURCE,
	.Copy_Dest           = .COPY_DEST,
}

@(private)
LAYOUT := [gpu.Texture_Layout]d3d.BARRIER_LAYOUT {
	.Undefined           = .UNDEFINED,
	.Render_Target       = .RENDER_TARGET,
	.Depth_Stencil_Write = .DEPTH_STENCIL_WRITE,
	.Shader_Resource     = .SHADER_RESOURCE,
	.Unordered_Access    = .UNORDERED_ACCESS,
}

@(private = "file")
texture_entry :: proc(texture: gpu.Texture) -> ^Texture_Entry {
	entry := gpu.pool_get(&dev.textures, texture)
	assert(entry != nil, "gpu: invalid texture handle")
	return entry
}

@(private = "file")
buffer_entry :: proc(buffer: gpu.Buffer) -> ^Buffer_Entry {
	entry := gpu.pool_get(&dev.buffers, buffer)
	assert(entry != nil, "gpu: invalid buffer handle")
	return entry
}
