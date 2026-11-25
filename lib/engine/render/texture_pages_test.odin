package render

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/lz4"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// The fake platform of the pool of mesh pages with textures that are counted and whose streams are kept, and the video
// memory that a test says the process uses. Its first field is the mesh pages' fake, so its reads, uploads, jobs and
// buffers are that one's.
@(private = "file")
Texture_Fake :: struct {
	using page:    Page_Fake,
	next_texture:  u32,
	live_textures: int,
	created:       [dynamic]gpu.Texture_Desc,
	// What streamed into textures, in order.
	streams:       [dynamic][]byte,
	// The video memory that the process uses, other than the pool's atlases, and the budget that the OS gives it.
	others:        u64,
	budget:        u64,
	pool:          ^Texture_Pool,
}

@(private = "file")
texture_fake :: proc() -> ^Texture_Fake {
	return (^Texture_Fake)(context.user_ptr)
}

@(private = "file")
texture_platform :: proc(frame: ^virtual.Arena) -> core.Platform_API {
	p := page_platform(frame)
	p.gpu_create_texture = proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
		fake := texture_fake()
		fake.next_texture += 1
		fake.live_textures += 1
		append(&fake.created, desc)
		return transmute(gpu.Texture)[2]u32{fake.next_texture, 1}
	}
	p.gpu_destroy_texture = proc(texture: gpu.Texture) {
		if texture != {} {
			texture_fake().live_textures -= 1
		}
	}
	p.gpu_stream_texture = proc(texture: gpu.Texture, data: []byte) -> gpu.Transfer {
		fake := texture_fake()
		append(&fake.streams, slice.clone(data))
		fake.next_transfer += 1
		return gpu.Transfer(fake.next_transfer)
	}
	p.gpu_video_memory = proc() -> (used, budget: u64) {
		fake := texture_fake()
		return fake.others + fake.pool.stats.pool_bytes, fake.budget
	}
	return p
}

// A logger that counts what the code under test logs, and passes on what the test does.
@(private = "file")
Log_Count :: struct {
	inner:    runtime.Logger,
	errors:   int,
	warnings: int,
}

@(private = "file")
count_logs :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	count := (^Log_Count)(data)
	if strings.has_suffix(location.file_path, "_test.odin") {
		count.inner.procedure(count.inner.data, level, text, options, location)
	} else if level == .Error {
		count.errors += 1
	} else if level == .Warning {
		count.warnings += 1
	}
}

// Test_Texture is a virtual texture that a test wrote: each mip as the cooker would have encoded it, and its blob.
@(private)
Test_Texture :: struct {
	size:  [2]u32,
	mips:  [][]byte,
	blob:  []byte,
	pages: []format.Texture_Page,
}

// test_mips is a chain of mips of a format whose bytes tell which mip and which block they are of, and a seed.
@(private = "file")
test_mips :: proc(f: format.Texture_Format, size: [2]u32, seed: u8) -> [][]byte {
	count: u32 = 1
	for max(size.x >> count, size.y >> count) > 0 {
		count += 1
	}
	mips := make([][]byte, count, context.temp_allocator)
	for &mip, i in mips {
		mip = make(
			[]byte,
			format.texture_mip_size(f, max(size.x >> u32(i), 1), max(size.y >> u32(i), 1)),
			context.temp_allocator,
		)
		for &b, k in mip {
			b = u8(k * 31 + i * 7) + seed
		}
	}
	return mips
}

// test_payload is a page of a mip as the cooker writes it, before it is compressed: its 34 by 34 blocks, of which the ring
// at the edge is the neighbours' blocks, or 0xee past the mip's edge.
@(private = "file")
test_payload :: proc(
	f: format.Texture_Format,
	mip: []byte,
	mip_size: [2]u32,
	x, y: u32,
) -> []byte {
	block := format.texture_format_block(f)
	tile := format.TEXTURE_PAGE_TEXELS / 4
	blocks := [2]int{int(mip_size.x + 3) / 4, int(mip_size.y + 3) / 4}
	payload := make([]byte, tile * tile * block, context.temp_allocator)
	for row in 0 ..< tile {
		for col in 0 ..< tile {
			bx := int(x) * 32 + col - 1
			by := int(y) * 32 + row - 1
			to := payload[(row * tile + col) * block:][:block]
			if bx >= 0 && bx < blocks.x && by >= 0 && by < blocks.y {
				copy(to, mip[(by * blocks.x + bx) * block:][:block])
			} else {
				slice.fill(to, 0xee)
			}
		}
	}
	return payload
}

