// Package asset_format defines what tools/cook writes and the asset runtime reads: GUIDs, .meta files and blob
// layouts. It imports nothing from core, so the cooker can use it. See docs/content-pipeline.md.
package asset_format

import "core:mem"
import "core:strings"

import "cinnabar:core/layout"

// Guid identifies a source asset. Content refers to other content only by GUID.
Guid :: distinct [16]u8

// guid_parse reads the 32 hex digits that guid_format writes.
guid_parse :: proc "contextless" (text: string) -> (guid: Guid, ok: bool) {
	if len(text) != 2 * len(Guid) {
		return
	}
	for i in 0 ..< len(Guid) {
		high, high_ok := hex_digit(text[2 * i])
		low, low_ok := hex_digit(text[2 * i + 1])
		if !high_ok || !low_ok {
			return
		}
		guid[i] = high << 4 | low
	}
	return guid, true
}

// guid_format writes 32 lowercase hex digits into buffer.
guid_format :: proc "contextless" (guid: Guid, buffer: ^[2 * len(Guid)]u8) -> string {
	digits := "0123456789abcdef"
	for b, i in guid {
		buffer[2 * i] = digits[b >> 4]
		buffer[2 * i + 1] = digits[b & 0xf]
	}
	return string(buffer[:])
}

@(private = "file")
hex_digit :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

META_EXTENSION :: ".meta"

// Meta is a parsed .meta file: lines of `key = value`, with `#` comments. Every .meta has a guid. The other keys are
// the asset's import settings.
Meta :: struct {
	guid:     Guid,
	settings: []Meta_Setting,
}

Meta_Setting :: struct {
	key, value: string,
}

// meta_parse parses a .meta file. The settings point into text. It fails on a malformed line or a missing guid.
meta_parse :: proc(text: string, allocator := context.allocator) -> (meta: Meta, ok: bool) {
	settings := make([dynamic]Meta_Setting, allocator)
	has_guid := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 {
			delete(settings)
			return
		}
		key := strings.trim_space(trimmed[:equals])
		value := strings.trim_space(trimmed[equals + 1:])
		if key == "guid" {
			meta.guid, has_guid = guid_parse(value)
			if !has_guid {
				delete(settings)
				return
			}
		} else {
			append(&settings, Meta_Setting{key, value})
		}
	}
	if !has_guid {
		delete(settings)
		return
	}
	meta.settings = settings[:]
	return meta, true
}

meta_value :: proc(meta: Meta, key: string) -> (value: string, ok: bool) {
	for s in meta.settings {
		if s.key == key {
			return s.value, true
		}
	}
	return
}

// meta_guid is the GUID in a .meta file's text.
meta_guid :: proc(text: string) -> (Guid, bool) {
	meta, ok := meta_parse(text, context.temp_allocator)
	return meta.guid, ok
}

// script_mutable_globals lists the engine globals whose fields change while scripts run, such as Time.delta. In a
// sandbox, luau_load resolves a chain like Time.delta once and keeps the value, so every call of luau.compile passes
// these as mutableGlobals, which turns that off for them. The list ends with nil, as the compiler expects. Keep it in
// a local while the compiler runs.
script_mutable_globals :: proc "contextless" () -> [3]cstring {
	return {"Time", "Input", nil}
}

// "CNB1" in a little-endian u32.
BLOB_MAGIC :: 0x31424e43
// The runtime loads blobs at this alignment, so every structure in a blob is aligned to it at most.
BLOB_ALIGN :: 16

Asset_Kind :: enum u32 {
	None,
	Script,
}

// Slice is a range of a blob, in bytes from the blob's start.
Slice :: struct {
	offset, size: u32,
}

// Blob_Header starts every blob. layout is the layout hash of the kind's structures, so a blob from a cooker with
// other structures is rejected. key is the cache key that the blob was cooked with.
Blob_Header :: struct {
	magic:  u32,
	kind:   Asset_Kind,
	layout: u64,
	key:    u64,
	guid:   Guid,
}

Script_Flag :: enum u32 {
	// Compile to machine code at load.
	Native,
	// The module returns a behaviour class, and fields holds its schema.
	Behaviour,
}

Script_Flags :: bit_set[Script_Flag; u32]

