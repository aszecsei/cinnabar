// The pool of virtual texture pages: the pages of every virtual texture that are resident, in atlases of tiles, with the
// table that says which tile each page is in, the records that name each texture's range of the table, the feedback
// that the shaders write, and the reads, the loads and the evictions that follow it. See
// docs/rendering/assets.md#virtual-textures.
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

// The tiles across and down one layer of an atlas. A tile holds one page with its border, so a layer is 2176 texels on a
// side. Matches TEXTURE_ATLAS_TILES in texture_pages.hlsli.
TEXTURE_ATLAS_TILES :: 16
TEXTURE_ATLAS_LAYER_SLOTS :: TEXTURE_ATLAS_TILES * TEXTURE_ATLAS_TILES
TEXTURE_ATLAS_SIZE :: TEXTURE_ATLAS_TILES * format.TEXTURE_PAGE_TEXELS
// The most atlases that a pool has: one for each format of page.
MAX_TEXTURE_ATLASES :: 4
// The pages of every resident virtual texture together, each with an entry of the table. A texture that would pass it is
// not made resident.
MAX_TEXTURE_PAGES :: 1 << 16
// The virtual textures that are resident at once, each with a record.
MAX_VIRTUAL_TEXTURES :: 4096
// The most paged levels that a record names, which a texture of 16384 texels on a side is well within.
MAX_VIRTUAL_LEVELS :: 12
// A table entry's slot for a page that is not resident. Matches TEXTURE_PAGE_ABSENT in texture_pages.hlsli.
TEXTURE_PAGE_ABSENT :: max(u32)
// A material's slot of a virtual texture has this bit set in its first word, with the texture's record below it. Matches
// VIRTUAL_TEXTURE_BIT in texture_pages.hlsli.
VIRTUAL_TEXTURE_BIT :: 1 << 31
// The bits of Virtual_Texture_Record.sampler. Match VIRTUAL_SAMPLER_WRAP_MASK, VIRTUAL_SAMPLER_MIP_NEAREST and
// VIRTUAL_SAMPLER_ANISOTROPY_SHIFT in material_virtual.hlsli.
VIRTUAL_SAMPLER_WRAP_MASK :: 3
VIRTUAL_SAMPLER_MIP_NEAREST :: 1 << 2
VIRTUAL_SAMPLER_ANISOTROPY_SHIFT :: 8
// The most reads of pages that are open at once.
TEXTURE_PAGE_READS :: 32
// The most pages that a frame decompresses and copies into the atlases: about 400 KiB of the frame's uploads.
TEXTURE_PAGE_LOADS_PER_FRAME :: 16
// A page that a view used within this many frames does not leave, so a pool that is too small for a view does not trade
// the view's pages for each other every frame.
TEXTURE_PAGE_KEEP_FRAMES :: 4
// A read whose page no view has asked for in this many frames is ended.
TEXTURE_PAGE_FORGET_FRAMES :: 30
// A texture's range of the table and its record are not given to another texture for this many frames, in which the
// feedback of the frames that drew it comes back.
TEXTURE_TABLE_COOL_FRAMES :: 8
// How often the pool asks the platform for the video memory in use, in frames.
TEXTURE_BUDGET_CHECK_FRAMES :: 30
// The most pages of virtual textures that a frame decompresses for the textures that assemble a whole texture.
TEXTURE_WHOLE_PAGES_PER_FRAME :: 32
// The most bytes of pages that one read takes for a whole texture.
TEXTURE_WHOLE_READ_SIZE :: 8 << 20

#assert(TEXTURE_ATLAS_SIZE == 2176)

// Virtual_Texture_Record is a virtual texture's record, which shaders read as it is: matches Virtual_Texture_Record in
// texture_pages.hlsli. A material's slot names it by its index (see VIRTUAL_TEXTURE_BIT). Its paged levels are the
// texture's mips 0 up to levels, and each is a grid of pages, 128 texels on a side, row by row: level i is the texture's
// size shifted right by i, at least a texel, over 128 and rounded up on each axis. A level's page p is the table entry
// table + level_first[i] + p. The mips from levels on are the tail texture's own, whose mip 0 is the texture's mip
// levels. An entry is the page's slot in the atlas, or TEXTURE_PAGE_ABSENT: slot / 256 is the layer, and slot % 256 the
// tile in it, at texel ((slot % 16) * 136, (slot / 16 % 16) * 136) of the layer, whose first 4 texels on each side are
// the border. The page covers the 128 texels from 4 in. The material's sampler for the texture is its own with clamping,
// so the shader applies the texture's wrap itself, and it takes the rest of how the texture samples from `sampler`.
Virtual_Texture_Record :: struct {
	// The texture's mip 0, in texels.
	size:        [2]u32,
	// The record's first entry of the table, and how many entries: the pages of every level.
	table:       u32,
	page_count:  u32,
	// How many levels are paged: the texture's first mip of the tail.
	levels:      u32,
	// The read indices of the atlas that has the pages, a Texture2DArray, and of the tail texture, a Texture2D.
	atlas:       u32,
	tail:        u32,
	// How the texture samples, which the shader cannot ask of its clamping sampler: its wrap, as the format's Texture_Wrap, in
	// the bits of VIRTUAL_SAMPLER_WRAP_MASK, VIRTUAL_SAMPLER_MIP_NEAREST for a nearest mip filter, and from
	// VIRTUAL_SAMPLER_ANISOTROPY_SHIFT the anisotropy that its sampler takes under the quality's cap (see
	// sampler_anisotropy), which the shader picks levels by.
	sampler:     u32,
	// Each paged level's first page, from the record's first entry. Levels past the paged ones are 0.
	level_first: [MAX_VIRTUAL_LEVELS]u32,
}

#assert(size_of(Virtual_Texture_Record) == 80)
#assert(size_of(Virtual_Texture_Record) % 16 == 0)

// Texture_Stream_Stats is what the Resource Monitor shows of the pool: the pages that are resident, the slots, the
// pages that views asked for and that are not resident yet, the bytes of pages that every frame has copied, which a
// reader takes a rate from, the bytes of the atlases, and the video memory that the process uses of its budget.
Texture_Stream_Stats :: struct {
	resident_pages: u32,
	capacity_pages: u32,
	pending_pages:  u32,
	streamed_total: u64,
	pool_bytes:     u64,
	video_used:     u64,
	video_budget:   u64,
}

// Texture_Atlas is the tiles of one format of page: a texture array of layers of TEXTURE_ATLAS_TILES squared tiles.
@(private)
Texture_Atlas :: struct {
	format:        gpu.Format,
	texture:       gpu.Texture,
	layers:        u32,
	// The resident textures that have this format, each with a root page that must have a slot.
	textures:      u32,
	// The pages of this format that views asked for and that were resident, over the last frames, which the pool's
	// slots are divided by when it is made again.
	demand:        u32,
	// Each slot's table entry, or TEXTURE_PAGE_ABSENT, the free slots, and how many have a page.
	slots:         []u32,
	free_slots:    [dynamic]u32,
	used_slots:    u32,
	// The resident pages that may leave, in the frame that victims_frame says, the one used longest ago last.
	victims:       [dynamic]Texture_Victim,
	victims_frame: u64,
}

@(private)
Texture_Victim :: struct {
	entry: u32,
	used:  u64,
}

