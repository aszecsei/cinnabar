package gpu

import "core:sync"

Validation_Error :: enum u8 {
	None,
	Nested_Pass,
	End_Pass_Outside_Pass,
	Unclosed_Pass,
	Bad_Attachment_Count,
	Invalid_Texture,
	Bad_Attachment_Usage,
	Attachment_Size_Mismatch,
	End_Marker_Without_Begin,
	Marker_Crosses_Pass,
	Unclosed_Marker,
	Invalid_Buffer,
	Invalid_Pipeline,
	Wrong_Pipeline_Kind,
	Pipeline_Pass_Mismatch,
	No_Pipeline,
	State_Outside_Pass,
	Bad_Buffer_Usage,
	No_Index_Buffer,
	Draw_Outside_Pass,
	Dispatch_Inside_Pass,
	Barrier_Inside_Pass,
	Bad_Barrier,
	Layout_Mismatch,
	Attachment_Layout,
	Bad_Resume,
	Bad_Suspend,
	Wrong_Queue,
	Bad_Indirect,
	Invalid_Accel,
	Build_Inside_Pass,
	Bad_Accel_Build,
	Copy_Inside_Pass,
	Bad_Copy,
}

// Resources lets validation look up handles. Each procedure returns false for an invalid handle.
Resources :: struct {
	texture:  proc(texture: Texture) -> (Texture_Desc, bool),
	buffer:   proc(buffer: Buffer) -> (Buffer_Desc, bool),
	pipeline: proc(pipeline: Pipeline) -> (Pipeline_Info, bool),
	accel:    proc(accel: Accel_Struct) -> (Accel_Info, bool),
}

// Layout_Tracker follows texture layouts across submissions for validation. The backends do not track layouts
// to translate barriers. Validation tracks them to find wrong barriers on every backend.
// A backend tracks each texture from its creation, and the frame target from the start of each frame.
Layout_Tracker :: struct {
	layouts: map[Texture]Texture_Layout,
	mutex:   sync.Mutex,
}

layout_tracker_init :: proc(tracker: ^Layout_Tracker, allocator := context.allocator) {
	tracker.layouts = make(map[Texture]Texture_Layout, allocator)
}

layout_tracker_destroy :: proc(tracker: ^Layout_Tracker) {
	delete(tracker.layouts)
	tracker^ = {}
}

track_layout :: proc(tracker: ^Layout_Tracker, texture: Texture, layout: Texture_Layout) {
	sync.guard(&tracker.mutex)
	tracker.layouts[texture] = layout
}

untrack_layout :: proc(tracker: ^Layout_Tracker, texture: Texture) {
	sync.guard(&tracker.mutex)
	delete_key(&tracker.layouts, texture)
}

tracked_layout :: proc(tracker: ^Layout_Tracker, texture: Texture) -> (layout: Texture_Layout, ok: bool) {
	sync.guard(&tracker.mutex)
	return tracker.layouts[texture]
}

