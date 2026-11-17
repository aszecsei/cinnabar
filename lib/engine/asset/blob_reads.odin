package asset

import "core:log"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// Blob_Read is a read of an asset's blob across frames, on the host's threads (see
// docs/content/blobs-and-loading.md#reads-across-frames). Its zero value is not a read, and blob_read_poll gives it as
// Failed, so a read that never began never reads as done.
Blob_Read :: union {
	Blob_Read_Pending,
	Blob_Read_Failed,
	Blob_Read_Finished,
}

// Blob_Read_Pending is a read that the host has started. size is the blob's bytes as they are in memory, and
// stored_size is the bytes that the file holds for it, which are fewer when the codec compresses them.
Blob_Read_Pending :: struct {
	file:        core.File_Read,
	guid:        format.Guid,
	codec:       format.Bundle_Codec,
	size:        int,
	stored_size: int,
}

// Blob_Read_Failed is a read that could not begin, or that blob_read_poll found failed.
Blob_Read_Failed :: struct {}

// Blob_Read_Finished is a read that is over, which blob_read_end has nothing to do for.
Blob_Read_Finished :: struct {}

Blob_Read_State :: enum u8 {
	Failed,
	Pending,
	Done,
}

// blob_read_begin starts the read of an asset's whole blob across frames. It gives Blob_Read_Failed, and logs why, for
// a GUID that has no blob, for a paged mesh, whose pages stream (see docs/content/blobs-and-loading.md#loading), and for
// a platform without reads across frames.
blob_read_begin :: proc(a: ^Assets, guid: format.Guid) -> Blob_Read {
	platform := a.platform
	if platform.file_read_begin == nil || platform.file_read_result == nil {
		return Blob_Read_Failed{}
	}
	buffer: [32]u8
	pending := Blob_Read_Pending {
		guid = guid,
	}
	path: string
	offset: i64
	switch &source in a.source {
	case Loose_Cache:
		path = loose_path(a, guid)
		size, found := platform.file_size(path)
		if !found || size <= 0 || size > i64(max(u32)) {
			log.errorf(
				"asset: no blob for %s at %s. Cook the content.",
				format.guid_format(guid, &buffer),
				path,
			)
			return Blob_Read_Failed{}
		}
		pending.size = int(size)
		pending.stored_size = int(size)
	case Bundle:
		b, entry, found := bundle_entry_opening(a, &source, guid)
		if !found {
			log.errorf(
				"asset: no open bundle has %s. Cook and package the content.",
				format.guid_format(guid, &buffer),
			)
			return Blob_Read_Failed{}
		}
		if entry.kind == .Mesh {
			log.errorf(
				"asset: %s is a mesh, whose pages stream",
				format.guid_format(guid, &buffer),
			)
			return Blob_Read_Failed{}
		}
		path = bundle_path(a, &source, string(b.name[:b.name_len]))
		offset = i64(entry.offset)
		pending.codec = entry.codec
		pending.size = int(entry.size)
		pending.stored_size = entry.codec == .None ? int(entry.size) : int(entry.stored_size)
	case:
		return Blob_Read_Failed{}
	}
	pending.file = platform.file_read_begin(path, offset, pending.stored_size)
	if pending.file == 0 {
		log.errorf("asset: cannot begin the read of %s", path)
		return Blob_Read_Failed{}
	}
	return pending
}

// blob_read_poll gives a read's state. When the host's read is done, it copies or decompresses the blob into allocator,
// at BLOB_ALIGN, checks it as read_blob does, and ends the host's read. Then the read is finished, and the caller owns
// data. A read that fails is ended too. The caller does not read data for a state other than Done.
blob_read_poll :: proc(
	a: ^Assets,
	read: ^Blob_Read,
	allocator: mem.Allocator,
) -> (
	data: []byte,
	state: Blob_Read_State,
) {
	pending, is_pending := read.(Blob_Read_Pending)
	if !is_pending {
		return nil, .Failed
	}
	bytes, host_state := a.platform.file_read_result(pending.file)
	switch host_state {
	case .Pending:
		return nil, .Pending
	case .Failed:
		buffer: [32]u8
		log.errorf("asset: cannot read %s", format.guid_format(pending.guid, &buffer))
		blob_read_end(a, read)
		read^ = Blob_Read_Failed{}
		return nil, .Failed
	case .Done:
	}
	blob, valid := blob_read_copy(pending, bytes, allocator)
	blob_read_end(a, read)
	if !valid {
		read^ = Blob_Read_Failed{}
		return nil, .Failed
	}
	return blob, .Done
}

// blob_read_copy makes a finished read's blob in allocator from the bytes that the host read, and checks it. bytes are
// valid until the host's read ends.
@(private = "file")
blob_read_copy :: proc(
	pending: Blob_Read_Pending,
	bytes: []byte,
	allocator: mem.Allocator,
) -> (
	blob: []byte,
	ok: bool,
) {
	buffer: [32]u8
	name := format.guid_format(pending.guid, &buffer)
	if len(bytes) != pending.stored_size {
		log.errorf("asset: the read of %s is cut short", name)
		return
	}
	blob = mem.alloc_bytes_non_zeroed(pending.size, format.BLOB_ALIGN, allocator) or_else nil
	if blob == nil {
		return
	}
	switch pending.codec {
	case .None:
		copy(blob, bytes)
	case .Lz4:
		if !lz4.decompress(bytes, blob) {
			log.errorf("asset: cannot decompress %s", name)
			delete(blob, allocator)
			return nil, false
		}
	}
	header, valid := format.blob_header(blob)
	if !valid || header.guid != pending.guid || header.kind == .Mesh {
		log.errorf("asset: %s is not a cooked blob of its GUID, or is a mesh", name)
		delete(blob, allocator)
		return nil, false
	}
	return blob, true
}

// blob_read_end ends a read, and cancels one that is pending. Ending a read again, or one that began or finished as a
// failure, does nothing.
blob_read_end :: proc(a: ^Assets, read: ^Blob_Read) {
	if pending, is_pending := read.(Blob_Read_Pending); is_pending {
		a.platform.file_read_end(pending.file)
		read^ = Blob_Read_Finished{}
	}
}