// Script_Blob is the start of a script blob (see docs/content-pipeline.md#blob-format).
Script_Blob :: struct {
	header:      Blob_Header,
	flags:       Script_Flags,
	bytecode:    Slice,
	// Script_Require records, sorted by path.
	requires:    Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/scripts/hello.luau".
	source_path: Slice,
	// The behaviour's field schema. Empty until behaviours exist.
	fields:      Slice,
}

// Script_Require maps a require string to the module it resolves to.
Script_Require :: struct {
	path:   Slice,
	target: Guid,
}

script_layout :: proc() -> u64 {
	return layout.hash(Script_Blob) ~ layout.hash(Script_Require) * 31
}

blob_bytes :: proc "contextless" (data: []byte, s: Slice) -> []byte {
	return data[s.offset:][:s.size]
}

blob_string :: proc "contextless" (data: []byte, s: Slice) -> string {
	return string(blob_bytes(data, s))
}

blob_header :: proc "contextless" (data: []byte) -> (^Blob_Header, bool) {
	if len(data) < size_of(Blob_Header) || uintptr(raw_data(data)) % align_of(Script_Blob) != 0 {
		return nil, false
	}
	header := (^Blob_Header)(raw_data(data))
	return header, header.magic == BLOB_MAGIC
}

// script_view checks a script blob: its header, its layout and that every slice is inside it.
script_view :: proc(data: []byte) -> (blob: ^Script_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Script || header.layout != script_layout() || len(data) < size_of(Script_Blob) {
		return
	}
	blob = (^Script_Blob)(raw_data(data))
	slices := [?]Slice{blob.bytecode, blob.requires, blob.source_path, blob.fields}
	for s in slices {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.requires.size % size_of(Script_Require) != 0 || blob.requires.offset % align_of(Script_Require) != 0 {
		return nil, false
	}
	for r in script_requires(data, blob) {
		if u64(r.path.offset) + u64(r.path.size) > u64(len(data)) {
			return nil, false
		}
	}
	return blob, true
}

script_requires :: proc "contextless" (data: []byte, blob: ^Script_Blob) -> []Script_Require {
	bytes := blob_bytes(data, blob.requires)
	return ([^]Script_Require)(raw_data(bytes))[:len(bytes) / size_of(Script_Require)]
}

// script_find_require is the module that a require string resolves to.
script_find_require :: proc(data: []byte, blob: ^Script_Blob, path: string) -> (target: Guid, ok: bool) {
	requires := script_requires(data, blob)
	low, high := 0, len(requires)
	for low < high {
		mid := (low + high) / 2
		switch name := blob_string(data, requires[mid].path); {
		case name == path:
			return requires[mid].target, true
		case name < path:
			low = mid + 1
		case:
			high = mid
		}
	}
	return
}

Require_Entry :: struct {
	path:   string,
	target: Guid,
}

Script_Contents :: struct {
	guid:        Guid,
	key:         u64,
	flags:       Script_Flags,
	bytecode:    []byte,
	// Sorted by path.
	requires:    []Require_Entry,
	source_path: string,
}

// script_write builds a script blob.
script_write :: proc(contents: Script_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Script_Blob), allocator)
	requires := reserve_bytes(&buffer, len(contents.requires) * size_of(Script_Require), align_of(Script_Require))
	bytecode := append_bytes(&buffer, contents.bytecode)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	for r, i in contents.requires {
		path := append_bytes(&buffer, transmute([]byte)r.path)
		record := Script_Require{path, r.target}
		mem.copy(&buffer[requires.offset + u32(i * size_of(Script_Require))], &record, size_of(record))
	}
	blob := Script_Blob {
		header = {magic = BLOB_MAGIC, kind = .Script, layout = script_layout(), key = contents.key, guid = contents.guid},
		flags = contents.flags,
		bytecode = bytecode,
		requires = requires,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

@(private = "file")
reserve_bytes :: proc(buffer: ^[dynamic]byte, size, align: int) -> Slice {
	offset := mem.align_forward_int(len(buffer), align)
	resize(buffer, offset + size)
	return {u32(offset), u32(size)}
}

@(private = "file")
append_bytes :: proc(buffer: ^[dynamic]byte, data: []byte) -> Slice {
	s := reserve_bytes(buffer, len(data), 1)
	copy(buffer[s.offset:], data)
	return s
}