// validate checks the rules that every backend enforces (see docs/gpu.md#pass-rules).
// With a tracker, it also checks barrier layouts and attachment layouts, and applies the barriers to the tracker.
// After a rejected command buffer, the tracker holds the layouts that the valid packets left.
// packet is the index of the offending packet, or the packet count for errors found at the end.
// queue is the queue that the command buffer is submitted to. A compute queue runs no render passes, and its barriers
// use only COMPUTE_QUEUE_SYNCS and COMPUTE_QUEUE_ACCESSES.
validate :: proc(
	cb: Command_Buffer,
	resources: Resources,
	layouts: ^Layout_Tracker = nil,
	queue := Queue.Graphics,
) -> (
	err: Validation_Error,
	packet: int,
) {
	if layouts != nil {
		sync.lock(&layouts.mutex)
	}
	defer if layouts != nil {
		sync.unlock(&layouts.mutex)
	}

	in_pass := false
	// The attachment formats of the current pass, as a pipeline would declare them.
	pass_formats: Pipeline_Info
	marker_depth := 0
	pass_marker_depth := 0
	// The packet index of a suspending pass's End_Pass. Nothing may follow it.
	suspended_at := -1
	pass_flags: Pass_Flags
	// Bindings reset at every pass boundary.
	graphics_bound := false
	mesh_bound := false
	compute_bound := false
	ray_tracing_bound := false
	index_buffer_set := false

	it := packet_iterator(cb)
	for p in next_packet(&it) {
		defer packet += 1
		if suspended_at >= 0 {
			return .Bad_Suspend, packet
		}
		switch p.kind {
		case .Begin_Pass:
			if queue != .Graphics {
				return .Wrong_Queue, packet
			}
			if in_pass {
				return .Nested_Pass, packet
			}
			pass := payload(p, Begin_Pass)
			if err = validate_pass_flags(pass, packet); err != .None {
				return err, packet
			}
			pass_flags = pass.flags
			pass_formats, err = validate_attachments(pass, resources)
			if err != .None {
				return err, packet
			}
			if layouts != nil && !attachments_in_layout(pass, layouts) {
				return .Attachment_Layout, packet
			}
			in_pass = true
			pass_marker_depth = marker_depth
			graphics_bound, mesh_bound, compute_bound, ray_tracing_bound = false, false, false, false
			index_buffer_set = false
		case .End_Pass:
			if !in_pass {
				return .End_Pass_Outside_Pass, packet
			}
			if marker_depth != pass_marker_depth {
				return .Marker_Crosses_Pass, packet
			}
			if .Suspending in pass_flags {
				suspended_at = packet
			}
			in_pass = false
			graphics_bound, mesh_bound, compute_bound, ray_tracing_bound = false, false, false, false
			index_buffer_set = false
		case .Begin_Marker:
			marker_depth += 1
		case .End_Marker:
			if marker_depth == 0 {
				return .End_Marker_Without_Begin, packet
			}
			if in_pass && marker_depth == pass_marker_depth {
				return .Marker_Crosses_Pass, packet
			}
			marker_depth -= 1
		case .Set_Pipeline:
			info, ok := resources.pipeline(payload(p, Set_Pipeline).pipeline)
			if !ok {
				return .Invalid_Pipeline, packet
			}
			raster := info.kind == .Graphics || info.kind == .Mesh
			if raster != in_pass {
				return .Wrong_Pipeline_Kind, packet
			}
			if raster && !same_formats(info, pass_formats) {
				return .Pipeline_Pass_Mismatch, packet
			}
			graphics_bound, mesh_bound = info.kind == .Graphics, info.kind == .Mesh
			compute_bound, ray_tracing_bound = info.kind == .Compute, info.kind == .Ray_Tracing
		case .Push_Constants:
		case .Set_Pass_Constants:
			if _, ok := resources.buffer(payload(p, Set_Pass_Constants).buffer); !ok {
				return .Invalid_Buffer, packet
			}
		case .Set_Index_Buffer:
			if !in_pass {
				return .State_Outside_Pass, packet
			}
			desc, ok := resources.buffer(payload(p, Set_Index_Buffer).buffer)
			if !ok {
				return .Invalid_Buffer, packet
			}
			if .Index not_in desc.usage {
				return .Bad_Buffer_Usage, packet
			}
			index_buffer_set = true
		case .Set_Viewport, .Set_Scissor:
			if !in_pass {
				return .State_Outside_Pass, packet
			}
		case .Draw, .Draw_Indexed:
			if !in_pass {
				return .Draw_Outside_Pass, packet
			}
			if mesh_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !graphics_bound {
				return .No_Pipeline, packet
			}
			if p.kind == .Draw_Indexed && !index_buffer_set {
				return .No_Index_Buffer, packet
			}
		case .Dispatch:
			if in_pass {
				return .Dispatch_Inside_Pass, packet
			}
			if ray_tracing_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !compute_bound {
				return .No_Pipeline, packet
			}
		case .Draw_Mesh:
			if !in_pass {
				return .Draw_Outside_Pass, packet
			}
			if graphics_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !mesh_bound {
				return .No_Pipeline, packet
			}
		case .Draw_Mesh_Indirect:
			if !in_pass {
				return .Draw_Outside_Pass, packet
			}
			if graphics_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !mesh_bound {
				return .No_Pipeline, packet
			}
			d := payload(p, Draw_Indirect)
			if err = validate_indirect(resources, d.arguments, d.offset, int(d.max_count) * size_of(Draw_Mesh_Indirect_Args)); err != .None {
				return err, packet
			}
			if d.count != {} {
				if err = validate_indirect(resources, d.count, d.count_offset, size_of(u32)); err != .None {
					return err, packet
				}
			}
		case .Draw_Indirect, .Draw_Indexed_Indirect:
			if !in_pass {
				return .Draw_Outside_Pass, packet
			}
			if mesh_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !graphics_bound {
				return .No_Pipeline, packet
			}
			if p.kind == .Draw_Indexed_Indirect && !index_buffer_set {
				return .No_Index_Buffer, packet
			}
			d := payload(p, Draw_Indirect)
			stride := p.kind == .Draw_Indirect ? size_of(Draw_Indirect_Args) : size_of(Draw_Indexed_Indirect_Args)
			if err = validate_indirect(resources, d.arguments, d.offset, int(d.max_count) * stride); err != .None {
				return err, packet
			}
			if d.count != {} {
				if err = validate_indirect(resources, d.count, d.count_offset, size_of(u32)); err != .None {
					return err, packet
				}
			}
		case .Copy_Buffer:
			if in_pass {
				return .Copy_Inside_Pass, packet
			}
			c := payload(p, Copy_Buffer)
			source, source_ok := resources.buffer(c.source)
			dest, dest_ok := resources.buffer(c.dest)
			if !source_ok || !dest_ok {
				return .Invalid_Buffer, packet
			}
			aligned := c.source_offset % 4 == 0 && c.dest_offset % 4 == 0 && c.size % 4 == 0
			in_range := int(c.source_offset) + int(c.size) <= int(source.size) && int(c.dest_offset) + int(c.size) <= int(dest.size)
			if c.source == c.dest || !aligned || !in_range || .Readback in source.usage {
				return .Bad_Copy, packet
			}
		case .Dispatch_Rays:
			if in_pass {
				return .Dispatch_Inside_Pass, packet
			}
			if compute_bound {
				return .Wrong_Pipeline_Kind, packet
			}
			if !ray_tracing_bound {
				return .No_Pipeline, packet
			}
		case .Build_Accel:
			if in_pass {
				return .Build_Inside_Pass, packet
			}
			if err = validate_build(resources, payload(p, Build_Accel)); err != .None {
				return err, packet
			}
		case .Dispatch_Indirect:
			if in_pass {
				return .Dispatch_Inside_Pass, packet
			}
			if !compute_bound {
				return .No_Pipeline, packet
			}
			d := payload(p, Dispatch_Indirect)
			if err = validate_indirect(resources, d.arguments, d.offset, size_of(Dispatch_Indirect_Args)); err != .None {
				return err, packet
			}
		case .Barriers:
			if in_pass {
				return .Barrier_Inside_Pass, packet
			}
			buffers, textures, accels := barrier_data(p)
			if queue == .Compute && !compute_queue_barriers(buffers, textures, accels) {
				return .Bad_Barrier, packet
			}
			for b in accels {
				if _, ok := resources.accel(b.accel); !ok {
					return .Invalid_Accel, packet
				}
				valid := b.access_before <= ACCEL_ACCESSES && b.access_after <= ACCEL_ACCESSES
				if !valid || !valid_sync(b.sync_before, b.access_before) || !valid_sync(b.sync_after, b.access_after) {
					return .Bad_Barrier, packet
				}
			}
			for b in buffers {
				desc, ok := resources.buffer(b.buffer)
				if !ok {
					return .Invalid_Buffer, packet
				}
				if !valid_buffer_barrier(b, desc) {
					return .Bad_Barrier, packet
				}
			}
			for b in textures {
				desc, ok := resources.texture(b.texture)
				if !ok {
					return .Invalid_Texture, packet
				}
				if !valid_texture_barrier(b, desc) {
					return .Bad_Barrier, packet
				}
				if layouts == nil {
					continue
				}
				// Undefined as the layout before discards the contents, whatever the layout is.
				if current, tracked := layouts.layouts[b.texture]; tracked && b.layout_before != .Undefined && b.layout_before != current {
					return .Layout_Mismatch, packet
				}
				layouts.layouts[b.texture] = b.layout_after
			}
		}
	}

	if in_pass {
		return .Unclosed_Pass, packet
	}
	if marker_depth != 0 {
		return .Unclosed_Marker, packet
	}
	return .None, packet
}

