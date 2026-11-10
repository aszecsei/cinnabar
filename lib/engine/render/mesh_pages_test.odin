package render

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
import "cinnabar:core/lz4"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// A fake platform for the pool of mesh pages: it counts buffers and acceleration structures, keeps the readback
// buffers' bytes, gives uploads from the heap, runs jobs where they are started, and reads file ranges when they are
// asked for, or when the test lets them go. Each test has its own, in its context's user pointer.
@(private)
Page_Fake :: struct {
	next_buffer:   u32,
	live_buffers:  int,
	readbacks:     map[u32][]byte,
	uploads:       [dynamic][]byte,
	// The sizes of the buffers that streamed, and the transfers that are done.
	streamed:      [dynamic]int,
	next_transfer: u64,
	done_through:  u64,
	accels:        int,
	reads:         [64]Fake_Read,
	reads_begun:   int,
	reads_open:    int,
	// While set, a read that begins stays pending.
	hold_reads:    bool,
}

@(private)
Fake_Read :: struct {
	open:    bool,
	pending: bool,
	path:    string,
	offset:  i64,
	data:    []byte,
	ok:      bool,
}

@(private = "file")
page_fake :: proc() -> ^Page_Fake {
	return (^Page_Fake)(context.user_ptr)
}

@(private = "file")
finish_read :: proc(read: ^Fake_Read) {
	read.ok = core.file_read_range(read.path, read.offset, read.data) == len(read.data)
	read.pending = false
}

// page_file_reads gives a platform the fake's reads of file ranges, for a test whose context's user pointer is a
// Page_Fake. page_fake_reads_destroy frees what they left.
@(private)
page_file_reads :: proc(platform: ^core.Platform_API) {
	fake := page_platform(nil)
	platform.file_read_range = fake.file_read_range
	platform.file_read_begin, platform.file_read_result, platform.file_read_end = fake.file_read_begin, fake.file_read_result, fake.file_read_end
}

@(private = "file")
page_platform :: proc(frame: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator = frame != nil ? virtual.arena_allocator(frame) : {},
		asset_allocator = runtime.heap_allocator(),
		heap_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_read_range = core.file_read_range,
		file_modified = core.file_modified,
		file_read_begin = proc(path: string, offset: i64, size: int) -> core.File_Read {
			fake := page_fake()
			for &read, i in fake.reads {
				if read.open {
					continue
				}
				read = {open = true, pending = true, path = fmt.aprintf("%s", path), offset = offset, data = make([]byte, size)}
				fake.reads_begun += 1
				fake.reads_open += 1
				if !fake.hold_reads {
					finish_read(&read)
				}
				return core.File_Read(i + 1)
			}
			return 0
		},
		file_read_result = proc(read: core.File_Read) -> ([]byte, core.File_Read_State) {
			fake := page_fake()
			if read == 0 || !fake.reads[read - 1].open {
				return nil, .Failed
			}
			r := &fake.reads[read - 1]
			if r.pending {
				return nil, .Pending
			}
			return r.data, r.ok ? .Done : .Failed
		},
		file_read_end = proc(read: core.File_Read) {
			fake := page_fake()
			if read != 0 && fake.reads[read - 1].open {
				delete(fake.reads[read - 1].path)
				delete(fake.reads[read - 1].data)
				fake.reads[read - 1] = {}
				fake.reads_open -= 1
			}
		},
		jobs_run = proc(list: []jobs.Job, counter: ^jobs.Counter) {
			for job in list {
				job.procedure(job.data)
			}
		},
		jobs_wait = proc(counter: ^jobs.Counter) {},
		gpu_create_buffer = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
			fake := page_fake()
			fake.next_buffer += 1
			fake.live_buffers += 1
			if .Readback in desc.usage {
				fake.readbacks[fake.next_buffer] = make([]byte, desc.size)
			}
			return transmute(gpu.Buffer)[2]u32{fake.next_buffer, 1}
		},
		gpu_destroy_buffer = proc(buffer: gpu.Buffer) {
			if buffer != {} {
				fake := page_fake()
				fake.live_buffers -= 1
				id := (transmute([2]u32)buffer)[0]
				if bytes, found := fake.readbacks[id]; found {
					delete(bytes)
					delete_key(&fake.readbacks, id)
				}
			}
		},
		gpu_read_buffer = proc(buffer: gpu.Buffer) -> ([]byte, bool) {
			bytes, found := page_fake().readbacks[(transmute([2]u32)buffer)[0]]
			return bytes, found
		},
		gpu_upload = proc(size, align: int) -> (gpu.Upload, bool) {
			fake := page_fake()
			data, _ := mem.alloc_bytes(size, max(align, 16))
			append(&fake.uploads, data)
			return {data = data, buffer = transmute(gpu.Buffer)[2]u32{0xffff, 1}}, true
		},
		gpu_stream_buffer = proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {
			assert(len(data) % 4 == 0, "a buffer stream is a multiple of 4 bytes")
			fake := page_fake()
			append(&fake.streamed, len(data))
			fake.next_transfer += 1
			return gpu.Transfer(fake.next_transfer)
		},
		gpu_transfer_done = proc(transfer: gpu.Transfer) -> bool {
			return u64(transfer) <= page_fake().done_through
		},
		gpu_create_accel = proc(desc: gpu.Accel_Struct_Desc) -> gpu.Accel_Struct {
			fake := page_fake()
			fake.accels += 1
			return transmute(gpu.Accel_Struct)[2]u32{u32(fake.accels), 1}
		},
		gpu_destroy_accel = proc(accel: gpu.Accel_Struct) {
			if accel != {} {
				page_fake().accels -= 1
			}
		},
	}
}

