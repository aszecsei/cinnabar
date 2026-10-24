// Package gpu is the backend-agnostic GPU interface: handles, descriptions and command buffers.
// It is pure Odin and is compiled into both the host and the game DLL. See docs/gpu.md.
package gpu

// A handle with generation 0 is the nil handle.
Handle :: struct {
	index:      u32,
	generation: u32,
}

Buffer :: distinct Handle
Texture :: distinct Handle
Sampler :: distinct Handle
Pipeline :: distinct Handle

// Capabilities above the hardware floor. The backend reports them at device creation.
Feature :: enum u8 {
	Mesh_Shaders,
	Ray_Query,
	Ray_Tracing_Pipeline,
}

Features :: bit_set[Feature]

// Pool capacities. The bindless index ranges below depend on them.
MAX_BUFFERS :: 16384
MAX_TEXTURES :: 16384
MAX_SAMPLERS :: 1024
MAX_PIPELINES :: 4096

// The bindless index of a view is a fixed function of the handle's pool index (see docs/gpu.md#binding-model).
// The resource descriptor heap holds these ranges in order: buffer reads, buffer writes, texture reads, texture writes.
BUFFER_READ_BASE :: 0
BUFFER_WRITE_BASE :: BUFFER_READ_BASE + MAX_BUFFERS
TEXTURE_READ_BASE :: BUFFER_WRITE_BASE + MAX_BUFFERS
TEXTURE_WRITE_BASE :: TEXTURE_READ_BASE + MAX_TEXTURES
RESOURCE_DESCRIPTOR_COUNT :: TEXTURE_WRITE_BASE + MAX_TEXTURES

// read_index is the bindless index of a buffer's ByteAddressBuffer view, or a texture's sampled view.
read_index :: proc {
	buffer_read_index,
	texture_read_index,
}

// write_index is the bindless index of a buffer's RWByteAddressBuffer view, or a texture's storage view.
// Only resources with the Storage usage have one.
write_index :: proc {
	buffer_write_index,
	texture_write_index,
}

buffer_read_index :: proc(buffer: Buffer) -> u32 {
	return BUFFER_READ_BASE + buffer.index
}

buffer_write_index :: proc(buffer: Buffer) -> u32 {
	return BUFFER_WRITE_BASE + buffer.index
}

texture_read_index :: proc(texture: Texture) -> u32 {
	return TEXTURE_READ_BASE + texture.index
}

texture_write_index :: proc(texture: Texture) -> u32 {
	return TEXTURE_WRITE_BASE + texture.index
}

// sampler_index is the bindless index in the sampler descriptor heap.
sampler_index :: proc(sampler: Sampler) -> u32 {
	return sampler.index
}

Format :: enum u8 {
	Unknown,
	R8_Unorm,
	RG8_Unorm,
	RGBA8_Unorm,
	RGBA8_Unorm_Srgb,
	BGRA8_Unorm,
	BGRA8_Unorm_Srgb,
	RGB10A2_Unorm,
	RG11B10_Float,
	R16_Float,
	RG16_Float,
	RGBA16_Float,
	R32_Uint,
	R32_Float,
	RG32_Float,
	RGBA32_Float,
	D32_Float,
	D32_Float_S8_Uint,
}

// The frame target is written through an sRGB view.
FRAME_TARGET_FORMAT :: Format.RGBA8_Unorm_Srgb

is_depth_format :: proc(format: Format) -> bool {
	#partial switch format {
	case .D32_Float, .D32_Float_S8_Uint:
		return true
	}
	return false
}

is_srgb_format :: proc(format: Format) -> bool {
	return format == .RGBA8_Unorm_Srgb || format == .BGRA8_Unorm_Srgb
}

// format_size is the size of one texel in bytes.
format_size :: proc(format: Format) -> int {
	switch format {
	case .Unknown:
		return 0
	case .R8_Unorm:
		return 1
	case .RG8_Unorm, .R16_Float:
		return 2
	case .RGBA8_Unorm, .RGBA8_Unorm_Srgb, .BGRA8_Unorm, .BGRA8_Unorm_Srgb, .RGB10A2_Unorm, .RG11B10_Float, .RG16_Float, .R32_Uint, .R32_Float, .D32_Float:
		return 4
	case .RGBA16_Float, .RG32_Float, .D32_Float_S8_Uint:
		return 8
	case .RGBA32_Float:
		return 16
	}
	return 0
}

// Scope is a resource's lifetime group. On a soft restart, core destroys every resource in the Game scope.
// The engine destroys the Level and Asset scopes with gpu_destroy_scope. Permanent resources belong to core.
Scope :: enum u8 {
	Game,
	Level,
	Asset,
	Permanent,
}

Buffer_Usage :: enum u8 {
	Index,
	// The buffer has a write view.
	Storage,
	Indirect,
}

Buffer_Usages :: bit_set[Buffer_Usage;u8]

// Every buffer has a read view. Shaders read buffers as ByteAddressBuffer.
// size must be a multiple of 4.
Buffer_Desc :: struct {
	size:  u32,
	usage: Buffer_Usages,
	scope: Scope,
	label: string,
}

Texture_Usage :: enum u8 {
	// The texture has a read view.
	Sampled,
	// The texture has a write view.
	Storage,
	Render_Target,
	Depth_Stencil,
}

Texture_Usages :: bit_set[Texture_Usage;u8]

