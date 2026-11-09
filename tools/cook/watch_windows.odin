package cook

import "core:fmt"
import "core:log"
import "core:strings"
import win "core:sys/windows"
import "core:time"

// Watcher waits for changes under a set of directories, or for another thread to wake it, and remembers which paths
// changed until watcher_take hands them over. When it cannot say, as when Windows drops changes because its buffer
// filled, or a directory was not watched for a while, it says that everything changed, so the next pass scans all of
// it (see docs/content/daemon-and-operations.md#saved-index).
Watcher :: struct {
	dirs:    [dynamic]^Watched_Dir,
	// The directories' events, then the wake event.
	events:  [dynamic]win.HANDLE,
	wake:    win.HANDLE,
	// What changed since the last watcher_take, in the heap. Only note_path, note_everything and watcher_take change it.
	pending: Pending_Changes,
}

// Watch_Changes is what changed since the last watcher_take: nil for nothing, the paths that changed, or everything.
Watch_Changes :: union {
	Changed_Paths,
	Changed_Everything,
}

// Changed_Paths are the files and directories that changed: absolute, with forward slashes, each once.
Changed_Paths :: struct {
	paths: []string,
}

// Changed_Everything is a change that the watcher cannot say more of.
Changed_Everything :: struct {}

// More changed paths than this is a change of everything: a scan of everything costs less than looking at each.
MAX_CHANGED_PATHS :: 4096

@(private = "file")
Pending_Changes :: union {
	Pending_Paths,
	Changed_Everything,
}

@(private = "file")
Pending_Paths :: struct {
	paths: map[string]bool,
}

Wait_Result :: enum {
	Timeout,
	Changed,
	// watcher_wake was called.
	Woken,
	// The wait failed, which watcher_wait reports.
	Failed,
}

// Watch_State is whether a directory is watched. Reading: its handle is open, and a read is pending, so its event
// signals a change. Broken: the directory went, or its read failed, as when `just clean` deletes it; its handle is
// closed, and watcher_wait opens it again once it can.
@(private = "file")
Watch_State :: enum {
	Broken,
	Reading,
}

@(private = "file")
Watched_Dir :: struct {
	path:       string,
	state:      Watch_State,
	// Open only while Reading.
	handle:     win.HANDLE,
	// The directory that handle is open on, so that one made again at the same path is told from it.
	identity:   Dir_Identity,
	// Windows writes into these while a read is pending, so a Watched_Dir never moves. The event outlives the handle,
	// so the watcher's events stay in the directories' order.
	overlapped: win.OVERLAPPED,
	buffer:     [1024]u32,
}

@(private = "file")
Dir_Identity :: struct {
	volume: win.DWORD,
	high:   win.DWORD,
	low:    win.DWORD,
}

@(private = "file")
WATCH_FILTER :: win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_SIZE

// A read whose changes did not fit in the buffer, which Windows may give instead of a read of no bytes.
@(private = "file")
ERROR_NOTIFY_ENUM_DIR :: 1022

// How long a wait goes, at most, between tries to open a broken directory again.
@(private = "file")
REOPEN_MS :: 500

// watcher_open watches each directory and everything under it. The watcher keeps the paths, so they must outlive it.
// Each directory must exist; one that goes later is watched again once it is back (see watcher_wait).
watcher_open :: proc(w: ^Watcher, dirs: []string) -> bool {
	w^ = {}
	// Auto-reset, so one wake wakes one wait.
	w.wake = win.CreateEventW(nil, false, false, nil)
	for path in dirs {
		d := new(Watched_Dir)
		d.path = path
		d.overlapped.hEvent = win.CreateEventW(nil, true, false, nil)
		append(&w.dirs, d)
		append(&w.events, d.overlapped.hEvent)
		if error := open_dir(d); error != 0 {
			log.errorf("cook: cannot watch %s: Windows error %d", path, error)
			watcher_close(w)
			return false
		}
	}
	append(&w.events, w.wake)
	return true
}

watcher_close :: proc(w: ^Watcher) {
	for d in w.dirs {
		close_dir(d)
		win.CloseHandle(d.overlapped.hEvent)
		free(d)
	}
	if w.wake != nil {
		win.CloseHandle(w.wake)
	}
	delete(w.dirs)
	delete(w.events)
	pending_free(&w.pending)
	w^ = {}
}