// Test_Page is a page of a test's mesh: its level, and for each of its meshlets the page of the group that it was
// simplified from, or MESH_PAGE_NONE. Each meshlet is one triangle of three vertices of its own.
@(private)
Test_Page :: struct {
	depth:   u8,
	refined: []u32,
}

// paged_mesh_bytes is a paged mesh blob of one submesh with these pages, the last of which is the root. A page depends
// on the pages that hold meshlets simplified from it.
@(private)
paged_mesh_bytes :: proc(guid: format.Guid, pages: []Test_Page, key: u64 = 0) -> []byte {
	stride := int(format.mesh_attribute_stride({}))
	entries := make([]format.Page_Entry, len(pages), context.temp_allocator)
	dependencies := make([][dynamic]u32, len(pages), context.temp_allocator)
	for &d in dependencies {
		d = make([dynamic]u32, context.temp_allocator)
	}
	meshlets, vertices, indices: u32
	for page, p in pages {
		count := u32(len(page.refined))
		records := make([]format.Meshlet, count, context.temp_allocator)
		refs := make([dynamic]u32, context.temp_allocator)
		triangles := make([dynamic]u32, context.temp_allocator)
		for &m, i in records {
			m = {triangle_count = 1, depth = page.depth, parent_error = max(f32), refined_page = page.refined[i]}
			format.meshlet_write_vertices(&m, []u32{u32(i) * 3, u32(i) * 3 + 1, u32(i) * 3 + 2}, &refs)
			m.triangle_offset = u32(len(triangles))
			append(&triangles, u32(0 | 1 << 8 | 2 << 16))
			if page.refined[i] != format.MESH_PAGE_NONE && int(page.refined[i]) != p && !slice.contains(dependencies[page.refined[i]][:], u32(p)) {
				append(&dependencies[page.refined[i]], u32(p))
			}
		}
		header := format.Mesh_Page_Header {
			meshlet_count  = count,
			vertex_count   = count * 3,
			ref_words      = u32(len(refs)),
			triangle_words = u32(len(triangles)),
		}
		header.vertex_refs = size_of(format.Mesh_Page_Header) + count * size_of(format.Meshlet)
		header.triangles = header.vertex_refs + header.ref_words * 4
		header.positions = header.triangles + header.triangle_words * 4
		header.attributes = header.positions + header.vertex_count * 12
		size := int(header.attributes) + int(header.vertex_count) * stride
		bytes := make([]byte, size, context.temp_allocator)
		mem.copy(raw_data(bytes), &header, size_of(header))
		copy(bytes[size_of(format.Mesh_Page_Header):], mem.slice_to_bytes(records))
		copy(bytes[header.vertex_refs:], mem.slice_to_bytes(refs[:]))
		copy(bytes[header.triangles:], mem.slice_to_bytes(triangles[:]))
		// A position that says which vertex of which page it is.
		for v in 0 ..< int(header.vertex_count) {
			(^[3]f32)(&bytes[int(header.positions) + v * 12])^ = {f32(p), f32(v), 0}
		}
		block := lz4.compress(bytes, make([]byte, lz4.bound(size), context.temp_allocator))
		level0 := page.depth == 0 ? count : 0
		entries[p] = {
			record = {
				size = u32(size),
				checksum = hash.fnv32a(block),
				first_meshlet = meshlets,
				meshlet_count = count,
				level0_meshlets = level0,
				first_vertex = level0 > 0 ? vertices : 0,
				vertex_count = header.vertex_count,
				flags = p == len(pages) - 1 ? {.Root} : {},
			},
			compressed = block,
		}
		meshlets += count
		if level0 > 0 {
			vertices += header.vertex_count
			indices += count * 3
		}
	}
	for &e, p in entries {
		slice.sort(dependencies[p][:])
		e.dependencies = dependencies[p][:]
	}
	written := format.mesh_write(
		{
			guid = guid,
			key = key,
			flags = {.Paged},
			vertex_count = vertices,
			index_count = indices,
			meshlet_count = meshlets,
			submeshes = {{index_count = indices, meshlet_count = meshlets}},
			pages = entries,
		},
		context.temp_allocator,
	)
	aligned, _ := mem.alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, written)
	return aligned
}

