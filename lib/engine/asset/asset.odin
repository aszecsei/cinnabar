// Package asset is the asset runtime: it loads cooked blobs by GUID and keeps them behind generational handles. In
// development it reloads the blobs that a cook writes again. See docs/content-pipeline.md#loading.
package asset

import "core:fmt"
import "core:log"

import "cinnabar:core"
import format "cinnabar:engine/asset/format"

MAX_ASSETS :: 4096
MAX_PATH :: 260

// Handle is a loaded asset. The zero handle is no asset, and a handle to an unloaded asset is detected.
Handle :: struct {
	index:      u32,
	generation: u32,
}

// Loose_Cache reads blobs from the cooker's cache directory, <dir>/<guid>.blob. It is the development source.
Loose_Cache :: struct {
	// The directory, copied in, so that no string points into the DLL image.
	dir:     [MAX_PATH]u8,
	dir_len: int,
}

// Source is where blobs come from. A union, so it holds no procedure pointers into the DLL image. Bundles are added
// with the package step.
Source :: union {
	Loose_Cache,
}

loose_cache :: proc(dir: string) -> Source {
	cache: Loose_Cache
	if len(dir) > MAX_PATH {
		log.panicf("asset: the cache path %q is too long", dir)
	}
	cache.dir_len = copy(cache.dir[:], dir)
	return cache
}

@(private)
Record :: struct {
	guid:       format.Guid,
	// Even while the record is free, odd while it holds an asset, so the zero handle never matches.
	generation: u32,
	// Increments every time the blob is swapped.
	version:    u32,
	kind:       format.Asset_Kind,
	// The blob, in the platform's asset allocator, at format.BLOB_ALIGN.
	data:       []byte,
	// The source's modification time, to detect a new blob.
	modified:   i64,
}

// Assets lives in Game_State. It holds no pointers into the DLL image, so it survives code reload.
Assets :: struct {
	platform:  ^core.Platform_API,
	source:    Source,
	records:   [MAX_ASSETS]Record,
	// Records below this index have been used.
	used:             u32,
	// The modification time of the cache's generation file when poll last checked the blobs.
	cache_generation: i64,
}

init :: proc(a: ^Assets, platform: ^core.Platform_API, source: Source) {
	a.platform = platform
	a.source = source
	a.used = 0
	a.cache_generation = platform.file_modified(generation_path(a))
}

// reload keeps every loaded asset after a code reload.
reload :: proc(a: ^Assets, platform: ^core.Platform_API) {
	a.platform = platform
}

// destroy unloads every asset.
destroy :: proc(a: ^Assets) {
	for &r in a.records[:a.used] {
		free_data(a, &r)
	}
	a.used = 0
}

// load returns the handle of a loaded asset, and otherwise reads its blob. It fails if the blob is missing or is not
// a blob for this GUID.
load :: proc(a: ^Assets, guid: format.Guid) -> (h: Handle, ok: bool) {
	if found, loaded := find(a, guid); loaded {
		return found, true
	}
	index := u32(0)
	for index < a.used && a.records[index].generation % 2 == 1 {
		index += 1
	}
	if index == MAX_ASSETS {
		log.errorf("asset: more than %d assets", MAX_ASSETS)
		return
	}
	data, modified := read_blob(a, guid) or_return
	header, _ := format.blob_header(data)
	r := &a.records[index]
	r^ = {
		guid       = guid,
		generation = r.generation + 1,
		kind       = header.kind,
		data       = data,
		modified   = modified,
	}
	a.used = max(a.used, index + 1)
	return {index, r.generation}, true
}

// find is the handle of an asset, if it is loaded.
find :: proc(a: ^Assets, guid: format.Guid) -> (h: Handle, loaded: bool) {
	for &r, i in a.records[:a.used] {
		if r.generation % 2 == 1 && r.guid == guid {
			return {u32(i), r.generation}, true
		}
	}
	return
}

