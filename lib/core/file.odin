package core

import "base:runtime"
import "core:mem"
import "core:os"
import "core:time"

// file_read reads a whole file into memory from allocator, at the given alignment.
file_read :: proc(path: string, align: int, allocator: runtime.Allocator) -> (data: []byte, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return
	}
	defer os.close(f)
	size, size_err := os.file_size(f)
	if size_err != nil || size < 0 {
		return
	}
	buffer, alloc_err := mem.alloc_bytes_non_zeroed(int(size), align, allocator)
	if alloc_err != nil {
		return
	}
	read, read_err := os.read_full(f, buffer)
	if read_err != nil || read != int(size) {
		mem.free_bytes(buffer, allocator)
		return
	}
	return buffer, true
}

// file_modified is a file's modification time in nanoseconds since the Unix epoch, or 0 if it does not exist.
file_modified :: proc(path: string) -> i64 {
	modified, err := os.modification_time_by_path(path)
	return err == nil ? time.to_unix_nanoseconds(modified) : 0
}