@(private = "file")
NONE :: format.MESH_PAGE_NONE

// chain_pages is a mesh of four levels in six pages: two of level 0, two of level 1, each simplified from one of them,
// one of level 2 simplified from both, and the root. So page 0 depends on 2, 1 on 3, 2 and 3 on 4, and 4 on 5.
@(private)
chain_pages :: proc() -> []Test_Page {
	pages := make([]Test_Page, 6, context.temp_allocator)
	pages[0] = {0, slice.clone([]u32{NONE}, context.temp_allocator)}
	pages[1] = {0, slice.clone([]u32{NONE}, context.temp_allocator)}
	pages[2] = {1, slice.clone([]u32{0}, context.temp_allocator)}
	pages[3] = {1, slice.clone([]u32{1}, context.temp_allocator)}
	pages[4] = {2, slice.clone([]u32{2, 3}, context.temp_allocator)}
	pages[5] = {3, slice.clone([]u32{4}, context.temp_allocator)}
	return pages
}

// star_pages is a mesh of `count` level 0 pages and a root of a meshlet simplified from each, so each page depends on
// the root alone.
@(private = "file")
star_pages :: proc(count: int) -> []Test_Page {
	pages := make([]Test_Page, count + 1, context.temp_allocator)
	refined := make([]u32, count, context.temp_allocator)
	for &page, i in pages[:count] {
		page = {0, slice.clone([]u32{NONE}, context.temp_allocator)}
		refined[i] = u32(i)
	}
	pages[count] = {1, refined}
	return pages
}

@(private = "file")
Page_Fixture :: struct {
	fake:     Page_Fake,
	frame:    virtual.Arena,
	platform: core.Platform_API,
	dir:      string,
	assets:   asset.Assets,
	r:        ^Residency,
}

@(private = "file")
page_fixture :: proc(t: ^testing.T, slots: u32 = 64) -> ^Page_Fixture {
	f := new(Page_Fixture)
	f.fake.readbacks = make(map[u32][]byte)
	testing.expect(t, virtual.arena_init_growing(&f.frame) == nil)
	f.platform = page_platform(&f.frame)
	dir, err := os.make_directory_temp("", "mesh_pages_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	asset.init(&f.assets, &f.platform, asset.loose_cache(f.dir))
	f.r = new(Residency)
	residency_init(f.r, &f.platform, &f.assets)
	f.r.pool.wanted_slots = slots
	return f
}

@(private = "file")
page_fixture_destroy :: proc(t: ^testing.T, f: ^Page_Fixture) {
	residency_destroy(f.r)
	// Everything that the residency made is gone: its buffers, its reads and its acceleration structures.
	testing.expect_value(t, f.fake.live_buffers, 0)
	testing.expect_value(t, f.fake.reads_open, 0)
	testing.expect_value(t, f.fake.accels, 0)
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
	virtual.arena_destroy(&f.frame)
	free(f)
}

@(private = "file")
write_paged :: proc(t: ^testing.T, f: ^Page_Fixture, guid: format.Guid, pages: []Test_Page, modified: time.Time, key: u64 = 0) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(guid, &buffer))
	blob := paged_mesh_bytes(guid, pages, key)
	_, valid := format.mesh_view(blob)
	testing.expect(t, valid, "the test's blob is a paged mesh")
	testing.expect(t, os.write_entire_file(path, blob) == nil)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
	generation := fmt.tprintf("%s/%s", f.dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("1")) == nil)
	testing.expect(t, os.change_times(generation, modified, modified) == nil)
}

// Want is a word of the feedback: a page that a view wants, by how much, or with no priority a page that a view drew
// from.
@(private = "file")
Want :: struct {
	entry:    u32,
	priority: f32,
}

