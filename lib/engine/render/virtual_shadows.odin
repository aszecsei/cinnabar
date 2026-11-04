package render

import "core:math"
import "core:math/bits"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// The virtual shadow map (see docs/rendering/lighting-and-shadows.md#virtual-shadow-maps): a directional light's stack of
// clipmap levels around the camera, each a virtual texture twice the extent of the one before. A compute pass marks the
// pages that the frame reads, a second gives them physical pages in one pool, and the depth pass and the lights reach
// the pool through a page table. virtual_shadow.hlsli holds the shaders' side, and the procs here match it, so tests
// on the null backend cover the logic that the shaders run.

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
// A page table's entry for a virtual page without a physical page.
VIRTUAL_NO_PAGE :: max(u32)
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
// Copies of the stats that the CPU reads, so a read never waits for a frame in flight.
VIRTUAL_STATS_COPIES :: 3
VIRTUAL_MARK_GROUP_SIZE :: 8
// Matches numthreads in virtual_shadow_allocate.hlsl.
VIRTUAL_ALLOCATE_GROUP_SIZE :: 64

VIRTUAL_MARK_SHADER :: #load("../content/shaders/virtual_shadow_mark.hlsl.meta", string)
VIRTUAL_ALLOCATE_SHADER :: #load("../content/shaders/virtual_shadow_allocate.hlsl.meta", string)

// Virtual_Shadow_Stats are the virtual shadow map's pages a frame or two ago, which the editor shows: those that the
// frame asked for, those that it got, those that the pool had no room for, and how many the pool holds. Matches the
// words that virtual_shadow_allocate.hlsl stores.
Virtual_Shadow_Stats :: struct {
	requested: u32,
	allocated: u32,
	missed:    u32,
	capacity:  u32,
}

// Virtual_Shadows is the virtual shadow map's state between frames, in Shadow_Passes. The pool is not a graph's
// transient texture: every view's Frame_Constants holds its indices, and they are written before transients have any.
Virtual_Shadows :: struct {
	mark_pipeline:     Shader_Pipeline,
	allocate_pipeline: Shader_Pipeline,
	requests:          gpu.Buffer,
	table:             gpu.Buffer,
	arguments:         gpu.Buffer,
	stats:             gpu.Buffer,
	stats_copies:      [VIRTUAL_STATS_COPIES]gpu.Buffer,
	stats_written:     [VIRTUAL_STATS_COPIES]bool,
	stats_next:        int,
	last_stats:        Virtual_Shadow_Stats,
	// The last frame counted, so the next copy is the one that it wrote.
	counted:           bool,
	pool:              gpu.Texture,
	pool_pages:        [2]u32,
}

// Virtual_Frame is one frame's virtual shadow map, in Shadow_Frame. count is its levels, 0 without it, which are the
// first shadow views.
@(private)
Virtual_Frame :: struct {
	count:     int,
	camera:    Virtual_Camera,
	pool:      Texture,
	requests:  Buffer,
	table:     Buffer,
	arguments: Buffer,
	stats:     Buffer,
}

// Virtual_Camera is what a level depends on: the camera's axes, projection scales and near plane, its position in the
// render origin's space, and how a distance picks a level.
Virtual_Camera :: struct {
	right, up, forward: [3]f32,
	scale:              [2]f32,
	near:               f32,
	offset:             [3]f32,
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
	requests:  u32,
	table:     u32,
	stats:     u32,
	arguments: u32,
	phase:     u32,
}

@(private = "file")
Mark_Phase :: enum u32 {
	Pixels,
	Volume,
}

