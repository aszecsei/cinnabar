// Package gpu is the backend-agnostic GPU interface: handles, descriptions and command buffers.
// It is pure Odin and is compiled into both the host and the game DLL. See docs/gpu/README.md.
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
// An acceleration structure for ray tracing (see docs/gpu/ray-tracing.md#ray-tracing).
Accel_Struct :: distinct Handle
// A vendor's temporal upscaler (see docs/gpu/upscalers.md#upscalers).
Upscaler :: distinct Handle

// Capabilities above the hardware floor. The backend reports them at device creation.
Feature :: enum u8 {
	Mesh_Shaders,
	Ray_Query,
	Ray_Tracing_Pipeline,
}

Features :: bit_set[Feature]

Vendor :: enum u8 {
	Unknown,
	Amd,
	Intel,
	Nvidia,
	Qualcomm,
	Microsoft,
}

// vendor_from_id is the vendor of a PCI vendor ID.
vendor_from_id :: proc(id: u32) -> Vendor {
	switch id {
	case 0x1002, 0x1022:
		return .Amd
	case 0x8086:
		return .Intel
	case 0x10de:
		return .Nvidia
	case 0x5143, 0x4d4f4351:
		return .Qualcomm
	case 0x1414:
		return .Microsoft
	}
	return .Unknown
}

// Adapter is the device that the backend chose, for choosing the defaults of what the game draws (see
// docs/gpu/interface.md#adapter).
Adapter :: struct {
	vendor:       Vendor,
	device_id:    u32,
	// The adapter's own memory in bytes, 0 when unknown or shared with the CPU.
	video_memory: u64,
	// UTF-8, with zeros after it (see adapter_name).
	name:         [128]u8,
}

// adapter_name is an adapter's name, in its memory.
adapter_name :: proc(a: ^Adapter) -> string {
	n := 0
	for n < len(a.name) && a.name[n] != 0 {
		n += 1
	}
	return string(a.name[:n])
}

// Pool capacities. The bindless index ranges below depend on them.
MAX_BUFFERS :: 16384
MAX_TEXTURES :: 16384
MAX_SAMPLERS :: 1024
MAX_PIPELINES :: 4096
MAX_ACCEL_STRUCTS :: 4096
MAX_UPSCALERS :: 16
// The geometries of one bottom-level acceleration structure.
MAX_ACCEL_GEOMETRIES :: 16

// The bindless index of a view is a fixed function of the handle's pool index (see docs/gpu/interface.md#binding-model).
// The resource descriptor heap holds these ranges in order: buffer reads, buffer writes, texture reads, texture writes,
// acceleration structures.
BUFFER_READ_BASE :: 0
BUFFER_WRITE_BASE :: BUFFER_READ_BASE + MAX_BUFFERS
TEXTURE_READ_BASE :: BUFFER_WRITE_BASE + MAX_BUFFERS
TEXTURE_WRITE_BASE :: TEXTURE_READ_BASE + MAX_TEXTURES
ACCEL_READ_BASE :: TEXTURE_WRITE_BASE + MAX_TEXTURES
RESOURCE_DESCRIPTOR_COUNT :: ACCEL_READ_BASE + MAX_ACCEL_STRUCTS

