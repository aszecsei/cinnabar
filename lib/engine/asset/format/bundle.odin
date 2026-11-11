package asset_format

import "core:mem"
import "core:slice"
import "core:strings"

import "cinnabar:core/layout"

// A bundle is one load unit's blobs in one file, `<name>.cbb`: a head, then each blob at BLOB_ALIGN, on its own
// compressed or as it is (see docs/content/blobs-and-loading.md#bundles). The runtime reads the head when it opens the
// bundle, and a blob when it loads the blob's asset.
BUNDLE_EXTENSION :: ".cbb"
// The bundle that every other bundle depends on: what more than one level uses, and what no level names.
GLOBAL_BUNDLE :: "global"
// The longest name of a bundle: GLOBAL_BUNDLE, or a level's scene's GUID in hex.
BUNDLE_MAX_NAME :: 32

// The project settings' key of the scenes that are not levels, as GUIDs between commas: the package step puts them,
// and what only they use, in the global bundle, as it does what no level names.
BUNDLE_GLOBAL_SCENES_KEY :: "bundles.global_scenes"

// bundle_parse_scenes parses the value of BUNDLE_GLOBAL_SCENES_KEY: GUIDs between commas, or nothing.
bundle_parse_scenes :: proc(value: string, allocator := context.allocator) -> (scenes: []Guid, ok: bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" {
		return nil, true
	}
	parts := strings.split(trimmed, ",", context.temp_allocator)
	scenes = make([]Guid, len(parts), allocator)
	for part, i in parts {
		guid, parsed := guid_parse(strings.trim_space(part))
		if !parsed {
			delete(scenes, allocator)
			return nil, false
		}
		scenes[i] = guid
	}
	return scenes, true
}

// "CBB1" in a little-endian u32.
BUNDLE_MAGIC :: 0x31424243

// Bundle_Codec is how a blob is stored in a bundle.
Bundle_Codec :: enum u32 {
	// As it is, so that what reads a range of the blob, such as a stream or a mesh's pages, reads it from the bundle.
	None,
	// One LZ4 block.
	Lz4,
}

// Bundle_Header starts a bundle. Everything up to head_size is the head, which the entries and the dependencies are in.
Bundle_Header :: struct {
	magic:        u32,
	head_size:    u32,
	layout:       u64,
	// The whole file's size, so that a bundle that was cut short is refused when it opens.
	file_size:    u64,
	// Bundle_Entry records, sorted by GUID.
	entries:      Slice,
	// Slices of the names of the bundles that this one depends on, without the extension, which open first.
	dependencies: Slice,
}

// Bundle_Entry is one blob of a bundle. stored_size is the size in the file, and size the blob's.
Bundle_Entry :: struct {
	guid:        Guid,
	kind:        Asset_Kind,
	codec:       Bundle_Codec,
	stored_size: u32,
	size:        u32,
	// From the file's start, at BLOB_ALIGN.
	offset:      u64,
}

bundle_layout :: proc() -> u64 {
	return layout.hash(Bundle_Header) ~ layout.hash(Bundle_Entry) * 31
}

// guid_compare orders GUIDs by their bytes, which is the order of their hex.
guid_compare :: proc "contextless" (a, b: Guid) -> slice.Ordering {
	for i in 0 ..< len(Guid) {
		if a[i] != b[i] {
			return .Less if a[i] < b[i] else .Greater
		}
	}
	return .Equal
}

guid_less :: proc(a, b: Guid) -> bool {
	return guid_compare(a, b) == .Less
}

// bundle_head_size is the size of a bundle's head from its header's bytes, or 0 if they do not start a bundle of this
// build's layout.
bundle_head_size :: proc(start: []byte) -> int {
	if len(start) < size_of(Bundle_Header) {
		return 0
	}
	header := (^Bundle_Header)(raw_data(start))
	if header.magic != BUNDLE_MAGIC || header.layout != bundle_layout() || header.head_size < size_of(Bundle_Header) {
		return 0
	}
	return int(header.head_size)
}

