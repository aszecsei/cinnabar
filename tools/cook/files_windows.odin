package cook

import "core:os"
import "core:strings"
import win "core:sys/windows"

// move_file moves a file or a directory. Unlike os.rename, it never replaces what is at the destination, and it moves
// a file to another volume, as between roots on two drives. A directory moves only on its volume.
move_file :: proc(from, to: string) -> (error: string) {
	flags: win.DWORD = os.is_dir(from) ? 0 : win.MOVEFILE_COPY_ALLOWED | win.MOVEFILE_WRITE_THROUGH
	if !win.MoveFileExW(win.utf8_to_wstring(from, context.temp_allocator), win.utf8_to_wstring(to, context.temp_allocator), flags) {
		return os.error_string(os.Platform_Error(win.GetLastError()))
	}
	return ""
}

// recycle sends files and directories to the Recycle Bin, without asking.
recycle :: proc(paths: []string) -> bool {
	if len(paths) == 0 {
		return true
	}
	// pFrom is a list of absolute paths with backslashes, each ending with a zero, and another zero after the last.
	list := make([dynamic]u16, context.temp_allocator)
	for path in paths {
		wide := win.utf8_to_utf16(strings.join(strings.split(path, "/", context.temp_allocator), "\\", context.temp_allocator), context.temp_allocator)
		append(&list, ..wide)
		append(&list, 0)
	}
	append(&list, 0)
	op := win.SHFILEOPSTRUCTW {
		wFunc  = win.FO_DELETE,
		pFrom  = win.PCZZWSTR(raw_data(list)),
		fFlags = win.FOF_ALLOWUNDO | win.FOF_NO_UI,
	}
	return win.SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted
}