// read_index is the bindless index of a buffer's ByteAddressBuffer view, a texture's sampled view, or an
// acceleration structure's RaytracingAccelerationStructure view.
read_index :: proc {
	buffer_read_index,
	texture_read_index,
	accel_read_index,
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

// stencil_index is the view of a sampled D32_Float_S8_Uint texture's stencil plane, a Texture2D<uint2> whose g is the
// stencil (cn_stencil_texture in HLSL). A depth texture has no write view, so its write slot holds this one.
stencil_index :: proc(texture: Texture) -> u32 {
	return TEXTURE_WRITE_BASE + texture.index
}

// Shaders trace only against top-level structures, but every acceleration structure has a view.
accel_read_index :: proc(accel: Accel_Struct) -> u32 {
	return ACCEL_READ_BASE + accel.index
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
	// Block-compressed formats store 4x4 blocks of texels (see docs/content/kinds/textures.md#textures). They are only
	// sampled, and mip 0 of a texture in one has sides that are multiples of 4.
	BC1_Unorm,
	BC1_Unorm_Srgb,
	BC4_Unorm,
	BC5_Unorm,
	BC6H_Ufloat,
	BC7_Unorm,
	BC7_Unorm_Srgb,
}

// The frame target is written through an sRGB view in the Sdr output mode, as the preview targets always are.
FRAME_TARGET_FORMAT :: Format.RGBA8_Unorm_Srgb

// Output_Mode is how the frame target's colors reach the display (see docs/gpu/presentation.md#presentation).
Output_Mode :: enum u8 {
	// sRGB, in FRAME_TARGET_FORMAT.
	Sdr,
	// HDR10: RGB10A2_Unorm, Rec. 2020 primaries encoded with the PQ curve of SMPTE ST 2084, where 1 is 10000 nits.
	Hdr10,
	// scRGB: RGBA16_Float, linear with Rec. 709 primaries, where 1 is 80 nits.
	Scrgb,
}

// Output_Request is the output mode that a game asks for. Auto is Hdr10 while the display is in HDR mode, and Sdr
// otherwise.
Output_Request :: enum u8 {
	Auto,
	Sdr,
	Hdr10,
	Scrgb,
}

// Display is what the backend knows of the display that shows most of the window. Luminances are in nits, 0 when
// unknown.
Display :: struct {
	// The desktop is in HDR on this display.
	hdr:                      bool,
	min_luminance:            f32,
	max_luminance:            f32,
	max_full_frame_luminance: f32,
	// The brightness that Windows gives SDR content on the display in HDR, which its settings set.
	sdr_white:                f32,
}

// Output is a frame's output: its mode, the frame target's format, which follows from the mode, and the display.
Output :: struct {
	mode:    Output_Mode,
	format:  Format,
	display: Display,
}

// output_format is the frame target's format in an output mode.
output_format :: proc(mode: Output_Mode) -> Format {
	switch mode {
	case .Hdr10:
		return .RGB10A2_Unorm
	case .Scrgb:
		return .RGBA16_Float
	case .Sdr:
	}
	return FRAME_TARGET_FORMAT
}

// output_mode is the mode that a request gives on a display.
output_mode :: proc(request: Output_Request, display: Display) -> Output_Mode {
	switch request {
	case .Sdr:
		return .Sdr
	case .Hdr10:
		return .Hdr10
	case .Scrgb:
		return .Scrgb
	case .Auto:
	}
	return display.hdr ? .Hdr10 : .Sdr
}

// The editor's previews render into shared targets of their own beside the frame target, at most this many, each at
// most this large on a side (see docs/rendering/materials.md#material-previews).
MAX_PREVIEW_TARGETS :: 4
MAX_PREVIEW_SIZE :: 1024

// Preview_Target is a frame of a preview target: its texture, in the render target layout until the frame ends, in
// FRAME_TARGET_FORMAT, its shared objects' name prefix, in temporary memory, its generation and its size.
Preview_Target :: struct {
	texture:    Texture,
	prefix:     string,
	generation: u32,
	size:       [2]u32,
}

// Frame_Capture is a copy of a frame's final frame target in CPU memory, as the backend's readback gives it (see
// docs/gpu/presentation.md#frame-capture). The pixels are the backend's, row_pitch bytes per row, and stay valid until
// release_frame_capture. The format is the frame target's: RGBA8 sRGB bytes in Sdr, RGB10A2 PQ in Hdr10 and RGBA16F in
// Scrgb, with the display's SDR white in nits for the HDR modes, or 0 when unknown.
Frame_Capture :: struct {
	// The backend's slot, which release_frame_capture frees.
	slot:      u32,
	size:      [2]u32,
	format:    Format,
	mode:      Output_Mode,
	sdr_white: f32,
	row_pitch: u32,
	pixels:    []byte,
}

is_depth_format :: proc(format: Format) -> bool {
	#partial switch format {
	case .D32_Float, .D32_Float_S8_Uint:
		return true
	}
	return false
}

