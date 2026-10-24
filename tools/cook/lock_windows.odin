package cook

import "core:fmt"
import "core:log"
import "core:os"
import win "core:sys/windows"

LOCK_FILE :: ".cook.lock"

// Cache_Lock keeps two cooks from writing to one cache at once, such as a batch cook while the daemon runs. Both
// would give a new asset a .meta file, each with its own GUID. The lock is a file that no other handle can open, and
// that Windows deletes when its handle closes, so a cook that crashes leaves no lock behind.
Cache_Lock :: struct {
	handle: win.HANDLE,
}

Lock_Result :: enum {
	Locked,
	// Another cook holds the lock.
	Held,
	Failed,
}

// lock_cache takes the cache's lock. It reports a failure, but not that another cook holds it, which each caller
// says in its own way.
lock_cache :: proc(cache: string) -> (lock: Cache_Lock, result: Lock_Result) {
	if err := os.make_directory_all(cache); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", cache, err)
		return {}, .Failed
	}
	path := fmt.tprintf("%s/%s", cache, LOCK_FILE)
	handle := win.CreateFileW(
		win.utf8_to_wstring(path),
		win.GENERIC_READ | win.GENERIC_WRITE,
		0,
		nil,
		win.OPEN_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_DELETE_ON_CLOSE,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		error := win.GetLastError()
		if error == win.ERROR_SHARING_VIOLATION || error == win.ERROR_ACCESS_DENIED {
			return {}, .Held
		}
		log.errorf("cook: %s: Windows error %d", path, error)
		return {}, .Failed
	}
	return {handle}, .Locked
}

unlock_cache :: proc(lock: ^Cache_Lock) {
	if lock.handle != nil {
		win.CloseHandle(lock.handle)
	}
	lock^ = {}
}
