// A virtual texture's whole texture: an ordinary texture of every mip, which the readers that cannot sample pages need, such
// as sprites, particles and the UI. It is assembled from the texture's pages the first time that one of them asks. See
// docs/rendering/assets.md#virtual-textures.
package render

import "core:hash"
import "core:log"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/lz4"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// Texture_Whole is where a virtual texture's whole texture is. nil is not asked for: the texture has none.
// change_whole is its only writer.
Texture_Whole :: union {
	Whole_Assembling,
	Whole_Streaming,
	Whole_Ready,
}

// Whole_Assembling is the mips filling from the pages in order: the heap's chain, the next page to add, and the read of
// the next pages that are not in the blob's head, as a range of the texture's pages and where the range starts in the
// file.
Whole_Assembling :: struct {
	mips:        []byte,
	next_page:   u32,
	read:        core.File_Read,
	read_end:    u32,
	read_offset: u64,
}

// Whole_Streaming is the texture on its way to the GPU.
Whole_Streaming :: struct {
	texture:  gpu.Texture,
	transfer: gpu.Transfer,
}

// Whole_Ready is the texture in place, as Resident_Resources.whole.
Whole_Ready :: struct {}

@(private = "file")
Whole_Event :: union #no_nil {
	// Something asked for it.
	Whole_Asked,
	// Every page is in the chain, and the texture streams.
	Whole_Assembled,
	// The texture is in.
	Whole_Landed,
	// It cannot be assembled, or its texture goes.
	Whole_Dropped,
}

@(private = "file")
Whole_Asked :: struct {
	mips: []byte,
}

@(private = "file")
Whole_Assembled :: struct {
	streaming: Whole_Streaming,
}

@(private = "file")
Whole_Landed :: struct {}

@(private = "file")
Whole_Dropped :: struct {}

// change_whole is the one writer of a virtual texture's whole texture (see
// docs/overview/conventions.md#state-with-a-lifecycle): it frees what the state that it leaves held, and gives the
// resources the texture when it is in.
@(private = "file")
change_whole :: proc(r: ^Residency, res: ^Resident_Resources, event: Whole_Event) -> bool {
	free_mips :: proc(r: ^Residency, a: Whole_Assembling) {
		delete(a.mips, r.platform.heap_allocator)
		if a.read != 0 {
			r.platform.file_read_end(a.read)
		}
	}
	switch e in event {
	case Whole_Asked:
		if res.whole_state != nil {
			return false
		}
		res.whole_state = Whole_Assembling {
			mips = e.mips,
		}
	case Whole_Assembled:
		assembling := res.whole_state.(Whole_Assembling) or_return
		free_mips(r, assembling)
		res.whole_state = e.streaming
	case Whole_Landed:
		s := res.whole_state.(Whole_Streaming) or_return
		t := res.texture
		res.whole = {
			texture      = s.texture,
			pixel_format = t.pixel_format,
			size         = t.size,
			mip_count    = t.mip_count,
			usage        = t.usage,
			dimension    = .D2,
			layer_count  = 1,
			sampler      = t.sampler,
		}
		res.whole_state = Whole_Ready{}
		res.whole_failed_at = 0
	case Whole_Dropped:
		switch s in res.whole_state {
		case Whole_Assembling:
			free_mips(r, s)
		case Whole_Streaming:
			r.platform.gpu_destroy_texture(s.texture)
		case Whole_Ready:
			r.platform.gpu_destroy_texture(res.whole.texture)
			res.whole = {}
		case:
			return false
		}
		res.whole_state = nil
	}
	return true
}

// resident_whole gives a virtual texture's whole texture, and whether it is ready. The first call starts to assemble it
// from the texture's pages, over some frames, as advance_whole does; until it is ready, the reader uses its default.
@(private)
resident_whole :: proc(
	r: ^Residency,
	e: ^Resident_Entry,
) -> (
	texture: ^Resident_Texture,
	ready: bool,
) {
	res := &e.current
	if _, whole := res.whole_state.(Whole_Ready); whole {
		return &res.whole, true
	}
	pool := &r.texture_pool
	id := res.texture.virtual
	if res.whole_state == nil &&
	   (res.whole_failed_at == 0 || r.frame - res.whole_failed_at >= RESIDENT_RETRY_FRAMES) &&
	   int(id) <= len(pool.textures) &&
	   pool.textures[id - 1].live {
		tex := &pool.textures[id - 1]
		size := format.texture_chain_size(tex.blob_format, tex.size, tex.mip_count)
		change_whole(r, res, Whole_Asked{make([]byte, size, r.platform.heap_allocator)})
	}
	return &res.whole, false
}

// drop_whole frees a virtual texture's whole texture, or what is on its way. Call it when the texture goes.
@(private)
drop_whole :: proc(r: ^Residency, res: ^Resident_Resources) {
	change_whole(r, res, Whole_Dropped{})
}

// advance_whole moves a ready virtual texture's whole texture on by what this frame can do: it adds the pages whose
// blocks are at hand, in order, at most the pool's budget of them, starts the read of the next ones, and streams the
// texture when every page is in. Call it once a frame for each ready virtual texture.
@(private)
advance_whole :: proc(r: ^Residency, e: ^Resident_Entry) {
	res := &e.current
	switch &s in res.whole_state {
	case Whole_Assembling:
		assemble_whole(r, e, &s)
	case Whole_Streaming:
		if r.platform.gpu_transfer_done(s.transfer) {
			change_whole(r, res, Whole_Landed{})
		}
	case Whole_Ready:
	}
}

