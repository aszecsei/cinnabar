// The pool of mesh pages: the pages of every paged mesh that are resident, in one buffer of slots, with the table that
// says which slot each page is in, the feedback that the selection writes, and the reads, the loads and the evictions
// that follow it. See docs/rendering/assets.md#mesh-pages.
package render

import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/jobs"
import "cinnabar:core/lz4"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// The pages of every resident paged mesh together, each with an entry of the table. A mesh that would pass it is not
// made resident.
MAX_MESH_PAGES :: 1 << 16
// A table entry's slot for a page that is not resident. Matches MESH_PAGE_ABSENT in mesh_pages.hlsli.
MESH_PAGE_ABSENT :: max(u32)
// A selected meshlet of a paged mesh is its page's slot above this bit and its index in the page below it. Matches
// MESH_PAGE_SLOT_SHIFT in mesh_pages.hlsli.
MESH_PAGE_SLOT_SHIFT :: 12
#assert(format.MESH_PAGE_SIZE / size_of(format.Meshlet) < 1 << MESH_PAGE_SLOT_SHIFT)
// The pool has at least this many slots, and at most what MESH_PAGE_SLOT_SHIFT leaves.
MESH_POOL_MIN_SLOTS :: 16
MESH_POOL_MAX_SLOTS :: 1 << (32 - MESH_PAGE_SLOT_SHIFT)
// The most reads of pages that are open at once.
MESH_PAGE_READS :: 32
// The most pages that a frame decompresses and copies into the pool: 2 MiB of the frame's uploads.
MESH_PAGE_LOADS_PER_FRAME :: 16
// A page that a view used within this many frames does not leave, so a pool that is too small for a view does not
// trade the view's pages for each other every frame.
MESH_PAGE_KEEP_FRAMES :: 4
// A read whose page no view has asked for in this many frames is ended.
MESH_PAGE_FORGET_FRAMES :: 30
// A mesh's range of the table is not given to another mesh for this many frames, in which the feedback of the frames
// that drew it comes back.
MESH_TABLE_COOL_FRAMES :: 8
// The most pages of level 0 that a frame decompresses for the meshes that assemble theirs.
LEVEL0_PAGES_PER_FRAME :: 32
// The most bytes of level 0 pages that one read takes.
LEVEL0_READ_SIZE :: 8 << 20

// Table_Entry is a page's entry of the table, which shaders read as it is: matches Mesh_Page_Entry in mesh_pages.hlsli.
// first_meshlet is the page's first meshlet in its mesh, which a draw without a selection finds a meshlet's page by.
Table_Entry :: struct {
	slot:          u32,
	first_meshlet: u32,
}

// Mesh_Stream_Stats is what the Resource Monitor shows of the pool: the pages that are resident, the slots, the pages
// that views asked for and that are not resident yet, the bytes that the last frame copied into the pool, and the
// bytes that every frame has, which a reader takes a rate from.
Mesh_Stream_Stats :: struct {
	resident_pages:   u32,
	capacity_pages:   u32,
	pending_requests: u32,
	streamed_bytes:   u32,
	streamed_total:   u64,
}

// Mesh_Pool is the pool's state, in Residency.
Mesh_Pool :: struct {
	// The slots, MESH_PAGE_SIZE bytes each, the table, and the feedback: a word for each table entry, which the selection
	// sets to 1 for a resident page that it draws from and raises to the projected error of a page that it wants.
	pool:        gpu.Buffer,
	table:       gpu.Buffer,
	feedback:    gpu.Buffer,
	ring:        Readback_Ring,
	slot_count:  u32,
	// What the renderer asked the pool to be, in slots. The pool is rebuilt when it differs from slot_count.
	wanted_slots: u32,
	// Each slot's table entry, or MESH_PAGE_ABSENT, and the free slots.
	slots:       []u32,
	free_slots:  [dynamic]u32,
	// Each table entry's page, the table as the GPU should have it, and the entries that it does not have yet.
	pages:       []Pool_Page,
	entries:     []Table_Entry,
	dirty:       [dynamic]u32,
	// The paged meshes, by their id less 1, the free ranges of the table as (first, count), and the ranges that wait.
	meshes:      [dynamic]Pool_Mesh,
	free_ranges: [dynamic][2]u32,
	cooling:     [dynamic]Cooling_Range,
	// One past the highest table entry that a mesh has had, which the feedback is zeroed and read back up to.
	high:        u32,
	frame:       u64,
	open_reads:  int,
	// The pages that the last update found wanted and not resident, by priority, most wanted first, in frame memory.
	wanted:      []Wanted_Page,
	stats:       Mesh_Stream_Stats,
	// Level 0 pages that this frame may still decompress.
	level0_budget: int,
	// Whether the GPU's table is of this pool. ensure_pool is its only writer with commit_stream_pages and
	// mesh_pool_not_sent.
	table_sync:  Table_Sync,
}