// validate_submission validates each command buffer, and checks that the pieces of split passes form chains:
// a command buffer that ends with a suspended pass is followed by one that resumes it with the same attachments.
// buffer is the index of the offending command buffer.
validate_submission :: proc(
	buffers: []Command_Buffer,
	resources: Resources,
	layouts: ^Layout_Tracker = nil,
	queue := Queue.Graphics,
) -> (
	err: Validation_Error,
	buffer: int,
	packet: int,
) {
	suspended: ^Begin_Pass
	for cb, i in buffers {
		if err, packet = validate(cb, resources, layouts, queue); err != .None {
			return err, i, packet
		}
		resumed, suspends := chain_ends(cb)
		switch {
		case resumed != nil && suspended == nil:
			return .Bad_Resume, i, 0
		case resumed == nil && suspended != nil:
			return .Bad_Suspend, i - 1, 0
		case resumed != nil && !same_attachments(resumed, suspended):
			return .Bad_Resume, i, 0
		}
		suspended = suspends
	}
	if suspended != nil {
		return .Bad_Suspend, len(buffers) - 1, 0
	}
	return .None, len(buffers), 0
}

// A resumed piece loads what the suspended piece stored, so it neither clears nor discards. A suspended piece stores.
@(private = "file")
validate_pass_flags :: proc(pass: ^Begin_Pass, packet: int) -> Validation_Error {
	has_depth := pass.depth.texture != {}
	if .Resuming in pass.flags {
		if packet != 0 {
			return .Bad_Resume
		}
		for color in pass.colors[:pass.color_count] {
			if color.load != .Load {
				return .Bad_Resume
			}
		}
		if has_depth && pass.depth.load != .Load {
			return .Bad_Resume
		}
	}
	if .Suspending in pass.flags {
		for color in pass.colors[:pass.color_count] {
			if color.store != .Store {
				return .Bad_Suspend
			}
		}
		if has_depth && pass.depth.store != .Store {
			return .Bad_Suspend
		}
	}
	return .None
}

