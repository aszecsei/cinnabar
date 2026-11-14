package render

import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:slice"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The virtual shadow map (see docs/rendering/lighting-and-shadows.md#virtual-shadow-maps): a directional light's stack of
// clipmap levels around the camera, each a virtual texture twice the extent of the one before. A compute pass marks the
// pages that the frame reads, the allocation's passes give them physical pages in one pool, and the depth pass and the
// lights reach the pool through a page table. With the cache, the table and the pool last from frame to frame, so a page
// that the pool still holds does not draw again, and when the pool is full the pages that were asked for longest ago
// leave first. virtual_shadow.hlsli holds the shaders' side, and the procs here match it, so tests on the null backend
// cover the logic that the shaders run.

// A level is this many pages on a side, each of this many texels.
VIRTUAL_PAGES :: 128
VIRTUAL_PAGE_TEXELS :: 128
VIRTUAL_SIZE :: VIRTUAL_PAGES * VIRTUAL_PAGE_TEXELS
VIRTUAL_LEVEL_PAGES :: VIRTUAL_PAGES * VIRTUAL_PAGES
VIRTUAL_LEVEL_WORDS :: VIRTUAL_LEVEL_PAGES / 32
// The first level's extent in meters, whose texel is about a millimeter: a pixel's footprint at 1 m at 1080p. A level's
// half extent is about 8.8 times the distance that its texel matches, so the levels need to reach their last texel's
// match, not their last extent. Past that, each pixel takes more of the last level's texels than it can show, and more
// of its pages, with nothing coarser to fall back to.
VIRTUAL_FIRST_EXTENT :: 16
// The most levels that a Shadow_Params has, which the buffers hold.
VIRTUAL_MAX_LEVELS :: 13
// A page table's entry for a virtual page without a physical page. An entry with VIRTUAL_DRAW is a page that the frame
// draws, which only the depth pass and its culling look for; the lookups take its physical page without the bit.
VIRTUAL_NO_PAGE :: max(u32)
VIRTUAL_DRAW :: u32(1) << 31
// A level's table is toroidal: a page's entry is at its absolute page modulo VIRTUAL_PAGES on each axis, so a page keeps
// its entry as the level's origin moves. After the levels' entries, the table holds each level's count of the pages that
// the frame draws, at VIRTUAL_TABLE_COUNTS.
VIRTUAL_TABLE_COUNTS :: VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_PAGES
VIRTUAL_TABLE_WORDS :: VIRTUAL_TABLE_COUNTS + VIRTUAL_MAX_LEVELS
// A physical page's record of a page that holds nothing.
VIRTUAL_FREE :: max(u32)
// The eviction's histogram of the pages' ages, in frames since a frame asked for them. Pages older than its last bin
// count as equally old. Matches VIRTUAL_AGE_BINS in virtual_shadow_allocate.hlsl.
VIRTUAL_AGE_BINS :: 1024
// The most physical pages that a Shadow_Params' pool has, which the allocation's scratch buffer holds.
VIRTUAL_MAX_POOL_PAGES :: 64 * 64
// The scratch buffer's words: counters, the histogram, then the list of the pages that the frame may give out. Matches
// SCRATCH_* in virtual_shadow_allocate.hlsl.
VIRTUAL_SCRATCH_HISTOGRAM :: 16
VIRTUAL_SCRATCH_LIST :: VIRTUAL_SCRATCH_HISTOGRAM + VIRTUAL_AGE_BINS
VIRTUAL_SCRATCH_WORDS :: VIRTUAL_SCRATCH_LIST + VIRTUAL_MAX_POOL_PAGES
// How far the camera may be from the levels' anchor, in meters on each axis, before the anchor moves to it (see
// virtual_grid_anchor). Level 0's pages are 12.5 cm, so its page indices stay within 2^30.
VIRTUAL_ANCHOR_REACH :: f64(1 << 26)
// A level's depth covers this many times its extent on each side of its anchor, which stays while the camera is within
// the level's extent of it (see virtual_depth_anchor), so the range always holds the level's extent around the camera.
VIRTUAL_DEPTH_RANGE :: 2
VIRTUAL_POOL_FORMAT :: gpu.Format.R32_Uint
// The view model's pixels are not where the camera's projection would place them, so a level's valid rectangle also
// holds this many meters around the camera.
VIRTUAL_VIEW_MODEL_REACH :: 2
// The volume mark's grid through the view's frustum, and how many levels coarser than their footprints its points mark.
// Match VOLUME_GRID and VOLUME_LEVELS in virtual_shadow_mark.hlsl.
VIRTUAL_VOLUME_GRID :: [3]u32{64, 40, 32}
VIRTUAL_VOLUME_LEVELS :: 3
// How far the volume mark reaches, in meters, which is the cascades' reach: past it, the fog and the sprites are lit, as
// they are past the cascades. A farther point takes a page of the coarsest level for itself, and the far slices of the
// grid would take more pages than the pool has.
VIRTUAL_VOLUME_REACH :: SHADOW_DISTANCE
// The lookups' offsets move a point by at most this many texels. Matches MARK_MARGIN in virtual_shadow_mark.hlsl.
VIRTUAL_MARK_MARGIN :: 1
VIRTUAL_MARK_GROUP_SIZE :: 8
// A sphere over more than this many pages on a side counts as reaching one, which is cheaper to draw than to test.
// Matches VIRTUAL_CULL_PAGES in virtual_pages.hlsli.
VIRTUAL_CULL_PAGES :: 8
// Matches numthreads in virtual_shadow_allocate.hlsl.
VIRTUAL_ALLOCATE_GROUP_SIZE :: 64

VIRTUAL_MARK_SHADER :: #load("../content/shaders/virtual_shadow_mark.hlsl.meta", string)
VIRTUAL_ALLOCATE_SHADER :: #load("../content/shaders/virtual_shadow_allocate.hlsl.meta", string)

// Virtual_Shadow_Stats are the virtual shadow map's pages a frame or two ago, which the editor shows: those that the
// frame asked for, those that it got, those that the pool had no room for, and how many the pool holds; of those that
// it got, those that the pool still held and those that it drew; the pages that left the pool for them, and the pages
// that the pool holds after the frame. Matches the words that virtual_shadow_allocate.hlsl stores.
Virtual_Shadow_Stats :: struct {
	requested: u32,
	allocated: u32,
	missed:    u32,
	capacity:  u32,
	cached:    u32,
	drawn:     u32,
	evicted:   u32,
	resident:  u32,
}

// Virtual_Shadows is the virtual shadow map's pipelines and the buffers that a view's passes fill and use within its
// graph, which every view shares, in Shadow_Passes: the requests, the allocation's scratch and the pool clear's
// arguments start empty in each graph.
Virtual_Shadows :: struct {
	mark_pipeline:     Shader_Pipeline,
	allocate_pipeline: Shader_Pipeline,
	requests:          gpu.Buffer,
	scratch:           gpu.Buffer,
	arguments:         gpu.Buffer,
}

// Virtual_Page is a physical page's record, which lasts with the pool: the level and the absolute page that it holds,
// with level VIRTUAL_FREE for none, and the last frame that asked for it, by the cache's epoch. Matches Virtual_Page in
// virtual_shadow_allocate.hlsl.
Virtual_Page :: struct {
	level: u32,
	page:  [2]i32,
	last:  u32,
}

// Virtual_Cache is what the pool's pages were drawn for, and so what keeps them valid: the world position that the
// levels' grids are measured from (see virtual_grid_anchor), the light's direction, the shadows' parameters and
// settings, and each level's depth anchor (see virtual_depth_anchor), with the epoch of the last frame that drew it,
// which the pages' ages count from, the scene frame that it drew in, whose changes of casters were the last that it
// took (see casters.odin), and the slots that it drew live.
Virtual_Cache :: struct {
	anchor:    ecs.World_Position,
	direction: [3]f32,
	params:    Shadow_Params,
	settings:  Shadow_Settings,
	anchors:   [VIRTUAL_MAX_LEVELS]f64,
	epoch:     u32,
	frame:     u64,
	live:      Live_Slots,
}