// test_texture builds a virtual texture blob of a format and size, at the runtime's alignment.
@(private)
test_texture :: proc(
	guid: format.Guid,
	size: [2]u32,
	f: format.Texture_Format = .BC7_Unorm_Srgb,
	seed: u8 = 0,
	key: u64 = 0,
) -> (
	tex: Test_Texture,
) {
	tex.size = size
	tex.mips = test_mips(f, size, seed)
	mip_count := u32(len(tex.mips))
	tail_mip := format.texture_tail_mip(size, mip_count)
	pages := make([dynamic]format.Texture_Page_Contents, context.temp_allocator)
	for mip in 0 ..< tail_mip {
		mip_size := [2]u32{max(size.x >> mip, 1), max(size.y >> mip, 1)}
		grid := [2]u32{(mip_size.x + 127) / 128, (mip_size.y + 127) / 128}
		for y in 0 ..< grid.y {
			for x in 0 ..< grid.x {
				payload := test_payload(f, tex.mips[mip], mip_size, x, y)
				block := lz4.compress(
					payload,
					make([]byte, lz4.bound(len(payload)), context.temp_allocator),
				)
				append(
					&pages,
					format.Texture_Page_Contents {
						record = {size = u32(len(payload)), checksum = hash.fnv32a(block)},
						compressed = block,
					},
				)
			}
		}
	}
	pages[len(pages) - 1].record.flags = {.Root}
	tail := make([dynamic]byte, context.temp_allocator)
	for mip in tex.mips[tail_mip:] {
		append(&tail, ..mip)
	}
	written := format.texture_write(
		{
			guid = guid,
			key = key,
			format = f,
			usage = .Color,
			size = size,
			mip_count = mip_count,
			sampler = {wrap = .Mirror, anisotropy = 4},
			mips = tail[:],
			flags = {.Virtual},
			pages = pages[:],
		},
		context.temp_allocator,
	)
	aligned, _ := mem.alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, written)
	blob, ok := format.texture_view(aligned)
	assert(ok, "the test's blob is a virtual texture")
	tex.blob = aligned
	tex.pages = format.texture_pages(aligned, blob)
	return
}

@(private = "file")
Texture_Fixture :: struct {
	fake:     Texture_Fake,
	frame:    virtual.Arena,
	platform: core.Platform_API,
	dir:      string,
	assets:   asset.Assets,
	r:        ^Residency,
}

// texture_fixture makes a residency with a pool of megabytes MiB, which gives each format one layer of 256 slots at 8.
@(private = "file")
texture_fixture :: proc(t: ^testing.T, megabytes: u32 = 8) -> ^Texture_Fixture {
	f := new(Texture_Fixture)
	f.fake.readbacks = make(map[u32][]byte)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = texture_platform(&f.frame)
	dir, err := os.make_directory_temp("", "texture_pages_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	f.r = new(Residency)
	residency_init(f.r, &f.platform, &f.assets)
	f.fake.pool = &f.r.texture_pool
	residency_set_texture_pool(f.r, megabytes)
	return f
}

@(private = "file")
texture_fixture_destroy :: proc(t: ^testing.T, f: ^Texture_Fixture) {
	residency_destroy(f.r)
	// Everything that the residency made is gone: its buffers, its textures and its reads.
	testing.expect_value(t, f.fake.live_buffers, 0)
	testing.expect_value(t, f.fake.live_textures, 0)
	testing.expect_value(t, f.fake.reads_open, 0)
	free(f.r)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	for upload in f.fake.uploads {
		delete(upload)
	}
	delete(f.fake.uploads)
	delete(f.fake.streamed)
	delete(f.fake.readbacks)
	delete(f.fake.created)
	for s in f.fake.streams {
		delete(s)
	}
	delete(f.fake.streams)
	virtual.arena_destroy(&f.frame)
	free(f)
}

// write_texture writes a virtual texture's blob and a generation file at modified, as a cook does.
@(private = "file")
write_texture :: proc(
	t: ^testing.T,
	f: ^Texture_Fixture,
	guid: format.Guid,
	size: [2]u32,
	modified: time.Time,
	format_: format.Texture_Format = .BC7_Unorm_Srgb,
	seed: u8 = 0,
	key: u64 = 0,
) -> Test_Texture {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer))
	tex := test_texture(guid, size, format_, seed, key)
	testing.expect(t, os.write_entire_file(path, tex.blob) == nil)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
	generation := fmt.tprintf("%s/%s", f.dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("1")) == nil)
	testing.expect(t, os.change_times(generation, modified, modified) == nil)
	return tex
}

// Want is a word of the feedback: a page that a view wants, by how much, or with no priority a page that a view drew
// from.
@(private = "file")
Want :: struct {
	entry:    u32,
	priority: f32,
}

