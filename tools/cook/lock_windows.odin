package cook

import "core:fmt"
import "core:log"
import "core:os"
import win "core:sys/windows"
import "core:time"

LOCK_FILE :: ".cook.lock"

// Lock is a file that no other handle can open, and that Windows deletes when its handle closes, so a cook that
// crashes leaves no lock behind. A cache's lock keeps two cooks from writing one cache's blobs, index and generation
// file at once. A content root's lock keeps two cooks, as the daemon and a release cook, which have their own caches,
// from giving one asset two GUIDs (see lock_root).
Lock :: struct {
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
lock_cache :: proc(cache: string) -> (lock: Lock, result: Lock_Result) {
	if err := os.make_directory_all(cache); err != nil && err != .Exist {
		log.errorf("cook: %s: %v", cache, err)
		return {}, .Failed
	}
	return lock_file(fmt.tprintf("%s/%s", cache, LOCK_FILE))
}

// A cook holds a root's lock only while it writes .meta files, which takes milliseconds, so another waits for it.
ROOT_LOCK_ATTEMPTS :: 500
ROOT_LOCK_WAIT :: 20 * time.Millisecond

// lock_root takes a content root's lock, and waits while another cook holds it. Whoever changes which .meta file is
// next to which asset in the root holds it: a cook that gives a new asset its .meta file or adds sub-assets to one,
// and each of the daemon's asset operations. A cook that finds an asset without a .meta file looks again under the
// lock, so two cooks give it one GUID. The scan skips the lock, as its name starts with a dot.
lock_root :: proc(dir: string) -> (lock: Lock, ok: bool) {
	path := fmt.tprintf("%s/%s", dir, LOCK_FILE)
	for _ in 0 ..< ROOT_LOCK_ATTEMPTS {
		result: Lock_Result
		lock, result = lock_file(path)
		switch result {
		case .Locked:
			return lock, true
		case .Failed:
			return {}, false
		case .Held:
			time.sleep(ROOT_LOCK_WAIT)
		}
	}
	log.errorf("cook: another cook is writing .meta files in %s", dir)
	return {}, false
}

// lock_roots takes every root's lock, in the roots' order, so two cooks that take several never wait for each other.
// On failure it holds none.
lock_roots :: proc(roots: []Root) -> (locks: []Lock, ok: bool) {
	locks = make([]Lock, len(roots), context.temp_allocator)
	for root, i in roots {
		if locks[i], ok = lock_root(root.dir); !ok {
			unlock_all(locks[:i])
			return nil, false
		}
	}
	return locks, true
}

unlock_all :: proc(locks: []Lock) {
	#reverse for &lock in locks {
		unlock(&lock)
	}
}

unlock :: proc(lock: ^Lock) {
	if lock.handle != nil {
		win.CloseHandle(lock.handle)
	}
	lock^ = {}
}

@(private = "file")
lock_file :: proc(path: string) -> (lock: Lock, result: Lock_Result) {
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