has_stencil :: proc(format: Format) -> bool {
	return format == .D32_Float_S8_Uint
}

is_srgb_format :: proc(format: Format) -> bool {
	#partial switch format {
	case .RGBA8_Unorm_Srgb, .BGRA8_Unorm_Srgb, .BC1_Unorm_Srgb, .BC7_Unorm_Srgb:
		return true
	}
	return false
}

// is_block_format is true for the block-compressed formats, which store 4x4 blocks of texels.
is_block_format :: proc(format: Format) -> bool {
	#partial switch format {
	case .BC1_Unorm, .BC1_Unorm_Srgb, .BC4_Unorm, .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm, .BC7_Unorm_Srgb:
		return true
	}
	return false
}

// surface_size is the size of a width x height surface of the format, tightly packed: rows of texels, or rows of 4x4
// blocks, where a partial block takes a whole one.
surface_size :: proc(format: Format, width, height: u32) -> int {
	if is_block_format(format) {
		return int((width + 3) / 4) * int((height + 3) / 4) * format_size(format)
	}
	return int(width) * int(height) * format_size(format)
}

// format_size is the size of one texel in bytes, or of one 4x4 block for a block-compressed format.
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
	case .RGBA16_Float, .RG32_Float, .D32_Float_S8_Uint, .BC1_Unorm, .BC1_Unorm_Srgb, .BC4_Unorm:
		return 8
	case .RGBA32_Float, .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm, .BC7_Unorm_Srgb:
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
	// The CPU reads the buffer with gpu_read_buffer, and the GPU only copies into it with cmd_copy_buffer. It has no
	// views and no other usage, and no initial data (see docs/gpu/queues-streaming-readback.md#readback).
	Readback,
}

Buffer_Usages :: bit_set[Buffer_Usage;u8]

// Every buffer but a Readback buffer has a read view. Shaders read buffers as ByteAddressBuffer.
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
	// The contents arrive with gpu_stream_texture on the copy queue. The texture is sampled once the transfer is done.
	// It needs Sampled and no other usage.
	Streamed,
}

Texture_Usages :: bit_set[Texture_Usage;u8]

