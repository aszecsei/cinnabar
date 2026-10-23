package gpu

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
}

// Resources lets validation look up handles. Each procedure returns false for an invalid handle.
Resources :: struct {
	texture:  proc(texture: Texture) -> (Texture_Desc, bool),
	buffer:   proc(buffer: Buffer) -> (Buffer_Desc, bool),
	pipeline: proc(pipeline: Pipeline) -> (Pipeline_Info, bool),
}

// validate checks the rules that every backend enforces (see docs/gpu.md#pass-rules).
// packet is the index of the offending packet, or the packet count for errors found at the end.
validate :: proc(cb: Command_Buffer, resources: Resources) -> (err: Validation_Error, packet: int) {
	in_pass := false
	// The attachment formats of the current pass, as a pipeline would declare them.
	pass_formats: Pipeline_Info
	marker_depth := 0
	pass_marker_depth := 0
	// Bindings reset at every pass boundary.
	graphics_bound := false
	compute_bound := false
	index_buffer_set := false

	it := packet_iterator(cb)
	for p in next_packet(&it) {
		defer packet += 1
		switch p.kind {
		case .Begin_Pass:
			if in_pass {
				return .Nested_Pass, packet
			}
			pass := payload(p, Begin_Pass)
			pass_formats, err = validate_attachments(pass, resources)
			if err != .None {
				return err, packet
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
