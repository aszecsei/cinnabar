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
}

// Resources lets validation look up handles. Each procedure returns false for an invalid handle.
Resources :: struct {
	texture:  proc(texture: Texture) -> (Texture_Desc, bool),
	buffer:   proc(buffer: Buffer) -> (Buffer_Desc, bool),
	pipeline: proc(pipeline: Pipeline) -> (Pipeline_Info, bool),
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
validate :: proc(cb: Command_Buffer, resources: Resources, layouts: ^Layout_Tracker = nil) -> (err: Validation_Error, packet: int) {
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
	compute_bound := false
	index_buffer_set := false

	it := packet_iterator(cb)
	for p in next_packet(&it) {
		defer packet += 1
		if suspended_at >= 0 {
			return .Bad_Suspend, packet
		}
		switch p.kind {
		case .Begin_Pass:
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
			graphics_bound, compute_bound = false, false
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
			graphics_bound, compute_bound = false, false
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
			if (info.kind == .Graphics) != in_pass {
				return .Wrong_Pipeline_Kind, packet
			}
			if info.kind == .Graphics && info != pass_formats {
				return .Pipeline_Pass_Mismatch, packet
			}
			graphics_bound, compute_bound = info.kind == .Graphics, info.kind == .Compute
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
			if !compute_bound {
				return .No_Pipeline, packet
			}
		case .Barriers:
			if in_pass {
				return .Barrier_Inside_Pass, packet
			}
			buffers, textures := barrier_data(p)
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
) -> (
	err: Validation_Error,
	buffer: int,
	packet: int,
) {
	suspended: ^Begin_Pass
	for cb, i in buffers {
		if err, packet = validate(cb, resources, layouts); err != .None {
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

@(private = "file")
valid_buffer_barrier :: proc(b: Buffer_Barrier, desc: Buffer_Desc) -> bool {
	allowed := Accesses{.Shader_Resource}
	if .Index in desc.usage {
		allowed += {.Index_Buffer}
	}
	if .Storage in desc.usage {
		allowed += {.Unordered_Access}
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
}

// Backends check descriptions with these procedures before they create a resource.
validate_buffer_desc :: proc(desc: Buffer_Desc, data: []byte) -> Desc_Error {
	if desc.size == 0 || desc.size % 4 != 0 {
		return .Bad_Size
	}
	if len(data) > int(desc.size) {
		return .Bad_Data_Size
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
	if desc.mip_count > mip_count(desc.size) {
		return .Bad_Mip_Count
	}
	if data != nil && (.Sampled not_in desc.usage || len(data) != int(desc.size.x * desc.size.y) * format_size(desc.format)) {
		return .Bad_Data_Size
	}
	return .None
}

validate_graphics_pipeline_desc :: proc(desc: Graphics_Pipeline_Desc) -> Desc_Error {
	if len(desc.vertex) == 0 || (len(desc.colors) > 0 && len(desc.pixel) == 0) {
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
