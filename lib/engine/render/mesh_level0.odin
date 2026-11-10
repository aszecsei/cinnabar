// A paged mesh's level 0: its own triangles as whole buffers of positions, attributes and indices, which the paths that
// do not draw meshlets from the pool need. It is assembled from the mesh's pages the first time that one of them asks.
// See docs/rendering/assets.md#level-0.
package render

import "core:hash"
import "core:log"
import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/lz4"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// Level0 is where a paged mesh's level 0 is. nil is not asked for: the mesh has no positions, attributes or indices.
// change_level0 is its only writer.
Level0 :: union {
	Level0_Assembling,
	Level0_Streaming,
	Level0_Ready,
}

// Level0_Assembling is the streams filling from the pages in order: the heap's arrays, the next page to add, how many
// indices are in, and the read of the next pages that are not in the blob's head, as a range of the mesh's pages and
// where the range starts in the file.
Level0_Assembling :: struct {
	positions:   []byte,
	attributes:  []byte,
	indices:     []u32,
	next_page:   u32,
	index_count: u32,
	read:        core.File_Read,
	read_end:    u32,
	read_offset: u32,
}

// Level0_Streaming is the buffers on their way to the GPU.
Level0_Streaming :: struct {
	positions:  gpu.Buffer,
	attributes: gpu.Buffer,
	indices:    gpu.Buffer,
	transfers:  [3]gpu.Transfer,
}

// Level0_Ready is the mesh's positions, attributes and indices in place.
Level0_Ready :: struct {}

@(private = "file")
Level0_Event :: union #no_nil {
	// Something asked for it.
	Level0_Asked,
	// Every page is in the arrays, and the buffers stream.
	Level0_Assembled,
	// The buffers are in.
	Level0_Landed,
	// It cannot be assembled, or its mesh goes.
	Level0_Dropped,
}

@(private = "file")
Level0_Asked :: struct {
	arrays: Level0_Assembling,
}

@(private = "file")
Level0_Assembled :: struct {
	streaming: Level0_Streaming,
}

@(private = "file")
Level0_Landed :: struct {}

@(private = "file")
Level0_Dropped :: struct {}

// change_level0 is the one writer of a mesh's level 0 (see docs/overview/conventions.md#state-with-a-lifecycle): it
// frees what the state that it leaves held, and puts the buffers in the mesh when they are in.
@(private = "file")
change_level0 :: proc(r: ^Residency, m: ^Resident_Mesh, event: Level0_Event) -> bool {
	free_arrays :: proc(r: ^Residency, a: Level0_Assembling) {
		heap := r.platform.heap_allocator
		delete(a.positions, heap)
		delete(a.attributes, heap)
		delete(a.indices, heap)
		if a.read != 0 {
			r.platform.file_read_end(a.read)
		}
	}
	switch e in event {
	case Level0_Asked:
		if m.level0 != nil {
			return false
		}
		m.level0 = e.arrays
	case Level0_Assembled:
		arrays := m.level0.(Level0_Assembling) or_return
		free_arrays(r, arrays)
		m.level0 = e.streaming
	case Level0_Landed:
		s := m.level0.(Level0_Streaming) or_return
		m.positions, m.attributes, m.indices = s.positions, s.attributes, s.indices
		m.level0 = Level0_Ready{}
		m.level0_failed_at = 0
		if r.accels {
			create_mesh_accel(r, m)
		}
	case Level0_Dropped:
		switch s in m.level0 {
		case Level0_Assembling:
			free_arrays(r, s)
		case Level0_Streaming:
			r.platform.gpu_destroy_buffer(s.positions)
			r.platform.gpu_destroy_buffer(s.attributes)
			r.platform.gpu_destroy_buffer(s.indices)
		case Level0_Ready:
			// The mesh's buffers go with the mesh.
		case:
			return false
		}
		m.level0 = nil
	}
	return true
}