// page_entry is the table entry of a page of a texture, by its level and its place in the level.
@(private = "file")
page_entry :: proc(f: ^Texture_Fixture, id: u32, mip, x, y: u32) -> u32 {
	tex := &f.r.texture_pool.textures[id - 1]
	level := tex.levels[mip]
	return tex.first + level.first_page + y * level.grid.x + x
}

// step is one frame: the feedback that came back, the residency's update, the stream pass, and its commit if the frame
// executes. After it, every page with a slot has its parent in a slot too, its entry names the slot that holds it, and
// nothing is resident beyond the atlases' slots.
@(private = "file")
step :: proc(
	t: ^testing.T,
	f: ^Texture_Fixture,
	wants: []Want = nil,
	executes := true,
) -> ^Stream_Texture_Pages {
	pool := &f.r.texture_pool
	if pool.table != {} {
		data, _ := f.platform.gpu_read_buffer(pool.ring.copies[pool.ring.next])
		mem.zero_slice(data)
		words := slice.reinterpret([]u32, data)
		for w in wants {
			words[w.entry] = w.priority > 0 ? transmute(u32)w.priority : 1
		}
		mark_readback_copied(&pool.ring, pool.ring.next)
	}
	residency_update(f.r)
	sp := prepare_stream_texture_pages(pool, &f.platform, &f.assets)
	if sp != nil && executes {
		commit_stream_texture_pages(sp)
	}
	check_pool(t, f)
	return sp
}

// check_pool checks what must hold after every frame.
@(private = "file")
check_pool :: proc(t: ^testing.T, f: ^Texture_Fixture) {
	pool := &f.r.texture_pool
	slots: u32
	for &a in pool.atlases[:pool.atlas_count] {
		slots += a.used_slots
		testing.expectf(
			t,
			int(a.used_slots) <= len(a.slots),
			"%d pages are in %d slots",
			a.used_slots,
			len(a.slots),
		)
	}
	resident: u32
	for &tex in pool.textures[:pool.texture_high] {
		if !tex.live {
			continue
		}
		atlas := &pool.atlases[tex.atlas]
		for _, p in tex.pages {
			entry := tex.first + u32(p)
			slot, has := state_slot(pool.pages[entry].state)
			if !has {
				testing.expect_value(t, pool.entries[entry], TEXTURE_PAGE_ABSENT)
				continue
			}
			resident += 1
			testing.expect_value(t, pool.entries[entry], slot)
			testing.expect_value(t, atlas.slots[slot], entry)
			if parent, has_parent := page_parent(pool, entry); has_parent {
				_, parent_has := state_slot(pool.pages[parent].state)
				testing.expectf(
					t,
					parent_has,
					"page %d has a slot, and its parent %d has none",
					entry,
					parent,
				)
			}
		}
	}
	testing.expect_value(t, resident, slots)
}

@(private = "file")
resident_set :: proc(f: ^Texture_Fixture, id: u32) -> (count: int) {
	tex := &f.r.texture_pool.textures[id - 1]
	for p in 0 ..< tex.count {
		count += int(texture_pool_resident(&f.r.texture_pool, id, p))
	}
	return
}

// expect_rows checks that a load's upload holds a page's blocks row by row, each row at its pitch.
@(private = "file")
expect_rows :: proc(t: ^testing.T, load: Texture_Page_Load, payload: []byte) {
	testing.expect_value(t, load.rows, 34)
	testing.expect_value(t, load.pitch % gpu.TEXTURE_COPY_PITCH_ALIGN, 0)
	testing.expect_value(t, load.upload.offset % gpu.TEXTURE_COPY_OFFSET_ALIGN, 0)
	for row in 0 ..< load.rows {
		testing.expect(
			t,
			slice.equal(
				load.upload.data[row * load.pitch:][:load.row_bytes],
				payload[row * load.row_bytes:][:load.row_bytes],
			),
			"the upload's rows are the page's",
		)
	}
}