// Table_Sync is whether the GPU's page table says where pages are in the pool's buffer as it is now.
@(private)
Table_Sync :: enum u8 {
	// It does: every change since went through a pass that executed, or waits for one as a dirty entry.
	Current,
	// The pool's buffer was made again, and the table still names slots of the one before. Nothing may draw from it.
	Stale,
	// This frame's stream pages pass copies the whole table. The frame's own view may draw from the pool, as the pass
	// comes first in its graph. It is current once the frame executes, and stale again if it does not.
	Sent,
}

@(private)
Cooling_Range :: struct {
	range: [2]u32,
	until: u64,
}

@(private)
Wanted_Page :: struct {
	entry:    u32,
	priority: f32,
}

// Pool_Mesh is a paged mesh in the pool: its range of the table, and what reading its pages needs after its blob's head
// has gone from the frame.
@(private)
Pool_Mesh :: struct {
	live:         bool,
	guid:         format.Guid,
	// The asset that the head came from, with its version and its file's time then. A live mesh has no pages.
	handle:       asset.Handle,
	version:      u32,
	modified:     i64,
	first:        u32,
	count:        u32,
	stride:       u32,
	records:      []format.Mesh_Page,
	dependencies: []u32,
	// The frame that something last drew the mesh without a selection, which keeps every page of it.
	pinned_frame: u64,
	// A page of it was not what its table said, which was logged. It asks for no more.
	failed:       bool,
}

// Pool_Page is one table entry's page. change_page is the only writer of state.
@(private)
Pool_Page :: struct {
	// The mesh's id, or 0 for an entry that no mesh has.
	mesh:         u32,
	state:        Page_State,
	// The last frame that a view drew from it, and that a view wanted it.
	used_frame:   u64,
	wanted_frame: u64,
	// The most that anything wanted it by in wanted_frame.
	wanted_priority: f32,
	// The pages with a slot that depend on it. It keeps its slot while there are any.
	dependents:   u32,
	sync:         Entry_Sync,
}

// Entry_Sync is whether the GPU's table has an entry as the CPU's does. mark_dirty, add_stream_pages_pass, its commit and
// mesh_pool_update write it.
@(private)
Entry_Sync :: enum u8 {
	Clean,
	// Listed in Mesh_Pool.dirty for the next stream pages pass.
	Dirty,
	// A pass copies it this frame. It is clean once the frame executes, and dirty again if it does not.
	Sent,
}

// Page_State is where a page is. nil is absent: not resident, and not on its way.
@(private)
Page_State :: union {
	// The host reads its block from the blob's file.
	Page_Reading,
	// This frame copies it into its slot. It is resident once the frame executes, and reading again if it does not.
	Page_Copying,
	Page_Resident,
}

@(private)
Page_Reading :: struct {
	read: core.File_Read,
}

@(private)
Page_Copying :: struct {
	slot: u32,
	// 0 for a root, whose block is in the blob's head.
	read: core.File_Read,
}

@(private)
Page_Resident :: struct {
	slot: u32,
}

@(private = "file")
Page_Event :: union #no_nil {
	// A read of its block began.
	Page_Read_Began,
	// It took a slot, which this frame copies it into.
	Page_Took_Slot,
	// The frame that copied it executed.
	Page_Copied,
	// The frame that should have copied it did not execute.
	Page_Not_Copied,
	// It leaves: evicted, its read ended, or its mesh gone.
	Page_Left,
}

@(private = "file")
Page_Read_Began :: struct {
	read: core.File_Read,
}

@(private = "file")
Page_Took_Slot :: struct {
	slot: u32,
}

@(private = "file")
Page_Copied :: struct {}

@(private = "file")
Page_Not_Copied :: struct {}

@(private = "file")
Page_Left :: struct {}

// change_page is the one writer of a page's state (see docs/overview/conventions.md#state-with-a-lifecycle). It keeps
// with the state what follows from it: the slot's owner, the table's entry, the count of open reads and its
// dependencies' counts of dependents. It gives false for an event that the state does not take.
@(private = "file")
change_page :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, entry: u32, event: Page_Event) -> bool {
	page := &pool.pages[entry]
	take_slot :: proc(pool: ^Mesh_Pool, entry: u32, slot: u32) {
		pool.slots[slot] = entry
		for d in page_dependencies(pool, entry) {
			pool.pages[d].dependents += 1
		}
		// The table says so in the pass that copies the page, so the GPU sees both or neither.
		set_entry(pool, entry, slot)
	}
	give_slot :: proc(pool: ^Mesh_Pool, entry: u32, slot: u32) {
		pool.slots[slot] = MESH_PAGE_ABSENT
		append(&pool.free_slots, slot)
		for d in page_dependencies(pool, entry) {
			pool.pages[d].dependents -= 1
		}
		set_entry(pool, entry, MESH_PAGE_ABSENT)
	}
	end_read :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, read: core.File_Read) {
		if read != 0 {
			platform.file_read_end(read)
			pool.open_reads -= 1
		}
	}
	switch e in event {
	case Page_Read_Began:
		if page.state != nil || e.read == 0 {
			return false
		}
		pool.open_reads += 1
		page.state = Page_Reading{e.read}
	case Page_Took_Slot:
		read: core.File_Read
		if reading, is_reading := page.state.(Page_Reading); is_reading {
			read = reading.read
		} else if page.state != nil {
			return false
		}
		take_slot(pool, entry, e.slot)
		page.state = Page_Copying{e.slot, read}
	case Page_Copied:
		copying := page.state.(Page_Copying) or_return
		end_read(pool, platform, copying.read)
		page.state = Page_Resident{copying.slot}
		page.used_frame = pool.frame
	case Page_Not_Copied:
		copying := page.state.(Page_Copying) or_return
		give_slot(pool, entry, copying.slot)
		// Its read is still open, with its block.
		page.state = copying.read != 0 ? Page_Reading{copying.read} : nil
	case Page_Left:
		switch s in page.state {
		case Page_Reading:
			end_read(pool, platform, s.read)
		case Page_Copying:
			end_read(pool, platform, s.read)
			give_slot(pool, entry, s.slot)
		case Page_Resident:
			give_slot(pool, entry, s.slot)
		case:
			return false
		}
		page.state = nil
	}
	return true
}