// chain_ends returns the command buffer's first pass if it resumes, and its last pass if it suspends.
// validate has already checked that a resuming pass comes first and a suspending pass comes last.
@(private = "file")
chain_ends :: proc(cb: Command_Buffer) -> (resumed: ^Begin_Pass, suspends: ^Begin_Pass) {
	it := packet_iterator(cb)
	for p in next_packet(&it) {
		if p.kind != .Begin_Pass {
			continue
		}
		pass := payload(p, Begin_Pass)
		if .Resuming in pass.flags {
			resumed = pass
		}
		suspends = .Suspending in pass.flags ? pass : nil
	}
	return
}

@(private = "file")
same_attachments :: proc(a, b: ^Begin_Pass) -> bool {
	if a.color_count != b.color_count || a.depth.texture != b.depth.texture {
		return false
	}
	for i in 0 ..< a.color_count {
		if a.colors[i].texture != b.colors[i].texture {
			return false
		}
	}
	return true
}

// validate_attachments returns the pass's attachment formats in the form a matching pipeline has.
@(private = "file")
validate_attachments :: proc(pass: ^Begin_Pass, resources: Resources) -> (formats: Pipeline_Info, err: Validation_Error) {
	has_depth := pass.depth.texture != {}
	if pass.color_count > MAX_COLOR_ATTACHMENTS || (pass.color_count == 0 && !has_depth) {
		return {}, .Bad_Attachment_Count
	}
	formats.kind = .Graphics
	formats.color_count = pass.color_count
	size: Maybe([2]u32)

	for color, i in pass.colors[:pass.color_count] {
		desc, ok := resources.texture(color.texture)
		if !ok {
			return {}, .Invalid_Texture
		}
		if .Render_Target not_in desc.usage {
			return {}, .Bad_Attachment_Usage
		}
		if s, has_size := size.?; has_size && s != desc.size {
			return {}, .Attachment_Size_Mismatch
		}
		size = desc.size
		formats.color_formats[i] = desc.format
	}
	if has_depth {
		desc, ok := resources.texture(pass.depth.texture)
		if !ok {
			return {}, .Invalid_Texture
		}
		if .Depth_Stencil not_in desc.usage || !is_depth_format(desc.format) {
			return {}, .Bad_Attachment_Usage
		}
		if s, has_size := size.?; has_size && s != desc.size {
			return {}, .Attachment_Size_Mismatch
		}
		formats.depth_format = desc.format
	}
	return formats, .None
}

