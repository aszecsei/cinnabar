package asset_format

import "core:mem"

import "cinnabar:core/layout"

SHADER_EXTENSION :: ".hlsl"

// Shader_Stage is the stage of an entry of a shader blob. A ray tracing library has one Library entry.
Shader_Stage :: enum u32 {
	Vertex,
	Pixel,
	Compute,
	Amplification,
	Mesh,
	Library,
}

Shader_Stages :: bit_set[Shader_Stage;u32]

// Shader_Target is the bytecode of an entry. A port adds its target as more entries in the same blob.
Shader_Target :: enum u32 {
	DXIL,
}

// Shader_Blob is the start of a shader blob (see docs/content/blobs-and-loading.md#blob-format).
Shader_Blob :: struct {
	header:      Blob_Header,
	// Shader_Entry records, sorted by stage and then target.
	entries:     Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/shaders/post.hlsl".
	source_path: Slice,
}

Shader_Entry :: struct {
	stage:  Shader_Stage,
	target: Shader_Target,
	code:   Slice,
}

shader_layout :: proc() -> u64 {
	return layout.hash(Shader_Blob) ~ layout.hash(Shader_Entry) * 31
}

// shader_view checks a shader blob: its header, its layout and that every slice is inside it.
shader_view :: proc(data: []byte) -> (blob: ^Shader_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Shader || header.layout != shader_layout() || len(data) < size_of(Shader_Blob) {
		return
	}
	blob = (^Shader_Blob)(raw_data(data))
	for s in ([?]Slice{blob.entries, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.entries.size % size_of(Shader_Entry) != 0 || blob.entries.offset % align_of(Shader_Entry) != 0 {
		return nil, false
	}
	for e in shader_entries(data, blob) {
		if u64(e.code.offset) + u64(e.code.size) > u64(len(data)) {
			return nil, false
		}
	}
	return blob, true
}

shader_entries :: proc "contextless" (data: []byte, blob: ^Shader_Blob) -> []Shader_Entry {
	bytes := blob_bytes(data, blob.entries)
	return ([^]Shader_Entry)(raw_data(bytes))[:len(bytes) / size_of(Shader_Entry)]
}

// shader_code is the bytecode of a stage for a target, or nil if the blob has no such entry.
shader_code :: proc "contextless" (data: []byte, blob: ^Shader_Blob, stage: Shader_Stage, target := Shader_Target.DXIL) -> []byte {
	for e in shader_entries(data, blob) {
		if e.stage == stage && e.target == target {
			return blob_bytes(data, e.code)
		}
	}
	return nil
}

// shader_stages is the stages that the blob has for a target.
shader_stages :: proc "contextless" (data: []byte, blob: ^Shader_Blob, target := Shader_Target.DXIL) -> (stages: Shader_Stages) {
	for e in shader_entries(data, blob) {
		if e.target == target {
			stages += {e.stage}
		}
	}
	return
}

Shader_Code :: struct {
	stage:  Shader_Stage,
	target: Shader_Target,
	code:   []byte,
}

Shader_Contents :: struct {
	guid:        Guid,
	key:         u64,
	// Sorted by stage and then target.
	entries:     []Shader_Code,
	source_path: string,
}

// shader_write builds a shader blob. Each entry's bytecode starts at BLOB_ALIGN.
shader_write :: proc(contents: Shader_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Shader_Blob), allocator)
	entries := reserve_bytes(&buffer, len(contents.entries) * size_of(Shader_Entry), align_of(Shader_Entry))
	for e, i in contents.entries {
		code := reserve_bytes(&buffer, len(e.code), BLOB_ALIGN)
		copy(buffer[code.offset:], e.code)
		record := Shader_Entry{e.stage, e.target, code}
		mem.copy(&buffer[entries.offset + u32(i * size_of(Shader_Entry))], &record, size_of(record))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Shader_Blob {
		header = {magic = BLOB_MAGIC, kind = .Shader, layout = shader_layout(), key = contents.key, guid = contents.guid},
		entries = entries,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