// Virtual_State is one view's virtual shadow map between frames, in View_State: its pool of pages, which the level
// sizes, so a view at another level has a pool of its own, the page table and the pages' records, which last with the
// pool, what they were drawn for, and its stats. The pool is not a graph's transient texture: every view's
// Frame_Constants holds its indices, and they are written before transients have any.
//
// cache is nil when the table and the records hold nothing that a frame can keep: before the first frame, after a new
// pool, and after a frame that executed without the virtual shadow map. Only a frame's commit changes it (see
// commit_virtual_cache), so a frame that fails leaves what the GPU last drew. A soft restart makes a new View_State.
Virtual_State :: struct {
	stats:      gpu.Buffer,
	stats_ring: Readback_Ring,
	last_stats: Virtual_Shadow_Stats,
	pool:       gpu.Texture,
	pool_pages: [2]u32,
	table:      gpu.Buffer,
	pages:      gpu.Buffer,
	cache:      Maybe(Virtual_Cache),
}

// Virtual_Frame is one frame's virtual shadow map, in Shadow_Frame. count is its levels, 0 without it, which are the
// first shadow views. cache is what the frame draws for, which its commit keeps; reset is whether the frame starts
// the table and the records again, and invalidate the levels whose pages it drops.
@(private)
Virtual_Frame :: struct {
	count:      int,
	camera:     Virtual_Camera,
	cache:      Virtual_Cache,
	reset:      bool,
	invalidate: u32,
	// The pages that the frame drops under the casters that changed and the live ones, in the upload ring, if any.
	dropped:    gpu.Upload,
	drops:      bool,
	pool:       Texture,
	requests:   Buffer,
	table:      Buffer,
	pages:      Buffer,
	scratch:    Buffer,
	arguments:  Buffer,
	stats:      Buffer,
}

// Virtual_Camera is what a level depends on: the camera's axes, projection scales and near plane, its position in
// meters from the levels' anchor in the world (see virtual_grid_anchor), and how a distance picks a level. The levels'
// grids are of the world's space, not the render origin's, so a rebase moves no page.
Virtual_Camera :: struct {
	right, up, forward: [3]f32,
	scale:              [2]f32,
	near:               f32,
	position:           [3]f64,
	selection:          Virtual_Selection,
}

// Virtual_Selection is how a distance from the camera picks a level. Frame_Constants has its fields.
Virtual_Selection :: struct {
	levels:      int,
	first_texel: f32,
	// The angle that a pixel takes up, so its footprint at a distance is the distance times this.
	pixel_angle: f32,
	// The quality's bias in levels: above 0 is coarser.
	bias:        f32,
}

// Virtual_Level is one level: its projection and its view, with the page_origin that nests its grid in the next
// level's, its culling planes, and its valid rectangle in texels, which is its depth pass's scissor.
Virtual_Level :: struct {
	projection: matrix[4, 4]f32,
	view:       Shadow_View,
	planes:     [6][4]f32,
	scissor:    [4]u32,
}

// Virtual_Mark_Push matches Virtual_Mark_Push in virtual_shadow_mark.hlsl.
@(private = "file")
Virtual_Mark_Push :: struct {
	forward:    [4]f32,
	projection: [4]f32,
	view_model: [4]f32,
	depth:      u32,
	stencil:    u32,
	requests:   u32,
	phase:      u32,
	size:       [2]u32,
	reach:      f32,
	padding:    u32,
}

// Virtual_Allocate_Push matches Virtual_Allocate_Push in virtual_shadow_allocate.hlsl.
@(private = "file")
Virtual_Allocate_Push :: struct {
	requests:       u32,
	table:          u32,
	pages:          u32,
	scratch:        u32,
	stats:          u32,
	arguments:      u32,
	phase:          u32,
	now:            u32,
	invalidate:     u32,
	dropped:        u32,
	dropped_offset: u32,
	drops:          u32,
}

@(private = "file")
Mark_Phase :: enum u32 {
	Pixels,
	Volume,
}

// The allocation's phases, a dispatch each. Match ALLOCATE_* in virtual_shadow_allocate.hlsl.
@(private = "file")
Allocate_Phase :: enum u32 {
	Reset,
	Clear,
	Fit,
	Retire,
	Select,
	Collect,
	Assign,
	Clear_Pool,
}

// virtual_level_extent is a level's extent in meters, and virtual_level_texel a texel's.
virtual_level_extent :: proc(level: int) -> f64 {
	return f64(VIRTUAL_FIRST_EXTENT) * f64(u64(1) << uint(level))
}

virtual_level_texel :: proc(level: int) -> f64 {
	return virtual_level_extent(level) / VIRTUAL_SIZE
}

// virtual_footprint_level is the level whose texel is nearest a pixel's footprint at a distance from the camera, with
// the bias. Matches virtual_footprint_level in virtual_shadow.hlsli.
virtual_footprint_level :: proc(s: Virtual_Selection, distance: f32) -> int {
	level := math.floor(
		math.log2(max(distance * s.pixel_angle / s.first_texel, 1e-6)) + s.bias + 0.5,
	)
	return int(clamp(level, 0, f32(s.levels - 1)))
}

// virtual_level_reach is the farthest distance from the camera that picks a level, or +inf for the last, which takes
// every farther point too.
virtual_level_reach :: proc(s: Virtual_Selection, level: int) -> f32 {
	if level >= s.levels - 1 {
		return math.inf_f32(1)
	}
	return s.first_texel / s.pixel_angle * math.pow(f32(2), f32(level) + 0.5 - s.bias)
}

// virtual_grid_anchor is the world position that the levels' grids and depth anchors are measured from: the cache's
// while the camera is within VIRTUAL_ANCHOR_REACH of it on every axis, or else the camera's. Measured from the world's
// origin, level 0's page index would pass 32 bits past 268,000 km, and the sample's playground is at 1.5e11 m. A new
// anchor moves every page, so the cache starts again.
virtual_grid_anchor :: proc(cache: Maybe(Virtual_Cache), camera: ecs.World_Position) -> ecs.World_Position {
	if previous, ok := cache.?; ok {
		d := ecs.position_sub_f64(camera, previous.anchor)
		if max(abs(d.x), abs(d.y), abs(d.z)) < VIRTUAL_ANCHOR_REACH {
			return previous.anchor
		}
	}
	return camera
}

// light_dot is a position in meters from the levels' anchor along one of the light's axes.
@(private = "file")
light_dot :: proc(p: [3]f64, axis: [3]f32) -> f64 {
	return p.x * f64(axis.x) + p.y * f64(axis.y) + p.z * f64(axis.z)
}

// virtual_camera_depth is the camera's position along the light, in meters from the levels' anchor.
virtual_camera_depth :: proc(c: Virtual_Camera, direction: [3]f32) -> f64 {
	return light_dot(c.position, direction)
}

// virtual_depth_anchor is where a level's range of depth is centered along the light, in meters from the levels'
// anchor: the previous anchor while the camera is within the level's extent of it, or else the page nearest the
// camera. A page's depths hold only while its level's anchor stays, so a level's pages are dropped when it moves. The
// range is VIRTUAL_DEPTH_RANGE times the extent on each side, so it holds the level's extent around the camera; were the
// anchor to follow the camera by pages, as the grid across the light does, level 0's pages would last only 12.5 cm of
// the camera's movement toward the light.
virtual_depth_anchor :: proc(camera_depth: f64, level: int, previous: Maybe(f64) = nil) -> f64 {
	extent := virtual_level_extent(level)
	if anchor, ok := previous.?; ok && abs(camera_depth - anchor) <= extent {
		return anchor
	}
	page := extent / VIRTUAL_PAGES
	return math.round(camera_depth / page) * page
}