// A new texture starts in the layout of its first usage in this order: Render_Target, Depth_Stencil, Storage, Sampled.
// A texture created with data starts in the sampled layout. See initial_layout.
Texture_Desc :: struct {
	size:      [2]u32,
	// A 3D texture's depth in texels. 0 means a 2D texture. A 3D texture has one mip and no data, and is only sampled
	// and written in shaders.
	depth:     u32,
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

// Barriers follow the Enhanced Barriers model (see docs/gpu/command-buffers.md#barriers). An empty Syncs means no
// synchronization, and an empty Accesses means no access.
Sync :: enum u8 {
	All,
	Index_Input,
	Vertex_Shading,
	Pixel_Shading,
	Depth_Stencil,
	Render_Target,
	Compute_Shading,
	// Reading indirect arguments and counts.
	Execute_Indirect,
	// Acceleration structure builds, with their inputs and scratch memory.
	Build_Accel,
	// The shaders of a ray tracing pipeline.
	Ray_Tracing,
	Copy,
}

Syncs :: bit_set[Sync;u16]

Access :: enum u8 {
	Index_Buffer,
	Render_Target,
	// Includes the depth test's reads.
	Depth_Stencil_Write,
	Shader_Resource,
	Unordered_Access,
	Indirect_Argument,
	Accel_Read,
	Accel_Write,
	Copy_Source,
	Copy_Dest,
}

Accesses :: bit_set[Access;u16]

WRITE_ACCESSES :: Accesses{.Render_Target, .Depth_Stencil_Write, .Unordered_Access, .Accel_Write, .Copy_Dest}

// A compute queue runs no graphics work, so its barriers use only these.
COMPUTE_QUEUE_SYNCS :: Syncs{.All, .Compute_Shading, .Execute_Indirect, .Build_Accel, .Ray_Tracing, .Copy}
COMPUTE_QUEUE_ACCESSES :: Accesses{.Shader_Resource, .Unordered_Access, .Indirect_Argument, .Accel_Read, .Accel_Write, .Copy_Source, .Copy_Dest}
// The accesses an acceleration structure can have.
ACCEL_ACCESSES :: Accesses{.Accel_Read, .Accel_Write}

// Queue is where a submission runs. Compute runs alongside graphics (async compute). Cross-queue dependencies
// are declared at submission (see docs/gpu/queues-streaming-readback.md#queues).
Queue :: enum u8 {
	Graphics,
	Compute,
}

Queues :: bit_set[Queue;u8]

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
	// Anything but Always makes a comparison sampler: SampleCmp compares its reference value with each texel by this,
	// and filters the results, as shadow maps need. Shaders get it with cn_comparison_sampler.
	compare:    Compare_Op,
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

Stencil_Op :: enum u8 {
	Keep,
	Zero,
	// Writes the reference value, from cmd_set_stencil_reference.
	Replace,
	Increment_Clamp,
	Decrement_Clamp,
	Invert,
}

// Stencil_State is the stencil test and its writes, the same for front and back faces. The test compares the
// reference value with the stencil, both masked by read_mask, by compare: it passes when reference compare stencil.
// The zero state does nothing: Always, and no writes. A pipeline with a stencil test or writes needs a depth format
// with a stencil.
Stencil_State :: struct {
	compare:    Compare_Op,
	pass:       Stencil_Op,
	fail:       Stencil_Op,
	depth_fail: Stencil_Op,
	read_mask:  u8,
	write_mask: u8,
}

// stencil_used is whether a stencil state tests or writes.
stencil_used :: proc(s: Stencil_State) -> bool {
	return s.compare != .Always || s.write_mask != 0
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
// A graphics pipeline has a vertex shader, or a mesh shader with an optional amplification shader. Mesh pipelines
// need Features.Mesh_Shaders. The mesh shader declares its topology, so topology applies only to vertex pipelines.
Graphics_Pipeline_Desc :: struct {
	vertex:        []byte,
	amplification: []byte,
	mesh:          []byte,
	pixel:         []byte,
	colors:        []Color_Target,
	depth_format:  Format,
	// Always disables the depth test.
	depth_compare: Compare_Op,
	depth_write:   bool,
	// Added to each fragment's depth: a constant in units of the depth format's precision near the fragment, and a
	// factor of the triangle's slope. Shadow maps use them against acne. With reversed depth, a negative bias moves
	// a fragment away from the camera.
	depth_bias:    i32,
	slope_bias:    f32,
	// Clamps depth to the viewport's range instead of clipping, so geometry in front of the near plane still writes
	// depth there, as directional shadow maps need.
	depth_clamp:   bool,
	stencil:       Stencil_State,
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

// Graphics is a vertex pipeline, and Mesh a mesh pipeline. Both run in render passes. Compute and Ray_Tracing
// pipelines run outside them.
Pipeline_Kind :: enum u8 {
	Graphics,
	Mesh,
	Compute,
	Ray_Tracing,
}

// Hit_Group names its closest hit and any hit shaders in the library. Either can be empty, but not both.
Hit_Group :: struct {
	name:        string,
	closest_hit: string,
	any_hit:     string,
}

// Ray_Tracing_Pipeline_Desc names exports of a DXIL library. The backend builds the shader table: the ray generation
// shader, the miss shaders in order (TraceRay's miss index), and the hit groups in order (an instance's hit_group_offset
// plus TraceRay's offset). Records have no local data: shaders get their resources bindless. Ray tracing pipelines
// need Features.Ray_Tracing_Pipeline. 0 sizes and recursion take the defaults.
Ray_Tracing_Pipeline_Desc :: struct {
	library:            []byte,
	ray_generation:     string,
	miss:               []string,
	hit_groups:         []Hit_Group,
	max_payload_size:   u32,
	// The default is 8: the barycentrics of a triangle hit.
	max_attribute_size: u32,
	// The default is 1: TraceRay only from the ray generation shader.
	max_recursion:      u32,
	scope:              Scope,
	label:              string,
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
		kind         = len(desc.mesh) > 0 ? .Mesh : .Graphics,
		color_count  = u32(len(desc.colors)),
		depth_format = desc.depth_format,
	}
	for color, i in desc.colors {
		info.color_formats[i] = color.format
	}
	return info
}

Accel_Kind :: enum u8 {
	// Geometry: triangles in vertex and index buffers.
	Bottom,
	// Instances of bottom-level structures. Shaders trace against these.
	Top,
}

Accel_Flag :: enum u8 {
	// The structure can be updated (refit) instead of rebuilt.
	Allow_Update,
	// Faster builds and slower traces. The default prefers fast traces.
	Prefer_Fast_Build,
}

Accel_Flags :: bit_set[Accel_Flag;u8]

Accel_Vertex_Format :: enum u8 {
	// Two floats: the third coordinate is 0.
	RG32_Float,
	RGB32_Float,
}

// Accel_Geometry is triangles for a bottom-level structure. A nil index buffer means a triangle list of vertices.
// The structure keeps these handles: its builds read the buffers.
Accel_Geometry :: struct {
	vertices:      Buffer,
	vertex_offset: u32,
	vertex_stride: u32,
	vertex_count:  u32,
	vertex_format: Accel_Vertex_Format,
	indices:       Buffer,
	index_offset:  u32,
	index_count:   u32,
	index_format:  Index_Format,
	opaque:        bool,
}

// A bottom-level structure has geometries. A top-level structure has room for max_instances instances.
// The backend sizes the structure and its build scratch memory at creation.
Accel_Struct_Desc :: struct {
	kind:          Accel_Kind,
	flags:         Accel_Flags,
	geometries:    []Accel_Geometry,
	max_instances: u32,
	scope:         Scope,
	label:         string,
}

// Accel_Info is what validation needs to know about an acceleration structure. inputs_valid is false when a
// geometry buffer of a bottom-level structure was destroyed.
Accel_Info :: struct {
	kind:          Accel_Kind,
	flags:         Accel_Flags,
	max_instances: u32,
	inputs_valid:  bool,
}

accel_info :: proc(desc: Accel_Struct_Desc) -> Accel_Info {
	return {kind = desc.kind, flags = desc.flags, max_instances = desc.max_instances, inputs_valid = true}
}

Accel_Instance_Flag :: enum u8 {
	Cull_Disable,
	Front_Counterclockwise,
	Force_Opaque,
	Force_Non_Opaque,
}

Accel_Instance_Flags :: bit_set[Accel_Instance_Flag;u8]

// Accel_Instance is a top-level structure's instance record, in the layout that D3D12 and Vulkan share. transform is
// row-major 3x4, object to world. id is 24 bits and reaches shaders as InstanceID(). hit_group_offset is 24 bits and
// offsets the hit group index in ray tracing pipelines. accel is gpu_accel_reference of a bottom-level structure.
// Records are 16-byte aligned. A Metal backend converts them at build time.
Accel_Instance :: struct {
	transform:              [3][4]f32,
	id_and_mask:            u32,
	hit_group_offset_flags: u32,
	accel:                  u64,
}

#assert(size_of(Accel_Instance) == 64)

accel_instance :: proc(
	transform: [3][4]f32,
	accel_reference: u64,
	id: u32 = 0,
	mask: u8 = 0xff,
	hit_group_offset: u32 = 0,
	flags: Accel_Instance_Flags = {},
) -> Accel_Instance {
	return {
		transform = transform,
		id_and_mask = (id & 0xffffff) | u32(mask) << 24,
		hit_group_offset_flags = (hit_group_offset & 0xffffff) | u32(transmute(u8)flags) << 24,
		accel = accel_reference,
	}
}

// Upscaler_Kind is a vendor's temporal upscaler, which a backend runs through the vendor's library when it finds it
// (see docs/gpu/upscalers.md#upscalers).
Upscaler_Kind :: enum u8 {
	// AMD FidelityFX Super Resolution, through the FidelityFX API: FSR 4 on the GPUs that have it, and FSR 3.1 on the
	// others.
	Fsr,
}

Upscaler_Kinds :: bit_set[Upscaler_Kind;u8]

Upscaler_Flag :: enum u8 {
	// The color is linear HDR. Without it, it is linear and at most 1.
	Hdr,
	// Depth is reversed: 1 at the near plane, and 0 at the far one.
	Depth_Reversed,
	// The projection has no far plane.
	Depth_Infinite,
}

Upscaler_Flags :: bit_set[Upscaler_Flag;u8]

// Upscaler_Desc is an upscaler into one output size, from renders at most max_render_size. The upscaler keeps its own
// history and finds the exposure from the color.
Upscaler_Desc :: struct {
	kind:            Upscaler_Kind,
	flags:           Upscaler_Flags,
	max_render_size: [2]u32,
	output_size:     [2]u32,
	scope:           Scope,
	label:           string,
}

// Stats is what a backend holds, for the editor's resource monitor (see docs/editor/shell-and-panels.md#resource-monitor). The live
// counts include the backend's own permanent resources.
Stats :: struct {
	buffers:             u32,
	textures:            u32,
	samplers:            u32,
	pipelines:           u32,
	accels:              u32,
	// The most that a frame's upload ring used since the last call.
	upload_bytes_max:    u64,
	// The adapter's local memory that the process uses, and the budget that the OS gives it, or 0 when unknown.
	video_memory_used:   u64,
	video_memory_budget: u64,
}

// Transfer identifies a streaming copy (see docs/gpu/queues-streaming-readback.md#streaming). gpu_transfer_done reports when the resource can
// be used. The zero Transfer is always done.
Transfer :: distinct u64

// mip_chain_size is the size of a texture's mips, each tightly packed, mip 0 first: the data of gpu_stream_texture.
mip_chain_size :: proc(desc: Texture_Desc) -> int {
	size := 0
	for mip in 0 ..< max(desc.mip_count, 1) {
		size += surface_size(desc.format, max(desc.size.x >> mip, 1), max(desc.size.y >> mip, 1))
	}
	return size
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

// Indirect argument records. A draw record starts with a draw ID, which shaders read as CN_DRAW_ID. Portable code
// stores the record's index there, counting from the record at the command's offset: the Vulkan backend delivers
// that index, not the stored value. See docs/gpu/gpu-driven-and-mesh-shaders.md#gpu-driven-rendering.
Draw_Indirect_Args :: struct {
	draw_id:        u32,
	vertex_count:   u32,
	instance_count: u32,
	first_vertex:   u32,
	first_instance: u32,
}

Draw_Indexed_Indirect_Args :: struct {
	draw_id:        u32,
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

Dispatch_Indirect_Args :: struct {
	groups: [3]u32,
}

// groups is the mesh or amplification shader group count.
Draw_Mesh_Indirect_Args :: struct {
	draw_id: u32,
	groups:  [3]u32,
}