@(test)
a_virtual_texture_is_ready_when_its_root_and_its_tail_are_in :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	tex := write_texture(t, f, guid, {512, 384}, time.now())

	_, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, !ready)
	// The tail streams as an ordinary texture of the mips from the tail on, and the pool makes its buffers and an atlas:
	// the records, the table, the feedback and its three copies.
	testing.expect_value(t, f.fake.live_buffers, 6)
	if testing.expect_value(t, len(f.fake.created), 2) {
		tail := f.fake.created[0]
		testing.expect_value(t, tail.size, [2]u32{64, 48})
		testing.expect_value(t, tail.mip_count, 7)
		testing.expect_value(t, tail.usage, gpu.Texture_Usages{.Sampled, .Streamed})
		testing.expect_value(t, tail.format, gpu.Format.BC7_Unorm_Srgb)
		atlas := f.fake.created[1]
		testing.expect_value(t, atlas.size, [2]u32{2176, 2176})
		testing.expect_value(t, atlas.layers, 1)
		testing.expect_value(t, atlas.usage, gpu.Texture_Usages{.Sampled})
		testing.expect_value(t, atlas.format, gpu.Format.BC7_Unorm_Srgb)
		testing.expect_value(t, gpu.validate_texture_desc(atlas, nil), gpu.Desc_Error.None)
	}
	tail := make([dynamic]byte, context.temp_allocator)
	for mip in tex.mips[3:] {
		append(&tail, ..mip)
	}
	if testing.expect_value(t, len(f.fake.streams), 1) {
		testing.expect(
			t,
			slice.equal(f.fake.streams[0], tail[:]),
			"the tail is the mips from mip 3",
		)
	}

	// The first frame copies the root, from the head, with the table and the record, and the second finds it in.
	sp := step(t, f)
	if testing.expect(t, sp != nil) {
		testing.expect_value(t, len(sp.loads), 1)
		testing.expect_value(t, len(sp.entries), 17)
		testing.expect_value(t, len(sp.runs), 1)
		values := slice.reinterpret([]u32, sp.table_upload.data[:17 * 4])
		for value, page in values {
			testing.expect_value(t, value != TEXTURE_PAGE_ABSENT, page == 16)
		}
		if testing.expect_value(t, len(sp.record_ids), 1) {
			record := (^Virtual_Texture_Record)(raw_data(sp.record_upload.data))^
			atlas := f.r.texture_pool.atlases[0].texture
			testing.expect_value(t, record.size, [2]u32{512, 384})
			testing.expect_value(t, record.table, 0)
			testing.expect_value(t, record.page_count, 17)
			testing.expect_value(t, record.levels, 3)
			testing.expect_value(t, record.atlas, gpu.read_index(atlas))
			testing.expect_value(
				t,
				record.tail,
				gpu.read_index(transmute(gpu.Texture)[2]u32{1, 1}),
			)
			testing.expect_value(
				t,
				record.sampler,
				u32(format.Texture_Wrap.Mirror) | 4 << VIRTUAL_SAMPLER_ANISOTROPY_SHIFT,
			)
			testing.expect_value(t, record.level_first[0], 0)
			testing.expect_value(t, record.level_first[1], 12)
			testing.expect_value(t, record.level_first[2], 16)
			testing.expect_value(t, record.level_first[3], 0)
		}
		// The upload is the page as the cooker wrote it, with each row of blocks at its own pitch.
		load := sp.loads[0]
		testing.expect_value(t, load.slot, 0)
		testing.expect_value(t, load.pitch, 768)
		expect_rows(t, load, test_payload(.BC7_Unorm_Srgb, tex.mips[2], {128, 96}, 0, 0))
	}
	_, ready = resident_virtual_texture(f.r, guid)
	testing.expect(t, !ready, "the tail has not landed")
	step(t, f)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	texture, now_ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, now_ready)
	testing.expect_value(t, texture.virtual, 1)
	testing.expect_value(t, texture.size, [2]u32{512, 384})
	testing.expect_value(t, texture.mip_count, 10)
	testing.expect_value(t, texture.sampler.wrap, format.Texture_Wrap.Mirror)
	// A cap on the samplers' anisotropy changes the record's, which the next frame sends.
	texture_pool_set_anisotropy(&f.r.texture_pool, 2)
	pooled := &f.r.texture_pool.textures[0]
	testing.expect_value(
		t,
		pooled.record.sampler,
		u32(format.Texture_Wrap.Mirror) | 2 << VIRTUAL_SAMPLER_ANISOTROPY_SHIFT,
	)
	testing.expect_value(t, pooled.record_sync, Entry_Sync.Dirty)
	stats := texture_stream_stats(f.r)
	testing.expect_value(t, stats.resident_pages, 1)
	testing.expect_value(t, stats.capacity_pages, 256)
	testing.expect_value(t, stats.pool_bytes, 4734976)
	testing.expect_value(t, stats.pending_pages, 0)
	testing.expect_value(t, f.fake.reads_begun, 0)
	// A frame after the table was sent has nothing left to send.
	settled := step(t, f)
	testing.expect(t, settled != nil && len(settled.entries) == 0 && len(settled.loads) == 0)
}

