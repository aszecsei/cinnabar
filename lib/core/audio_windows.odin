#+private
package core

import "core:log"
import "core:sync"
import win "core:sys/windows"
import "core:time"

import wasapi "vendor:windows/wasapi"

foreign import avrt "system:Avrt.lib"

@(default_calling_convention = "system")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(TaskName: win.LPCWSTR, TaskIndex: ^win.DWORD) -> win.HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(AvrtHandle: win.HANDLE) -> win.BOOL ---
}

// The endpoint's buffer, in units of 100 ns: three of the usual 10 ms periods, so one late wake does not glitch.
AUDIO_ENDPOINT_BUFFER :: 300_000
// How often the thread tries a device that would not open, and looks for a new default device.
AUDIO_RETRY_INTERVAL :: time.Second
// The longest wait for the endpoint, which also bounds how long closing takes.
AUDIO_WAIT_MS :: 100
// How often the queue drains without an endpoint.
AUDIO_IDLE_INTERVAL :: 10 * time.Millisecond

Audio_Stream :: struct {
	client: ^wasapi.IAudioClient,
	render: ^wasapi.IAudioRenderClient,
	// From the endpoint, for CoTaskMemFree.
	id:     win.LPWSTR,
	size:   u32,
}

// _audio_thread keeps the default endpoint open and feeds it from the queue, and drains the queue at the sample rate
// while it has no endpoint (see docs/core/audio.md#device-loss).
_audio_thread :: proc(data: rawptr) {
	device := (^Audio_Device)(data)
	if hr := win.CoInitializeEx(nil, .MULTITHREADED); win.FAILED(hr) {
		log.errorf("core: audio: CoInitializeEx: %x", u32(hr))
		return
	}
	defer win.CoUninitialize()

	task_index: win.DWORD
	task := AvSetMmThreadCharacteristicsW(win.L("Pro Audio"), &task_index)
	if task == nil {
		log.warnf("core: audio: no multimedia thread priority: %d", win.GetLastError())
	}
	defer if task != nil {
		AvRevertMmThreadCharacteristics(task)
	}

	wake := win.CreateEventW(nil, false, false, nil)
	defer win.CloseHandle(wake)

	enumerator: ^wasapi.IMMDeviceEnumerator
	if hr := win.CoCreateInstance(wasapi.CLSID_MMDeviceEnumerator, nil, win.CLSCTX_ALL, wasapi.IID_IMMDeviceEnumerator, cast(^win.LPVOID)&enumerator); win.FAILED(hr) {
		log.errorf("core: audio: no device enumerator: %x", u32(hr))
	}
	defer if enumerator != nil {
		enumerator->Release()
	}

	stream: Audio_Stream
	defer audio_stream_close(device, &stream)
	warned := false
	idle_start := time.tick_now()
	idle_drained: u64
	last_look: time.Tick

	for !sync.atomic_load_explicit(&device.closing, .Acquire) {
		if stream.client == nil {
			if enumerator != nil && (last_look == {} || time.tick_since(last_look) >= AUDIO_RETRY_INTERVAL) {
				last_look = time.tick_now()
				hr := audio_stream_open(device, enumerator, wake, &stream)
				if win.FAILED(hr) && !warned {
					log.warnf("core: audio: no output device: %x. The queue drains until one opens.", u32(hr))
					warned = true
				}
				if win.SUCCEEDED(hr) {
					warned = false
				}
			}
			if stream.client == nil {
				time.sleep(AUDIO_IDLE_INTERVAL)
				due := u64(time.duration_seconds(time.tick_since(idle_start)) * AUDIO_SAMPLE_RATE)
				audio_device_skip(device, int(due - idle_drained))
				idle_drained = due
			}
			continue
		}

		win.WaitForSingleObject(wake, AUDIO_WAIT_MS)
		if hr := audio_stream_fill(device, &stream); win.FAILED(hr) {
			log.warnf("core: audio: the output device stopped: %x", u32(hr))
			audio_stream_close(device, &stream)
		} else if time.tick_since(last_look) >= AUDIO_RETRY_INTERVAL {
			last_look = time.tick_now()
			if audio_default_changed(enumerator, stream.id) {
				log.info("core: audio: the default output device changed")
				audio_stream_close(device, &stream)
				last_look = {}
			}
		}
		if stream.client == nil {
			idle_start = time.tick_now()
			idle_drained = 0
		}
	}
}