// A new texture starts in the layout of its first usage in this order: Render_Target, Depth_Stencil, Storage, Sampled.
// A texture created with data starts in the sampled layout. See initial_layout.
Texture_Desc :: struct {
	size:      [2]u32,
	format:    Format,
	// 0 means 1.
	mip_count: u32,
	usage:     Texture_Usages,
	scope:     Scope,
	label:     string,
}

// initial_layout is the layout a new texture starts in. A texture created with data starts in the sampled layout.
initial_layout :: proc(usage: Texture_Usages, has_data: bool) -> Texture_Layout {
	switch {
	case has_data:
		return .Shader_Resource
	case .Render_Target in usage:
		return .Render_Target
	case .Depth_Stencil in usage:
		return .Depth_Stencil_Write
	case .Storage in usage:
		return .Unordered_Access
	}
	return .Shader_Resource
}

// Barriers follow the Enhanced Barriers model (see docs/gpu.md#barriers). An empty Syncs means no
// synchronization, and an empty Accesses means no access.
Sync :: enum u8 {
	All,
	Index_Input,
	Vertex_Shading,
	Pixel_Shading,
	Depth_Stencil,
	Render_Target,
	Compute_Shading,
}

Syncs :: bit_set[Sync;u16]

Access :: enum u8 {
	Index_Buffer,
	Render_Target,
	// Includes the depth test's reads.
	Depth_Stencil_Write,
	Shader_Resource,
	Unordered_Access,
}

Accesses :: bit_set[Access;u16]

WRITE_ACCESSES :: Accesses{.Render_Target, .Depth_Stencil_Write, .Unordered_Access}

Texture_Layout :: enum u8 {
	// The contents are undefined. As a barrier's layout_before, it discards the contents.
	Undefined,
	Render_Target,
	Depth_Stencil_Write,
	Shader_Resource,
	Unordered_Access,
}

// layout_accesses are the accesses that a texture allows in a layout.
layout_accesses :: proc(layout: Texture_Layout) -> Accesses {
	switch layout {
	case .Undefined:
		return {}
	case .Render_Target:
		return {.Render_Target}
	case .Depth_Stencil_Write:
		return {.Depth_Stencil_Write}
	case .Shader_Resource:
		return {.Shader_Resource}
	case .Unordered_Access:
		return {.Unordered_Access}
	}
	return {}
}

// layout_usage is the usage a texture needs to enter a layout. Every texture can be Undefined.
layout_usage :: proc(layout: Texture_Layout) -> (usage: Texture_Usage, needed: bool) {
	switch layout {
	case .Undefined:
		return {}, false
	case .Render_Target:
		return .Render_Target, true
	case .Depth_Stencil_Write:
		return .Depth_Stencil, true
	case .Shader_Resource:
		return .Sampled, true
	case .Unordered_Access:
		return .Storage, true
	}
	return {}, false
}

Filter :: enum u8 {
	Nearest,
	Linear,
}

Address_Mode :: enum u8 {
	Repeat,
	Mirror,
	Clamp,
}

Sampler_Desc :: struct {
	filter:     Filter,
	mip_filter: Filter,
	address:    Address_Mode,
	// 0 or 1 disables anisotropic filtering. The maximum is 16.
	anisotropy: u8,
	scope:      Scope,
	label:      string,
}

Topology :: enum u8 {
	Triangle_List,
	Triangle_Strip,
	Line_List,
	Point_List,
}

// Front faces are clockwise.
Cull_Mode :: enum u8 {
	None,
	Back,
	Front,
}

Compare_Op :: enum u8 {
	Always,
	Never,
	Less,
	Less_Equal,
	Equal,
	Greater,
	Greater_Equal,
	Not_Equal,
}

Blend :: enum u8 {
	Opaque,
	Alpha,
	Premultiplied,
	Additive,
}

Color_Target :: struct {
	format: Format,
	blend:  Blend,
}

// Shaders are DXIL blobs. Pipelines have no vertex input layout: vertex shaders pull their vertices.
Graphics_Pipeline_Desc :: struct {
	vertex:        []byte,
	pixel:         []byte,
	colors:        []Color_Target,
	depth_format:  Format,
	// Always disables the depth test.
	depth_compare: Compare_Op,
	depth_write:   bool,
	topology:      Topology,
	cull:          Cull_Mode,
	scope:         Scope,
	label:         string,
}

Compute_Pipeline_Desc :: struct {
	compute: []byte,
	scope:   Scope,
	label:   string,
}

Pipeline_Kind :: enum u8 {
	Graphics,
	Compute,
}

// Pipeline_Info is what validation needs to know about a pipeline.
Pipeline_Info :: struct {
	kind:         Pipeline_Kind,
	color_count:  u32,
	color_formats: [MAX_COLOR_ATTACHMENTS]Format,
	depth_format: Format,
}

pipeline_info :: proc(desc: Graphics_Pipeline_Desc) -> Pipeline_Info {
	info := Pipeline_Info {
		kind         = .Graphics,
		color_count  = u32(len(desc.colors)),
		depth_format = desc.depth_format,
	}
	for color, i in desc.colors {
		info.color_formats[i] = color.format
	}
	return info
}

// Upload is memory in the frame's upload ring. It is valid until the end of the frame.
// Shaders read it through read_index(buffer) at offset.
Upload :: struct {
	data:   []byte,
	buffer: Buffer,
	offset: u32,
}

// Pass constants must be aligned to this in the upload ring.
PASS_CONSTANTS_ALIGN :: 256