// attachments_in_layout checks that color attachments are in the render target layout and the depth attachment
// is in the depth write layout. The caller holds the tracker's mutex.
@(private = "file")
attachments_in_layout :: proc(pass: ^Begin_Pass, layouts: ^Layout_Tracker) -> bool {
	in_layout :: proc(layouts: ^Layout_Tracker, texture: Texture, layout: Texture_Layout) -> bool {
		current, tracked := layouts.layouts[texture]
		return !tracked || current == layout
	}
	for color in pass.colors[:pass.color_count] {
		if !in_layout(layouts, color.texture, .Render_Target) {
			return false
		}
	}
	return pass.depth.texture == {} || in_layout(layouts, pass.depth.texture, .Depth_Stencil_Write)
}

// A barrier without synchronization on one side has no access on that side.
@(private = "file")
valid_sync :: proc(sync: Syncs, access: Accesses) -> bool {
	return sync != {} || access == {}
}

// same_formats compares the attachment formats of a pipeline with those of a pass.
@(private = "file")
same_formats :: proc(a, b: Pipeline_Info) -> bool {
	return a.color_count == b.color_count && a.color_formats == b.color_formats && a.depth_format == b.depth_format
}

// validate_indirect checks an indirect argument or count buffer: the Indirect usage, a 4-byte aligned offset, and
// size bytes in range.
@(private = "file")
validate_indirect :: proc(resources: Resources, buffer: Buffer, offset: u32, size: int) -> Validation_Error {
	desc, ok := resources.buffer(buffer)
	if !ok {
		return .Invalid_Buffer
	}
	if .Indirect not_in desc.usage {
		return .Bad_Buffer_Usage
	}
	if offset % 4 != 0 || int(offset) + size > int(desc.size) {
		return .Bad_Indirect
	}
	return .None
}

// validate_build checks a build against its acceleration structure. A bottom-level build takes no instances, and a
// top-level build's instance records are 16-byte aligned and in range.
@(private = "file")
validate_build :: proc(resources: Resources, build: ^Build_Accel) -> Validation_Error {
	info, ok := resources.accel(build.accel)
	if !ok {
		return .Invalid_Accel
	}
	if build.update && .Allow_Update not_in info.flags {
		return .Bad_Accel_Build
	}
	switch info.kind {
	case .Bottom:
		if build.instances != {} || build.count != 0 {
			return .Bad_Accel_Build
		}
		if !info.inputs_valid {
			return .Invalid_Buffer
		}
	case .Top:
		desc, has_instances := resources.buffer(build.instances)
		if !has_instances {
			return .Invalid_Buffer
		}
		end := int(build.offset) + int(build.count) * size_of(Accel_Instance)
		if build.offset % 16 != 0 || build.count > info.max_instances || end > int(desc.size) {
			return .Bad_Accel_Build
		}
	}
	return .None
}