@(test)
wanted_pages_arrive_with_their_parents_first :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	tex := write_texture(t, f, guid, {1024, 1024}, time.now())
	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	texture, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	id := texture.virtual

	// A page of mip 0 is wanted, and so are the pages that cover it, down to the root, which is in already.
	fine := page_entry(f, id, 0, 3, 5)
	middle := page_entry(f, id, 1, 1, 2)
	coarse := page_entry(f, id, 2, 0, 1)
	f.fake.hold_reads = true
	step(t, f, {{fine, 2}})
	testing.expect_value(t, texture_stream_stats(f.r).pending_pages, 3)
	// The reads begin in the order that the pages are wanted: the coarser the page, the earlier.
	testing.expect_value(t, f.fake.reads_open, 3)

	// The finest page's read is in first, and the page waits for its parents.
	finish_read(&f.fake.reads[2])
	sp := step(t, f, {{fine, 2}})
	testing.expect(t, sp != nil && len(sp.loads) == 0, "the finest page waits for its parents")
	testing.expect_value(t, resident_set(f, id), 1)

	finish_read(&f.fake.reads[0])
	sp = step(t, f, {{fine, 2}})
	if testing.expect(t, sp != nil) {
		testing.expect_value(t, len(sp.loads), 1)
		testing.expect_value(t, sp.loads[0].entry, coarse)
	}
	finish_read(&f.fake.reads[1])
	sp = step(t, f, {{fine, 2}})
	if testing.expect(t, sp != nil) {
		// The parent comes before its child, and the table has both.
		if testing.expect_value(t, len(sp.loads), 2) {
			testing.expect_value(t, sp.loads[0].entry, middle)
			testing.expect_value(t, sp.loads[1].entry, fine)
			expect_rows(
				t,
				sp.loads[1],
				test_payload(.BC7_Unorm_Srgb, tex.mips[0], {1024, 1024}, 3, 5),
			)
		}
		testing.expect_value(t, len(sp.entries), 2)
	}
	testing.expect_value(t, resident_set(f, id), 4)
	// The next frame finds nothing wanted that is not in.
	step(t, f, {{fine, 2}})
	testing.expect_value(t, texture_stream_stats(f.r).pending_pages, 0)
	// The pool's table names a slot for each of them.
	testing.expect(t, f.r.texture_pool.entries[fine] != TEXTURE_PAGE_ABSENT)
	testing.expect(t, f.r.texture_pool.entries[middle] != TEXTURE_PAGE_ABSENT)
	testing.expect(t, f.r.texture_pool.entries[coarse] != TEXTURE_PAGE_ABSENT)
}

@(private = "file")
fine_pages :: proc(f: ^Texture_Fixture, id: u32, rows: [2]u32, columns: u32) -> []Want {
	wants := make([dynamic]Want, context.temp_allocator)
	for y in rows[0] ..< rows[1] {
		for x in 0 ..< columns {
			append(&wants, Want{page_entry(f, id, 0, x, y), 2})
		}
	}
	return wants[:]
}

@(private = "file")
resident_of :: proc(f: ^Texture_Fixture, wants: []Want) -> (n: int) {
	for w in wants {
		_, resident := f.r.texture_pool.pages[w.entry].state.(Page_Resident)
		n += int(resident)
	}
	return
}

// run_frames steps frames with the same wants, and checks that none loads more than a frame may, and that the root stays.
@(private = "file")
run_frames :: proc(t: ^testing.T, f: ^Texture_Fixture, wants: []Want, frames: int, id: u32) {
	root := f.r.texture_pool.textures[id - 1].count - 1
	for _ in 0 ..< frames {
		sp := step(t, f, wants)
		if sp != nil {
			testing.expect(t, len(sp.loads) <= TEXTURE_PAGE_LOADS_PER_FRAME)
		}
		testing.expect(t, texture_pool_resident(&f.r.texture_pool, id, root), "the root stays")
	}
}

@(test)
a_pool_smaller_than_what_is_wanted_keeps_what_views_use :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	write_texture(t, f, guid, {4096, 4096}, time.now())
	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	texture, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	id := texture.virtual
	// 1,365 pages in 256 slots.
	testing.expect_value(t, f.r.texture_pool.textures[id - 1].count, 1365)
	testing.expect_value(t, texture_stream_stats(f.r).capacity_pages, 256)

	// A view uses 112 pages of mip 0 and the 42 pages that cover them, which fit.
	a := fine_pages(f, id, {0, 4}, 28)
	run_frames(t, f, a, 30, id)
	testing.expect_value(t, resident_of(f, a), 112)
	testing.expect_value(t, texture_stream_stats(f.r).resident_pages, 154)
	// Its second half is used on, and the first is not, for longer than a page is kept.
	first, second := a[:56], a[56:]
	run_frames(t, f, second, 3 * TEXTURE_PAGE_KEEP_FRAMES, id)
	// Then another view's pages are wanted, more than there is room for without a page that was used. The pages that were
	// used longest ago leave first, so none of the second half goes while some of the first is in.
	b := fine_pages(f, id, {16, 20}, 30)
	both := slice.concatenate([][]Want{second, b}, context.temp_allocator)
	run_frames(t, f, both, 40, id)
	testing.expect_value(t, resident_of(f, b), 120)
	in_first, in_second := resident_of(f, first), resident_of(f, second)
	testing.expect(t, in_first < 56, "pages that nothing used left for the ones that views want")
	testing.expectf(
		t,
		in_second == 56 || in_first == 0,
		"%d of the older pages are in, and %d of the newer ones",
		in_first,
		in_second,
	)

	// More is wanted than fits, and all of it is in use: nothing leaves, and the rest waits.
	all := fine_pages(f, id, {0, 16}, 32)
	run_frames(t, f, all, 60, id)
	stats := texture_stream_stats(f.r)
	testing.expect_value(t, stats.resident_pages, 256)
	testing.expect(t, stats.pending_pages > 0)
}

