package gpu_d3d12

import "base:runtime"
import "core:hash"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

import "cinnabar:core/gpu"

// The upscalers (see docs/gpu/upscalers.md#upscalers): FSR through the FidelityFX API, whose loader init_upscalers
// looks for next to the executable. An upscaler is a FidelityFX context, which records its own compute passes into
// the command list at Upscale.

@(private)
Upscaler_Entry :: struct {
	desc:        gpu.Upscaler_Desc,
	ffx_context: Ffx_Context,
}

@(private)
Upscalers :: struct {
	upscaler_pool:  gpu.Pool(gpu.Upscaler, Upscaler_Entry),
	ffx:            Ffx_Api,
	// The upscalers that this device can run.
	upscaler_kinds: gpu.Upscaler_Kinds,
	// The FidelityFX API repeats a warning for every dispatch that it applies to, so each is logged once: these are
	// the hashes of the messages logged, the oldest replaced first.
	ffx_logged:     [32]u64,
	ffx_next:       int,
	ffx_mutex:      sync.Mutex,
}

// init_upscalers loads the FidelityFX API's loader, and asks it which versions of FSR the device can run. Without
// the loader, or a version, there is no FSR.
@(private)
init_upscalers :: proc() {
	gpu.pool_init(&dev.upscaler_pool, gpu.MAX_UPSCALERS, dev.allocator)
	module := win.LoadLibraryExW(win.L(FFX_LOADER_DLL), nil, {.LOAD_LIBRARY_SEARCH_DEFAULT_DIRS})
	if module == nil {
		log.infof("d3d12: no FSR: %s is missing", FFX_LOADER_DLL)
		return
	}
	api := Ffx_Api {
		module          = module,
		create_context  = Ffx_Create_Context(win.GetProcAddress(module, "ffxCreateContext")),
		destroy_context = Ffx_Destroy_Context(win.GetProcAddress(module, "ffxDestroyContext")),
		query           = Ffx_Query(win.GetProcAddress(module, "ffxQuery")),
		dispatch        = Ffx_Dispatch(win.GetProcAddress(module, "ffxDispatch")),
	}
	if api.create_context == nil || api.destroy_context == nil || api.query == nil || api.dispatch == nil {
		log.errorf("d3d12: no FSR: %s lacks the FidelityFX API", FFX_LOADER_DLL)
		win.FreeLibrary(module)
		return
	}
	dev.ffx = api

	MAX_VERSIONS :: 8
	ids: [MAX_VERSIONS]u64
	names: [MAX_VERSIONS]cstring
	count := u64(MAX_VERSIONS)
	versions := Ffx_Query_Desc_Get_Versions {
		header = {type = FFX_QUERY_DESC_TYPE_GET_VERSIONS},
		create_desc_type = FFX_CREATE_CONTEXT_DESC_TYPE_UPSCALE,
		device = dev.device,
		output_count = &count,
		ids = &ids[0],
		names = &names[0],
	}
	if dev.ffx.query(nil, &versions.header) != FFX_RETURN_OK || count == 0 {
		log.info("d3d12: no FSR: the device runs no version of it")
		return
	}
	dev.upscaler_kinds += {.Fsr}
	list := make([]string, min(count, MAX_VERSIONS), context.temp_allocator)
	for &name, i in list {
		name = string(names[i])
	}
	log.infof("d3d12: FSR %s, from the FidelityFX API %s", strings.join(list, ", ", context.temp_allocator), FFX_SDK_VERSION)
}

// shutdown_upscalers destroys the live upscalers and unloads the loader. The GPU must be idle.
@(private)
shutdown_upscalers :: proc() {
	for i in 0 ..< dev.upscaler_pool.count {
		if upscaler, ok := gpu.pool_handle(&dev.upscaler_pool, i); ok {
			destroy_ffx_context(dev.upscaler_pool.items[i].ffx_context)
			gpu.pool_remove(&dev.upscaler_pool, upscaler)
		}
	}
	gpu.pool_destroy(&dev.upscaler_pool)
	if dev.ffx.module != nil {
		win.FreeLibrary(win.HMODULE(dev.ffx.module))
	}
	dev.ffx = {}
	dev.upscaler_kinds = {}
}