@(private = "file")
compute_queue_barriers :: proc(buffers: []Buffer_Barrier, textures: []Texture_Barrier, accels: []Accel_Barrier) -> bool {
	for b in accels {
		if !(b.sync_before + b.sync_after <= COMPUTE_QUEUE_SYNCS) {
			return false
		}
	}
	for b in buffers {
		if !(b.sync_before + b.sync_after <= COMPUTE_QUEUE_SYNCS) || !(b.access_before + b.access_after <= COMPUTE_QUEUE_ACCESSES) {
			return false
		}
	}
	for b in textures {
		if !(b.sync_before + b.sync_after <= COMPUTE_QUEUE_SYNCS) || !(b.access_before + b.access_after <= COMPUTE_QUEUE_ACCESSES) {
			return false
		}
		for layout in ([2]Texture_Layout{b.layout_before, b.layout_after}) {
			if layout != .Undefined && layout != .Shader_Resource && layout != .Unordered_Access {
				return false
			}
		}
	}
	return true
}

@(private = "file")
valid_buffer_barrier :: proc(b: Buffer_Barrier, desc: Buffer_Desc) -> bool {
	allowed := Accesses{.Shader_Resource, .Copy_Source, .Copy_Dest}
	if .Index in desc.usage {
		allowed += {.Index_Buffer}
	}
	if .Storage in desc.usage {
		allowed += {.Unordered_Access}
	}
	if .Indirect in desc.usage {
		allowed += {.Indirect_Argument}
	}
	return b.access_before <= allowed && b.access_after <= allowed && valid_sync(b.sync_before, b.access_before) && valid_sync(b.sync_after, b.access_after)
}

@(private = "file")
valid_texture_barrier :: proc(b: Texture_Barrier, desc: Texture_Desc) -> bool {
	allowed_layout :: proc(layout: Texture_Layout, usage: Texture_Usages) -> bool {
		needed, has_need := layout_usage(layout)
		return !has_need || needed in usage
	}
	if b.layout_after == .Undefined || !allowed_layout(b.layout_before, desc.usage) || !allowed_layout(b.layout_after, desc.usage) {
		return false
	}
	access_ok := b.access_before <= layout_accesses(b.layout_before) && b.access_after <= layout_accesses(b.layout_after)
	return access_ok && valid_sync(b.sync_before, b.access_before) && valid_sync(b.sync_after, b.access_after)
}

Desc_Error :: enum u8 {
	None,
	Bad_Size,
	Bad_Format,
	Bad_Usage,
	Bad_Mip_Count,
	Bad_Data_Size,
	Missing_Shader,
	Bad_Color_Count,
	// A graphics pipeline has a vertex shader or a mesh shader, not both, and an amplification shader needs a mesh shader.
	Bad_Stages,
	// A bottom-level acceleration structure has 1 to MAX_ACCEL_GEOMETRIES whole-triangle geometries, and a top-level
	// one has no geometries and room for at least one instance.
	Bad_Geometry,
}

// Backends check descriptions with these procedures before they create a resource.
validate_buffer_desc :: proc(desc: Buffer_Desc, data: []byte) -> Desc_Error {
	if desc.size == 0 || desc.size % 4 != 0 {
		return .Bad_Size
	}
	if len(data) > int(desc.size) {
		return .Bad_Data_Size
	}
	if .Readback in desc.usage && (desc.usage != {.Readback} || data != nil) {
		return .Bad_Usage
	}
	return .None
}

// data is mip 0 with tightly packed rows.
validate_texture_desc :: proc(desc: Texture_Desc, data: []byte) -> Desc_Error {
	if desc.size.x == 0 || desc.size.y == 0 {
		return .Bad_Size
	}
	if desc.format == .Unknown {
		return .Bad_Format
	}
	depth := is_depth_format(desc.format)
	if desc.usage == {} || (.Depth_Stencil in desc.usage) != depth || (depth && .Render_Target in desc.usage) {
		return .Bad_Usage
	}
	// Storage views cannot be sRGB.
	if .Storage in desc.usage && is_srgb_format(desc.format) {
		return .Bad_Usage
	}
	// The copy queue writes a streamed texture, and copy queues cannot change layouts.
	if .Streamed in desc.usage && (desc.usage != {.Sampled, .Streamed} || data != nil) {
		return .Bad_Usage
	}
	if desc.mip_count > mip_count(desc.size) {
		return .Bad_Mip_Count
	}
	if data != nil && (.Sampled not_in desc.usage || len(data) != int(desc.size.x * desc.size.y) * format_size(desc.format)) {
		return .Bad_Data_Size
	}
	return .None
}