// Texture_Pool is the pool's state, in Residency.
Texture_Pool :: struct {
	atlases:        [MAX_TEXTURE_ATLASES]Texture_Atlas,
	atlas_count:    int,
	// The records, the table and the feedback: a word for each table entry, which shaders set to 1 for a resident page that
	// they sample and raise to the priority of a page that they want, as a float's bits, which is larger for a page that
	// shows more.
	records:        gpu.Buffer,
	table:          gpu.Buffer,
	feedback:       gpu.Buffer,
	ring:           Readback_Ring,
	// What the renderer asked the atlases to be, in bytes, the most that the video memory budget lets them be, 0 for no
	// limit, and what they were made for. The atlases are made again when what they should be differs from built_bytes.
	quality_bytes:  u64,
	limit_bytes:    u64,
	built_bytes:    u64,
	// Each table entry's page, the table as the GPU should have it, and the entries that it does not have yet.
	pages:          []Texture_Pool_Page,
	entries:        []u32,
	dirty:          [dynamic]u32,
	// The most anisotropy that a texture's sampler takes, which the records carry (see texture_pool_set_anisotropy).
	anisotropy_cap: u8,
	// The virtual textures, by their id less 1, which is their record's index, the unused ids, the free ranges of the table
	// as (first, count), and the ranges and ids that wait. The records that the GPU should have are the textures' own.
	textures:       []Pool_Texture,
	free_ids:       [dynamic]u32,
	free_ranges:    [dynamic][2]u32,
	cooling:        [dynamic]Texture_Cooling,
	dirty_records:  [dynamic]u32,
	// One past the highest id and the highest table entry that a texture has had, which the records are searched and the
	// feedback is zeroed and read back up to.
	texture_high:   u32,
	high:           u32,
	frame:          u64,
	open_reads:     int,
	// The pages that the last update found wanted and not resident, by priority, most wanted first, in frame memory.
	wanted:         []Wanted_Page,
	stats:          Texture_Stream_Stats,
	// Pages that this frame may still decompress for whole textures.
	whole_budget:   int,
	// Whether the GPU's table and records are of the atlases as they are now. ensure_texture_pool is its only writer with
	// commit_stream_texture_pages and texture_pool_not_sent.
	table_sync:     Table_Sync,
	// The pages that came in since the last update, and those that came before it, which this frame takes (see
	// texture_pool_refined), as the textures that they refine.
	refining:       [dynamic]Refined_Texture,
	refined:        [dynamic]Refined_Texture,
}

@(private)
Texture_Cooling :: struct {
	range: [2]u32,
	id:    u32,
	until: u64,
}

// Pool_Texture is a virtual texture in the pool: its range of the table, its record, and what reading its pages needs
// after its blob's head has gone from the frame. id less 1 is its index in Texture_Pool.textures.
@(private)
Pool_Texture :: struct {
	live:        bool,
	guid:        format.Guid,
	// The asset that the head came from, with its version and its file's time then. A live texture has no pages.
	handle:      asset.Handle,
	version:     u32,
	modified:    i64,
	first:       u32,
	count:       u32,
	// Its atlas, by its place in the pool's.
	atlas:       u32,
	blob_format: format.Texture_Format,
	sampler:     format.Texture_Sampler,
	size:        [2]u32,
	mip_count:   u32,
	levels:      []format.Texture_Level,
	pages:       []format.Texture_Page,
	// The record as the GPU should have it, and whether it does.
	record:      Virtual_Texture_Record,
	record_sync: Entry_Sync,
	// A page of it was not what its table said, which was logged. It asks for no more.
	failed:      bool,
}

// Texture_Pool_Page is one table entry's page. change_texture_page is the only writer of state.
@(private)
Texture_Pool_Page :: struct {
	// The texture's id, or 0 for an entry that no texture has.
	texture:         u32,
	state:           Page_State,
	// The last frame that a view drew from it, and that a view wanted it.
	used_frame:      u64,
	wanted_frame:    u64,
	// The most that anything wanted it by in wanted_frame.
	wanted_priority: f32,
	// The pages with a slot that it is the parent of. It keeps its slot while there are any.
	dependents:      u32,
	sync:            Entry_Sync,
}

@(private = "file")
Texture_Page_Event :: union #no_nil {
	// A read of its block began.
	Texture_Page_Read_Began,
	// It took a slot, which this frame copies it into.
	Texture_Page_Took_Slot,
	// The frame that copied it executed.
	Texture_Page_Copied,
	// The frame that should have copied it did not execute.
	Texture_Page_Not_Copied,
	// It leaves: evicted, its read ended, or its texture gone.
	Texture_Page_Left,
}

@(private = "file")
Texture_Page_Read_Began :: struct {
	read: core.File_Read,
}

@(private = "file")
Texture_Page_Took_Slot :: struct {
	slot: u32,
}

@(private = "file")
Texture_Page_Copied :: struct {}

@(private = "file")
Texture_Page_Not_Copied :: struct {}

@(private = "file")
Texture_Page_Left :: struct {}

// change_texture_page is the one writer of a page's state (see docs/overview/conventions.md#state-with-a-lifecycle). It
// keeps with the state what follows from it: the slot's owner, the table's entry, the count of open reads and its
// parent's count of dependents. It gives false for an event that the state does not take.
@(private = "file")
change_texture_page :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	entry: u32,
	event: Texture_Page_Event,
) -> bool {
	page := &pool.pages[entry]
	take_slot :: proc(pool: ^Texture_Pool, entry: u32, slot: u32) {
		atlas := page_atlas(pool, entry)
		atlas.slots[slot] = entry
		atlas.used_slots += 1
		if parent, has := page_parent(pool, entry); has {
			pool.pages[parent].dependents += 1
		}
		// The table says so in the pass that copies the page, so the GPU sees both or neither.
		set_texture_entry(pool, entry, slot)
	}
	give_slot :: proc(pool: ^Texture_Pool, entry: u32, slot: u32) {
		atlas := page_atlas(pool, entry)
		atlas.slots[slot] = TEXTURE_PAGE_ABSENT
		atlas.used_slots -= 1
		append(&atlas.free_slots, slot)
		if parent, has := page_parent(pool, entry); has {
			pool.pages[parent].dependents -= 1
		}
		set_texture_entry(pool, entry, TEXTURE_PAGE_ABSENT)
	}
	end_read :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API, read: core.File_Read) {
		if read != 0 {
			platform.file_read_end(read)
			pool.open_reads -= 1
		}
	}
	switch e in event {
	case Texture_Page_Read_Began:
		if page.state != nil || e.read == 0 {
			return false
		}
		pool.open_reads += 1
		page.state = Page_Reading{e.read}
	case Texture_Page_Took_Slot:
		read: core.File_Read
		if reading, is_reading := page.state.(Page_Reading); is_reading {
			read = reading.read
		} else if page.state != nil {
			return false
		}
		take_slot(pool, entry, e.slot)
		page.state = Page_Copying{e.slot, read}
	case Texture_Page_Copied:
		copying := page.state.(Page_Copying) or_return
		end_read(pool, platform, copying.read)
		page.state = Page_Resident{copying.slot}
		page.used_frame = pool.frame
		// Its mip drew from the page one coarser until now, and the root's from the texture's default.
		tex, record := page_record(pool, entry)
		before := .Root in record.flags ? tex.mip_count : u32(record.mip) + 1
		append(&pool.refining, Refined_Texture{tex.guid, tex.size, before})
	case Texture_Page_Not_Copied:
		copying := page.state.(Page_Copying) or_return
		give_slot(pool, entry, copying.slot)
		// Its read is still open, with its block.
		page.state = copying.read != 0 ? Page_Reading{copying.read} : nil
	case Texture_Page_Left:
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

// set_texture_entry sets a table entry's slot, and lists the entry for the GPU.
@(private = "file")
set_texture_entry :: proc(pool: ^Texture_Pool, entry: u32, slot: u32) {
	pool.entries[entry] = slot
	mark_entry_dirty(pool, entry)
}

@(private = "file")
mark_entry_dirty :: proc(pool: ^Texture_Pool, entry: u32) {
	if pool.pages[entry].sync != .Dirty {
		pool.pages[entry].sync = .Dirty
		append(&pool.dirty, entry)
	}
}

@(private = "file")
mark_record_dirty :: proc(pool: ^Texture_Pool, id: u32) {
	tex := &pool.textures[id - 1]
	if tex.record_sync != .Dirty {
		tex.record_sync = .Dirty
		append(&pool.dirty_records, id)
	}
}

// page_atlas is the atlas that a table entry's page has its tile in.
@(private = "file")
page_atlas :: proc(pool: ^Texture_Pool, entry: u32) -> ^Texture_Atlas {
	return &pool.atlases[pool.textures[pool.pages[entry].texture - 1].atlas]
}

// page_record is a table entry's record in its texture's table.
@(private = "file")
page_record :: proc(
	pool: ^Texture_Pool,
	entry: u32,
) -> (
	tex: ^Pool_Texture,
	record: format.Texture_Page,
) {
	tex = &pool.textures[pool.pages[entry].texture - 1]
	return tex, tex.pages[entry - tex.first]
}

// page_parent is the table entry of the page one level coarser that covers a page, which must have a slot for the page
// to have one. The root has none.
@(private)
page_parent :: proc(pool: ^Texture_Pool, entry: u32) -> (parent: u32, has: bool) {
	tex, record := page_record(pool, entry)
	next := int(record.mip) + 1
	if next >= len(tex.levels) {
		return
	}
	level := tex.levels[next]
	return tex.first + level.first_page + u32(record.y / 2) * level.grid.x + u32(record.x / 2),
		true
}

@(private)
state_slot :: proc(state: Page_State) -> (slot: u32, has: bool) {
	#partial switch s in state {
	case Page_Copying:
		return s.slot, true
	case Page_Resident:
		return s.slot, true
	}
	return
}