// virtual_level is a level for a light's direction, with its depth centered on anchor, or by default on the page nearest
// the camera. Its grid is of whole pages in the world's space, so a page stays at the same texels as the camera moves
// and as the render origin rebases, and each level's grid is on every second line of the one before's, so each page has
// one parent. The level's valid rectangle holds the view's frustum out to the level's reach, in pages: a level's pixels
// are all in there, and a level's depth pass rasterizes only there, so its cost follows the screen. Depth is 1 at the
// light's end of the level's range, and 0 at the other, as the cascades have it.
virtual_level :: proc(c: Virtual_Camera, direction: [3]f32, level: int, anchor: Maybe(f64) = nil) -> (l: Virtual_Level) {
	light_right, light_up := light_basis(direction)
	extent := virtual_level_extent(level)
	page := extent / VIRTUAL_PAGES
	half := extent * 0.5
	// In the light's axes. A page's v grows away from up, as a texture's does.
	camera_u := light_dot(c.position, light_right)
	camera_v := -light_dot(c.position, light_up)
	camera_d := light_dot(c.position, direction)
	origin := [2]i32 {
		i32(math.floor(camera_u / page)) - VIRTUAL_PAGES / 2,
		i32(math.floor(camera_v / page)) - VIRTUAL_PAGES / 2,
	}
	// The level's middle, relative to the camera.
	center_u := (f64(origin.x) + VIRTUAL_PAGES / 2) * page - camera_u
	center_v := (f64(origin.y) + VIRTUAL_PAGES / 2) * page - camera_v
	center_d := (anchor.? or_else virtual_depth_anchor(camera_d, level)) - camera_d

	// A point in the level is at most its half extent times sqrt(2) from the camera across the light, and its range
	// along the light is more than that, wherever the anchor is.
	depth_half := extent * VIRTUAL_DEPTH_RANGE
	h := f32(half)
	x, y := f32(center_u), -f32(center_v)
	r := f32(depth_half)
	d := f32(center_d)
	l.projection = matrix[4, 4]f32{
		light_right.x / h, light_right.y / h, light_right.z / h, -x / h,
		light_up.x / h, light_up.y / h, light_up.z / h, -y / h,
		-direction.x / (2 * r), -direction.y / (2 * r), -direction.z / (2 * r), (r + d) / (2 * r),
		0, 0, 0, 1,
	}

	// The pages of the frustum out to the reach, and of the view model around the camera.
	uv_of :: proc(p, right, up: [3]f32, center_u, center_v, extent: f64) -> [2]f64 {
		return {
			0.5 + (f64(linalg.dot(p, right)) - center_u) / extent,
			0.5 + (-f64(linalg.dot(p, up)) - center_v) / extent,
		}
	}
	low := [2]f64{math.F64_MAX, math.F64_MAX}
	high := [2]f64{-math.F64_MAX, -math.F64_MAX}
	include :: proc(low, high: ^[2]f64, uv: [2]f64) {
		low^ = {min(low.x, uv.x), min(low.y, uv.y)}
		high^ = {max(high.x, uv.x), max(high.y, uv.y)}
	}
	far := min(virtual_level_reach(c.selection, level), f32(extent) * 2)
	for z in ([2]f32{c.near, far}) {
		for k in 0 ..< 4 {
			px := (k & 1 != 0 ? 1 : -1) * z / c.scale.x
			py := (k & 2 != 0 ? 1 : -1) * z / c.scale.y
			include(
				&low,
				&high,
				uv_of(
					c.right * px + c.up * py + c.forward * z,
					light_right,
					light_up,
					center_u,
					center_v,
					extent,
				),
			)
		}
	}
	around := f64(VIRTUAL_VIEW_MODEL_REACH) / extent
	middle := uv_of({}, light_right, light_up, center_u, center_v, extent)
	include(&low, &high, middle - around)
	include(&low, &high, middle + around)
	page_low := [2]i32 {
		clamp(i32(math.floor(low.x * VIRTUAL_PAGES)) - 1, 0, VIRTUAL_PAGES),
		clamp(i32(math.floor(low.y * VIRTUAL_PAGES)) - 1, 0, VIRTUAL_PAGES),
	}
	page_high := [2]i32 {
		clamp(i32(math.ceil(high.x * VIRTUAL_PAGES)) + 1, 0, VIRTUAL_PAGES),
		clamp(i32(math.ceil(high.y * VIRTUAL_PAGES)) + 1, 0, VIRTUAL_PAGES),
	}

	l.view = Shadow_View {
		rows        = matrix_rows(l.projection),
		rect        = {
			f32(page_low.x) / VIRTUAL_PAGES,
			f32(page_low.y) / VIRTUAL_PAGES,
			f32(page_high.x) / VIRTUAL_PAGES,
			f32(page_high.y) / VIRTUAL_PAGES,
		},
		texel       = f32(virtual_level_texel(level)),
		page_origin = origin,
	}
	l.scissor = {
		u32(page_low.x) * VIRTUAL_PAGE_TEXELS,
		u32(page_low.y) * VIRTUAL_PAGE_TEXELS,
		u32(page_high.x - page_low.x) * VIRTUAL_PAGE_TEXELS,
		u32(page_high.y - page_low.y) * VIRTUAL_PAGE_TEXELS,
	}

	// The culling's bounds are the valid rectangle's, and as for the cascades, no plane culls casters toward the light.
	min_u := center_u + (f64(page_low.x) / VIRTUAL_PAGES - 0.5) * extent
	max_u := center_u + (f64(page_high.x) / VIRTUAL_PAGES - 0.5) * extent
	min_v := center_v + (f64(page_low.y) / VIRTUAL_PAGES - 0.5) * extent
	max_v := center_v + (f64(page_high.y) / VIRTUAL_PAGES - 0.5) * extent
	l.planes = frustum_planes_6(l.projection)
	l.planes[0] = {light_right.x, light_right.y, light_right.z, f32(-min_u)}
	l.planes[1] = {-light_right.x, -light_right.y, -light_right.z, f32(max_u)}
	l.planes[2] = {light_up.x, light_up.y, light_up.z, f32(max_v)}
	l.planes[3] = {-light_up.x, -light_up.y, -light_up.z, f32(-min_v)}
	l.planes[4] = {0, 0, 0, 1}
	return
}

// virtual_project is a point's position in a level: its virtual texel, and its depth. Matches virtual_project in
// virtual_shadow.hlsli.
virtual_project :: proc(view: Shadow_View, p: [3]f32) -> (texel: [2]f32, z: f32) {
	v := [4]f32{p.x, p.y, p.z, 1}
	ndc := [2]f32{linalg.dot(view.rows[0], v), linalg.dot(view.rows[1], v)}
	texel = {(ndc.x * 0.5 + 0.5) * VIRTUAL_SIZE, (ndc.y * -0.5 + 0.5) * VIRTUAL_SIZE}
	z = linalg.dot(view.rows[2], v)
	return
}

// virtual_block is the first texel and the size of the block that a lookup reads at a texel. Matches virtual_block in
// virtual_shadow.hlsli.
virtual_block :: proc(texel: [2]f32, filter: Shadow_Filter) -> (base: [2]i32, size: i32) {
	switch filter {
	case .Taps_4:
		return {i32(math.floor(texel.x)) - 1, i32(math.floor(texel.y)) - 1}, 3
	case .Taps_9:
		return {i32(math.floor(texel.x - 0.5)) - 1, i32(math.floor(texel.y - 0.5)) - 1}, 4
	case .Taps_1:
	}
	return {i32(math.floor(texel.x - 0.5)), i32(math.floor(texel.y - 0.5))}, 2
}

// virtual_in_rect is whether texels from low to high are in a level's valid rectangle. Matches virtual_in_rect in
// virtual_shadow.hlsli.
virtual_in_rect :: proc(view: Shadow_View, low, high: [2]i32) -> bool {
	lower := view.rect.xy * VIRTUAL_SIZE
	upper := view.rect.zw * VIRTUAL_SIZE
	return(
		f32(low.x) >= lower.x &&
		f32(low.y) >= lower.y &&
		f32(high.x) < upper.x &&
		f32(high.y) < upper.y \
	)
}

// page_index is a level's page's bit in the requests, by its place in the level.
@(private = "file")
page_index :: proc(level: int, page: [2]i32) -> int {
	return level * VIRTUAL_LEVEL_PAGES + int(page.y) * VIRTUAL_PAGES + int(page.x)
}

// virtual_table_slot is an absolute page's entry in its level's table, which is toroidal. Matches virtual_table_slot in
// virtual_pages.hlsli.
virtual_table_slot :: proc(level: int, page: [2]i32) -> int {
	return level * VIRTUAL_LEVEL_PAGES + int(page.y & (VIRTUAL_PAGES - 1)) * VIRTUAL_PAGES + int(page.x & (VIRTUAL_PAGES - 1))
}

// virtual_entry_page is a table entry's physical page, or VIRTUAL_NO_PAGE.
virtual_entry_page :: proc(entry: u32) -> u32 {
	return entry == VIRTUAL_NO_PAGE ? VIRTUAL_NO_PAGE : entry & ~VIRTUAL_DRAW
}

// virtual_entry_draws is whether a table entry's page draws this frame.
virtual_entry_draws :: proc(entry: u32) -> bool {
	return entry != VIRTUAL_NO_PAGE && entry & VIRTUAL_DRAW != 0
}