// step is one frame: the feedback that came back, the residency's update, the stream pages pass, and its commit if the
// frame executes. After it, every page with a slot has what it depends on in slots too.
@(private = "file")
step :: proc(t: ^testing.T, f: ^Page_Fixture, wants: []Want = nil, executes := true) -> ^Stream_Pages {
	pool := &f.r.pool
	if pool.pool != {} {
		data, _ := f.platform.gpu_read_buffer(pool.ring.copies[pool.ring.next])
		mem.zero_slice(data)
		words := slice.reinterpret([]u32, data)
		for w in wants {
			words[w.entry] = w.priority > 0 ? transmute(u32)w.priority : 1
		}
		mark_readback_copied(&pool.ring, pool.ring.next)
	}
	residency_update(f.r)
	sp := prepare_stream_pages(pool, &f.platform, &f.assets)
	if sp != nil && executes {
		commit_stream_pages(sp)
	}
	residents: u32
	for &mesh in pool.meshes {
		if !mesh.live {
			continue
		}
		for record, i in mesh.records {
			entry := mesh.first + u32(i)
			slot, has := pool_page_slot(pool, entry)
			if !has {
				continue
			}
			residents += 1
			testing.expect_value(t, pool.slots[slot], entry)
			for d in mesh.dependencies[record.first_dependency:][:record.dependency_count] {
				_, dependency_has := pool_page_slot(pool, d)
				testing.expectf(t, dependency_has, "page %d has a slot, and page %d that it depends on has none", entry, d)
			}
		}
	}
	testing.expectf(t, residents <= u32(len(pool.slots)), "%d pages are in %d slots", residents, len(pool.slots))
	return sp
}

@(private = "file")
pool_page_slot :: proc(pool: ^Mesh_Pool, entry: u32) -> (slot: u32, has: bool) {
	#partial switch s in pool.pages[entry].state {
	case Page_Copying:
		return s.slot, true
	case Page_Resident:
		return s.slot, true
	}
	return
}

@(private = "file")
residents :: proc(f: ^Page_Fixture, id: u32, count: u32) -> (set: [64]bool, total: int) {
	for page in 0 ..< count {
		set[page] = mesh_pool_resident(&f.r.pool, id, page)
		total += int(set[page])
	}
	return
}

@(test)
a_paged_mesh_is_ready_when_its_roots_are_in_the_pool :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	write_paged(t, f, guid, chain_pages(), time.now())

	mesh, ready := resident_mesh(f.r, guid)
	testing.expect(t, !ready)
	// The pool, the table, the feedback and its three copies, and no buffer of the mesh's own.
	testing.expect_value(t, f.fake.live_buffers, 6)
	testing.expect_value(t, len(f.fake.streamed), 0)

	// The first frame copies the root, from the head, and the second finds it in.
	sp := step(t, f)
	testing.expect(t, sp != nil)
	if sp != nil {
		testing.expect_value(t, len(sp.loads), 1)
		// The table says where each page is: the root in its slot, and the others absent, each with its first meshlet.
		testing.expect_value(t, len(sp.entries), 6)
		testing.expect_value(t, len(sp.runs), 1)
		values := slice.reinterpret([]Table_Entry, sp.table_upload.data[:6 * size_of(Table_Entry)])
		for value, page in values {
			testing.expect_value(t, value.slot != MESH_PAGE_ABSENT, page == 5)
		}
		testing.expect_value(t, values[4].first_meshlet, 4)
		testing.expect_value(t, values[5].first_meshlet, 6)
		// The upload is the page as the cooker wrote it.
		header := (^format.Mesh_Page_Header)(raw_data(sp.loads[0].upload.data))
		testing.expect_value(t, header.meshlet_count, 1)
	}
	_, ready = resident_mesh(f.r, guid)
	testing.expect(t, !ready, "the mesh is ready the frame after its root was copied")
	step(t, f)
	mesh, ready = resident_mesh(f.r, guid)
	testing.expect(t, ready)
	testing.expect(t, mesh.paged && mesh.page_count == 6 && mesh.pages_first == 0)
	testing.expect(t, mesh.positions == {} && mesh.meshlets == {})
	testing.expect_value(t, f.fake.reads_begun, 0)
	stats := mesh_stream_stats(f.r)
	testing.expect_value(t, stats.resident_pages, 1)
	testing.expect_value(t, stats.capacity_pages, 64)
	record := mesh_record(mesh)
	testing.expect(t, record.flags & MESH_RECORD_PAGED != 0 && record.page_count == 6)

	// The root stays wanted and resident with no view asking for it, and nothing else comes.
	for _ in 0 ..< 3 * MESH_PAGE_KEEP_FRAMES {
		step(t, f)
	}
	_, total := residents(f, mesh.pool_mesh, 6)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, mesh_stream_stats(f.r).pending_requests, 0)
}