// set_entry sets a table entry's slot, and lists the entry for the GPU.
@(private = "file")
set_entry :: proc(pool: ^Mesh_Pool, entry: u32, slot: u32) {
	pool.entries[entry].slot = slot
	mark_dirty(pool, entry)
}

@(private = "file")
mark_dirty :: proc(pool: ^Mesh_Pool, entry: u32) {
	if pool.pages[entry].sync != .Dirty {
		pool.pages[entry].sync = .Dirty
		append(&pool.dirty, entry)
	}
}

// page_record and page_dependencies are a table entry's record in its mesh's table, and the table entries of the pages
// that it depends on, in frame memory.
@(private = "file")
page_record :: proc(pool: ^Mesh_Pool, entry: u32) -> (mesh: ^Pool_Mesh, record: format.Mesh_Page) {
	mesh = &pool.meshes[pool.pages[entry].mesh - 1]
	return mesh, mesh.records[entry - mesh.first]
}

@(private = "file")
page_dependencies :: proc(pool: ^Mesh_Pool, entry: u32) -> []u32 {
	mesh, record := page_record(pool, entry)
	return mesh.dependencies[record.first_dependency:][:record.dependency_count]
}

@(private = "file")
page_slot :: proc(page: Pool_Page) -> (slot: u32, has: bool) {
	#partial switch s in page.state {
	case Page_Copying:
		return s.slot, true
	case Page_Resident:
		return s.slot, true
	}
	return
}

mesh_pool_init :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API) {
	pool^ = {}
}

// make_tables makes the pool's tables, the first time that a paged mesh is resident: a game without one has none.
@(private = "file")
make_tables :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API) {
	heap := platform.heap_allocator
	pool.pages = make([]Pool_Page, MAX_MESH_PAGES, heap)
	pool.entries = make([]Table_Entry, MAX_MESH_PAGES, heap)
	pool.free_slots = make([dynamic]u32, heap)
	pool.dirty = make([dynamic]u32, heap)
	pool.meshes = make([dynamic]Pool_Mesh, heap)
	pool.free_ranges = make([dynamic][2]u32, heap)
	pool.cooling = make([dynamic]Cooling_Range, heap)
	append(&pool.free_ranges, [2]u32{0, MAX_MESH_PAGES})
}

// mesh_pool_destroy ends every read and frees the pool. Call it with the meshes already removed or not: it removes what
// is left.
mesh_pool_destroy :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API) {
	if pool.pages == nil {
		return
	}
	for &m, i in pool.meshes {
		if m.live {
			mesh_pool_remove(pool, platform, u32(i + 1))
		}
	}
	platform.gpu_destroy_buffer(pool.pool)
	platform.gpu_destroy_buffer(pool.table)
	platform.gpu_destroy_buffer(pool.feedback)
	destroy_readback_ring(&pool.ring, platform)
	heap := platform.heap_allocator
	delete(pool.pages, heap)
	delete(pool.entries, heap)
	delete(pool.slots, heap)
	delete(pool.free_slots)
	delete(pool.dirty)
	delete(pool.meshes)
	delete(pool.free_ranges)
	delete(pool.cooling)
	pool^ = {}
}

// mesh_pool_slots is how many slots a budget in MiB gives.
mesh_pool_slots :: proc(megabytes: u32) -> u32 {
	slots := u64(megabytes) * mem.Megabyte / format.MESH_PAGE_SIZE
	return u32(clamp(slots, MESH_POOL_MIN_SLOTS, MESH_POOL_MAX_SLOTS))
}