// virtual_mark marks a lookup's pages in a level's bits, and reach meters around them for the soft shadows' rays, for a
// point at the first level from level on whose valid rectangle holds its block, and returns that level, or -1. Matches
// mark in virtual_shadow_mark.hlsl.
virtual_mark :: proc(
	requests: []u32,
	views: []Shadow_View,
	filter: Shadow_Filter,
	p: [3]f32,
	level: int,
	reach: f32 = 0,
) -> int {
	for l in level ..< len(views) {
		texel, _ := virtual_project(views[l], p)
		base, size := virtual_block(texel, filter)
		low := base - VIRTUAL_MARK_MARGIN
		high := base + size - 1 + VIRTUAL_MARK_MARGIN
		if !virtual_in_rect(views[l], low, high) {
			continue
		}
		// The soft shadows' rays read as far around the block as reach, within the valid rectangle.
		texels := i32(math.ceil(reach / views[l].texel))
		lower := [2]i32{i32(views[l].rect.x * VIRTUAL_SIZE), i32(views[l].rect.y * VIRTUAL_SIZE)}
		upper := [2]i32{i32(views[l].rect.z * VIRTUAL_SIZE), i32(views[l].rect.w * VIRTUAL_SIZE)} - 1
		low = {max(low.x - texels, lower.x), max(low.y - texels, lower.y)}
		high = {min(high.x + texels, upper.x), min(high.y + texels, upper.y)}
		for y in low.y / VIRTUAL_PAGE_TEXELS ..= high.y / VIRTUAL_PAGE_TEXELS {
			for x in low.x / VIRTUAL_PAGE_TEXELS ..= high.x / VIRTUAL_PAGE_TEXELS {
				index := page_index(l, {x, y})
				requests[index >> 5] |= 1 << uint(index & 31)
			}
		}
		return l
	}
	return -1
}

// virtual_parent_page is a level's page's parent in the next coarser level, whose grid is on every second line of the
// level's. Matches fit_pool in virtual_shadow_allocate.hlsl.
virtual_parent_page :: proc(origin, page, parent_origin: [2]i32) -> [2]i32 {
	return {(origin.x + page.x) >> 1 - parent_origin.x, (origin.y + page.y) >> 1 - parent_origin.y}
}

// virtual_rect_draws is whether pages from low to high, by their places in a level whose first page is origin, have a
// page that the frame draws. A sphere over more than VIRTUAL_CULL_PAGES pages on a side counts as reaching one if the
// level draws any. Matches virtual_rect_draws in virtual_pages.hlsli.
virtual_rect_draws :: proc(table: []u32, level: int, origin, low, high: [2]i32) -> bool {
	first := [2]i32{max(low.x, 0), max(low.y, 0)}
	last := [2]i32{min(high.x, VIRTUAL_PAGES - 1), min(high.y, VIRTUAL_PAGES - 1)}
	if first.x > last.x || first.y > last.y {
		return false
	}
	if last.x - first.x >= VIRTUAL_CULL_PAGES || last.y - first.y >= VIRTUAL_CULL_PAGES {
		return table[VIRTUAL_TABLE_COUNTS + level] > 0
	}
	for y in first.y ..= last.y {
		for x in first.x ..= last.x {
			if virtual_entry_draws(table[virtual_table_slot(level, origin + {x, y})]) {
				return true
			}
		}
	}
	return false
}

// virtual_page_fields is what a level's Cull_View holds for virtual_reaches_draws: the level, its valid rectangle's
// first page, which the view's left and bottom planes are at, and its origin modulo the table's wrap. The level takes
// 4 bits and the rest 7 each: the first page is at most the middle page, since the rectangle holds the camera.
virtual_page_fields :: proc(view: Shadow_View, level: int) -> u32 {
	x := min(u32(math.round(view.rect.x * VIRTUAL_PAGES)), VIRTUAL_PAGES - 1)
	y := min(u32(math.round(view.rect.y * VIRTUAL_PAGES)), VIRTUAL_PAGES - 1)
	origin := [2]u32{u32(view.page_origin.x & (VIRTUAL_PAGES - 1)), u32(view.page_origin.y & (VIRTUAL_PAGES - 1))}
	return u32(level) | x << 4 | y << 11 | origin.x << 18 | origin.y << 25
}

// virtual_reaches_draws is whether a sphere relative to the camera reaches a page that a level draws, from its culling
// planes and its page fields. Matches virtual_view_reaches_draws in virtual_pages.hlsli.
virtual_reaches_draws :: proc(table: []u32, planes: [6][4]f32, fields: u32, center: [3]f32, radius: f32) -> bool {
	level := int(fields & 0xf)
	page := f32(virtual_level_extent(level)) / VIRTUAL_PAGES
	at := [2]f32{linalg.dot(planes[0].xyz, center) + planes[0].w, linalg.dot(planes[3].xyz, center) + planes[3].w} / page
	reach := radius / page + 1.0 / VIRTUAL_PAGE_TEXELS
	first := [2]i32{i32((fields >> 4) & 0x7f), i32((fields >> 11) & 0x7f)}
	origin := [2]i32{i32((fields >> 18) & 0x7f), i32((fields >> 25) & 0x7f)}
	low := first + [2]i32{i32(math.floor(at.x - reach)), i32(math.floor(at.y - reach))}
	high := first + [2]i32{i32(math.floor(at.x + reach)), i32(math.floor(at.y + reach))}
	return virtual_rect_draws(table, level, origin, low, high)
}

// virtual_fit_pool makes the marks fit the pool, if they do not: finest level first, it moves a page's mark to its parent
// in the next coarser level, one page at a time, until they fit. Marks that fit move nothing, so no level draws pages that
// nothing reads. It returns how many pages the frame asked for, how many moved, and how many marks are left. Matches
// fit_pool in virtual_shadow_allocate.hlsl.
virtual_fit_pool :: proc(requests: []u32, views: []Shadow_View, capacity: u32) -> (requested, moved, total: u32) {
	for word in requests[:len(views) * VIRTUAL_LEVEL_WORDS] {
		requested += u32(bits.count_ones(word))
	}
	total = requested
	for level in 0 ..< len(views) - 1 {
		origin, parent_origin := views[level].page_origin, views[level + 1].page_origin
		for word in 0 ..< VIRTUAL_LEVEL_WORDS {
			if total <= capacity {
				return
			}
			at := level * VIRTUAL_LEVEL_WORDS + word
			pending := requests[at]
			for pending != 0 && total > capacity {
				index := word * 32 + int(bits.count_trailing_zeros(pending))
				pending &= pending - 1
				requests[at] = pending
				total -= 1
				moved += 1
				page := [2]i32{i32(index % VIRTUAL_PAGES), i32(index / VIRTUAL_PAGES)}
				parent := virtual_parent_page(origin, page, parent_origin)
				if parent.x >= 0 && parent.y >= 0 && parent.x < VIRTUAL_PAGES && parent.y < VIRTUAL_PAGES {
					parent_index := page_index(level + 1, parent)
					mask := u32(1) << uint(parent_index & 31)
					if requests[parent_index >> 5] & mask == 0 {
						requests[parent_index >> 5] |= mask
						total += 1
					}
				}
			}
		}
	}
	return
}

// virtual_reset empties the table and the pages' records, as a frame does that keeps nothing. Matches ALLOCATE_RESET in
// virtual_shadow_allocate.hlsl.
virtual_reset :: proc(table: []u32, pages: []Virtual_Page) {
	for &entry in table[:VIRTUAL_TABLE_COUNTS] {
		entry = VIRTUAL_NO_PAGE
	}
	for &page in pages {
		page.level = VIRTUAL_FREE
	}
}

// Virtual_Retired is what virtual_retire counts: the pages that the frame asked for and the pool holds, the pages that
// the pool holds once those that are no longer valid leave, and the others' ages.
Virtual_Retired :: struct {
	hits:      u32,
	valid:     u32,
	histogram: [VIRTUAL_AGE_BINS]u32,
}

