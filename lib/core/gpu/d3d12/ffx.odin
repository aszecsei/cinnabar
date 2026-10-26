package gpu_d3d12

// The part of the FidelityFX API that runs FSR (see docs/gpu/upscalers.md#fsr), after the headers of the AMD FSR SDK
// (ffx_api.h, ffx_api_types.h, dx12/ffx_api_dx12.h and ffx_upscale.h), whose license follows. The backend loads the
// API's loader at run time, so a machine without it has no FSR.
//
// Copyright (C) Advanced Micro Devices, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of
// the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// The SDK release whose loader the justfile downloads (fidelityfx_version), and the upscaler API version that its
// headers declare, which a context asks for.
FFX_SDK_VERSION :: "2.3.0"
FFX_UPSCALER_VERSION :: 4 << 22 | 1 << 12 | 1

FFX_LOADER_DLL :: "amd_fidelityfx_loader_dx12.dll"

FFX_RETURN_OK :: 0

// Structure types, which each description's header names.
FFX_QUERY_DESC_TYPE_GET_VERSIONS :: 4
FFX_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12 :: 0x2
FFX_CREATE_CONTEXT_DESC_TYPE_UPSCALE :: 0x10000
FFX_DISPATCH_DESC_TYPE_UPSCALE :: 0x10001
FFX_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION :: 0x1000b

// FfxApiCreateContextUpscaleFlags.
FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE :: 1 << 0
FFX_UPSCALE_ENABLE_DEPTH_INVERTED :: 1 << 3
FFX_UPSCALE_ENABLE_DEPTH_INFINITE :: 1 << 4
FFX_UPSCALE_ENABLE_AUTO_EXPOSURE :: 1 << 5
FFX_UPSCALE_ENABLE_DEBUG_CHECKING :: 1 << 7

// FfxApiMsgType.
FFX_MESSAGE_TYPE_ERROR :: 0

// FfxApiResourceState: what the dispatch finds a resource in, and leaves it in.
FFX_RESOURCE_STATE_UNORDERED_ACCESS :: 1 << 1
FFX_RESOURCE_STATE_COMPUTE_READ :: 1 << 2
FFX_RESOURCE_STATE_PIXEL_READ :: 1 << 3

// FfxApiResourceUsage.
FFX_RESOURCE_USAGE_READ_ONLY :: 0
FFX_RESOURCE_USAGE_UAV :: 1 << 1
FFX_RESOURCE_USAGE_DEPTHTARGET :: 1 << 2

FFX_RESOURCE_TYPE_TEXTURE2D :: 2

// FfxApiSurfaceFormat, the values that gpu.Format has.
Ffx_Surface_Format :: enum u32 {
	Unknown            = 0,
	R32G32B32A32_Float = 3,
	R16G16B16A16_Float = 4,
	R32G32_Float       = 6,
	R8G8B8A8_Unorm     = 10,
	R8G8B8A8_Srgb      = 12,
	B8G8R8A8_Unorm     = 14,
	B8G8R8A8_Srgb      = 15,
	R11G11B10_Float    = 16,
	R10G10B10A2_Unorm  = 17,
	R16G16_Float       = 18,
	R16_Float          = 21,
	R8_Unorm           = 25,
	R8G8_Unorm         = 26,
	R32_Float          = 28,
	R32_Uint           = 8,
}

Ffx_Context :: rawptr

Ffx_Header :: struct {
	type: u64,
	next: ^Ffx_Header,
}

Ffx_Dimensions :: [2]u32

Ffx_Resource_Description :: struct {
	type:      u32,
	format:    Ffx_Surface_Format,
	width:     u32,
	height:    u32,
	depth:     u32,
	mip_count: u32,
	flags:     u32,
	usage:     u32,
}

Ffx_Resource :: struct {
	resource:    rawptr,
	description: Ffx_Resource_Description,
	state:       u32,
}

Ffx_Message_Proc :: #type proc "c" (type: u32, message: [^]u16)

Ffx_Create_Backend_Dx12_Desc :: struct {
	header: Ffx_Header,
	device: rawptr,
}

Ffx_Create_Context_Desc_Upscale :: struct {
	header:           Ffx_Header,
	flags:            u32,
	max_render_size:  Ffx_Dimensions,
	max_upscale_size: Ffx_Dimensions,
	message:          Ffx_Message_Proc,
}

Ffx_Create_Context_Desc_Upscale_Version :: struct {
	header:  Ffx_Header,
	version: u32,
}

Ffx_Query_Desc_Get_Versions :: struct {
	header:           Ffx_Header,
	create_desc_type: u64,
	device:           rawptr,
	// In: the capacity of ids and names. Out: how many versions there are.
	output_count:     ^u64,
	ids:              [^]u64,
	names:            [^]cstring,
}

Ffx_Dispatch_Desc_Upscale :: struct {
	header:                       Ffx_Header,
	command_list:                 rawptr,
	color:                        Ffx_Resource,
	depth:                        Ffx_Resource,
	motion_vectors:               Ffx_Resource,
	exposure:                     Ffx_Resource,
	reactive:                     Ffx_Resource,
	transparency_and_composition: Ffx_Resource,
	output:                       Ffx_Resource,
	jitter_offset:                [2]f32,
	motion_vector_scale:          [2]f32,
	render_size:                  Ffx_Dimensions,
	upscale_size:                 Ffx_Dimensions,
	enable_sharpening:            bool,
	sharpness:                    f32,
	// In milliseconds.
	frame_time_delta:             f32,
	pre_exposure:                 f32,
	reset:                        bool,
	camera_near:                  f32,
	camera_far:                   f32,
	camera_fov_angle_vertical:    f32,
	view_space_to_meters_factor:  f32,
	flags:                        u32,
}

#assert(size_of(Ffx_Resource) == 48 && size_of(Ffx_Create_Context_Desc_Upscale) == 48)
#assert(offset_of(Ffx_Dispatch_Desc_Upscale, jitter_offset) == 360 && size_of(Ffx_Dispatch_Desc_Upscale) == 432)

Ffx_Create_Context :: #type proc "c" (ctx: ^Ffx_Context, desc: ^Ffx_Header, allocation_callbacks: rawptr) -> u32
Ffx_Destroy_Context :: #type proc "c" (ctx: ^Ffx_Context, allocation_callbacks: rawptr) -> u32
Ffx_Query :: #type proc "c" (ctx: ^Ffx_Context, desc: ^Ffx_Header) -> u32
Ffx_Dispatch :: #type proc "c" (ctx: ^Ffx_Context, desc: ^Ffx_Header) -> u32

// Ffx_Api is the loader's entry points, all nil when it is missing.
Ffx_Api :: struct {
	module:         rawptr,
	create_context:  Ffx_Create_Context,
	destroy_context: Ffx_Destroy_Context,
	query:           Ffx_Query,
	dispatch:        Ffx_Dispatch,
}