// ensure_pool creates the pool's buffers the first time, and makes them again at another size when wanted_slots has
// changed: every page leaves, and the roots come back first.
@(private = "file")
ensure_pool :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API) -> bool {
	wanted := pool.wanted_slots != 0 ? pool.wanted_slots : mesh_pool_slots(DEFAULT_MESH_POOL)
	if pool.pool != {} && pool.slot_count == wanted {
		return true
	}
	if pool.pages == nil {
		make_tables(pool, platform)
	}
	for &page, entry in pool.pages[:pool.high] {
		if _, has := page_slot(page); has {
			change_page(pool, platform, u32(entry), Page_Left{})
		}
	}
	platform.gpu_destroy_buffer(pool.pool)
	delete(pool.slots, platform.heap_allocator)
	pool.pool, pool.slots, pool.slot_count = {}, nil, 0
	clear(&pool.free_slots)
	// Every page left, so every entry is listed for the GPU, and until a frame copies them the table is the old pool's.
	pool.table_sync = .Stale
	// The table, the feedback and its copies are made together or not at all.
	if pool.table == {} {
		pool.table = platform.gpu_create_buffer({size = MAX_MESH_PAGES * size_of(Table_Entry), usage = {.Storage}, label = "mesh page table"}, nil)
		pool.feedback = platform.gpu_create_buffer({size = MAX_MESH_PAGES * 4, usage = {.Storage}, label = "mesh page feedback"}, nil)
		if pool.table == {} || pool.feedback == {} || !ensure_readback_ring(&pool.ring, platform, MAX_MESH_PAGES * 4, "mesh page feedback copy") {
			platform.gpu_destroy_buffer(pool.table)
			platform.gpu_destroy_buffer(pool.feedback)
			destroy_readback_ring(&pool.ring, platform)
			pool.table, pool.feedback = {}, {}
			return false
		}
	}
	// A device may refuse a pool of the size that the budget asks for, so it halves until one fits.
	for slots := wanted; slots >= MESH_POOL_MIN_SLOTS; slots /= 2 {
		if u64(slots) * format.MESH_PAGE_SIZE > u64(max(u32)) {
			continue
		}
		pool.pool = platform.gpu_create_buffer({size = slots * format.MESH_PAGE_SIZE, usage = {.Storage}, label = "mesh page pool"}, nil)
		if pool.pool != {} {
			pool.slots = make([]u32, slots, platform.heap_allocator)
			slice.fill(pool.slots, MESH_PAGE_ABSENT)
			for slot := slots; slot > 0; slot -= 1 {
				append(&pool.free_slots, slot - 1)
			}
			// What was asked for, so that the pool is not made again each frame.
			pool.slot_count = wanted
			pool.stats.capacity_pages = slots
			return true
		}
	}
	log.error("render: cannot create the pool of mesh pages")
	return false
}

// mesh_pool_add gives a paged mesh a range of the table, and returns its id, or 0 if the table is full. Its pages are
// absent: the roots load in the frames after, and the mesh is ready when they are in (see mesh_pool_ready).
mesh_pool_add :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, guid: format.Guid, handle: asset.Handle, version: u32, modified: i64, data: []byte, blob: ^format.Mesh_Blob) -> (id: u32) {
	records := format.mesh_pages(data, blob)
	count := u32(len(records))
	if count == 0 || !ensure_pool(pool, platform) {
		return 0
	}
	first, found := take_range(pool, count)
	if !found {
		log.errorf("render: more than %d mesh pages are resident", MAX_MESH_PAGES)
		return 0
	}
	heap := platform.heap_allocator
	mesh := Pool_Mesh {
		live         = true,
		guid         = guid,
		handle       = handle,
		version      = version,
		modified     = modified,
		first        = first,
		count        = count,
		stride       = format.mesh_attribute_stride(blob.flags),
		records      = slice.clone(records, heap),
		dependencies = slice.clone(format.mesh_page_dependencies(data, blob), heap),
	}
	// A dependency is a page of the mesh in its blob, and an entry of the table here.
	for &d in mesh.dependencies {
		d += first
	}
	for &m, i in pool.meshes {
		if !m.live {
			m, id = mesh, u32(i + 1)
			break
		}
	}
	if id == 0 {
		append(&pool.meshes, mesh)
		id = u32(len(pool.meshes))
	}
	for record, i in records {
		entry := first + u32(i)
		pool.pages[entry] = {mesh = id}
		pool.entries[entry] = {MESH_PAGE_ABSENT, record.first_meshlet}
		mark_dirty(pool, entry)
	}
	pool.high = max(pool.high, first + count)
	return id
}

// mesh_pool_remove takes a mesh out of the pool: its reads end, its slots are free, and its range of the table waits
// before another mesh takes it.
mesh_pool_remove :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, id: u32) {
	if id == 0 || int(id) > len(pool.meshes) || !pool.meshes[id - 1].live {
		return
	}
	mesh := &pool.meshes[id - 1]
	// From the last page, which nothing depends on by the time that its dependents have gone.
	for i := mesh.count; i > 0; i -= 1 {
		entry := mesh.first + i - 1
		change_page(pool, platform, entry, Page_Left{})
		pool.pages[entry].mesh = 0
	}
	append(&pool.cooling, Cooling_Range{{mesh.first, mesh.count}, pool.frame + MESH_TABLE_COOL_FRAMES})
	delete(mesh.records, platform.heap_allocator)
	delete(mesh.dependencies, platform.heap_allocator)
	mesh^ = {}
}