// virtual_retire goes over the pool's pages, as a thread each does on the GPU. A page leaves when its level is one that
// the frame drops, is past the frame's levels, no longer holds its page since the level's origin moved, or is one that
// dropped has, under a caster that changed (see virtual_drop_pages). A page that
// stays takes its entry again without VIRTUAL_DRAW. A page that the frame asks for is a hit: the frame keeps it and does
// not ask for it again, and its age starts over. Every other page's age goes into the histogram. Matches retire in
// virtual_shadow_allocate.hlsl.
virtual_retire :: proc(
	requests, table: []u32,
	pages: []Virtual_Page,
	views: []Shadow_View,
	now, invalidate: u32,
	dropped: []u32 = nil,
) -> (
	r: Virtual_Retired,
) {
	for &page, p in pages {
		if page.level == VIRTUAL_FREE {
			continue
		}
		level := int(page.level)
		slot := virtual_table_slot(level, page.page)
		local: [2]i32
		keep := level < len(views) && invalidate & (1 << uint(level)) == 0
		if keep {
			local = page.page - views[level].page_origin
			keep = local.x >= 0 && local.y >= 0 && local.x < VIRTUAL_PAGES && local.y < VIRTUAL_PAGES
		}
		if keep && dropped != nil {
			at := page_index(level, local)
			keep = dropped[at >> 5] & (u32(1) << uint(at & 31)) == 0
		}
		if !keep {
			table[slot] = VIRTUAL_NO_PAGE
			page.level = VIRTUAL_FREE
			continue
		}
		table[slot] = u32(p)
		r.valid += 1
		index := page_index(level, local)
		mask := u32(1) << uint(index & 31)
		if requests[index >> 5] & mask != 0 {
			requests[index >> 5] &~= mask
			page.last = now
			r.hits += 1
		} else {
			r.histogram[min(now - page.last, VIRTUAL_AGE_BINS - 1)] += 1
		}
	}
	return
}

// virtual_select finds which pages leave for the frame's new pages when the pool's free pages are too few: the oldest
// first, by the histogram from its oldest bin. Every page in a bin older than threshold leaves, and quota of those in
// threshold's. With no page to leave, threshold is past the last bin. Matches select_evictions in
// virtual_shadow_allocate.hlsl.
virtual_select :: proc(histogram: []u32, fresh, free: u32) -> (threshold, quota: u32) {
	need := fresh > free ? fresh - free : 0
	threshold = VIRTUAL_AGE_BINS
	for bin := VIRTUAL_AGE_BINS - 1; bin >= 0 && need > 0; bin -= 1 {
		threshold = u32(bin)
		if histogram[bin] >= need {
			quota = need
			need = 0
		} else {
			quota = histogram[bin]
			need -= histogram[bin]
		}
	}
	return
}

// virtual_collect lists the pages that the frame may give out: the free pages, and those that virtual_select chose to
// leave, which leave the table. A page that the frame asked for has its age 0 and never leaves. Matches collect in
// virtual_shadow_allocate.hlsl, whose threads list the pages in any order.
virtual_collect :: proc(
	table: []u32,
	pages: []Virtual_Page,
	now, threshold, quota: u32,
	allocator := context.temp_allocator,
) -> (
	available: [dynamic]u32,
	evicted: u32,
) {
	available = make([dynamic]u32, allocator)
	taken: u32
	for &page, p in pages {
		if page.level != VIRTUAL_FREE {
			if page.last == now {
				continue
			}
			bin := min(now - page.last, VIRTUAL_AGE_BINS - 1)
			take := bin > threshold
			if !take && bin == threshold {
				take = taken < quota
				taken += 1
			}
			if !take {
				continue
			}
			table[virtual_table_slot(int(page.level), page.page)] = VIRTUAL_NO_PAGE
			page.level = VIRTUAL_FREE
			evicted += 1
		}
		append(&available, u32(p))
	}
	return
}

// virtual_assign gives each page that the frame asks for and the pool does not hold the next page of the list, coarsest
// level first, so the finest go without when the list runs out, and marks it to draw. It returns how many it gave and
// how many went without, and counts each level's in the table. Matches assign in virtual_shadow_allocate.hlsl.
virtual_assign :: proc(
	requests, table: []u32,
	pages: []Virtual_Page,
	views: []Shadow_View,
	available: []u32,
	now: u32,
) -> (
	drawn, missed: u32,
) {
	for level := len(views) - 1; level >= 0; level -= 1 {
		count: u32
		for word in 0 ..< VIRTUAL_LEVEL_WORDS {
			pending := requests[level * VIRTUAL_LEVEL_WORDS + word]
			for pending != 0 {
				index := word * 32 + int(bits.count_trailing_zeros(pending))
				pending &= pending - 1
				if int(drawn) >= len(available) {
					missed += 1
					continue
				}
				p := available[drawn]
				drawn += 1
				count += 1
				page := views[level].page_origin + {i32(index % VIRTUAL_PAGES), i32(index / VIRTUAL_PAGES)}
				table[virtual_table_slot(level, page)] = p | VIRTUAL_DRAW
				pages[p] = {u32(level), page, now}
			}
		}
		table[VIRTUAL_TABLE_COUNTS + level] = count
	}
	return
}

// virtual_allocate runs a frame's allocation as its passes do, in order, and returns its stats: the drawn counts start at
// 0, the marks fit the pool, the pages that stay keep their entries and the hits their pages, the oldest pages leave for
// the new ones, and the new pages are given out. The pool's size is the records'. With reset, the table and the records
// start empty, as in a frame that keeps nothing. The table holds VIRTUAL_TABLE_WORDS.
virtual_allocate :: proc(
	requests, table: []u32,
	pages: []Virtual_Page,
	views: []Shadow_View,
	now: u32 = 1,
	invalidate: u32 = 0,
	reset := false,
	dropped: []u32 = nil,
) -> (
	stats: Virtual_Shadow_Stats,
) {
	if reset {
		virtual_reset(table, pages)
	}
	for &count in table[VIRTUAL_TABLE_COUNTS:] {
		count = 0
	}
	capacity := u32(len(pages))
	requested, moved, total := virtual_fit_pool(requests, views, capacity)
	retired := virtual_retire(requests, table, pages, views, now, invalidate, dropped)
	threshold, quota := virtual_select(retired.histogram[:], total - retired.hits, capacity - retired.valid)
	available, evicted := virtual_collect(table, pages, now, threshold, quota)
	drawn, missed := virtual_assign(requests, table, pages, views, available[:], now)
	return {
		requested = requested,
		allocated = retired.hits + drawn,
		missed = moved + missed,
		capacity = capacity,
		cached = retired.hits,
		drawn = drawn,
		evicted = evicted,
		resident = retired.valid - evicted + drawn,
	}
}

// virtual_drop_pages sets the bits of each level's pages that a sphere relative to the camera covers, with a texel's
// margin, as the requests are laid out: the pages that its caster's depth may be in, which the frame drops. dropped
// holds VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS words.
virtual_drop_pages :: proc(views: []Shadow_View, spheres: [][4]f32, dropped: []u32) {
	for view, level in views {
		texel_size := f32(virtual_level_texel(level))
		for s in spheres {
			texel, _ := virtual_project(view, s.xyz)
			reach := s.w / texel_size + 1
			low := [2]i32{i32(math.floor((texel.x - reach) / VIRTUAL_PAGE_TEXELS)), i32(math.floor((texel.y - reach) / VIRTUAL_PAGE_TEXELS))}
			high := [2]i32{i32(math.floor((texel.x + reach) / VIRTUAL_PAGE_TEXELS)), i32(math.floor((texel.y + reach) / VIRTUAL_PAGE_TEXELS))}
			if high.x < 0 || high.y < 0 || low.x >= VIRTUAL_PAGES || low.y >= VIRTUAL_PAGES {
				continue
			}
			low, high = linalg.max(low, 0), linalg.min(high, VIRTUAL_PAGES - 1)
			for y in low.y ..= high.y {
				first := page_index(level, {low.x, y})
				last := page_index(level, {high.x, y})
				for at := first; at <= last; {
					// A word at a time where the run covers it.
					if at & 31 == 0 && last - at >= 31 {
						dropped[at >> 5] = max(u32)
						at += 32
						continue
					}
					dropped[at >> 5] |= u32(1) << uint(at & 31)
					at += 1
				}
			}
		}
	}
}