texture_pool_init :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API) {
	pool^ = {}
}

// make_texture_tables makes the pool's tables, the first time that a virtual texture is resident: a game without one has
// none.
@(private = "file")
make_texture_tables :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API) {
	heap := platform.heap_allocator
	pool.pages = make([]Texture_Pool_Page, MAX_TEXTURE_PAGES, heap)
	pool.entries = make([]u32, MAX_TEXTURE_PAGES, heap)
	slice.fill(pool.entries, TEXTURE_PAGE_ABSENT)
	pool.textures = make([]Pool_Texture, MAX_VIRTUAL_TEXTURES, heap)
	pool.free_ids = make([dynamic]u32, heap)
	// The lowest id comes first.
	for id := u32(MAX_VIRTUAL_TEXTURES); id > 0; id -= 1 {
		append(&pool.free_ids, id)
	}
	pool.dirty = make([dynamic]u32, heap)
	pool.dirty_records = make([dynamic]u32, heap)
	pool.free_ranges = make([dynamic][2]u32, heap)
	pool.cooling = make([dynamic]Texture_Cooling, heap)
	pool.refining = make([dynamic]Refined_Texture, heap)
	pool.refined = make([dynamic]Refined_Texture, heap)
	append(&pool.free_ranges, [2]u32{0, MAX_TEXTURE_PAGES})
}

// texture_pool_destroy ends every read and frees the pool. Call it with the textures already removed or not: it removes
// what is left.
texture_pool_destroy :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API) {
	if pool.pages == nil {
		return
	}
	for &t, i in pool.textures[:pool.texture_high] {
		if t.live {
			texture_pool_remove(pool, platform, u32(i + 1))
		}
	}
	for i in 0 ..< pool.atlas_count {
		destroy_atlas(pool, platform, i)
	}
	platform.gpu_destroy_buffer(pool.records)
	platform.gpu_destroy_buffer(pool.table)
	platform.gpu_destroy_buffer(pool.feedback)
	destroy_readback_ring(&pool.ring, platform)
	heap := platform.heap_allocator
	delete(pool.pages, heap)
	delete(pool.entries, heap)
	delete(pool.textures, heap)
	delete(pool.free_ids)
	delete(pool.dirty)
	delete(pool.dirty_records)
	delete(pool.free_ranges)
	delete(pool.cooling)
	delete(pool.refining)
	delete(pool.refined)
	pool^ = {}
}

// atlas_layer_bytes is the bytes that one layer of an atlas of a format takes.
@(private = "file")
atlas_layer_bytes :: proc(f: gpu.Format) -> u64 {
	blocks := u64(TEXTURE_ATLAS_SIZE / 4)
	return blocks * blocks * u64(gpu.format_size(f))
}

// atlas_page_bytes is the bytes that one page of a format takes in a tile.
@(private = "file")
atlas_page_bytes :: proc(f: gpu.Format) -> u64 {
	blocks := u64(format.TEXTURE_PAGE_TEXELS / 4)
	return blocks * blocks * u64(gpu.format_size(f))
}

// atlas_weight is what share of a pool a format gets when a texture of it comes first, of 10: more for the color maps
// that most textures are than for the normals and the masks.
@(private = "file")
atlas_weight :: proc(f: gpu.Format) -> u64 {
	#partial switch f {
	case .BC7_Unorm_Srgb, .BC7_Unorm:
		return 5
	case .BC5_Unorm:
		return 3
	}
	return 2
}

// atlas_floor is the fewest layers that an atlas has: one with a tile for each root page of its textures, and at least
// one.
@(private = "file")
atlas_floor :: proc(a: ^Texture_Atlas) -> u32 {
	return max((a.textures + TEXTURE_ATLAS_LAYER_SLOTS - 1) / TEXTURE_ATLAS_LAYER_SLOTS, 1)
}

// wanted_pool_bytes is how many bytes the atlases are to have in all: the quality's budget, or what the video memory
// budget leaves of it.
@(private = "file")
wanted_pool_bytes :: proc(pool: ^Texture_Pool) -> u64 {
	bytes :=
		pool.quality_bytes != 0 ? pool.quality_bytes : u64(DEFAULT_TEXTURE_POOL) * mem.Megabyte
	return pool.limit_bytes != 0 ? min(bytes, pool.limit_bytes) : bytes
}

// floor_pool_bytes is the fewest bytes that the atlases can have: a layer of each format that a texture has.
@(private = "file")
floor_pool_bytes :: proc(pool: ^Texture_Pool) -> (bytes: u64) {
	for &a in pool.atlases[:pool.atlas_count] {
		if a.textures > 0 {
			bytes += u64(atlas_floor(&a)) * atlas_layer_bytes(a.format)
		}
	}
	return
}

// plan_atlases is how many layers each atlas of a textures has when the atlases are made again to take bytes: its share
// of the bytes by what its pages were in demand, or by its format's weight when nothing was.
@(private = "file")
plan_atlases :: proc(pool: ^Texture_Pool, bytes: u64) -> (layers: [MAX_TEXTURE_ATLASES]u32) {
	demand, weights: u64
	for &a in pool.atlases[:pool.atlas_count] {
		if a.textures > 0 {
			demand += u64(a.demand) * atlas_page_bytes(a.format)
			weights += atlas_weight(a.format)
		}
	}
	for &a, i in pool.atlases[:pool.atlas_count] {
		if a.textures == 0 {
			continue
		}
		share := bytes * atlas_weight(a.format) / max(weights, 1)
		if demand > 0 {
			share = u64(f64(bytes) * f64(u64(a.demand) * atlas_page_bytes(a.format)) / f64(demand))
		}
		layers[i] = u32(
			clamp(
				share / atlas_layer_bytes(a.format),
				u64(atlas_floor(&a)),
				gpu.MAX_TEXTURE_LAYERS,
			),
		)
	}
	return
}