@(private = "file")
take_range :: proc(pool: ^Mesh_Pool, count: u32) -> (first: u32, ok: bool) {
	for &range, i in pool.free_ranges {
		if range.y >= count {
			first = range.x
			range.x += count
			range.y -= count
			if range.y == 0 {
				unordered_remove(&pool.free_ranges, i)
			}
			return first, true
		}
	}
	return
}

// mesh_pool_ready is whether a mesh's roots are in the pool, so that it draws.
mesh_pool_ready :: proc(pool: ^Mesh_Pool, id: u32) -> bool {
	if id == 0 || int(id) > len(pool.meshes) {
		return false
	}
	mesh := &pool.meshes[id - 1]
	for record, i in mesh.records {
		if .Root in record.flags {
			if _, resident := pool.pages[mesh.first + u32(i)].state.(Page_Resident); !resident {
				return false
			}
		}
	}
	return mesh.live && !mesh.failed
}

// mesh_pool_failed is whether a page of a mesh was not what its table said.
mesh_pool_failed :: proc(pool: ^Mesh_Pool, id: u32) -> bool {
	return id != 0 && int(id) <= len(pool.meshes) && pool.meshes[id - 1].failed
}

// mesh_pool_range is a mesh's first entry of the table and its count of pages, for its mesh record.
mesh_pool_range :: proc(pool: ^Mesh_Pool, id: u32) -> (first, count: u32) {
	if id == 0 || int(id) > len(pool.meshes) {
		return MESH_PAGE_ABSENT, 0
	}
	return pool.meshes[id - 1].first, pool.meshes[id - 1].count
}

// mesh_pool_pin keeps every page of a mesh for this frame and asks for the ones that are absent: for what draws the
// mesh without a selection, which tests every meshlet (see docs/rendering/assets.md#mesh-pages).
mesh_pool_pin :: proc(pool: ^Mesh_Pool, id: u32) {
	if id != 0 && int(id) <= len(pool.meshes) {
		pool.meshes[id - 1].pinned_frame = pool.frame
	}
}

// mesh_pinned is whether something pinned a mesh in this frame or the last, whose draws the pool serves now.
@(private = "file")
mesh_pinned :: proc(pool: ^Mesh_Pool, mesh: ^Pool_Mesh) -> bool {
	return mesh.pinned_frame != 0 && mesh.pinned_frame + 1 >= pool.frame
}

// mesh_pool_update starts the pool's frame: it takes back what a frame that did not execute was to copy, reads the
// feedback that came back, marks the pages that views drew from, lists the ones that they want, ends the reads that
// nothing wants any more, and starts reads for the most wanted. Call it once a frame, before the frame's graphs.
mesh_pool_update :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, assets: ^asset.Assets) {
	if pool.pages == nil {
		return
	}
	pool.frame += 1
	pool.level0_budget = LEVEL0_PAGES_PER_FRAME
	pool.wanted = nil
	pool.stats.streamed_bytes = 0
	for i := len(pool.cooling) - 1; i >= 0; i -= 1 {
		if pool.cooling[i].until <= pool.frame {
			append(&pool.free_ranges, pool.cooling[i].range)
			unordered_remove(&pool.cooling, i)
		}
	}
	// A pool that could not be made, or made again, is tried again.
	if !ensure_pool(pool, platform) {
		return
	}
	if pool.table_sync == .Sent {
		pool.table_sync = .Stale
	}
	// What the last frame's pass was to copy, if that frame did not execute.
	for &page, entry in pool.pages[:pool.high] {
		if _, copying := page.state.(Page_Copying); copying {
			change_page(pool, platform, u32(entry), Page_Not_Copied{})
		}
		if page.sync == .Sent {
			mark_dirty(pool, u32(entry))
		}
	}

	wanted := make([dynamic]Wanted_Page, platform.frame_allocator)
	want :: proc(pool: ^Mesh_Pool, wanted: ^[dynamic]Wanted_Page, entry: u32, priority: f32) {
		page := &pool.pages[entry]
		if page.mesh == 0 || pool.meshes[page.mesh - 1].failed {
			return
		}
		if page.wanted_frame != pool.frame {
			page.wanted_priority = 0
		}
		page.wanted_frame = pool.frame
		page.wanted_priority = max(page.wanted_priority, priority)
		if _, has := page_slot(page^); has {
			page.used_frame = pool.frame
		} else {
			append(wanted, Wanted_Page{entry, priority})
		}
	}
	if data, take := take_readback(&pool.ring, platform, int(pool.high) * 4); take == .Fresh {
		words := slice.reinterpret([]u32, data[:int(pool.high) * 4])
		for word, entry in words {
			if word != 0 {
				want(pool, &wanted, u32(entry), transmute(f32)word)
			}
		}
	}
	// The roots are always wanted, before anything else, and so is every page of a mesh that draws without a selection.
	for &mesh in pool.meshes {
		if !mesh.live {
			continue
		}
		pinned := mesh_pinned(pool, &mesh)
		for record, i in mesh.records {
			if .Root in record.flags {
				want(pool, &wanted, mesh.first + u32(i), max(f32))
			} else if pinned {
				want(pool, &wanted, mesh.first + u32(i), max(f32) / 2)
			}
		}
	}
	// What a wanted page depends on is wanted as much, and what that depends on. The walk asks for a page by the groups
	// of it that show, and a page depends on pages for its other groups too, which no view asks for.
	for i := 0; i < len(wanted); i += 1 {
		w := wanted[i]
		for d in page_dependencies(pool, w.entry) {
			if pool.pages[d].wanted_frame != pool.frame || pool.pages[d].wanted_priority < w.priority {
				want(pool, &wanted, d, w.priority)
			}
		}
	}
	// A page that is wanted twice, by the feedback and by its mesh, is listed once, at its higher priority.
	slice.sort_by(wanted[:], proc(a, b: Wanted_Page) -> bool {
		return a.entry < b.entry || (a.entry == b.entry && a.priority > b.priority)
	})
	unique := 0
	for w, i in wanted {
		if i == 0 || w.entry != wanted[i - 1].entry {
			wanted[unique] = w
			unique += 1
		}
	}
	resize(&wanted, unique)
	slice.sort_by(wanted[:], proc(a, b: Wanted_Page) -> bool {
		return a.priority > b.priority || (a.priority == b.priority && a.entry > b.entry)
	})
	pool.wanted = wanted[:]
	pool.stats.pending_requests = u32(len(wanted))

	for &page, entry in pool.pages[:pool.high] {
		if _, reading := page.state.(Page_Reading); reading && page.wanted_frame + MESH_PAGE_FORGET_FRAMES < pool.frame {
			change_page(pool, platform, u32(entry), Page_Left{})
		}
	}
	if platform.file_read_begin == nil {
		return
	}
	for w in wanted {
		if pool.open_reads >= MESH_PAGE_READS {
			break
		}
		page := &pool.pages[w.entry]
		mesh, record := page_record(pool, w.entry)
		// A root's block is in the head, which the load takes it from.
		if page.state != nil || .Root in record.flags {
			continue
		}
		location, found := asset.blob_location(assets, mesh.guid)
		// The cooker wrote the blob again: its pages are another blob's, and the new version streams soon.
		if !found || !location.raw || platform.file_modified(location.path) != mesh.modified {
			continue
		}
		if read := platform.file_read_begin(location.path, location.offset + i64(record.offset), int(record.compressed_size)); read != 0 {
			change_page(pool, platform, w.entry, Page_Read_Began{read})
		}
	}
}

