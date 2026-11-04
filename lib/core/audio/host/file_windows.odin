package audio_host

import win "core:sys/windows"

// file_open opens with FILE_SHARE_DELETE, so that the daemon can delete a blob that a stream is reading. A rename over an
// open file fails all the same (see docs/audio/design.md#streaming).
@(private)
file_open :: proc "c" (path: cstring) -> rawptr {
	context = host_context()
	buffer: [win.MAX_PATH_WIDE]u16
	length := win.MultiByteToWideChar(win.CP_UTF8, 0, (^u8)(rawptr(path)), -1, &buffer[0], i32(len(buffer)))
	if length == 0 {
		return nil
	}
	handle := win.CreateFileW(
		cstring16(&buffer[0]),
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_SEQUENTIAL_SCAN,
		nil,
	)
	return nil if handle == win.INVALID_HANDLE_VALUE else rawptr(handle)
}

@(private)
file_read_at :: proc "c" (file: rawptr, offset: u64, buffer: rawptr, size: u64) -> i64 {
	overlapped := win.OVERLAPPED {
		Offset     = u32(offset),
		OffsetHigh = u32(offset >> 32),
	}
	read: u32
	if !win.ReadFile(win.HANDLE(file), buffer, u32(size), &read, &overlapped) {
		// Past the end is not a failure: it reads nothing.
		if win.GetLastError() == win.ERROR_HANDLE_EOF {
			return 0
		}
		return -1
	}
	return i64(read)
}

@(private)
file_modified :: proc "c" (file: rawptr) -> i64 {
	info: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(win.HANDLE(file), &info) {
		return 0
	}
	// FILETIME counts 100 ns from 1601. Only a comparison reads this, so the epoch does not matter.
	return (i64(info.ftLastWriteTime.dwHighDateTime) << 32 | i64(info.ftLastWriteTime.dwLowDateTime)) * 100
}

@(private)
file_close :: proc "c" (file: rawptr) {
	win.CloseHandle(win.HANDLE(file))
}