// virtual_drop_spheres are the spheres, relative to the camera, whose pages a view's virtual shadow map drops: both
// places of each change of casters that it takes, and every slot that it draws live, whose shadow changes each frame.
// The live slots without bounds, mesh particles, drop none.
@(private)
virtual_drop_spheres :: proc(
	t: ^Caster_Tracking,
	changes: []Caster_Change,
	live: ^Live_Slots,
	high: u32,
	camera: ecs.World_Position,
	allocator := context.allocator,
) -> [][4]f32 {
	spheres := make([dynamic][4]f32, allocator)
	add :: proc(spheres: ^[dynamic][4]f32, s: Caster_Sphere, camera: ecs.World_Position) {
		c := ecs.position_sub(s.center, camera)
		append(spheres, [4]f32{c.x, c.y, c.z, s.radius})
	}
	for change in changes {
		if s, has := change.old.?; has {
			add(&spheres, s, camera)
		}
		if s, has := change.new.?; has {
			add(&spheres, s, camera)
		}
	}
	for c, slot in t.slots[:high] {
		if slot_live(live, u32(slot)) && !c.unbounded {
			add(&spheres, c.sphere, camera)
		}
	}
	return spheres[:]
}

// virtual_lookup is the finest level from level on that has the page that holds the point, or -1. A mark that does not fit
// the pool moves to its page's parent, so a marked point finds one unless the pool has no room for the coarsest level's.
// Matches virtual_find in virtual_shadow.hlsli.
virtual_lookup :: proc(table: []u32, views: []Shadow_View, p: [3]f32, level: int) -> int {
	for l in level ..< len(views) {
		texel, _ := virtual_project(views[l], p)
		at := [2]i32{i32(math.floor(texel.x)), i32(math.floor(texel.y))}
		if virtual_in_rect(views[l], at, at) &&
		   table[virtual_table_slot(l, views[l].page_origin + at / VIRTUAL_PAGE_TEXELS)] != VIRTUAL_NO_PAGE {
			return l
		}
	}
	return -1
}

// virtual_lookup_level is the first level that a point's lookup tries: one finer than its footprint's. Matches virtual_find
// in virtual_shadow.hlsli.
virtual_lookup_level :: proc(s: Virtual_Selection, distance: f32) -> int {
	return max(virtual_footprint_level(s, distance) - 1, 0)
}

// virtual_shadow_stats is the frame's own view's virtual shadow map's pages, a frame or two ago, all 0 after a frame
// without it.
virtual_shadow_stats :: proc(r: ^Renderer) -> Virtual_Shadow_Stats {
	return stats_state(r).virtual_shadows.last_stats
}

@(private)
virtual_shadows_init :: proc(v: ^Virtual_Shadows) {
	v.mark_pipeline = shader_pipeline(VIRTUAL_MARK_SHADER)
	v.allocate_pipeline = shader_pipeline(VIRTUAL_ALLOCATE_SHADER)
}

@(private)
virtual_shadows_destroy :: proc(v: ^Virtual_Shadows, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&v.mark_pipeline, platform)
	destroy_shader_pipeline(&v.allocate_pipeline, platform)
	platform.gpu_destroy_buffer(v.requests)
	platform.gpu_destroy_buffer(v.scratch)
	platform.gpu_destroy_buffer(v.arguments)
	v^ = {}
}

// virtual_state_destroy frees a view's virtual shadow map.
@(private)
virtual_state_destroy :: proc(v: ^Virtual_State, platform: ^core.Platform_API) {
	platform.gpu_destroy_buffer(v.stats)
	destroy_readback_ring(&v.stats_ring, platform)
	platform.gpu_destroy_texture(v.pool)
	platform.gpu_destroy_buffer(v.table)
	platform.gpu_destroy_buffer(v.pages)
	v^ = {}
}

// read_virtual_stats keeps the newest stats' copy that has come back. After a frame without the virtual shadow map, or
// one that did not execute, the stats are empty.
@(private)
read_virtual_stats :: proc(r: ^Renderer, view: ^View_State) {
	v := &view.virtual_shadows
	data, take := take_readback(&v.stats_ring, r.platform, size_of(Virtual_Shadow_Stats))
	switch take {
	case .Fresh:
		v.last_stats = (^Virtual_Shadow_Stats)(raw_data(data))^
	case .Idle:
		v.last_stats = {}
	case .Waiting:
	}
}

// ensure_virtual_shadows syncs the virtual shadow map's pipelines and creates what the level's parameters need, and says
// whether this frame can use it: until they compile, the frame draws the cascades. The pool changes with the quality.
@(private)
ensure_virtual_shadows :: proc(r: ^Renderer, s: ^Virtual_State, p: Shadow_Params) -> bool {
	v := &r.shadows.virtual
	platform := r.platform
	sync_compute_pipeline(
		&v.mark_pipeline,
		platform,
		r.residency.assets,
		{label = "virtual shadow mark"},
		r.reloaded,
	)
	sync_compute_pipeline(
		&v.allocate_pipeline,
		platform,
		r.residency.assets,
		{label = "virtual shadow allocate"},
		r.reloaded,
	)
	if v.mark_pipeline.pipeline == {} || v.allocate_pipeline.pipeline == {} {
		return false
	}
	if v.requests == {} {
		v.requests = platform.gpu_create_buffer(
			{
				size = VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS * 4,
				usage = {.Storage},
				label = "virtual shadow requests",
			},
			nil,
		)
		v.scratch = platform.gpu_create_buffer(
			{
				size = VIRTUAL_SCRATCH_WORDS * 4,
				usage = {.Storage},
				label = "virtual shadow scratch",
			},
			nil,
		)
		v.arguments = platform.gpu_create_buffer(
			{
				size = size_of(gpu.Dispatch_Indirect_Args),
				usage = {.Storage, .Indirect},
				label = "virtual shadow clear arguments",
			},
			nil,
		)
	}
	if s.stats == {} {
		s.stats = platform.gpu_create_buffer(
			{
				size = size_of(Virtual_Shadow_Stats),
				usage = {.Storage},
				label = "virtual shadow stats",
			},
			nil,
		)
	}
	if !ensure_readback_ring(&s.stats_ring, platform, size_of(Virtual_Shadow_Stats), "virtual shadow stats readback") {
		return false
	}
	if s.table == {} {
		s.table = platform.gpu_create_buffer(
			{
				size = VIRTUAL_TABLE_WORDS * 4,
				usage = {.Storage},
				label = "virtual shadow table",
			},
			nil,
		)
		s.cache = nil
	}
	if s.pool_pages != p.pool_pages {
		platform.gpu_destroy_texture(s.pool)
		platform.gpu_destroy_buffer(s.pages)
		s.pool, s.pages, s.pool_pages = {}, {}, {}
		// A new pool's pages hold nothing, whatever the table says.
		s.cache = nil
		if p.pool_pages.x * p.pool_pages.y > VIRTUAL_MAX_POOL_PAGES {
			return false
		}
		s.pool = platform.gpu_create_texture(
			{
				size = p.pool_pages * VIRTUAL_PAGE_TEXELS,
				format = VIRTUAL_POOL_FORMAT,
				usage = {.Sampled, .Storage},
				label = "virtual shadow pool",
			},
			nil,
		)
		s.pages = platform.gpu_create_buffer(
			{
				size = p.pool_pages.x * p.pool_pages.y * size_of(Virtual_Page),
				usage = {.Storage},
				label = "virtual shadow pages",
			},
			nil,
		)
		s.pool_pages = p.pool_pages
	}
	return(
		v.requests != {} &&
		v.scratch != {} &&
		v.arguments != {} &&
		s.stats != {} &&
		s.table != {} &&
		s.pool != {} &&
		s.pages != {} 	)
}

// virtual_cache_plan is what a frame keeps of the cache, the one place that decides it. A frame starts the table and the
// records again (reset) without a cache, with the cache off, when it does not know every change of casters since the
// cache was drawn (tracked), or when the light's direction, the shadows' parameters or their quality's settings changed,
// or the levels' anchor moved: every page was drawn for those. Otherwise it keeps them, and drops the pages of the levels
// whose depth anchor moved (invalidate, a bit each). next is what the frame draws for, which its commit keeps, with the
// next epoch, which the pages that it asks for take.
virtual_cache_plan :: proc(
	cache: Maybe(Virtual_Cache),
	enabled: bool,
	anchor: ecs.World_Position,
	c: Virtual_Camera,
	direction: [3]f32,
	params: Shadow_Params,
	settings: Shadow_Settings,
	tracked := true,
	frame: u64 = 0,
) -> (
	next: Virtual_Cache,
	reset: bool,
	invalidate: u32,
) {
	// The cascades' distance and split, which a volume may blend from frame to frame, and the atlas's cache draw nothing
	// of the levels.
	settings := settings
	settings.distance, settings.split_lambda, settings.atlas_cache = 0, 0, false
	previous, kept := cache.?
	reset =
		!enabled ||
		!tracked ||
		!kept ||
		previous.anchor != anchor ||
		previous.direction != direction ||
		previous.params != params ||
		previous.settings != settings
	next = {
		anchor    = anchor,
		direction = direction,
		params    = params,
		settings  = settings,
		epoch     = kept ? previous.epoch + 1 : 1,
		frame     = frame,
	}
	depth := virtual_camera_depth(c, direction)
	for level in 0 ..< c.selection.levels {
		if reset {
			next.anchors[level] = virtual_depth_anchor(depth, level)
			continue
		}
		next.anchors[level] = virtual_depth_anchor(depth, level, previous.anchors[level])
		if next.anchors[level] != previous.anchors[level] {
			invalidate |= 1 << uint(level)
		}
	}
	return
}