// Page_Load is one page that a frame decompresses and copies into the pool.
@(private)
Page_Load :: struct {
	entry:  u32,
	slot:   u32,
	block:  []byte,
	record: format.Mesh_Page,
	stride: u32,
	upload: gpu.Upload,
	ok:     bool,
}

// Stream_Pages is what a frame's stream pages pass does, and what its commit makes of it.
@(private)
Stream_Pages :: struct {
	pool:     ^Mesh_Pool,
	platform: ^core.Platform_API,
	loads:    []Page_Load,
	// Runs of the table that the GPU does not have: the first entry, the count, and where they are in table_upload.
	runs:     [][2]u32,
	entries:  []u32,
	table_upload: gpu.Upload,
	zero_upload:  gpu.Upload,
	pool_buffer:  Buffer,
	table:        Buffer,
	feedback:     Buffer,
	high:         u32,
}

// Mesh_Pool_Frame is the graph's buffers of the pool for a frame, 0 before the pool has any mesh.
Mesh_Pool_Frame :: struct {
	pool:     Buffer,
	table:    Buffer,
	feedback: Buffer,
}

// prepare_stream_pages picks what a frame's stream pages pass copies, and decompresses it into the frame's uploads: the
// pages that are ready to load, the changed entries of the table, and zeros for the feedback. The pages are the roots,
// then the pages whose reads are done, the ones that others depend on first, each only when what it depends on has a
// slot. A page takes a free slot, or the slot of the page that no view has used for the longest, if that is long
// enough. It gives nil before the pool has a mesh, and when the frame's uploads are full. commit_stream_pages is what
// the frame leaves once it executes; without it, the next update takes everything back.
@(private)
prepare_stream_pages :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, assets: ^asset.Assets) -> ^Stream_Pages {
	if pool.pool == {} {
		return nil
	}
	sp := new(Stream_Pages, platform.frame_allocator)
	sp.pool, sp.platform = pool, platform
	loads := make([dynamic]Page_Load, platform.frame_allocator)

	// The candidates: a wanted page whose block is at hand, the most wanted first. A dependency is wanted at least as
	// much as its dependents, as its error is larger, so it comes first.
	for w in pool.wanted {
		if len(loads) >= MESH_PAGE_LOADS_PER_FRAME {
			break
		}
		page := &pool.pages[w.entry]
		// Its mesh went since the update listed it, as a version that a newer one replaced does.
		if page.mesh == 0 {
			continue
		}
		mesh, record := page_record(pool, w.entry)
		block: []byte
		switch s in page.state {
		case Page_Reading:
			data, state := platform.file_read_result(s.read)
			if state == .Pending {
				continue
			}
			if state == .Failed {
				change_page(pool, platform, w.entry, Page_Left{})
				continue
			}
			block = data
		case Page_Copying, Page_Resident:
			continue
		case:
			if .Root not_in record.flags {
				continue
			}
			// The head, if it is still the version that the table came from.
			head, loaded := asset.data(assets, mesh.handle)
			if !loaded || asset.version(assets, mesh.handle) != mesh.version || u64(record.offset) + u64(record.compressed_size) > u64(len(head)) {
				continue
			}
			block = head[record.offset:][:record.compressed_size]
		}
		if len(block) != int(record.compressed_size) || hash.fnv32a(block) != record.checksum {
			fail_page(pool, platform, w.entry, "is not the page that its table names")
			continue
		}
		ready := true
		for d in page_dependencies(pool, w.entry) {
			_, has := page_slot(pool.pages[d])
			ready &&= has
		}
		if !ready {
			continue
		}
		slot, found := take_slot(pool, platform)
		if !found {
			// Nothing can leave for it, and so for nothing less wanted either.
			break
		}
		upload, uploaded := platform.gpu_upload(int(record.size), 16)
		if !uploaded {
			append(&pool.free_slots, slot)
			break
		}
		change_page(pool, platform, w.entry, Page_Took_Slot{slot})
		append(&loads, Page_Load{entry = w.entry, slot = slot, block = block, record = record, stride = mesh.stride, upload = upload})
	}

	// Decompressed on the job threads, each into the frame's upload memory, and checked there.
	if len(loads) > 0 {
		list := make([]jobs.Job, len(loads), platform.frame_allocator)
		for &load, i in loads {
			list[i] = {decompress_page, &load}
		}
		counter: jobs.Counter
		platform.jobs_run(list, &counter)
		platform.jobs_wait(&counter)
	}
	kept := 0
	for load in loads {
		if !load.ok {
			fail_page(pool, platform, load.entry, "does not decompress into a page")
			continue
		}
		loads[kept] = load
		kept += 1
	}
	sp.loads = loads[:kept]

	// The table's changed entries, in runs.
	slice.sort(pool.dirty[:])
	entries := slice.clone(pool.dirty[:], platform.frame_allocator)
	runs := make([dynamic][2]u32, platform.frame_allocator)
	values := make([]Table_Entry, len(entries), platform.frame_allocator)
	for entry, i in entries {
		values[i] = pool.entries[entry]
		if i > 0 && entry == entries[i - 1] + 1 {
			runs[len(runs) - 1].y += 1
		} else {
			append(&runs, [2]u32{entry, 1})
		}
	}
	sp.entries, sp.runs = entries, runs[:]
	ok := true
	if len(values) > 0 {
		sp.table_upload, ok = upload_bytes(platform, slice.to_bytes(values))
	}
	sp.high = pool.high
	if ok && sp.high > 0 {
		sp.zero_upload, ok = platform.gpu_upload(int(sp.high) * 4, 16)
		if ok {
			mem.zero_slice(sp.zero_upload.data)
		}
	}
	if !ok {
		// The frame's uploads are full: nothing is copied, and the next update takes the slots back.
		return nil
	}
	for entry in entries {
		pool.pages[entry].sync = .Sent
	}
	clear(&pool.dirty)
	if pool.table_sync == .Stale {
		pool.table_sync = .Sent
	}
	return sp
}