// bundle_view checks a bundle's head against the size of its file: its header, that its entries are sorted, aligned and
// inside the file, and that its dependencies' names are inside the head.
bundle_view :: proc(head: []byte, file_size: i64) -> (header: ^Bundle_Header, entries: []Bundle_Entry, ok: bool) {
	size := bundle_head_size(head)
	if size == 0 || size != len(head) || uintptr(raw_data(head)) % align_of(Bundle_Header) != 0 {
		return
	}
	header = (^Bundle_Header)(raw_data(head))
	if header.file_size != u64(file_size) || u64(header.head_size) > header.file_size {
		return nil, nil, false
	}
	inside :: proc(head: []byte, s: Slice, $T: typeid) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(head)) && s.size % size_of(T) == 0 && s.offset % align_of(T) == 0
	}
	if !inside(head, header.entries, Bundle_Entry) || !inside(head, header.dependencies, Slice) {
		return nil, nil, false
	}
	entries = bundle_entries(head, header)
	for e, i in entries {
		if i > 0 && guid_compare(entries[i - 1].guid, e.guid) != .Less {
			return nil, nil, false
		}
		if e.offset % BLOB_ALIGN != 0 || e.offset < u64(header.head_size) || e.offset + u64(e.stored_size) > header.file_size {
			return nil, nil, false
		}
		if e.codec > max(Bundle_Codec) || (e.codec == .None && e.stored_size != e.size) {
			return nil, nil, false
		}
	}
	for d in bundle_dependency_slices(head, header) {
		if u64(d.offset) + u64(d.size) > u64(len(head)) || d.size == 0 || d.size > BUNDLE_MAX_NAME {
			return nil, nil, false
		}
	}
	return header, entries, true
}

bundle_entries :: proc "contextless" (head: []byte, header: ^Bundle_Header) -> []Bundle_Entry {
	bytes := blob_bytes(head, header.entries)
	return ([^]Bundle_Entry)(raw_data(bytes))[:len(bytes) / size_of(Bundle_Entry)]
}

@(private = "file")
bundle_dependency_slices :: proc "contextless" (head: []byte, header: ^Bundle_Header) -> []Slice {
	bytes := blob_bytes(head, header.dependencies)
	return ([^]Slice)(raw_data(bytes))[:len(bytes) / size_of(Slice)]
}

// bundle_dependency is the name of a bundle's dependency, which points into its head.
bundle_dependency :: proc "contextless" (head: []byte, header: ^Bundle_Header, index: int) -> string {
	return blob_string(head, bundle_dependency_slices(head, header)[index])
}

bundle_dependency_count :: proc "contextless" (header: ^Bundle_Header) -> int {
	return int(header.dependencies.size / size_of(Slice))
}

// bundle_find is the entry of a GUID, by binary search.
bundle_find :: proc(entries: []Bundle_Entry, guid: Guid) -> (entry: Bundle_Entry, found: bool) {
	index := slice.binary_search_by(entries, guid, proc(e: Bundle_Entry, guid: Guid) -> slice.Ordering {
		return guid_compare(e.guid, guid)
	}) or_return
	return entries[index], true
}

// Bundle_Blob is a blob as bundle_write takes it: stored is its bytes as codec stores them, and size the blob's size.
Bundle_Blob :: struct {
	guid:   Guid,
	kind:   Asset_Kind,
	codec:  Bundle_Codec,
	size:   u32,
	stored: []byte,
}

// bundle_write builds a bundle of blobs, in any order, that depends on the bundles that dependencies names.
bundle_write :: proc(blobs: []Bundle_Blob, dependencies: []string, allocator := context.allocator) -> []byte {
	sorted := slice.clone(blobs, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Bundle_Blob) -> bool {
		return guid_less(a.guid, b.guid)
	})
	buffer := make([dynamic]byte, size_of(Bundle_Header), allocator)
	entries := reserve_bytes(&buffer, len(sorted) * size_of(Bundle_Entry), align_of(Bundle_Entry))
	names := reserve_bytes(&buffer, len(dependencies) * size_of(Slice), align_of(Slice))
	for d, i in dependencies {
		name := append_bytes(&buffer, transmute([]byte)d)
		mem.copy(&buffer[names.offset + u32(i * size_of(Slice))], &name, size_of(name))
	}
	head_size := u32(len(buffer))
	for b, i in sorted {
		offset := mem.align_forward_int(len(buffer), BLOB_ALIGN)
		resize(&buffer, offset + len(b.stored))
		copy(buffer[offset:], b.stored)
		entry := Bundle_Entry {
			guid        = b.guid,
			kind        = b.kind,
			codec       = b.codec,
			stored_size = u32(len(b.stored)),
			size        = b.size,
			offset      = u64(offset),
		}
		mem.copy(&buffer[entries.offset + u32(i * size_of(Bundle_Entry))], &entry, size_of(entry))
	}
	header := Bundle_Header {
		magic        = BUNDLE_MAGIC,
		head_size    = head_size,
		layout       = bundle_layout(),
		file_size    = u64(len(buffer)),
		entries      = entries,
		dependencies = names,
	}
	mem.copy(raw_data(buffer), &header, size_of(header))
	return buffer[:]
}