@(private = "file")
Allocate_Phase :: enum u32 {
	Clear,
	Pages,
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

// virtual_level is a level for a light's direction. Its grid is of whole pages in the render origin's space, so a page
// stays at the same texels as the camera moves, and each level's grid is on every second line of the one before's, so
// each page has one parent. The level's valid rectangle holds the view's frustum out to the level's reach, in pages: a
// level's pixels are all in there, and a level's depth pass rasterizes only there, so its cost follows the screen. Depth
// is 1 at the light's end of the level's range, and 0 at the other, as the cascades have it.
virtual_level :: proc(c: Virtual_Camera, direction: [3]f32, level: int) -> (l: Virtual_Level) {
	light_right, light_up := light_basis(direction)
	extent := virtual_level_extent(level)
	page := extent / VIRTUAL_PAGES
	half := extent * 0.5
	// In the light's axes. A page's v grows away from up, as a texture's does.
	camera_u := f64(linalg.dot(c.offset, light_right))
	camera_v := -f64(linalg.dot(c.offset, light_up))
	camera_d := f64(linalg.dot(c.offset, direction))
	origin := [2]i32 {
		i32(math.floor(camera_u / page)) - VIRTUAL_PAGES / 2,
		i32(math.floor(camera_v / page)) - VIRTUAL_PAGES / 2,
	}
	// The level's middle, relative to the camera.
	center_u := (f64(origin.x) + VIRTUAL_PAGES / 2) * page - camera_u
	center_v := (f64(origin.y) + VIRTUAL_PAGES / 2) * page - camera_v
	center_d := math.floor(camera_d / page) * page - camera_d

	// A point in the level is at most its half extent times sqrt(2) from the camera across the light, and its range
	// along the light is more than that.
	depth_half := extent
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

@(private = "file")
page_index :: proc(level: int, page: [2]i32) -> int {
	return level * VIRTUAL_LEVEL_PAGES + int(page.y) * VIRTUAL_PAGES + int(page.x)
}

// virtual_mark marks a lookup's pages in a level's bits, for a point at the first level from level on whose valid
// rectangle holds its block, and returns that level, or -1. Matches mark in virtual_shadow_mark.hlsl.
virtual_mark :: proc(
	requests: []u32,
	views: []Shadow_View,
	filter: Shadow_Filter,
	p: [3]f32,
	level: int,
) -> int {
	for l in level ..< len(views) {
		texel, _ := virtual_project(views[l], p)
		base, size := virtual_block(texel, filter)
		low := base - VIRTUAL_MARK_MARGIN
		high := base + size - 1 + VIRTUAL_MARK_MARGIN
		if !virtual_in_rect(views[l], low, high) {
			continue
		}
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
// level's. Matches propagate in virtual_shadow_allocate.hlsl.
virtual_parent_page :: proc(origin, page, parent_origin: [2]i32) -> [2]i32 {
	return {(origin.x + page.x) >> 1 - parent_origin.x, (origin.y + page.y) >> 1 - parent_origin.y}
}

// virtual_propagate sets each marked page's parent, finest first. Matches propagate in virtual_shadow_allocate.hlsl.
virtual_propagate :: proc(requests: []u32, views: []Shadow_View) {
	for level in 0 ..< len(views) - 1 {
		origin, parent_origin := views[level].page_origin, views[level + 1].page_origin
		for word in 0 ..< VIRTUAL_LEVEL_WORDS {
			pending := requests[level * VIRTUAL_LEVEL_WORDS + word]
			for pending != 0 {
				index := word * 32 + int(bits.count_trailing_zeros(pending))
				pending &= pending - 1
				page := [2]i32{i32(index % VIRTUAL_PAGES), i32(index / VIRTUAL_PAGES)}
				parent := virtual_parent_page(origin, page, parent_origin)
				if parent.x >= 0 &&
				   parent.y >= 0 &&
				   parent.x < VIRTUAL_PAGES &&
				   parent.y < VIRTUAL_PAGES {
					parent_index := page_index(level + 1, parent)
					requests[parent_index >> 5] |= 1 << uint(parent_index & 31)
				}
			}
		}
	}
}

// virtual_allocate gives pages out from the coarsest level, writes the table, and returns the stats. The table starts
// with VIRTUAL_NO_PAGE everywhere. Matches allocate in virtual_shadow_allocate.hlsl.
virtual_allocate :: proc(
	requests, table: []u32,
	levels: int,
	capacity: u32,
) -> (
	stats: Virtual_Shadow_Stats,
) {
	stats.capacity = capacity
	for level := levels - 1; level >= 0; level -= 1 {
		for word in 0 ..< VIRTUAL_LEVEL_WORDS {
			pending := requests[level * VIRTUAL_LEVEL_WORDS + word]
			for pending != 0 {
				index := word * 32 + int(bits.count_trailing_zeros(pending))
				pending &= pending - 1
				stats.requested += 1
				if stats.allocated < capacity {
					table[level * VIRTUAL_LEVEL_PAGES + index] = stats.allocated
					stats.allocated += 1
				} else {
					stats.missed += 1
				}
			}
		}
	}
	return
}

// virtual_lookup is the finest level from a point's footprint that has the page that holds the point, or -1. Marks
// propagate to the parents of those pages, so a marked point finds one unless the pool has room for no level of it.
// Matches virtual_find in virtual_shadow.hlsli.
virtual_lookup :: proc(table: []u32, views: []Shadow_View, p: [3]f32, level: int) -> int {
	for l in level ..< len(views) {
		texel, _ := virtual_project(views[l], p)
		at := [2]i32{i32(math.floor(texel.x)), i32(math.floor(texel.y))}
		if virtual_in_rect(views[l], at, at) &&
		   table[page_index(l, at / VIRTUAL_PAGE_TEXELS)] != VIRTUAL_NO_PAGE {
			return l
		}
	}
	return -1
}

// virtual_shadow_stats is the virtual shadow map's pages, a frame or two ago, all 0 after a frame without it.
virtual_shadow_stats :: proc(r: ^Renderer) -> Virtual_Shadow_Stats {
	return r.shadows.virtual.last_stats
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
	platform.gpu_destroy_buffer(v.table)
	platform.gpu_destroy_buffer(v.arguments)
	platform.gpu_destroy_buffer(v.stats)
	for b in v.stats_copies {
		platform.gpu_destroy_buffer(b)
	}
	platform.gpu_destroy_texture(v.pool)
	v^ = {}
}

// read_virtual_stats takes each stats' copy that has come back, the newest last, and keeps it.
@(private)
read_virtual_stats :: proc(r: ^Renderer) {
	v := &r.shadows.virtual
	for k in 0 ..< VIRTUAL_STATS_COPIES {
		i := (v.stats_next + k) % VIRTUAL_STATS_COPIES
		if !v.stats_written[i] {
			continue
		}
		if data, ok := r.platform.gpu_read_buffer(v.stats_copies[i]);
		   ok && len(data) >= size_of(Virtual_Shadow_Stats) {
			v.last_stats = (^Virtual_Shadow_Stats)(raw_data(data))^
			v.stats_written[i] = false
		}
	}
}

// finish_virtual_stats moves on to the next copy, once the frame has copied into this one. A frame without the virtual
// shadow map shows none.
@(private)
finish_virtual_stats :: proc(r: ^Renderer) {
	v := &r.shadows.virtual
	if !v.counted {
		v.stats_written = {}
		v.last_stats = {}
		return
	}
	v.stats_written[v.stats_next] = true
	v.stats_next = (v.stats_next + 1) % VIRTUAL_STATS_COPIES
	v.counted = false
}

// ensure_virtual_shadows syncs the virtual shadow map's pipelines and creates what the level's parameters need, and says
// whether this frame can use it: until they compile, the frame draws the cascades. The pool changes with the quality.
@(private)
ensure_virtual_shadows :: proc(r: ^Renderer, p: Shadow_Params) -> bool {
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
		v.table = platform.gpu_create_buffer(
			{
				size = VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_PAGES * 4,
				usage = {.Storage},
				label = "virtual shadow table",
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
		v.stats = platform.gpu_create_buffer(
			{
				size = size_of(Virtual_Shadow_Stats),
				usage = {.Storage},
				label = "virtual shadow stats",
			},
			nil,
		)
		for &b in v.stats_copies {
			b = platform.gpu_create_buffer(
				{
					size = size_of(Virtual_Shadow_Stats),
					usage = {.Readback},
					label = "virtual shadow stats readback",
				},
				nil,
			)
		}
	}
	if v.pool_pages != p.pool_pages {
		platform.gpu_destroy_texture(v.pool)
		size := p.pool_pages * VIRTUAL_PAGE_TEXELS
		v.pool = platform.gpu_create_texture(
			{
				size = size,
				format = VIRTUAL_POOL_FORMAT,
				usage = {.Sampled, .Storage},
				label = "virtual shadow pool",
			},
			nil,
		)
		v.pool_pages = p.pool_pages
	}
	return v.requests != {} && v.table != {} && v.arguments != {} && v.stats != {} && v.pool != {}
}

// add_virtual_levels adds the levels of a directional light as the first shadow views.
@(private)
add_virtual_levels :: proc(f: ^Frame, sf: ^Shadow_Frame, direction: [3]f32) {
	c := virtual_camera(f, sf.params)
	sf.virtual.camera = c
	sf.virtual.count = c.selection.levels
	for level in 0 ..< c.selection.levels {
		l := virtual_level(c, direction, level)
		append(&sf.matrices, l.projection)
		append(&sf.views, l.view)
		append(&sf.planes, l.planes)
		append(&sf.eyes, [4]f32{direction.x, direction.y, direction.z, 0})
		append(&sf.viewports, l.scissor)
	}
}

@(private = "file")
virtual_camera :: proc(f: ^Frame, p: Shadow_Params) -> Virtual_Camera {
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	return {
		right = right,
		up = up,
		forward = forward,
		scale = scale,
		near = f.view.near,
		offset = ecs.position_sub(f.view.position, f.renderer.scene.origin),
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
	v := &f.renderer.shadows.virtual
	s := sf.virtual.camera.selection
	c.virtual_levels = u32(s.levels)
	c.virtual_first_texel = s.first_texel
	c.virtual_pixel_angle = s.pixel_angle
	c.virtual_bias = s.bias
	c.virtual_pool = gpu.read_index(v.pool)
	c.virtual_pool_storage = gpu.write_index(v.pool)
	c.virtual_table = gpu.read_index(v.table)
	c.virtual_pool_pages_per_row = v.pool_pages.x
	c.virtual_pool_pages = v.pool_pages.x * v.pool_pages.y
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

// add_virtual_shadow_passes adds the virtual shadow map's passes: clearing the requests and the page table, marking
// from the prepass's depth, allocating, clearing the new pages, and drawing each level. Every page allocates and draws
// again each frame.
@(private)
add_virtual_shadow_passes :: proc(f: ^Frame) {
	r := f.renderer
	v := &r.shadows.virtual
	sf := f.shadows
	vf := &sf.virtual
	g := f.graph
	vf.pool = import_texture(g, v.pool, .Storage)
	vf.requests = import_buffer(g, v.requests)
	vf.table = import_buffer(g, v.table)
	vf.arguments = import_buffer(g, v.arguments)
	vf.stats = import_buffer(g, v.stats)

	p := add_compute_pass(g, "virtual shadow clear", run_virtual_clear, f)
	write(g, p, vf.requests)
	write(g, p, vf.table)

	p = add_compute_pass(g, "virtual shadow mark", run_virtual_mark, f)
	read(g, p, f.depth)
	write(g, p, vf.requests)

	p = add_compute_pass(g, "virtual shadow allocate", run_virtual_allocate, f)
	write(g, p, vf.requests)
	write(g, p, vf.table)
	write(g, p, vf.arguments)
	write(g, p, vf.stats)

	p = add_compute_pass(g, "virtual shadow pages clear", run_virtual_pool_clear, f)
	indirect_buffer(g, p, vf.arguments)
	write(g, p, vf.pool)

	p = add_render_pass(g, "virtual shadow maps", draw_virtual_shadow_maps, f, pieces = vf.count)
	rasterize_size(g, p, {VIRTUAL_SIZE, VIRTUAL_SIZE})
	read(g, p, vf.table)
	write(g, p, vf.pool)
	declare_scene_draws(f, p)

	// The stats' copy, for read_virtual_stats to take once it is back.
	copy := import_buffer(g, v.stats_copies[v.stats_next])
	p = add_compute_pass(g, "virtual shadow stats", proc(ctx: ^Pass_Context) {
			f := (^Frame)(ctx.data)
			v := &f.renderer.shadows.virtual
			gpu.cmd_copy_buffer(
				ctx.cb,
				gpu_buffer(ctx.graph, f.shadows.virtual.stats),
				0,
				v.stats_copies[v.stats_next],
				0,
				size_of(Virtual_Shadow_Stats),
			)
		}, f)
	copy_source(g, p, vf.stats)
	copy_dest(g, p, copy)
	v.counted = true
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
		requests  = gpu.write_index(gpu_buffer(g, vf.requests)),
		table     = gpu.write_index(gpu_buffer(g, vf.table)),
		stats     = gpu.write_index(gpu_buffer(g, vf.stats)),
		arguments = gpu.write_index(gpu_buffer(g, vf.arguments)),
		phase     = u32(phase),
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	return true
}

@(private = "file")
run_virtual_clear :: proc(ctx: ^Pass_Context) {
	if set_virtual_allocate(ctx, .Clear) {
		// The whole table, since a quality with more levels may read the entries past this one's.
		gpu.cmd_dispatch(
			ctx.cb,
			{VIRTUAL_MAX_LEVELS * VIRTUAL_LEVEL_PAGES / VIRTUAL_ALLOCATE_GROUP_SIZE, 1, 1},
		)
	}
}

@(private = "file")
run_virtual_allocate :: proc(ctx: ^Pass_Context) {
	if set_virtual_allocate(ctx, .Pages) {
		gpu.cmd_dispatch(ctx.cb, {1, 1, 1})
	}
}

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
		view_model = {view_model_scale.x, view_model_scale.y, view_model.near, 0},
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
	push.phase = u32(Mark_Phase.Volume)
	gpu.cmd_push_constants(ctx.cb, &push)
	grid := VIRTUAL_VOLUME_GRID
	gpu.cmd_dispatch(
		ctx.cb,
		{grid.x / VIRTUAL_MARK_GROUP_SIZE, grid.y / VIRTUAL_MARK_GROUP_SIZE, grid.z},
	)
}

@(private = "file")
draw_virtual_shadow_maps :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	scissor := f.shadows.viewports[ctx.piece]
	gpu.cmd_set_viewport(ctx.cb, {0, 0}, {VIRTUAL_SIZE, VIRTUAL_SIZE})
	gpu.cmd_set_scissor(ctx.cb, {i32(scissor.x), i32(scissor.y)}, {i32(scissor.z), i32(scissor.w)})
	draw_scene_view(f, ctx.cb, FIRST_SHADOW_VIEW + ctx.piece, .Virtual_Depth)
}