// mesh_pool_drawable is whether a paged mesh may draw from the pool now: not while the pool's buffer was made again
// and no pass has copied the table for it.
mesh_pool_drawable :: proc(pool: ^Mesh_Pool) -> bool {
	return pool.table_sync != .Stale
}

// mesh_pool_not_sent says that the frame's own graph did not execute, so that the views that draw after it in the frame
// do not take its stream pages pass as done.
mesh_pool_not_sent :: proc(pool: ^Mesh_Pool) {
	if pool.table_sync == .Sent {
		pool.table_sync = .Stale
	}
}

// add_stream_pages_pass adds the pass that brings the pool up to date before anything draws from it (see
// prepare_stream_pages), after a copy of the feedback that the last frame's views wrote. Call it in the frame's own
// view, before the selection.
@(private)
add_stream_pages_pass :: proc(g: ^Graph, pool: ^Mesh_Pool, platform: ^core.Platform_API, assets: ^asset.Assets) -> (frame: Mesh_Pool_Frame) {
	sp := prepare_stream_pages(pool, platform, assets)
	if sp == nil {
		return
	}

	sp.pool_buffer = import_buffer(g, pool.pool)
	sp.table = import_buffer(g, pool.table)
	sp.feedback = import_buffer(g, pool.feedback)
	// What every view of the last frame wrote, the extra views after the frame's own, is copied for the CPU before this
	// frame zeroes it.
	if sp.high > 0 {
		add_readback_copy(g, platform, &pool.ring, sp.feedback, sp.high * 4, "copy page feedback")
	}
	p := add_compute_pass(g, "stream pages", stream_pages, sp)
	copy_dest(g, p, sp.pool_buffer)
	copy_dest(g, p, sp.table)
	copy_dest(g, p, sp.feedback)
	on_executed(g, commit_stream_pages, sp)
	return {pool = sp.pool_buffer, table = sp.table, feedback = sp.feedback}
}