validate_graphics_pipeline_desc :: proc(desc: Graphics_Pipeline_Desc) -> Desc_Error {
	has_vertex, has_mesh := len(desc.vertex) > 0, len(desc.mesh) > 0
	if has_vertex && (has_mesh || len(desc.amplification) > 0) {
		return .Bad_Stages
	}
	if (!has_vertex && !has_mesh) || (len(desc.colors) > 0 && len(desc.pixel) == 0) {
		return .Missing_Shader
	}
	if len(desc.colors) > MAX_COLOR_ATTACHMENTS || (len(desc.colors) == 0 && desc.depth_format == .Unknown) {
		return .Bad_Color_Count
	}
	for color in desc.colors {
		if color.format == .Unknown || is_depth_format(color.format) {
			return .Bad_Format
		}
	}
	if desc.depth_format != .Unknown && !is_depth_format(desc.depth_format) {
		return .Bad_Format
	}
	return .None
}

validate_ray_tracing_pipeline_desc :: proc(desc: Ray_Tracing_Pipeline_Desc) -> Desc_Error {
	if len(desc.library) == 0 || desc.ray_generation == "" {
		return .Missing_Shader
	}
	if desc.max_payload_size == 0 || desc.max_payload_size % 4 != 0 || desc.max_attribute_size % 4 != 0 || desc.max_recursion > 31 {
		return .Bad_Stages
	}
	for group in desc.hit_groups {
		if group.name == "" || (group.closest_hit == "" && group.any_hit == "") {
			return .Missing_Shader
		}
	}
	for name in desc.miss {
		if name == "" {
			return .Missing_Shader
		}
	}
	return .None
}

// validate_stream_buffer checks a buffer stream: the data fits at the offset, and both are multiples of 4.
validate_stream_buffer :: proc(desc: Buffer_Desc, offset: u32, data: []byte) -> Desc_Error {
	if len(data) == 0 || len(data) % 4 != 0 || offset % 4 != 0 || int(offset) + len(data) > int(desc.size) {
		return .Bad_Data_Size
	}
	return .None
}

// validate_stream_texture checks a texture stream: a Streamed texture, not streamed before, and its whole mip chain.
validate_stream_texture :: proc(desc: Texture_Desc, streamed_before: bool, data: []byte) -> Desc_Error {
	if .Streamed not_in desc.usage || streamed_before {
		return .Bad_Usage
	}
	if len(data) != mip_chain_size(desc) {
		return .Bad_Data_Size
	}
	return .None
}

// validate_accel_desc checks the shape of a description. The backend checks that the geometry buffers are valid.
validate_accel_desc :: proc(desc: Accel_Struct_Desc) -> Desc_Error {
	switch desc.kind {
	case .Top:
		if len(desc.geometries) > 0 || desc.max_instances == 0 {
			return .Bad_Geometry
		}
	case .Bottom:
		if len(desc.geometries) == 0 || len(desc.geometries) > MAX_ACCEL_GEOMETRIES {
			return .Bad_Geometry
		}
		for g in desc.geometries {
			min_stride: u32 = g.vertex_format == .RG32_Float ? 8 : 12
			if g.vertex_count == 0 || g.vertex_stride < min_stride || g.vertex_stride % 4 != 0 || g.vertex_offset % 4 != 0 {
				return .Bad_Geometry
			}
			triangles_whole := g.indices == {} ? g.vertex_count % 3 == 0 : g.index_count > 0 && g.index_count % 3 == 0
			if !triangles_whole {
				return .Bad_Geometry
			}
		}
	}
	return .None
}

validate_compute_pipeline_desc :: proc(desc: Compute_Pipeline_Desc) -> Desc_Error {
	return len(desc.compute) == 0 ? .Missing_Shader : .None
}

// mip_count is the length of the full mip chain for a size.
mip_count :: proc(size: [2]u32) -> u32 {
	count: u32 = 1
	for s := max(size.x, size.y); s > 1; s >>= 1 {
		count += 1
	}
	return count
}