@(test)
a_wanted_page_comes_in_after_what_it_depends_on :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	write_paged(t, f, guid, chain_pages(), time.now())
	mesh, _ := resident_mesh(f.r, guid)
	step(t, f)
	step(t, f)
	id := mesh.pool_mesh

	// A view wants page 0 alone. The pool asks for what it depends on as much, pages 2 and 4, though no view did: a page
	// depends on pages for all of its groups, and the walk asks only for the groups that show. All three come in one
	// frame, the fake's reads being done at once, each after what it depends on, and the pages that nothing needs do not.
	sp := step(t, f, {{0, 4}})
	testing.expect_value(t, f.fake.reads_begun, 3)
	testing.expect_value(t, mesh_stream_stats(f.r).pending_requests, 3)
	if testing.expect(t, sp != nil && len(sp.loads) == 3) {
		testing.expect_value(t, sp.loads[0].entry, 4)
		testing.expect_value(t, sp.loads[1].entry, 2)
		testing.expect_value(t, sp.loads[2].entry, 0)
		testing.expect_value(t, mesh_stream_stats(f.r).streamed_bytes, sp.loads[0].record.size + sp.loads[1].record.size + sp.loads[2].record.size)
	}
	set: [64]bool
	total: int
	set, total = residents(f, id, 6)
	testing.expect(t, total == 4 && set[0] && set[2] && set[4] && set[5] && !set[1] && !set[3])
	testing.expect_value(t, f.fake.reads_open, 0)
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, 4)

	// A page that is resident and wanted again counts as used, and is not read again.
	step(t, f, {{0, 4}, {2, 0}})
	testing.expect_value(t, f.fake.reads_begun, 3)
	testing.expect_value(t, mesh_stream_stats(f.r).pending_requests, 0)
}

@(test)
a_frame_starts_and_loads_no_more_pages_than_its_caps :: proc(t: ^testing.T) {
	f := page_fixture(t, 128)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	COUNT :: 60
	write_paged(t, f, guid, star_pages(COUNT), time.now())
	mesh, _ := resident_mesh(f.r, guid)
	step(t, f)
	step(t, f)
	id := mesh.pool_mesh

	wants := make([]Want, COUNT, context.temp_allocator)
	for &w, i in wants {
		w = {u32(i), 2 + f32(i)}
	}
	// The reads that are open at once, the most wanted first.
	f.fake.hold_reads = true
	step(t, f, wants)
	testing.expect_value(t, f.fake.reads_open, MESH_PAGE_READS)
	testing.expect_value(t, mesh_stream_stats(f.r).pending_requests, COUNT)
	for &read in f.fake.reads {
		if read.open {
			finish_read(&read)
		}
	}
	f.fake.hold_reads = false
	// Each frame loads a frame's count, and starts reads in the places of the ones that it ended.
	sp := step(t, f, wants)
	if testing.expect(t, sp != nil) {
		testing.expect_value(t, len(sp.loads), MESH_PAGE_LOADS_PER_FRAME)
		testing.expect_value(t, sp.loads[0].entry, COUNT - 1)
	}
	_, total := residents(f, id, COUNT + 1)
	testing.expect_value(t, total, 1 + MESH_PAGE_LOADS_PER_FRAME)
	for _ in 0 ..< 8 {
		step(t, f, wants)
	}
	_, total = residents(f, id, COUNT + 1)
	testing.expect_value(t, total, COUNT + 1)
	testing.expect_value(t, f.fake.reads_begun, COUNT)
	testing.expect_value(t, f.fake.reads_open, 0)

	// A read that nothing wants any more is ended, and its page is absent again.
	other := format.guid_parse("00000000000000000000000000000253") or_else {}
	write_paged(t, f, other, chain_pages(), time.now())
	resident_mesh(f.r, other)
	step(t, f)
	step(t, f)
	first := f.r.pool.meshes[1].first
	f.fake.hold_reads = true
	// The page, and the two that it depends on.
	step(t, f, {{first, 3}})
	testing.expect_value(t, f.fake.reads_open, 3)
	for _ in 0 ..< MESH_PAGE_FORGET_FRAMES + 2 {
		step(t, f)
	}
	testing.expect_value(t, f.fake.reads_open, 0)
}