upscalers :: proc() -> gpu.Upscaler_Kinds {
	return dev.upscaler_kinds
}

// create_upscaler makes a FidelityFX context, which compiles FSR's pipelines before it returns. The context finds the
// exposure from the color itself.
create_upscaler :: proc(desc: gpu.Upscaler_Desc) -> gpu.Upscaler {
	if err := gpu.validate_upscaler_desc(desc); err != .None {
		log.errorf("gpu: upscaler %q: %v", desc.label, err)
		return {}
	}
	if desc.kind not_in dev.upscaler_kinds {
		log.errorf("gpu: upscaler %q: the device cannot run %v", desc.label, desc.kind)
		return {}
	}
	version := Ffx_Create_Context_Desc_Upscale_Version {
		header  = {type = FFX_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION},
		version = FFX_UPSCALER_VERSION,
	}
	backend := Ffx_Create_Backend_Dx12_Desc {
		header = {type = FFX_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12, next = &version.header},
		device = dev.device,
	}
	create := Ffx_Create_Context_Desc_Upscale {
		header           = {type = FFX_CREATE_CONTEXT_DESC_TYPE_UPSCALE, next = &backend.header},
		flags            = FFX_UPSCALE_ENABLE_AUTO_EXPOSURE,
		max_render_size  = desc.max_render_size,
		max_upscale_size = desc.output_size,
		message          = on_ffx_message,
	}
	if .Hdr in desc.flags {
		create.flags |= FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE
	}
	if .Depth_Reversed in desc.flags {
		create.flags |= FFX_UPSCALE_ENABLE_DEPTH_INVERTED
	}
	if .Depth_Infinite in desc.flags {
		create.flags |= FFX_UPSCALE_ENABLE_DEPTH_INFINITE
	}
	when ODIN_DEBUG {
		create.flags |= FFX_UPSCALE_ENABLE_DEBUG_CHECKING
	}
	ctx: Ffx_Context
	if code := dev.ffx.create_context(&ctx, &create.header, nil); code != FFX_RETURN_OK {
		log.errorf("gpu: upscaler %q: ffxCreateContext failed: %d", desc.label, code)
		return {}
	}
	stored := desc
	stored.label = ""
	upscaler := gpu.pool_add(&dev.upscaler_pool, Upscaler_Entry{stored, ctx})
	if upscaler == {} {
		log.errorf("gpu: upscaler %q: the pool is full", desc.label)
		destroy_ffx_context(ctx)
	}
	return upscaler
}

destroy_upscaler :: proc(upscaler: gpu.Upscaler) {
	if entry, ok := gpu.pool_remove(&dev.upscaler_pool, upscaler); ok {
		defer_release_upscaler(entry.ffx_context, upscaler.index)
	}
}

@(private)
destroy_ffx_context :: proc(ctx: Ffx_Context) {
	ctx := ctx
	if code := dev.ffx.destroy_context(&ctx, nil); code != FFX_RETURN_OK {
		log.errorf("d3d12: ffxDestroyContext failed: %d", code)
	}
}

// upscale records an Upscale. The context leaves its own descriptor heaps, root signature and pipeline bound, so the
// translation binds the backend's again.
@(private)
upscale :: proc(list: rawptr, u: ^gpu.Upscale) {
	entry := gpu.pool_get(&dev.upscaler_pool, u.upscaler)
	assert(entry != nil, "gpu: invalid upscaler handle")
	read_state :: FFX_RESOURCE_STATE_COMPUTE_READ | FFX_RESOURCE_STATE_PIXEL_READ
	dispatch := Ffx_Dispatch_Desc_Upscale {
		header                      = {type = FFX_DISPATCH_DESC_TYPE_UPSCALE},
		command_list                = list,
		color                       = ffx_resource(u.color, read_state),
		depth                       = ffx_resource(u.depth, read_state),
		motion_vectors              = ffx_resource(u.motion, read_state),
		output                      = ffx_resource(u.output, FFX_RESOURCE_STATE_UNORDERED_ACCESS),
		jitter_offset               = u.jitter,
		motion_vector_scale         = u.motion_scale,
		render_size                 = u.render_size,
		upscale_size                = entry.desc.output_size,
		enable_sharpening           = u.sharpness > 0,
		sharpness                   = u.sharpness,
		frame_time_delta            = u.delta_time * 1000,
		pre_exposure                = 1,
		reset                       = bool(u.reset),
		camera_near                 = u.near,
		camera_far                  = u.far,
		camera_fov_angle_vertical   = u.fov_y,
		view_space_to_meters_factor = 1,
	}
	if code := dev.ffx.dispatch(&entry.ffx_context, &dispatch.header); code != FFX_RETURN_OK {
		log.errorf("d3d12: ffxDispatch failed: %d", code)
	}
}