@(private = "file")
fail_whole :: proc(r: ^Residency, e: ^Resident_Entry, reason: string) {
	if e.current.whole_failed_at == 0 {
		buffer: [32]u8
		log.errorf(
			"render: the whole texture of the virtual texture %s %s",
			format.guid_format(e.guid, &buffer),
			reason,
		)
	}
	e.current.whole_failed_at = max(r.frame, 1)
	change_whole(r, &e.current, Whole_Dropped{})
}

// whole_mip_offset is where a mip starts in a whole texture's chain.
@(private = "file")
whole_mip_offset :: proc(f: format.Texture_Format, size: [2]u32, mip: u32) -> (offset: int) {
	for i in 0 ..< mip {
		offset += format.texture_mip_size(f, max(size.x >> i, 1), max(size.y >> i, 1))
	}
	return
}

@(private = "file")
assemble_whole :: proc(r: ^Residency, e: ^Resident_Entry, s: ^Whole_Assembling) {
	pool := &r.texture_pool
	platform := r.platform
	id := e.current.texture.virtual
	if id == 0 || int(id) > len(pool.textures) || !pool.textures[id - 1].live {
		return
	}
	tex := &pool.textures[id - 1]
	for pool.whole_budget > 0 {
		if int(s.next_page) == len(tex.pages) {
			finish_whole(r, e, tex, s)
			return
		}
		record := tex.pages[s.next_page]
		block: []byte
		if .Root in record.flags {
			head, loaded := asset.data(r.assets, tex.handle)
			if !loaded ||
			   asset.version(r.assets, tex.handle) != tex.version ||
			   u64(record.offset) + u64(record.compressed_size) > u64(len(head)) {
				// The blob changed, and the texture's next version streams.
				return
			}
			block = head[record.offset:][:record.compressed_size]
		} else {
			if s.read == 0 {
				if platform.file_read_begin == nil {
					fail_whole(r, e, "cannot be read on this platform")
					return
				}
				location, found := asset.blob_location(r.assets, tex.guid)
				if !found || !location.raw {
					fail_whole(r, e, "is not stored as it is, so its pages cannot be read")
					return
				}
				if platform.file_modified(location.path) != tex.modified {
					return
				}
				// The pages from this one that follow each other in the file, up to a read's size.
				end := s.next_page
				size: u64
				for int(end) < len(tex.pages) &&
				    (.Root not_in tex.pages[end].flags) &&
				    tex.pages[end].offset >= record.offset {
					next :=
						tex.pages[end].offset + u64(tex.pages[end].compressed_size) - record.offset
					if end > s.next_page && next > TEXTURE_WHOLE_READ_SIZE {
						break
					}
					size = next
					end += 1
				}
				s.read = platform.file_read_begin(
					location.path,
					location.offset + i64(record.offset),
					int(size),
				)
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
				fail_whole(r, e, "could not be read")
				return
			case .Done:
			}
			block = data[record.offset - s.read_offset:][:record.compressed_size]
		}
		if hash.fnv32a(block) != record.checksum {
			fail_whole(r, e, "has a page that is not the one that its table names")
			return
		}
		payload := make([]byte, record.size, platform.frame_allocator)
		if !lz4.decompress(block, payload) {
			fail_whole(r, e, "has a page that does not decompress")
			return
		}
		mip := u32(record.mip)
		size := [2]u32{max(tex.size.x >> mip, 1), max(tex.size.y >> mip, 1)}
		offset := whole_mip_offset(tex.blob_format, tex.size, mip)
		format.texture_page_strip(
			tex.blob_format,
			payload,
			tex.levels[mip],
			u32(record.x),
			u32(record.y),
			s.mips[offset:][:format.texture_mip_size(tex.blob_format, size.x, size.y)],
		)
		s.next_page += 1
		pool.whole_budget -= 1
		if s.read != 0 && s.next_page >= s.read_end {
			platform.file_read_end(s.read)
			s.read = 0
		}
	}
}

// finish_whole adds the tail's mips from the blob's head, and streams the chain into a texture of its own.
@(private = "file")
finish_whole :: proc(r: ^Residency, e: ^Resident_Entry, tex: ^Pool_Texture, s: ^Whole_Assembling) {
	head, loaded := asset.data(r.assets, tex.handle)
	if !loaded || asset.version(r.assets, tex.handle) != tex.version {
		// The blob changed, and the texture's next version streams.
		return
	}
	blob, viewed := format.texture_view(head)
	if !viewed {
		fail_whole(r, e, "has a head that is not a texture's")
		return
	}
	tail := format.texture_tail(head, blob)
	offset := whole_mip_offset(tex.blob_format, tex.size, blob.tail_mip)
	if len(tail) != len(s.mips) - offset {
		fail_whole(r, e, "has a tail that is not its last mips")
		return
	}
	copy(s.mips[offset:], tail)
	t := &e.current.texture
	texture := r.platform.gpu_create_texture(
		{
			size = t.size,
			format = t.pixel_format,
			mip_count = t.mip_count,
			usage = {.Sampled, .Streamed},
			label = "virtual texture assembled",
		},
		nil,
	)
	transfer: gpu.Transfer
	if texture != {} {
		transfer = r.platform.gpu_stream_texture(texture, s.mips)
	}
	if transfer == 0 {
		r.platform.gpu_destroy_texture(texture)
		fail_whole(r, e, "cannot stream")
		return
	}
	change_whole(r, &e.current, Whole_Assembled{{texture, transfer}})
}
