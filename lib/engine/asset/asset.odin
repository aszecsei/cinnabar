// Package asset is the asset runtime: it loads cooked blobs by GUID and keeps them behind generational handles. In
// development it reloads the blobs that a cook writes again. See docs/content/blobs-and-loading.md#loading.
package asset

import "core:fmt"
import "core:log"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/lz4"
import "cinnabar:core/profile"
import format "cinnabar:engine/asset/format"

MAX_ASSETS :: 4096
MAX_PATH :: 260
MAX_BUNDLES :: 64

// BUNDLES is true in a release build, whose content is bundles: content_source then gives the Bundle source.
BUNDLES :: #config(BUNDLES, false)

// Handle is a loaded asset, which every user of the asset shares. The zero handle is no asset, and a handle to an
// unloaded asset is detected.
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

// Bundle reads blobs from the bundles in a directory, <dir>/<name>.cbb (see docs/content/blobs-and-loading.md#bundles).
// It is the release source. init opens the global bundle, and load opens a level's bundle, <scene guid>.cbb, when it
// loads the scene. A bundle opens after the bundles that it depends on, and stays open for the session.
Bundle :: struct {
	dir:     [MAX_PATH]u8,
	dir_len: int,
	// In the order that they opened, so each after its dependencies.
	open:    [MAX_BUNDLES]Open_Bundle,
	count:   int,
}

// Open_Bundle is a bundle's head, in the asset allocator, and its entries, which point into it.
Open_Bundle :: struct {
	name:     [format.BUNDLE_MAX_NAME]u8,
	name_len: int,
	// The file's modification time when it opened, which every blob read from it has.
	modified: i64,
	head:     []byte,
	entries:  []format.Bundle_Entry,
}

// Source is where blobs come from. A union, so it holds no procedure pointers into the DLL image.
Source :: union {
	Loose_Cache,
	Bundle,
}

loose_cache :: proc(dir: string) -> Source {
	cache: Loose_Cache
	if len(dir) > MAX_PATH {
		log.panicf("asset: the cache path %q is too long", dir)
	}
	cache.dir_len = copy(cache.dir[:], dir)
	return cache
}

bundle :: proc(dir: string) -> Source {
	b: Bundle
	if len(dir) > MAX_PATH {
		log.panicf("asset: the bundles' path %q is too long", dir)
	}
	b.dir_len = copy(b.dir[:], dir)
	return b
}

// content_source is a game's source for its content directory: its bundles in a release build, and the loose cache
// otherwise.
content_source :: proc(dir: string) -> Source {
	return bundle(dir) when BUNDLES else loose_cache(dir)
}

@(private)
Record :: struct {
	guid:       format.Guid,
	// Even while the record is free, odd while it holds an asset, so the zero handle never matches.
	generation: u32,
	// 1 when loaded, and increments every time the blob is swapped, so 0 is no asset.
	version:    u32,
	// The loads that are not unloaded. At max(u32) it stays, and the asset stays loaded.
	users:      u32,
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
	switch &source in a.source {
	case Loose_Cache:
		a.cache_generation = platform.file_modified(generation_path(a))
	case Bundle:
		source.count = 0
		open_bundle(a, format.GLOBAL_BUNDLE)
	}
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
	if source, is_bundle := &a.source.(Bundle); is_bundle {
		for &b in source.open[:source.count] {
			delete(b.head, a.platform.asset_allocator)
		}
		source.count = 0
	}
}

// load returns the handle of a loaded asset, and otherwise reads its blob. Each load adds a user, which unload
// removes. Code that keeps the asset for the session need not unload it. It fails if the blob is missing or is not
// a blob for this GUID.
load :: proc(a: ^Assets, guid: format.Guid) -> (h: Handle, ok: bool) {
	if found, loaded := find(a, guid); loaded {
		r := &a.records[found.index]
		if r.users < max(u32) {
			r.users += 1
		}
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
		version    = 1,
		users      = 1,
		kind       = header.kind,
		data       = data,
		modified   = modified,
	}
	a.used = max(a.used, index + 1)
	return {index, r.generation}, true
}

// find is the handle of an asset, if it is loaded. It adds no user, so do not unload what it gives.
find :: proc(a: ^Assets, guid: format.Guid) -> (h: Handle, loaded: bool) {
	for &r, i in a.records[:a.used] {
		if r.generation % 2 == 1 && r.guid == guid {
			return {u32(i), r.generation}, true
		}
	}
	return
}

