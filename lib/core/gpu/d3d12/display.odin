package gpu_d3d12

import win "core:sys/windows"

import "vendor:directx/dxgi"

import "cinnabar:core/gpu"

// find_display describes the display that shows most of the window. A factory that is no longer current sees the
// adapters and outputs as they were, such as the display's HDR mode before it changed, so a new one replaces it.
@(private)
find_display :: proc() -> (display: gpu.Display) {
	if !dev.factory->IsCurrent() {
		factory: ^dxgi.IFactory6
		if check(dxgi.CreateDXGIFactory2({}, dxgi.IFactory6_UUID, (^rawptr)(&factory)), "CreateDXGIFactory2") {
			release(&dev.factory)
			dev.factory = factory
		}
	}
	window: win.RECT
	win.GetWindowRect(dev.hwnd, &window)
	best: i32 = -1
	for i: u32 = 0;; i += 1 {
		adapter: ^dxgi.IAdapter1
		if win.FAILED(dev.factory->EnumAdapters1(i, &adapter)) {
			break
		}
		for j: u32 = 0;; j += 1 {
			output: ^dxgi.IOutput
			if win.FAILED(adapter->EnumOutputs(j, &output)) {
				break
			}
			output6: ^dxgi.IOutput6
			desc: dxgi.OUTPUT_DESC1
			if win.SUCCEEDED(output->QueryInterface(dxgi.IOutput6_UUID, (^rawptr)(&output6))) {
				if win.SUCCEEDED(output6->GetDesc1(&desc)) {
					r := desc.DesktopCoordinates
					area := max(0, min(r.right, window.right) - max(r.left, window.left)) * max(0, min(r.bottom, window.bottom) - max(r.top, window.top))
					if area > best {
						best = area
						display = {
							hdr                      = desc.ColorSpace == .RGB_FULL_G2084_NONE_P2020,
							min_luminance            = desc.MinLuminance,
							max_luminance            = desc.MaxLuminance,
							max_full_frame_luminance = desc.MaxFullFrameLuminance,
							sdr_white                = sdr_white_level(desc.DeviceName),
						}
					}
				}
				output6->Release()
			}
			output->Release()
		}
		adapter->Release()
	}
	return
}

// sdr_white_level is the brightness in nits that Windows gives SDR content on the display with a GDI device name, as
// its HDR settings set it, or 0 when it is unknown. DXGI does not report it, so it comes from the display configuration.
@(private = "file")
sdr_white_level :: proc(device_name: [32]u16) -> f32 {
	path_count, mode_count: u32
	if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != 0 {
		return 0
	}
	paths := make([]Displayconfig_Path_Info, path_count, context.temp_allocator)
	modes := make([]Displayconfig_Mode_Info, mode_count, context.temp_allocator)
	if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, raw_data(paths), &mode_count, raw_data(modes), nil) != 0 {
		return 0
	}
	for path in paths[:path_count] {
		source := Displayconfig_Source_Device_Name {
			header = {type = .Get_Source_Name, size = size_of(Displayconfig_Source_Device_Name), adapter_id = path.source_adapter_id, id = path.source_id},
		}
		if DisplayConfigGetDeviceInfo(&source.header) != 0 || source.view_gdi_device_name != device_name {
			continue
		}
		white := Displayconfig_Sdr_White_Level {
			header = {type = .Get_Sdr_White_Level, size = size_of(Displayconfig_Sdr_White_Level), adapter_id = path.target_adapter_id, id = path.target_id},
		}
		if DisplayConfigGetDeviceInfo(&white.header) != 0 {
			return 0
		}
		// 1000 is 80 nits.
		return f32(white.sdr_white_level) / 1000 * 80
	}
	return 0
}

@(private = "file")
QDC_ONLY_ACTIVE_PATHS :: 0x2

// The display configuration's records, as wingdi.h has them, with only the fields that sdr_white_level reads named.
@(private = "file")
Displayconfig_Path_Info :: struct {
	source_adapter_id: win.LUID,
	source_id:         u32,
	_:                 [2]u32,
	target_adapter_id: win.LUID,
	target_id:         u32,
	_:                 [9]u32,
	flags:             u32,
}

@(private = "file")
Displayconfig_Mode_Info :: struct {
	_: [8]u64,
}

@(private = "file")
Displayconfig_Device_Info_Type :: enum i32 {
	Get_Source_Name     = 1,
	Get_Sdr_White_Level = 11,
}

@(private = "file")
Displayconfig_Device_Info_Header :: struct {
	type:       Displayconfig_Device_Info_Type,
	size:       u32,
	adapter_id: win.LUID,
	id:         u32,
}

@(private = "file")
Displayconfig_Source_Device_Name :: struct {
	header:               Displayconfig_Device_Info_Header,
	view_gdi_device_name: [32]u16,
}

@(private = "file")
Displayconfig_Sdr_White_Level :: struct {
	header:          Displayconfig_Device_Info_Header,
	sdr_white_level: u32,
}

#assert(size_of(Displayconfig_Path_Info) == 72 && size_of(Displayconfig_Mode_Info) == 64)
#assert(size_of(Displayconfig_Source_Device_Name) == 84 && size_of(Displayconfig_Sdr_White_Level) == 24)

foreign import user32 "system:User32.lib"

@(private = "file", default_calling_convention = "system")
foreign user32 {
	GetDisplayConfigBufferSizes :: proc(flags: u32, path_count, mode_count: ^u32) -> i32 ---
	QueryDisplayConfig :: proc(flags: u32, path_count: ^u32, paths: [^]Displayconfig_Path_Info, mode_count: ^u32, modes: [^]Displayconfig_Mode_Info, topology: rawptr) -> i32 ---
	DisplayConfigGetDeviceInfo :: proc(packet: ^Displayconfig_Device_Info_Header) -> i32 ---
}