// mesh_pool_buffers imports the pool's buffers into a graph that draws from the pool and does not bring it up to date:
// an extra view's.
@(private)
mesh_pool_buffers :: proc(g: ^Graph, pool: ^Mesh_Pool) -> (frame: Mesh_Pool_Frame) {
	if pool.pool == {} || pool.table == {} {
		return
	}
	return {pool = import_buffer(g, pool.pool), table = import_buffer(g, pool.table), feedback = import_buffer(g, pool.feedback)}
}

@(private = "file")
decompress_page :: proc(data: rawptr) {
	load := (^Page_Load)(data)
	out := load.upload.data[:load.record.size]
	if lz4.decompress(load.block, out) {
		_, load.ok = format.mesh_page_view(out, load.record, load.stride)
	}
}

@(private = "file")
stream_pages :: proc(ctx: ^Pass_Context) {
	sp := (^Stream_Pages)(ctx.data)
	g := ctx.graph
	for load in sp.loads {
		gpu.cmd_copy_buffer(ctx.cb, load.upload.buffer, load.upload.offset, gpu_buffer(g, sp.pool_buffer), load.slot * format.MESH_PAGE_SIZE, load.record.size)
	}
	offset := sp.table_upload.offset
	for run in sp.runs {
		size := run.y * size_of(Table_Entry)
		gpu.cmd_copy_buffer(ctx.cb, sp.table_upload.buffer, offset, gpu_buffer(g, sp.table), run.x * size_of(Table_Entry), size)
		offset += size
	}
	if sp.high > 0 {
		gpu.cmd_copy_buffer(ctx.cb, sp.zero_upload.buffer, sp.zero_upload.offset, gpu_buffer(g, sp.feedback), 0, sp.high * 4)
	}
}

// commit_stream_pages is what a frame that executed leaves: its pages are resident, and the GPU's table is the CPU's
// for the entries that it copied.
@(private)
commit_stream_pages :: proc(data: rawptr) {
	sp := (^Stream_Pages)(data)
	pool := sp.pool
	for load in sp.loads {
		if change_page(pool, sp.platform, load.entry, Page_Copied{}) {
			pool.stats.streamed_bytes += load.record.size
			pool.stats.streamed_total += u64(load.record.size)
		}
	}
	if pool.table_sync == .Sent {
		pool.table_sync = .Current
	}
	// An entry that changed again since the pass was made is dirty, and stays listed.
	for entry in sp.entries {
		if pool.pages[entry].sync == .Sent {
			pool.pages[entry].sync = .Clean
		}
	}
	count: u32
	for slot_entry in pool.slots {
		count += u32(slot_entry != MESH_PAGE_ABSENT)
	}
	pool.stats.resident_pages = count
}

// take_slot gives a free slot, or the slot of the resident page that no view has used for the longest: one that is not
// a root, that nothing with a slot depends on, whose mesh is not pinned, and that no view used in the last
// MESH_PAGE_KEEP_FRAMES frames. That page leaves.
@(private = "file")
take_slot :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API) -> (slot: u32, ok: bool) {
	if len(pool.free_slots) > 0 {
		return pop(&pool.free_slots), true
	}
	victim := MESH_PAGE_ABSENT
	oldest := max(u64)
	for entry in pool.slots {
		if entry == MESH_PAGE_ABSENT {
			continue
		}
		page := &pool.pages[entry]
		mesh, record := page_record(pool, entry)
		_, resident := page.state.(Page_Resident)
		if !resident || .Root in record.flags || page.dependents > 0 || mesh_pinned(pool, mesh) || page.used_frame + MESH_PAGE_KEEP_FRAMES >= pool.frame {
			continue
		}
		if page.used_frame < oldest {
			oldest, victim = page.used_frame, entry
		}
	}
	if victim == MESH_PAGE_ABSENT {
		return
	}
	change_page(pool, platform, victim, Page_Left{})
	return pop(&pool.free_slots), true
}

// fail_page takes a page whose bytes are wrong out of the pool, and its mesh with it from the pages that are asked for,
// which is logged once for the mesh. The cooker's next blob streams as a new version.
@(private = "file")
fail_page :: proc(pool: ^Mesh_Pool, platform: ^core.Platform_API, entry: u32, reason: string) {
	mesh, _ := page_record(pool, entry)
	change_page(pool, platform, entry, Page_Left{})
	if !mesh.failed {
		mesh.failed = true
		buffer: [32]u8
		log.errorf("render: page %d of the mesh %s %s", entry - mesh.first, format.guid_format(mesh.guid, &buffer), reason)
	}
}

// mesh_pool_resident is whether a mesh's page is in the pool, for the tests.
mesh_pool_resident :: proc(pool: ^Mesh_Pool, id: u32, page: u32) -> bool {
	if id == 0 || int(id) > len(pool.meshes) || page >= pool.meshes[id - 1].count {
		return false
	}
	_, resident := pool.pages[pool.meshes[id - 1].first + page].state.(Page_Resident)
	return resident
}