// unload removes a user that load added, and frees the asset when it removes the last.
unload :: proc(a: ^Assets, h: Handle) {
	r := record(a, h)
	if r == nil || r.users == max(u32) {
		return
	}
	r.users -= 1
	if r.users == 0 {
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

// version is 1 when the asset loads, and increments each time poll swaps its blob. It is 0 for a handle to no asset.
version :: proc(a: ^Assets, h: Handle) -> u32 {
	r := record(a, h)
	return r.version if r != nil else 0
}

guid :: proc(a: ^Assets, h: Handle) -> format.Guid {
	r := record(a, h)
	return r.guid if r != nil else {}
}

// current is whether poll has seen the cooker's last write, so that what is loaded is what the index says is cooked.
// Bundles do not change, so they are always current.
current :: proc(a: ^Assets) -> bool {
	if _, is_cache := a.source.(Loose_Cache); !is_cache {
		return true
	}
	return a.platform.file_modified(generation_path(a)) == a.cache_generation
}

// poll swaps the blobs that the cooker has written again, and returns their handles in frame memory. Call it at the
// end of the frame, when nothing holds a blob. It checks the blobs only when the cache's generation file changes,
// which a cook writes after all of its blobs, so every blob of one cook is swapped in the same frame. Bundles do not
// change, so with them it returns nothing: hot reload is development's, from the loose cache.
poll :: proc(a: ^Assets) -> []Handle {
	profile.scope_text(&a.platform.profile, "Assets poll", .Asset)
	if _, is_cache := a.source.(Loose_Cache); !is_cache {
		return nil
	}
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
		path := loose_path(a, r.guid)
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

// preview_blob reads a material's blob from the preview area of the cache, <dir>/preview/<guid>.blob, where the cook
// daemon cooks the editor's unsaved materials (see docs/rendering/materials.md#material-previews), if it is newer than modified.
// The data is in the asset allocator, and the caller frees it. Bundles have no previews.
preview_blob :: proc(a: ^Assets, guid: format.Guid, modified: i64) -> (data: []byte, newer: i64, changed: bool) {
	buffer: [32]u8
	path: string
	switch &source in a.source {
	case Loose_Cache:
		path = fmt.aprintf("%s/preview/%s.blob", string(source.dir[:source.dir_len]), format.guid_format(guid, &buffer), allocator = a.platform.frame_allocator)
	case Bundle:
		return nil, modified, false
	}
	newer = a.platform.file_modified(path)
	if newer == 0 || newer == modified {
		return nil, modified, false
	}
	data = a.platform.file_read(path, format.BLOB_ALIGN, a.platform.asset_allocator) or_else nil
	header, valid := format.blob_header(data)
	if data == nil || !valid || header.guid != guid {
		if data != nil {
			delete(data, a.platform.asset_allocator)
		}
		return nil, modified, false
	}
	return data, newer, true
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

// Blob_Location is where an asset's blob is, for what reads a blob itself, such as a stream or a mesh's pages: the file,
// in frame memory, and the blob's offset in it. raw is whether the file holds the blob's bytes as they are, so that a
// range of the blob is the same range of the file from offset. A blob that a bundle compresses is not raw.
Blob_Location :: struct {
	path:   string,
	offset: i64,
	raw:    bool,
}

// blob_location is where an asset's blob is: its file in the loose cache, or the open bundle that has it. ok is false
// for a GUID that no open bundle has.
blob_location :: proc(a: ^Assets, guid: format.Guid) -> (location: Blob_Location, ok: bool) {
	switch &source in a.source {
	case Loose_Cache:
		return {path = loose_path(a, guid), raw = true}, true
	case Bundle:
		b, entry := bundle_entry(&source, guid) or_return
		return {path = bundle_path(a, &source, string(b.name[:b.name_len])), offset = i64(entry.offset), raw = entry.codec == .None}, true
	}
	return
}

// read reads an asset's blob without loading the asset, as load does: a paged mesh's head, and the whole of any other
// blob. The data is in the asset allocator, and the caller frees it.
read :: proc(a: ^Assets, guid: format.Guid) -> (data: []byte, modified: i64, ok: bool) {
	return read_blob(a, guid)
}

@(private)
loose_path :: proc(a: ^Assets, guid: format.Guid) -> string {
	buffer: [32]u8
	source := &a.source.(Loose_Cache)
	return fmt.aprintf("%s/%s.blob", string(source.dir[:source.dir_len]), format.guid_format(guid, &buffer), allocator = a.platform.frame_allocator)
}

@(private)
generation_path :: proc(a: ^Assets) -> string {
	source := &a.source.(Loose_Cache)
	return fmt.aprintf("%s/%s", string(source.dir[:source.dir_len]), format.GENERATION_FILE, allocator = a.platform.frame_allocator)
}

@(private)
bundle_path :: proc(a: ^Assets, source: ^Bundle, name: string) -> string {
	return fmt.aprintf("%s/%s%s", string(source.dir[:source.dir_len]), name, format.BUNDLE_EXTENSION, allocator = a.platform.frame_allocator)
}

// bundle_entry is the open bundle that has a GUID, and its entry, by a binary search of each bundle's table.
@(private)
bundle_entry :: proc(source: ^Bundle, guid: format.Guid) -> (b: ^Open_Bundle, entry: format.Bundle_Entry, found: bool) {
	for &open in source.open[:source.count] {
		if e, in_bundle := format.bundle_find(open.entries, guid); in_bundle {
			return &open, e, true
		}
	}
	return
}

// open_bundle opens the bundle <dir>/<name>.cbb after the bundles that it depends on, and reads its head. A bundle that
// is open already stays as it is. It fails, and logs why, if the bundle or a dependency is missing or does not check, or
// if the bundles would be more than MAX_BUNDLES.
open_bundle :: proc(a: ^Assets, name: string) -> bool {
	source, is_bundle := &a.source.(Bundle)
	return is_bundle && open_bundle_at(a, source, name, 0)
}

@(private)
open_bundle_at :: proc(a: ^Assets, source: ^Bundle, name: string, depth: int) -> bool {
	for &b in source.open[:source.count] {
		if string(b.name[:b.name_len]) == name {
			return true
		}
	}
	if len(name) > format.BUNDLE_MAX_NAME || depth > MAX_BUNDLES {
		log.errorf("asset: the bundle %q has a name that is too long, or depends on itself", name)
		return false
	}
	path := bundle_path(a, source, name)
	modified := a.platform.file_modified(path)
	Start :: struct #align (format.BLOB_ALIGN) {
		bytes: [size_of(format.Bundle_Header)]byte,
	}
	start: Start
	if modified == 0 || a.platform.file_read_range(path, 0, start.bytes[:]) != len(start.bytes) {
		log.errorf("asset: no bundle at %s. Package the content.", path)
		return false
	}
	size := format.bundle_head_size(start.bytes[:])
	if size == 0 {
		log.errorf("asset: %s is not a bundle of this build's layout. Package the content.", path)
		return false
	}
	head, err := mem.alloc_bytes_non_zeroed(size, format.BLOB_ALIGN, a.platform.asset_allocator)
	if err != nil {
		return false
	}
	// The header gives the file's size. The file is whole if it has a byte at the size's end and none past it.
	file_size := i64(-1)
	if a.platform.file_read_range(path, 0, head) == size {
		end := i64((^format.Bundle_Header)(raw_data(head)).file_size)
		last: [1]byte
		if a.platform.file_read_range(path, end - 1, last[:]) == 1 && a.platform.file_read_range(path, end, last[:]) == 0 {
			file_size = end
		}
	}
	header, entries, valid := format.bundle_view(head, file_size)
	if !valid {
		log.errorf("asset: %s is cut short, or is not a bundle. Package the content.", path)
		delete(head, a.platform.asset_allocator)
		return false
	}
	for i in 0 ..< format.bundle_dependency_count(header) {
		if !open_bundle_at(a, source, format.bundle_dependency(head, header, i), depth + 1) {
			delete(head, a.platform.asset_allocator)
			return false
		}
	}
	if source.count == MAX_BUNDLES {
		log.errorf("asset: more than %d bundles", MAX_BUNDLES)
		delete(head, a.platform.asset_allocator)
		return false
	}
	b := &source.open[source.count]
	b^ = {modified = modified, head = head, entries = entries}
	b.name_len = copy(b.name[:], name)
	source.count += 1
	return true
}

// modified is the modification time of the blob that an asset's data was read from, or 0 for no asset. What reads more
// of the blob's file later, as the renderer reads a mesh's pages, compares the file's time with it.
modified :: proc(a: ^Assets, h: Handle) -> i64 {
	r := record(a, h)
	return r != nil ? r.modified : 0
}

// read_head reads a paged mesh's head from its blob at offset in a file: the blob without the pages that stream (see
// docs/content/blobs-and-loading.md#loading). It gives nil for any other blob, and for a platform without ranged reads.
@(private)
read_head :: proc(a: ^Assets, path: string, offset: i64) -> []byte {
	if a.platform.file_read_range == nil {
		return nil
	}
	Start :: struct #align (format.BLOB_ALIGN) {
		bytes: [size_of(format.Mesh_Blob)]byte,
	}
	start: Start
	if a.platform.file_read_range(path, offset, start.bytes[:]) != len(start.bytes) {
		return nil
	}
	size := format.mesh_head_size(start.bytes[:])
	if size == 0 {
		return nil
	}
	head, err := mem.alloc_bytes_non_zeroed(size, format.BLOB_ALIGN, a.platform.asset_allocator)
	if err != nil {
		return nil
	}
	if a.platform.file_read_range(path, offset, head) != size {
		delete(head, a.platform.asset_allocator)
		return nil
	}
	return head
}

// read_blob reads and checks a blob: a paged mesh's head, and the whole of any other. The modification time is read
// first, so a blob that changes during the read is read again at the next poll.
@(private)
read_blob :: proc(a: ^Assets, guid: format.Guid) -> (data: []byte, modified: i64, ok: bool) {
	path: string
	switch &source in a.source {
	case Loose_Cache:
		path = loose_path(a, guid)
		modified = a.platform.file_modified(path)
		data = read_head(a, path, 0)
		if data == nil {
			data = a.platform.file_read(path, format.BLOB_ALIGN, a.platform.asset_allocator) or_else nil
		}
		if data == nil {
			buffer: [32]u8
			log.errorf("asset: no blob for %s at %s. Cook the content.", format.guid_format(guid, &buffer), path)
			return
		}
	case Bundle:
		data, modified, path = read_bundled(a, &source, guid) or_return
	case:
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

// read_bundled reads a blob from the open bundle that has it. A GUID that no open bundle has may be a level's scene, so
// it opens <guid>.cbb, if there is one, and looks again. A blob that the bundle stores as it is reads as a loose blob
// does, a paged mesh's head alone, and one that it compresses is decompressed into the asset allocator.
@(private)
read_bundled :: proc(a: ^Assets, source: ^Bundle, guid: format.Guid) -> (data: []byte, modified: i64, path: string, ok: bool) {
	buffer: [32]u8
	name := format.guid_format(guid, &buffer)
	b, entry, found := bundle_entry(source, guid)
	if !found && a.platform.file_modified(bundle_path(a, source, name)) != 0 && open_bundle_at(a, source, name, 0) {
		b, entry, found = bundle_entry(source, guid)
	}
	if !found {
		log.errorf("asset: no open bundle has %s. Cook and package the content.", name)
		return
	}
	path = bundle_path(a, source, string(b.name[:b.name_len]))
	switch entry.codec {
	case .None:
		if entry.kind == .Mesh {
			data = read_head(a, path, i64(entry.offset))
		}
		if data == nil {
			data = mem.alloc_bytes_non_zeroed(int(entry.size), format.BLOB_ALIGN, a.platform.asset_allocator) or_else nil
			if data != nil && a.platform.file_read_range(path, i64(entry.offset), data) != len(data) {
				delete(data, a.platform.asset_allocator)
				data = nil
			}
		}
	case .Lz4:
		stored := mem.alloc_bytes_non_zeroed(int(entry.stored_size), 1, a.platform.frame_allocator) or_else nil
		if stored == nil || a.platform.file_read_range(path, i64(entry.offset), stored) != len(stored) {
			break
		}
		data = mem.alloc_bytes_non_zeroed(int(entry.size), format.BLOB_ALIGN, a.platform.asset_allocator) or_else nil
		if data != nil && !lz4.decompress(stored, data) {
			delete(data, a.platform.asset_allocator)
			data = nil
		}
	}
	if data == nil {
		log.errorf("asset: cannot read %s from %s", name, path)
		return
	}
	return data, b.modified, path, true
}