// make_atlas creates an atlas of a format with about layers layers, fewer where the device refuses so many, but not fewer
// than it needs for its roots. Every record of a texture in it names it.
@(private = "file")
make_atlas :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	index: int,
	layers: u32,
) -> bool {
	a := &pool.atlases[index]
	floor := atlas_floor(a)
	n := clamp(layers, floor, gpu.MAX_TEXTURE_LAYERS)
	for {
		texture := platform.gpu_create_texture(
			{
				size = {TEXTURE_ATLAS_SIZE, TEXTURE_ATLAS_SIZE},
				layers = n,
				format = a.format,
				mip_count = 1,
				usage = {.Sampled},
				label = "virtual texture atlas",
			},
			nil,
		)
		if texture != {} {
			a.texture, a.layers = texture, n
			break
		}
		if n == floor {
			log.error("render: cannot create an atlas of virtual texture pages")
			return false
		}
		n = max(n / 2, floor)
	}
	a.slots = make([]u32, n * TEXTURE_ATLAS_LAYER_SLOTS, platform.heap_allocator)
	slice.fill(a.slots, TEXTURE_PAGE_ABSENT)
	a.used_slots = 0
	a.free_slots = make([dynamic]u32, 0, len(a.slots), platform.heap_allocator)
	for slot := u32(len(a.slots)); slot > 0; slot -= 1 {
		append(&a.free_slots, slot - 1)
	}
	for &t, i in pool.textures[:pool.texture_high] {
		if t.live && t.atlas == u32(index) {
			t.record.atlas = gpu.read_index(a.texture)
			mark_record_dirty(pool, u32(i + 1))
		}
	}
	count_atlases(pool)
	return true
}

// destroy_atlas destroys an atlas's texture and slots, once its pages have left.
@(private = "file")
destroy_atlas :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API, index: int) {
	a := &pool.atlases[index]
	platform.gpu_destroy_texture(a.texture)
	delete(a.slots, platform.heap_allocator)
	delete(a.free_slots)
	// The victims are in frame memory.
	a.texture, a.slots, a.free_slots, a.victims, a.victims_frame = {}, nil, nil, nil, 0
	a.layers, a.used_slots = 0, 0
	count_atlases(pool)
}

// count_atlases updates the stats that the atlases' sizes give.
@(private = "file")
count_atlases :: proc(pool: ^Texture_Pool) {
	pool.stats.capacity_pages, pool.stats.pool_bytes = 0, 0
	for &a in pool.atlases[:pool.atlas_count] {
		pool.stats.capacity_pages += u32(len(a.slots))
		pool.stats.pool_bytes += u64(a.layers) * atlas_layer_bytes(a.format)
	}
}

// ensure_texture_pool creates the pool's buffers the first time, and its atlases as the textures need them: an atlas is
// made when its first texture comes, with its format's share of the budget. When the budget has changed, or a format
// comes that the atlases leave no room for, they are all made again: every page leaves, the roots come back first, and
// the layers go to the formats by what they were in demand.
@(private = "file")
ensure_texture_pool :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API) -> bool {
	if pool.pages == nil {
		make_texture_tables(pool, platform)
	}
	// The records, the table, the feedback and its copies are made together or not at all.
	if pool.table == {} {
		pool.records = platform.gpu_create_buffer(
			{
				size = MAX_VIRTUAL_TEXTURES * size_of(Virtual_Texture_Record),
				usage = {.Storage},
				label = "virtual texture records",
			},
			nil,
		)
		pool.table = platform.gpu_create_buffer(
			{size = MAX_TEXTURE_PAGES * 4, usage = {.Storage}, label = "texture page table"},
			nil,
		)
		pool.feedback = platform.gpu_create_buffer(
			{size = MAX_TEXTURE_PAGES * 4, usage = {.Storage}, label = "texture page feedback"},
			nil,
		)
		if pool.records == {} ||
		   pool.table == {} ||
		   pool.feedback == {} ||
		   !ensure_readback_ring(
				   &pool.ring,
				   platform,
				   MAX_TEXTURE_PAGES * 4,
				   "texture page feedback copy",
			   ) {
			platform.gpu_destroy_buffer(pool.records)
			platform.gpu_destroy_buffer(pool.table)
			platform.gpu_destroy_buffer(pool.feedback)
			destroy_readback_ring(&pool.ring, platform)
			pool.records, pool.table, pool.feedback = {}, {}, {}
			return false
		}
	}
	bytes := wanted_pool_bytes(pool)
	made := false
	for &a in pool.atlases[:pool.atlas_count] {
		made ||= a.texture != {}
	}
	rebuild := made && pool.built_bytes != bytes
	for i in 0 ..< pool.atlas_count {
		a := &pool.atlases[i]
		if rebuild || a.textures == 0 || a.texture != {} {
			continue
		}
		layers := u32(bytes * atlas_weight(a.format) / 10 / atlas_layer_bytes(a.format))
		if made &&
		   pool.stats.pool_bytes + u64(max(layers, atlas_floor(a))) * atlas_layer_bytes(a.format) >
			   bytes {
			rebuild = true
			continue
		}
		if !make_atlas(pool, platform, i, layers) {
			return false
		}
		made = true
	}
	if rebuild {
		for &page, entry in pool.pages[:pool.high] {
			if _, has := state_slot(page.state); has {
				change_texture_page(pool, platform, u32(entry), Texture_Page_Left{})
			}
		}
		for i in 0 ..< pool.atlas_count {
			destroy_atlas(pool, platform, i)
		}
		// Every page left, so every entry is listed for the GPU, and until a frame copies them the table is the old
		// atlases'. The records name the new atlases.
		pool.table_sync = .Stale
		layers := plan_atlases(pool, bytes)
		for i in 0 ..< pool.atlas_count {
			if pool.atlases[i].textures > 0 && !make_atlas(pool, platform, i, layers[i]) {
				return false
			}
		}
	}
	pool.built_bytes = bytes
	return true
}

// virtual_sampler_bits is a record's `sampler` word for a texture's sampler under a cap on anisotropy.
@(private = "file")
virtual_sampler_bits :: proc(s: format.Texture_Sampler, cap: u8) -> u32 {
	anisotropy, _ := sampler_anisotropy(s, cap)
	bits := u32(s.wrap) & VIRTUAL_SAMPLER_WRAP_MASK
	if s.mip_filter == .Nearest {
		bits |= VIRTUAL_SAMPLER_MIP_NEAREST
	}
	return bits | u32(anisotropy) << VIRTUAL_SAMPLER_ANISOTROPY_SHIFT
}

// texture_pool_set_anisotropy sets the most anisotropy that the textures' samplers take (see texture_samplers_set_cap),
// which the records carry: a cap that changes rewrites the records that it changes.
texture_pool_set_anisotropy :: proc(pool: ^Texture_Pool, cap: u8) {
	if pool.anisotropy_cap == cap {
		return
	}
	pool.anisotropy_cap = cap
	for &tex, i in pool.textures[:pool.texture_high] {
		if !tex.live {
			continue
		}
		sampler := virtual_sampler_bits(tex.sampler, cap)
		if tex.record.sampler != sampler {
			tex.record.sampler = sampler
			mark_record_dirty(pool, u32(i + 1))
		}
	}
}

// texture_pool_bytes is the bytes that a budget in MiB is.
texture_pool_bytes :: proc(megabytes: u32) -> u64 {
	return u64(megabytes) * mem.Megabyte
}