@(test)
the_least_recently_used_pages_leave_a_full_pool :: proc(t: ^testing.T) {
	f := page_fixture(t, MESH_POOL_MIN_SLOTS)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	COUNT :: 40
	write_paged(t, f, guid, star_pages(COUNT), time.now())
	chain := format.guid_parse("00000000000000000000000000000253") or_else {}
	write_paged(t, f, chain, chain_pages(), time.now())
	mesh, _ := resident_mesh(f.r, guid)
	resident_mesh(f.r, chain)
	step(t, f)
	step(t, f)
	id := mesh.pool_mesh
	chain_id: u32 = id == 1 ? 2 : 1
	chain_first := f.r.pool.meshes[chain_id - 1].first
	testing.expect_value(t, mesh_stream_stats(f.r).capacity_pages, MESH_POOL_MIN_SLOTS)

	// The pool fills: the two roots, the chain's pages 4, 2 and 0, and eleven of the star's.
	wants := make([dynamic]Want, context.temp_allocator)
	append(&wants, Want{chain_first + 0, 4}, Want{chain_first + 2, 5}, Want{chain_first + 4, 6})
	for page in 0 ..< u32(11) {
		append(&wants, Want{f.r.pool.meshes[id - 1].first + page, 3})
	}
	for _ in 0 ..< 4 {
		step(t, f, wants[:])
	}
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, MESH_POOL_MIN_SLOTS)
	testing.expect_value(t, len(f.r.pool.free_slots), 0)

	// More is wanted than fits, while everything in the pool is still used: nothing leaves, and the rest waits.
	first := f.r.pool.meshes[id - 1].first
	more := slice.clone_to_dynamic(wants[:], context.temp_allocator)
	for page in 11 ..< u32(20) {
		append(&more, Want{first + page, 2})
	}
	for _ in 0 ..< 3 * MESH_PAGE_KEEP_FRAMES {
		step(t, f, more[:])
	}
	set, _ := residents(f, id, COUNT + 1)
	for page in 11 ..< 20 {
		testing.expectf(t, !set[page], "page %d took the slot of a page that a view was using", page)
	}
	testing.expect_value(t, mesh_stream_stats(f.r).pending_requests, 9)

	// The views stop using the star's pages 0 to 4, and after the frames that a page is kept for, pages 11 to 15 take
	// their slots: the ones that were used longest ago leave, and no others.
	later := make([dynamic]Want, context.temp_allocator)
	append(&later, Want{chain_first + 0, 0}, Want{chain_first + 2, 0}, Want{chain_first + 4, 0})
	for page in 5 ..< u32(11) {
		append(&later, Want{first + page, 0})
	}
	for page in 11 ..< u32(16) {
		append(&later, Want{first + page, 2})
	}
	for _ in 0 ..< 3 * MESH_PAGE_KEEP_FRAMES {
		step(t, f, later[:])
	}
	set, _ = residents(f, id, COUNT + 1)
	for page in 0 ..< 16 {
		testing.expectf(t, set[page] == (page >= 5), "page %d is resident: %v", page, set[page])
	}
	testing.expect(t, set[COUNT], "the root never leaves")
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, MESH_POOL_MIN_SLOTS)

	// Nothing uses the chain any more, and the star wants its slots. Its page 0 leaves, then 2, then 4, each only when
	// nothing in the pool depends on it, and its root stays.
	last := make([dynamic]Want, context.temp_allocator)
	for page in 5 ..< u32(16) {
		append(&last, Want{first + page, 0})
	}
	for page in 16 ..< u32(19) {
		append(&last, Want{first + page, 2})
	}
	for _ in 0 ..< 6 * MESH_PAGE_KEEP_FRAMES {
		step(t, f, last[:])
	}
	chain_set, chain_total := residents(f, chain_id, 6)
	testing.expect(t, chain_total == 1 && chain_set[5], "the chain keeps its root alone")
	set, _ = residents(f, id, COUNT + 1)
	testing.expect(t, set[16] && set[17] && set[18])
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, MESH_POOL_MIN_SLOTS)
}

@(test)
a_frame_that_does_not_execute_copies_its_pages_again :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	write_paged(t, f, guid, chain_pages(), time.now())
	mesh, _ := resident_mesh(f.r, guid)

	// The root's frame fails: the mesh is not ready, the slot comes back, and the next frame copies the root and the
	// whole table again.
	failed := step(t, f, executes = false)
	testing.expect(t, failed != nil && len(failed.loads) == 1 && len(failed.entries) == 6)
	testing.expect_value(t, len(f.r.pool.free_slots), 63)
	again := step(t, f)
	testing.expect_value(t, len(f.r.pool.free_slots), 63)
	testing.expect(t, again != nil && len(again.loads) == 1 && len(again.entries) == 6)
	step(t, f)
	_, ready := resident_mesh(f.r, guid)
	testing.expect(t, ready)

	// A page whose read is done keeps its read through a frame that fails, and loads from it in the next.
	wants := []Want{{4, 3}}
	f.fake.hold_reads = true
	step(t, f, wants)
	finish_read(&f.fake.reads[0])
	f.fake.hold_reads = false
	failed = step(t, f, wants, executes = false)
	testing.expect(t, failed != nil && len(failed.loads) == 1)
	testing.expect(t, !mesh_pool_resident(&f.r.pool, mesh.pool_mesh, 4))
	testing.expect_value(t, f.fake.reads_open, 1)
	again = step(t, f, wants)
	testing.expect(t, again != nil && len(again.loads) == 1)
	testing.expect(t, mesh_pool_resident(&f.r.pool, mesh.pool_mesh, 4))
	testing.expect_value(t, f.fake.reads_begun, 1)
	testing.expect_value(t, f.fake.reads_open, 0)
	// The table's entry of the page went with the frame that executed, and nothing is left to send.
	testing.expect_value(t, len(f.r.pool.dirty), 0)
	settled := step(t, f, wants)
	testing.expect(t, settled != nil && len(settled.entries) == 0 && len(settled.loads) == 0)
}