// add_virtual_levels adds the levels of a directional light as the first shadow views, and plans what the frame keeps
// of the cache.
@(private)
add_virtual_levels :: proc(f: ^Frame, sf: ^Shadow_Frame, direction: [3]f32) {
	cache := f.state.virtual_shadows.cache
	anchor := virtual_grid_anchor(cache, f.view.position)
	c := virtual_camera(f, sf.params, anchor)
	vf := &sf.virtual
	vf.camera = c
	vf.count = c.selection.levels
	// The cache knows what changed since it drew only if it drew in the last scene frame, whose changes it took.
	s := &f.renderer.scene
	scene := f.scene_frame
	previous, kept := cache.?
	tracked := kept && scene != nil && scene.live != nil && s.casters.frame == s.frame && previous.frame + 1 == s.frame
	vf.cache, vf.reset, vf.invalidate = virtual_cache_plan(
		cache,
		f.shadow_settings.virtual_cache,
		anchor,
		c,
		direction,
		sf.params,
		f.shadow_settings,
		tracked,
		s.frame,
	)
	if scene != nil && scene.live != nil {
		vf.cache.live = scene.live^
	}
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level, vf.cache.anchors[level])
		append(&sf.matrices, l.projection)
		append(&sf.views, l.view)
		append(&sf.planes, l.planes)
		append(&sf.eyes, [4]f32{direction.x, direction.y, direction.z, 0})
		append(&sf.viewports, l.scissor)
	}
	// The pages under the casters that changed since the cache drew, and under the live ones, draw again.
	if vf.reset || !tracked {
		return
	}
	platform := f.renderer.platform
	changes := view_caster_changes(&s.casters, scene.live, &previous.live, platform.frame_allocator)
	spheres := virtual_drop_spheres(&s.casters, changes, scene.live, s.high, f.view.position, platform.frame_allocator)
	if len(spheres) == 0 {
		return
	}
	dropped := make([]u32, VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS, platform.frame_allocator)
	virtual_drop_pages(sf.views[len(sf.views) - c.selection.levels:], spheres, dropped)
	ok: bool
	vf.dropped, ok = upload_bytes(platform, slice.to_bytes(dropped))
	if !ok {
		// Without the drops, nothing that the cache holds is known to be right.
		vf.reset = true
		return
	}
	vf.drops = true
}

@(private = "file")
virtual_camera :: proc(f: ^Frame, p: Shadow_Params, anchor: ecs.World_Position) -> Virtual_Camera {
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	return {
		right = right,
		up = up,
		forward = forward,
		scale = scale,
		near = view_near(f.view),
		position = ecs.position_sub_f64(f.view.position, anchor),
		selection = {
			levels = p.virtual_levels,
			first_texel = f32(virtual_level_texel(0)),
			pixel_angle = 2 / (scale.y * f32(max(f.size.y, 1))),
			bias = p.virtual_bias,
		},
	}
}

// virtual_constants sets the virtual shadow map's fields of the views' constants.
@(private)
virtual_constants :: proc(c: ^Frame_Constants, f: ^Frame) {
	sf := f.shadows
	pool := &f.state.virtual_shadows
	s := sf.virtual.camera.selection
	c.virtual_levels = u32(s.levels)
	c.virtual_first_texel = s.first_texel
	c.virtual_pixel_angle = s.pixel_angle
	c.virtual_bias = s.bias
	c.virtual_pool = gpu.read_index(pool.pool)
	c.virtual_pool_storage = gpu.write_index(pool.pool)
	c.virtual_table = gpu.read_index(pool.table)
	c.virtual_pool_pages_per_row = pool.pool_pages.x
	c.virtual_pool_pages = pool.pool_pages.x * pool.pool_pages.y
}

// declare_virtual_shadows declares that a pass reads the virtual shadow map, if the frame has it.
@(private)
declare_virtual_shadows :: proc(f: ^Frame, p: Pass) {
	sf := f.shadows
	if sf.virtual.count > 0 {
		read(f.graph, p, sf.virtual.pool)
		read(f.graph, p, sf.virtual.table)
	}
}

// add_virtual_shadow_passes adds the virtual shadow map's passes: clearing the requests and the scratch, and the table
// and the pages' records when the frame keeps nothing; marking from the prepass's depth; the allocation's phases, a pass
// each, so the graph puts its barriers between them; clearing the pages that draw, and drawing each level. Its commit
// keeps what the frame drew for once the frame has run.
@(private)
add_virtual_shadow_passes :: proc(f: ^Frame) {
	r := f.renderer
	v := &r.shadows.virtual
	state := &f.state.virtual_shadows
	sf := f.shadows
	vf := &sf.virtual
	g := f.graph
	vf.pool = import_texture(g, state.pool, .Storage)
	vf.requests = import_buffer(g, v.requests)
	vf.table = import_buffer(g, state.table)
	vf.pages = import_buffer(g, state.pages)
	vf.scratch = import_buffer(g, v.scratch)
	vf.arguments = import_buffer(g, v.arguments)
	vf.stats = import_buffer(g, state.stats)

	p := add_compute_pass(g, "virtual shadow clear", run_virtual_clear, f)
	write(g, p, vf.requests)
	write(g, p, vf.scratch)
	write(g, p, vf.table)
	write(g, p, vf.pages)

	p = add_compute_pass(g, "virtual shadow mark", run_virtual_mark, f)
	read(g, p, f.depth)
	write(g, p, vf.requests)

	// The allocation's phases. Each writes the scratch, which orders them.
	phases := [?]struct {
		name:  string,
		phase: Allocate_Phase,
	} {
		{"virtual shadow fit", .Fit},
		{"virtual shadow retire", .Retire},
		{"virtual shadow select", .Select},
		{"virtual shadow collect", .Collect},
		{"virtual shadow assign", .Assign},
	}
	for phase in phases {
		p = add_compute_pass(g, phase.name, allocate_phase_proc(phase.phase), f)
		write(g, p, vf.requests)
		write(g, p, vf.scratch)
		write(g, p, vf.table)
		write(g, p, vf.pages)
		if phase.phase == .Assign {
			write(g, p, vf.arguments)
			write(g, p, vf.stats)
		}
	}

	p = add_compute_pass(g, "virtual shadow pages clear", run_virtual_pool_clear, f)
	indirect_buffer(g, p, vf.arguments)
	read(g, p, vf.scratch)
	write(g, p, vf.pool)

	add_virtual_culling(f)

	p = add_render_pass(g, "virtual shadow maps", draw_virtual_shadow_maps, f, pieces = vf.count)
	rasterize_size(g, p, {VIRTUAL_SIZE, VIRTUAL_SIZE})
	read(g, p, vf.table)
	write(g, p, vf.pool)
	declare_scene_draws(f, p)

	// The stats' copy, for read_virtual_stats to take once it is back.
	add_readback_copy(g, f.renderer.platform, &state.stats_ring, vf.stats, size_of(Virtual_Shadow_Stats), "virtual shadow stats")
	on_executed(g, commit_virtual_cache, f)
}

// commit_virtual_cache keeps what a frame that executed drew its pages for, which the next frame's plan compares with.
// A frame without the virtual shadow map forgets it (see forget_virtual_cache).
@(private = "file")
commit_virtual_cache :: proc(data: rawptr) {
	f := (^Frame)(data)
	f.state.virtual_shadows.cache = f.shadows.virtual.cache
}