// texture_pool_add gives a virtual texture a range of the table and a record, and returns its id, or 0 if the table or
// the records are full, or the texture cannot be in the pool. tail is the texture of its mips from the tail on. Its pages
// are absent: the root loads in the frames after, and the texture is ready when it is in (see texture_pool_ready).
texture_pool_add :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	guid: format.Guid,
	handle: asset.Handle,
	version: u32,
	modified: i64,
	data: []byte,
	blob: ^format.Texture_Blob,
	tail: gpu.Texture,
) -> (
	id: u32,
) {
	levels := format.texture_levels(data, blob)
	pages := format.texture_pages(data, blob)
	count := u32(len(pages))
	buffer: [32]u8
	if count == 0 || len(levels) > MAX_VIRTUAL_LEVELS {
		log.errorf(
			"render: the virtual texture %s has %d paged levels, and the pool takes %d",
			format.guid_format(guid, &buffer),
			len(levels),
			MAX_VIRTUAL_LEVELS,
		)
		return 0
	}
	pixel_format := gpu_format(blob.format)
	index := -1
	for &a, i in pool.atlases[:pool.atlas_count] {
		if a.format == pixel_format {
			index = i
		}
	}
	if index < 0 {
		if pool.atlas_count == MAX_TEXTURE_ATLASES {
			log.errorf("render: more than %d formats of virtual textures", MAX_TEXTURE_ATLASES)
			return 0
		}
		index = pool.atlas_count
		pool.atlases[index].format = pixel_format
		pool.atlas_count += 1
	}
	if pool.pages == nil {
		make_texture_tables(pool, platform)
	}
	first, found := take_texture_range(pool, count)
	if !found || len(pool.free_ids) == 0 {
		log.errorf(
			"render: more than %d virtual texture pages, or %d virtual textures, are resident",
			MAX_TEXTURE_PAGES,
			MAX_VIRTUAL_TEXTURES,
		)
		if found {
			append(&pool.free_ranges, [2]u32{first, count})
		}
		return 0
	}
	id = pop(&pool.free_ids)
	atlas := &pool.atlases[index]
	atlas.textures += 1
	if !ensure_texture_pool(pool, platform) || atlas.texture == {} {
		atlas.textures -= 1
		append(&pool.free_ranges, [2]u32{first, count})
		append(&pool.free_ids, id)
		return 0
	}
	heap := platform.heap_allocator
	tex := &pool.textures[id - 1]
	tex^ = {
		live = true,
		guid = guid,
		handle = handle,
		version = version,
		modified = modified,
		first = first,
		count = count,
		atlas = u32(index),
		blob_format = blob.format,
		sampler = blob.sampler,
		size = blob.size,
		mip_count = blob.mip_count,
		levels = slice.clone(levels, heap),
		pages = slice.clone(pages, heap),
		record = {
			size = blob.size,
			table = first,
			page_count = count,
			levels = u32(len(levels)),
			atlas = gpu.read_index(atlas.texture),
			tail = gpu.read_index(tail),
			sampler = virtual_sampler_bits(blob.sampler, pool.anisotropy_cap),
		},
	}
	for l, i in levels {
		tex.record.level_first[i] = l.first_page
	}
	mark_record_dirty(pool, id)
	for i in 0 ..< count {
		entry := first + i
		pool.pages[entry] = {
			texture = id,
		}
		pool.entries[entry] = TEXTURE_PAGE_ABSENT
		mark_entry_dirty(pool, entry)
	}
	pool.high = max(pool.high, first + count)
	pool.texture_high = max(pool.texture_high, id)
	return id
}

// texture_pool_remove takes a texture out of the pool: its reads end, its tiles are free, and its range of the table and
// its record wait before another texture takes them.
texture_pool_remove :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API, id: u32) {
	if id == 0 || int(id) > len(pool.textures) || !pool.textures[id - 1].live {
		return
	}
	tex := &pool.textures[id - 1]
	// From the first page, the finest, so that a page's children have left before it does.
	for i in 0 ..< tex.count {
		entry := tex.first + i
		change_texture_page(pool, platform, entry, Texture_Page_Left{})
		pool.pages[entry].texture = 0
	}
	pool.atlases[tex.atlas].textures -= 1
	append(
		&pool.cooling,
		Texture_Cooling{{tex.first, tex.count}, id, pool.frame + TEXTURE_TABLE_COOL_FRAMES},
	)
	delete(tex.levels, platform.heap_allocator)
	delete(tex.pages, platform.heap_allocator)
	// The record stays as the GPU has it, for the materials that name it until their tables are made again.
	tex.live = false
	tex.levels, tex.pages = nil, nil
}