// ffx_resource describes a texture to the FidelityFX API, in the state that the graph's barriers left it in. The
// API's views take the resource's own format, as they do for depth.
@(private = "file")
ffx_resource :: proc(texture: gpu.Texture, state: u32) -> Ffx_Resource {
	entry := gpu.pool_get(&dev.textures, texture)
	assert(entry != nil, "gpu: invalid texture handle")
	usage := u32(FFX_RESOURCE_USAGE_READ_ONLY)
	if .Storage in entry.desc.usage {
		usage |= FFX_RESOURCE_USAGE_UAV
	}
	if .Depth_Stencil in entry.desc.usage {
		usage |= FFX_RESOURCE_USAGE_DEPTHTARGET
	}
	return {
		resource = entry.resource,
		description = {
			type = FFX_RESOURCE_TYPE_TEXTURE2D,
			format = FFX_FORMAT[entry.desc.format],
			width = entry.desc.size.x,
			height = entry.desc.size.y,
			depth = 1,
			mip_count = max(entry.desc.mip_count, 1),
			usage = usage,
		},
		state = state,
	}
}

@(private = "file")
FFX_FORMAT := #partial [gpu.Format]Ffx_Surface_Format {
	.R8_Unorm          = .R8_Unorm,
	.RG8_Unorm         = .R8G8_Unorm,
	.RGBA8_Unorm       = .R8G8B8A8_Unorm,
	.RGBA8_Unorm_Srgb  = .R8G8B8A8_Srgb,
	.BGRA8_Unorm       = .B8G8R8A8_Unorm,
	.BGRA8_Unorm_Srgb  = .B8G8R8A8_Srgb,
	.RGB10A2_Unorm     = .R10G10B10A2_Unorm,
	.RG11B10_Float     = .R11G11B10_Float,
	.R16_Float         = .R16_Float,
	.RG16_Float        = .R16G16_Float,
	.RGBA16_Float      = .R16G16B16A16_Float,
	.R32_Uint          = .R32_Uint,
	.R32_Float         = .R32_Float,
	.RG32_Float        = .R32G32_Float,
	.RGBA32_Float      = .R32G32B32A32_Float,
	.D32_Float         = .R32_Float,
	.D32_Float_S8_Uint = .R32_Float,
}

// on_ffx_message logs what the FidelityFX API reports, which with debug checking includes misuse of the API, once for
// each message.
@(private = "file")
on_ffx_message :: proc "c" (type: u32, message: [^]u16) {
	context = runtime.default_context()
	context.logger = dev.logger
	n := 0
	for message[n] != 0 {
		n += 1
	}
	key := hash.fnv64a(slice.to_bytes(message[:n]))
	{
		sync.guard(&dev.ffx_mutex)
		if slice.contains(dev.ffx_logged[:], key) {
			return
		}
		dev.ffx_logged[dev.ffx_next] = key
		dev.ffx_next = (dev.ffx_next + 1) % len(dev.ffx_logged)
	}
	buf: [1024]u8
	text := win.wstring_to_utf8(buf[:], win.wstring(message))
	if type == FFX_MESSAGE_TYPE_ERROR {
		log.errorf("fsr: %s", text)
	} else {
		log.warnf("fsr: %s", text)
	}
}