// resident_level0 is whether a mesh's positions, attributes and indices are resident, which a mesh without pages always
// has. A paged mesh's are assembled from its pages the first time that this is asked, over some frames; until then,
// what needs them draws nothing. What draws vertices by index, traces the mesh or shades a hit on it asks: the paths
// that do not draw meshlets (see docs/rendering/assets.md#level-0).
resident_level0 :: proc(r: ^Residency, m: ^Resident_Mesh) -> bool {
	if !m.paged {
		return true
	}
	if _, ready := m.level0.(Level0_Ready); ready {
		return true
	}
	if m.level0 == nil && (m.level0_failed_at == 0 || r.frame - m.level0_failed_at >= RESIDENT_RETRY_FRAMES) {
		heap := r.platform.heap_allocator
		arrays := Level0_Assembling {
			positions  = make([]byte, int(m.vertex_count) * 12, heap),
			attributes = make([]byte, int(m.vertex_count) * int(m.attribute_stride), heap),
			indices    = make([]u32, m.index_count, heap),
		}
		change_level0(r, m, Level0_Asked{arrays})
	}
	return false
}

// drop_level0 frees a mesh's level 0 that is on its way. Call it when the mesh goes.
@(private)
drop_level0 :: proc(r: ^Residency, m: ^Resident_Mesh) {
	change_level0(r, m, Level0_Dropped{})
}

// advance_level0 moves a mesh's level 0 on by what this frame can do: it adds the pages whose blocks are at hand, in
// order, at most the pool's budget of them, starts the read of the next ones, and streams the buffers when every page
// is in. Call it once a frame for each ready mesh.
@(private)
advance_level0 :: proc(r: ^Residency, m: ^Resident_Mesh) {
	switch &s in m.level0 {
	case Level0_Assembling:
		assemble_level0(r, m, &s)
	case Level0_Streaming:
		done := true
		for t in s.transfers {
			done &&= r.platform.gpu_transfer_done(t)
		}
		if done {
			change_level0(r, m, Level0_Landed{})
		}
	case Level0_Ready:
	}
}

@(private = "file")
fail_level0 :: proc(r: ^Residency, m: ^Resident_Mesh, guid: format.Guid, reason: string) {
	if m.level0_failed_at == 0 {
		buffer: [32]u8
		log.errorf("render: level 0 of the mesh %s %s", format.guid_format(guid, &buffer), reason)
	}
	m.level0_failed_at = max(r.frame, 1)
	change_level0(r, m, Level0_Dropped{})
}