@(test)
the_pool_shrinks_while_the_process_is_over_its_video_memory :: proc(t: ^testing.T) {
	f := texture_fixture(t, 64)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	count := Log_Count {
		inner = context.logger,
	}
	context.logger = {count_logs, &count, .Debug, {}}
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	write_texture(t, f, guid, {1024, 1024}, time.now())
	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	// The color atlas has its share of the budget: 7 of the 4.5 MiB layers.
	stats := texture_stream_stats(f.r)
	testing.expect_value(t, stats.capacity_pages, 7 * 256)
	testing.expect_value(t, stats.pool_bytes, 7 * 4734976)

	// While the process is within its budget, the pool is as it was made.
	f.fake.others, f.fake.budget = 50 * mem.Megabyte, 100 * mem.Megabyte
	for _ in 0 ..< 2 * TEXTURE_BUDGET_CHECK_FRAMES {
		step(t, f)
	}
	stats = texture_stream_stats(f.r)
	testing.expect_value(t, stats.capacity_pages, 7 * 256)
	testing.expect_value(t, stats.video_used, 50 * mem.Megabyte + 7 * 4734976)
	testing.expect_value(t, stats.video_budget, 100 * mem.Megabyte)
	testing.expect_value(t, count.warnings, 0)

	// Over it, the pool shrinks to what its budget leaves of it: 10 MiB is two layers. It is made again, and the root
	// comes back.
	f.fake.others = 90 * mem.Megabyte
	for _ in 0 ..< 2 * TEXTURE_BUDGET_CHECK_FRAMES {
		step(t, f)
	}
	stats = texture_stream_stats(f.r)
	testing.expect_value(t, stats.capacity_pages, 2 * 256)
	testing.expect_value(t, stats.pool_bytes, 2 * 4734976)
	testing.expect_value(t, count.warnings, 1)
	_, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	testing.expect(t, texture_pool_ready(&f.r.texture_pool, 1))

	// It does not grow again, whatever the process uses, and the same quality does not undo it.
	f.fake.others = 0
	residency_set_texture_pool(f.r, 64)
	for _ in 0 ..< 2 * TEXTURE_BUDGET_CHECK_FRAMES {
		step(t, f)
	}
	testing.expect_value(t, texture_stream_stats(f.r).capacity_pages, 2 * 256)
	testing.expect_value(t, count.warnings, 1)

	// A new quality budget replaces the limit: 32 MiB is seven layers, all for the one format that is in use.
	residency_set_texture_pool(f.r, 32)
	step(t, f)
	testing.expect_value(t, texture_stream_stats(f.r).capacity_pages, 7 * 256)

	// It never goes below a layer for the format of each texture, however little the budget leaves.
	f.fake.others = 400 * mem.Megabyte
	for _ in 0 ..< 2 * TEXTURE_BUDGET_CHECK_FRAMES {
		step(t, f)
	}
	testing.expect_value(t, texture_stream_stats(f.r).capacity_pages, 256)
	testing.expect_value(t, count.warnings, 2)
	for _ in 0 ..< 3 {
		step(t, f)
	}
	testing.expect(t, texture_pool_ready(&f.r.texture_pool, 1))
	testing.expect_value(t, count.errors, 0)
}

