package cook

import "core:log"
import win "core:sys/windows"

// Watcher waits for changes under a set of directories. It does not say what changed: each pass scans the roots
// again, and the cache keys find what is dirty, so a change that Windows drops (when its buffer fills) loses nothing.
Watcher :: struct {
	dirs:   [dynamic]^Watched_Dir,
	events: [dynamic]win.HANDLE,
}

@(private = "file")
Watched_Dir :: struct {
	path:       string,
	handle:     win.HANDLE,
	// Windows writes into these while a read is pending, so a Watched_Dir never moves.
	overlapped: win.OVERLAPPED,
	buffer:     [1024]u32,
}

@(private = "file")
WATCH_FILTER :: win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_SIZE

// watcher_open watches each directory and everything under it. The watcher keeps the paths, so they must outlive it.
watcher_open :: proc(w: ^Watcher, dirs: []string) -> bool {
	w^ = {}
	for path in dirs {
		handle := win.CreateFileW(
			win.utf8_to_wstring(path),
			win.FILE_LIST_DIRECTORY,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			nil,
			win.OPEN_EXISTING,
			win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED,
			nil,
		)
		if handle == win.INVALID_HANDLE_VALUE {
			log.errorf("cook: cannot watch %s: Windows error %d", path, win.GetLastError())
			watcher_close(w)
			return false
		}
		d := new(Watched_Dir)
		d.path = path
		d.handle = handle
		d.overlapped.hEvent = win.CreateEventW(nil, true, false, nil)
		append(&w.dirs, d)
		append(&w.events, d.overlapped.hEvent)
		if !start_read(d) {
			watcher_close(w)
			return false
		}
	}
	return true
}

watcher_close :: proc(w: ^Watcher) {
	for d in w.dirs {
		win.CancelIoEx(d.handle, &d.overlapped)
		// The read must finish before its buffer is freed.
		transferred: win.DWORD
		win.GetOverlappedResult(d.handle, &d.overlapped, &transferred, true)
		win.CloseHandle(d.overlapped.hEvent)
		win.CloseHandle(d.handle)
		free(d)
	}
	delete(w.dirs)
	delete(w.events)
	w^ = {}
}

// WAIT_FOREVER is watcher_wait's timeout for no limit.
WAIT_FOREVER :: u32(win.INFINITE)

// watcher_wait waits up to timeout milliseconds for a change under any directory. It returns false if none came, or
// if the wait failed, which it reports.
watcher_wait :: proc(w: ^Watcher, timeout: u32) -> bool {
	result := win.WaitForMultipleObjects(win.DWORD(len(w.events)), raw_data(w.events), false, timeout)
	if result == win.WAIT_TIMEOUT {
		return false
	}
	index := int(result - win.WAIT_OBJECT_0)
	if result == win.WAIT_FAILED || index < 0 || index >= len(w.dirs) {
		log.errorf("cook: waiting for changes failed: Windows error %d", win.GetLastError())
		return false
	}
	d := w.dirs[index]
	transferred: win.DWORD
	win.GetOverlappedResult(d.handle, &d.overlapped, &transferred, false)
	win.ResetEvent(d.overlapped.hEvent)
	start_read(d)
	return true
}

@(private = "file")
start_read :: proc(d: ^Watched_Dir) -> bool {
	if !win.ReadDirectoryChangesW(d.handle, &d.buffer, size_of(d.buffer), true, WATCH_FILTER, nil, &d.overlapped, nil) {
		log.errorf("cook: cannot watch %s: Windows error %d", d.path, win.GetLastError())
		return false
	}
	return true
}