unload :: proc(a: ^Assets, h: Handle) {
	if r := record(a, h); r != nil {
		free_data(a, r)
		r.generation += 1
	}
}

// data is an asset's blob. It stays valid until poll swaps the blob or the asset is unloaded, so do not keep it
// across frames.
data :: proc(a: ^Assets, h: Handle) -> (blob: []byte, ok: bool) {
	r := record(a, h)
	return r.data if r != nil else nil, r != nil
}

// version increments each time poll swaps the asset's blob.
version :: proc(a: ^Assets, h: Handle) -> u32 {
	r := record(a, h)
	return r.version if r != nil else 0
}

guid :: proc(a: ^Assets, h: Handle) -> format.Guid {
	r := record(a, h)
	return r.guid if r != nil else {}
}

// poll swaps the blobs that the cooker has written again, and returns their handles in frame memory. Call it at the
// end of the frame, when nothing holds a blob. It checks the blobs only when the cache's generation file changes,
// which a cook writes after all of its blobs, so every blob of one cook is swapped in the same frame.
poll :: proc(a: ^Assets) -> []Handle {
	generation := a.platform.file_modified(generation_path(a))
	if generation == a.cache_generation {
		return nil
	}
	a.cache_generation = generation
	changed := make([dynamic]Handle, a.platform.frame_allocator)
	for &r, i in a.records[:a.used] {
		if r.generation % 2 == 0 {
			continue
		}
		path := blob_path(a, r.guid)
		if modified := a.platform.file_modified(path); modified == 0 || modified == r.modified {
			continue
		}
		data, modified, ok := read_blob(a, r.guid)
		if !ok {
			// The old blob stays, and the next cook's generation tries again.
			continue
		}
		free_data(a, &r)
		r.data = data
		r.modified = modified
		r.version += 1
		append(&changed, Handle{u32(i), r.generation})
	}
	return changed[:]
}

@(private)
record :: proc(a: ^Assets, h: Handle) -> ^Record {
	if h.index >= a.used || a.records[h.index].generation != h.generation || h.generation % 2 == 0 {
		return nil
	}
	return &a.records[h.index]
}

@(private)
free_data :: proc(a: ^Assets, r: ^Record) {
	if r.data != nil {
		delete(r.data, a.platform.asset_allocator)
		r.data = nil
	}
}

@(private)
blob_path :: proc(a: ^Assets, guid: format.Guid) -> string {
	buffer: [32]u8
	switch &source in a.source {
	case Loose_Cache:
		return fmt.aprintf("%s/%s.blob", string(source.dir[:source.dir_len]), format.guid_format(guid, &buffer), allocator = a.platform.frame_allocator)
	}
	return ""
}

@(private)
generation_path :: proc(a: ^Assets) -> string {
	switch &source in a.source {
	case Loose_Cache:
		return fmt.aprintf("%s/%s", string(source.dir[:source.dir_len]), format.GENERATION_FILE, allocator = a.platform.frame_allocator)
	}
	return ""
}

// read_blob reads and checks a blob. The modification time is read first, so a blob that changes during the read
// is read again at the next poll.
@(private)
read_blob :: proc(a: ^Assets, guid: format.Guid) -> (data: []byte, modified: i64, ok: bool) {
	path := blob_path(a, guid)
	modified = a.platform.file_modified(path)
	data = a.platform.file_read(path, format.BLOB_ALIGN, a.platform.asset_allocator) or_else nil
	if data == nil {
		buffer: [32]u8
		log.errorf("asset: no blob for %s at %s. Cook the content.", format.guid_format(guid, &buffer), path)
		return
	}
	header, valid := format.blob_header(data)
	if !valid || header.guid != guid {
		log.errorf("asset: %s is not a cooked blob of its GUID", path)
		delete(data, a.platform.asset_allocator)
		return nil, 0, false
	}
	return data, modified, true
}
