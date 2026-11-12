package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A perception is a .perception text file: the tags that an agent's Perceiver notices, and the rows that fill its
// blackboard's keys from what it perceives (see docs/content/kinds/perceptions.md). Tags are named in text; the runtime
// finds each name in the project's perception.tags.
PERCEPTION_EXTENSION :: ".perception"

// A perception has at most this many rows, and notices at most this many tags.
MAX_PERCEPTION_ROWS :: 32
MAX_PERCEPTION_NOTICES :: 32
// A row's of when it reads no other row.
PERCEPTION_NONE :: max(u32)

// Perception_Source is what a row writes into its key.
Perception_Source :: enum u32 {
	// An entity: the nearest remembered entity with the row's tag, those perceived now first.
	Nearest,
	// The same, among those seen now.
	Nearest_Seen,
	// The same, among those heard now.
	Nearest_Heard,
	// A position: the last known position of the entity that the Nearest row in of chose.
	Position,
	// A bool: whether that entity is seen now.
	Visible,
	// A float: the seconds since that entity was last perceived.
	Since,
	// A bool: whether a noise with the row's tag was heard in this tick.
	Heard_Noise,
	// A position: the loudest noise with the row's tag that was heard in this tick.
	Loudest_Noise,
}

// perception_source_type is the type of key that a source writes.
perception_source_type :: proc "contextless" (s: Perception_Source) -> Blackboard_Type {
	switch s {
	case .Nearest, .Nearest_Seen, .Nearest_Heard:
		return .Entity
	case .Position, .Loudest_Noise:
		return .Position
	case .Visible, .Heard_Noise:
		return .Bool
	case .Since:
		return .Float
	}
	return .Entity
}

// perception_source_chooses is whether a source chooses an entity, which other rows read.
perception_source_chooses :: proc "contextless" (s: Perception_Source) -> bool {
	return s == .Nearest || s == .Nearest_Seen || s == .Nearest_Heard
}

// perception_source_reads_row is whether a source reads the entity that another row chose.
perception_source_reads_row :: proc "contextless" (s: Perception_Source) -> bool {
	return s == .Position || s == .Visible || s == .Since
}

// Perception_Row fills a key: its name and animation_graph_hash, its source, the tag that it looks at, "" for any, and
// for a source that reads another row, that row's index, before its own.
Perception_Row :: struct {
	key:      Slice,
	key_hash: u32,
	source:   Perception_Source,
	tag:      Slice,
	tag_hash: u32,
	of:       u32,
}
#assert(size_of(Perception_Row) == 32)

// Perception_Blob is the start of a perception blob (see docs/content/blobs-and-loading.md#blob-format).
Perception_Blob :: struct {
	header:      Blob_Header,
	// Slice records, each a tag's name. None notices every tag.
	notices:     Slice,
	rows:        Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/ai/guard.perception".
	source_path: Slice,
}

perception_layout :: proc() -> u64 {
	return layout.hash(Perception_Blob) ~ layout.hash(Perception_Row) * 31
}

// perception_view checks a perception blob: its header, its layout, that its slices are inside it, and that each row's
// source is known and reads only a row before it that chooses an entity.
perception_view :: proc(data: []byte) -> (blob: ^Perception_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Perception || header.layout != perception_layout() || len(data) < size_of(Perception_Blob) {
		return
	}
	blob = (^Perception_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.notices, size_of(Slice), align_of(Slice)) ||
	   !inside(data, blob.rows, size_of(Perception_Row), align_of(Perception_Row)) ||
	   !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	notices := perception_notices(data, blob)
	rows := perception_rows(data, blob)
	if len(notices) > MAX_PERCEPTION_NOTICES || len(rows) > MAX_PERCEPTION_ROWS {
		return nil, false
	}
	for n in notices {
		if !inside(data, n, 1, 1) {
			return nil, false
		}
	}
	for r, i in rows {
		if r.source > .Loudest_Noise || !inside(data, r.key, 1, 1) || !inside(data, r.tag, 1, 1) {
			return nil, false
		}
		if perception_source_reads_row(r.source) {
			if r.of >= u32(i) || !perception_source_chooses(rows[r.of].source) {
				return nil, false
			}
		} else if r.of != PERCEPTION_NONE {
			return nil, false
		}
	}
	return blob, true
}

perception_notices :: proc "contextless" (data: []byte, blob: ^Perception_Blob) -> []Slice {
	bytes := blob_bytes(data, blob.notices)
	return ([^]Slice)(raw_data(bytes))[:len(bytes) / size_of(Slice)]
}

perception_rows :: proc "contextless" (data: []byte, blob: ^Perception_Blob) -> []Perception_Row {
	bytes := blob_bytes(data, blob.rows)
	return ([^]Perception_Row)(raw_data(bytes))[:len(bytes) / size_of(Perception_Row)]
}

// Perception_Row_Contents is a row as perception_write takes it. tag is "" for any, and of is PERCEPTION_NONE for a
// source that reads no other row.
Perception_Row_Contents :: struct {
	key:    string,
	source: Perception_Source,
	tag:    string,
	of:     u32,
}

Perception_Contents :: struct {
	guid:        Guid,
	key:         u64,
	notices:     []string,
	rows:        []Perception_Row_Contents,
	source_path: string,
}

// perception_write builds a perception blob.
perception_write :: proc(contents: Perception_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Perception_Blob), allocator)
	notices := reserve_bytes(&buffer, len(contents.notices) * size_of(Slice), align_of(Slice))
	rows := reserve_bytes(&buffer, len(contents.rows) * size_of(Perception_Row), align_of(Perception_Row))
	for n, i in contents.notices {
		s := append_bytes(&buffer, transmute([]byte)n)
		mem.copy(&buffer[int(notices.offset) + i * size_of(Slice)], &s, size_of(s))
	}
	for r, i in contents.rows {
		record := Perception_Row {
			key      = append_bytes(&buffer, transmute([]byte)r.key),
			key_hash = animation_graph_hash(r.key),
			source   = r.source,
			tag      = append_bytes(&buffer, transmute([]byte)r.tag),
			tag_hash = animation_graph_hash(r.tag) if r.tag != "" else 0,
			of       = r.of,
		}
		mem.copy(&buffer[int(rows.offset) + i * size_of(Perception_Row)], &record, size_of(record))
	}
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Perception_Blob {
		header = {magic = BLOB_MAGIC, kind = .Perception, layout = perception_layout(), key = contents.key, guid = contents.guid},
		notices = notices,
		rows = rows,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}