// watcher_take hands over what changed since the last take, in allocator, and forgets it.
watcher_take :: proc(w: ^Watcher, allocator := context.allocator) -> Watch_Changes {
	defer pending_free(&w.pending)
	switch p in w.pending {
	case Pending_Paths:
		paths := make([]string, len(p.paths), allocator)
		i := 0
		for path in p.paths {
			paths[i] = strings.clone(path, allocator)
			i += 1
		}
		return Changed_Paths{paths}
	case Changed_Everything:
		return Changed_Everything{}
	}
	return nil
}

// notify_paths adds the paths that a ReadDirectoryChangesW buffer names, under the directory that it watches, to out.
notify_paths :: proc(dir: string, buffer: []byte, out: ^[dynamic]string, allocator := context.allocator) {
	NAME_OFFSET :: int(offset_of(win.FILE_NOTIFY_INFORMATION, FileName))
	for offset := 0; offset + NAME_OFFSET <= len(buffer); {
		info := (^win.FILE_NOTIFY_INFORMATION)(raw_data(buffer[offset:]))
		length := int(info.FileNameLength)
		if offset + NAME_OFFSET + length > len(buffer) {
			return
		}
		name := ([^]u16)(raw_data(buffer[offset + NAME_OFFSET:]))[:length / 2]
		utf8, _ := win.utf16_to_utf8(name, context.temp_allocator)
		path, _ := strings.replace_all(fmt.tprintf("%s/%s", dir, utf8), "\\", "/", context.temp_allocator)
		append(out, strings.clone(path, allocator))
		if info.NextEntryOffset == 0 {
			return
		}
		offset += int(info.NextEntryOffset)
	}
}

// note_path remembers that a path changed.
@(private = "file")
note_path :: proc(w: ^Watcher, path: string) {
	switch &p in w.pending {
	case nil:
		w.pending = Pending_Paths{make(map[string]bool)}
		note_path(w, path)
	case Pending_Paths:
		if path in p.paths {
			return
		}
		if len(p.paths) >= MAX_CHANGED_PATHS {
			note_everything(w)
			return
		}
		p.paths[strings.clone(path)] = true
	case Changed_Everything:
	}
}

// note_everything remembers that the watcher cannot say what changed.
@(private = "file")
note_everything :: proc(w: ^Watcher) {
	pending_free(&w.pending)
	w.pending = Changed_Everything{}
}

@(private = "file")
pending_free :: proc(pending: ^Pending_Changes) {
	if p, is_paths := pending.(Pending_Paths); is_paths {
		for path in p.paths {
			delete(path)
		}
		delete(p.paths)
	}
	pending^ = nil
}

// WAIT_FOREVER is watcher_wait's timeout for no limit.
WAIT_FOREVER :: u32(win.INFINITE)

// watcher_wake wakes the thread that waits, or its next wait. Any thread can call it.
watcher_wake :: proc(w: ^Watcher) {
	win.SetEvent(w.wake)
}

// watcher_wait waits up to timeout milliseconds for a change under any directory, or for watcher_wake, and remembers
// the paths that changed. A directory that went, or whose read failed, is Broken: the change is Changed, and while any
// directory is Broken the wait tries to open it again every REOPEN_MS. A directory that opens again is Changed too.
// Both are a change of everything, since what changed in it meanwhile was not seen, as is a read that Windows could
// not fit in its buffer.
watcher_wait :: proc(w: ^Watcher, timeout: u32) -> Wait_Result {
	start := time.tick_now()
	for {
		if reopen_dirs(w) {
			note_everything(w)
			return .Changed
		}
		wait := timeout
		if broken(w) {
			if timeout != WAIT_FOREVER {
				elapsed := u32(time.duration_milliseconds(time.tick_since(start)))
				wait = elapsed >= timeout ? 0 : timeout - elapsed
			}
			wait = min(wait, REOPEN_MS)
		}
		result := win.WaitForMultipleObjects(win.DWORD(len(w.events)), raw_data(w.events), false, wait)
		if result == win.WAIT_TIMEOUT {
			if wait == timeout || (timeout != WAIT_FOREVER && u32(time.duration_milliseconds(time.tick_since(start))) >= timeout) {
				return .Timeout
			}
			continue
		}
		index := int(result - win.WAIT_OBJECT_0)
		if result == win.WAIT_FAILED || index < 0 || index > len(w.dirs) {
			log.errorf("cook: waiting for changes failed: Windows error %d", win.GetLastError())
			return .Failed
		}
		if index == len(w.dirs) {
			return .Woken
		}
		d := w.dirs[index]
		transferred: win.DWORD
		read := win.GetOverlappedResult(d.handle, &d.overlapped, &transferred, false)
		error := win.GetLastError()
		win.ResetEvent(d.overlapped.hEvent)
		switch {
		case !read && error == ERROR_NOTIFY_ENUM_DIR, read && transferred == 0:
			// Windows dropped what changed, as more changed than its buffer holds.
			note_everything(w)
		case read:
			paths := make([dynamic]string, context.temp_allocator)
			notify_paths(d.path, ([^]byte)(&d.buffer)[:transferred], &paths, context.temp_allocator)
			for path in paths {
				note_path(w, path)
			}
		}
		if !read && error != ERROR_NOTIFY_ENUM_DIR {
			break_dir(d, error)
			note_everything(w)
		} else if !same_dir(d) {
			// The directory at the path went, or is going: it was deleted while the handle kept it.
			break_dir(d, 0)
			note_everything(w)
		} else if !start_read(d) {
			break_dir(d, win.GetLastError())
			note_everything(w)
		}
		return .Changed
	}
}