// audio_stream_open opens the default endpoint in the device's format, fills its buffer and starts it.
audio_stream_open :: proc(device: ^Audio_Device, enumerator: ^wasapi.IMMDeviceEnumerator, wake: win.HANDLE, stream: ^Audio_Stream) -> (hr: win.HRESULT) {
	defer if win.FAILED(hr) {
		audio_stream_close(device, stream)
	}
	endpoint: ^wasapi.IMMDevice
	hr = enumerator->GetDefaultAudioEndpoint(.Render, .Console, &endpoint)
	if win.FAILED(hr) {
		return
	}
	defer endpoint->Release()
	hr = endpoint->GetId(&stream.id)
	if win.FAILED(hr) {
		return
	}
	hr = endpoint->Activate(wasapi.IID_IAudioClient, win.CLSCTX_ALL, nil, cast([^]rawptr)&stream.client)
	if win.FAILED(hr) {
		return
	}
	format := wasapi.WAVEFORMATEX {
		wFormatTag      = .IEEE_FLOAT,
		nChannels       = len(Audio_Frame),
		nSamplesPerSec  = AUDIO_SAMPLE_RATE,
		nAvgBytesPerSec = AUDIO_SAMPLE_RATE * size_of(Audio_Frame),
		nBlockAlign     = size_of(Audio_Frame),
		wBitsPerSample  = size_of(f32) * 8,
	}
	flags := u32(wasapi.AUDCLNT_FLAG.STREAM_EVENTCALLBACK) | u32(wasapi.AUDCLNT_FLAG.STREAM_AUTOCONVERTPCM) | u32(wasapi.AUDCLNT_FLAG.STREAM_SRC_DEFAULT_QUALITY)
	hr = stream.client->Initialize(.SHARED, flags, AUDIO_ENDPOINT_BUFFER, 0, &format, nil)
	if win.FAILED(hr) {
		return
	}
	hr = stream.client->GetBufferSize(&stream.size)
	if win.FAILED(hr) {
		return
	}
	hr = stream.client->SetEventHandle(wake)
	if win.FAILED(hr) {
		return
	}
	hr = stream.client->GetService(wasapi.IID_IAudioRenderClient, cast(^rawptr)&stream.render)
	if win.FAILED(hr) {
		return
	}
	hr = audio_stream_fill(device, stream)
	if win.FAILED(hr) {
		return
	}
	hr = stream.client->Start()
	if win.FAILED(hr) {
		return
	}
	sync.atomic_store_explicit(&device.open, true, .Relaxed)
	log.infof("core: audio: opened the default output device, with %d frames of buffer", stream.size)
	return
}

audio_stream_close :: proc(device: ^Audio_Device, stream: ^Audio_Stream) {
	sync.atomic_store_explicit(&device.open, false, .Relaxed)
	if stream.client != nil {
		stream.client->Stop()
	}
	if stream.render != nil {
		stream.render->Release()
	}
	if stream.client != nil {
		stream.client->Release()
	}
	if stream.id != nil {
		win.CoTaskMemFree(stream.id)
	}
	stream^ = {}
}

// audio_stream_fill gives the endpoint all the frames that its buffer has room for.
audio_stream_fill :: proc(device: ^Audio_Device, stream: ^Audio_Stream) -> (hr: win.HRESULT) {
	padding: u32
	hr = stream.client->GetCurrentPadding(&padding)
	if win.FAILED(hr) {
		return
	}
	free := stream.size - padding
	if free == 0 {
		return
	}
	data: [^]byte
	hr = stream.render->GetBuffer(free, &data)
	if win.FAILED(hr) {
		return
	}
	audio_device_take(device, ([^]Audio_Frame)(data)[:free])
	return stream.render->ReleaseBuffer(free, 0)
}

// audio_default_changed reports whether the default endpoint is another one than id. With no default at all, the open
// stream fails by itself.
audio_default_changed :: proc(enumerator: ^wasapi.IMMDeviceEnumerator, id: win.LPWSTR) -> bool {
	endpoint: ^wasapi.IMMDevice
	if win.FAILED(enumerator->GetDefaultAudioEndpoint(.Render, .Console, &endpoint)) {
		return false
	}
	defer endpoint->Release()
	current: win.LPWSTR
	if win.FAILED(endpoint->GetId(&current)) {
		return false
	}
	defer win.CoTaskMemFree(current)
	for i := 0;; i += 1 {
		a, b := ([^]win.WCHAR)(current)[i], ([^]win.WCHAR)(id)[i]
		if a != b {
			return true
		}
		if a == 0 {
			return false
		}
	}
}