// forget_virtual_cache drops the cache of a view whose frame executed without the virtual shadow map: what moved in the
// meantime is not known.
@(private)
forget_virtual_cache :: proc(f: ^Frame) {
	if f.state.virtual_shadows.cache == nil {
		return
	}
	on_executed(f.graph, proc(data: rawptr) {
		(^Frame)(data).state.virtual_shadows.cache = nil
	}, f)
}

// add_virtual_culling adds the culling of the levels' views, which the page table has to be written for: their instance
// sets' lists, then their draws. Only an instance or an item that reaches a page draws, so a level's cost follows its
// pages, and not all that is over its valid rectangle.
@(private = "file")
add_virtual_culling :: proc(f: ^Frame) {
	sf := f.scene_frame
	if sf == nil || len(sf.items) == 0 {
		return
	}
	g := f.graph
	table := f.shadows.virtual.table
	add_virtual_instance_passes(f, table)
	p := add_compute_pass(g, "cull virtual shadow draws", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		sf := f.scene_frame
		pipeline := f.renderer.scene.cull_pipeline.pipeline
		if pipeline == {} {
			return
		}
		gpu.cmd_set_pipeline(ctx.cb, pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, sf.virtual_cull)
		gpu.cmd_dispatch(ctx.cb, {u32(len(sf.items) + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, u32(f.shadows.virtual.count), 1})
	}, f)
	read(g, p, sf.instances)
	read(g, p, table)
	if len(sf.sets) > 0 {
		read(g, p, sf.instance_counters)
	}
	if sf.meshlet_select.selections != 0 {
		read(g, p, sf.meshlet_select.selections)
	}
	write(g, p, sf.arguments)
	write(g, p, sf.mesh_arguments)
	write(g, p, sf.draws)
	write(g, p, sf.counts)
	if sf.stats != 0 {
		write(g, p, sf.stats)
	}
}

@(private = "file")
set_virtual_allocate :: proc(ctx: ^Pass_Context, phase: Allocate_Phase) -> bool {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.shadows.virtual.allocate_pipeline.pipeline
	if pipeline == {} || sf == nil || sf.view_constants == nil {
		return false
	}
	g := ctx.graph
	vf := &f.shadows.virtual
	push := Virtual_Allocate_Push {
		requests   = gpu.write_index(gpu_buffer(g, vf.requests)),
		table      = gpu.write_index(gpu_buffer(g, vf.table)),
		pages      = gpu.write_index(gpu_buffer(g, vf.pages)),
		scratch    = gpu.write_index(gpu_buffer(g, vf.scratch)),
		stats      = gpu.write_index(gpu_buffer(g, vf.stats)),
		arguments  = gpu.write_index(gpu_buffer(g, vf.arguments)),
		phase      = u32(phase),
		now        = vf.cache.epoch,
		invalidate = vf.invalidate,
	}
	if vf.drops {
		push.dropped, push.dropped_offset, push.drops = gpu.read_index(vf.dropped.buffer), vf.dropped.offset, 1
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	return true
}

@(private = "file")
allocate_groups :: proc(threads: int) -> u32 {
	return u32(threads + VIRTUAL_ALLOCATE_GROUP_SIZE - 1) / VIRTUAL_ALLOCATE_GROUP_SIZE
}

@(private = "file")
pool_page_count :: proc(f: ^Frame) -> int {
	pages := f.state.virtual_shadows.pool_pages
	return int(pages.x * pages.y)
}

// run_virtual_clear clears the requests, the scratch and the drawn counts, and with reset, every entry of the table, for
// a quality with more levels may read past this one's, and every page's record. The two write apart, so they need no
// barrier between them.
@(private = "file")
run_virtual_clear :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	if f.shadows.virtual.reset && set_virtual_allocate(ctx, .Reset) {
		gpu.cmd_dispatch(ctx.cb, {allocate_groups(max(VIRTUAL_TABLE_COUNTS, pool_page_count(f))), 1, 1})
	}
	if set_virtual_allocate(ctx, .Clear) {
		gpu.cmd_dispatch(ctx.cb, {allocate_groups(max(VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_WORDS, VIRTUAL_SCRATCH_LIST)), 1, 1})
	}
}

// run_allocate_phase dispatches a phase of the allocation: one thread for a phase that runs in order, or a thread for
// each of the pool's pages.
@(private = "file")
run_allocate_phase :: proc(ctx: ^Pass_Context, phase: Allocate_Phase) {
	if !set_virtual_allocate(ctx, phase) {
		return
	}
	#partial switch phase {
	case .Retire, .Collect:
		gpu.cmd_dispatch(ctx.cb, {allocate_groups(pool_page_count((^Frame)(ctx.data))), 1, 1})
	case:
		gpu.cmd_dispatch(ctx.cb, {1, 1, 1})
	}
}

// allocate_phase_proc is the Pass_Proc of a phase that add_virtual_shadow_passes adds in its loop.
@(private = "file")
allocate_phase_proc :: proc(phase: Allocate_Phase) -> Pass_Proc {
	#partial switch phase {
	case .Fit:
		return proc(ctx: ^Pass_Context) {run_allocate_phase(ctx, .Fit)}
	case .Retire:
		return proc(ctx: ^Pass_Context) {run_allocate_phase(ctx, .Retire)}
	case .Select:
		return proc(ctx: ^Pass_Context) {run_allocate_phase(ctx, .Select)}
	case .Collect:
		return proc(ctx: ^Pass_Context) {run_allocate_phase(ctx, .Collect)}
	}
	return proc(ctx: ^Pass_Context) {run_allocate_phase(ctx, .Assign)}
}

// run_virtual_pool_clear clears the pages that the frame draws, a group of rows of a page each, from the arguments that
// assign wrote.
@(private = "file")
run_virtual_pool_clear :: proc(ctx: ^Pass_Context) {
	if set_virtual_allocate(ctx, .Clear_Pool) {
		f := (^Frame)(ctx.data)
		gpu.cmd_dispatch_indirect(ctx.cb, gpu_buffer(ctx.graph, f.shadows.virtual.arguments), 0)
	}
}

@(private = "file")
run_virtual_mark :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.scene_frame
	pipeline := f.renderer.shadows.virtual.mark_pipeline.pipeline
	if pipeline == {} || sf == nil || sf.view_constants == nil {
		return
	}
	g := ctx.graph
	vf := &f.shadows.virtual
	c := vf.camera
	view_model := view_model_view(f.view)
	view_model_scale := projection_scale(
		view_projection(view_model, f32(f.size.x) / f32(max(f.size.y, 1))),
	)
	push := Virtual_Mark_Push {
		forward    = {c.forward.x, c.forward.y, c.forward.z, 0},
		projection = {c.scale.x, c.scale.y, c.near, 0},
		view_model = {view_model_scale.x, view_model_scale.y, view_near(view_model), 0},
		depth      = gpu.read_index(gpu_texture(g, f.depth)),
		stencil    = gpu.stencil_index(gpu_texture(g, f.depth)),
		requests   = gpu.write_index(gpu_buffer(g, vf.requests)),
		phase      = u32(Mark_Phase.Pixels),
		size       = f.size,
		reach      = VIRTUAL_VOLUME_REACH,
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	groups := (f.size + VIRTUAL_MARK_GROUP_SIZE - 1) / VIRTUAL_MARK_GROUP_SIZE
	gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, 1})
	// The volume mark's pages are for what has no prepass. Every caster over them draws, so a frame without it marks none.
	if f.fog != nil || has_transparency(f) || has_sprites(f) {
		push.phase = u32(Mark_Phase.Volume)
		gpu.cmd_push_constants(ctx.cb, &push)
		grid := VIRTUAL_VOLUME_GRID
		gpu.cmd_dispatch(ctx.cb, {grid.x / VIRTUAL_MARK_GROUP_SIZE, grid.y / VIRTUAL_MARK_GROUP_SIZE, grid.z})
	}
}

@(private = "file")
draw_virtual_shadow_maps :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	scissor := f.shadows.viewports[ctx.piece]
	gpu.cmd_set_viewport(ctx.cb, {0, 0}, {VIRTUAL_SIZE, VIRTUAL_SIZE})
	gpu.cmd_set_scissor(ctx.cb, {i32(scissor.x), i32(scissor.y)}, {i32(scissor.z), i32(scissor.w)})
	draw_scene_view(f, ctx.cb, FIRST_SHADOW_VIEW + ctx.piece, .Virtual_Depth)
}