@(private = "file")
take_texture_range :: proc(pool: ^Texture_Pool, count: u32) -> (first: u32, ok: bool) {
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

// texture_pool_ready is whether a texture's root is in the pool, so that it draws.
texture_pool_ready :: proc(pool: ^Texture_Pool, id: u32) -> bool {
	if id == 0 || int(id) > len(pool.textures) {
		return false
	}
	tex := &pool.textures[id - 1]
	if !tex.live || tex.failed {
		return false
	}
	_, resident := pool.pages[tex.first + tex.count - 1].state.(Page_Resident)
	return resident
}

// texture_pool_failed is whether a page of a texture was not what its table said.
texture_pool_failed :: proc(pool: ^Texture_Pool, id: u32) -> bool {
	return id != 0 && int(id) <= len(pool.textures) && pool.textures[id - 1].failed
}

// texture_pool_drawable is whether a virtual texture may be sampled from the pool now: not while the atlases were made
// again and no pass has copied the table and the records for them.
texture_pool_drawable :: proc(pool: ^Texture_Pool) -> bool {
	return pool.table_sync != .Stale
}

// texture_pool_not_sent says that the frame's own graph did not execute, so that the views that draw after it in the
// frame do not take its stream texture pages pass as done.
texture_pool_not_sent :: proc(pool: ^Texture_Pool) {
	if pool.table_sync == .Sent {
		pool.table_sync = .Stale
	}
}

// check_texture_budget asks the platform for the video memory that the process uses, every TEXTURE_BUDGET_CHECK_FRAMES
// frames. While it is over its budget, the atlases are to be what the budget leaves of them, which is never fewer bytes
// than a layer of each format that a texture has, and never more than the quality's. They are made again at the update.
@(private = "file")
check_texture_budget :: proc(pool: ^Texture_Pool, platform: ^core.Platform_API) {
	if platform.gpu_video_memory == nil ||
	   (pool.frame != 1 && pool.frame % TEXTURE_BUDGET_CHECK_FRAMES != 0) {
		return
	}
	used, budget := platform.gpu_video_memory()
	pool.stats.video_used, pool.stats.video_budget = used, budget
	if budget == 0 || used <= budget || pool.stats.pool_bytes == 0 {
		return
	}
	others := used - min(used, pool.stats.pool_bytes)
	target := budget > others ? budget - others : 0
	target = max(target, floor_pool_bytes(pool))
	if target < pool.built_bytes {
		pool.limit_bytes = target
		log.warnf(
			"render: the process uses %d MiB of its %d MiB of video memory, so the texture pool shrinks to %d MiB",
			used / mem.Megabyte,
			budget / mem.Megabyte,
			target / mem.Megabyte,
		)
	}
}

// texture_pool_update starts the pool's frame: it takes back what a frame that did not execute was to copy, reads the
// feedback that came back, marks the pages that views drew from, lists the ones that they want, ends the reads that
// nothing wants any more, and starts reads for the most wanted. Call it once a frame, before the frame's graphs.
texture_pool_update :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
) {
	pool.frame += 1
	// What came in since the last update is this frame's to draw shadows for.
	pool.refined, pool.refining = pool.refining, pool.refined
	clear(&pool.refining)
	check_texture_budget(pool, platform)
	if pool.pages == nil {
		return
	}
	pool.whole_budget = TEXTURE_WHOLE_PAGES_PER_FRAME
	pool.wanted = nil
	for i := len(pool.cooling) - 1; i >= 0; i -= 1 {
		if pool.cooling[i].until <= pool.frame {
			append(&pool.free_ranges, pool.cooling[i].range)
			append(&pool.free_ids, pool.cooling[i].id)
			unordered_remove(&pool.cooling, i)
		}
	}
	// A pool that could not be made, or made again, is tried again.
	if !ensure_texture_pool(pool, platform) {
		return
	}
	if pool.table_sync == .Sent {
		pool.table_sync = .Stale
	}
	// What the last frame's pass was to copy, if that frame did not execute.
	for &page, entry in pool.pages[:pool.high] {
		if _, copying := page.state.(Page_Copying); copying {
			change_texture_page(pool, platform, u32(entry), Texture_Page_Not_Copied{})
		}
		if page.sync == .Sent {
			mark_entry_dirty(pool, u32(entry))
		}
	}
	for &tex, i in pool.textures[:pool.texture_high] {
		if tex.live && tex.record_sync == .Sent {
			mark_record_dirty(pool, u32(i + 1))
		}
	}

	wanted := make([dynamic]Wanted_Page, platform.frame_allocator)
	want :: proc(pool: ^Texture_Pool, wanted: ^[dynamic]Wanted_Page, entry: u32, priority: f32) {
		page := &pool.pages[entry]
		if page.texture == 0 || pool.textures[page.texture - 1].failed {
			return
		}
		if page.wanted_frame != pool.frame {
			page.wanted_priority = 0
		}
		page.wanted_frame = pool.frame
		page.wanted_priority = max(page.wanted_priority, priority)
		if _, has := state_slot(page.state); has {
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
	// The roots are always wanted, before anything else.
	for &tex in pool.textures[:pool.texture_high] {
		if tex.live {
			want(pool, &wanted, tex.first + tex.count - 1, max(f32))
		}
	}
	// The page that covers a wanted page is wanted as much, and the one that covers that, so the chain to the root stays
	// whole: a page has a tile only while its parent has one.
	for i := 0; i < len(wanted); i += 1 {
		w := wanted[i]
		if parent, has := page_parent(pool, w.entry); has {
			if pool.pages[parent].wanted_frame != pool.frame ||
			   pool.pages[parent].wanted_priority < w.priority {
				want(pool, &wanted, parent, w.priority)
			}
		}
	}
	// A page that is wanted twice is listed once, at its higher priority.
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
	pool.stats.pending_pages = u32(len(wanted))
	// What each atlas is asked for, which is what it is divided by, decays over some frames.
	counts: [MAX_TEXTURE_ATLASES]u32
	for w in wanted {
		counts[pool.textures[pool.pages[w.entry].texture - 1].atlas] += 1
	}
	for &a, i in pool.atlases[:pool.atlas_count] {
		a.demand = max(a.demand - a.demand / 16, counts[i] + a.used_slots)
	}

	for &page, entry in pool.pages[:pool.high] {
		if _, reading := page.state.(Page_Reading);
		   reading && page.wanted_frame + TEXTURE_PAGE_FORGET_FRAMES < pool.frame {
			change_texture_page(pool, platform, u32(entry), Texture_Page_Left{})
		}
	}
	if platform.file_read_begin == nil {
		return
	}
	for w in wanted {
		if pool.open_reads >= TEXTURE_PAGE_READS {
			break
		}
		page := &pool.pages[w.entry]
		tex, record := page_record(pool, w.entry)
		// A root's block is in the head, which the load takes it from.
		if page.state != nil || .Root in record.flags {
			continue
		}
		location, found := asset.blob_location(assets, tex.guid)
		// The cooker wrote the blob again: its pages are another blob's, and the new version streams soon.
		if !found || !location.raw || platform.file_modified(location.path) != tex.modified {
			continue
		}
		if read := platform.file_read_begin(
			location.path,
			location.offset + i64(record.offset),
			int(record.compressed_size),
		); read != 0 {
			change_texture_page(pool, platform, w.entry, Texture_Page_Read_Began{read})
		}
	}
}

// Texture_Page_Load is one page that a frame decompresses and copies into an atlas.
@(private)
Texture_Page_Load :: struct {
	entry:     u32,
	atlas:     u32,
	slot:      u32,
	block:     []byte,
	record:    format.Texture_Page,
	// The page's rows as the blocks have them, and in the upload: its rows are pitch bytes apart.
	rows:      u32,
	row_bytes: u32,
	pitch:     u32,
	payload:   []byte,
	upload:    gpu.Upload,
	ok:        bool,
}

// Stream_Texture_Pages is what a frame's stream texture pages pass does, and what its commit makes of it.
@(private)
Stream_Texture_Pages :: struct {
	pool:          ^Texture_Pool,
	platform:      ^core.Platform_API,
	loads:         []Texture_Page_Load,
	// Runs of the table that the GPU does not have: the first entry, the count, and where they are in table_upload. Then the
	// same for the records, by id less 1.
	runs:          [][2]u32,
	entries:       []u32,
	table_upload:  gpu.Upload,
	record_runs:   [][2]u32,
	record_ids:    []u32,
	record_upload: gpu.Upload,
	zero_upload:   gpu.Upload,
	atlases:       [MAX_TEXTURE_ATLASES]Texture,
	records:       Buffer,
	table:         Buffer,
	feedback:      Buffer,
	high:          u32,
}

// Texture_Pool_Frame is the graph's resources of the pool for a frame, 0 before the pool has any virtual texture. The
// shaders get the records' read index, the table's read index and the feedback's write index in Frame_Constants:
// texture_records, texture_pages and texture_feedback. A pass that samples virtual textures declares what it reads (see
// declare_texture_pool_reads), and the pass that writes the feedback declares it written.
Texture_Pool_Frame :: struct {
	records:  Buffer,
	table:    Buffer,
	feedback: Buffer,
	// The atlases that exist, which the records name by their read indices. 0 for an atlas that does not.
	atlases:  [MAX_TEXTURE_ATLASES]Texture,
}

// prepare_stream_texture_pages picks what a frame's stream texture pages pass copies, and decompresses it into the
// frame's uploads: the pages that are ready to load, the changed entries of the table and records, and zeros for the
// feedback. The pages are the roots, then the pages whose reads are done, each only when its parent has a slot. A page
// takes a free tile of its atlas, or the tile of the page that no view has used for the longest, if that is long
// enough. It gives nil before the pool has a texture, and when the frame's uploads are full.
// commit_stream_texture_pages is what the frame leaves once it executes; without it, the next update takes everything
// back.
@(private)
prepare_stream_texture_pages :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
) -> ^Stream_Texture_Pages {
	if pool.table == {} {
		return nil
	}
	sp := new(Stream_Texture_Pages, platform.frame_allocator)
	sp.pool, sp.platform = pool, platform
	loads := make([dynamic]Texture_Page_Load, platform.frame_allocator)
	full: [MAX_TEXTURE_ATLASES]bool

	// The candidates: a wanted page whose block is at hand, the most wanted first. A page's parent is wanted at least as
	// much as it is, so it comes first.
	for w in pool.wanted {
		if len(loads) >= TEXTURE_PAGE_LOADS_PER_FRAME {
			break
		}
		page := &pool.pages[w.entry]
		// Its texture went since the update listed it, as a version that a newer one replaced does.
		if page.texture == 0 {
			continue
		}
		tex, record := page_record(pool, w.entry)
		if full[tex.atlas] || pool.atlases[tex.atlas].texture == {} {
			continue
		}
		block: []byte
		switch s in page.state {
		case Page_Reading:
			data, state := platform.file_read_result(s.read)
			if state == .Pending {
				continue
			}
			if state == .Failed {
				change_texture_page(pool, platform, w.entry, Texture_Page_Left{})
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
			head, loaded := asset.data(assets, tex.handle)
			if !loaded ||
			   asset.version(assets, tex.handle) != tex.version ||
			   u64(record.offset) + u64(record.compressed_size) > u64(len(head)) {
				continue
			}
			block = head[record.offset:][:record.compressed_size]
		}
		if len(block) != int(record.compressed_size) || hash.fnv32a(block) != record.checksum {
			fail_texture_page(pool, platform, w.entry, "is not the page that its table names")
			continue
		}
		if parent, has := page_parent(pool, w.entry); has {
			if _, parent_has := state_slot(pool.pages[parent].state); !parent_has {
				continue
			}
		}
		atlas := &pool.atlases[tex.atlas]
		rows := u32(format.TEXTURE_PAGE_TEXELS / 4)
		row_bytes := rows * u32(gpu.format_size(atlas.format))
		pitch :=
			(row_bytes + gpu.TEXTURE_COPY_PITCH_ALIGN - 1) &~ (gpu.TEXTURE_COPY_PITCH_ALIGN - 1)
		if record.size != rows * row_bytes {
			fail_texture_page(pool, platform, w.entry, "is not the size of a page")
			continue
		}
		slot, found := take_texture_slot(pool, platform, int(tex.atlas))
		if !found {
			// Nothing can leave for it, and so for nothing less wanted in its atlas either.
			full[tex.atlas] = true
			continue
		}
		upload, uploaded := platform.gpu_upload(int(pitch * rows), gpu.TEXTURE_COPY_OFFSET_ALIGN)
		if !uploaded {
			append(&atlas.free_slots, slot)
			break
		}
		change_texture_page(pool, platform, w.entry, Texture_Page_Took_Slot{slot})
		append(
			&loads,
			Texture_Page_Load {
				entry = w.entry,
				atlas = tex.atlas,
				slot = slot,
				block = block,
				record = record,
				rows = rows,
				row_bytes = row_bytes,
				pitch = pitch,
				payload = make([]byte, record.size, platform.frame_allocator),
				upload = upload,
			},
		)
	}

	// Decompressed on the job threads, each into the frame's upload memory, and checked there.
	if len(loads) > 0 {
		list := make([]jobs.Job, len(loads), platform.frame_allocator)
		for &load, i in loads {
			list[i] = {decompress_texture_page, &load}
		}
		counter: jobs.Counter
		platform.jobs_run(list, &counter)
		platform.jobs_wait(&counter)
	}
	kept := 0
	for load in loads {
		if !load.ok {
			fail_texture_page(pool, platform, load.entry, "does not decompress into a page")
			continue
		}
		loads[kept] = load
		kept += 1
	}
	sp.loads = loads[:kept]

	// The table's changed entries and the changed records, in runs.
	slice.sort(pool.dirty[:])
	entries := slice.clone(pool.dirty[:], platform.frame_allocator)
	runs := make([dynamic][2]u32, platform.frame_allocator)
	values := make([]u32, len(entries), platform.frame_allocator)
	for entry, i in entries {
		values[i] = pool.entries[entry]
		if i > 0 && entry == entries[i - 1] + 1 {
			runs[len(runs) - 1].y += 1
		} else {
			append(&runs, [2]u32{entry, 1})
		}
	}
	sp.entries, sp.runs = entries, runs[:]
	slice.sort(pool.dirty_records[:])
	ids := slice.clone(pool.dirty_records[:], platform.frame_allocator)
	record_runs := make([dynamic][2]u32, platform.frame_allocator)
	records := make([]Virtual_Texture_Record, len(ids), platform.frame_allocator)
	for id, i in ids {
		records[i] = pool.textures[id - 1].record
		if i > 0 && id == ids[i - 1] + 1 {
			record_runs[len(record_runs) - 1].y += 1
		} else {
			append(&record_runs, [2]u32{id - 1, 1})
		}
	}
	sp.record_ids, sp.record_runs = ids, record_runs[:]
	ok := true
	if len(values) > 0 {
		sp.table_upload, ok = upload_bytes(platform, slice.to_bytes(values))
	}
	if ok && len(records) > 0 {
		sp.record_upload, ok = upload_bytes(platform, slice.to_bytes(records))
	}
	sp.high = pool.high
	if ok && sp.high > 0 {
		sp.zero_upload, ok = platform.gpu_upload(int(sp.high) * 4, 16)
		if ok {
			mem.zero_slice(sp.zero_upload.data)
		}
	}
	if !ok {
		// The frame's uploads are full: nothing is copied, and the next update takes the tiles back.
		return nil
	}
	for entry in entries {
		pool.pages[entry].sync = .Sent
	}
	clear(&pool.dirty)
	for id in ids {
		pool.textures[id - 1].record_sync = .Sent
	}
	clear(&pool.dirty_records)
	if pool.table_sync == .Stale {
		pool.table_sync = .Sent
	}
	return sp
}

// add_stream_texture_pages_pass adds the pass that brings the pool up to date before anything draws from it (see
// prepare_stream_texture_pages), after a copy of the feedback that the last frame's views wrote. Call it in the frame's
// own view, before the passes that draw.
@(private)
add_stream_texture_pages_pass :: proc(
	g: ^Graph,
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	assets: ^asset.Assets,
) -> (
	frame: Texture_Pool_Frame,
) {
	sp := prepare_stream_texture_pages(pool, platform, assets)
	if sp == nil {
		return
	}

	sp.records = import_buffer(g, pool.records)
	sp.table = import_buffer(g, pool.table)
	sp.feedback = import_buffer(g, pool.feedback)
	for &a, i in pool.atlases[:pool.atlas_count] {
		if a.texture != {} {
			sp.atlases[i] = import_texture(g, a.texture, .Sampled)
		}
	}
	// What every view of the last frame wrote, the extra views after the frame's own, is copied for the CPU before this
	// frame zeroes it.
	if sp.high > 0 {
		add_readback_copy(
			g,
			platform,
			&pool.ring,
			sp.feedback,
			sp.high * 4,
			"copy texture page feedback",
		)
	}
	p := add_compute_pass(g, "stream texture pages", stream_texture_pages, sp)
	copy_dest(g, p, sp.records)
	copy_dest(g, p, sp.table)
	copy_dest(g, p, sp.feedback)
	copied: [MAX_TEXTURE_ATLASES]bool
	for load in sp.loads {
		copied[load.atlas] = true
	}
	for texture, i in sp.atlases {
		if copied[i] {
			copy_dest(g, p, texture)
		}
	}
	on_executed(g, commit_stream_texture_pages, sp)
	return {records = sp.records, table = sp.table, feedback = sp.feedback, atlases = sp.atlases}
}

// texture_pool_buffers imports the pool's resources into a graph that draws from the pool and does not bring it up to
// date: an extra view's.
@(private)
texture_pool_buffers :: proc(g: ^Graph, pool: ^Texture_Pool) -> (frame: Texture_Pool_Frame) {
	if pool.records == {} || pool.table == {} {
		return
	}
	frame = {
		records  = import_buffer(g, pool.records),
		table    = import_buffer(g, pool.table),
		feedback = import_buffer(g, pool.feedback),
	}
	for &a, i in pool.atlases[:pool.atlas_count] {
		if a.texture != {} {
			frame.atlases[i] = import_texture(g, a.texture, .Sampled)
		}
	}
	return
}

// declare_texture_pool_reads declares that a pass samples virtual textures: it reads the records, the table and the
// atlases, which the stream texture pages pass wrote.
@(private)
declare_texture_pool_reads :: proc(g: ^Graph, p: Pass, frame: Texture_Pool_Frame) {
	if frame.records == 0 {
		return
	}
	read(g, p, frame.records)
	read(g, p, frame.table)
	for atlas in frame.atlases {
		if atlas != 0 {
			read(g, p, atlas)
		}
	}
}

// declare_texture_feedback declares that a pass whose pixel shaders sample virtual textures writes the pool's feedback:
// the world pass and the transparent ones, which draw the camera's views (see cn_feedback_begin in
// material_virtual.hlsli). A view whose constants have no feedback (Frame_Constants.texture_feedback) writes none.
@(private)
declare_texture_feedback :: proc(g: ^Graph, p: Pass, frame: Texture_Pool_Frame) {
	if frame.feedback != 0 {
		write(g, p, frame.feedback)
	}
}

@(private = "file")
decompress_texture_page :: proc(data: rawptr) {
	load := (^Texture_Page_Load)(data)
	if !lz4.decompress(load.block, load.payload) {
		return
	}
	for row in 0 ..< load.rows {
		copy(
			load.upload.data[row * load.pitch:][:load.row_bytes],
			load.payload[row * load.row_bytes:][:load.row_bytes],
		)
	}
	load.ok = true
}

@(private = "file")
stream_texture_pages :: proc(ctx: ^Pass_Context) {
	sp := (^Stream_Texture_Pages)(ctx.data)
	g := ctx.graph
	for load in sp.loads {
		layer, tile := load.slot / TEXTURE_ATLAS_LAYER_SLOTS, load.slot % TEXTURE_ATLAS_LAYER_SLOTS
		gpu.cmd_copy_buffer_to_texture(
			ctx.cb,
			load.upload.buffer,
			load.upload.offset,
			load.pitch,
			gpu_texture(g, sp.atlases[load.atlas]),
			0,
			layer,
			{
				(tile % TEXTURE_ATLAS_TILES) * format.TEXTURE_PAGE_TEXELS,
				(tile / TEXTURE_ATLAS_TILES) * format.TEXTURE_PAGE_TEXELS,
			},
			{format.TEXTURE_PAGE_TEXELS, format.TEXTURE_PAGE_TEXELS},
		)
	}
	offset := sp.table_upload.offset
	for run in sp.runs {
		size := run.y * 4
		gpu.cmd_copy_buffer(
			ctx.cb,
			sp.table_upload.buffer,
			offset,
			gpu_buffer(g, sp.table),
			run.x * 4,
			size,
		)
		offset += size
	}
	offset = sp.record_upload.offset
	for run in sp.record_runs {
		size := run.y * size_of(Virtual_Texture_Record)
		gpu.cmd_copy_buffer(
			ctx.cb,
			sp.record_upload.buffer,
			offset,
			gpu_buffer(g, sp.records),
			run.x * size_of(Virtual_Texture_Record),
			size,
		)
		offset += size
	}
	if sp.high > 0 {
		gpu.cmd_copy_buffer(
			ctx.cb,
			sp.zero_upload.buffer,
			sp.zero_upload.offset,
			gpu_buffer(g, sp.feedback),
			0,
			sp.high * 4,
		)
	}
}

// commit_stream_texture_pages is what a frame that executed leaves: its pages are resident, and the GPU's table and
// records are the CPU's for the entries and records that it copied.
// texture_pool_refined are the pages that came in before this frame's update, as the textures that they refine.
texture_pool_refined :: proc(pool: ^Texture_Pool) -> []Refined_Texture {
	return pool.refined[:]
}

@(private)
commit_stream_texture_pages :: proc(data: rawptr) {
	sp := (^Stream_Texture_Pages)(data)
	pool := sp.pool
	for load in sp.loads {
		if change_texture_page(pool, sp.platform, load.entry, Texture_Page_Copied{}) {
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
	for id in sp.record_ids {
		if pool.textures[id - 1].record_sync == .Sent {
			pool.textures[id - 1].record_sync = .Clean
		}
	}
	pool.stats.resident_pages = 0
	for &a in pool.atlases[:pool.atlas_count] {
		pool.stats.resident_pages += a.used_slots
	}
}

// take_texture_slot gives a free tile of an atlas, or the tile of the resident page that no view has used for the
// longest: one that is not a root, that nothing with a tile has as its parent, and that no view used in the last
// TEXTURE_PAGE_KEEP_FRAMES frames. That page leaves.
@(private = "file")
take_texture_slot :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	index: int,
) -> (
	slot: u32,
	ok: bool,
) {
	a := &pool.atlases[index]
	if len(a.free_slots) > 0 {
		return pop(&a.free_slots), true
	}
	leaves :: proc(pool: ^Texture_Pool, entry: u32) -> bool {
		page := &pool.pages[entry]
		_, record := page_record(pool, entry)
		_, resident := page.state.(Page_Resident)
		return(
			resident &&
			.Root not_in record.flags &&
			page.dependents == 0 &&
			page.used_frame + TEXTURE_PAGE_KEEP_FRAMES < pool.frame \
		)
	}
	// The pages that may leave are listed once a frame, the one used longest ago last.
	if a.victims_frame != pool.frame {
		a.victims_frame = pool.frame
		a.victims = make([dynamic]Texture_Victim, platform.frame_allocator)
		for entry in a.slots {
			if entry != TEXTURE_PAGE_ABSENT && leaves(pool, entry) {
				append(&a.victims, Texture_Victim{entry, pool.pages[entry].used_frame})
			}
		}
		slice.sort_by(a.victims[:], proc(x, y: Texture_Victim) -> bool {
			return x.used > y.used || (x.used == y.used && x.entry > y.entry)
		})
	}
	// A page that was listed may have got a child since.
	for len(a.victims) > 0 {
		victim := pop(&a.victims)
		if leaves(pool, victim.entry) {
			change_texture_page(pool, platform, victim.entry, Texture_Page_Left{})
			return pop(&a.free_slots), true
		}
	}
	return
}

// fail_texture_page takes a page whose bytes are wrong out of the pool, and its texture with it from the pages that are
// asked for, which is logged once for the texture. The cooker's next blob streams as a new version.
@(private = "file")
fail_texture_page :: proc(
	pool: ^Texture_Pool,
	platform: ^core.Platform_API,
	entry: u32,
	reason: string,
) {
	tex, _ := page_record(pool, entry)
	change_texture_page(pool, platform, entry, Texture_Page_Left{})
	if !tex.failed {
		tex.failed = true
		buffer: [32]u8
		log.errorf(
			"render: page %d of the texture %s %s",
			entry - tex.first,
			format.guid_format(tex.guid, &buffer),
			reason,
		)
	}
}

// texture_pool_resident is whether a texture's page is in the pool, for the tests.
texture_pool_resident :: proc(pool: ^Texture_Pool, id: u32, page: u32) -> bool {
	if id == 0 || int(id) > len(pool.textures) || page >= pool.textures[id - 1].count {
		return false
	}
	_, resident := pool.pages[pool.textures[id - 1].first + page].state.(Page_Resident)
	return resident
}