@(test)
a_paged_meshs_new_blob_takes_the_place_of_the_old :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	start := time.now()
	write_paged(t, f, guid, chain_pages(), start)
	mesh, _ := resident_mesh(f.r, guid)
	step(t, f)
	step(t, f)
	wants := []Want{{2, 5}, {4, 6}}
	step(t, f, wants)
	step(t, f, wants)
	old := mesh.pool_mesh
	_, total := residents(f, old, 6)
	testing.expect_value(t, total, 3)

	// The cooker writes the mesh again, as a star. A page of the old blob is not read from the new file.
	write_paged(t, f, guid, star_pages(8), time.time_add(start, 2 * time.Second), 1)
	begun := f.fake.reads_begun
	step(t, f, {{0, 9}})
	testing.expect_value(t, f.fake.reads_begun, begun)

	// The new version streams beside the old, which draws until the new one's root is in. Then the old one's slots are
	// free, and its range of the table waits before a mesh takes it again.
	testing.expect_value(t, len(asset.poll(&f.assets)), 1)
	step(t, f)
	ready: bool
	mesh, ready = resident_mesh(f.r, guid)
	testing.expect(t, ready && mesh.pool_mesh == old, "the old version draws while the new one streams")
	step(t, f)
	step(t, f)
	mesh, ready = resident_mesh(f.r, guid)
	testing.expect(t, ready && mesh.pool_mesh != old && mesh.page_count == 9)
	testing.expect_value(t, mesh.pages_first, 6)
	_, total = residents(f, mesh.pool_mesh, 9)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, 1)
	testing.expect_value(t, len(f.r.pool.free_slots), 63)
	live := 0
	for m in f.r.pool.meshes {
		live += int(m.live)
	}
	testing.expect_value(t, live, 1)

	// A blob whose root is not what its table says does not become ready, and says so once.
	broken := format.guid_parse("00000000000000000000000000000254") or_else {}
	blob := paged_mesh_bytes(broken, chain_pages())
	view, _ := format.mesh_view(blob)
	root := format.mesh_pages(blob, view)[5]
	blob[root.offset + 1] ~= 0xff
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(broken, &buffer)), blob) == nil)
	context.logger = testlog.expected_errors()
	resident_mesh(f.r, broken)
	for _ in 0 ..< 4 {
		step(t, f)
	}
	_, ready = resident_mesh(f.r, broken)
	testing.expect(t, !ready)
	testing.expect(t, resident_failed(f.r, broken))
}

// A blob that the cooker writes again while the version before it is still streaming takes its place at once: the old
// version's roots were in the head that went, so it could never come in.
@(test)
a_new_blob_takes_over_from_one_whose_roots_are_not_in_yet :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	start := time.now()
	write_paged(t, f, guid, chain_pages(), start)
	_, ready := resident_mesh(f.r, guid)
	testing.expect(t, !ready)

	write_paged(t, f, guid, star_pages(8), time.time_add(start, 2 * time.Second), 1)
	testing.expect_value(t, len(asset.poll(&f.assets)), 1)
	for _ in 0 ..< 4 {
		step(t, f)
	}
	mesh, now_ready := resident_mesh(f.r, guid)
	testing.expect(t, now_ready && mesh.page_count == 9, "the new version is in")
	live := 0
	for m in f.r.pool.meshes {
		live += int(m.live)
	}
	testing.expect_value(t, live, 1)
	testing.expect(t, !resident_failed(f.r, guid))
}