@(test)
the_atlases_share_the_pool_by_format :: proc(t: ^testing.T) {
	f := texture_fixture(t, 64)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	color := format.guid_parse("00000000000000000000000000000301") or_else {}
	normal := format.guid_parse("00000000000000000000000000000302") or_else {}
	write_texture(t, f, color, {1024, 1024}, time.now())
	write_texture(t, f, normal, {1024, 1024}, time.now(), .BC5_Unorm, 5)
	resident_virtual_texture(f.r, color)
	resident_virtual_texture(f.r, normal)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	pool := &f.r.texture_pool
	// Each format has an atlas of its own, made with its share of the budget when its first texture came.
	testing.expect_value(t, pool.atlas_count, 2)
	testing.expect_value(t, pool.atlases[0].format, gpu.Format.BC7_Unorm_Srgb)
	testing.expect_value(t, pool.atlases[1].format, gpu.Format.BC5_Unorm)
	testing.expect_value(t, pool.atlases[0].layers, 7)
	testing.expect_value(t, pool.atlases[1].layers, 4)
	_, ready := resident_virtual_texture(f.r, normal)
	testing.expect(t, ready)
	first, _ := resident_virtual_texture(f.r, color)
	second, _ := resident_virtual_texture(f.r, normal)
	testing.expect_value(t, texture_pool_resident(pool, first.virtual, 84), true)
	testing.expect_value(t, texture_pool_resident(pool, second.virtual, 84), true)
	testing.expect_value(t, pool.textures[first.virtual - 1].atlas, 0)
	testing.expect_value(t, pool.textures[second.virtual - 1].atlas, 1)

	// When the pool is made again, the layers go to the formats by what they were in demand: the color texture's pages are
	// wanted, and the normal map's are not.
	wants := fine_pages(f, first.virtual, {0, 8}, 8)
	run_frames(t, f, wants, 12, first.virtual)
	residency_set_texture_pool(f.r, 32)
	step(t, f)
	testing.expect(t, pool.atlases[0].layers > pool.atlases[1].layers)
	testing.expect(t, pool.atlases[1].layers >= 1)
	_, ready = resident_virtual_texture(f.r, normal)
	testing.expect(t, ready)
}

@(test)
a_virtual_textures_new_blob_takes_the_place_of_the_old :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	start := time.now()
	write_texture(t, f, guid, {512, 384}, start, seed = 1)
	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	texture, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	old := texture.virtual
	fine := page_entry(f, old, 0, 1, 1)
	for _ in 0 ..< 3 {
		step(t, f, {{fine, 2}})
	}
	// The page, the page that covers it, and the root.
	testing.expect_value(t, resident_set(f, old), 3)

	// The cooker writes the texture again. The new version streams beside the old, which draws until the new one's root
	// and tail are in.
	write_texture(t, f, guid, {512, 384}, time.time_add(start, 2 * time.Second), seed = 2, key = 1)
	testing.expect_value(t, len(asset.poll(&f.assets)), 1)
	step(t, f)
	texture, ready = resident_virtual_texture(f.r, guid)
	testing.expect(
		t,
		ready && texture.virtual == old,
		"the old version draws while the new one streams",
	)
	live := 0
	for tex in f.r.texture_pool.textures {
		live += int(tex.live)
	}
	testing.expect_value(t, live, 2)
	// The new version has a range of its own, past the old one's.
	testing.expect_value(t, f.r.texture_pool.textures[1].first, 17)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	texture, ready = resident_virtual_texture(f.r, guid)
	testing.expect(t, ready && texture.virtual != old && texture.virtual != 0)
	live = 0
	for tex in f.r.texture_pool.textures {
		live += int(tex.live)
	}
	testing.expect_value(t, live, 1)
	// The old one's tiles are free: the new one's root alone is in, and one tail and one atlas are left.
	testing.expect_value(t, texture_stream_stats(f.r).resident_pages, 1)
	testing.expect_value(t, f.r.texture_pool.atlases[0].textures, 1)
	testing.expect_value(t, f.fake.live_textures, 2)
	testing.expect_value(t, len(f.r.texture_pool.cooling), 1)
	// The old range and record wait before another texture takes them.
	for _ in 0 ..< TEXTURE_TABLE_COOL_FRAMES {
		step(t, f)
	}
	testing.expect_value(t, len(f.r.texture_pool.cooling), 0)
	testing.expect_value(t, len(f.r.texture_pool.free_ids), MAX_VIRTUAL_TEXTURES - 1)
}