@(private = "file")
assemble_level0 :: proc(r: ^Residency, m: ^Resident_Mesh, s: ^Level0_Assembling) {
	pool := &r.pool
	platform := r.platform
	if m.pool_mesh == 0 || int(m.pool_mesh) > len(pool.meshes) || !pool.meshes[m.pool_mesh - 1].live {
		return
	}
	mesh := &pool.meshes[m.pool_mesh - 1]
	records := mesh.records
	for pool.level0_budget > 0 {
		// The pages with level 0 meshlets come first in each submesh, and a page without any adds nothing.
		for int(s.next_page) < len(records) && records[s.next_page].level0_meshlets == 0 {
			s.next_page += 1
		}
		if int(s.next_page) == len(records) {
			finish_level0(r, m, mesh, s)
			return
		}
		record := records[s.next_page]
		block: []byte
		if .Root in record.flags {
			head, loaded := asset.data(r.assets, mesh.handle)
			if !loaded || asset.version(r.assets, mesh.handle) != mesh.version || u64(record.offset) + u64(record.compressed_size) > u64(len(head)) {
				// The blob changed, and the mesh's next version streams.
				return
			}
			block = head[record.offset:][:record.compressed_size]
		} else {
			if s.read == 0 {
				if platform.file_read_begin == nil {
					fail_level0(r, m, mesh.guid, "cannot be read on this platform")
					return
				}
				path := asset.blob_path(r.assets, mesh.guid)
				if platform.file_modified(path) != mesh.modified {
					return
				}
				// The pages from this one that follow each other in the file, up to a read's size.
				end := s.next_page
				size: u32
				for int(end) < len(records) && (.Root not_in records[end].flags) && records[end].level0_meshlets > 0 {
					next := records[end].offset + records[end].compressed_size - record.offset
					if end > s.next_page && next > LEVEL0_READ_SIZE {
						break
					}
					size = next
					end += 1
				}
				s.read = platform.file_read_begin(path, i64(record.offset), int(size))
				s.read_end, s.read_offset = end, record.offset
				if s.read == 0 {
					// The host's reads are all in use. The next frame asks again.
					return
				}
			}
			data, state := platform.file_read_result(s.read)
			switch state {
			case .Pending:
				return
			case .Failed:
				fail_level0(r, m, mesh.guid, "could not be read")
				return
			case .Done:
			}
			block = data[record.offset - s.read_offset:][:record.compressed_size]
		}
		if hash.fnv32a(block) != record.checksum {
			fail_level0(r, m, mesh.guid, "has a page that is not the one that its table names")
			return
		}
		page, _ := mem.alloc_bytes_non_zeroed(int(record.size), 16, platform.frame_allocator)
		header: ^format.Mesh_Page_Header
		viewed := false
		if lz4.decompress(block, page) {
			header, viewed = format.mesh_page_view(page, record, mesh.stride)
		}
		count := viewed ? format.mesh_page_level0_indices(page, header, record) : 0
		if !viewed ||
		   u64(record.first_vertex) + u64(header.vertex_count) > u64(m.vertex_count) ||
		   u64(s.index_count) + u64(count) > u64(len(s.indices)) {
			fail_level0(r, m, mesh.guid, "has a page that does not decompress into a page of it")
			return
		}
		copy(s.positions[record.first_vertex * 12:], mem.slice_to_bytes(format.mesh_page_positions(page, header)))
		copy(s.attributes[record.first_vertex * mesh.stride:], format.mesh_page_attributes(page, header))
		format.mesh_page_level0(page, header, record, s.indices[s.index_count:])
		s.index_count += u32(count)
		s.next_page += 1
		pool.level0_budget -= 1
		if s.read != 0 && s.next_page >= s.read_end {
			platform.file_read_end(s.read)
			s.read = 0
		}
	}
}

// finish_level0 streams the arrays into buffers of their own, with 16-bit indices for a mesh that has them.
@(private = "file")
finish_level0 :: proc(r: ^Residency, m: ^Resident_Mesh, mesh: ^Pool_Mesh, s: ^Level0_Assembling) {
	if s.index_count != m.index_count {
		fail_level0(r, m, mesh.guid, "has other triangles than its blob says")
		return
	}
	index_bytes := mem.slice_to_bytes(s.indices)
	if m.index_format == .U16 {
		narrow := make([]u16, (len(s.indices) + 1) &~ 1, r.platform.frame_allocator)
		for index, i in s.indices {
			narrow[i] = u16(index)
		}
		index_bytes = mem.slice_to_bytes(narrow)
	}
	streaming: Level0_Streaming
	ok := true
	stream :: proc(r: ^Residency, data: []byte, usage: gpu.Buffer_Usages, label: string, ok: ^bool) -> (buffer: gpu.Buffer, transfer: gpu.Transfer) {
		if !ok^ || len(data) == 0 {
			ok^ = false
			return
		}
		buffer = r.platform.gpu_create_buffer({size = u32(len(data)), usage = usage, label = label}, nil)
		if buffer != {} {
			transfer = r.platform.gpu_stream_buffer(buffer, 0, data)
		}
		ok^ = buffer != {} && transfer != 0
		return
	}
	streaming.positions, streaming.transfers[0] = stream(r, s.positions, {}, "mesh positions", &ok)
	streaming.attributes, streaming.transfers[1] = stream(r, s.attributes, {}, "mesh attributes", &ok)
	streaming.indices, streaming.transfers[2] = stream(r, index_bytes, {.Index}, "mesh indices", &ok)
	if !ok {
		r.platform.gpu_destroy_buffer(streaming.positions)
		r.platform.gpu_destroy_buffer(streaming.attributes)
		r.platform.gpu_destroy_buffer(streaming.indices)
		fail_level0(r, m, mesh.guid, "cannot stream")
		return
	}
	change_level0(r, m, Level0_Assembled{streaming})
}