// open_dir opens a directory's handle and starts its read, and gives the Windows error when it cannot.
@(private = "file")
open_dir :: proc(d: ^Watched_Dir) -> win.DWORD {
	assert(d.state == .Broken)
	handle := win.CreateFileW(
		win.utf8_to_wstring(d.path),
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		return win.GetLastError()
	}
	identity, ok := handle_identity(handle)
	if !ok {
		error := win.GetLastError()
		win.CloseHandle(handle)
		return error
	}
	d.handle, d.identity = handle, identity
	win.ResetEvent(d.overlapped.hEvent)
	if !start_read(d) {
		error := win.GetLastError()
		win.CloseHandle(handle)
		d.handle = nil
		return error
	}
	d.state = .Reading
	return 0
}

// close_dir ends a directory's read and closes its handle. The read must finish before its buffer can go.
@(private = "file")
close_dir :: proc(d: ^Watched_Dir) {
	if d.state != .Reading {
		return
	}
	win.CancelIoEx(d.handle, &d.overlapped)
	transferred: win.DWORD
	win.GetOverlappedResult(d.handle, &d.overlapped, &transferred, true)
	win.CloseHandle(d.handle)
	d.handle = nil
	d.state = .Broken
}

// break_dir closes a directory whose read failed or that went, so that a directory deleted while it was watched can
// go, and logs it. watcher_wait opens it again.
@(private = "file")
break_dir :: proc(d: ^Watched_Dir, error: win.DWORD) {
	close_dir(d)
	win.ResetEvent(d.overlapped.hEvent)
	if error != 0 {
		log.warnf("cook: %s is not watched, Windows error %d: it is watched again once it can be opened", d.path, error)
	} else {
		log.warnf("cook: %s went: it is watched again once it is back", d.path)
	}
}

// reopen_dirs tries to open each Broken directory again, and is true if one opened.
@(private = "file")
reopen_dirs :: proc(w: ^Watcher) -> (opened: bool) {
	for d in w.dirs {
		if d.state == .Broken && open_dir(d) == 0 {
			log.infof("cook: watching %s again", d.path)
			opened = true
		}
	}
	return
}

@(private = "file")
broken :: proc(w: ^Watcher) -> bool {
	for d in w.dirs {
		if d.state == .Broken {
			return true
		}
	}
	return false
}

// same_dir is whether the path still names the directory that the handle is open on. A directory deleted while it is
// watched stays until the handle closes, but can no longer be opened by its path, or another can be made there.
@(private = "file")
same_dir :: proc(d: ^Watched_Dir) -> bool {
	handle := win.CreateFileW(
		win.utf8_to_wstring(d.path),
		win.FILE_READ_ATTRIBUTES,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		return false
	}
	defer win.CloseHandle(handle)
	identity, ok := handle_identity(handle)
	return ok && identity == d.identity
}

@(private = "file")
handle_identity :: proc(handle: win.HANDLE) -> (Dir_Identity, bool) {
	info: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(handle, &info) {
		return {}, false
	}
	return {info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow}, true
}

@(private = "file")
start_read :: proc(d: ^Watched_Dir) -> bool {
	return bool(win.ReadDirectoryChangesW(d.handle, &d.buffer, size_of(d.buffer), true, WATCH_FILTER, nil, &d.overlapped, nil))
}