@(test)
a_whole_texture_is_assembled_from_the_pages :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	tex := write_texture(t, f, guid, {512, 384}, time.now())
	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	virtual, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	tail_texture := virtual.texture
	streams := len(f.fake.streams)

	// A reader that needs a whole texture asks, and gets nothing until it is in: never the virtual texture's own tail.
	whole, whole_ready := resident_texture(f.r, guid)
	testing.expect(t, !whole_ready)
	_, assembling := f.r.entries[0].current.(Texture_Resources).whole_state.(Whole_Assembling)
	testing.expect(t, assembling)
	for _ in 0 ..< 3 {
		step(t, f)
		whole, whole_ready = resident_texture(f.r, guid)
		testing.expect(t, !whole_ready)
	}
	// The 16 pages that are not the root came in one read of a range of the file, and the texture streamed as the
	// original's every mip.
	chain := make([dynamic]byte, context.temp_allocator)
	for mip in tex.mips {
		append(&chain, ..mip)
	}
	if testing.expect_value(t, len(f.fake.streams), streams + 1) {
		testing.expect(
			t,
			slice.equal(f.fake.streams[streams], chain[:]),
			"the pages make the original mips",
		)
	}
	testing.expect_value(t, f.fake.reads_begun, 1)
	testing.expect_value(t, f.fake.reads_open, 0)
	_, streaming := f.r.entries[0].current.(Texture_Resources).whole_state.(Whole_Streaming)
	testing.expect(t, streaming)

	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	whole, whole_ready = resident_texture(f.r, guid)
	testing.expect(t, whole_ready)
	testing.expect(t, whole.texture != {} && whole.texture != tail_texture)
	testing.expect_value(t, whole.size, [2]u32{512, 384})
	testing.expect_value(t, whole.mip_count, 10)
	testing.expect_value(t, whole.virtual, 0)
	testing.expect_value(t, whole.dimension, format.Texture_Dimension.D2)
	// The material's reader still gets the virtual texture, and the whole texture is a second one beside it. The pool's
	// pages are as they were: assembling it took none.
	virtual, ready = resident_virtual_texture(f.r, guid)
	testing.expect(t, ready && virtual.virtual != 0 && virtual.texture == tail_texture)
	testing.expect_value(t, texture_stream_stats(f.r).resident_pages, 1)
	// A reader of another dimension is not given it.
	context.logger = testlog.expected_errors()
	_, other := resident_texture(f.r, guid, .Cube)
	testing.expect(t, !other)
}

@(test)
a_page_that_is_not_what_its_table_names_is_logged_once :: proc(t: ^testing.T) {
	f := texture_fixture(t)
	context.user_ptr = &f.fake
	defer texture_fixture_destroy(t, f)
	count := Log_Count {
		inner = context.logger,
	}
	context.logger = {count_logs, &count, .Debug, {}}
	guid := format.guid_parse("00000000000000000000000000000301") or_else {}
	start := time.now()
	tex := write_texture(t, f, guid, {1024, 1024}, start)
	// A byte of a page's block is not what the table says, in the file.
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer))
	tex.blob[tex.pages[0].offset + 1] ~= 0xff
	testing.expect(t, os.write_entire_file(path, tex.blob) == nil)
	testing.expect(t, os.change_times(path, start, start) == nil)

	resident_virtual_texture(f.r, guid)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	step(t, f)
	texture, ready := resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)
	id := texture.virtual
	good := page_entry(f, id, 0, 1, 0)
	broken := page_entry(f, id, 0, 0, 0)
	for _ in 0 ..< 3 {
		step(t, f, {{broken, 2}})
	}
	testing.expect_value(t, count.errors, 1)
	testing.expect(t, texture_pool_failed(&f.r.texture_pool, id))
	testing.expect(t, !texture_pool_resident(&f.r.texture_pool, id, 0))

	// The texture asks for no more pages, and says nothing more, but it goes on drawing from what it has.
	begun := f.fake.reads_begun
	for _ in 0 ..< 3 {
		step(t, f, {{broken, 2}, {good, 2}})
	}
	testing.expect_value(t, f.fake.reads_begun, begun)
	testing.expect_value(t, count.errors, 1)
	testing.expect_value(t, texture_stream_stats(f.r).pending_pages, 0)
	testing.expect(
		t,
		!texture_pool_resident(
			&f.r.texture_pool,
			id,
			good - f.r.texture_pool.textures[id - 1].first,
		),
	)
	_, ready = resident_virtual_texture(f.r, guid)
	testing.expect(t, ready)

	// The cooker's next blob is a new version, which asks again.
	write_texture(
		t,
		f,
		guid,
		{1024, 1024},
		time.time_add(start, 2 * time.Second),
		seed = 3,
		key = 1,
	)
	testing.expect_value(t, len(asset.poll(&f.assets)), 1)
	for _ in 0 ..< 4 {
		f.fake.done_through = f.fake.next_transfer
		step(t, f)
	}
	texture, ready = resident_virtual_texture(f.r, guid)
	testing.expect(t, ready && texture.virtual != id)
	good = page_entry(f, texture.virtual, 0, 1, 0)
	for _ in 0 ..< 3 {
		step(t, f, {{good, 2}})
	}
	first := f.r.texture_pool.textures[texture.virtual - 1].first
	testing.expect(t, texture_pool_resident(&f.r.texture_pool, texture.virtual, good - first))
	testing.expect_value(t, count.errors, 1)
}