@(test)
level_0_is_assembled_from_the_pages_when_something_asks :: proc(t: ^testing.T) {
	f := page_fixture(t)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	write_paged(t, f, guid, star_pages(5), time.now())
	resident_mesh(f.r, guid)
	step(t, f)
	step(t, f)
	mesh, ready := resident_mesh(f.r, guid)
	testing.expect(t, ready)
	testing.expect(t, mesh.level0 == nil, "nothing has asked for level 0")
	testing.expect_value(t, f.fake.reads_begun, 0)

	// What draws by index asks, and draws nothing until the buffers are in.
	_, whole := resident_whole_mesh(f.r, guid)
	testing.expect(t, !whole)
	_, assembling := mesh.level0.(Level0_Assembling)
	testing.expect(t, assembling)
	step(t, f)
	// One read took the five pages, which follow each other in the file.
	testing.expect_value(t, f.fake.reads_begun, 1)
	step(t, f)
	mesh, _ = resident_mesh(f.r, guid)
	_, streaming := mesh.level0.(Level0_Streaming)
	testing.expect(t, streaming)
	testing.expect_value(t, f.fake.reads_open, 0)
	// Fifteen vertices and fifteen 16-bit indices, padded to whole words.
	if testing.expect_value(t, len(f.fake.streamed), 3) {
		testing.expect_value(t, f.fake.streamed[0], 15 * 12)
		testing.expect_value(t, f.fake.streamed[1], 15 * int(format.mesh_attribute_stride({})))
		testing.expect_value(t, f.fake.streamed[2], 16 * 2)
	}
	_, whole = resident_whole_mesh(f.r, guid)
	testing.expect(t, !whole, "the buffers are not in yet")
	testing.expect(t, mesh.positions == {})

	// The ray scene's acceleration structure waits for level 0 too.
	residency_enable_accels(f.r)
	testing.expect_value(t, f.fake.accels, 0)
	f.fake.done_through = f.fake.next_transfer
	step(t, f)
	mesh, whole = resident_whole_mesh(f.r, guid)
	testing.expect(t, whole)
	testing.expect(t, mesh.positions != {} && mesh.attributes != {} && mesh.indices != {})
	testing.expect_value(t, mesh.index_count, 15)
	testing.expect_value(t, f.fake.accels, 1)
	testing.expect_value(t, len(unbuilt_accels(f.r)), 1)
	// No page came into the pool for it: the pool has the root alone.
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, 1)

	// With acceleration structures on, a mesh's level 0 is asked for as soon as the mesh is ready.
	other := format.guid_parse("00000000000000000000000000000253") or_else {}
	write_paged(t, f, other, chain_pages(), time.now())
	resident_mesh(f.r, other)
	for _ in 0 ..< 6 {
		f.fake.done_through = f.fake.next_transfer
		step(t, f)
	}
	second, _ := resident_mesh(f.r, other)
	_, second_ready := second.level0.(Level0_Ready)
	testing.expect(t, second_ready)
	testing.expect_value(t, second.vertex_count, 6)
	testing.expect_value(t, f.fake.accels, 2)
}

@(test)
a_pinned_mesh_keeps_every_page :: proc(t: ^testing.T) {
	f := page_fixture(t, MESH_POOL_MIN_SLOTS)
	context.user_ptr = &f.fake
	defer page_fixture_destroy(t, f)
	guid := format.guid_parse("00000000000000000000000000000252") or_else {}
	write_paged(t, f, guid, chain_pages(), time.now())
	star := format.guid_parse("00000000000000000000000000000253") or_else {}
	write_paged(t, f, star, star_pages(30), time.now())
	resident_mesh(f.r, guid)
	resident_mesh(f.r, star)
	step(t, f)
	step(t, f)
	mesh, _ := resident_mesh(f.r, guid)
	star_mesh, _ := resident_mesh(f.r, star)
	star_first := star_mesh.pages_first

	// What draws the mesh without a selection pins it each frame, and every page comes in with no view asking.
	for _ in 0 ..< 4 {
		resident_pin(f.r, mesh)
		step(t, f)
	}
	_, total := residents(f, mesh.pool_mesh, 6)
	testing.expect_value(t, total, 6)

	// Its pages stay while the pool is full and other pages are wanted, however long ago a view used them.
	wants := make([]Want, 20, context.temp_allocator)
	for &w, i in wants {
		w = {star_first + u32(i), 3}
	}
	for _ in 0 ..< 4 * MESH_PAGE_KEEP_FRAMES {
		resident_pin(f.r, mesh)
		step(t, f, wants)
	}
	_, total = residents(f, mesh.pool_mesh, 6)
	testing.expect_value(t, total, 6)
	testing.expect_value(t, mesh_stream_stats(f.r).resident_pages, MESH_POOL_MIN_SLOTS)

	// When nothing pins it, its pages leave for the ones that are wanted, down to its root.
	for _ in 0 ..< 8 * MESH_PAGE_KEEP_FRAMES {
		step(t, f, wants)
	}
	set, count := residents(f, mesh.pool_mesh, 6)
	testing.expect(t, count == 1 && set[5])

	// A smaller or larger budget makes the pool again, and the roots come back first. Until a frame has copied the
	// table for the new pool, the meshes draw nothing: the GPU's table names slots of the pool that went.
	residency_set_mesh_pool(f.r, 4)
	testing.expect_value(t, f.r.pool.wanted_slots, 32)
	step(t, f, executes = false)
	testing.expect_value(t, mesh_stream_stats(f.r).capacity_pages, 32)
	_, ready := resident_mesh(f.r, guid)
	testing.expect(t, ready, "the frame's own view draws after its pass, which copies the table")
	mesh_pool_not_sent(&f.r.pool)
	_, ready = resident_mesh(f.r, guid)
	testing.expect(t, !ready, "the frame did not execute, so its other views draw nothing of the mesh")
	step(t, f)
	step(t, f)
	_, ready = resident_mesh(f.r, guid)
	testing.expect(t, ready)
	testing.expect(t, mesh_pool_ready(&f.r.pool, mesh.pool_mesh) && mesh_pool_ready(&f.r.pool, star_mesh.pool_mesh))
}
